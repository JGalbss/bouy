%% KeyObjectHandle and NativeKeyObject of internalBinding('crypto')
%% (src/crypto/crypto_keys.cc): the native side of KeyObject and CryptoKey.
%% A handle holds {secret, Bytes} or {public | private, Key}, where Key is a
%% key of buoy_crypto_pkey. A public handle may hold the key of a private
%% one, as Node shares the EVP_PKEY.
-module(buoy_crypto_keys).

-export([members/0, handle/1, key_data/1, is_handle/1, secret_bytes/1]).
-export([from_args/2, private_encoding/1, public_encoding/1, encode_public/2, encode_private/2]).
-export([kind_name/1, jwk_curve/1, from_clone/1]).

-define(SECRET, 0).
-define(PUBLIC, 1).
-define(PRIVATE, 2).
-define(FORMAT_DER, 0).
-define(FORMAT_PEM, 1).
-define(FORMAT_JWK, 2).
-define(PKCS1, 0).
-define(PKCS8, 1).
-define(SPKI, 2).
-define(SEC1, 3).

-spec members() -> [{binary(), term()}].
members() ->
    [{<<"KeyObjectHandle">>, handle_class()},
     {<<"createNativeKeyObjectClass">>, buoy_crypto:fn(<<"createNativeKeyObjectClass">>, 1, fun native_class/2)}].

%% The class is one per realm, so a handle that the binding makes is an
%% instance of the class that internal/crypto/keys reads.
handle_class() ->
    Key = {?MODULE, handle_class, erlang:get('$buoy_realm')},
    case erlang:get(Key) of
        undefined ->
            Methods = [
                {<<"init">>, 0, fun init/2},
                {<<"getSymmetricKeySize">>, 0, fun(This, _) -> byte_size(secret(key_data(This))) end},
                {<<"getAsymmetricKeyType">>, 0, fun asymmetric_key_type/2},
                {<<"checkEcKeyData">>, 0, fun check_ec_key_data/2},
                {<<"export">>, 0, fun export/2},
                {<<"exportJwk">>, 0, fun export_jwk/2},
                {<<"initECRaw">>, 0, fun init_ec_raw/2},
                {<<"initEDRaw">>, 0, fun init_ed_raw/2},
                {<<"initPqcRaw">>, 0, fun init_pqc_raw/2},
                {<<"rawPublicKey">>, 0, fun raw_public_key/2},
                {<<"rawSeed">>, 0, fun raw_seed/2},
                {<<"initJwk">>, 0, fun init_jwk/2},
                {<<"keyDetail">>, 0, fun key_detail/2},
                {<<"equals">>, 0, fun equals/2}],
            Class = buoy_crypto:class(<<"KeyObjectHandle">>, fun(_, _) -> undefined end,
                                      [M || {Name, _, _} = M <- Methods,
                                            buoy_crypto:is_built(<<"KeyObjectHandle.", Name/binary>>)]),
            erlang:put(Key, Class),
            Class;
        Class ->
            Class
    end.

%% A new KeyObjectHandle that holds Data (KeyObjectHandle::Create).
-spec handle(term()) -> term().
handle(Data) ->
    Class = handle_class(),
    Handle = buoy_heap:construct(Class, [], Class),
    buoy_crypto:put_state(Handle, {key, Data}),
    Handle.

%% The key that a KeyObjectHandle holds.
-spec key_data(term()) -> term().
key_data(Handle) -> buoy_crypto:state(Handle, key).

-spec is_handle(term()) -> boolean().
is_handle(V) ->
    buoy_heap:is_object(V) andalso buoy_heap:private_find(V, buoy_crypto:state_key(key)) =/= error.

%% The bytes of a secret key: a KeyObjectHandle, or the bytes of a buffer
%% (ByteSource::FromSecretKeyBytes).
-spec secret_bytes(term()) -> binary().
secret_bytes(V) ->
    case buoy_heap:is_object(V) andalso buoy_heap:private_find(V, buoy_crypto:state_key(key)) of
        {ok, Data} -> secret(Data);
        _ -> buoy_crypto:bytes(V)
    end.

secret({secret, Bytes}) -> Bytes;
secret(_) -> buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_KEYTYPE">>).

%% createNativeKeyObjectClass(callback): the callback gets NativeKeyObject
%% and returns [KeyObject, SecretKeyObject, PublicKeyObject,
%% PrivateKeyObject], which the realm keeps to make the KeyObjects that it
%% receives. A NativeKeyObject clones for messaging with its key.
native_class(_, Args) ->
    Native = buoy_node:constructor(<<"NativeKeyObject">>, 1, fun(This, A) ->
        Data = key_data(buoy_node:arg(1, A)),
        buoy_crypto:put_state(This, {key, Data}),
        buoy_binding_messaging:set_cloneable(This, ?MODULE, Data),
        undefined
    end),
    Classes = buoy_heap:call(buoy_node:arg(1, Args), undefined, [Native]),
    erlang:put(classes_key(), Classes),
    Classes.

classes_key() -> {?MODULE, key_object_classes, erlang:get('$buoy_realm')}.

%% The KeyObject of this realm for the key of a clone
%% (KeyObjectTransferData::Deserialize), after node:crypto has made the
%% classes.
-spec from_clone(term()) -> term().
from_clone(Data) ->
    erlang:get(classes_key()) =:= undefined andalso buoy_node:require(<<"crypto">>),
    Index = case Data of
        {secret, _} -> 1;
        {public, _} -> 2;
        {private, _} -> 3
    end,
    Class = buoy_heap:get(erlang:get(classes_key()), Index),
    buoy_heap:construct(Class, [handle(Data)], Class).

%%% Reading keys

%% The key of the four arguments (data, format, type, passphrase) at the
%% head of Args, as GetPrivateKeyFromJs (Context private) and
%% GetPublicOrPrivateKeyFromJs (Context public) read them, and the
%% arguments after them.
-spec from_args(list(), private | public) -> {term(), list()}.
from_args(Args0, Context) ->
    Args = Args0 ++ lists:duplicate(4 - min(4, length(Args0)), undefined),
    [Data, Format, Type, Passphrase | Rest] = Args,
    Key = case is_handle(Data) of
        true -> key_data(Data);
        false -> parse(buoy_crypto:data(Data, undefined), Format, Type, passphrase(Passphrase), Context)
    end,
    {Key, Rest}.

passphrase(undefined) -> undefined;
passphrase(null) -> undefined;
passphrase(V) -> buoy_crypto:bytes(V).

parse(Bytes, Format, Type, Passphrase, private) ->
    {private, private_key(Bytes, Format, Type, Passphrase)};
parse(Bytes, ?FORMAT_PEM, _, Passphrase, public) ->
    case buoy_crypto_pkey:parse_public_pem(Bytes) of
        {ok, K} -> {public, K};
        not_recognized -> {private, private_key(Bytes, ?FORMAT_PEM, undefined, Passphrase)}
    end;
parse(Bytes, Format, Type, Passphrase, public) ->
    case Type =:= ?SPKI orelse (Type =:= ?PKCS1 andalso not buoy_crypto_pkey:is_rsa_private(Bytes)) of
        true -> {public, buoy_crypto_pkey:parse_public_der(Bytes, Type)};
        false -> {private, private_key(Bytes, Format, Type, Passphrase)}
    end.

private_key(Bytes, Format, Type, Passphrase) ->
    buoy_crypto_pkey:parse_private(Bytes, Format, Type, Passphrase).

%%% Encodings

%% The encoding of a public key in Args, as GetPublicKeyEncodingFromJs
%% reads it in a key generation: key_object, jwk, or {Format, Type}.
-spec public_encoding(list()) -> {term(), list()}.
public_encoding([undefined, _ | Rest]) -> {key_object, Rest};
public_encoding([?FORMAT_JWK, _ | Rest]) -> {jwk, Rest};
public_encoding([Format, Type | Rest]) -> {{Format, Type}, Rest}.

%% The encoding of a private key: key_object, jwk, or {Format, Type,
%% Cipher, Passphrase}, after GetPrivateKeyEncodingFromJs.
-spec private_encoding(list()) -> {term(), list()}.
private_encoding([undefined, _, _, _ | Rest]) -> {key_object, Rest};
private_encoding([?FORMAT_JWK, _, _, _ | Rest]) -> {jwk, Rest};
private_encoding([Format, Type, Cipher, Passphrase | Rest]) ->
    CipherName = case buoy_crypto:is_string(Cipher) of
        true ->
            Name = buoy_crypto:string(Cipher),
            buoy_crypto_cipher:exists(Name) orelse buoy_crypto:fail_code(<<"ERR_CRYPTO_UNKNOWN_CIPHER">>),
            Name;
        false -> undefined
    end,
    {{Format, Type, CipherName, passphrase(Passphrase)}, Rest}.

%% The public key K in Encoding, in the realm.
-spec encode_public(buoy_crypto_pkey:key(), term()) -> term().
encode_public(K, key_object) -> handle({public, K});
encode_public(K, jwk) -> export_jwk_object({public, K}, buoy_node:object([]), false);
encode_public(K, {Format, Type}) -> output(Format, buoy_crypto_pkey:write_public(K, Format, Type)).

-spec encode_private(buoy_crypto_pkey:key(), term()) -> term().
encode_private(K, key_object) -> handle({private, K});
encode_private(K, jwk) -> export_jwk_object({private, K}, buoy_node:object([]), false);
encode_private(K, {Format, Type, Cipher, Passphrase}) ->
    output(Format, write_private(K, Format, Type, Cipher, Passphrase)).

write_private(K, Format, Type, Cipher, Passphrase) ->
    try buoy_crypto_pkey:write_private(K, Format, Type, Cipher, Passphrase)
    catch
        error:{crypto_failure, {openssl, unsupported}} -> buoy_crypto:fail({message, <<"Failed to encode private key">>})
    end.

output(?FORMAT_PEM, Pem) -> Pem;
output(_, Der) -> buoy_crypto:buffer(Der).

%%% KeyObjectHandle

%% init(kKeyTypeSecret, buffer) or init(type, data, format, type, passphrase)
init(This, [?SECRET, Bytes | _]) ->
    buoy_crypto:put_state(This, {key, {secret, buoy_crypto:bytes(Bytes)}});
init(This, [?PUBLIC | Rest]) ->
    {{_, K}, _} = from_args(Rest, public),
    buoy_crypto:put_state(This, {key, {public, K}});
init(This, [?PRIVATE | Rest]) ->
    {Key, _} = from_args(Rest, private),
    buoy_crypto:put_state(This, {key, Key}).

asymmetric_key_type(This, _) ->
    {_, #{kind := Kind}} = key_data(This),
    kind_name(Kind).

%% The name of a kind of key, as asymmetricKeyType gives it.
-spec kind_name(atom()) -> binary().
kind_name(Kind) -> binary:replace(atom_to_binary(Kind), <<"_">>, <<"-">>, [global]).

check_ec_key_data(This, _) ->
    case key_data(This) of
        {private, #{kind := ec, curve := Curve, priv := D, pub := Pub}} ->
            {Derived, _} = crypto:generate_key(ecdh, Curve, D),
            Order = binary:decode_unsigned(element(4, buoy_crypto_pkey:curve_info(Curve))),
            D > 0 andalso D < Order andalso same_point(Curve, Derived, Pub);
        {_, #{kind := ec, curve := Curve, pub := Pub}} ->
            case buoy_crypto_pkey:decode_point(Curve, Pub) of
                {ok, XY} -> buoy_crypto_pkey:on_curve(Curve, XY);
                error -> false
            end
    end.

same_point(Curve, A, B) ->
    buoy_crypto_pkey:decode_point(Curve, A) =:= buoy_crypto_pkey:decode_point(Curve, B).

%% export(), export(format, type), or export(format, type, cipher, passphrase)
export(This, Args) ->
    case key_data(This) of
        {secret, Bytes} -> buoy_crypto:buffer(Bytes);
        {public, K} ->
            {{Format, Type}, _} = public_encoding(Args),
            output(Format, buoy_crypto_pkey:write_public(K, Format, Type));
        {private, K} ->
            [Format, Type | Rest] = Args ++ [undefined, undefined],
            {{_, _, Cipher, Passphrase}, _} = private_encoding([Format, Type | Rest ++ [undefined, undefined]]),
            output(Format, write_private(K, Format, Type, Cipher, Passphrase))
    end.

%% exportJwk(target, handleRsaPss)
export_jwk(This, Args) ->
    export_jwk_object(key_data(This), buoy_node:arg(1, Args), buoy_ref:truthy(buoy_node:arg(2, Args))).

export_jwk_object({secret, Bytes}, Target, _) ->
    set(Target, [{<<"kty">>, <<"oct">>}, {<<"k">>, b64(Bytes)}]);
export_jwk_object({Type, #{kind := Kind} = K}, Target, HandleRsaPss)
  when Kind =:= rsa; Kind =:= rsa_pss andalso HandleRsaPss ->
    #{n := N, e := E} = K,
    Private = [{F, b64(int(maps:get(F, K)))} || Type =:= private, F <- [d, p, q, dp, dq, qi]],
    set(Target, [{<<"kty">>, <<"RSA">>}, {<<"n">>, b64(int(N))}, {<<"e">>, b64(int(E))}] ++
                [{atom_to_binary(F), V} || {F, V} <- Private]);
export_jwk_object({Type, #{kind := ec, curve := Curve, pub := Pub} = K}, Target, _) ->
    Crv = case jwk_curve_name(Curve) of
        {ok, C} -> C;
        error -> buoy_crypto:fail_code(<<"ERR_CRYPTO_JWK_UNSUPPORTED_CURVE">>,
                                       <<"Unsupported JWK EC curve: ", (buoy_crypto_pkey:curve_name(Curve))/binary, ".">>)
    end,
    {ok, {X, Y}} = buoy_crypto_pkey:decode_point(Curve, Pub),
    Size = (field_bits(Curve) + 7) div 8,
    D = [{<<"d">>, b64(<<(maps:get(priv, K)):(Size * 8)>>)} || Type =:= private],
    set(Target, [{<<"kty">>, <<"EC">>}, {<<"x">>, b64(<<X:(Size * 8)>>)}, {<<"y">>, b64(<<Y:(Size * 8)>>)},
                 {<<"crv">>, Crv}] ++ D);
export_jwk_object({Type, #{kind := Kind, pub := Pub} = K}, Target, _)
  when Kind =:= ed25519; Kind =:= ed448; Kind =:= x25519; Kind =:= x448 ->
    D = [{<<"d">>, b64(maps:get(priv, K))} || Type =:= private],
    set(Target, [{<<"crv">>, okp_name(Kind)}] ++ D ++ [{<<"x">>, b64(Pub)}, {<<"kty">>, <<"OKP">>}]);
export_jwk_object({Type, #{kind := Kind, pub := Pub} = K}, Target, _)
  when Kind =:= ml_dsa_44; Kind =:= ml_dsa_65; Kind =:= ml_dsa_87 ->
    Priv = [{<<"priv">>, b64(seed(K))} || Type =:= private],
    set(Target, [{<<"kty">>, <<"AKP">>}, {<<"alg">>, string:uppercase(kind_name(Kind))}, {<<"pub">>, b64(Pub)}] ++ Priv);
export_jwk_object(_, _, _) ->
    buoy_crypto:fail_code(<<"ERR_CRYPTO_JWK_UNSUPPORTED_KEY_TYPE">>).

%% A JWK of ML-DSA holds the seed, which a key from an expanded private key lacks.
seed(#{seed := Seed}) -> Seed;
seed(_) -> buoy_crypto:fail_code(<<"ERR_CRYPTO_OPERATION_FAILED">>, <<"key does not have an available seed">>).

set(Target, Pairs) ->
    [buoy_heap:set(Target, K, V) || {K, V} <- Pairs],
    Target.

b64(Bytes) -> buoy_node_encoding:decode(base64url, Bytes).

int(I) -> binary:encode_unsigned(I).

okp_name(ed25519) -> <<"Ed25519">>;
okp_name(ed448) -> <<"Ed448">>;
okp_name(x25519) -> <<"X25519">>;
okp_name(x448) -> <<"X448">>.

jwk_curve_name(prime256v1) -> {ok, <<"P-256">>};
jwk_curve_name(secp256k1) -> {ok, <<"secp256k1">>};
jwk_curve_name(secp384r1) -> {ok, <<"P-384">>};
jwk_curve_name(secp521r1) -> {ok, <<"P-521">>};
jwk_curve_name(_) -> error.

%% The curve of a JWK crv name.
-spec jwk_curve(binary()) -> {ok, atom()} | error.
jwk_curve(Name) -> buoy_crypto_pkey:curve(Name).

field_bits(Curve) ->
    case element(1, buoy_crypto_pkey:curve_info(Curve)) of
        {prime_field, P} -> buoy_crypto:bit_length(binary:decode_unsigned(P));
        {characteristic_two_field, M, _} -> M
    end.

%% initJwk(jwk, namedCurve): the type of the key that it read.
init_jwk(This, Args) ->
    Jwk = buoy_node:arg(1, Args),
    Kty = buoy_heap:get(Jwk, <<"kty">>),
    buoy_crypto:is_string(Kty) orelse buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_JWK">>),
    {Type, _} = Data = case buoy_crypto:string(Kty) of
        <<"oct">> ->
            K = buoy_heap:get(Jwk, <<"k">>),
            buoy_crypto:is_string(K) orelse
                buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_JWK">>, <<"Invalid JWK secret key format">>),
            {secret, buoy_node_encoding:encode(base64url, K)};
        <<"RSA">> -> rsa_jwk(Jwk);
        <<"EC">> -> ec_jwk(Jwk, buoy_node:arg(2, Args));
        Other ->
            buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_JWK">>, <<Other/binary, " is not a supported JWK key type">>)
    end,
    buoy_crypto:put_state(This, {key, Data}),
    type_number(Type).

type_number(secret) -> ?SECRET;
type_number(public) -> ?PUBLIC;
type_number(private) -> ?PRIVATE.

jwk_field(Jwk, Name, Error) ->
    case buoy_heap:get(Jwk, Name) of
        undefined -> undefined;
        V ->
            buoy_crypto:is_string(V) orelse buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_JWK">>, Error),
            binary:decode_unsigned(buoy_node_encoding:encode(base64url, V))
    end.

rsa_jwk(Jwk) ->
    Error = <<"Invalid JWK RSA key">>,
    [N, E, D] = [jwk_field(Jwk, F, Error) || F <- [<<"n">>, <<"e">>, <<"d">>]],
    (N =:= undefined orelse E =:= undefined) andalso buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_JWK">>, Error),
    Public = #{kind => rsa, n => N, e => E},
    case D of
        undefined -> {public, Public};
        _ ->
            Fields = [jwk_field(Jwk, F, Error) || F <- [<<"p">>, <<"q">>, <<"dp">>, <<"dq">>, <<"qi">>]],
            lists:member(undefined, Fields) andalso buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_JWK">>, Error),
            [P, Q, DP, DQ, QI] = Fields,
            {private, Public#{d => D, p => P, q => Q, dp => DP, dq => DQ, qi => QI}}
    end.

ec_jwk(Jwk, CurveName) ->
    Curve = case jwk_curve(buoy_crypto:string(CurveName)) of
        {ok, C} -> C;
        error -> buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_CURVE">>)
    end,
    Error = <<"Invalid JWK EC key">>,
    [X, Y, D] = [jwk_field(Jwk, F, Error) || F <- [<<"x">>, <<"y">>, <<"d">>]],
    (X =:= undefined orelse Y =:= undefined) andalso buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_JWK">>, Error),
    buoy_crypto_pkey:on_curve(Curve, {X, Y}) orelse buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_JWK">>, Error),
    Pub = buoy_crypto_pkey:encode_point(Curve, {X, Y}, uncompressed),
    Key = #{kind => ec, curve => Curve, pub => Pub, explicit => false},
    case D of
        undefined -> {public, Key};
        _ -> {private, Key#{priv => D}}
    end.

%% initECRaw(curve, point): whether the point is a public key of the curve.
init_ec_raw(This, Args) ->
    case buoy_crypto_pkey:curve(buoy_crypto:string(buoy_node:arg(1, Args))) of
        {ok, Curve} ->
            Point = buoy_crypto:bytes(buoy_node:arg(2, Args)),
            case buoy_crypto_pkey:decode_point(Curve, Point) of
                {ok, XY} ->
                    buoy_crypto_pkey:on_curve(Curve, XY) andalso begin
                        buoy_crypto:put_state(This, {key, {public, #{kind => ec, curve => Curve, pub => Point,
                                                                       explicit => false}}}),
                        true
                    end;
                error -> false
            end;
        error -> false
    end.

%% initEDRaw(name, keyData, type)
init_ed_raw(This, Args) ->
    Kind = okp_kind(buoy_crypto:string(buoy_node:arg(1, Args))),
    Bytes = buoy_crypto:bytes(buoy_node:arg(2, Args)),
    case {buoy_node:arg(3, Args), byte_size(Bytes) =:= okp_size(Kind)} of
        {_, false} -> false;
        {?PRIVATE, true} ->
            Pub = okp_public(Kind, Bytes),
            buoy_crypto:put_state(This, {key, {private, #{kind => Kind, priv => Bytes, pub => Pub}}}),
            true;
        {_, true} ->
            buoy_crypto:put_state(This, {key, {public, #{kind => Kind, pub => Bytes}}}),
            true
    end.

okp_kind(<<"Ed25519">>) -> ed25519;
okp_kind(<<"Ed448">>) -> ed448;
okp_kind(<<"X25519">>) -> x25519;
okp_kind(<<"X448">>) -> x448.

okp_size(ed25519) -> 32;
okp_size(x25519) -> 32;
okp_size(ed448) -> 57;
okp_size(x448) -> 56.

okp_public(Kind, Priv) when Kind =:= ed25519; Kind =:= ed448 -> element(1, crypto:generate_key(eddsa, Kind, Priv));
okp_public(Kind, Priv) -> element(1, crypto:generate_key(eddh, Kind, Priv)).

%% initPqcRaw(name, keyData, type): a seed for a private key.
init_pqc_raw(This, Args) ->
    Kind = binary_to_atom(string:lowercase(binary:replace(buoy_crypto:string(buoy_node:arg(1, Args)), <<"-">>, <<"_">>, [global]))),
    Bytes = buoy_crypto:bytes(buoy_node:arg(2, Args)),
    case buoy_crypto_pqc:from_raw(Kind, Bytes, buoy_node:arg(3, Args) =:= ?PRIVATE) of
        {ok, Data} ->
            buoy_crypto:put_state(This, {key, Data}),
            true;
        error -> false
    end.

raw_public_key(This, _) ->
    {_, #{pub := Pub}} = key_data(This),
    buoy_crypto:buffer(Pub).

raw_seed(This, _) ->
    case key_data(This) of
        {private, #{seed := Seed}} -> buoy_crypto:buffer(Seed);
        {private, #{kind := Kind, priv := Priv}} when Kind =/= ml_dsa_44, Kind =/= ml_dsa_65, Kind =/= ml_dsa_87,
                                                      Kind =/= ml_kem_512, Kind =/= ml_kem_768, Kind =/= ml_kem_1024 ->
            buoy_crypto:buffer(Priv);
        _ -> buoy_crypto:fail_code(<<"ERR_CRYPTO_OPERATION_FAILED">>, <<"Failed to get raw seed">>)
    end.

%% keyDetail(target)
key_detail(This, Args) ->
    Target = buoy_node:arg(1, Args),
    case key_data(This) of
        {secret, Bytes} -> set(Target, [{<<"length">>, byte_size(Bytes) * 8}]);
        {_, K} -> set(Target, asymmetric_detail(K))
    end.

asymmetric_detail(#{kind := Kind, n := N, e := E} = K) when Kind =:= rsa; Kind =:= rsa_pss ->
    Base = [{<<"modulusLength">>, buoy_crypto:bit_length(N)}, {<<"publicExponent">>, buoy_crypto:array_buffer(int(E))}],
    case buoy_crypto_pkey:pss_params(K) of
        #{md := Md, mgf1 := Mgf1, salt := Salt} ->
            Base ++ [{<<"hashAlgorithm">>, Md}, {<<"mgf1HashAlgorithm">>, Mgf1}, {<<"saltLength">>, Salt}];
        undefined -> Base
    end;
asymmetric_detail(#{kind := dsa, p := P, q := Q}) ->
    [{<<"modulusLength">>, buoy_crypto:bit_length(P)}, {<<"divisorLength">>, buoy_crypto:bit_length(Q)}];
asymmetric_detail(#{kind := ec, curve := Curve}) ->
    [{<<"namedCurve">>, buoy_crypto_pkey:curve_name(Curve)}];
asymmetric_detail(#{kind := dh}) ->
    [];
asymmetric_detail(_) ->
    buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_KEYTYPE">>).

%% equals(other): EVP_PKEY_eq compares the public parts.
equals(This, Args) ->
    case {key_data(This), key_data(buoy_node:arg(1, Args))} of
        {{secret, A}, {secret, B}} -> buoy_crypto:equal_bytes(A, B);
        {{_, A}, {_, B}} -> same_public(buoy_crypto_pkey:public(A), buoy_crypto_pkey:public(B))
    end.

same_public(#{kind := ec, curve := C, pub := A}, #{kind := ec, curve := C, pub := B}) -> same_point(C, A, B);
same_public(A, B) -> maps:without([explicit, x942], A) =:= maps:without([explicit, x942], B).
