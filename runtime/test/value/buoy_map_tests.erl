-module(buoy_map_tests).

-include_lib("eunit/include/eunit.hrl").

thrown(F) ->
    try F() of
        Value -> {returned, Value}
    catch
        error:{'$throw', #{<<"name">> := Name, <<"message">> := Message}} -> <<Name/binary, ": ", Message/binary>>
    end.

set(Map, Key, Value) -> element(2, buoy_map:mutate(<<"set">>, Map, [Key, Value])).

delete(Map, Key) -> element(2, buoy_map:mutate(<<"delete">>, Map, [Key])).

order_test_() ->
    %% const m = new Map([["a",1]]); m.set("b",2); m.set("a",3); m.delete("b"); m.set("b",4)
    Map = set(delete(set(set(buoy_map:new([[[<<"a">>, 1]]]), <<"b">>, 2), <<"a">>, 3), <<"b">>), <<"b">>, 4),
    Many = lists:foldl(fun(I, Acc) -> set(Acc, 100 - I, I) end, buoy_map:new([]), lists:seq(1, 50)),
    [
        ?_assertEqual([{<<"a">>, 3}, {<<"b">>, 4}], buoy_map:entries(Map)),
        ?_assertEqual(2, buoy_map:get(Map, <<"size">>)),
        ?_assertEqual(3, buoy_map:call(<<"get">>, Map, [<<"a">>])),
        ?_assertNot(buoy_map:call(<<"has">>, Map, [<<"z">>])),
        ?_assertEqual({'$iterator', <<"Map Iterator">>, [<<"a">>, <<"b">>]}, buoy_map:call(<<"keys">>, Map, [])),
        ?_assertEqual({'$iterator', <<"Map Iterator">>, [3, 4]}, buoy_map:call(<<"values">>, Map, [])),
        ?_assertEqual({'$iterator', <<"Map Entries">>, [[<<"a">>, 3], [<<"b">>, 4]]}, buoy_map:call(<<"entries">>, Map, [])),
        ?_assertEqual([100 - I || I <- lists:seq(1, 50)], buoy_rt:to_list(buoy_map:call(<<"keys">>, Many, [])))
    ].

keys_test_() ->
    %% m.set(1,"int"); m.set(1.0,"float"); m.set(-0,"nz"); m.set(NaN,"n1"); m.set(NaN,"n2")
    Map = lists:foldl(fun({K, V}, Acc) -> set(Acc, K, V) end, buoy_map:new([]), [
        {1, <<"int">>}, {1.0, <<"float">>}, {-0.0, <<"nz">>}, {'NaN', <<"n1">>}, {'NaN', <<"n2">>}
    ]),
    [
        ?_assertEqual([{1, <<"float">>}, {0, <<"nz">>}, {'NaN', <<"n2">>}], buoy_map:entries(Map)),
        ?_assertEqual(<<"nz">>, buoy_map:call(<<"get">>, Map, [0])),
        ?_assertEqual(<<"float">>, buoy_map:call(<<"get">>, Map, [1.0])),
        ?_assertEqual(undefined, buoy_map:call(<<"get">>, Map, [<<"1">>])),
        ?_assert(buoy_map:call(<<"has">>, set(buoy_map:new([]), [1, 2], x), [[1, 2]]))
    ].

mutate_test_() ->
    Map = buoy_map:new([[[a, 1]]]),
    [
        ?_assertMatch({{'$map', _}, {'$map', _}}, buoy_map:mutate(<<"set">>, Map, [b, 2])),
        ?_assertMatch({true, _}, buoy_map:mutate(<<"delete">>, Map, [a])),
        ?_assertMatch({false, _}, buoy_map:mutate(<<"delete">>, Map, [z])),
        ?_assertEqual(0, buoy_map:get(element(2, buoy_map:mutate(<<"clear">>, Map, [])), <<"size">>)),
        ?_assertEqual({1, Map}, buoy_map:mutate(<<"get">>, Map, [a])),
        %% A chained `set` on a value that is not a place returns the new Map.
        ?_assertEqual(2, buoy_map:get(buoy_map:call(<<"set">>, Map, [b, 2]), <<"size">>)),
        ?_assert(buoy_map:call(<<"delete">>, Map, [a]))
    ].

for_each_test_() ->
    Map = buoy_map:new([[[k1, v1], [k2, v2]]]),
    Self = self(),
    [
        ?_assertEqual(
            [{v1, k1}, {v2, k2}],
            begin
                undefined = buoy_map:call(<<"forEach">>, Map, [fun([V, K, M]) -> Self ! {V, K, M =:= Map} end]),
                [receive {V, K, true} -> {V, K} end || _ <- [1, 2]]
            end
        )
    ].

new_test_() ->
    [
        ?_assertEqual([], buoy_map:entries(buoy_map:new([]))),
        ?_assertEqual([], buoy_map:entries(buoy_map:new([undefined]))),
        ?_assertEqual([{a, 1}], buoy_map:entries(buoy_map:new([buoy_map:new([[[a, 1]]])]))),
        ?_assertEqual(<<"TypeError: Iterator value 1 is not an entry object">>, thrown(fun() -> buoy_map:new([[1]]) end)),
        %% node -e 'console.log(Map.groupBy([1, 2, 3], (x) => x % 2))'
        ?_assertEqual([{1, [1, 3]}, {0, [2]}], buoy_map:entries(buoy_rt:call(buoy_map:'$member'(<<"groupBy">>), [[1, 2, 3], fun([X | _]) -> X rem 2 end]))),
        ?_assertEqual(undefined, buoy_map:get(buoy_map:new([]), <<"length">>)),
        ?_assertEqual(<<"TypeError: Map(0) {}.push is not a function">>, thrown(fun() -> buoy_map:call(<<"push">>, buoy_map:new([]), []) end))
    ].
