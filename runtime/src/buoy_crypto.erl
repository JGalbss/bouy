%% The helpers that the parts of internalBinding('crypto') share, as
%% src/crypto/crypto_util.cc gives them to the parts of Node's binding: the
%% bytes of a buffer source, new buffers, the classes of the binding, and
%% the errors of OpenSSL.
-module(buoy_crypto).

-include("buoy_ref.hrl").

%% The numbers of the libraries of OpenSSL's errors (err.h), and the reason
%% ERR_R_UNSUPPORTED with its flag.
-define(RSA, 4).
-define(DH, 5).
-define(EVP, 6).
-define(PEM, 9).
-define(ASN1, 13).
-define(EC, 16).
-define(PROV, 57).
-define(DECODER, 60).
-define(R_UNSUPPORTED, 16#8010C).

-export([bytes/1, data/2, is_buffer_source/1, array_buffer/1, buffer/1, encoding/2, encode/2, encode_output/3]).
-export([class/3, method/3, state/2, put_state/2]).
-export([throw_error/1, throw_openssl/1, error_value/1, openssl_reason/1]).
-export([to_uint32/1, to_int32/1, string/1, is_string/1, equal_bytes/2]).

%% A function that only throws is a named fun, for dialyzer (node-builtins.md).
-dialyzer({no_return, [throw_error/1, throw_openssl/1, illegal/0]}).

%%% Bytes

%% The bytes of an ArrayBuffer, a SharedArrayBuffer, or a view of one.
-spec bytes(term()) -> binary().
bytes(V) -> buoy_node_encoding:view_bytes(V).

-spec is_buffer_source(term()) -> boolean().
is_buffer_source(V) ->
    buoy_heap:is_object(V) andalso
        lists:member(buoy_heap:class_of(V), [typed_array, data_view, array_buffer, shared_array_buffer]).

%% The bytes of the argument of Decode (crypto_util.h): a string in the
%% encoding Encoding (utf8 when it names none), or a view.
-spec data(term(), term()) -> binary().
data(V, Encoding) when ?IS_STRING(V) ->
    buoy_node_encoding:encode(encoding(Encoding, utf8), V);
data(V, _) ->
    bytes(V).

-spec array_buffer(binary()) -> term().
array_buffer(Bytes) ->
    Buffer = buoy_ref_buffer:allocate(byte_size(Bytes)),
    buoy_ref_buffer:write(Buffer, 0, Bytes),
    Buffer.

-spec buffer(binary()) -> term().
buffer(Bytes) -> buoy_node_encoding:new_buffer(Bytes).

%% The encoding that the argument Value names, as ParseEncoding reads it,
%% or Default.
-spec encoding(term(), buoy_node_encoding:encoding()) -> buoy_node_encoding:encoding().
encoding(Value, Default) ->
    case buoy_node_encoding:parse(Value) of
        {ok, E} -> E;
        error -> Default
    end.

%% StringBytes::Encode: a Buffer for the encoding buffer, else a string.
-spec encode(binary(), buoy_node_encoding:encoding()) -> term().
encode(Bytes, buffer) -> buffer(Bytes);
encode(Bytes, Enc) -> buoy_node_encoding:decode(Enc, Bytes).

%% Bytes in the encoding that the argument Encoding names, or Default.
-spec encode_output(binary(), term(), buoy_node_encoding:encoding()) -> term().
encode_output(Bytes, Encoding, Default) -> encode(Bytes, encoding(Encoding, Default)).

%% Whether A and B are the same bytes, in a time that does not depend on
%% where they differ (CRYPTO_memcmp).
-spec equal_bytes(binary(), binary()) -> boolean().
equal_bytes(<<>>, <<>>) -> true;
equal_bytes(A, B) when byte_size(A) =:= byte_size(B) -> crypto:hash_equals(A, B);
equal_bytes(_, _) -> false.

-spec string(term()) -> binary().
string(V) -> buoy_ref_string:to_utf8(buoy_ref:to_string(V)).

-spec is_string(term()) -> boolean().
is_string(V) -> ?IS_STRING(V).

-spec to_uint32(term()) -> non_neg_integer().
to_uint32(V) -> buoy_ref_number:to_uint32(buoy_ref:to_number(V)).

-spec to_int32(term()) -> integer().
to_int32(V) -> buoy_ref_number:to_int32(buoy_ref:to_number(V)).

%%% Classes

%% A class of the binding: Init(This, Args) runs for `new`, and each method
%% of Methods is {Name, Length, fun(This, Args)}.
-spec class(binary(), fun((term(), list()) -> term()), [{binary(), non_neg_integer(), fun((term(), list()) -> term())}]) -> term().
class(Name, Init, Methods) ->
    Class = buoy_node:constructor(Name, 0, fun(This, Args) -> Init(This, Args), undefined end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    [method(Proto, Method, Length, Fun) || {Method, Length, Fun} <- Methods],
    Class.

method(Proto, Name, Length, Fun) ->
    buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, Length, Fun), writable => true,
                                    enumerable => true, configurable => true}).

-spec method(term(), binary(), fun((term(), list()) -> term())) -> ok.
method(Proto, Name, Fun) ->
    method(Proto, Name, 0, Fun),
    ok.

%% The native state Tag of This, or an Illegal invocation.
-spec state(term(), term()) -> term().
state(This, Tag) ->
    case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, {'#', ?MODULE, Tag}) of
        {ok, S} -> S;
        _ -> illegal()
    end.

-spec put_state(term(), {term(), term()}) -> ok.
put_state(This, {Tag, S}) ->
    buoy_heap:private_put(This, {'#', ?MODULE, Tag}, S),
    ok.

-spec illegal() -> no_return().
illegal() -> buoy_ref:type_error(<<"Illegal invocation">>).

%%% Errors

%% Throws Error(Message), as ThrowCryptoError does with no OpenSSL error.
-spec throw_error(binary()) -> no_return().
throw_error(Message) -> erlang:error({'$throw', error_value({message, Message})}).

%% Throws the OpenSSL error Reason, as ThrowCryptoError does with one.
-spec throw_openssl(atom()) -> no_return().
throw_openssl(Reason) -> erlang:error({'$throw', error_value({openssl, Reason})}).

%% The JavaScript error of a failure of a part of the binding:
%%   {message, Text}: Error(Text);
%%   {openssl, Reason}: the error that Decorate gives the OpenSSL error Reason;
%%   {code, Class, Code, Text}: the error of internal/errors with the code Code.
-spec error_value(term()) -> term().
error_value({message, Message}) ->
    buoy_heap:error_object('Error', Message, <<"Error: ", Message/binary>>);
error_value({openssl, Reason}) ->
    {Lib, Number, Text} = openssl_reason(Reason),
    Message = iolist_to_binary(io_lib:format("error:~8.16.0B:~s::~s", [((Lib bsl 23) bor Number), library(Lib), Text])),
    E = error_value({message, Message}),
    Upper = string:uppercase(binary:replace(Text, <<" ">>, <<"_">>, [global])),
    Code = <<"ERR_OSSL_", (prefix(Lib))/binary, Upper/binary>>,
    [buoy_heap:set(E, K, V) || {K, V} <- [{<<"library">>, library(Lib)}, {<<"reason">>, Text}, {<<"code">>, Code}]],
    E;
error_value({code, Class, Code, Message}) ->
    E = buoy_heap:error_object(Class, Message, buoy_ref_string:concat([atom_to_binary(Class), <<": ">>, Message])),
    buoy_heap:define(E, <<"code">>, #{value => Code, writable => true, enumerable => true, configurable => true}),
    E.

%% The OpenSSL 3 errors that the binding raises: the library, and the number
%% and the text of the reason.
-spec openssl_reason(atom()) -> {pos_integer(), non_neg_integer(), binary()}.
openssl_reason(bad_decrypt) -> {?PROV, 100, <<"bad decrypt">>};
openssl_reason(wrong_final_block_length) -> {?PROV, 107, <<"wrong final block length">>};
openssl_reason(invalid_key_length) -> {?PROV, 105, <<"invalid key length">>};
openssl_reason(invalid_iv_length) -> {?PROV, 109, <<"invalid iv length">>};
openssl_reason(unsupported) -> {?EVP, ?R_UNSUPPORTED, <<"unsupported">>};
openssl_reason(decoder_unsupported) -> {?DECODER, ?R_UNSUPPORTED, <<"unsupported">>};
openssl_reason(not_xof_or_invalid_length) -> {?EVP, 178, <<"not XOF or invalid length">>};
openssl_reason(memory_limit_exceeded) -> {?EVP, 172, <<"memory limit exceeded">>}.

library(?EVP) -> <<"digital envelope routines">>;
library(?PROV) -> <<"Provider routines">>;
library(?DECODER) -> <<"DECODER routines">>;
library(?RSA) -> <<"rsa routines">>;
library(?PEM) -> <<"PEM routines">>;
library(?ASN1) -> <<"asn1 encoding routines">>;
library(?EC) -> <<"elliptic curve routines">>;
library(?DH) -> <<"Diffie-Hellman routines">>.

%% The prefix of the code of an error of the library Lib (OSSL_ERROR_CODES_MAP).
prefix(?EVP) -> <<"EVP_">>;
prefix(?RSA) -> <<"RSA_">>;
prefix(?PEM) -> <<"PEM_">>;
prefix(?ASN1) -> <<"ASN1_">>;
prefix(?EC) -> <<"EC_">>;
prefix(?DH) -> <<"DH_">>;
prefix(_) -> <<>>.
