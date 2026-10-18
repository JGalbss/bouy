%% Argon2Job of internalBinding('crypto') (src/crypto/crypto_argon2.cc):
%% Argon2d, Argon2i, and Argon2id of RFC 9106, version 0x13, in Erlang,
%% with BLAKE2b of RFC 7693 for the variable-length hashes that OTP's
%% crypto does not give. OpenSSL computes it on one thread, as here.
-module(buoy_crypto_argon2).

-export([members/0, argon2/9, blake2b/2]).

-define(MASK, 16#FFFFFFFFFFFFFFFF).
-define(VERSION, 16#13).

-spec members() -> [{binary(), term()}].
members() ->
    [{<<"Argon2Job">>, buoy_crypto_job:class(<<"Argon2Job">>, fun argon2_job/1)}].

%% new Argon2Job(mode, message, nonce, parallelism, tagLength, memory,
%% passes, secret, associatedData, type)
argon2_job([Message, Nonce, Lanes, TagLen, Memory, Passes, Secret, AD, Type | _]) ->
    [P, S, K, X] = [optional(V) || V <- [Message, Nonce, Secret, AD]],
    valid(Lanes, TagLen, Memory, Passes, S) orelse buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_ARGON2_PARAMS">>),
    {fun() -> {ok, argon2(Type, P, S, K, X, Lanes, TagLen, Memory, Passes)} end, fun buoy_crypto:array_buffer/1}.

optional(undefined) -> <<>>;
optional(V) -> buoy_crypto:bytes(V).

%% The parameters that OpenSSL's Argon2 accepts.
valid(Lanes, TagLen, Memory, Passes, Salt) ->
    Lanes >= 1 andalso Lanes =< 16#FFFFFF andalso (TagLen =:= 0 orelse TagLen >= 4)
        andalso Memory >= 8 * Lanes andalso Passes >= 1 andalso byte_size(Salt) >= 8.

%% Argon2 of type 0 (d), 1 (i), or 2 (id) with the password P, the salt S,
%% the secret K, the associated data X, and the costs.
-spec argon2(0..2, binary(), binary(), binary(), binary(), pos_integer(), non_neg_integer(), pos_integer(),
             pos_integer()) -> binary().
argon2(_, _, _, _, _, _, 0, _, _) -> <<>>;
argon2(Type, P, S, K, X, Lanes, TagLen, Memory, Passes) ->
    H0 = blake2b(64, iolist_to_binary([<<Lanes:32/little, TagLen:32/little, Memory:32/little, Passes:32/little,
                                        ?VERSION:32/little, Type:32/little>>,
                                       <<(byte_size(P)):32/little>>, P, <<(byte_size(S)):32/little>>, S,
                                       <<(byte_size(K)):32/little>>, K, <<(byte_size(X)):32/little>>, X])),
    Blocks = 4 * Lanes * (Memory div (4 * Lanes)),
    Q = Blocks div Lanes,
    Seg = Q div 4,
    Ctx = #{type => Type, lanes => Lanes, q => Q, seg => Seg, blocks => Blocks, passes => Passes},
    Mem0 = maps:from_list([{{L, C}, words(hprime(1024, <<H0/binary, C:32/little, L:32/little>>))}
                           || L <- lists:seq(0, Lanes - 1), C <- [0, 1]]),
    Mem = lists:foldl(fun({Pass, Slice, Lane}, M) -> segment(Ctx, M, Pass, Slice, Lane) end, Mem0,
                      [{Pass, Slice, Lane} || Pass <- lists:seq(0, Passes - 1), Slice <- lists:seq(0, 3),
                                              Lane <- lists:seq(0, Lanes - 1)]),
    Final = lists:foldl(fun(L, Acc) -> xor_blocks(Acc, maps:get({L, Q - 1}, Mem)) end,
                        maps:get({0, Q - 1}, Mem), lists:seq(1, Lanes - 1)),
    hprime(TagLen, bytes(Final)).

segment(#{type := Type, seg := Seg} = Ctx, Mem, Pass, Slice, Lane) ->
    Independent = Type =:= 1 orelse (Type =:= 2 andalso Pass =:= 0 andalso Slice < 2),
    Start = case Pass =:= 0 andalso Slice =:= 0 of
        true -> 2;
        false -> 0
    end,
    {M, _} = lists:foldl(fun(Index, {M0, Addresses}) ->
        {Pseudo, Addresses1} = case Independent of
            true -> address(Ctx, Pass, Lane, Slice, Index, Addresses);
            false -> {element(1, maps:get(previous(Ctx, Lane, Slice, Index), M0)), Addresses}
        end,
        {fill(Ctx, M0, Pass, Slice, Lane, Index, Pseudo), Addresses1}
    end, {Mem, undefined}, lists:seq(Start, Seg - 1)),
    M.

previous(#{seg := Seg, q := Q}, Lane, Slice, Index) ->
    J = Slice * Seg + Index,
    case J of
        0 -> {Lane, Q - 1};
        _ -> {Lane, J - 1}
    end.

%% The pseudo-random word of a data-independent index: a word of the
%% address block, made again every 128 indices.
address(#{blocks := Blocks, passes := Passes, type := Type}, Pass, Lane, Slice, Index, Addresses) ->
    Counter = Index div 128 + 1,
    Block = case Addresses of
        {Counter, B} -> B;
        _ ->
            Input = list_to_tuple([Pass, Lane, Slice, Blocks, Passes, Type, Counter | lists:duplicate(121, 0)]),
            Zero = erlang:make_tuple(128, 0),
            compress(Zero, compress(Zero, Input))
    end,
    {element((Index rem 128) + 1, Block), {Counter, Block}}.

fill(#{lanes := Lanes, q := Q, seg := Seg}, Mem, Pass, Slice, Lane, Index, Pseudo) ->
    J1 = Pseudo band 16#FFFFFFFF,
    J2 = Pseudo bsr 32,
    RefLane = case Pass =:= 0 andalso Slice =:= 0 of
        true -> Lane;
        false -> J2 rem Lanes
    end,
    Same = RefLane =:= Lane,
    Back = case Index of
        0 -> -1;
        _ -> 0
    end,
    Area = case {Pass, Same} of
        {0, true} -> Slice * Seg + Index - 1;
        {0, false} -> Slice * Seg + Back;
        {_, true} -> Q - Seg + Index - 1;
        {_, false} -> Q - Seg + Back
    end,
    Y = (Area * ((J1 * J1) bsr 32)) bsr 32,
    Relative = Area - 1 - Y,
    StartPos = case Pass =:= 0 orelse Slice =:= 3 of
        true -> 0;
        false -> (Slice + 1) * Seg
    end,
    Ref = maps:get({RefLane, (StartPos + Relative) rem Q}, Mem),
    Prev = maps:get(previous(#{seg => Seg, q => Q}, Lane, Slice, Index), Mem),
    New = compress(Prev, Ref),
    Key = {Lane, Slice * Seg + Index},
    case Pass of
        0 -> Mem#{Key => New};
        _ -> Mem#{Key => xor_blocks(maps:get(Key, Mem), New)}
    end.

%%% The compression function G

compress(X, Y) ->
    R = xor_blocks(X, Y),
    Rows = lists:foldl(fun(I, Acc) -> permute_words(Acc, [16 * I + K || K <- lists:seq(0, 15)]) end,
                       R, lists:seq(0, 7)),
    Cols = lists:foldl(fun(I, Acc) ->
        permute_words(Acc, lists:append([[2 * I + 16 * K, 2 * I + 16 * K + 1] || K <- lists:seq(0, 7)]))
    end, Rows, lists:seq(0, 7)),
    xor_blocks(Cols, R).

%% P over the 16 words of Block at the indices Is.
permute_words(Block, Is) ->
    V = list_to_tuple([element(I + 1, Block) || I <- Is]),
    V1 = lists:foldl(fun({A, B, C, D}, Acc) -> gb(Acc, A, B, C, D) end, V,
                     [{0, 4, 8, 12}, {1, 5, 9, 13}, {2, 6, 10, 14}, {3, 7, 11, 15},
                      {0, 5, 10, 15}, {1, 6, 11, 12}, {2, 7, 8, 13}, {3, 4, 9, 14}]),
    {Out, _} = lists:foldl(fun(I, {B, N}) -> {setelement(I + 1, B, element(N, V1)), N + 1} end, {Block, 1}, Is),
    Out.

gb(V, IA, IB, IC, ID) ->
    [A0, B0, C0, D0] = [element(I + 1, V) || I <- [IA, IB, IC, ID]],
    A1 = blamka(A0, B0),
    D1 = rotr(D0 bxor A1, 32),
    C1 = blamka(C0, D1),
    B1 = rotr(B0 bxor C1, 24),
    A2 = blamka(A1, B1),
    D2 = rotr(D1 bxor A2, 16),
    C2 = blamka(C1, D2),
    B2 = rotr(B1 bxor C2, 63),
    lists:foldl(fun({I, W}, Acc) -> setelement(I + 1, Acc, W) end, V, [{IA, A2}, {IB, B2}, {IC, C2}, {ID, D2}]).

blamka(A, B) -> (A + B + 2 * (A band 16#FFFFFFFF) * (B band 16#FFFFFFFF)) band ?MASK.

rotr(W, N) -> ((W bsr N) bor (W bsl (64 - N))) band ?MASK.

xor_blocks(A, B) -> list_to_tuple(lists:zipwith(fun(X, Y) -> X bxor Y end, tuple_to_list(A), tuple_to_list(B))).

words(Bin) -> list_to_tuple([W || <<W:64/little>> <= Bin]).

bytes(Block) -> << <<W:64/little>> || W <- tuple_to_list(Block) >>.

%% H' of RFC 9106: a hash of T bytes.
hprime(T, A) when T =< 64 -> blake2b(T, <<T:32/little, A/binary>>);
hprime(T, A) ->
    R = (T + 31) div 32 - 2,
    V1 = blake2b(64, <<T:32/little, A/binary>>),
    {Ws, Vr} = lists:foldl(fun(_, {Acc, V}) -> {[binary:part(V, 0, 32) | Acc], blake2b(64, V)} end,
                           {[], V1}, lists:seq(2, R)),
    Last = blake2b(T - 32 * R, Vr),
    iolist_to_binary(lists:reverse([Last, binary:part(Vr, 0, 32) | Ws])).

%%% BLAKE2b

-define(IV, {16#6a09e667f3bcc908, 16#bb67ae8584caa73b, 16#3c6ef372fe94f82b, 16#a54ff53a5f1d36f1,
             16#510e527fade682d1, 16#9b05688c2b3e6c1f, 16#1f83d9abfb41bd6b, 16#5be0cd19137e2179}).

%% BLAKE2b without a key, with an output of OutLen bytes (1 to 64).
-spec blake2b(1..64, binary()) -> binary().
blake2b(64, Data) -> crypto:hash(blake2b, Data);
blake2b(OutLen, Data) ->
    H0 = setelement(1, ?IV, element(1, ?IV) bxor 16#01010000 bxor OutLen),
    H = blake_blocks(H0, Data, 0),
    binary:part(<< <<W:64/little>> || W <- tuple_to_list(H) >>, 0, OutLen).

blake_blocks(H, Data, T) when byte_size(Data) > 128 ->
    <<Block:128/binary, Rest/binary>> = Data,
    blake_blocks(blake_compress(H, Block, T + 128, false), Rest, T + 128);
blake_blocks(H, Last, T) ->
    Pad = 128 - byte_size(Last),
    blake_compress(H, <<Last/binary, 0:(Pad * 8)>>, T + byte_size(Last), true).

sigma() ->
    {{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}, {14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3},
     {11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4}, {7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8},
     {9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13}, {2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9},
     {12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11}, {13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10},
     {6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5}, {10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0}}.

blake_compress(H, Block, T, Last) ->
    M = words(Block),
    V0 = list_to_tuple(tuple_to_list(H) ++ tuple_to_list(?IV)),
    V1 = setelement(13, V0, element(13, V0) bxor (T band ?MASK)),
    V2 = setelement(14, V1, element(14, V1) bxor (T bsr 64)),
    V3 = case Last of
        true -> setelement(15, V2, element(15, V2) bxor ?MASK);
        false -> V2
    end,
    V = lists:foldl(fun(Round, Acc) ->
        S = element((Round rem 10) + 1, sigma()),
        Mx = fun(I) -> element(element(I + 1, S) + 1, M) end,
        lists:foldl(fun({N, {A, B, C, D}}, Acc1) -> blake_g(Acc1, A, B, C, D, Mx(2 * N), Mx(2 * N + 1)) end, Acc,
                    lists:zip(lists:seq(0, 7), [{0,4,8,12}, {1,5,9,13}, {2,6,10,14}, {3,7,11,15},
                                                {0,5,10,15}, {1,6,11,12}, {2,7,8,13}, {3,4,9,14}]))
    end, V3, lists:seq(0, 11)),
    list_to_tuple([element(I, H) bxor element(I, V) bxor element(I + 8, V) || I <- lists:seq(1, 8)]).

blake_g(V, IA, IB, IC, ID, X, Y) ->
    [A0, B0, C0, D0] = [element(I + 1, V) || I <- [IA, IB, IC, ID]],
    A1 = (A0 + B0 + X) band ?MASK,
    D1 = rotr(D0 bxor A1, 32),
    C1 = (C0 + D1) band ?MASK,
    B1 = rotr(B0 bxor C1, 24),
    A2 = (A1 + B1 + Y) band ?MASK,
    D2 = rotr(D1 bxor A2, 16),
    C2 = (C1 + D2) band ?MASK,
    B2 = rotr(B1 bxor C2, 63),
    lists:foldl(fun({I, W}, Acc) -> setelement(I + 1, Acc, W) end, V, [{IA, A2}, {IB, B2}, {IC, C2}, {ID, D2}]).
