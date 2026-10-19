-module(buoy_console_tests).

-include_lib("eunit/include/eunit.hrl").

%% Arguments and the line Node prints for them, generated with util.format.
node_cases() ->
    [
        {[1], <<"1"/utf8>>},
        {[1.5e0], <<"1.5"/utf8>>},
        {[-0.0], <<"-0"/utf8>>},
        {['NaN'], <<"NaN"/utf8>>},
        {['Infinity'], <<"Infinity"/utf8>>},
        {['-Infinity'], <<"-Infinity"/utf8>>},
        {[3.0000000000000004e-1], <<"0.30000000000000004"/utf8>>},
        {[1.0e21], <<"1e+21"/utf8>>},
        {[1.5e-7], <<"1.5e-7"/utf8>>},
        {[1.2345678901234568e20], <<"123456789012345680000"/utf8>>},
        {[5.0e-324], <<"5e-324"/utf8>>},
        {[9007199254740992], <<"9007199254740992"/utf8>>},
        {[<<"plain"/utf8>>], <<"plain"/utf8>>},
        {[<<""/utf8>>], <<""/utf8>>},
        {[<<"a"/utf8>>, <<"b"/utf8>>], <<"a b"/utf8>>},
        {[1, <<"a"/utf8>>, true, null, undefined], <<"1 a true null undefined"/utf8>>},
        {[[]], <<"[]"/utf8>>},
        {[#{}], <<"{}"/utf8>>},
        {[[1, 2, 3]], <<"[ 1, 2, 3 ]"/utf8>>},
        {[[<<"a"/utf8>>, <<"it's"/utf8>>, <<"say \"hi\""/utf8>>, <<"both ' and \""/utf8>>, <<"a\x{a}b"/utf8>>, <<"tab\x{9}"/utf8>>, <<"\x{1}\x{7f}\x{85}\x{e9}\x{1f600}"/utf8>>]], <<"[\x{a}  'a',\x{a}  \"it's\",\x{a}  'say \"hi\"',\x{a}  `both ' and \"`,\x{a}  'a\\nb',\x{a}  'tab\\t',\x{a}  '\\x01\\x7F\\x85\x{e9}\x{1f600}'\x{a}]"/utf8>>},
        {[#{<<"a"/utf8>> => 1, <<"b"/utf8>> => <<"x"/utf8>>, <<"c"/utf8>> => [1, 2, 3], <<"d"/utf8>> => #{<<"e"/utf8>> => #{<<"f"/utf8>> => #{<<"g"/utf8>> => 1}}}}], <<"{ a: 1, b: 'x', c: [ 1, 2, 3 ], d: { e: { f: [Object] } } }"/utf8>>},
        {[[[1, [2, [3, [4]]]]]], <<"[ [ 1, [ 2, [Array] ] ] ]"/utf8>>},
        {[#{<<"a"/utf8>> => #{<<"b"/utf8>> => #{<<"c"/utf8>> => #{<<"d"/utf8>> => #{}}}}}], <<"{ a: { b: { c: [Object] } } }"/utf8>>},
        {[#{<<"a"/utf8>> => #{<<"b"/utf8>> => #{<<"c"/utf8>> => []}}}], <<"{ a: { b: { c: [] } } }"/utf8>>},
        {[#{<<"a"/utf8>> => #{<<"b"/utf8>> => #{<<"c"/utf8>> => [1]}}}], <<"{ a: { b: { c: [Array] } } }"/utf8>>},
        {[#{<<"aaaaaaaaaa"/utf8>> => 1111111111, <<"bbbbbbbbbb"/utf8>> => 2222222222, <<"cccccccccc"/utf8>> => 3333333333, <<"dddddddddd"/utf8>> => 4444444444}], <<"{\x{a}  aaaaaaaaaa: 1111111111,\x{a}  bbbbbbbbbb: 2222222222,\x{a}  cccccccccc: 3333333333,\x{a}  dddddddddd: 4444444444\x{a}}"/utf8>>},
        {[#{<<"x"/utf8>> => #{<<"aaaaaaaaaa"/utf8>> => 1111111111, <<"bbbbbbbbbb"/utf8>> => 2222222222, <<"cccccccccc"/utf8>> => 3333333333, <<"dddddddddd"/utf8>> => 4444444444}}], <<"{\x{a}  x: {\x{a}    aaaaaaaaaa: 1111111111,\x{a}    bbbbbbbbbb: 2222222222,\x{a}    cccccccccc: 3333333333,\x{a}    dddddddddd: 4444444444\x{a}  }\x{a}}"/utf8>>},
        {[[#{<<"aaaaaaaaaa"/utf8>> => 1111111111, <<"bbbbbbbbbb"/utf8>> => 2222222222, <<"cccccccccc"/utf8>> => 3333333333, <<"dddddddddd"/utf8>> => 4444444444}, #{<<"aaaaaaaaaa"/utf8>> => 1111111111, <<"bbbbbbbbbb"/utf8>> => 2222222222, <<"cccccccccc"/utf8>> => 3333333333, <<"dddddddddd"/utf8>> => 4444444444}]], <<"[\x{a}  {\x{a}    aaaaaaaaaa: 1111111111,\x{a}    bbbbbbbbbb: 2222222222,\x{a}    cccccccccc: 3333333333,\x{a}    dddddddddd: 4444444444\x{a}  },\x{a}  {\x{a}    aaaaaaaaaa: 1111111111,\x{a}    bbbbbbbbbb: 2222222222,\x{a}    cccccccccc: 3333333333,\x{a}    dddddddddd: 4444444444\x{a}  }\x{a}]"/utf8>>},
        {[[1, 2, 3, 4, 5, 6]], <<"[ 1, 2, 3, 4, 5, 6 ]"/utf8>>},
        {[[1, 2, 3, 4, 5, 6, 7]], <<"[\x{a}  1, 2, 3, 4,\x{a}  5, 6, 7\x{a}]"/utf8>>},
        {[[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27]], <<"[\x{a}   1,  2,  3,  4,  5,  6,  7,  8,\x{a}   9, 10, 11, 12, 13, 14, 15, 16,\x{a}  17, 18, 19, 20, 21, 22, 23, 24,\x{a}  25, 26, 27\x{a}]"/utf8>>},
        {[[<<"a"/utf8>>, <<"b"/utf8>>, <<"c"/utf8>>, <<"d"/utf8>>, <<"e"/utf8>>, <<"f"/utf8>>, <<"g"/utf8>>]], <<"[\x{a}  'a', 'b', 'c',\x{a}  'd', 'e', 'f',\x{a}  'g'\x{a}]"/utf8>>},
        {[[<<"aaaaaaaaaaaaaaaaaaaa"/utf8>>, <<"bbbbbbbbbbbbbbbbbbbbbbbb"/utf8>>, <<"cccccccccccccccccccccc"/utf8>>, <<"dddd"/utf8>>]], <<"[\x{a}  'aaaaaaaaaaaaaaaaaaaa',\x{a}  'bbbbbbbbbbbbbbbbbbbbbbbb',\x{a}  'cccccccccccccccccccccc',\x{a}  'dddd'\x{a}]"/utf8>>},
        {[[1.5e0, -2, 300, 'NaN', 4, 5, 6, 7, 8]], <<"[\x{a}  1.5, -2, 300, NaN, 4,\x{a}    5,  6,   7,   8\x{a}]"/utf8>>},
        {[[true, false, null, undefined, 1, <<"a"/utf8>>, 2]], <<"[ true, false, null, undefined, 1, 'a', 2 ]"/utf8>>},
        {[[#{<<"id"/utf8>> => 0}, #{<<"id"/utf8>> => 1}, #{<<"id"/utf8>> => 2}, #{<<"id"/utf8>> => 3}, #{<<"id"/utf8>> => 4}, #{<<"id"/utf8>> => 5}, #{<<"id"/utf8>> => 6}, #{<<"id"/utf8>> => 7}, #{<<"id"/utf8>> => 8}, #{<<"id"/utf8>> => 9}, #{<<"id"/utf8>> => 10}, #{<<"id"/utf8>> => 11}]], <<"[\x{a}  { id: 0 },  { id: 1 },\x{a}  { id: 2 },  { id: 3 },\x{a}  { id: 4 },  { id: 5 },\x{a}  { id: 6 },  { id: 7 },\x{a}  { id: 8 },  { id: 9 },\x{a}  { id: 10 }, { id: 11 }\x{a}]"/utf8>>},
        {[[[0, 0], [1, 2], [2, 4], [3, 6], [4, 8], [5, 10], [6, 12], [7, 14]]], <<"[\x{a}  [ 0, 0 ],  [ 1, 2 ],\x{a}  [ 2, 4 ],  [ 3, 6 ],\x{a}  [ 4, 8 ],  [ 5, 10 ],\x{a}  [ 6, 12 ], [ 7, 14 ]\x{a}]"/utf8>>},
        {[#{<<"list"/utf8>> => [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], <<"name"/utf8>> => <<"nested"/utf8>>}], <<"{\x{a}  list: [\x{a}    0, 1, 2, 3, 4,\x{a}    5, 6, 7, 8, 9\x{a}  ],\x{a}  name: 'nested'\x{a}}"/utf8>>},
        {[#{<<"deep"/utf8>> => #{<<"list"/utf8>> => [0, 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000, 11000, 12000, 13000, 14000, 15000, 16000, 17000, 18000, 19000, 20000, 21000, 22000, 23000, 24000, 25000]}}], <<"{\x{a}  deep: {\x{a}    list: [\x{a}          0,  1000,  2000,  3000,\x{a}       4000,  5000,  6000,  7000,\x{a}       8000,  9000, 10000, 11000,\x{a}      12000, 13000, 14000, 15000,\x{a}      16000, 17000, 18000, 19000,\x{a}      20000, 21000, 22000, 23000,\x{a}      24000, 25000\x{a}    ]\x{a}  }\x{a}}"/utf8>>},
        {[buoy_map:new([[[<<"a"/utf8>>, 1], [<<"b"/utf8>>, #{<<"x"/utf8>> => 1}]]])], <<"Map(2) { 'a' => 1, 'b' => { x: 1 } }"/utf8>>},
        {[buoy_set:new([[1, <<"a"/utf8>>]])], <<"Set(2) { 1, 'a' }"/utf8>>},
        {[buoy_map:new([[]])], <<"Map(0) {}"/utf8>>},
        {[buoy_set:new([[]])], <<"Set(0) {}"/utf8>>},
        {[buoy_map:new([[[1, buoy_map:new([[[2, buoy_map:new([[[3, buoy_map:new([[[4, 5]]])]]])]]])]]])], <<"Map(1) { 1 => Map(1) { 2 => Map(1) { 3 => [Map] } } }"/utf8>>},
        {[#{<<"m"/utf8>> => buoy_set:new([[[1, 2], #{<<"a"/utf8>> => 1}]])}], <<"{ m: Set(2) { [ 1, 2 ], { a: 1 } } }"/utf8>>},
        {[buoy_map:new([[[<<"key0"/utf8>>, <<"value number 0"/utf8>>], [<<"key1"/utf8>>, <<"value number 1"/utf8>>], [<<"key2"/utf8>>, <<"value number 2"/utf8>>], [<<"key3"/utf8>>, <<"value number 3"/utf8>>], [<<"key4"/utf8>>, <<"value number 4"/utf8>>], [<<"key5"/utf8>>, <<"value number 5"/utf8>>], [<<"key6"/utf8>>, <<"value number 6"/utf8>>], [<<"key7"/utf8>>, <<"value number 7"/utf8>>]]])], <<"Map(8) {\x{a}  'key0' => 'value number 0',\x{a}  'key1' => 'value number 1',\x{a}  'key2' => 'value number 2',\x{a}  'key3' => 'value number 3',\x{a}  'key4' => 'value number 4',\x{a}  'key5' => 'value number 5',\x{a}  'key6' => 'value number 6',\x{a}  'key7' => 'value number 7'\x{a}}"/utf8>>},
        {[buoy_set:new([[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29]])], <<"Set(30) {\x{a}  0,\x{a}  1,\x{a}  2,\x{a}  3,\x{a}  4,\x{a}  5,\x{a}  6,\x{a}  7,\x{a}  8,\x{a}  9,\x{a}  10,\x{a}  11,\x{a}  12,\x{a}  13,\x{a}  14,\x{a}  15,\x{a}  16,\x{a}  17,\x{a}  18,\x{a}  19,\x{a}  20,\x{a}  21,\x{a}  22,\x{a}  23,\x{a}  24,\x{a}  25,\x{a}  26,\x{a}  27,\x{a}  28,\x{a}  29\x{a}}"/utf8>>},
        {[{'$date', 0}], <<"1970-01-01T00:00:00.000Z"/utf8>>},
        {[#{<<"when"/utf8>> => {'$date', 86400000}}], <<"{ when: 1970-01-02T00:00:00.000Z }"/utf8>>},
        {[<<"%s is %d years"/utf8>>, <<"Bob"/utf8>>, 42, <<"extra"/utf8>>, #{<<"a"/utf8>> => 1}], <<"Bob is 42 years extra { a: 1 }"/utf8>>},
        {[<<"%%"/utf8>>, <<"x"/utf8>>], <<"% x"/utf8>>},
        {[<<"a%%b"/utf8>>], <<"a%%b"/utf8>>},
        {[<<"%c styled"/utf8>>, <<"color: red"/utf8>>], <<" styled"/utf8>>},
        {[<<"%j %O %i %f"/utf8>>, #{<<"a"/utf8>> => 1}, #{<<"b"/utf8>> => 2}, <<"42.5px"/utf8>>, <<"3.5x"/utf8>>], <<"{\"a\":1} { b: 2 } 42 3.5"/utf8>>},
        {[<<"%s"/utf8>>, #{<<"a"/utf8>> => #{<<"b"/utf8>> => 1}}], <<"{ a: [Object] }"/utf8>>},
        {[<<"%s"/utf8>>, [1, [2, [3]]]], <<"[ 1, [Array] ]"/utf8>>},
        {[<<"%s %s"/utf8>>, -0.0, 5], <<"-0 5"/utf8>>},
        {[<<"%d"/utf8>>, <<"12"/utf8>>], <<"12"/utf8>>},
        {[<<"%d %d"/utf8>>, #{}, -0.0], <<"NaN -0"/utf8>>},
        {[<<"100%"/utf8>>, 5], <<"100% 5"/utf8>>},
        {[<<"%x %s"/utf8>>, <<"a"/utf8>>], <<"%x a"/utf8>>},
        {[<<"%s"/utf8>>], <<"%s"/utf8>>},
        {[<<"trailing %"/utf8>>, 1], <<"trailing % 1"/utf8>>},
        {[<<"%s:%s"/utf8>>, <<"a"/utf8>>], <<"a:%s"/utf8>>},
        {[#{<<"s"/utf8>> => <<"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"/utf8>>}], <<"{\x{a}  s: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'\x{a}}"/utf8>>},
        {[#{<<"s"/utf8>> => <<"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"/utf8>>, <<"t"/utf8>> => 1}], <<"{\x{a}  s: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',\x{a}  t: 1\x{a}}"/utf8>>},
        {[[<<"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"/utf8>>]], <<"[\x{a}  'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'\x{a}]"/utf8>>},
        {[[<<"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"/utf8>>]], <<"[\x{a}  'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'\x{a}]"/utf8>>},
        {[#{<<"a"/utf8>> => <<"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"/utf8>>}], <<"{ a: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' }"/utf8>>},
        {[#{<<"a"/utf8>> => <<"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"/utf8>>}], <<"{ a: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' }"/utf8>>},
        {[#{<<"a"/utf8>> => <<"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"/utf8>>}], <<"{ a: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' }"/utf8>>},
        {[#{<<"a"/utf8>> => [1, 2, #{<<"b"/utf8>> => <<"cccccccccccccccccccccccccccccccccccccccccccccccccc"/utf8>>}]}], <<"{\x{a}  a: [ 1, 2, { b: 'cccccccccccccccccccccccccccccccccccccccccccccccccc' } ]\x{a}}"/utf8>>},
        {[#{<<"outer"/utf8>> => #{<<"inner"/utf8>> => #{<<"a"/utf8>> => 1, <<"b"/utf8>> => <<"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"/utf8>>}}}], <<"{\x{a}  outer: {\x{a}    inner: {\x{a}      a: 1,\x{a}      b: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'\x{a}    }\x{a}  }\x{a}}"/utf8>>}
    ].

node_format_test_() ->
    [?_assertEqual(Expected, buoy_console:format(Args)) || {Args, Expected} <- node_cases()].

%% Errors print `Name: message` and their own fields, without stack frames.
error_test_() ->
    Plain = buoy_error:new(<<"Error">>, <<"boom">>),
    Coded = buoy_error:new(<<"Error">>, <<"boom">>, #{<<"code">> => <<"E1">>}),
    Caused = buoy_error:'Error#new'([<<"outer">>, #{<<"cause">> => <<"why">>}]),
    [
        ?_assertEqual(<<"Error: boom">>, buoy_console:format([Plain])),
        ?_assertEqual(<<"Error: boom { code: 'E1' }">>, buoy_console:format([Coded])),
        ?_assertEqual(<<"{ err: Error: boom { code: 'E1' } }">>, buoy_console:format([#{<<"err">> => Coded}])),
        ?_assertEqual(<<"Error: outer { [cause]: 'why' }">>, buoy_console:format([Caused])),
        ?_assertEqual(<<"Error">>, buoy_console:format([buoy_error:new(<<"Error">>, <<>>)])),
        ?_assertEqual(<<"{ a: { b: { c: [Error: deep] } } }">>, buoy_console:format([#{<<"a">> => #{<<"b">> => #{<<"c">> => Coded#{<<"message">> => <<"deep">>}}}}]))
    ].

other_values_test_() ->
    [
        ?_assertEqual(<<"[Function: format]">>, buoy_console:format([fun buoy_console:format/1])),
        ?_assertEqual(<<"[Function (anonymous)]">>, buoy_console:format([fun(_) -> ok end])),
        ?_assertEqual(<<"[class Counter]">>, buoy_console:format([{'$class', m, <<"Counter">>}])),
        ?_assertEqual(<<"Object [Math] {}">>, buoy_console:format([{'$namespace', buoy_math}])),
        ?_assertEqual(<<"[Function: Map]">>, buoy_console:format([{'$namespace', buoy_map}])),
        ?_assertEqual(<<"[ActorRef #3]">>, buoy_console:format([{'$ref', 3}])),
        ?_assertEqual(<<"Invalid Date">>, buoy_console:format([{'$date', 'NaN'}])),
        ?_assertEqual(<<"">>, buoy_console:format([])),
        ?_assertEqual(<<"'x'">>, buoy_console:inspect(<<"x">>)),
        ?_assertEqual(<<"{ a: [Object] }">>, buoy_console:inspect(#{<<"a">> => #{<<"b">> => 1}}, 0)),
        ?_assertEqual(<<"format">>, buoy_console:function_name(fun buoy_console:format/1)),
        ?_assertEqual(<<"">>, buoy_console:function_name(fun(_) -> ok end))
    ].

%% Collects what a process writes through its group leader.
capture(Fun) ->
    Self = self(),
    Leader = spawn_link(fun() -> io_server(Self, []) end),
    Old = group_leader(),
    group_leader(Leader, self()),
    try
        Fun()
    after
        group_leader(Old, self())
    end,
    Leader ! {done, Self},
    receive
        {output, Output} -> Output
    end.

io_server(Owner, Acc) ->
    receive
        {io_request, From, Ref, {put_chars, unicode, Chars}} ->
            From ! {io_reply, Ref, ok},
            io_server(Owner, [unicode:characters_to_binary(Chars) | Acc]);
        {io_request, From, Ref, {put_chars, unicode, M, F, A}} ->
            From ! {io_reply, Ref, ok},
            io_server(Owner, [unicode:characters_to_binary(apply(M, F, A)) | Acc]);
        {io_request, From, Ref, getopts} ->
            From ! {io_reply, Ref, [{encoding, unicode}]},
            io_server(Owner, Acc);
        {io_request, From, Ref, _} ->
            From ! {io_reply, Ref, {error, request}},
            io_server(Owner, Acc);
        {done, Owner} ->
            Owner ! {output, iolist_to_binary(lists:reverse(Acc))}
    end.

write_test_() ->
    [
        ?_assertEqual(<<"héllo 😀 [ 1, 'é' ]\n"/utf8>>, capture(fun() -> undefined = buoy_console:log([<<"héllo 😀"/utf8>>, [1, <<"é"/utf8>>]]) end)),
        ?_assertEqual(<<"a\nb\n">>, capture(fun() -> buoy_console:info([<<"a">>]), buoy_console:debug([<<"b">>]) end)),
        ?_assertEqual(<<"\n">>, capture(fun() -> buoy_console:log([]) end))
    ].

members_test_() ->
    [
        ?_assertEqual(fun buoy_console:log/1, buoy_console:'$member'(<<"log">>)),
        ?_assertEqual(fun buoy_console:error/1, buoy_console:'$member'(<<"error">>)),
        ?_assertEqual(undefined, buoy_console:'$member'(<<"table">>))
    ].

%% Node lays text out by UTF-16 length for line breaks and by terminal
%% columns for array groups: node -e 'console.log({ a: "😀".repeat(20), b: "😀".repeat(19) })'
width_test_() ->
    Emoji = fun(N) -> binary:copy(<<"😀"/utf8>>, N) end,
    Cities = [<<"東京"/utf8>>, <<"大阪"/utf8>>, <<"京都"/utf8>>, <<"札幌"/utf8>>, <<"福岡"/utf8>>, <<"神戸"/utf8>>, <<"横浜"/utf8>>, <<"名古屋"/utf8>>, <<"仙台"/utf8>>, <<"広島"/utf8>>],
    [
        ?_assertEqual(<<"{\n  a: '", (Emoji(20))/binary, "',\n  b: '", (Emoji(19))/binary, "'\n}">>, buoy_console:format([#{<<"a">> => Emoji(20), <<"b">> => Emoji(19)}])),
        ?_assertEqual(
            <<"[\n  '東京', '大阪',\n  '京都', '札幌',\n  '福岡', '神戸',\n  '横浜', '名古屋',\n  '仙台', '広島'\n]"/utf8>>,
            buoy_console:format([Cities])
        )
    ].

%% `%o` shows hidden properties at depth 4, and a nested string is cut
%% after 10000 code units.
hidden_test_() ->
    Long = binary:copy(<<"x">>, 10001),
    [
        ?_assertEqual(<<"[ 1, 2, [length]: 2 ]">>, buoy_console:format([<<"%o">>, [1, 2]])),
        ?_assertEqual(<<"[ [length]: 0 ]">>, buoy_console:format([<<"%o">>, []])),
        ?_assertEqual(<<"[\n  '", (binary:copy(<<"x">>, 10000))/binary, "'... 1 more character\n]">>, buoy_console:format([[Long]])),
        ?_assertEqual(Long, buoy_console:format([Long])),
        ?_assertEqual(<<"{ ['__proto__']: 1 }">>, buoy_console:format([#{<<"__proto__">> => 1}]))
    ].

runtime_values_test_() ->
    Map = buoy_map:new([[[<<"a">>, 1]]]),
    [
        ?_assertEqual(<<"[Schedule]">>, buoy_console:format([{'$schedule', self()}])),
        ?_assertEqual(<<"[Map Iterator] { 'a' }">>, buoy_console:format([buoy_rt:call_method(Map, <<"keys">>, [])])),
        ?_assertEqual(<<"[Map Entries] { [ 'a', 1 ] }">>, buoy_console:format([buoy_rt:call_method(Map, <<"entries">>, [])])),
        ?_assertEqual(<<"[Map Iterator] {  }">>, buoy_console:format([buoy_rt:call_method(buoy_map:new([]), <<"keys">>, [])])),
        ?_assertEqual(<<"Object [Array Iterator] {}">>, buoy_console:format([buoy_rt:call_method([1], <<"keys">>, [])])),
        ?_assertEqual(<<"[Function: map]">>, buoy_console:format([buoy_rt:get([], <<"map">>)])),
        ?_assertEqual(<<"[Object: null prototype] {}">>, buoy_console:format([buoy_object:'$member'(<<"prototype">>)]))
    ].
