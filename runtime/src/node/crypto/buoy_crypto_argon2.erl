%% Argon2Job of internalBinding('crypto') (src/crypto/crypto_argon2.cc):
%% Argon2d, Argon2i, and Argon2id of RFC 9106, version 0x13, in Erlang,
%% with BLAKE2b of RFC 7693 for the variable-length hashes that OTP's
%% crypto does not give. The lanes of a slice fill on parallel processes.
-module(buoy_crypto_argon2).

-export([members/0, argon2/9, blake2b/2]).

-define(MASK, 16#FFFFFFFFFFFFFFFF).
-define(M32, 16#FFFFFFFF).
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
    %% The blocks live in an ETS table as 1 KiB binaries, off the heap of
    %% the process, so the memory cost stays near the memory parameter.
    Mem = ets:new(?MODULE, [set, public, {read_concurrency, true}, {write_concurrency, true}]),
    try
        ets:insert(Mem, [{{L, C}, hprime(1024, <<H0/binary, C:32/little, L:32/little>>)}
                         || L <- lists:seq(0, Lanes - 1), C <- [0, 1]]),
        [slice(Ctx, Mem, Pass, Slice) || Pass <- lists:seq(0, Passes - 1), Slice <- lists:seq(0, 3)],
        Final = lists:foldl(fun(L, Acc) -> crypto:exor(Acc, block(Mem, {L, Q - 1})) end,
                            block(Mem, {0, Q - 1}), lists:seq(1, Lanes - 1)),
        hprime(TagLen, Final)
    after
        ets:delete(Mem)
    end.

block(Mem, Key) -> ets:lookup_element(Mem, Key, 2).

%% The segments of one slice. A lane reads other lanes only in finished
%% slices (RFC 9106, section 3.4), so the lanes fill at once, on at most
%% one process for each scheduler.
slice(#{lanes := 1} = Ctx, Mem, Pass, Slice) -> segment(Ctx, Mem, Pass, Slice, 0);
slice(#{lanes := Lanes} = Ctx, Mem, Pass, Slice) ->
    Workers = min(Lanes, erlang:system_info(schedulers_online)),
    Monitors = [spawn_monitor(fun() ->
                    [segment(Ctx, Mem, Pass, Slice, Lane) || Lane <- lists:seq(First, Lanes - 1, Workers)]
                end) || First <- lists:seq(0, Workers - 1)],
    [receive
         {'DOWN', Ref, process, Pid, normal} -> ok;
         {'DOWN', Ref, process, Pid, Reason} -> erlang:error({argon2_lane, Reason})
     end || {Pid, Ref} <- Monitors],
    ok.

segment(#{type := Type, seg := Seg} = Ctx, Mem, Pass, Slice, Lane) ->
    Independent = Type =:= 1 orelse (Type =:= 2 andalso Pass =:= 0 andalso Slice < 2),
    Start = case Pass =:= 0 andalso Slice =:= 0 of
        true -> 2;
        false -> 0
    end,
    lists:foldl(fun(Index, Addresses) ->
        Prev = block(Mem, previous(Ctx, Lane, Slice, Index)),
        {Pseudo, Addresses1} = case Independent of
            true -> address(Ctx, Pass, Lane, Slice, Index, Addresses);
            false -> {binary:decode_unsigned(binary:part(Prev, 0, 8), little), Addresses}
        end,
        fill(Ctx, Mem, Pass, Slice, Lane, Index, Pseudo, Prev),
        Addresses1
    end, undefined, lists:seq(Start, Seg - 1)),
    ok.

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
            Input = <<Pass:64/little, Lane:64/little, Slice:64/little, Blocks:64/little, Passes:64/little,
                      Type:64/little, Counter:64/little, 0:(121 * 64)>>,
            Zero = <<0:8192>>,
            compress(Zero, compress(Zero, Input))
    end,
    Offset = (Index rem 128) * 8,
    <<_:Offset/binary, Word:64/little, _/binary>> = Block,
    {Word, {Counter, Block}}.

fill(#{lanes := Lanes, q := Q, seg := Seg}, Mem, Pass, Slice, Lane, Index, Pseudo, Prev) ->
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
    New = compress(Prev, block(Mem, {RefLane, (StartPos + Relative) rem Q})),
    Key = {Lane, Slice * Seg + Index},
    ets:insert(Mem, {Key, case Pass of
                              0 -> New;
                              _ -> crypto:exor(block(Mem, Key), New)
                          end}).

%%% The compression function G, on 1 KiB binaries

%% The 64-bit words of a block are split into 32-bit halves, low then high,
%% so that every value stays a small integer and no bignum is made.
compress(X, Y) ->
    R = crypto:exor(X, Y),
    Q = << <<(p(Row))/binary>> || <<Row:128/binary>> <= R >>,
    Cols = list_to_tuple([p(<< <<(binary:part(Q, (2 * C + 16 * K) * 8, 16))/binary>> || K <- lists:seq(0, 7) >>)
                          || C <- lists:seq(0, 7)]),
    Z = << <<(binary:part(element(C + 1, Cols), K * 16, 16))/binary>> || K <- lists:seq(0, 7), C <- lists:seq(0, 7) >>,
    crypto:exor(Z, R).

%% The permutation P of RFC 9106 on the 16 words of 128 bytes.
p(<<L0:32/little, H0:32/little, L1:32/little, H1:32/little, L2:32/little, H2:32/little, L3:32/little, H3:32/little,
    L4:32/little, H4:32/little, L5:32/little, H5:32/little, L6:32/little, H6:32/little, L7:32/little, H7:32/little,
    L8:32/little, H8:32/little, L9:32/little, H9:32/little, L10:32/little, H10:32/little, L11:32/little, H11:32/little,
    L12:32/little, H12:32/little, L13:32/little, H13:32/little, L14:32/little, H14:32/little, L15:32/little, H15:32/little>>) ->
    {AL0, AH0, AL4, AH4, AL8, AH8, AL12, AH12} = g(L0, H0, L4, H4, L8, H8, L12, H12),
    {AL1, AH1, AL5, AH5, AL9, AH9, AL13, AH13} = g(L1, H1, L5, H5, L9, H9, L13, H13),
    {AL2, AH2, AL6, AH6, AL10, AH10, AL14, AH14} = g(L2, H2, L6, H6, L10, H10, L14, H14),
    {AL3, AH3, AL7, AH7, AL11, AH11, AL15, AH15} = g(L3, H3, L7, H7, L11, H11, L15, H15),
    {BL0, BH0, BL5, BH5, BL10, BH10, BL15, BH15} = g(AL0, AH0, AL5, AH5, AL10, AH10, AL15, AH15),
    {BL1, BH1, BL6, BH6, BL11, BH11, BL12, BH12} = g(AL1, AH1, AL6, AH6, AL11, AH11, AL12, AH12),
    {BL2, BH2, BL7, BH7, BL8, BH8, BL13, BH13} = g(AL2, AH2, AL7, AH7, AL8, AH8, AL13, AH13),
    {BL3, BH3, BL4, BH4, BL9, BH9, BL14, BH14} = g(AL3, AH3, AL4, AH4, AL9, AH9, AL14, AH14),
    <<BL0:32/little, BH0:32/little, BL1:32/little, BH1:32/little, BL2:32/little, BH2:32/little, BL3:32/little, BH3:32/little,
      BL4:32/little, BH4:32/little, BL5:32/little, BH5:32/little, BL6:32/little, BH6:32/little, BL7:32/little, BH7:32/little,
      BL8:32/little, BH8:32/little, BL9:32/little, BH9:32/little, BL10:32/little, BH10:32/little, BL11:32/little, BH11:32/little,
      BL12:32/little, BH12:32/little, BL13:32/little, BH13:32/little, BL14:32/little, BH14:32/little, BL15:32/little, BH15:32/little>>.

-compile({inline, [blamka/4]}).

%% fBlaMka: x + y + 2 * lo(x) * lo(y) modulo 2^64, as {Low, High}. The
%% product of the low halves is taken in two parts of at most 48 bits.
blamka(XL, XH, YL, YH) ->
    P1 = XL * (YL bsr 16),
    T = XL * (YL band 16#FFFF) + ((P1 band 16#FFFF) bsl 16),
    ML = T band ?M32,
    MH = (T bsr 32) + (P1 bsr 16),
    SL = XL + YL + ((ML bsl 1) band ?M32),
    {SL band ?M32, (XH + YH + (((MH bsl 1) bor (ML bsr 31)) band ?M32) + (SL bsr 32)) band ?M32}.

%% GB of RFC 9106 on four words: the rotations by 32, 24, 16, and 63 bits
%% move bits between the halves.
g(AL, AH, BL, BH, CL, CH, DL, DH) ->
    {AL1, AH1} = blamka(AL, AH, BL, BH),
    DL1 = DH bxor AH1, DH1 = DL bxor AL1,
    {CL1, CH1} = blamka(CL, CH, DL1, DH1),
    BXL = BL bxor CL1, BXH = BH bxor CH1,
    BL1 = ((BXL bsr 24) bor (BXH bsl 8)) band ?M32, BH1 = ((BXH bsr 24) bor (BXL bsl 8)) band ?M32,
    {AL2, AH2} = blamka(AL1, AH1, BL1, BH1),
    DXL = DL1 bxor AL2, DXH = DH1 bxor AH2,
    DL2 = ((DXL bsr 16) bor (DXH bsl 16)) band ?M32, DH2 = ((DXH bsr 16) bor (DXL bsl 16)) band ?M32,
    {CL2, CH2} = blamka(CL1, CH1, DL2, DH2),
    BYL = BL1 bxor CL2, BYH = BH1 bxor CH2,
    BL2 = ((BYL bsl 1) bor (BYH bsr 31)) band ?M32, BH2 = ((BYH bsl 1) bor (BYL bsr 31)) band ?M32,
    {AL2, AH2, BL2, BH2, CL2, CH2, DL2, DH2}.

rotr(W, N) -> ((W bsr N) bor (W bsl (64 - N))) band ?MASK.

words(Bin) -> list_to_tuple([W || <<W:64/little>> <= Bin]).

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
