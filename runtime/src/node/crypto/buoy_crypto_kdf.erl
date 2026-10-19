%% The key derivation jobs of internalBinding('crypto'): PBKDF2Job, HKDFJob,
%% and ScryptJob (src/crypto/crypto_pbkdf2.cc, crypto_hkdf.cc, and
%% crypto_scrypt.cc), on the HMAC of OTP's crypto and, for the ROMix of
%% scrypt, the NIF of crates/buoy-native.
-module(buoy_crypto_kdf).

-export([members/0, pbkdf2/5, pkcs12/6, hkdf/5]).

%% A function that only throws is a named fun, for dialyzer (node-builtins.md).
-dialyzer({no_return, [invalid_digest/1, invalid_scrypt_params/1]}).

-spec members() -> [{binary(), term()}].
members() ->
    [{<<"PBKDF2Job">>, buoy_crypto_job:class(<<"PBKDF2Job">>, fun pbkdf2_job/1)},
     {<<"HKDFJob">>, buoy_crypto_job:class(<<"HKDFJob">>, fun hkdf_job/1)},
     {<<"ScryptJob">>, buoy_crypto_job:class(<<"ScryptJob">>, fun scrypt_job/1)}].

digest_of(Name) ->
    case buoy_crypto_hash:digest(Name) of
        {ok, Md} -> Md;
        error -> invalid_digest(Name)
    end.

-spec invalid_digest(term()) -> no_return().
invalid_digest(Name) ->
    buoy_node:throw_code('TypeError', <<"ERR_CRYPTO_INVALID_DIGEST">>,
                         <<"Invalid digest: ", (buoy_crypto:string(Name))/binary>>).

%%% PBKDF2

%% new PBKDF2Job(mode, password, salt, iterations, keylen, digest)
pbkdf2_job([Password, Salt, Iterations, Length, Digest | _]) ->
    Md = digest_of(Digest),
    P = buoy_crypto:bytes(Password),
    S = buoy_crypto:bytes(Salt),
    {fun() -> {ok, pbkdf2(Md, P, S, Iterations, Length)} end, fun buoy_crypto:array_buffer/1}.

%% RFC 8018 PBKDF2 with HMAC over Md.
-spec pbkdf2(buoy_crypto_hash:md(), binary(), binary(), pos_integer(), non_neg_integer()) -> binary().
pbkdf2(_, _, _, _, 0) -> <<>>;
pbkdf2(#{name := Name}, Password, Salt, Iterations, Length)
  when Name =:= sha; Name =:= sha224; Name =:= sha256; Name =:= sha384; Name =:= sha512;
       Name =:= sha512_224; Name =:= sha512_256 ->
    crypto:pbkdf2_hmac(Name, Password, Salt, Iterations, Length);
pbkdf2(#{size := Size} = Md, Password, Salt, Iterations, Length) ->
    Blocks = (Length + Size - 1) div Size,
    <<Key:Length/binary, _/binary>> =
        iolist_to_binary([pbkdf2_block(Md, Password, Salt, Iterations, I) || I <- lists:seq(1, Blocks)]),
    Key.

pbkdf2_block(Md, Password, Salt, Iterations, I) ->
    U = buoy_crypto_hash:hmac(Md, Password, <<Salt/binary, I:32>>),
    pbkdf2_iterate(Md, Password, Iterations - 1, U, U).

pbkdf2_iterate(_, _, 0, _, T) -> T;
pbkdf2_iterate(Md, Password, N, U, T) ->
    Next = buoy_crypto_hash:hmac(Md, Password, U),
    pbkdf2_iterate(Md, Password, N - 1, Next, crypto:exor(T, Next)).

%%% PKCS #12

%% N bytes of the key derivation of PKCS #12 (RFC 7292, appendix B.2) for
%% the purpose Id (1 a key, 2 an IV, 3 a MAC key), from Password, which is
%% a BMPString with its two zero bytes, or empty for no password.
-spec pkcs12(buoy_crypto_hash:md(), 1..3, binary(), binary(), pos_integer(), non_neg_integer()) -> binary().
pkcs12(#{size := U} = Md, Id, Password, Salt, Iterations, N) ->
    V = pkcs12_block(Md),
    D = binary:copy(<<Id>>, V),
    I0 = <<(stretch(Salt, V))/binary, (stretch(Password, V))/binary>>,
    {Blocks, _} = lists:mapfoldl(fun(_, I) ->
        A = rehash(Md, buoy_crypto_hash:hash(Md, <<D/binary, I/binary>>), Iterations - 1),
        B = binary:part(binary:copy(A, (V + U - 1) div U), 0, V),
        {A, << <<(add_block(Block, B, V))/binary>> || <<Block:V/binary>> <= I >>}
    end, I0, lists:seq(1, (N + U - 1) div U)),
    binary:part(iolist_to_binary(Blocks), 0, N).

%% The input block size of the hash, v of appendix B.2.
pkcs12_block(#{name := Name}) when Name =:= sha384; Name =:= sha512; Name =:= sha512_224; Name =:= sha512_256 -> 128;
pkcs12_block(_) -> 64.

%% Bytes repeated to the next multiple of V bytes.
stretch(<<>>, _) -> <<>>;
stretch(Bytes, V) ->
    Length = V * ((byte_size(Bytes) + V - 1) div V),
    binary:part(binary:copy(Bytes, (Length + byte_size(Bytes) - 1) div byte_size(Bytes)), 0, Length).

rehash(_, A, 0) -> A;
rehash(Md, A, N) -> rehash(Md, buoy_crypto_hash:hash(Md, A), N - 1).

%% (Block + B + 1) mod 2^(8V).
add_block(Block, B, V) ->
    Bits = V * 8,
    <<X:Bits>> = Block,
    <<Y:Bits>> = B,
    <<(X + Y + 1):Bits>>.

%%% HKDF

%% new HKDFJob(mode, hash, key, salt, info, length)
hkdf_job([Digest, Key, Salt, Info, Length | _]) ->
    #{size := Size} = Md = digest_of(Digest),
    Length > 255 * Size andalso
        buoy_node:throw_code('RangeError', <<"ERR_CRYPTO_INVALID_KEYLEN">>, <<"Invalid key length">>),
    Secret = buoy_crypto_keys:secret_bytes(Key),
    S = buoy_crypto:bytes(Salt),
    I = buoy_crypto:bytes(Info),
    {fun() -> {ok, hkdf(Md, Secret, S, I, Length)} end, fun buoy_crypto:array_buffer/1}.

%% RFC 5869: an empty salt is a string of zeros as long as the digest.
-spec hkdf(buoy_crypto_hash:md(), binary(), binary(), binary(), non_neg_integer()) -> binary().
hkdf(_, _, _, _, 0) -> <<>>;
hkdf(#{size := Size} = Md, Key, Salt, Info, Length) ->
    Pseudo = buoy_crypto_hash:hmac(Md, salt(Salt, Size), Key),
    <<Out:Length/binary, _/binary>> = expand(Md, Pseudo, Info, Length, 1, <<>>, []),
    Out.

salt(<<>>, Size) -> <<0:(Size * 8)>>;
salt(Salt, _) -> Salt.

expand(_, _, _, Length, _, _, Acc) when Length =< 0 -> iolist_to_binary(lists:reverse(Acc));
expand(#{size := Size} = Md, Pseudo, Info, Length, I, Previous, Acc) ->
    T = buoy_crypto_hash:hmac(Md, Pseudo, <<Previous/binary, Info/binary, I>>),
    expand(Md, Pseudo, Info, Length - Size, I + 1, T, [T | Acc]).

%%% scrypt

%% new ScryptJob(mode, password, salt, N, r, p, maxmem, keylen)
scrypt_job([Password, Salt, N, R, P, MaxMem, Length | _]) ->
    check_scrypt(N, R, P, trunc(buoy_ref:to_number(MaxMem))),
    Pass = buoy_crypto:bytes(Password),
    S = buoy_crypto:bytes(Salt),
    {fun() -> scrypt(Pass, S, N, R, P, Length) end, fun buoy_crypto:array_buffer/1}.

%% The checks of EVP_PBE_scrypt_ex with no output, as ncrypto's
%% checkScryptParams calls it.
check_scrypt(N, R, P, MaxMem) ->
    (R =:= 0 orelse P =:= 0 orelse N < 2 orelse N band (N - 1) =/= 0) andalso invalid_scrypt_params(none),
    P > ((1 bsl 30) - 1) div R andalso invalid_scrypt_params(memory_limit_exceeded),
    16 * R =< 63 andalso N >= 1 bsl (16 * R) andalso invalid_scrypt_params(memory_limit_exceeded),
    Blen = P * 128 * R,
    Blen > 16#7FFFFFFF andalso invalid_scrypt_params(memory_limit_exceeded),
    Vlen = 32 * R * (N + 2) * 4,
    Limit = case MaxMem of
        0 -> 32 * 1024 * 1024;
        _ -> MaxMem
    end,
    Blen + Vlen > Limit andalso invalid_scrypt_params(memory_limit_exceeded),
    ok.

-spec invalid_scrypt_params(none | atom()) -> no_return().
invalid_scrypt_params(none) ->
    buoy_node:throw_code('RangeError', <<"ERR_CRYPTO_INVALID_SCRYPT_PARAMS">>, <<"Invalid scrypt params">>);
invalid_scrypt_params(Reason) ->
    E = buoy_crypto:error_value({openssl, Reason}),
    Message = buoy_ref_string:to_utf8(buoy_heap:get(E, <<"message">>)),
    buoy_node:throw_code('RangeError', <<"ERR_CRYPTO_INVALID_SCRYPT_PARAMS">>, <<"Invalid scrypt params: ", Message/binary>>).

%% RFC 7914 scrypt. Memory that the VM cannot hold fails as an allocation
%% of OpenSSL fails, where the NIF would abort.
scrypt(_, _, _, _, _, 0) -> {ok, <<>>};
scrypt(Password, Salt, N, R, P, Length) ->
    Sha256 = #{name => sha256, size => 32, xof => false},
    Size = 128 * R,
    case buoy_crypto:has_room(Size * (N + P)) of
        false -> {error, {message, <<"Deriving bits failed">>}};
        true ->
            B = pbkdf2(Sha256, Password, Salt, 1, P * Size),
            Mixed = << <<(buoy_native:scrypt_romix(Block, N))/binary>> || <<Block:Size/binary>> <= B >>,
            {ok, pbkdf2(Sha256, Password, Mixed, 1, Length)}
    end.
