%% The key derivation jobs of internalBinding('crypto'): PBKDF2Job, HKDFJob,
%% and ScryptJob (src/crypto/crypto_pbkdf2.cc, crypto_hkdf.cc, and
%% crypto_scrypt.cc), on the HMAC of OTP's crypto.
-module(buoy_crypto_kdf).

-export([members/0, pbkdf2/5, hkdf/5, scrypt/6]).

%% A function that only throws is a named fun, for dialyzer (node-builtins.md).
-dialyzer({no_return, [invalid_digest/1, invalid_scrypt_params/1]}).

-define(MASK, 16#FFFFFFFF).

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
    {fun() -> {ok, scrypt(Pass, S, N, R, P, Length)} end, fun buoy_crypto:array_buffer/1}.

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

%% RFC 7914 scrypt.
-spec scrypt(binary(), binary(), pos_integer(), pos_integer(), pos_integer(), non_neg_integer()) -> binary().
scrypt(_, _, _, _, _, 0) -> <<>>;
scrypt(Password, Salt, N, R, P, Length) ->
    Sha256 = #{name => sha256, size => 32, xof => false},
    Size = 128 * R,
    B = pbkdf2(Sha256, Password, Salt, 1, P * Size),
    Mixed = << <<(romix(Block, N, R))/binary>> || <<Block:Size/binary>> <= B >>,
    pbkdf2(Sha256, Password, Mixed, 1, Length).

romix(Block, N, R) ->
    X0 = words(Block),
    {X, V} = fill(X0, N, R, []),
    mix(X, N, R, V, N).

%% V holds the N states in order, so the step j reads element j + 1.
fill(X, 0, _, Acc) -> {X, list_to_tuple(lists:reverse(Acc))};
fill(X, N, R, Acc) -> fill(block_mix(X, R), N - 1, R, [X | Acc]).

mix(X, 0, _, _, _) -> << <<W:32/little>> || W <- tuple_to_list(X) >>;
mix(X, I, R, V, N) ->
    J = integerify(X, R) band (N - 1),
    mix(block_mix(xor_words(X, element(J + 1, V)), R), I - 1, R, V, N).

words(Bin) -> list_to_tuple([W || <<W:32/little>> <= Bin]).

xor_words(A, B) -> list_to_tuple(lists:zipwith(fun(X, Y) -> X bxor Y end, tuple_to_list(A), tuple_to_list(B))).

%% The first word of the last 64-byte block, as the low bits of Integerify.
integerify(X, R) -> element((2 * R - 1) * 16 + 1, X).

%% BlockMix with Salsa20/8 over the 2R blocks of 16 words of X.
block_mix(X, R) ->
    Blocks = blocks(tuple_to_list(X), []),
    Last = lists:last(Blocks),
    {Ys, _} = lists:mapfoldl(fun(Bi, Prev) ->
        Y = salsa(lists:zipwith(fun(A, B) -> A bxor B end, Prev, Bi)),
        {Y, Y}
    end, Last, Blocks),
    Even = [Y || {I, Y} <- lists:zip(lists:seq(0, 2 * R - 1), Ys), I rem 2 =:= 0],
    Odd = [Y || {I, Y} <- lists:zip(lists:seq(0, 2 * R - 1), Ys), I rem 2 =:= 1],
    list_to_tuple(lists:append(Even ++ Odd)).

blocks([], Acc) -> lists:reverse(Acc);
blocks(Words, Acc) ->
    {Block, Rest} = lists:split(16, Words),
    blocks(Rest, [Block | Acc]).

-compile({inline, [q/3]}).

%% The step of Salsa20: (A + B) rotated left by C bits.
q(A, B, C) ->
    V = (A + B) band ?MASK,
    ((V bsl C) band ?MASK) bor (V bsr (32 - C)).

%% Salsa20/8 core: four double rounds, then the input added back.
salsa([I0, I1, I2, I3, I4, I5, I6, I7, I8, I9, I10, I11, I12, I13, I14, I15] = Input) ->
    Out = rounds(4, {I0, I1, I2, I3, I4, I5, I6, I7, I8, I9, I10, I11, I12, I13, I14, I15}),
    lists:zipwith(fun(A, B) -> (A + B) band ?MASK end, tuple_to_list(Out), Input).

rounds(0, S) -> S;
rounds(N, {X0, X1, X2, X3, X4, X5, X6, X7, X8, X9, X10, X11, X12, X13, X14, X15}) ->
    %% Columns.
    A4 = X4 bxor q(X0, X12, 7), A8 = X8 bxor q(A4, X0, 9),
    A12 = X12 bxor q(A8, A4, 13), A0 = X0 bxor q(A12, A8, 18),
    A9 = X9 bxor q(X5, X1, 7), A13 = X13 bxor q(A9, X5, 9),
    A1 = X1 bxor q(A13, A9, 13), A5 = X5 bxor q(A1, A13, 18),
    A14 = X14 bxor q(X10, X6, 7), A2 = X2 bxor q(A14, X10, 9),
    A6 = X6 bxor q(A2, A14, 13), A10 = X10 bxor q(A6, A2, 18),
    A3 = X3 bxor q(X15, X11, 7), A7 = X7 bxor q(A3, X15, 9),
    A11 = X11 bxor q(A7, A3, 13), A15 = X15 bxor q(A11, A7, 18),
    %% Rows.
    B1 = A1 bxor q(A0, A3, 7), B2 = A2 bxor q(B1, A0, 9),
    B3 = A3 bxor q(B2, B1, 13), B0 = A0 bxor q(B3, B2, 18),
    B6 = A6 bxor q(A5, A4, 7), B7 = A7 bxor q(B6, A5, 9),
    B4 = A4 bxor q(B7, B6, 13), B5 = A5 bxor q(B4, B7, 18),
    B11 = A11 bxor q(A10, A9, 7), B8 = A8 bxor q(B11, A10, 9),
    B9 = A9 bxor q(B8, B11, 13), B10 = A10 bxor q(B9, B8, 18),
    B12 = A12 bxor q(A15, A14, 7), B13 = A13 bxor q(B12, A15, 9),
    B14 = A14 bxor q(B13, B12, 13), B15 = A15 bxor q(B14, B13, 18),
    rounds(N - 1, {B0, B1, B2, B3, B4, B5, B6, B7, B8, B9, B10, B11, B12, B13, B14, B15}).
