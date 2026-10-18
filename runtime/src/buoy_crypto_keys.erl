%% KeyObjectHandle and NativeKeyObject of internalBinding('crypto')
%% (src/crypto/crypto_keys.cc): the native side of KeyObject and CryptoKey.
%% A handle holds its key as an Erlang term: {secret, Bytes} or
%% {public | private, Key}, where Key is a map that names the type of the
%% key and holds its numbers.
-module(buoy_crypto_keys).

-export([members/0, secret_bytes/1, key_data/1, handle/1]).

-define(SECRET, 0).
-define(PUBLIC, 1).
-define(PRIVATE, 2).

-spec members() -> [{binary(), term()}].
members() ->
    [{<<"KeyObjectHandle">>, handle_class()},
     {<<"createNativeKeyObjectClass">>, buoy_node:fn(<<"createNativeKeyObjectClass">>, 1, fun native_class/2)}].

%% The class is one per realm, so a handle that the binding makes is an
%% instance of the class that internal/crypto/keys reads.
handle_class() ->
    case erlang:get({?MODULE, handle_class}) of
        undefined ->
            Class = buoy_crypto:class(<<"KeyObjectHandle">>, fun(_, _) -> undefined end, [
                {<<"init">>, 0, fun init/2},
                {<<"getSymmetricKeySize">>, 0, fun(This, _) -> byte_size(secret(key_data(This))) end},
                {<<"export">>, 0, fun export/2},
                {<<"exportJwk">>, 0, fun export_jwk/2},
                {<<"initJwk">>, 0, fun init_jwk/2},
                {<<"keyDetail">>, 0, fun key_detail/2},
                {<<"equals">>, 0, fun equals/2}]),
            erlang:put({?MODULE, handle_class}, Class),
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

%% The bytes of a secret key: a KeyObjectHandle, or the bytes of a buffer
%% (ByteSource::FromSecretKeyBytes).
-spec secret_bytes(term()) -> binary().
secret_bytes(V) ->
    case buoy_heap:is_object(V) andalso buoy_heap:private_find(V, {'#', buoy_crypto, key}) of
        {ok, Data} -> secret(Data);
        _ -> buoy_crypto:bytes(V)
    end.

secret({secret, Bytes}) -> Bytes.

%% createNativeKeyObjectClass(callback): the callback gets NativeKeyObject
%% and returns [KeyObject, SecretKeyObject, PublicKeyObject,
%% PrivateKeyObject], which the binding keeps to make key objects.
native_class(_, Args) ->
    Native = buoy_node:constructor(<<"NativeKeyObject">>, 1, fun(This, A) ->
        buoy_crypto:put_state(This, {key, key_data(buoy_node:arg(1, A))}),
        undefined
    end),
    Classes = buoy_heap:call(buoy_node:arg(1, Args), undefined, [Native]),
    erlang:put({?MODULE, key_object_classes}, Classes),
    Classes.

%% init(kKeyTypeSecret, buffer)
init(This, Args) ->
    case buoy_node:arg(1, Args) of
        ?SECRET -> buoy_crypto:put_state(This, {key, {secret, buoy_crypto:bytes(buoy_node:arg(2, Args))}});
        _ -> buoy_node:call(buoy_node:not_implemented(<<"crypto">>, <<"KeyObjectHandle.init">>), This, Args)
    end,
    undefined.

export(This, Args) ->
    case key_data(This) of
        {secret, Bytes} -> buoy_crypto:buffer(Bytes);
        _ -> buoy_node:call(buoy_node:not_implemented(<<"crypto">>, <<"KeyObjectHandle.export">>), This, Args)
    end.

%% exportJwk(target, handleRsaPss)
export_jwk(This, Args) ->
    Target = buoy_node:arg(1, Args),
    case key_data(This) of
        {secret, Bytes} ->
            buoy_heap:set(Target, <<"kty">>, <<"oct">>),
            buoy_heap:set(Target, <<"k">>, buoy_node_encoding:decode(base64url, Bytes)),
            Target;
        _ -> buoy_node:call(buoy_node:not_implemented(<<"crypto">>, <<"KeyObjectHandle.exportJwk">>), This, Args)
    end.

%% initJwk(jwk, namedCurve): the type of the key that it read.
init_jwk(This, Args) ->
    Jwk = buoy_node:arg(1, Args),
    case buoy_heap:get(Jwk, <<"kty">>) of
        <<"oct">> ->
            K = buoy_heap:get(Jwk, <<"k">>),
            buoy_crypto:is_string(K) orelse
                buoy_node:throw_code('TypeError', <<"ERR_CRYPTO_INVALID_JWK">>, <<"Invalid JWK secret key format">>),
            buoy_crypto:put_state(This, {key, {secret, buoy_node_encoding:encode(base64url, K)}}),
            ?SECRET;
        _ -> buoy_node:call(buoy_node:not_implemented(<<"crypto">>, <<"KeyObjectHandle.initJwk">>), This, Args)
    end.

%% keyDetail(target)
key_detail(This, Args) ->
    Target = buoy_node:arg(1, Args),
    case key_data(This) of
        {secret, Bytes} ->
            buoy_heap:set(Target, <<"length">>, byte_size(Bytes) * 8),
            Target;
        _ -> buoy_node:call(buoy_node:not_implemented(<<"crypto">>, <<"KeyObjectHandle.keyDetail">>), This, Args)
    end.

equals(This, Args) ->
    case {key_data(This), key_data(buoy_node:arg(1, Args))} of
        {{secret, A}, {secret, B}} -> buoy_crypto:equal_bytes(A, B);
        {A, B} -> A =:= B
    end.
