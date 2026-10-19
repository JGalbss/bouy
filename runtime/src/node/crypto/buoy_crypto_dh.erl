%% Diffie-Hellman and ECDH of internalBinding('crypto') (src/crypto/crypto_dh.cc
%% and crypto_ec.cc) on OTP's crypto: the classes DiffieHellman,
%% DiffieHellmanGroup, and ECDH, ECDHConvertKey, getCurves, and the jobs
%% that derive a shared secret from two key objects.
-module(buoy_crypto_dh).

-export([members/0, group_prime/1, generate_prime/2, derive/2]).

-spec members() -> [{binary(), term()}].
members() ->
    F = fun buoy_crypto:fn/3,
    DhMethods = [
        {<<"generateKeys">>, 0, fun dh_generate_keys/2},
        {<<"computeSecret">>, 0, fun dh_compute_secret/2},
        {<<"getPrime">>, 0, fun(This, _) -> buffer(maps:get(p, dh(This))) end},
        {<<"getGenerator">>, 0, fun(This, _) -> buffer(maps:get(g, dh(This))) end},
        {<<"getPublicKey">>, 0, fun(This, _) -> dh_part(This, y, <<"No public key - did you forget to generate one?">>) end},
        {<<"getPrivateKey">>, 0, fun(This, _) -> dh_part(This, x, <<"No private key - did you forget to generate one?">>) end},
        {<<"setPublicKey">>, 0, fun(This, Args) -> dh_set(This, y, Args) end},
        {<<"setPrivateKey">>, 0, fun(This, Args) -> dh_set(This, x, Args) end}],
    [{<<"DiffieHellman">>, verify_error(buoy_crypto:class(<<"DiffieHellman">>, fun dh_init/2, DhMethods))},
     {<<"DiffieHellmanGroup">>, verify_error(buoy_crypto:class(<<"DiffieHellmanGroup">>, fun dh_group_init/2, DhMethods))},
     {<<"DHBitsJob">>, buoy_crypto_job:class(<<"DHBitsJob">>, fun dh_bits_job/1)},
     {<<"ECDH">>, buoy_crypto:class(<<"ECDH">>, fun ecdh_init/2, [
        {<<"generateKeys">>, 0, fun ecdh_generate_keys/2},
        {<<"computeSecret">>, 0, fun ecdh_compute_secret/2},
        {<<"getPublicKey">>, 0, fun ecdh_get_public_key/2},
        {<<"getPrivateKey">>, 0, fun ecdh_get_private_key/2},
        {<<"setPublicKey">>, 0, fun ecdh_set_public_key/2},
        {<<"setPrivateKey">>, 0, fun ecdh_set_private_key/2}])},
     {<<"ECDHConvertKey">>, F(<<"ECDHConvertKey">>, 3, fun convert_key/2)},
     {<<"getCurves">>, F(<<"getCurves">>, 0, fun(_, _) -> buoy_heap:new_array(curve_names()) end)},
     {<<"ECDHBitsJob">>, buoy_crypto_job:class(<<"ECDHBitsJob">>, fun ecdh_bits_job/1)}].

buffer(Int) -> buoy_crypto:buffer(binary:encode_unsigned(Int)).

%%% DiffieHellman

%% new DiffieHellman(primeOrLength, generator)
dh_init(This, Args) ->
    length(Args) =:= 2 orelse buoy_crypto:fail({code, 'TypeError', <<"ERR_MISSING_ARGS">>,
                                                <<"Constructor must have two arguments">>}),
    [First, Second] = Args,
    State = case is_integer(First) of
        true ->
            First < 2 andalso buoy_crypto:fail({openssl, modulus_too_small}),
            is_integer(Second) orelse buoy_crypto:fail({code, 'TypeError', <<"ERR_INVALID_ARG_TYPE">>,
                                                        <<"Second argument must be an int32">>}),
            Second < 2 andalso buoy_crypto:fail({openssl, bad_generator}),
            #{p => generate_prime(First, Second), g => Second};
        false ->
            P = binary:decode_unsigned(buoy_crypto:bytes(First)),
            G = case is_integer(Second) of
                true -> Second;
                false -> binary:decode_unsigned(buoy_crypto:bytes(Second))
            end,
            G < 2 andalso buoy_crypto:fail({openssl, bad_generator}),
            #{p => P, g => G}
    end,
    buoy_crypto:put_state(This, {dh, State}).

%% new DiffieHellmanGroup(name)
dh_group_init(This, Args) ->
    P = case group_prime(buoy_crypto:string(buoy_node:arg(1, Args))) of
        {ok, Bytes} -> binary:decode_unsigned(Bytes);
        error -> buoy_crypto:fail_code(<<"ERR_CRYPTO_UNKNOWN_DH_GROUP">>)
    end,
    buoy_crypto:put_state(This, {dh, #{p => P, g => 2, group => true}}).

dh(This) -> buoy_crypto:state(This, dh).

%% verifyError: the codes of DH_check.
verify_error(Class) ->
    Proto = buoy_heap:get(Class, <<"prototype">>),
    Get = buoy_node:fn(<<"get verifyError">>, 0, fun(This, _) -> check(dh(This)) end),
    buoy_heap:define(Proto, <<"verifyError">>, #{get => Get, enumerable => false, configurable => true}),
    Class.

check(#{group := true}) -> 0;
check(#{p := P, g := G}) ->
    Small = [16#80 || buoy_crypto:bit_length(P) < 512],
    Large = [16#100 || buoy_crypto:bit_length(P) > 10000],
    Gen = [16#08 || G =< 1 orelse G >= P - 1],
    Prime = case P band 1 =:= 1 andalso buoy_crypto_random:is_prime(P, 0) of
        false -> [16#01];
        true ->
            case buoy_crypto_random:is_prime(P bsr 1, 0) of
                true -> [];
                false -> [16#02]
            end
    end,
    lists:foldl(fun(C, Acc) -> Acc bor C end, 0, Small ++ Large ++ Gen ++ Prime).

dh_generate_keys(This, _) ->
    #{p := P, g := G} = S = dh(This),
    S1 = case S of
        #{x := X} -> S#{y => buoy_crypto:mod_pow(G, X, P)};
        _ ->
            {Pub, Priv} = crypto:generate_key(dh, [P, G]),
            S#{y => binary:decode_unsigned(Pub), x => binary:decode_unsigned(Priv)}
    end,
    buoy_crypto:put_state(This, {dh, S1}),
    buffer(maps:get(y, S1)).

dh_part(This, Key, Message) ->
    case dh(This) of
        #{Key := V} -> buffer(V);
        _ -> buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_STATE">>, Message)
    end.

dh_set(This, Key, Args) ->
    V = binary:decode_unsigned(buoy_crypto:bytes(buoy_node:arg(1, Args))),
    buoy_crypto:put_state(This, {dh, (dh(This))#{Key => V}}),
    undefined.

%% computeSecret(otherPublicKey): the secret, padded to the size of p.
dh_compute_secret(This, Args) ->
    #{p := P} = S = dh(This),
    Y = binary:decode_unsigned(buoy_crypto:bytes(buoy_node:arg(1, Args))),
    Y =< 1 andalso buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_KEYLEN">>, <<"Supplied key is too small">>),
    Y >= P - 1 andalso buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_KEYLEN">>, <<"Supplied key is too large">>),
    X = case S of
        #{x := V} -> V;
        _ -> buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_KEYTYPE">>, <<"Unspecified validation error">>)
    end,
    buoy_crypto:buffer(padded(buoy_crypto:mod_pow(Y, X, P), P)).

padded(Secret, P) ->
    Size = (buoy_crypto:bit_length(P) + 7) div 8,
    <<Secret:(Size * 8)>>.

%% A safe prime of Bits bits for the generator G, as
%% DH_generate_parameters_ex makes it.
-spec generate_prime(non_neg_integer(), integer()) -> non_neg_integer().
generate_prime(Bits, _) when Bits < 512 -> buoy_crypto:fail({openssl, modulus_too_small});
generate_prime(Bits, 2) -> buoy_crypto_random:generate_prime(Bits, true, 24, 23);
generate_prime(Bits, 5) -> buoy_crypto_random:generate_prime(Bits, true, 60, 59);
generate_prime(Bits, _) -> buoy_crypto_random:generate_prime(Bits, true, 12, 11).

%%% Shared secrets of key objects

%% new DHBitsJob(mode, publicKey, privateKey): EVP_PKEY_derive.
dh_bits_job([PublicHandle, PrivateHandle | _]) ->
    {_, Public} = buoy_crypto_keys:key_data(PublicHandle),
    {private, Private} = buoy_crypto_keys:key_data(PrivateHandle),
    {fun() -> {ok, derive(Private, Public)} end, fun buoy_crypto:array_buffer/1}.

%% new ECDHBitsJob(mode, publicKey, privateKey)
ecdh_bits_job([PublicHandle, PrivateHandle | _]) ->
    case {buoy_crypto_keys:key_data(PublicHandle), buoy_crypto_keys:key_data(PrivateHandle)} of
        {{public, Public}, {private, Private}} ->
            {fun() -> {ok, derive(Private, Public)} end, fun buoy_crypto:array_buffer/1};
        _ -> buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_KEYTYPE">>)
    end.

%% The shared secret of the private key Private and the public key Public.
-spec derive(map(), map()) -> binary().
derive(#{kind := dh, p := P, g := G, x := X}, #{kind := dh, p := P, g := G, y := Y}) ->
    (Y > 1 andalso Y < P - 1) orelse buoy_crypto:fail({openssl, invalid_public_key}),
    padded(buoy_crypto:mod_pow(Y, X, P), P);
derive(#{kind := ec, curve := Curve, priv := D}, #{kind := ec, curve := Curve, pub := Pub}) ->
    Size = (buoy_crypto_pkey:curve_bits(Curve) + 7) div 8,
    crypto:compute_key(ecdh, Pub, <<D:(Size * 8)>>, Curve);
derive(#{kind := Kind, priv := Priv}, #{kind := Kind, pub := Pub}) when Kind =:= x25519; Kind =:= x448 ->
    %% OpenSSL refuses a low-order point, whose secret is all zeros.
    try crypto:compute_key(eddh, Pub, Priv, Kind)
    catch
        error:{error, _, _} -> buoy_crypto:fail({openssl, failed_during_derivation})
    end;
derive(#{kind := Kind}, #{kind := Kind}) when Kind =:= dh; Kind =:= ec ->
    buoy_crypto:fail({openssl, mismatching_domain_parameters});
derive(_, _) ->
    buoy_crypto:fail({openssl, operation_not_supported_for_this_keytype}).

%%% ECDH

%% new ECDH(curve): OBJ_sn2nid names the curve.
ecdh_init(This, Args) ->
    Curve = sn_curve(buoy_node:arg(1, Args)),
    buoy_crypto:put_state(This, {ecdh, #{curve => Curve}}).

sn_curve(Name) ->
    case buoy_crypto_pkey:curve_by_name(buoy_crypto:string(Name)) of
        {ok, C} -> C;
        error -> buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_CURVE">>)
    end.

ecdh(This) -> buoy_crypto:state(This, ecdh).

ecdh_generate_keys(This, _) ->
    #{curve := Curve} = S = ecdh(This),
    {Pub, Priv} = crypto:generate_key(ecdh, Curve),
    buoy_crypto:put_state(This, {ecdh, S#{pub => Pub, priv => binary:decode_unsigned(Priv)}}),
    undefined.

%% computeSecret(otherPublicKey)
ecdh_compute_secret(This, Args) ->
    #{curve := Curve} = S = ecdh(This),
    valid_pair(S) orelse buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_KEYPAIR">>),
    case point(Curve, buoy_crypto:bytes(buoy_node:arg(1, Args))) of
        {ok, XY} ->
            Pub = buoy_crypto_pkey:encode_point(Curve, XY, uncompressed),
            Size = (buoy_crypto_pkey:curve_bits(Curve) + 7) div 8,
            buoy_crypto:buffer(crypto:compute_key(ecdh, Pub, <<(maps:get(priv, S)):(Size * 8)>>, Curve));
        error -> <<"ERR_CRYPTO_ECDH_INVALID_PUBLIC_KEY">>
    end.

valid_pair(#{curve := Curve, priv := D, pub := Pub}) ->
    {Derived, _} = crypto:generate_key(ecdh, Curve, D),
    point(Curve, Derived) =:= point(Curve, Pub);
valid_pair(_) -> false.

%% A point of Curve that lies on it.
point(Curve, Bytes) ->
    case buoy_crypto_pkey:decode_point(Curve, Bytes) of
        {ok, XY} ->
            case buoy_crypto_pkey:on_curve(Curve, XY) of
                true -> {ok, XY};
                false -> error
            end;
        error -> error
    end.

%% getPublicKey(form)
ecdh_get_public_key(This, Args) ->
    case ecdh(This) of
        #{curve := Curve, pub := Pub} ->
            {ok, XY} = buoy_crypto_pkey:decode_point(Curve, Pub),
            buoy_crypto:buffer(buoy_crypto_pkey:encode_point(Curve, XY, form(buoy_node:arg(1, Args))));
        _ -> buoy_crypto:fail_code(<<"ERR_CRYPTO_OPERATION_FAILED">>, <<"Failed to get ECDH public key">>)
    end.

form(2) -> compressed;
form(6) -> hybrid;
form(_) -> uncompressed.

ecdh_get_private_key(This, _) ->
    case ecdh(This) of
        #{priv := D} -> buffer(D);
        _ -> buoy_crypto:fail_code(<<"ERR_CRYPTO_OPERATION_FAILED">>, <<"Failed to get ECDH private key">>)
    end.

%% setPrivateKey(key): the public key follows from it.
ecdh_set_private_key(This, Args) ->
    #{curve := Curve} = S = ecdh(This),
    D = binary:decode_unsigned(buoy_crypto:bytes(buoy_node:arg(1, Args))),
    Order = binary:decode_unsigned(element(4, buoy_crypto_pkey:curve_info(Curve))),
    (D >= 1 andalso D < Order) orelse
        buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_KEYTYPE">>, <<"Private key is not valid for specified curve.">>),
    {Pub, _} = crypto:generate_key(ecdh, Curve, D),
    buoy_crypto:put_state(This, {ecdh, S#{priv => D, pub => Pub}}),
    undefined.

ecdh_set_public_key(This, Args) ->
    #{curve := Curve} = S = ecdh(This),
    case point(Curve, buoy_crypto:bytes(buoy_node:arg(1, Args))) of
        {ok, XY} ->
            buoy_crypto:put_state(This, {ecdh, S#{pub => buoy_crypto_pkey:encode_point(Curve, XY, uncompressed)}}),
            undefined;
        error -> buoy_crypto:fail_code(<<"ERR_CRYPTO_OPERATION_FAILED">>, <<"Failed to convert Buffer to EC_POINT">>)
    end.

%% ECDHConvertKey(key, curve, form)
convert_key(_, Args) ->
    case buoy_crypto:bytes(buoy_node:arg(1, Args)) of
        <<>> -> <<>>;
        Bytes ->
            Curve = sn_curve(buoy_node:arg(2, Args)),
            case point(Curve, Bytes) of
                {ok, XY} -> buoy_crypto:buffer(buoy_crypto_pkey:encode_point(Curve, XY, form(buoy_node:arg(3, Args))));
                error -> buoy_crypto:fail_code(<<"ERR_CRYPTO_OPERATION_FAILED">>, <<"Failed to convert Buffer to EC_POINT">>)
            end
    end.

%% The curves of EC_get_builtin_curves as Node 25.9.0 lists them.
curve_names() ->
    [<<"Oakley-EC2N-3">>, <<"Oakley-EC2N-4">>, <<"SM2">>, <<"brainpoolP160r1">>, <<"brainpoolP160t1">>,
     <<"brainpoolP192r1">>, <<"brainpoolP192t1">>, <<"brainpoolP224r1">>, <<"brainpoolP224t1">>,
     <<"brainpoolP256r1">>, <<"brainpoolP256t1">>, <<"brainpoolP320r1">>, <<"brainpoolP320t1">>,
     <<"brainpoolP384r1">>, <<"brainpoolP384t1">>, <<"brainpoolP512r1">>, <<"brainpoolP512t1">>,
     <<"c2pnb163v1">>, <<"c2pnb163v2">>, <<"c2pnb163v3">>, <<"c2pnb176v1">>, <<"c2pnb208w1">>, <<"c2pnb272w1">>,
     <<"c2pnb304w1">>, <<"c2pnb368w1">>, <<"c2tnb191v1">>, <<"c2tnb191v2">>, <<"c2tnb191v3">>, <<"c2tnb239v1">>,
     <<"c2tnb239v2">>, <<"c2tnb239v3">>, <<"c2tnb359v1">>, <<"c2tnb431r1">>, <<"prime192v1">>, <<"prime192v2">>,
     <<"prime192v3">>, <<"prime239v1">>, <<"prime239v2">>, <<"prime239v3">>, <<"prime256v1">>, <<"secp112r1">>,
     <<"secp112r2">>, <<"secp128r1">>, <<"secp128r2">>, <<"secp160k1">>, <<"secp160r1">>, <<"secp160r2">>,
     <<"secp192k1">>, <<"secp224k1">>, <<"secp224r1">>, <<"secp256k1">>, <<"secp384r1">>, <<"secp521r1">>,
     <<"sect113r1">>, <<"sect113r2">>, <<"sect131r1">>, <<"sect131r2">>, <<"sect163k1">>, <<"sect163r1">>,
     <<"sect163r2">>, <<"sect193r1">>, <<"sect193r2">>, <<"sect233k1">>, <<"sect233r1">>, <<"sect239k1">>,
     <<"sect283k1">>, <<"sect283r1">>, <<"sect409k1">>, <<"sect409r1">>, <<"sect571k1">>, <<"sect571r1">>,
     <<"wap-wsg-idm-ecid-wtls1">>, <<"wap-wsg-idm-ecid-wtls10">>, <<"wap-wsg-idm-ecid-wtls11">>,
     <<"wap-wsg-idm-ecid-wtls12">>, <<"wap-wsg-idm-ecid-wtls3">>, <<"wap-wsg-idm-ecid-wtls4">>,
     <<"wap-wsg-idm-ecid-wtls5">>, <<"wap-wsg-idm-ecid-wtls6">>, <<"wap-wsg-idm-ecid-wtls7">>,
     <<"wap-wsg-idm-ecid-wtls8">>, <<"wap-wsg-idm-ecid-wtls9">>].

%%% Numbers

%% The primes of the groups of RFC 2409 and RFC 3526 (generator 2), as
%% getDiffieHellman(name) gives them.
-spec group_prime(binary()) -> {ok, binary()} | error.
group_prime(Name) -> modp_prime(string:lowercase(Name)).

modp_prime(<<"modp1">>) ->
    {ok, binary:decode_hex(<<"ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd"
      "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a63a3620ffffffffffffffff">>)};
modp_prime(<<"modp2">>) ->
    {ok, binary:decode_hex(<<"ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd"
      "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed"
      "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece65381ffffffffffffffff">>)};
modp_prime(<<"modp5">>) ->
    {ok, binary:decode_hex(<<"ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd"
      "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed"
      "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f"
      "83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca237327ffffffffffffffff">>)};
modp_prime(<<"modp14">>) ->
    {ok, binary:decode_hex(<<"ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd"
      "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed"
      "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f"
      "83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b"
      "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa0510"
      "15728e5a8aacaa68ffffffffffffffff">>)};
modp_prime(<<"modp15">>) ->
    {ok, binary:decode_hex(<<"ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd"
      "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed"
      "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f"
      "83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b"
      "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa0510"
      "15728e5a8aaac42dad33170d04507a33a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7"
      "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864d87602733ec86a64521f2b18177b200c"
      "bbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a93ad2caffffffffffffffff">>)};
modp_prime(<<"modp16">>) ->
    {ok, binary:decode_hex(<<"ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd"
      "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed"
      "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f"
      "83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b"
      "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa0510"
      "15728e5a8aaac42dad33170d04507a33a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7"
      "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864d87602733ec86a64521f2b18177b200c"
      "bbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a92108011a723c12a787e6d7"
      "88719a10bdba5b2699c327186af4e23c1a946834b6150bda2583e9ca2ad44ce8dbbbc2db04de8ef92e8efc141fbecaa6"
      "287c59474e6bc05d99b2964fa090c3a2233ba186515be7ed1f612970cee2d7afb81bdd762170481cd0069127d5b05aa9"
      "93b4ea988d8fddc186ffb7dc90a6c08f4df435c934063199ffffffffffffffff">>)};
modp_prime(<<"modp17">>) ->
    {ok, binary:decode_hex(<<"ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd"
      "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed"
      "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f"
      "83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b"
      "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa0510"
      "15728e5a8aaac42dad33170d04507a33a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7"
      "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864d87602733ec86a64521f2b18177b200c"
      "bbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a92108011a723c12a787e6d7"
      "88719a10bdba5b2699c327186af4e23c1a946834b6150bda2583e9ca2ad44ce8dbbbc2db04de8ef92e8efc141fbecaa6"
      "287c59474e6bc05d99b2964fa090c3a2233ba186515be7ed1f612970cee2d7afb81bdd762170481cd0069127d5b05aa9"
      "93b4ea988d8fddc186ffb7dc90a6c08f4df435c93402849236c3fab4d27c7026c1d4dcb2602646dec9751e763dba37bd"
      "f8ff9406ad9e530ee5db382f413001aeb06a53ed9027d831179727b0865a8918da3edbebcf9b14ed44ce6cbaced4bb1b"
      "db7f1447e6cc254b332051512bd7af426fb8f401378cd2bf5983ca01c64b92ecf032ea15d1721d03f482d7ce6e74fef6"
      "d55e702f46980c82b5a84031900b1c9e59e7c97fbec7e8f323a97a7e36cc88be0f1d45b7ff585ac54bd407b22b4154aa"
      "cc8f6d7ebf48e1d814cc5ed20f8037e0a79715eef29be32806a1d58bb7c5da76f550aa3d8a1fbff0eb19ccb1a313d55c"
      "da56c9ec2ef29632387fe8d76e3c0468043e8f663f4860ee12bf2d5b0b7474d6e694f91e6dcc4024ffffffffffffffff">>)};
modp_prime(<<"modp18">>) ->
    {ok, binary:decode_hex(<<"ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd"
      "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed"
      "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f"
      "83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b"
      "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa0510"
      "15728e5a8aaac42dad33170d04507a33a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7"
      "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864d87602733ec86a64521f2b18177b200c"
      "bbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a92108011a723c12a787e6d7"
      "88719a10bdba5b2699c327186af4e23c1a946834b6150bda2583e9ca2ad44ce8dbbbc2db04de8ef92e8efc141fbecaa6"
      "287c59474e6bc05d99b2964fa090c3a2233ba186515be7ed1f612970cee2d7afb81bdd762170481cd0069127d5b05aa9"
      "93b4ea988d8fddc186ffb7dc90a6c08f4df435c93402849236c3fab4d27c7026c1d4dcb2602646dec9751e763dba37bd"
      "f8ff9406ad9e530ee5db382f413001aeb06a53ed9027d831179727b0865a8918da3edbebcf9b14ed44ce6cbaced4bb1b"
      "db7f1447e6cc254b332051512bd7af426fb8f401378cd2bf5983ca01c64b92ecf032ea15d1721d03f482d7ce6e74fef6"
      "d55e702f46980c82b5a84031900b1c9e59e7c97fbec7e8f323a97a7e36cc88be0f1d45b7ff585ac54bd407b22b4154aa"
      "cc8f6d7ebf48e1d814cc5ed20f8037e0a79715eef29be32806a1d58bb7c5da76f550aa3d8a1fbff0eb19ccb1a313d55c"
      "da56c9ec2ef29632387fe8d76e3c0468043e8f663f4860ee12bf2d5b0b7474d6e694f91e6dbe115974a3926f12fee5e4"
      "38777cb6a932df8cd8bec4d073b931ba3bc832b68d9dd300741fa7bf8afc47ed2576f6936ba424663aab639c5ae4f568"
      "3423b4742bf1c978238f16cbe39d652de3fdb8befc848ad922222e04a4037c0713eb57a81a23f0c73473fc646cea306b"
      "4bcbc8862f8385ddfa9d4b7fa2c087e879683303ed5bdd3a062b3cf5b3a278a66d2a13f83f44f82ddf310ee074ab6a36"
      "4597e899a0255dc164f31cc50846851df9ab48195ded7ea1b1d510bd7ee74d73faf36bc31ecfa268359046f4eb879f92"
      "4009438b481c6cd7889a002ed5ee382bc9190da6fc026e479558e4475677e9aa9e3050e2765694dfc81f56e880b96e71"
      "60c980dd98edd3dfffffffffffffffff">>)};
modp_prime(_) -> error.
