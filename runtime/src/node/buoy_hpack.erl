%% HPACK (RFC 7541), the header compression of HTTP/2, as nghttp2 1.68.1
%% does it in lib/nghttp2_hd.c: the deflater indexes the fields that
%% hd_deflate_decide_indexing indexes, never indexes authorization and short
%% cookies, and uses Huffman coding when it is shorter. The inflater checks
%% the rules of dynamic table size updates and fails with an error that the
%% session turns into a COMPRESSION_ERROR.
%%
%% Bun encodes with ls-hpack (src/http/lshpack.rs); this is the same
%% algorithm in Erlang, with the tables of nghttp2_hd_huffman_data.c.
-module(buoy_hpack).

-export([new/1, encode/2, decode/2, set_max/2, set_decoder_max/2, table_size/1]).
-export_type([context/0]).

-define(ENTRY_OVERHEAD, 32).

-record(hpack, {table = [] :: [{binary(), binary()}],
                size = 0 :: non_neg_integer(),
                max = 4096 :: non_neg_integer(),
                %% The deflater: the smallest size since the last block, to
                %% announce in the next one.
                pending = none :: none | non_neg_integer(),
                %% The inflater: a table size update must open the next block.
                expect_update = false :: boolean(),
                limit = 4096 :: non_neg_integer()}).

-opaque context() :: #hpack{}.

-spec new(non_neg_integer()) -> context().
new(Max) -> #hpack{max = Max, limit = Max}.

%% The bytes of the dynamic table, as nghttp2_hd_*_get_dynamic_table_size.
-spec table_size(context()) -> non_neg_integer().
table_size(#hpack{size = Size}) -> Size.

%% The deflater learns the peer's SETTINGS_HEADER_TABLE_SIZE.
-spec set_max(context(), non_neg_integer()) -> context().
set_max(#hpack{pending = Pending} = H, Max) ->
    Min = case Pending of none -> Max; P -> min(P, Max) end,
    shrink(H#hpack{max = Max, pending = Min}).

%% The inflater learns the SETTINGS_HEADER_TABLE_SIZE that the peer acked.
-spec set_decoder_max(context(), non_neg_integer()) -> context().
set_decoder_max(#hpack{max = Old} = H, Max) when Max < Old ->
    shrink(H#hpack{max = Max, limit = Max, expect_update = true});
set_decoder_max(H, Max) ->
    H#hpack{limit = Max}.

%%% The deflater

%% Encodes the fields {Name, Value, NoIndex}, lower-case names first, as one
%% header block.
-spec encode([{binary(), binary(), boolean()}], context()) -> {iodata(), context()}.
encode(Fields, #hpack{pending = Pending, max = Max} = H0) ->
    {Prefix, H1} = case Pending of
        none -> {[], H0};
        Min when Min < Max -> {[int(Min, 5, 2#001), int(Max, 5, 2#001)], H0#hpack{pending = none}};
        _ -> {[int(Max, 5, 2#001)], H0#hpack{pending = none}}
    end,
    {Blocks, H2} = lists:mapfoldl(fun field/2, H1, Fields),
    {[Prefix | Blocks], H2}.

field({Name, Value, NoIndex}, H) ->
    Never = NoIndex orelse Name =:= <<"authorization">> orelse (Name =:= <<"cookie">> andalso byte_size(Value) < 20),
    Mode = case Never of
        true -> never;
        false -> indexing(Name, Value, H)
    end,
    case search(Name, Value, Mode, H) of
        {exact, Index} ->
            {int(Index, 7, 1), H};
        Found ->
            H1 = case Mode of
                with -> add({Name, Value}, H);
                _ -> H
            end,
            {Bits, PrefixBits} = case Mode of
                with -> {2#01, 6};
                without -> {2#0000, 4};
                never -> {2#0001, 4}
            end,
            Block = case Found of
                {name, Index} -> [int(Index, PrefixBits, Bits), string(Value)];
                none -> [int(0, PrefixBits, Bits), string(Name), string(Value)]
            end,
            {Block, H1}
    end.

indexing(Name, Value, #hpack{max = Max}) ->
    NoIndex = [<<":path">>, <<"age">>, <<"content-length">>, <<"etag">>, <<"if-modified-since">>,
               <<"if-none-match">>, <<"location">>, <<"set-cookie">>],
    case lists:member(Name, NoIndex) orelse room(Name, Value) > Max * 3 div 4 of
        true -> without;
        false -> with
    end.

%% search_hd_table: an exact match of the dynamic table, then of the static
%% table, then a match of the name.
search(Name, Value, Mode, #hpack{table = Table}) ->
    Dynamic = lists:enumerate(62, Table),
    Static = lists:enumerate(1, static()),
    Exact = case Mode of
        never -> false;
        _ -> find_exact(Name, Value, Dynamic ++ Static)
    end,
    case Exact of
        {ok, I} -> {exact, I};
        false ->
            case find_name(Name, Static) of
                {ok, I} -> {name, I};
                false ->
                    case find_name(Name, Dynamic) of
                        {ok, I} -> {name, I};
                        false -> none
                    end
            end
    end.

find_exact(N, V, [{I, {N, V}} | _]) -> {ok, I};
find_exact(N, V, [_ | T]) -> find_exact(N, V, T);
find_exact(_, _, []) -> false.

find_name(N, [{I, {N, _}} | _]) -> {ok, I};
find_name(N, [_ | T]) -> find_name(N, T);
find_name(_, []) -> false.

string(S) ->
    Huffman = huffman_encode(S),
    case byte_size(Huffman) < byte_size(S) of
        true -> [int(byte_size(Huffman), 7, 1), Huffman];
        false -> [int(byte_size(S), 7, 0), S]
    end.

%% An integer with an N-bit prefix after the bits Pattern (RFC 7541 5.1).
int(I, N, Pattern) ->
    Max = (1 bsl N) - 1,
    case I < Max of
        true -> <<Pattern:(8 - N), I:N>>;
        false -> [<<Pattern:(8 - N), Max:N>> | int_rest(I - Max)]
    end.

int_rest(I) when I >= 128 -> [128 + (I band 127) | int_rest(I bsr 7)];
int_rest(I) -> [I].

huffman_encode(S) ->
    Codes = codes(),
    Bits = << <<(element(1, element(C + 1, Codes))):(element(2, element(C + 1, Codes)))>> || <<C>> <= S >>,
    Pad = (8 - bit_size(Bits) rem 8) rem 8,
    <<Bits/bitstring, ((1 bsl Pad) - 1):Pad>>.

%%% The inflater

%% Decodes one header block: {ok, Fields, Context}, with each field as
%% {Name, Value, NeverIndexed}, or {error, Reason}.
-spec decode(binary(), context()) -> {ok, [{binary(), binary(), boolean()}], context()} | {error, binary()}.
decode(Block, H) ->
    try
        decode(Block, H, [], true)
    catch
        throw:{hpack, Reason} -> {error, Reason}
    end.

decode(<<>>, #hpack{expect_update = true}, _, _) ->
    throw({hpack, <<"expected table size update">>});
decode(<<>>, H, Acc, _) ->
    {ok, lists:reverse(Acc), H};
decode(<<1:1, _/bitstring>> = B, H, Acc, _) ->
    {Index, Rest} = read_int(B, 7),
    {Name, Value} = entry(Index, H),
    decode(Rest, check_update(H), [{Name, Value, false} | Acc], false);
decode(<<2#01:2, _/bitstring>> = B, H, Acc, _) ->
    {Name, Value, Rest} = literal(B, 6, check_update(H)),
    decode(Rest, add({Name, Value}, check_update(H)), [{Name, Value, false} | Acc], false);
decode(<<2#001:3, _/bitstring>> = B, #hpack{limit = Limit} = H, Acc, First) ->
    {Size, Rest} = read_int(B, 5),
    case First orelse H#hpack.expect_update of
        false -> throw({hpack, <<"table size update after a field">>});
        true when Size > Limit -> throw({hpack, <<"table size update above the limit">>});
        true -> decode(Rest, shrink(H#hpack{max = Size, expect_update = false}), Acc, true)
    end;
decode(<<2#0001:4, _/bitstring>> = B, H, Acc, _) ->
    {Name, Value, Rest} = literal(B, 4, check_update(H)),
    decode(Rest, check_update(H), [{Name, Value, true} | Acc], false);
decode(<<2#0000:4, _/bitstring>> = B, H, Acc, _) ->
    {Name, Value, Rest} = literal(B, 4, check_update(H)),
    decode(Rest, check_update(H), [{Name, Value, false} | Acc], false).

check_update(#hpack{expect_update = true}) -> throw({hpack, <<"expected table size update">>});
check_update(H) -> H.

literal(B, N, H) ->
    {Index, R1} = read_int(B, N),
    {Name, R2} = case Index of
        0 -> read_string(R1);
        _ -> {element(1, entry(Index, H)), R1}
    end,
    {Value, R3} = read_string(R2),
    {Name, Value, R3}.

entry(0, _) -> throw({hpack, <<"index 0">>});
entry(I, _) when I =< 61 -> lists:nth(I, static());
entry(I, #hpack{table = Table}) when I - 61 =< length(Table) -> lists:nth(I - 61, Table);
entry(_, _) -> throw({hpack, <<"index out of range">>}).

read_int(B, N) ->
    Skip = 8 - N,
    Max = (1 bsl N) - 1,
    case B of
        <<_:Skip, I:N, Rest/binary>> when I < Max -> {I, Rest};
        <<_:Skip, _:N, Rest/binary>> -> read_int_rest(Rest, Max, 0);
        _ -> throw({hpack, <<"truncated integer">>})
    end.

read_int_rest(_, _, Shift) when Shift > 28 -> throw({hpack, <<"integer overflow">>});
read_int_rest(<<1:1, V:7, Rest/binary>>, Acc, Shift) -> read_int_rest(Rest, Acc + (V bsl Shift), Shift + 7);
read_int_rest(<<0:1, V:7, Rest/binary>>, Acc, Shift) -> {Acc + (V bsl Shift), Rest};
read_int_rest(_, _, _) -> throw({hpack, <<"truncated integer">>}).

read_string(<<H:1, _/bitstring>> = B) ->
    {Length, Rest} = read_int(B, 7),
    case Rest of
        <<S:Length/binary, R/binary>> when H =:= 1 -> {huffman_decode(S), R};
        <<S:Length/binary, R/binary>> -> {S, R};
        _ -> throw({hpack, <<"truncated string">>})
    end;
read_string(_) ->
    throw({hpack, <<"truncated string">>}).

huffman_decode(S) ->
    huffman_decode(S, decode_map(), 0, 0, []).

huffman_decode(<<B:1, Rest/bitstring>>, Map, Code, Len, Acc) ->
    Code1 = Code * 2 + B,
    case Map of
        #{{Len + 1, Code1} := 256} -> throw({hpack, <<"EOS in a string">>});
        #{{Len + 1, Code1} := Sym} -> huffman_decode(Rest, Map, 0, 0, [Sym | Acc]);
        #{} when Len + 1 > 30 -> throw({hpack, <<"bad Huffman code">>});
        #{} -> huffman_decode(Rest, Map, Code1, Len + 1, Acc)
    end;
huffman_decode(<<>>, _, Code, Len, Acc) when Len < 8, Code =:= (1 bsl Len) - 1 ->
    list_to_binary(lists:reverse(Acc));
huffman_decode(<<>>, _, _, _, _) ->
    throw({hpack, <<"bad Huffman padding">>}).

%%% The dynamic table

room(Name, Value) -> byte_size(Name) + byte_size(Value) + ?ENTRY_OVERHEAD.

add({Name, Value} = E, #hpack{table = Table, size = Size, max = Max} = H) ->
    case room(Name, Value) of
        Room when Room > Max -> H#hpack{table = [], size = 0};
        Room -> shrink(H#hpack{table = [E | Table], size = Size + Room})
    end.

shrink(#hpack{size = Size, max = Max, table = Table} = H) when Size > Max, Table =/= [] ->
    {Name, Value} = lists:last(Table),
    shrink(H#hpack{table = lists:droplast(Table), size = Size - room(Name, Value)});
shrink(H) -> H.

static() ->
    [{<<":authority">>, <<>>}, {<<":method">>, <<"GET">>}, {<<":method">>, <<"POST">>}, {<<":path">>, <<"/">>},
     {<<":path">>, <<"/index.html">>}, {<<":scheme">>, <<"http">>}, {<<":scheme">>, <<"https">>},
     {<<":status">>, <<"200">>}, {<<":status">>, <<"204">>}, {<<":status">>, <<"206">>},
     {<<":status">>, <<"304">>}, {<<":status">>, <<"400">>}, {<<":status">>, <<"404">>},
     {<<":status">>, <<"500">>}, {<<"accept-charset">>, <<>>}, {<<"accept-encoding">>, <<"gzip, deflate">>},
     {<<"accept-language">>, <<>>}, {<<"accept-ranges">>, <<>>}, {<<"accept">>, <<>>},
     {<<"access-control-allow-origin">>, <<>>}, {<<"age">>, <<>>}, {<<"allow">>, <<>>},
     {<<"authorization">>, <<>>}, {<<"cache-control">>, <<>>}, {<<"content-disposition">>, <<>>},
     {<<"content-encoding">>, <<>>}, {<<"content-language">>, <<>>}, {<<"content-length">>, <<>>},
     {<<"content-location">>, <<>>}, {<<"content-range">>, <<>>}, {<<"content-type">>, <<>>},
     {<<"cookie">>, <<>>}, {<<"date">>, <<>>}, {<<"etag">>, <<>>}, {<<"expect">>, <<>>}, {<<"expires">>, <<>>},
     {<<"from">>, <<>>}, {<<"host">>, <<>>}, {<<"if-match">>, <<>>}, {<<"if-modified-since">>, <<>>},
     {<<"if-none-match">>, <<>>}, {<<"if-range">>, <<>>}, {<<"if-unmodified-since">>, <<>>},
     {<<"last-modified">>, <<>>}, {<<"link">>, <<>>}, {<<"location">>, <<>>}, {<<"max-forwards">>, <<>>},
     {<<"proxy-authenticate">>, <<>>}, {<<"proxy-authorization">>, <<>>}, {<<"range">>, <<>>},
     {<<"referer">>, <<>>}, {<<"refresh">>, <<>>}, {<<"retry-after">>, <<>>}, {<<"server">>, <<>>},
     {<<"set-cookie">>, <<>>}, {<<"strict-transport-security">>, <<>>}, {<<"transfer-encoding">>, <<>>},
     {<<"user-agent">>, <<>>}, {<<"vary">>, <<>>}, {<<"via">>, <<>>}, {<<"www-authenticate">>, <<>>}].

decode_map() ->
    case persistent_term:get({?MODULE, decode_map}, undefined) of
        undefined ->
            Map = maps:from_list([{{Len, Code}, Sym} || {Sym, {Code, Len}} <- lists:enumerate(0, tuple_to_list(codes()))]),
            persistent_term:put({?MODULE, decode_map}, Map),
            Map;
        Map ->
            Map
    end.

%% The code and the bit length of each symbol, 0 to 256 (EOS), from
%% huff_sym_table of nghttp2_hd_huffman_data.c.
codes() ->
    {{8184,13}, {8388568,23}, {268435426,28}, {268435427,28}, {268435428,28}, {268435429,28}, {268435430,28}, {268435431,28},
      {268435432,28}, {16777194,24}, {1073741820,30}, {268435433,28}, {268435434,28}, {1073741821,30}, {268435435,28}, {268435436,28},
      {268435437,28}, {268435438,28}, {268435439,28}, {268435440,28}, {268435441,28}, {268435442,28}, {1073741822,30}, {268435443,28},
      {268435444,28}, {268435445,28}, {268435446,28}, {268435447,28}, {268435448,28}, {268435449,28}, {268435450,28}, {268435451,28},
      {20,6}, {1016,10}, {1017,10}, {4090,12}, {8185,13}, {21,6}, {248,8}, {2042,11},
      {1018,10}, {1019,10}, {249,8}, {2043,11}, {250,8}, {22,6}, {23,6}, {24,6},
      {0,5}, {1,5}, {2,5}, {25,6}, {26,6}, {27,6}, {28,6}, {29,6},
      {30,6}, {31,6}, {92,7}, {251,8}, {32764,15}, {32,6}, {4091,12}, {1020,10},
      {8186,13}, {33,6}, {93,7}, {94,7}, {95,7}, {96,7}, {97,7}, {98,7},
      {99,7}, {100,7}, {101,7}, {102,7}, {103,7}, {104,7}, {105,7}, {106,7},
      {107,7}, {108,7}, {109,7}, {110,7}, {111,7}, {112,7}, {113,7}, {114,7},
      {252,8}, {115,7}, {253,8}, {8187,13}, {524272,19}, {8188,13}, {16380,14}, {34,6},
      {32765,15}, {3,5}, {35,6}, {4,5}, {36,6}, {5,5}, {37,6}, {38,6},
      {39,6}, {6,5}, {116,7}, {117,7}, {40,6}, {41,6}, {42,6}, {7,5},
      {43,6}, {118,7}, {44,6}, {8,5}, {9,5}, {45,6}, {119,7}, {120,7},
      {121,7}, {122,7}, {123,7}, {32766,15}, {2044,11}, {16381,14}, {8189,13}, {268435452,28},
      {1048550,20}, {4194258,22}, {1048551,20}, {1048552,20}, {4194259,22}, {4194260,22}, {4194261,22}, {8388569,23},
      {4194262,22}, {8388570,23}, {8388571,23}, {8388572,23}, {8388573,23}, {8388574,23}, {16777195,24}, {8388575,23},
      {16777196,24}, {16777197,24}, {4194263,22}, {8388576,23}, {16777198,24}, {8388577,23}, {8388578,23}, {8388579,23},
      {8388580,23}, {2097116,21}, {4194264,22}, {8388581,23}, {4194265,22}, {8388582,23}, {8388583,23}, {16777199,24},
      {4194266,22}, {2097117,21}, {1048553,20}, {4194267,22}, {4194268,22}, {8388584,23}, {8388585,23}, {2097118,21},
      {8388586,23}, {4194269,22}, {4194270,22}, {16777200,24}, {2097119,21}, {4194271,22}, {8388587,23}, {8388588,23},
      {2097120,21}, {2097121,21}, {4194272,22}, {2097122,21}, {8388589,23}, {4194273,22}, {8388590,23}, {8388591,23},
      {1048554,20}, {4194274,22}, {4194275,22}, {4194276,22}, {8388592,23}, {4194277,22}, {4194278,22}, {8388593,23},
      {67108832,26}, {67108833,26}, {1048555,20}, {524273,19}, {4194279,22}, {8388594,23}, {4194280,22}, {33554412,25},
      {67108834,26}, {67108835,26}, {67108836,26}, {134217694,27}, {134217695,27}, {67108837,26}, {16777201,24}, {33554413,25},
      {524274,19}, {2097123,21}, {67108838,26}, {134217696,27}, {134217697,27}, {67108839,26}, {134217698,27}, {16777202,24},
      {2097124,21}, {2097125,21}, {67108840,26}, {67108841,26}, {268435453,28}, {134217699,27}, {134217700,27}, {134217701,27},
      {1048556,20}, {16777203,24}, {1048557,20}, {2097126,21}, {4194281,22}, {2097127,21}, {2097128,21}, {8388595,23},
      {4194282,22}, {4194283,22}, {33554414,25}, {33554415,25}, {16777204,24}, {16777205,24}, {67108842,26}, {8388596,23},
      {67108843,26}, {134217702,27}, {67108844,26}, {67108845,26}, {134217703,27}, {134217704,27}, {134217705,27}, {134217706,27},
      {134217707,27}, {268435454,28}, {134217708,27}, {134217709,27}, {134217710,27}, {134217711,27}, {134217712,27}, {67108846,26},
      {1073741823,30}}.
