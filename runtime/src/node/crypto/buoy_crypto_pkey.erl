%% The asymmetric keys of the crypto binding, as ncrypto's EVPKeyPointer
%% reads and writes them: SPKI, PKCS#8 (plain or encrypted), PKCS#1, SEC1,
%% and their PEM forms. A key is a map with the numbers of its kind:
%%   rsa, rsa_pss: n, e, and d, p, q, dp, dq, qi when private; rsa_pss may
%%     hold pss => #{md, mgf1, salt};
%%   dsa: p, q, g, y, and x; dh: p, g, maybe q, y, and x;
%%   ec: curve (OTP's name), pub (an encoded point), priv, and explicit;
%%   ed25519, ed448, x25519, x448, ml_dsa_*, ml_kem_*, slh_dsa_*: pub and
%%     priv, and seed for ML-DSA and ML-KEM.
%% A failure raises {crypto_failure, Reason} (buoy_crypto:fail/1), so the
%% functions run in a job's process as well as in the realm.
-module(buoy_crypto_pkey).

-export([parse_public_pem/1, parse_public_der/2, parse_private/4, is_rsa_private/1]).
-export([write_public/3, write_private/5, spki/1, pkcs8/1]).
-export([is_private/1, complete/1, public/1]).
-export([curve/1, curve_by_name/1, curve_name/1, curve_info/1, curve_bits/1, decode_point/2, encode_point/3, on_curve/2]).
-export([pss_params/1]).

%% Functions that only throw.
-dialyzer({no_return, [fail/1]}).

-define(RSA, {1,2,840,113549,1,1,1}).
-define(RSA_PSS, {1,2,840,113549,1,1,10}).
-define(DSA, {1,2,840,10040,4,1}).
-define(DH, {1,2,840,113549,1,3,1}).
-define(DH_X942, {1,2,840,10046,2,1}).
-define(EC, {1,2,840,10045,2,1}).
-define(PRIME_FIELD, {1,2,840,10045,1,1}).
-define(MGF1, {1,2,840,113549,1,1,8}).
-define(PBES2, {1,2,840,113549,1,5,13}).
-define(PBKDF2, {1,2,840,113549,1,5,12}).

-define(FORMAT_DER, 0).
-define(FORMAT_PEM, 1).
-define(PKCS1, 0).
-define(PKCS8, 1).
-define(SPKI, 2).
-define(SEC1, 3).

-type key() :: #{kind := atom(), _ => _}.
-export_type([key/0]).

%%% Kinds

%% The OID of each kind that only names itself in an AlgorithmIdentifier.
oid_kinds() ->
    [{{1,3,101,110}, x25519}, {{1,3,101,111}, x448}, {{1,3,101,112}, ed25519}, {{1,3,101,113}, ed448},
     {{2,16,840,1,101,3,4,3,17}, ml_dsa_44}, {{2,16,840,1,101,3,4,3,18}, ml_dsa_65},
     {{2,16,840,1,101,3,4,3,19}, ml_dsa_87},
     {{2,16,840,1,101,3,4,4,1}, ml_kem_512}, {{2,16,840,1,101,3,4,4,2}, ml_kem_768},
     {{2,16,840,1,101,3,4,4,3}, ml_kem_1024},
     {{2,16,840,1,101,3,4,3,20}, slh_dsa_sha2_128s}, {{2,16,840,1,101,3,4,3,21}, slh_dsa_sha2_128f},
     {{2,16,840,1,101,3,4,3,22}, slh_dsa_sha2_192s}, {{2,16,840,1,101,3,4,3,23}, slh_dsa_sha2_192f},
     {{2,16,840,1,101,3,4,3,24}, slh_dsa_sha2_256s}, {{2,16,840,1,101,3,4,3,25}, slh_dsa_sha2_256f},
     {{2,16,840,1,101,3,4,3,26}, slh_dsa_shake_128s}, {{2,16,840,1,101,3,4,3,27}, slh_dsa_shake_128f},
     {{2,16,840,1,101,3,4,3,28}, slh_dsa_shake_192s}, {{2,16,840,1,101,3,4,3,29}, slh_dsa_shake_192f},
     {{2,16,840,1,101,3,4,3,30}, slh_dsa_shake_256s}, {{2,16,840,1,101,3,4,3,31}, slh_dsa_shake_256f}].

-spec is_private(key()) -> boolean().
is_private(#{kind := Kind} = K) when Kind =:= rsa; Kind =:= rsa_pss -> is_map_key(d, K);
is_private(#{kind := Kind} = K) when Kind =:= dsa; Kind =:= dh -> is_map_key(x, K);
is_private(K) -> is_map_key(priv, K) orelse is_map_key(seed, K).

%% The key without its private numbers.
-spec public(key()) -> key().
public(#{kind := Kind} = K) when Kind =:= rsa; Kind =:= rsa_pss -> maps:without([d, p, q, dp, dq, qi], K);
public(#{kind := Kind} = K) when Kind =:= dsa; Kind =:= dh -> maps:remove(x, K);
public(K) -> maps:without([priv, seed], K).

%%% Parsing

%% A public key in PEM, as TryParsePublicKeyPEM reads it: SPKI, PKCS#1, or
%% a certificate; not_recognized when Text holds none of them.
-spec parse_public_pem(binary()) -> {ok, key()} | not_recognized.
parse_public_pem(Text) ->
    Blocks = buoy_crypto_der:pem_blocks(Text),
    case [{L, D} || {L, D, _} <- Blocks, lists:member(L, [<<"PUBLIC KEY">>, <<"RSA PUBLIC KEY">>, <<"CERTIFICATE">>])] of
        [{<<"PUBLIC KEY">>, Der} | _] -> {ok, spki_decode(Der)};
        [{<<"RSA PUBLIC KEY">>, Der} | _] -> {ok, rsa_public_decode(Der)};
        [{<<"CERTIFICATE">>, Der} | _] -> {ok, certificate_key(Der)};
        [] -> not_recognized
    end.

%% A public key in DER: PKCS#1 or SPKI.
-spec parse_public_der(binary(), integer()) -> key().
parse_public_der(Der, ?PKCS1) -> rsa_public_decode(Der);
parse_public_der(Der, _) -> spki_decode(Der).

%% Whether Der starts as an RSAPrivateKey (IsRSAPrivateKey).
-spec is_rsa_private(binary()) -> boolean().
is_rsa_private(<<16#30, Rest/binary>>) ->
    Body = case Rest of
        <<0:1, _:7, B/binary>> -> B;
        <<1:1, N:7, B/binary>> when byte_size(B) >= N -> binary:part(B, N, byte_size(B) - N);
        _ -> <<>>
    end,
    case Body of
        <<2, 1, V, _/binary>> -> V band 16#FE =:= 0;
        _ -> false
    end;
is_rsa_private(_) -> false.

%% A private key, as TryParsePrivateKey reads it. Passphrase is a binary or
%% undefined.
-spec parse_private(binary(), integer(), integer() | undefined, binary() | undefined) -> key().
parse_private(Text, ?FORMAT_PEM, _, Passphrase) -> private_pem(Text, Passphrase);
parse_private(Der, ?FORMAT_DER, ?PKCS1, _) -> der_or_fail(fun() -> rsa_private_decode(Der) end);
parse_private(Der, ?FORMAT_DER, ?SEC1, _) -> der_or_fail(fun() -> sec1_decode(Der, undefined) end);
parse_private(Der, ?FORMAT_DER, ?PKCS8, Passphrase) ->
    case {is_encrypted_pkcs8(Der), Passphrase} of
        %% d2i_PKCS8PrivateKey_bio reports PEM_R_BAD_PASSWORD_READ, which
        %% TryParsePrivateKey turns into NEED_PASSPHRASE.
        {true, undefined} -> buoy_crypto:fail_code(<<"ERR_MISSING_PASSPHRASE">>);
        {true, _} -> pkcs8_decode(decrypt_pkcs8(Der, Passphrase));
        {false, _} -> pkcs8_decode(Der)
    end;
parse_private(_, _, _, _) -> fail(decoder_unsupported).

private_pem(Text, Passphrase) ->
    Labels = [<<"PRIVATE KEY">>, <<"ENCRYPTED PRIVATE KEY">>, <<"RSA PRIVATE KEY">>, <<"EC PRIVATE KEY">>,
              <<"DSA PRIVATE KEY">>, <<"ANY PRIVATE KEY">>],
    case [B || {L, _, _} = B <- buoy_crypto_der:pem_blocks(Text), lists:member(L, Labels)] of
        [] -> fail(decoder_unsupported);
        [{<<"ENCRYPTED PRIVATE KEY">>, Der, _} | _] -> pkcs8_decode(decrypt_pkcs8(Der, Passphrase));
        [{Label, Der0, Headers} | _] ->
            Der = legacy_decrypt(Der0, Headers, Passphrase),
            der_or_fail(fun() -> legacy_private(Label, Der) end)
    end.

legacy_private(<<"RSA PRIVATE KEY">>, Der) -> rsa_private_decode(Der);
legacy_private(<<"EC PRIVATE KEY">>, Der) -> sec1_decode(Der, undefined);
legacy_private(<<"DSA PRIVATE KEY">>, Der) -> dsa_private_decode(Der);
legacy_private(_, Der) -> pkcs8_decode(Der).

der_or_fail(Fun) ->
    try Fun()
    catch
        error:{crypto_failure, _} = E -> erlang:error(E);
        error:_ -> fail(decoder_unsupported)
    end.

decode(Der) ->
    case buoy_crypto_der:decode(Der) of
        {ok, V} -> V;
        error -> fail(decoder_unsupported)
    end.

%% SubjectPublicKeyInfo.
spki_decode(Der) ->
    der_or_fail(fun() ->
        {seq, [{seq, [{oid, Oid} | Params]}, {bits, Key}]} = decode(Der),
        public_from(Oid, params(Params), Key)
    end).

params([]) -> none;
params([P]) -> P.

public_from(?RSA, _, Key) -> rsa_public_decode(Key);
public_from(?RSA_PSS, Params, Key) -> (rsa_public_decode(Key))#{kind := rsa_pss, pss => pss_decode(Params)};
public_from(?DSA, {seq, [{int, P}, {int, Q}, {int, G}]}, Key) ->
    {int, Y} = decode(Key),
    #{kind => dsa, p => P, q => Q, g => G, y => Y};
public_from(Oid, Params, Key) when Oid =:= ?DH; Oid =:= ?DH_X942 ->
    {int, Y} = decode(Key),
    (dh_params(Oid, Params))#{y => Y};
public_from(?EC, Params, Point) ->
    {Curve, Explicit} = ec_params(Params),
    #{kind => ec, curve => Curve, pub => checked_point(Curve, Point), explicit => Explicit};
public_from(Oid, none, Key) ->
    {_, Kind} = lists:keyfind(Oid, 1, oid_kinds()),
    #{kind => Kind, pub => Key}.

dh_params(?DH, {seq, [{int, P}, {int, G} | _]}) -> #{kind => dh, p => P, g => G};
dh_params(?DH_X942, {seq, [{int, P}, {int, G}, {int, Q} | _]}) -> #{kind => dh, p => P, g => G, q => Q, x942 => true}.

%% ECParameters: a named curve, or explicit numbers that name one.
ec_params({oid, Oid}) ->
    case curve_of_oid(Oid) of
        {ok, Curve} -> {Curve, false};
        error -> fail(decoder_unsupported)
    end;
ec_params({seq, [{int, 1}, {seq, [{oid, ?PRIME_FIELD}, {int, P}]}, {seq, [{octets, A}, {octets, B} | _]},
                 {octets, G}, {int, Order} | _]}) ->
    Match = [C || C <- curves(), prime_curve_matches(C, P, A, B, G, Order)],
    case Match of
        [Curve | _] -> {Curve, true};
        [] -> fail(decoder_unsupported)
    end;
ec_params(_) -> fail(decoder_unsupported).

prime_curve_matches(Curve, P, A, B, G, Order) ->
    case curve_info(Curve) of
        {{prime_field, PB}, {CA, CB, _}, CG, COrder, _} ->
            binary:decode_unsigned(PB) =:= P andalso binary:decode_unsigned(CA) =:= binary:decode_unsigned(A)
                andalso binary:decode_unsigned(CB) =:= binary:decode_unsigned(B)
                andalso binary:decode_unsigned(COrder) =:= Order
                andalso normal_point(Curve, G) =:= CG;
        _ -> false
    end.

rsa_public_decode(Der) ->
    der_or_fail(fun() ->
        {seq, [{int, N}, {int, E}]} = decode(Der),
        #{kind => rsa, n => N, e => E}
    end).

rsa_private_decode(Der) ->
    {seq, [{int, V}, {int, N}, {int, E}, {int, D}, {int, P}, {int, Q}, {int, DP}, {int, DQ}, {int, QI} | _]} = decode(Der),
    true = V =:= 0 orelse V =:= 1,
    #{kind => rsa, n => N, e => E, d => D, p => P, q => Q, dp => DP, dq => DQ, qi => QI}.

dsa_private_decode(Der) ->
    {seq, [{int, 0}, {int, P}, {int, Q}, {int, G}, {int, Y}, {int, X}]} = decode(Der),
    #{kind => dsa, p => P, q => Q, g => G, y => Y, x => X}.

%% ECPrivateKey, with the parameters of its PKCS#8 algorithm when it omits them.
sec1_decode(Der, Outer) ->
    {seq, [{int, 1}, {octets, Priv} | Rest]} = decode(Der),
    Params = case [P || {ctx, 0, [P]} <- Rest] of
        [P] -> P;
        [] when Outer =/= undefined -> Outer
    end,
    {Curve, Explicit} = ec_params(Params),
    D = binary:decode_unsigned(Priv),
    Pub = case [B || {ctx, 1, [{bits, B}]} <- Rest] of
        [B] -> checked_point(Curve, B);
        [] -> derive_ec_public(Curve, D)
    end,
    #{kind => ec, curve => Curve, pub => Pub, priv => D, explicit => Explicit}.

%% PrivateKeyInfo, or OneAsymmetricKey.
pkcs8_decode(Der) ->
    der_or_fail(fun() ->
        {seq, [{int, V}, {seq, [{oid, Oid} | Params]}, {octets, Inner} | _]} = decode(Der),
        true = V =:= 0 orelse V =:= 1,
        private_from(Oid, params(Params), Inner)
    end).

private_from(?RSA, _, Inner) -> rsa_private_decode(Inner);
private_from(?RSA_PSS, Params, Inner) -> (rsa_private_decode(Inner))#{kind := rsa_pss, pss => pss_decode(Params)};
private_from(?DSA, {seq, [{int, P}, {int, Q}, {int, G}]}, Inner) ->
    {int, X} = decode(Inner),
    #{kind => dsa, p => P, q => Q, g => G, x => X, y => crypto_pow(G, X, P)};
private_from(Oid, Params, Inner) when Oid =:= ?DH; Oid =:= ?DH_X942 ->
    {int, X} = decode(Inner),
    #{p := P, g := G} = K = dh_params(Oid, Params),
    K#{x => X, y => crypto_pow(G, X, P)};
private_from(?EC, Params, Inner) -> sec1_decode(Inner, Params);
private_from(Oid, none, Inner) ->
    {_, Kind} = lists:keyfind(Oid, 1, oid_kinds()),
    raw_private(Kind, Inner).

raw_private(Kind, Inner) when Kind =:= ed25519; Kind =:= ed448; Kind =:= x25519; Kind =:= x448 ->
    {octets, Priv} = decode(Inner),
    #{kind => Kind, priv => Priv, pub => derive_okp_public(Kind, Priv)};
raw_private(Kind, Inner) ->
    buoy_crypto_pqc:private_decode(Kind, Inner).

crypto_pow(B, E, M) -> binary:decode_unsigned(crypto:mod_pow(B, E, M)).

%% RSASSA-PSS-params, or none for a key of any parameters.
pss_decode(none) -> undefined;
pss_decode({seq, Fields}) ->
    Md = case [O || {ctx, 0, [{seq, [{oid, O} | _]}]} <- Fields] of
        [O] -> md_of_oid(O);
        [] -> <<"sha1">>
    end,
    Mgf1 = case [O || {ctx, 1, [{seq, [{oid, ?MGF1}, {seq, [{oid, O} | _]}]}]} <- Fields] of
        [O2] -> md_of_oid(O2);
        [] -> <<"sha1">>
    end,
    Salt = case [S || {ctx, 2, [{int, S}]} <- Fields] of
        [S] -> S;
        [] -> 20
    end,
    #{md => Md, mgf1 => Mgf1, salt => Salt}.

%% The parameters of an RSA-PSS key for keyDetail.
-spec pss_params(key()) -> undefined | map().
pss_params(#{pss := Pss}) -> Pss;
pss_params(_) -> undefined.

%%% Encrypted keys

is_encrypted_pkcs8(<<16#30, Rest/binary>>) ->
    Body = case Rest of
        <<0:1, _:7, B/binary>> -> B;
        <<1:1, N:7, B/binary>> when byte_size(B) >= N -> binary:part(B, N, byte_size(B) - N);
        _ -> <<>>
    end,
    case Body of
        <<T, _/binary>> -> T =/= 2;
        _ -> false
    end;
is_encrypted_pkcs8(_) -> false.

%% The PrivateKeyInfo inside an EncryptedPrivateKeyInfo.
decrypt_pkcs8(_, undefined) -> fail(interrupted_or_cancelled);
decrypt_pkcs8(Der, Passphrase) ->
    {Scheme, Data} = der_or_fail(fun() ->
        {seq, [{seq, [{oid, ?PBES2}, {seq, [KdfSpec, EncSpec]}]}, {octets, D}]} = decode(Der),
        {{KdfSpec, EncSpec}, D}
    end),
    {{seq, [{oid, ?PBKDF2}, {seq, [{octets, Salt}, {int, Iter} | KdfRest]}]}, {seq, [{oid, CipherOid} | CipherParams]}} = Scheme,
    Cipher = case [Name || {Name, Oid} <- cipher_oids(), Oid =:= CipherOid] of
        [Name] -> pbe_cipher(Name);
        [] -> fail(unsupported)
    end,
    Prf = case [O || {seq, [{oid, O} | _]} <- KdfRest] of
        [O] -> md_of_oid(hmac_oid(O));
        [] -> <<"sha1">>
    end,
    {ok, Md} = buoy_crypto_hash:digest(Prf),
    Key = buoy_crypto_kdf:pbkdf2(Md, Passphrase, Salt, Iter, maps:get(key, Cipher)),
    IV = case CipherParams of
        [{octets, V}] -> V;
        _ -> <<>>
    end,
    crypt(Cipher, Key, IV, Data, false).

%% The ciphers of OpenSSL's key encryption that OTP's crypto runs, with the
%% OIDs that PBES2 names them by.
cipher_oids() ->
    [{<<"aes-128-ecb">>, {2,16,840,1,101,3,4,1,1}}, {<<"aes-128-cbc">>, {2,16,840,1,101,3,4,1,2}},
     {<<"aes-128-ofb">>, {2,16,840,1,101,3,4,1,3}}, {<<"aes-128-cfb">>, {2,16,840,1,101,3,4,1,4}},
     {<<"aes-192-ecb">>, {2,16,840,1,101,3,4,1,21}}, {<<"aes-192-cbc">>, {2,16,840,1,101,3,4,1,22}},
     {<<"aes-192-ofb">>, {2,16,840,1,101,3,4,1,23}}, {<<"aes-192-cfb">>, {2,16,840,1,101,3,4,1,24}},
     {<<"aes-256-ecb">>, {2,16,840,1,101,3,4,1,41}}, {<<"aes-256-cbc">>, {2,16,840,1,101,3,4,1,42}},
     {<<"aes-256-ofb">>, {2,16,840,1,101,3,4,1,43}}, {<<"aes-256-cfb">>, {2,16,840,1,101,3,4,1,44}},
     {<<"des-ede3-cbc">>, {1,2,840,113549,3,7}}, {<<"des-cbc">>, {1,3,14,3,2,7}}].

%% The cipher of a name, as OpenSSL's key encryption takes it.
pbe_cipher(Name) ->
    case buoy_crypto_cipher:otp_cipher(Name) of
        {ok, C} -> C;
        error -> fail(unsupported)
    end.

%% Data encrypted or decrypted, with PKCS#7 padding for a block cipher.
crypt(#{otp := Otp, block := Block}, Key, IV, Data, Encrypt) ->
    Opts = [{encrypt, Encrypt}] ++ [{padding, pkcs_padding} || Block > 1],
    try
        case IV of
            <<>> -> crypto:crypto_one_time(Otp, Key, Data, Opts);
            _ -> crypto:crypto_one_time(Otp, Key, IV, Data, Opts)
        end
    catch
        error:_ -> fail(bad_decrypt)
    end.

%% The RFC 1421 encryption of a PEM block (Proc-Type and DEK-Info).
legacy_decrypt(Der, Headers, Passphrase) ->
    case lists:keyfind(<<"DEK-Info">>, 1, Headers) of
        false -> Der;
        {_, _} when Passphrase =:= undefined -> fail(interrupted_or_cancelled);
        {_, Info} ->
            [Name, IVHex] = binary:split(Info, <<",">>),
            #{key := KeyLen} = Cipher = pbe_cipher(Name),
            IV = binary:decode_hex(IVHex),
            Key = bytes_to_key(Passphrase, binary:part(IV, 0, 8), KeyLen),
            crypt(Cipher, Key, IV, Der, false)
    end.

%% EVP_BytesToKey with MD5 and one round.
bytes_to_key(Pass, Salt, Length) -> bytes_to_key(Pass, Salt, Length, <<>>, <<>>).

bytes_to_key(_, _, Length, _, Acc) when byte_size(Acc) >= Length -> binary:part(Acc, 0, Length);
bytes_to_key(Pass, Salt, Length, Prev, Acc) ->
    D = crypto:hash(md5, <<Prev/binary, Pass/binary, Salt/binary>>),
    bytes_to_key(Pass, Salt, Length, D, <<Acc/binary, D/binary>>).

%%% Writing

%% The public key K in Format and Type, as writePublicKey writes it.
-spec write_public(key(), integer(), integer()) -> binary().
write_public(K, Format, ?PKCS1) ->
    rsa_only(K),
    out(Format, <<"RSA PUBLIC KEY">>, rsa_public_der(K));
write_public(K, Format, _) ->
    out(Format, <<"PUBLIC KEY">>, spki(K)).

rsa_only(#{kind := rsa}) -> ok;
rsa_only(_) -> fail(unsupported).

out(?FORMAT_PEM, Label, Der) -> buoy_crypto_der:pem_encode(Label, Der);
out(_, _, Der) -> Der.

%% The private key K in Format and Type, encrypted with the cipher named
%% Cipher, or not when it is undefined, under Passphrase.
-spec write_private(key(), integer(), integer(), binary() | undefined, binary() | undefined) -> binary().
write_private(K, Format, ?PKCS1, Cipher, Passphrase) ->
    rsa_only(K),
    legacy_out(Format, <<"RSA PRIVATE KEY">>, rsa_private_der(K), Cipher, Passphrase);
write_private(#{kind := ec} = K, Format, ?SEC1, Cipher, Passphrase) ->
    legacy_out(Format, <<"EC PRIVATE KEY">>, sec1(K, true), Cipher, Passphrase);
write_private(_, _, ?SEC1, _, _) ->
    fail(unsupported);
write_private(K, Format, _, undefined, _) ->
    out(Format, <<"PRIVATE KEY">>, pkcs8(K));
write_private(K, Format, _, Cipher, Passphrase) ->
    out(Format, <<"ENCRYPTED PRIVATE KEY">>, encrypt_pkcs8(pkcs8(K), Cipher, Passphrase)).

legacy_out(?FORMAT_PEM, Label, Der, undefined, _) -> buoy_crypto_der:pem_encode(Label, Der);
legacy_out(?FORMAT_PEM, Label, Der, CipherName, Passphrase) ->
    #{name := Name, key := KeyLen, iv := IVLen} = Cipher = pbe_cipher(CipherName),
    %% PEM_write_bio_* needs a cipher with an IV, whose head salts the key.
    IVLen >= 8 orelse fail(pem_unsupported_cipher),
    IV = crypto:strong_rand_bytes(IVLen),
    Key = bytes_to_key(Passphrase, binary:part(IV, 0, 8), KeyLen),
    Headers = [{<<"Proc-Type">>, <<"4,ENCRYPTED">>},
               {<<"DEK-Info">>, <<(string:uppercase(Name))/binary, ",", (binary:encode_hex(IV))/binary>>}],
    pem_with_headers(Label, Headers, crypt(Cipher, Key, IV, Der, true));
legacy_out(_, _, Der, _, _) -> Der.

pem_with_headers(Label, Headers, Der) ->
    Pem = buoy_crypto_der:pem_encode(Label, Der),
    Begin = <<"-----BEGIN ", Label/binary, "-----\n">>,
    <<Begin:(byte_size(Begin))/binary, Body/binary>> = Pem,
    iolist_to_binary([Begin, [[K, <<": ">>, V, $\n] || {K, V} <- Headers], $\n, Body]).

%% PBES2 with PBKDF2 and HMAC-SHA256, as OpenSSL 3 writes it.
encrypt_pkcs8(Der, CipherName, Passphrase) ->
    #{name := Name, key := KeyLen, iv := IVLen} = Cipher = pbe_cipher(CipherName),
    Oid = case lists:keyfind(Name, 1, cipher_oids()) of
        {_, O} -> O;
        false -> fail(unsupported)
    end,
    Salt = crypto:strong_rand_bytes(16),
    Iter = 2048,
    IV = crypto:strong_rand_bytes(IVLen),
    {ok, Md} = buoy_crypto_hash:digest(<<"sha256">>),
    Key = buoy_crypto_kdf:pbkdf2(Md, Passphrase, Salt, Iter, KeyLen),
    buoy_crypto_der:encode({seq, [
        {seq, [{oid, ?PBES2}, {seq, [
            {seq, [{oid, ?PBKDF2}, {seq, [{octets, Salt}, {int, Iter}, {seq, [{oid, {1,2,840,113549,2,9}}, null]}]}]},
            {seq, [{oid, Oid}, {octets, IV}]}]}]},
        {octets, crypt(Cipher, Key, IV, Der, true)}]}).

%% SubjectPublicKeyInfo of K.
-spec spki(key()) -> binary().
spki(#{kind := rsa} = K) -> spki_der({seq, [{oid, ?RSA}, null]}, rsa_public_der(K));
spki(#{kind := rsa_pss} = K) -> spki_der({seq, [{oid, ?RSA_PSS} | pss_encode(K)]}, rsa_public_der(K));
spki(#{kind := dsa, p := P, q := Q, g := G, y := Y}) ->
    spki_der({seq, [{oid, ?DSA}, {seq, [{int, P}, {int, Q}, {int, G}]}]}, buoy_crypto_der:encode({int, Y}));
spki(#{kind := dh, y := Y} = K) -> spki_der(dh_algorithm(K), buoy_crypto_der:encode({int, Y}));
spki(#{kind := ec, pub := Pub} = K) -> spki_der({seq, [{oid, ?EC}, ec_parameters(K)]}, Pub);
spki(#{kind := Kind, pub := Pub}) -> spki_der({seq, [{oid, kind_oid(Kind)}]}, Pub).

spki_der(Algorithm, Key) -> buoy_crypto_der:encode({seq, [Algorithm, {bits, Key}]}).

kind_oid(Kind) ->
    {Oid, _} = lists:keyfind(Kind, 2, oid_kinds()),
    Oid.

dh_algorithm(#{x942 := true, p := P, g := G, q := Q}) -> {seq, [{oid, ?DH_X942}, {seq, [{int, P}, {int, G}, {int, Q}]}]};
dh_algorithm(#{p := P, g := G}) -> {seq, [{oid, ?DH}, {seq, [{int, P}, {int, G}]}]}.

pss_encode(#{pss := #{md := Md, mgf1 := Mgf1, salt := Salt}}) ->
    Hash = [{ctx, 0, [{seq, [{oid, md_oid(Md)}, null]}]} || Md =/= <<"sha1">>],
    Mask = [{ctx, 1, [{seq, [{oid, ?MGF1}, {seq, [{oid, md_oid(Mgf1)}, null]}]}]} || Mgf1 =/= <<"sha1">>],
    SaltField = [{ctx, 2, [{int, Salt}]} || Salt =/= 20],
    [{seq, Hash ++ Mask ++ SaltField}];
pss_encode(_) -> [].

rsa_public_der(#{n := N, e := E}) -> buoy_crypto_der:encode({seq, [{int, N}, {int, E}]}).

rsa_private_der(#{n := N, e := E, d := D, p := P, q := Q, dp := DP, dq := DQ, qi := QI}) ->
    buoy_crypto_der:encode({seq, [{int, X} || X <- [0, N, E, D, P, Q, DP, DQ, QI]]}).

%% ECPrivateKey, with its parameters when it stands alone (SEC1).
sec1(#{curve := Curve, priv := D, pub := Pub} = K, WithParams) ->
    Size = (curve_bits(Curve) + 7) div 8,
    buoy_crypto_der:encode({seq, [{int, 1}, {octets, <<D:(Size * 8)>>}] ++
        [{ctx, 0, [ec_parameters(K)]} || WithParams] ++ [{ctx, 1, [{bits, Pub}]}]}).

ec_parameters(#{explicit := true, curve := Curve}) ->
    {{prime_field, P}, {A, B, Seed}, G, Order, Cofactor} = curve_info(Curve),
    Size = byte_size(P),
    {seq, [{int, 1}, {seq, [{oid, ?PRIME_FIELD}, {int, binary:decode_unsigned(P)}]},
           {seq, [{octets, left_pad(A, Size)}, {octets, left_pad(B, Size)}] ++ [{bits, Seed} || Seed =/= none]},
           {octets, G}, {int, binary:decode_unsigned(Order)}, {int, binary:decode_unsigned(Cofactor)}]};
ec_parameters(#{curve := Curve}) -> {oid, curve_oid(Curve)}.

left_pad(B, Size) when byte_size(B) >= Size -> B;
left_pad(B, Size) -> <<0:((Size - byte_size(B)) * 8), B/binary>>.

%% PrivateKeyInfo of K.
-spec pkcs8(key()) -> binary().
pkcs8(#{kind := rsa} = K) -> pkcs8_der({seq, [{oid, ?RSA}, null]}, rsa_private_der(K));
pkcs8(#{kind := rsa_pss} = K) -> pkcs8_der({seq, [{oid, ?RSA_PSS} | pss_encode(K)]}, rsa_private_der(K));
pkcs8(#{kind := dsa, p := P, q := Q, g := G, x := X}) ->
    pkcs8_der({seq, [{oid, ?DSA}, {seq, [{int, P}, {int, Q}, {int, G}]}]}, buoy_crypto_der:encode({int, X}));
pkcs8(#{kind := dh, x := X} = K) -> pkcs8_der(dh_algorithm(K), buoy_crypto_der:encode({int, X}));
pkcs8(#{kind := ec} = K) -> pkcs8_der({seq, [{oid, ?EC}, ec_parameters(K)]}, sec1(K, false));
pkcs8(#{kind := Kind, priv := Priv}) when Kind =:= ed25519; Kind =:= ed448; Kind =:= x25519; Kind =:= x448 ->
    pkcs8_der({seq, [{oid, kind_oid(Kind)}]}, buoy_crypto_der:encode({octets, Priv}));
pkcs8(#{kind := Kind} = K) ->
    pkcs8_der({seq, [{oid, kind_oid(Kind)}]}, buoy_crypto_pqc:private_encode(K)).

pkcs8_der(Algorithm, Inner) -> buoy_crypto_der:encode({seq, [{int, 0}, Algorithm, {octets, Inner}]}).

%%% Completing keys

%% K with the numbers that it implies: the CRT numbers of RSA, and public
%% keys from private ones.
-spec complete(key()) -> key().
complete(#{kind := ec, curve := Curve, priv := D} = K) when not is_map_key(pub, K) ->
    K#{pub => derive_ec_public(Curve, D)};
complete(K) -> K.

derive_ec_public(Curve, D) ->
    {Pub, _} = crypto:generate_key(ecdh, Curve, D),
    Pub.

derive_okp_public(Kind, Priv) when Kind =:= ed25519; Kind =:= ed448 ->
    {Pub, _} = crypto:generate_key(eddsa, Kind, Priv),
    Pub;
derive_okp_public(Kind, Priv) ->
    {Pub, _} = crypto:generate_key(eddh, Kind, Priv),
    Pub.

%% The key of the subject of a certificate.
certificate_key(Der) ->
    der_or_fail(fun() ->
        {seq, [{seq, Tbs} | _]} = decode(Der),
        [Spki] = [S || {seq, [{seq, [{oid, _} | _]}, {bits, _}]} = S <- Tbs],
        spki_decode(buoy_crypto_der:encode(Spki))
    end).

%%% Digests

md_oids() ->
    [{<<"sha1">>, {1,3,14,3,2,26}}, {<<"sha224">>, {2,16,840,1,101,3,4,2,4}},
     {<<"sha256">>, {2,16,840,1,101,3,4,2,1}}, {<<"sha384">>, {2,16,840,1,101,3,4,2,2}},
     {<<"sha512">>, {2,16,840,1,101,3,4,2,3}}, {<<"sha512-224">>, {2,16,840,1,101,3,4,2,5}},
     {<<"sha512-256">>, {2,16,840,1,101,3,4,2,6}}, {<<"sha3-224">>, {2,16,840,1,101,3,4,2,7}},
     {<<"sha3-256">>, {2,16,840,1,101,3,4,2,8}}, {<<"sha3-384">>, {2,16,840,1,101,3,4,2,9}},
     {<<"sha3-512">>, {2,16,840,1,101,3,4,2,10}}, {<<"md5">>, {1,2,840,113549,2,5}}].

md_oid(Name) ->
    {_, Oid} = lists:keyfind(Name, 1, md_oids()),
    Oid.

md_of_oid(Oid) ->
    case lists:keyfind(Oid, 2, md_oids()) of
        {Name, _} -> Name;
        false -> fail(unsupported)
    end.

%% The digest of an hmacWith* PRF of PBKDF2.
hmac_oid({1,2,840,113549,2,7}) -> {1,3,14,3,2,26};
hmac_oid({1,2,840,113549,2,8}) -> {2,16,840,1,101,3,4,2,4};
hmac_oid({1,2,840,113549,2,9}) -> {2,16,840,1,101,3,4,2,1};
hmac_oid({1,2,840,113549,2,10}) -> {2,16,840,1,101,3,4,2,2};
hmac_oid({1,2,840,113549,2,11}) -> {2,16,840,1,101,3,4,2,3};
hmac_oid(_) -> fail(unsupported).

%%% Curves

%% The OTP name of an OpenSSL curve name, or error.
%% The NIST names count, as EC_curve_nist2nid reads them.
-spec curve(binary()) -> {ok, atom()} | error.
curve(<<"P-192">>) -> {ok, prime192v1};
curve(<<"P-224">>) -> {ok, secp224r1};
curve(<<"P-256">>) -> {ok, prime256v1};
curve(<<"P-384">>) -> {ok, secp384r1};
curve(<<"P-521">>) -> {ok, secp521r1};
curve(Name) -> curve_by_name(Name).

%% The OTP name of an OpenSSL short name of a curve (OBJ_sn2nid).
-spec curve_by_name(binary()) -> {ok, atom()} | error.
curve_by_name(<<"wap-wsg-idm-ecid-", Name/binary>>) -> known_curve(Name);
curve_by_name(<<"Oakley-EC2N-3">>) -> {ok, ipsec3};
curve_by_name(<<"Oakley-EC2N-4">>) -> {ok, ipsec4};
curve_by_name(<<"secp256r1">>) -> error;
curve_by_name(<<"secp192r1">>) -> error;
curve_by_name(Name) -> known_curve(Name).

known_curve(Name) ->
    Curves = curves(),
    case [C || C <- Curves, atom_to_binary(C) =:= Name] of
        [C | _] -> {ok, C};
        [] -> error
    end.

curves() ->
    [C || C <- proplists:get_value(curves, crypto:supports()),
          not lists:member(C, [ed25519, ed448, x25519, x448, secp256r1, secp192r1])].

%% The OpenSSL name of an OTP curve.
-spec curve_name(atom()) -> binary().
curve_name(ipsec3) -> <<"Oakley-EC2N-3">>;
curve_name(ipsec4) -> <<"Oakley-EC2N-4">>;
curve_name(Curve) ->
    case atom_to_binary(Curve) of
        <<"wtls", _/binary>> = W -> <<"wap-wsg-idm-ecid-", W/binary>>;
        Name -> Name
    end.

curve_oid(prime256v1) -> pubkey_cert_records:namedCurves(secp256r1);
curve_oid(prime192v1) -> pubkey_cert_records:namedCurves(secp192r1);
curve_oid(Curve) ->
    try pubkey_cert_records:namedCurves(Curve)
    catch
        error:_ -> fail(missing_oid)
    end.

curve_of_oid(Oid) ->
    try pubkey_cert_records:namedCurves(Oid) of
        secp256r1 -> {ok, prime256v1};
        secp192r1 -> {ok, prime192v1};
        Curve when is_atom(Curve) -> {ok, Curve}
    catch
        _:_ -> error
    end.

%% The parameters of Curve. crypto:ec_curve/1 returns those of
%% crypto_ec_curves, whose primes are binaries where the spec of
%% ec_prime_field() says integers, so the call goes to the module itself.
-spec curve_info(atom()) -> tuple().
curve_info(Curve) -> crypto_ec_curves:curve(Curve).

%% The bits of the order of Curve: the size of its private keys.
-spec curve_bits(atom()) -> pos_integer().
curve_bits(Curve) ->
    Order = binary:decode_unsigned(element(4, curve_info(Curve))),
    bit_length(Order).

bit_length(0) -> 0;
bit_length(N) -> bit_length(N bsr 1) + 1.

field_bytes(Curve) ->
    case element(1, curve_info(Curve)) of
        {prime_field, P} -> (bit_length(binary:decode_unsigned(P)) + 7) div 8;
        {characteristic_two_field, M, _} -> (M + 7) div 8
    end.

%% The point Bytes of Curve, decoded to {X, Y}, or error (EC_POINT_oct2point).
-spec decode_point(atom(), binary()) -> {ok, {non_neg_integer(), non_neg_integer()}} | error.
decode_point(Curve, Bytes) ->
    Size = field_bytes(Curve),
    case Bytes of
        <<4, X:(Size * 8), Y:(Size * 8)>> -> {ok, {X, Y}};
        <<T, X:(Size * 8), Y:(Size * 8)>> when T =:= 6; T =:= 7 ->
            case Y band 1 =:= T band 1 of
                true -> {ok, {X, Y}};
                false -> error
            end;
        <<T, X:(Size * 8)>> when T =:= 2; T =:= 3 -> decompress(Curve, X, T band 1);
        _ -> error
    end.

decompress(Curve, X, Odd) ->
    case curve_info(Curve) of
        {{prime_field, PB}, {AB, BB, _}, _, _, _} ->
            P = binary:decode_unsigned(PB),
            A = binary:decode_unsigned(AB),
            B = binary:decode_unsigned(BB),
            Rhs = (pow(X, 3, P) + A * X + B) rem P,
            case sqrt_mod(Rhs, P) of
                {ok, Y0} when Y0 band 1 =:= Odd -> {ok, {X, Y0}};
                {ok, Y0} -> {ok, {X, (P - Y0) rem P}};
                error -> error
            end;
        _ -> error
    end.

pow(B, E, M) -> binary:decode_unsigned(crypto:mod_pow(B, E, M)).

%% A square root of A modulo the prime P (Tonelli-Shanks), or error.
sqrt_mod(0, _) -> {ok, 0};
sqrt_mod(A, P) ->
    case pow(A, (P - 1) div 2, P) of
        1 when P rem 4 =:= 3 -> {ok, pow(A, (P + 1) div 4, P)};
        1 -> {ok, tonelli(A, P)};
        _ -> error
    end.

tonelli(A, P) ->
    {Q, S} = odd(P - 1, 0),
    Z = hd([Z || Z <- lists:seq(2, 1000), pow(Z, (P - 1) div 2, P) =:= P - 1]),
    tonelli_loop(S, pow(Z, Q, P), pow(A, Q, P), pow(A, (Q + 1) div 2, P), P).

odd(Q, S) when Q band 1 =:= 0 -> odd(Q bsr 1, S + 1);
odd(Q, S) -> {Q, S}.

tonelli_loop(_, _, 1, R, _) -> R;
tonelli_loop(M, C, T, R, P) ->
    I = least_i(T, 1, P),
    B = pow(C, 1 bsl (M - I - 1), P),
    tonelli_loop(I, B * B rem P, T * B * B rem P, R * B rem P, P).

least_i(T, I, P) ->
    case pow(T, 1 bsl I, P) of
        1 -> I;
        _ -> least_i(T, I + 1, P)
    end.

%% The point {X, Y} of Curve in the form Form: uncompressed, compressed, or hybrid.
-spec encode_point(atom(), {non_neg_integer(), non_neg_integer()}, uncompressed | compressed | hybrid) -> binary().
encode_point(Curve, {X, Y}, Form) ->
    Size = field_bytes(Curve),
    case Form of
        uncompressed -> <<4, X:(Size * 8), Y:(Size * 8)>>;
        compressed -> <<(2 + (Y band 1)), X:(Size * 8)>>;
        hybrid -> <<(6 + (Y band 1)), X:(Size * 8), Y:(Size * 8)>>
    end.

%% Whether {X, Y} lies on Curve (a curve of a binary field is not checked).
-spec on_curve(atom(), {non_neg_integer(), non_neg_integer()}) -> boolean().
on_curve(Curve, {X, Y}) ->
    case curve_info(Curve) of
        {{prime_field, PB}, {AB, BB, _}, _, _, _} ->
            P = binary:decode_unsigned(PB),
            A = binary:decode_unsigned(AB),
            B = binary:decode_unsigned(BB),
            X < P andalso Y < P andalso (Y * Y - (X * X * X + A * X + B)) rem P =:= 0;
        _ -> true
    end.

normal_point(Curve, Bytes) ->
    case decode_point(Curve, Bytes) of
        {ok, XY} -> encode_point(Curve, XY, uncompressed);
        error -> Bytes
    end.

%% A point of a key, which must lie on its curve.
checked_point(Curve, Bytes) ->
    case decode_point(Curve, Bytes) of
        {ok, XY} ->
            on_curve(Curve, XY) orelse fail(decoder_unsupported),
            Bytes;
        error -> fail(decoder_unsupported)
    end.

fail(Reason) -> buoy_crypto:fail({openssl, Reason}).
