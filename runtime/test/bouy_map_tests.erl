-module(bouy_map_tests).

-include_lib("eunit/include/eunit.hrl").

thrown(F) ->
    try F() of
        Value -> {returned, Value}
    catch
        error:{'$throw', #{<<"name">> := Name, <<"message">> := Message}} -> <<Name/binary, ": ", Message/binary>>
    end.

set(Map, Key, Value) -> element(2, bouy_map:mutate(<<"set">>, Map, [Key, Value])).

delete(Map, Key) -> element(2, bouy_map:mutate(<<"delete">>, Map, [Key])).

order_test_() ->
    %% const m = new Map([["a",1]]); m.set("b",2); m.set("a",3); m.delete("b"); m.set("b",4)
    Map = set(delete(set(set(bouy_map:new([[[<<"a">>, 1]]]), <<"b">>, 2), <<"a">>, 3), <<"b">>), <<"b">>, 4),
    Many = lists:foldl(fun(I, Acc) -> set(Acc, 100 - I, I) end, bouy_map:new([]), lists:seq(1, 50)),
    [
        ?_assertEqual([{<<"a">>, 3}, {<<"b">>, 4}], bouy_map:entries(Map)),
        ?_assertEqual(2, bouy_map:get(Map, <<"size">>)),
        ?_assertEqual(3, bouy_map:call(<<"get">>, Map, [<<"a">>])),
        ?_assertNot(bouy_map:call(<<"has">>, Map, [<<"z">>])),
        ?_assertEqual({'$iterator', <<"Map Iterator">>, [<<"a">>, <<"b">>]}, bouy_map:call(<<"keys">>, Map, [])),
        ?_assertEqual({'$iterator', <<"Map Iterator">>, [3, 4]}, bouy_map:call(<<"values">>, Map, [])),
        ?_assertEqual({'$iterator', <<"Map Entries">>, [[<<"a">>, 3], [<<"b">>, 4]]}, bouy_map:call(<<"entries">>, Map, [])),
        ?_assertEqual([100 - I || I <- lists:seq(1, 50)], bouy_rt:to_list(bouy_map:call(<<"keys">>, Many, [])))
    ].

keys_test_() ->
    %% m.set(1,"int"); m.set(1.0,"float"); m.set(-0,"nz"); m.set(NaN,"n1"); m.set(NaN,"n2")
    Map = lists:foldl(fun({K, V}, Acc) -> set(Acc, K, V) end, bouy_map:new([]), [
        {1, <<"int">>}, {1.0, <<"float">>}, {-0.0, <<"nz">>}, {'NaN', <<"n1">>}, {'NaN', <<"n2">>}
    ]),
    [
        ?_assertEqual([{1, <<"float">>}, {0, <<"nz">>}, {'NaN', <<"n2">>}], bouy_map:entries(Map)),
        ?_assertEqual(<<"nz">>, bouy_map:call(<<"get">>, Map, [0])),
        ?_assertEqual(<<"float">>, bouy_map:call(<<"get">>, Map, [1.0])),
        ?_assertEqual(undefined, bouy_map:call(<<"get">>, Map, [<<"1">>])),
        ?_assert(bouy_map:call(<<"has">>, set(bouy_map:new([]), [1, 2], x), [[1, 2]]))
    ].

mutate_test_() ->
    Map = bouy_map:new([[[a, 1]]]),
    [
        ?_assertMatch({{'$map', _}, {'$map', _}}, bouy_map:mutate(<<"set">>, Map, [b, 2])),
        ?_assertMatch({true, _}, bouy_map:mutate(<<"delete">>, Map, [a])),
        ?_assertMatch({false, _}, bouy_map:mutate(<<"delete">>, Map, [z])),
        ?_assertEqual(0, bouy_map:get(element(2, bouy_map:mutate(<<"clear">>, Map, [])), <<"size">>)),
        ?_assertEqual({1, Map}, bouy_map:mutate(<<"get">>, Map, [a])),
        %% A chained `set` on a value that is not a place returns the new Map.
        ?_assertEqual(2, bouy_map:get(bouy_map:call(<<"set">>, Map, [b, 2]), <<"size">>)),
        ?_assert(bouy_map:call(<<"delete">>, Map, [a]))
    ].

for_each_test_() ->
    Map = bouy_map:new([[[k1, v1], [k2, v2]]]),
    Self = self(),
    [
        ?_assertEqual(
            [{v1, k1}, {v2, k2}],
            begin
                undefined = bouy_map:call(<<"forEach">>, Map, [fun([V, K, M]) -> Self ! {V, K, M =:= Map} end]),
                [receive {V, K, true} -> {V, K} end || _ <- [1, 2]]
            end
        )
    ].

new_test_() ->
    [
        ?_assertEqual([], bouy_map:entries(bouy_map:new([]))),
        ?_assertEqual([], bouy_map:entries(bouy_map:new([undefined]))),
        ?_assertEqual([{a, 1}], bouy_map:entries(bouy_map:new([bouy_map:new([[[a, 1]]])]))),
        ?_assertEqual(<<"TypeError: Iterator value 1 is not an entry object">>, thrown(fun() -> bouy_map:new([[1]]) end)),
        %% node -e 'console.log(Map.groupBy([1, 2, 3], (x) => x % 2))'
        ?_assertEqual([{1, [1, 3]}, {0, [2]}], bouy_map:entries(bouy_rt:call(bouy_map:'$member'(<<"groupBy">>), [[1, 2, 3], fun([X | _]) -> X rem 2 end]))),
        ?_assertEqual(undefined, bouy_map:get(bouy_map:new([]), <<"length">>)),
        ?_assertEqual(<<"TypeError: Map(0) {}.push is not a function">>, thrown(fun() -> bouy_map:call(<<"push">>, bouy_map:new([]), []) end))
    ].
