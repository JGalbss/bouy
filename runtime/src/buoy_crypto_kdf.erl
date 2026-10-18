%% The key derivation jobs of internalBinding('crypto'): PBKDF2Job, HKDFJob,
%% and ScryptJob (src/crypto/crypto_pbkdf2.cc, crypto_hkdf.cc, and
%% crypto_scrypt.cc), on the HMAC of OTP's crypto.
-module(buoy_crypto_kdf).

-export([members/0, pbkdf2/5, pkcs12/6, hkdf/5, scrypt/6]).

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

%% The states stay binaries, which live off the heap of the process, so a
%% large N does not make each garbage collection copy the whole of V.
romix(Block, N, R) ->
    {X, V} = fill(Block, N, R, []),
    mix(X, N, R, V, N).

%% V holds the N states in order, so the step j reads element j + 1.
fill(X, 0, _, Acc) -> {X, list_to_tuple(lists:reverse(Acc))};
fill(X, N, R, Acc) -> fill(block_mix(X, R), N - 1, R, [X | Acc]).

mix(X, 0, _, _, _) -> X;
mix(X, I, R, V, N) ->
    J = integerify(X, R) band (N - 1),
    mix(block_mix(crypto:exor(X, element(J + 1, V)), R), I - 1, R, V, N).

%% The first word of the last 64-byte block, as the low bits of Integerify.
integerify(X, R) ->
    <<_:((2 * R - 1) * 64)/binary, W:32/little, _/binary>> = X,
    W.

%% BlockMix with Salsa20/8 over the 2R blocks of 64 bytes of X: the even
%% outputs, then the odd ones.
block_mix(X, R) ->
    Last = binary:part(X, (2 * R - 1) * 64, 64),
    {Ys, _} = lists:mapfoldl(fun(Bi, Prev) ->
        Y = salsa(Prev, Bi),
        {Y, Y}
    end, Last, [Bi || <<Bi:64/binary>> <= X]),
    {Even, Odd} = split_alternate(Ys, [], []),
    iolist_to_binary([Even, Odd]).

split_alternate([E, O | Rest], Even, Odd) -> split_alternate(Rest, [E | Even], [O | Odd]);
split_alternate([], Even, Odd) -> {lists:reverse(Even), lists:reverse(Odd)}.

-compile({inline, [q/3]}).

%% The step of Salsa20: (A + B) rotated left by C bits.
q(A, B, C) ->
    V = (A + B) band ?MASK,
    ((V bsl C) band ?MASK) bor (V bsr (32 - C)).

%% Salsa20/8 core on the exclusive or of two 64-byte blocks: four double
%% rounds, then the input added back.
salsa(<<A0:32/little, A1:32/little, A2:32/little, A3:32/little, A4:32/little, A5:32/little, A6:32/little,
        A7:32/little, A8:32/little, A9:32/little, A10:32/little, A11:32/little, A12:32/little, A13:32/little,
        A14:32/little, A15:32/little>>,
      <<B0:32/little, B1:32/little, B2:32/little, B3:32/little, B4:32/little, B5:32/little, B6:32/little,
        B7:32/little, B8:32/little, B9:32/little, B10:32/little, B11:32/little, B12:32/little, B13:32/little,
        B14:32/little, B15:32/little>>) ->
    {I0, I1, I2, I3, I4, I5, I6, I7, I8, I9, I10, I11, I12, I13, I14, I15} =
        {A0 bxor B0, A1 bxor B1, A2 bxor B2, A3 bxor B3, A4 bxor B4, A5 bxor B5, A6 bxor B6, A7 bxor B7,
         A8 bxor B8, A9 bxor B9, A10 bxor B10, A11 bxor B11, A12 bxor B12, A13 bxor B13, A14 bxor B14, A15 bxor B15},
    {O0, O1, O2, O3, O4, O5, O6, O7, O8, O9, O10, O11, O12, O13, O14, O15} =
        rounds(4, {I0, I1, I2, I3, I4, I5, I6, I7, I8, I9, I10, I11, I12, I13, I14, I15}),
    <<(O0 + I0):32/little, (O1 + I1):32/little, (O2 + I2):32/little, (O3 + I3):32/little,
      (O4 + I4):32/little, (O5 + I5):32/little, (O6 + I6):32/little, (O7 + I7):32/little,
      (O8 + I8):32/little, (O9 + I9):32/little, (O10 + I10):32/little, (O11 + I11):32/little,
      (O12 + I12):32/little, (O13 + I13):32/little, (O14 + I14):32/little, (O15 + I15):32/little>>.

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
