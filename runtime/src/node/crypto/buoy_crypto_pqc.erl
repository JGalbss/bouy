%% The post-quantum keys of the crypto binding (OpenSSL 3.5's ML-DSA,
%% ML-KEM, and SLH-DSA, as ncrypto exposes them). OTP's crypto signs,
%% verifies, encapsulates, and decapsulates, but makes no key from a seed,
%% so the key generation of FIPS 203 and FIPS 204 from a seed runs here:
%% OpenSSL keeps the seed of a key and writes it in PKCS#8 and JWK.
-module(buoy_crypto_pqc).

-export([private_decode/2, private_encode/1, from_raw/3, otp_type/1, generate/1, from_seed/2]).

%% The OTP name of a kind.
-spec otp_type(atom()) -> atom().
otp_type(ml_dsa_44) -> mldsa44;
otp_type(ml_dsa_65) -> mldsa65;
otp_type(ml_dsa_87) -> mldsa87;
otp_type(ml_kem_512) -> mlkem512;
otp_type(ml_kem_768) -> mlkem768;
otp_type(ml_kem_1024) -> mlkem1024;
otp_type(Kind) -> Kind.

is_ml_kem(Kind) -> lists:member(Kind, [ml_kem_512, ml_kem_768, ml_kem_1024]).
is_ml_dsa(Kind) -> lists:member(Kind, [ml_dsa_44, ml_dsa_65, ml_dsa_87]).

%% A new key pair of Kind, with a seed for ML-DSA and ML-KEM.
-spec generate(atom()) -> map().
generate(Kind) ->
    case {is_ml_dsa(Kind), is_ml_kem(Kind)} of
        {true, _} -> from_seed(Kind, crypto:strong_rand_bytes(32));
        {_, true} -> from_seed(Kind, crypto:strong_rand_bytes(64));
        _ ->
            {Pub, Priv} = crypto:generate_key(otp_type(Kind), []),
            #{kind => Kind, pub => Pub, priv => Priv}
    end.

%% The private key of the inner bytes of a PKCS#8 key: the raw key of
%% SLH-DSA, or the seed, the expanded key, or both of ML-DSA and ML-KEM.
-spec private_decode(atom(), binary()) -> map().
private_decode(Kind, Inner) ->
    case is_ml_kem(Kind) orelse is_ml_dsa(Kind) of
        false -> slh_private(Kind, Inner);
        true ->
            case buoy_crypto_der:decode(Inner) of
                {ok, {seq, [{octets, Seed}, {octets, Expanded}]}} ->
                    K = from_seed(Kind, Seed),
                    maps:get(priv, K) =:= Expanded orelse buoy_crypto:fail({openssl, decoder_unsupported}),
                    K;
                {ok, {octets, Expanded}} -> expanded(Kind, Expanded);
                {ok, {ctx_prim, 0, Seed}} -> from_seed(Kind, Seed);
                _ -> buoy_crypto:fail({openssl, decoder_unsupported})
            end
    end.

slh_private(Kind, Priv) ->
    Half = byte_size(Priv) div 2,
    #{kind => Kind, priv => Priv, pub => binary:part(Priv, Half, Half)}.

%% A key of an expanded private key alone.
expanded(Kind, Expanded) ->
    case is_ml_kem(Kind) of
        true ->
            K = (byte_size(Expanded) - 96) div 768,
            #{kind => Kind, priv => Expanded, pub => binary:part(Expanded, 384 * K, 384 * K + 32)};
        false ->
            #{kind => Kind, priv => Expanded, pub => ml_dsa_public(Kind, Expanded)}
    end.

%% The inner bytes of the PKCS#8 form of K, as OpenSSL writes them.
-spec private_encode(map()) -> binary().
private_encode(#{kind := Kind, priv := Priv} = K) ->
    case is_ml_kem(Kind) orelse is_ml_dsa(Kind) of
        false -> Priv;
        true ->
            case K of
                #{seed := Seed} -> buoy_crypto_der:encode({seq, [{octets, Seed}, {octets, Priv}]});
                _ -> buoy_crypto_der:encode({octets, Priv})
            end
    end.

%% A key of raw bytes: a public key, or the seed of a private key.
-spec from_raw(atom(), binary(), boolean()) -> {ok, term()} | error.
from_raw(Kind, Bytes, false) ->
    case byte_size(Bytes) =:= public_size(Kind) of
        true -> {ok, {public, #{kind => Kind, pub => Bytes}}};
        false -> error
    end;
from_raw(Kind, Seed, true) ->
    try {ok, {private, from_seed(Kind, Seed)}}
    catch
        error:{crypto_failure, _} -> error
    end.

public_size(ml_dsa_44) -> 1312;
public_size(ml_dsa_65) -> 1952;
public_size(ml_dsa_87) -> 2592;
public_size(ml_kem_512) -> 800;
public_size(ml_kem_768) -> 1184;
public_size(ml_kem_1024) -> 1568;
public_size(_) -> undefined.

%% The key pair of a seed (ML-DSA.KeyGen_internal and ML-KEM.KeyGen_internal).
-spec from_seed(atom(), binary()) -> map().
from_seed(Kind, <<Xi:32/binary>>) ->
    is_ml_dsa(Kind) orelse buoy_crypto:fail({openssl, decoder_unsupported}),
    {Pk, Sk} = ml_dsa_keygen(dsa_params(Kind), Xi),
    #{kind => Kind, pub => Pk, priv => Sk, seed => Xi};
from_seed(Kind, <<D:32/binary, Z:32/binary>> = Seed) ->
    is_ml_kem(Kind) orelse buoy_crypto:fail({openssl, decoder_unsupported}),
    {Ek, Dk} = ml_kem_keygen(kem_k(Kind), D, Z),
    #{kind => Kind, pub => Ek, priv => Dk, seed => Seed};
from_seed(_, _) ->
    buoy_crypto:fail({openssl, decoder_unsupported}).

shake(Bits, Data, Length) ->
    crypto:hash_final_xof(crypto:hash_update(crypto:hash_init(Bits), Data), Length * 8).

%%% ML-DSA (FIPS 204)

-define(DQ, 8380417).

dsa_params(ml_dsa_44) -> #{k => 4, l => 4, eta => 2};
dsa_params(ml_dsa_65) -> #{k => 6, l => 5, eta => 4};
dsa_params(ml_dsa_87) -> #{k => 8, l => 7, eta => 2}.

ml_dsa_keygen(#{k := K, l := L, eta := Eta}, Xi) ->
    <<Rho:32/binary, RhoPrime:64/binary, Key:32/binary>> = shake(shake256, <<Xi/binary, K, L>>, 128),
    A = [[rej_ntt_poly(<<Rho/binary, S, R>>) || S <- lists:seq(0, L - 1)] || R <- lists:seq(0, K - 1)],
    S1 = [rej_bounded_poly(<<RhoPrime/binary, R:16/little>>, Eta) || R <- lists:seq(0, L - 1)],
    S2 = [rej_bounded_poly(<<RhoPrime/binary, (R + L):16/little>>, Eta) || R <- lists:seq(0, K - 1)],
    T = dsa_t(A, S1, S2),
    {T1, T0} = lists:unzip([power2round(P) || P <- T]),
    Pk = <<Rho/binary, (<< <<(pack(P, 10))/binary>> || P <- T1 >>)/binary>>,
    Tr = shake(shake256, Pk, 64),
    EtaBits = bit_length(2 * Eta),
    Sk = iolist_to_binary([Rho, Key, Tr,
                           [pack([Eta - C || C <- P], EtaBits) || P <- S1],
                           [pack([Eta - C || C <- P], EtaBits) || P <- S2],
                           [pack([4096 - C || C <- P], 13) || P <- T0]]),
    {Pk, Sk}.

%% The public key of an expanded ML-DSA private key: t = A s1 + s2 again.
ml_dsa_public(Kind, Sk) ->
    #{k := K, l := L, eta := Eta} = dsa_params(Kind),
    EtaBits = bit_length(2 * Eta),
    PolyBytes = 32 * EtaBits,
    <<Rho:32/binary, _Key:32/binary, _Tr:64/binary, Rest/binary>> = Sk,
    <<S1Bytes:(L * PolyBytes)/binary, S2Bytes:(K * PolyBytes)/binary, _/binary>> = Rest,
    S1 = [[Eta - C || C <- unpack(B, EtaBits)] || <<B:PolyBytes/binary>> <= S1Bytes],
    S2 = [[Eta - C || C <- unpack(B, EtaBits)] || <<B:PolyBytes/binary>> <= S2Bytes],
    A = [[rej_ntt_poly(<<Rho/binary, S, R>>) || S <- lists:seq(0, L - 1)] || R <- lists:seq(0, K - 1)],
    {T1, _} = lists:unzip([power2round(P) || P <- dsa_t(A, S1, S2)]),
    <<Rho/binary, (<< <<(pack(P, 10))/binary>> || P <- T1 >>)/binary>>.

%% t = NTT^-1(A NTT(s1)) + s2, with the small coefficients made positive.
dsa_t(A, S1, S2) ->
    S1Hat = [dsa_ntt([(C + ?DQ) rem ?DQ || C <- P]) || P <- S1],
    [poly_add(dsa_intt(row_product(Row, S1Hat, ?DQ)), S2Poly, ?DQ) || {Row, S2Poly} <- lists:zip(A, S2)].

%% RejNTTPoly: coefficients below q from three bytes of SHAKE128 each.
rej_ntt_poly(Seed) -> rej_ntt(shake(shake128, Seed, 840), Seed, 840, []).

rej_ntt(_, _, _, Acc) when length(Acc) =:= 256 -> lists:reverse(Acc);
rej_ntt(<<B0, B1, B2, Rest/binary>>, Seed, Len, Acc) ->
    C = ((B2 band 16#7F) bsl 16) bor (B1 bsl 8) bor B0,
    case C < ?DQ of
        true -> rej_ntt(Rest, Seed, Len, [C | Acc]);
        false -> rej_ntt(Rest, Seed, Len, Acc)
    end;
rej_ntt(_, Seed, Len, Acc) ->
    %% The stream ran out: take a longer one and skip the bytes used.
    Used = Len,
    Longer = shake(shake128, Seed, Len * 2),
    <<_:Used/binary, More/binary>> = Longer,
    rej_ntt(More, Seed, Len * 2, Acc).

%% RejBoundedPoly: coefficients in [-eta, eta] from half bytes of SHAKE256.
rej_bounded_poly(Seed, Eta) -> rej_bounded(shake(shake256, Seed, 512), Seed, 512, Eta, []).

rej_bounded(_, _, _, _, Acc) when length(Acc) >= 256 -> lists:reverse(lists:nthtail(length(Acc) - 256, Acc));
rej_bounded(<<Z, Rest/binary>>, Seed, Len, Eta, Acc) ->
    Acc1 = half_byte(Z band 15, Eta, Acc),
    Acc2 = case length(Acc1) < 256 of
        true -> half_byte(Z bsr 4, Eta, Acc1);
        false -> Acc1
    end,
    rej_bounded(Rest, Seed, Len, Eta, Acc2);
rej_bounded(<<>>, Seed, Len, Eta, Acc) ->
    Longer = shake(shake256, Seed, Len * 2),
    <<_:Len/binary, More/binary>> = Longer,
    rej_bounded(More, Seed, Len * 2, Eta, Acc).

half_byte(B, 2, Acc) when B < 15 -> [2 - (B rem 5) | Acc];
half_byte(B, 4, Acc) when B < 9 -> [4 - B | Acc];
half_byte(_, _, Acc) -> Acc.

power2round(P) ->
    lists:unzip([begin
        R = C rem ?DQ,
        R0 = centered(R band 8191, 8192),
        {(R - R0) bsr 13, R0}
    end || C <- P]).

centered(R, M) when R > M div 2 -> R - M;
centered(R, _) -> R.

dsa_zetas() ->
    case persistent_term:get({?MODULE, dsa_zetas}, undefined) of
        undefined ->
            Z = list_to_tuple([pow(1753, bitrev(K, 8), ?DQ) || K <- lists:seq(0, 255)]),
            persistent_term:put({?MODULE, dsa_zetas}, Z),
            Z;
        Z -> Z
    end.

dsa_ntt(P) -> tuple_to_list(ntt(list_to_tuple(P), dsa_zetas(), ?DQ, 128, 1, 0)).

dsa_intt(P) ->
    W = intt(list_to_tuple(P), dsa_zetas(), ?DQ, 1, 256, 1),
    [(C * 8347681) rem ?DQ || C <- tuple_to_list(W)].

%%% ML-KEM (FIPS 203)

-define(KQ, 3329).

kem_k(ml_kem_512) -> {2, 3};
kem_k(ml_kem_768) -> {3, 2};
kem_k(ml_kem_1024) -> {4, 2}.

ml_kem_keygen({K, Eta1}, D, Z) ->
    <<Rho:32/binary, Sigma:32/binary>> = crypto:hash(sha3_512, <<D/binary, K>>),
    A = [[sample_ntt(<<Rho/binary, J, I>>) || J <- lists:seq(0, K - 1)] || I <- lists:seq(0, K - 1)],
    S = [cbd(shake(shake256, <<Sigma/binary, N>>, 64 * Eta1), Eta1) || N <- lists:seq(0, K - 1)],
    E = [cbd(shake(shake256, <<Sigma/binary, N>>, 64 * Eta1), Eta1) || N <- lists:seq(K, 2 * K - 1)],
    SHat = [kem_ntt(P) || P <- S],
    EHat = [kem_ntt(P) || P <- E],
    THat = [poly_add(lists:foldl(fun({F, G}, Acc) -> poly_add(Acc, multiply_ntts(F, G), ?KQ) end,
                                 lists:duplicate(256, 0), lists:zip(Row, SHat)), EPoly, ?KQ)
            || {Row, EPoly} <- lists:zip(A, EHat)],
    Ek = <<(<< <<(pack(P, 12))/binary>> || P <- THat >>)/binary, Rho/binary>>,
    DkPke = << <<(pack(P, 12))/binary>> || P <- SHat >>,
    {Ek, iolist_to_binary([DkPke, Ek, crypto:hash(sha3_256, Ek), Z])}.

sample_ntt(Seed) -> sample_ntt(shake(shake128, Seed, 840), Seed, 840, []).

sample_ntt(_, _, _, Acc) when length(Acc) >= 256 -> lists:sublist(lists:reverse(Acc), 256);
sample_ntt(<<C0, C1, C2, Rest/binary>>, Seed, Len, Acc) ->
    D1 = C0 + 256 * (C1 band 15),
    D2 = (C1 bsr 4) + 16 * C2,
    Acc2 = case D1 < ?KQ of
        true -> [D1 | Acc];
        false -> Acc
    end,
    Acc3 = case D2 < ?KQ of
        true -> [D2 | Acc2];
        false -> Acc2
    end,
    sample_ntt(Rest, Seed, Len, Acc3);
sample_ntt(_, Seed, Len, Acc) ->
    Longer = shake(shake128, Seed, Len * 2),
    <<_:Len/binary, More/binary>> = Longer,
    sample_ntt(More, Seed, Len * 2, Acc).

%% SamplePolyCBD_eta.
cbd(Bytes, Eta) ->
    Bits = [B || <<Byte>> <= Bytes, B <- [(Byte bsr I) band 1 || I <- lists:seq(0, 7)]],
    cbd_coeffs(Bits, Eta, []).

cbd_coeffs([], _, Acc) -> lists:reverse(Acc);
cbd_coeffs(Bits, Eta, Acc) ->
    {X, Rest1} = lists:split(Eta, Bits),
    {Y, Rest2} = lists:split(Eta, Rest1),
    cbd_coeffs(Rest2, Eta, [(lists:sum(X) - lists:sum(Y) + ?KQ) rem ?KQ | Acc]).

kem_zetas() ->
    case persistent_term:get({?MODULE, kem_zetas}, undefined) of
        undefined ->
            Z = list_to_tuple([pow(17, bitrev(K, 7), ?KQ) || K <- lists:seq(0, 127)]),
            persistent_term:put({?MODULE, kem_zetas}, Z),
            Z;
        Z -> Z
    end.

kem_ntt(P) -> tuple_to_list(ntt(list_to_tuple(P), kem_zetas(), ?KQ, 128, 1, 1)).

%% MultiplyNTTs: the base case products with the gammas 17^(2 BitRev7(i) + 1).
multiply_ntts(F, G) ->
    multiply_ntts(F, G, 0, []).

multiply_ntts([], [], _, Acc) -> lists:reverse(Acc);
multiply_ntts([A0, A1 | F], [B0, B1 | G], I, Acc) ->
    Gamma = pow(17, 2 * bitrev(I, 7) + 1, ?KQ),
    C0 = (A0 * B0 + A1 * B1 * Gamma) rem ?KQ,
    C1 = (A0 * B1 + A1 * B0) rem ?KQ,
    multiply_ntts(F, G, I + 1, [C1, C0 | Acc]).

%%% Polynomials

%% The forward NTT with the zetas Zetas from index First: ML-DSA runs it
%% down to a length of 1, and ML-KEM down to 2 (Stop).
ntt(W, Zetas, Q, Len, M, Stop) when Len > Stop ->
    {W1, M1} = lists:foldl(fun(Start, {Acc, Mi}) ->
        Z = element(Mi + 1, Zetas),
        {lists:foldl(fun(J, A) ->
            T = (Z * element(J + Len + 1, A)) rem Q,
            Wj = element(J + 1, A),
            setelement(J + 1, setelement(J + Len + 1, A, (Wj - T + Q) rem Q), (Wj + T) rem Q)
        end, Acc, lists:seq(Start, Start + Len - 1)), Mi + 1}
    end, {W, M}, lists:seq(0, 255, 2 * Len)),
    ntt(W1, Zetas, Q, Len div 2, M1, Stop);
ntt(W, _, _, _, _, _) -> W.

%% The inverse NTT of ML-DSA, without the final scaling.
intt(W, Zetas, Q, Len, M, _) when Len < 256 ->
    {W1, M1} = lists:foldl(fun(Start, {Acc, Mi}) ->
        Z = Q - element(Mi, Zetas),
        {lists:foldl(fun(J, A) ->
            T = element(J + 1, A),
            U = element(J + Len + 1, A),
            setelement(J + Len + 1, setelement(J + 1, A, (T + U) rem Q), (Z * ((T - U + Q) rem Q)) rem Q)
        end, Acc, lists:seq(Start, Start + Len - 1)), Mi - 1}
    end, {W, M}, lists:seq(0, 255, 2 * Len)),
    intt(W1, Zetas, Q, Len * 2, M1, 0);
intt(W, _, _, _, _, _) -> W.

row_product(Row, Vector, Q) ->
    lists:foldl(fun({F, G}, Acc) -> poly_add(Acc, [(X * Y) rem Q || {X, Y} <- lists:zip(F, G)], Q) end,
                lists:duplicate(256, 0), lists:zip(Row, Vector)).

poly_add(F, G, Q) -> [(X + Y + Q) rem Q || {X, Y} <- lists:zip(F, G)].

%% The coefficients of P in Bits bits each, little-endian bit order.
pack(P, Bits) ->
    Int = lists:foldl(fun(C, Acc) -> (Acc bsl Bits) bor C end, 0, lists:reverse(P)),
    <<Int:(256 * Bits)/little>>.

unpack(Bytes, Bits) ->
    <<Int:(bit_size(Bytes))/little>> = Bytes,
    Mask = (1 bsl Bits) - 1,
    [(Int bsr (I * Bits)) band Mask || I <- lists:seq(0, 255)].

bitrev(K, Bits) ->
    lists:foldl(fun(I, Acc) -> (Acc bsl 1) bor ((K bsr I) band 1) end, 0, lists:seq(0, Bits - 1)).

pow(B, E, M) -> binary:decode_unsigned(crypto:mod_pow(B, E, M)).

bit_length(0) -> 0;
bit_length(N) -> bit_length(N bsr 1) + 1.
