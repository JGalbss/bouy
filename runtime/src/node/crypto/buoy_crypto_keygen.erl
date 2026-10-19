%% The key generation jobs of internalBinding('crypto')
%% (src/crypto/crypto_keygen.cc and the keygen traits of crypto_rsa.cc,
%% crypto_dsa.cc, crypto_ec.cc, and crypto_dh.cc) on OTP's crypto, and the
%% export jobs of WebCrypto keys. A pair job returns [publicKey,
%% privateKey] in the encodings that its arguments ask for.
-module(buoy_crypto_keygen).

-export([members/0]).

-define(RSA_PSS, 1).
-define(NAMED_CURVE, 1).
-define(FORMAT_RAW, 0).
-define(FORMAT_PKCS8, 1).
-define(FORMAT_SPKI, 2).

-spec members() -> [{binary(), term()}].
members() ->
    Job = fun buoy_crypto_job:class/2,
    [{<<"RsaKeyPairGenJob">>, Job(<<"RsaKeyPairGenJob">>, fun rsa_job/1)},
     {<<"DsaKeyPairGenJob">>, Job(<<"DsaKeyPairGenJob">>, fun dsa_job/1)},
     {<<"EcKeyPairGenJob">>, Job(<<"EcKeyPairGenJob">>, fun ec_job/1)},
     {<<"DhKeyPairGenJob">>, Job(<<"DhKeyPairGenJob">>, fun dh_job/1)},
     {<<"NidKeyPairGenJob">>, Job(<<"NidKeyPairGenJob">>, fun nid_job/1)},
     {<<"SecretKeyGenJob">>, Job(<<"SecretKeyGenJob">>, fun secret_job/1)},
     {<<"RSAKeyExportJob">>, Job(<<"RSAKeyExportJob">>, fun export_job/1)},
     {<<"ECKeyExportJob">>, Job(<<"ECKeyExportJob">>, fun export_job/1)},
     {<<"DHKeyExportJob">>, Job(<<"DHKeyExportJob">>, fun export_job/1)}].

%% A pair job: Generate makes the private key in the job's process, and the
%% encodings in Encoding turn both keys into values in the realm.
pair(Generate, Encoding) ->
    {PublicEncoding, Rest} = buoy_crypto_keys:public_encoding(Encoding),
    {PrivateEncoding, _} = buoy_crypto_keys:private_encoding(Rest),
    {fun() -> {ok, plain_errors(Generate)} end,
     fun(K) ->
         buoy_heap:new_array([buoy_crypto_keys:encode_public(buoy_crypto_pkey:public(K), PublicEncoding),
                              buoy_crypto_keys:encode_private(K, PrivateEncoding)])
     end}.

%% OpenSSL's errors of a key generation reach JavaScript as their message
%% alone (CryptoErrorStore::ToException).
plain_errors(Generate) ->
    try Generate()
    catch
        error:{crypto_failure, {openssl, Reason}} -> buoy_crypto:fail({message, buoy_crypto:openssl_message(Reason)})
    end.

%%% RSA

%% new RsaKeyPairGenJob(mode, variant, modulusLength, publicExponent,
%% [hash, mgf1Hash, saltLength,] ...encoding)
rsa_job([?RSA_PSS, Bits, Exponent, Md, Mgf1, Salt | Rest]) ->
    Pss = pss_params(digest(Md, <<"Invalid digest: ">>), digest(Mgf1, <<"Invalid MGF1 digest: ">>), Salt),
    pair(fun() -> rsa(rsa_pss, Bits, Exponent, Pss) end, Rest);
rsa_job([_, Bits, Exponent | Rest]) ->
    pair(fun() -> rsa(rsa, Bits, Exponent, undefined) end, Rest).

digest(undefined, _) -> undefined;
digest(Name, Prefix) ->
    case buoy_crypto_hash:digest(Name) of
        {ok, Md} -> Md;
        error -> buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_DIGEST">>, <<Prefix/binary, (buoy_crypto:string(Name))/binary>>)
    end.

%% The name that keyDetail reports for a digest.
md_name(#{name := sha}) -> <<"sha1">>;
md_name(#{name := Atom}) -> binary:replace(atom_to_binary(Atom), <<"_">>, <<"-">>).

%% The restrictions of a new RSA-PSS key, as OpenSSL's keygen sets them.
pss_params(undefined, undefined, undefined) -> undefined;
pss_params(Md, Mgf1, Salt) ->
    {ok, Sha1} = buoy_crypto_hash:digest(<<"sha1">>),
    Hash = default(Md, Sha1),
    DefaultSalt = case Md of
        undefined -> 20;
        #{size := Size} -> Size
    end,
    #{md => md_name(Hash), mgf1 => md_name(default(Mgf1, Hash)), salt => default(Salt, DefaultSalt)}.

default(undefined, Default) -> Default;
default(V, _) -> V.

rsa(Kind, Bits, Exponent, Pss) ->
    Bits < 512 andalso buoy_crypto:fail({openssl, key_size_too_small}),
    (Exponent < 3 orelse Exponent rem 2 =:= 0) andalso buoy_crypto:fail({openssl, pub_exponent_out_of_range}),
    {_, [E, N, D, P, Q, DP, DQ, QI]} = crypto:generate_key(rsa, {Bits, Exponent}),
    Int = fun binary:decode_unsigned/1,
    K = #{kind => Kind, n => Int(N), e => Int(E), d => Int(D), p => Int(P), q => Int(Q),
          dp => Int(DP), dq => Int(DQ), qi => Int(QI)},
    case Pss of
        undefined -> K;
        _ -> K#{pss => Pss}
    end.

%%% DSA

%% new DsaKeyPairGenJob(mode, modulusLength, divisorLength, ...encoding)
dsa_job([L, N | Rest]) ->
    pair(fun() -> dsa(L, N) end, Rest).

%% A key of new FIPS 186-4 parameters with primes of L and N bits (N is
%% 160 below 2048 bits and 256 from there when it is -1).
dsa(L, N0) ->
    N = case N0 of
        -1 when L >= 2048 -> 256;
        -1 -> 160;
        _ -> N0
    end,
    (L < 512 orelse N < 160 orelse N >= L) andalso buoy_crypto:fail({openssl, provider_keymgmt_failure}),
    Q = buoy_crypto_random:generate_prime(N, false, undefined, undefined),
    P = dsa_prime(L, Q),
    G = dsa_generator(P, Q, 2),
    X = 1 + rand_below(Q - 1),
    #{kind => dsa, p => P, q => Q, g => G, x => X, y => pow(G, X, P)}.

dsa_prime(L, Q) ->
    X = rand_bits(L) bor (1 bsl (L - 1)),
    P = X - (X rem (2 * Q)) + 1,
    case P >= 1 bsl (L - 1) andalso buoy_crypto_random:is_prime(P, 0) of
        true -> P;
        false -> dsa_prime(L, Q)
    end.

dsa_generator(P, Q, H) ->
    case pow(H, (P - 1) div Q, P) of
        1 -> dsa_generator(P, Q, H + 1);
        G -> G
    end.

%%% EC

%% new EcKeyPairGenJob(mode, namedCurve, paramEncoding, ...encoding)
ec_job([Name, ParamEncoding | Rest]) ->
    Curve = case buoy_crypto_pkey:curve(buoy_crypto:string(Name)) of
        {ok, C} -> C;
        error -> buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_CURVE">>)
    end,
    Explicit = ParamEncoding =/= ?NAMED_CURVE,
    pair(fun() ->
        {Pub, Priv} = crypto:generate_key(ecdh, Curve),
        #{kind => ec, curve => Curve, pub => Pub, priv => binary:decode_unsigned(Priv), explicit => Explicit}
    end, Rest).

%%% DH

%% new DhKeyPairGenJob(mode, group, ...encoding) or (mode, prime or
%% primeLength, generator, ...encoding)
dh_job([Group | Rest]) when is_binary(Group); element(1, Group) =:= '$u16' ->
    Prime = case buoy_crypto_dh:group_prime(buoy_crypto:string(Group)) of
        {ok, P} -> binary:decode_unsigned(P);
        error -> buoy_crypto:fail_code(<<"ERR_CRYPTO_UNKNOWN_DH_GROUP">>)
    end,
    pair(fun() -> dh_key(Prime, 2) end, Rest);
dh_job([Size, Generator | Rest]) when is_integer(Size) ->
    Size < 0 andalso buoy_crypto:fail_code(<<"ERR_OUT_OF_RANGE">>, <<"Invalid prime size">>),
    pair(fun() -> dh_key(buoy_crypto_dh:generate_prime(Size, Generator), Generator) end, Rest);
dh_job([Prime, Generator | Rest]) ->
    P = binary:decode_unsigned(buoy_crypto:bytes(Prime)),
    pair(fun() -> dh_key(P, Generator) end, Rest).

dh_key(P, G) ->
    bit_length(P) < 512 andalso buoy_crypto:fail({openssl, modulus_too_small}),
    G < 2 andalso buoy_crypto:fail({openssl, bad_generator}),
    {Pub, Priv} = crypto:generate_key(dh, [P, G]),
    #{kind => dh, p => P, g => G, y => binary:decode_unsigned(Pub), x => binary:decode_unsigned(Priv)}.

%%% Keys of one algorithm

%% new NidKeyPairGenJob(mode, nid, ...encoding)
nid_job([Nid | Rest]) ->
    Kind = nid_kind(Nid),
    pair(fun() -> nid_key(Kind) end, Rest).

nid_kind(1087) -> ed25519;
nid_kind(1088) -> ed448;
nid_kind(1034) -> x25519;
nid_kind(1035) -> x448;
nid_kind(1457) -> ml_dsa_44;
nid_kind(1458) -> ml_dsa_65;
nid_kind(1459) -> ml_dsa_87;
nid_kind(1454) -> ml_kem_512;
nid_kind(1455) -> ml_kem_768;
nid_kind(1456) -> ml_kem_1024;
nid_kind(1460) -> slh_dsa_sha2_128s;
nid_kind(1461) -> slh_dsa_sha2_128f;
nid_kind(1462) -> slh_dsa_sha2_192s;
nid_kind(1463) -> slh_dsa_sha2_192f;
nid_kind(1464) -> slh_dsa_sha2_256s;
nid_kind(1465) -> slh_dsa_sha2_256f;
nid_kind(1466) -> slh_dsa_shake_128s;
nid_kind(1467) -> slh_dsa_shake_128f;
nid_kind(1468) -> slh_dsa_shake_192s;
nid_kind(1469) -> slh_dsa_shake_192f;
nid_kind(1470) -> slh_dsa_shake_256s;
nid_kind(1471) -> slh_dsa_shake_256f.

nid_key(Kind) when Kind =:= ed25519; Kind =:= ed448 ->
    {Pub, Priv} = crypto:generate_key(eddsa, Kind),
    #{kind => Kind, pub => Pub, priv => Priv};
nid_key(Kind) when Kind =:= x25519; Kind =:= x448 ->
    {Pub, Priv} = crypto:generate_key(eddh, Kind),
    #{kind => Kind, pub => Pub, priv => Priv};
nid_key(Kind) ->
    buoy_crypto_pqc:generate(Kind).

%% new SecretKeyGenJob(mode, length): length counts bits.
secret_job([Bits | _]) ->
    {fun() -> {ok, crypto:strong_rand_bytes(Bits div 8)} end,
     fun(Bytes) -> buoy_crypto_keys:handle({secret, Bytes}) end}.

%%% Export

%% new RSAKeyExportJob(mode, format, key, variant), and ECKeyExportJob and
%% DHKeyExportJob(mode, format, key): the bytes of a WebCrypto export.
export_job([Format, Handle | _]) ->
    Data = buoy_crypto_keys:key_data(Handle),
    {fun() -> {ok, export(Format, Data)} end, fun buoy_crypto:array_buffer/1}.

export(?FORMAT_PKCS8, {private, K}) -> buoy_crypto_pkey:pkcs8(K);
export(?FORMAT_SPKI, {public, K}) -> buoy_crypto_pkey:spki(buoy_crypto_pkey:public(K));
export(?FORMAT_RAW, {public, #{kind := ec, curve := Curve, pub := Pub}}) ->
    {ok, XY} = buoy_crypto_pkey:decode_point(Curve, Pub),
    buoy_crypto_pkey:encode_point(Curve, XY, uncompressed);
export(?FORMAT_RAW, {public, #{pub := Pub}}) -> Pub;
export(Format, _) when Format =:= ?FORMAT_PKCS8; Format =:= ?FORMAT_SPKI ->
    buoy_crypto:fail({message, <<"Invalid key type">>});
export(_, _) ->
    buoy_crypto:fail({message, <<"Cipher job failed">>}).

%%% Numbers

pow(B, E, M) -> binary:decode_unsigned(crypto:mod_pow(B, E, M)).

bit_length(0) -> 0;
bit_length(N) -> bit_length(N bsr 1) + 1.

rand_bits(Bits) ->
    binary:decode_unsigned(crypto:strong_rand_bytes((Bits + 7) div 8)) band ((1 bsl Bits) - 1).

rand_below(N) ->
    binary:decode_unsigned(crypto:strong_rand_bytes((bit_length(N) + 7) div 8 + 8)) rem N.
