%% Argon2Job of internalBinding('crypto') (src/crypto/crypto_argon2.cc):
%% Argon2d, Argon2i, and Argon2id of RFC 9106, version 0x13. OTP's crypto
%% has no Argon2, so the NIF of crates/buoy-native derives it with the
%% rust-argon2 crate, as Bun does, on a dirty CPU scheduler.
-module(buoy_crypto_argon2).

-export([members/0]).

-spec members() -> [{binary(), term()}].
members() ->
    [{<<"Argon2Job">>, buoy_crypto_job:class(<<"Argon2Job">>, fun argon2_job/1)}].

%% new Argon2Job(mode, message, nonce, parallelism, tagLength, memory,
%% passes, secret, associatedData, type)
argon2_job([Message, Nonce, Lanes, TagLen, Memory, Passes, Secret, AD, Type | _]) ->
    [P, S, K, X] = [optional(V) || V <- [Message, Nonce, Secret, AD]],
    valid(Lanes, TagLen, Memory, Passes, S) orelse buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_ARGON2_PARAMS">>),
    {fun() -> derive(Type, P, S, K, X, Lanes, TagLen, Memory, Passes) end, fun buoy_crypto:array_buffer/1}.

optional(undefined) -> <<>>;
optional(V) -> buoy_crypto:bytes(V).

%% The parameters that OpenSSL's Argon2 accepts.
valid(Lanes, TagLen, Memory, Passes, Salt) ->
    Lanes >= 1 andalso Lanes =< 16#FFFFFF andalso (TagLen =:= 0 orelse TagLen >= 4)
        andalso Memory >= 8 * Lanes andalso Passes >= 1 andalso byte_size(Salt) >= 8.

%% Argon2Traits::DeriveBits: a tag of 0 bytes is empty, and memory that the
%% VM cannot hold fails as an allocation of OpenSSL fails, where the NIF
%% would abort.
derive(_, _, _, _, _, _, 0, _, _) ->
    {ok, <<>>};
derive(Type, P, S, K, X, Lanes, TagLen, Memory, Passes) ->
    case buoy_crypto:has_room(Memory * 1024 + TagLen) andalso
         buoy_native:argon2(Type, P, S, K, X, Lanes, TagLen, Memory, Passes) of
        Tag when is_binary(Tag) -> {ok, Tag};
        _ -> {error, {message, <<"Deriving bits failed">>}}
    end.
