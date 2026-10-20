%% The helpers that the parts of internalBinding('crypto') share, as
%% src/crypto/crypto_util.cc gives them to the parts of Node's binding: the
%% bytes of a buffer source, new buffers, the classes of the binding, and
%% the errors of OpenSSL.
-module(buoy_crypto).

-include("buoy_ref.hrl").

-export([bytes/1, data/2, is_buffer_source/1, array_buffer/1, buffer/1, encoding/2, encode/2, encode_output/3]).
-export([class/3, fn/3, method/3, state/2, put_state/2, state_key/1, guard/1]).
-export([fail/1, fail_code/1, fail_code/2, throw_error/1, throw_openssl/1, error_value/1, openssl_message/1]).
-export([to_uint32/1, to_int32/1, string/1, is_string/1, equal_bytes/2, bit_length/1, has_room/1]).
-export([mod_pow/3, rand_below/1, openssl_version/0, has_openssl/2, is_built/1]).

%% A function that only throws is a named fun, for dialyzer (node-builtins.md).
-dialyzer({no_return, [fail/1, fail_code/1, fail_code/2, throw_error/1, throw_openssl/1, illegal/0]}).

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
%% The bits of a non-negative integer, as BN_num_bits counts them. It reads
%% the bytes once: a bit-by-bit shift loop is quadratic in the size.
-spec bit_length(non_neg_integer()) -> non_neg_integer().
bit_length(0) -> 0;
bit_length(N) ->
    <<Top, _/binary>> = Bytes = binary:encode_unsigned(N),
    (byte_size(Bytes) - 1) * 8 + length(integer_to_list(Top, 2)).

%% B to the power E modulo M, on OpenSSL's BN_mod_exp.
-spec mod_pow(non_neg_integer(), non_neg_integer(), pos_integer()) -> non_neg_integer().
mod_pow(B, E, M) -> binary:decode_unsigned(crypto:mod_pow(B, E, M)).

%% A random integer in [0, N), from 64 more random bits than N has, so the
%% bias of the remainder is below 2^-64.
-spec rand_below(pos_integer()) -> non_neg_integer().
rand_below(N) when N =< 1 -> 0;
rand_below(N) -> binary:decode_unsigned(crypto:strong_rand_bytes((bit_length(N) + 7) div 8 + 8)) rem N.

%% Whether the VM can hold Bytes more under BUOY_MAX_MEMORY. A NIF whose
%% allocation fails aborts the VM, so a job asks first.
-spec has_room(non_neg_integer()) -> boolean().
has_room(Bytes) -> Bytes < buoy_guard:limit(os:getenv("BUOY_MAX_MEMORY", "")) - erlang:memory(total).

%%% The linked OpenSSL

%% The version of the OpenSSL that OTP's crypto links, as <<"3.0.13">>,
%% which process.versions.openssl names; error when crypto cannot load it.
-spec openssl_version() -> {ok, binary()} | error.
openssl_version() ->
    try crypto:info_lib() of
        [{<<"OpenSSL">>, _, Text} | _] -> {ok, hd(tl(binary:split(Text, <<" ">>, [global])))};
        _ -> error
    catch
        error:_ -> error
    end.

%% Whether the linked OpenSSL is Major.Minor or later, as hasOpenSSL of
%% Node's test/common/crypto.js asks. Node offers only the algorithms of
%% the OpenSSL that it links, and its tests expect that, so the binding
%% hides each algorithm that this OpenSSL lacks, even one that Buoy
%% implements itself.
-spec has_openssl(non_neg_integer(), non_neg_integer()) -> boolean().
has_openssl(Major, Minor) ->
    case openssl_version() of
        {ok, Text} ->
            case re:run(Text, <<"^(\\d+)\\.(\\d+)">>, [{capture, all_but_first, binary}]) of
                {match, [M, N]} -> {binary_to_integer(M), binary_to_integer(N)} >= {Major, Minor};
                nomatch -> false
            end;
        error -> false
    end.

%% Whether Node builds the member Name of internalBinding('crypto'), or the
%% method Class.Method of one of its classes, with the linked OpenSSL:
%% Argon2 needs OpenSSL 3.2 (node_crypto.cc), and ML-DSA, ML-KEM, and
%% SLH-DSA need 3.5 (OPENSSL_WITH_PQC in crypto_keys.cc). Node's lib reads
%% each absent member as an unsupported algorithm.
-spec is_built(binary()) -> boolean().
is_built(<<"Argon2Job">>) -> has_openssl(3, 2);
is_built(<<"kTypeArgon2", _/binary>>) -> has_openssl(3, 2);
is_built(<<"EVP_PKEY_ML_", _/binary>>) -> has_openssl(3, 5);
is_built(<<"EVP_PKEY_SLH_", _/binary>>) -> has_openssl(3, 5);
is_built(<<"KeyObjectHandle.", Method/binary>>) ->
    has_openssl(3, 5) orelse not lists:member(Method, [<<"initPqcRaw">>, <<"rawPublicKey">>, <<"rawSeed">>]);
is_built(_) -> true.

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
    Class = buoy_node:constructor(Name, 0, fun(This, Args) -> guard(fun() -> Init(This, Args) end), undefined end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    [method(Proto, Method, Length, Fun) || {Method, Length, Fun} <- Methods],
    Class.

method(Proto, Name, Length, Fun) ->
    buoy_heap:define(Proto, Name, #{value => fn(Name, Length, Fun), writable => true,
                                    enumerable => true, configurable => true}).

%% A function of the binding, whose failures (fail/1) throw.
-spec fn(binary(), non_neg_integer(), fun((term(), list()) -> term())) -> term().
fn(Name, Length, Fun) ->
    buoy_node:fn(Name, Length, fun(This, Args) -> guard(fun() -> Fun(This, Args) end) end).

%% The result of Fun, with a failure of fail/1 thrown as its JavaScript error.
-spec guard(fun(() -> T)) -> T.
guard(Fun) ->
    try Fun()
    catch
        error:{crypto_failure, Reason} -> erlang:error({'$throw', error_value(Reason)})
    end.

-spec method(term(), binary(), fun((term(), list()) -> term())) -> ok.
method(Proto, Name, Fun) ->
    method(Proto, Name, 0, Fun),
    ok.

%% The native state Tag of This, or an Illegal invocation.
-spec state(term(), atom()) -> term().
state(This, Tag) ->
    case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, state_key(Tag)) of
        {ok, S} -> S;
        _ -> illegal()
    end.

-spec put_state(term(), {atom(), term()}) -> ok.
put_state(This, {Tag, S}) ->
    buoy_heap:private_put(This, state_key(Tag), S),
    ok.

%% The private name that holds the native state Tag of an object.
-spec state_key(atom()) -> {'#', ?MODULE, binary()}.
state_key(Tag) -> {'#', ?MODULE, atom_to_binary(Tag)}.

-spec illegal() -> no_return().
illegal() -> buoy_ref:type_error(<<"Illegal invocation">>).

%%% Errors

%% Fails with Reason (see error_value/1). It works in any process: guard/1
%% throws it in the realm, and a job reports it as its error.
-spec fail(term()) -> no_return().
fail(Reason) -> erlang:error({crypto_failure, Reason}).

%% Fails with the error of Node's THROW_<Code> (src/node_errors.h), with its
%% default message or Message.
-spec fail_code(binary()) -> no_return().
fail_code(Code) ->
    {_, Message} = node_error(Code),
    fail_code(Code, Message).

-spec fail_code(binary(), binary()) -> no_return().
fail_code(Code, Message) ->
    {Class, _} = node_error(Code),
    fail({code, Class, Code, Message}).

node_error(<<"ERR_CRYPTO_INVALID_AUTH_TAG">>) -> {'TypeError', <<"Invalid authentication tag">>};
node_error(<<"ERR_CRYPTO_INVALID_COUNTER">>) -> {'TypeError', <<"Invalid counter">>};
node_error(<<"ERR_CRYPTO_INVALID_CURVE">>) -> {'TypeError', <<"Invalid EC curve name">>};
node_error(<<"ERR_CRYPTO_INVALID_DIGEST">>) -> {'TypeError', <<"Invalid digest">>};
node_error(<<"ERR_CRYPTO_INVALID_IV">>) -> {'TypeError', <<"Invalid initialization vector">>};
node_error(<<"ERR_CRYPTO_INVALID_JWK">>) -> {'TypeError', <<"Invalid JWK format">>};
node_error(<<"ERR_CRYPTO_INVALID_KEYLEN">>) -> {'RangeError', <<"Invalid key length">>};
node_error(<<"ERR_CRYPTO_INVALID_KEYPAIR">>) -> {'RangeError', <<"Invalid key pair">>};
node_error(<<"ERR_CRYPTO_INVALID_KEYTYPE">>) -> {'RangeError', <<"Invalid key type">>};
node_error(<<"ERR_CRYPTO_INVALID_MESSAGELEN">>) -> {'RangeError', <<"Invalid message length">>};
node_error(<<"ERR_CRYPTO_INVALID_STATE">>) -> {'Error', <<"Invalid state">>};
node_error(<<"ERR_CRYPTO_INVALID_TAG_LENGTH">>) -> {'RangeError', <<"Invalid taglength">>};
node_error(<<"ERR_CRYPTO_JWK_UNSUPPORTED_CURVE">>) -> {'Error', <<"Unsupported JWK EC curve">>};
node_error(<<"ERR_CRYPTO_JWK_UNSUPPORTED_KEY_TYPE">>) -> {'Error', <<"Unsupported JWK Key Type.">>};
node_error(<<"ERR_CRYPTO_OPERATION_FAILED">>) -> {'Error', <<"Operation failed">>};
node_error(<<"ERR_CRYPTO_UNKNOWN_CIPHER">>) -> {'Error', <<"Unknown cipher">>};
node_error(<<"ERR_CRYPTO_UNKNOWN_DH_GROUP">>) -> {'Error', <<"Unknown DH group">>};
node_error(<<"ERR_CRYPTO_UNSUPPORTED_OPERATION">>) -> {'Error', <<"Unsupported crypto operation">>};
node_error(<<"ERR_CRYPTO_JOB_INIT_FAILED">>) -> {'Error', <<"Failed to initialize crypto job config">>};
node_error(<<"ERR_CRYPTO_INVALID_ARGON2_PARAMS">>) -> {'TypeError', <<"Invalid Argon2 params">>};
node_error(<<"ERR_CRYPTO_INVALID_SCRYPT_PARAMS">>) -> {'RangeError', <<"Invalid scrypt params">>};
node_error(<<"ERR_MISSING_PASSPHRASE">>) -> {'TypeError', <<"Passphrase required for encrypted key">>};
node_error(<<"ERR_OUT_OF_RANGE">>) -> {'RangeError', <<"Out of range">>};
node_error(<<"ERR_INVALID_ARG_VALUE">>) -> {'TypeError', <<"Invalid argument value">>};
node_error(<<"ERR_OSSL_EVP_INVALID_DIGEST">>) -> {'Error', <<"Invalid digest used">>}.

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
    {Lib, _, Text} = reason(Reason),
    {_, LibName, Prefix} = library(Lib),
    E = error_value({message, openssl_message(Reason)}),
    Upper = string:uppercase(binary:replace(Text, <<" ">>, <<"_">>, [global])),
    Code = <<"ERR_OSSL_", Prefix/binary, Upper/binary>>,
    [buoy_heap:set(E, K, V) || {K, V} <- [{<<"library">>, LibName}, {<<"reason">>, Text}, {<<"code">>, Code}]],
    E;
error_value({code, Class, Code, Message}) ->
    E = buoy_heap:error_object(Class, Message, buoy_ref_string:concat([atom_to_binary(Class), <<": ">>, Message])),
    buoy_heap:define(E, <<"code">>, #{value => Code, writable => true, enumerable => true, configurable => true}),
    E.

%% The text of the OpenSSL error Reason, as ERR_error_string_n writes it.
-spec openssl_message(atom()) -> binary().
openssl_message(Reason) ->
    {Lib, Number, Text} = reason(Reason),
    {LibNumber, LibName, _} = library(Lib),
    iolist_to_binary(io_lib:format("error:~8.16.0B:~s::~s", [(LibNumber bsl 23) bor Number, LibName, Text])).

%% The OpenSSL 3 errors that the binding raises: the library, and the number
%% and the text of the reason. A number with 16#80000 is a common reason.
reason(bad_decrypt) -> {prov, 100, <<"bad decrypt">>};
reason(wrong_final_block_length) -> {prov, 107, <<"wrong final block length">>};
reason(invalid_key_length) -> {prov, 105, <<"invalid key length">>};
reason(invalid_iv_length) -> {prov, 109, <<"invalid iv length">>};
reason(illegal_padding) -> {prov, 165, <<"illegal or unsupported padding mode">>};
reason(oaep_decoding_error) -> {rsa, 121, <<"oaep decoding error">>};
reason(digest_too_big) -> {rsa, 112, <<"digest too big for rsa key">>};
reason(data_too_large_for_key_size) -> {rsa, 110, <<"data too large for key size">>};
reason(key_size_too_small) -> {prov, 171, <<"key size too small">>};
reason(pub_exponent_out_of_range) -> {rsa, 178, <<"pub exponent out of range">>};
reason(provider_keymgmt_failure) -> {evp, 233, <<"provider keymgmt failure">>};
reason(unsupported) -> {evp, 16#8010C, <<"unsupported">>};
reason(decode_error) -> {evp, 114, <<"decode error">>};
reason(xts_duplicated_keys) -> {prov, 149, <<"xts duplicated keys">>};
reason(pem_no_start_line) -> {pem, 108, <<"no start line">>};
reason(pem_asn1_lib) -> {pem, 16#8000D, <<"ASN1 lib">>};
reason(pem_unsupported_cipher) -> {pem, 113, <<"unsupported cipher">>};
reason(decoder_unsupported) -> {decoder, 16#8010C, <<"unsupported">>};
reason(interrupted_or_cancelled) -> {crypto, 16#80109, <<"interrupted or cancelled">>};
reason(not_xof_or_invalid_length) -> {evp, 178, <<"not XOF or invalid length">>};
reason(memory_limit_exceeded) -> {evp, 172, <<"memory limit exceeded">>};
reason(operation_not_supported_for_this_keytype) -> {evp, 150, <<"operation not supported for this keytype">>};
reason(prov_operation_not_supported_for_this_keytype) -> {prov, 178, <<"operation not supported for this keytype">>};
reason(digest_not_allowed) -> {prov, 174, <<"digest not allowed">>};
reason(pss_saltlen_too_small) -> {prov, 172, <<"pss saltlen too small">>};
reason(different_parameters) -> {evp, 153, <<"different parameters">>};
reason(mismatching_domain_parameters) -> {prov, 203, <<"mismatching domain parameters">>};
reason(invalid_digest) -> {prov, 122, <<"invalid digest">>};
reason(bad_generator) -> {dh, 101, <<"bad generator">>};
reason(modulus_too_small) -> {dh, 126, <<"modulus too small">>};
reason(bits_too_small) -> {bn, 118, <<"bits too small">>};
reason(bignum_too_long) -> {bn, 114, <<"bignum too long">>};
reason(missing_oid) -> {prov, 209, <<"missing OID">>};
reason(tag_not_set) -> {prov, 119, <<"tag not set">>};
reason(failed_during_derivation) -> {prov, 164, <<"failed during derivation">>};
reason(invalid_public_key) -> {ec, 107, <<"invalid public key">>};
reason(point_is_not_on_curve) -> {ec, 107, <<"point is not on curve">>}.

%% The number, the name, and the code prefix of each library (err.h and
%% OSSL_ERROR_CODES_MAP of crypto_util.cc).
library(bn) -> {3, <<"bignum routines">>, <<"BN_">>};
library(rsa) -> {4, <<"rsa routines">>, <<"RSA_">>};
library(dh) -> {5, <<"Diffie-Hellman routines">>, <<"DH_">>};
library(evp) -> {6, <<"digital envelope routines">>, <<"EVP_">>};
library(pem) -> {9, <<"PEM routines">>, <<"PEM_">>};
library(crypto) -> {15, <<"common libcrypto routines">>, <<"CRYPTO_">>};
library(ec) -> {16, <<"elliptic curve routines">>, <<"EC_">>};
library(prov) -> {57, <<"Provider routines">>, <<>>};
library(decoder) -> {60, <<"DECODER routines">>, <<>>}.
