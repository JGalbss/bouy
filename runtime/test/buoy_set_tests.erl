-module(buoy_set_tests).

-include_lib("eunit/include/eunit.hrl").

add(Set, Item) -> element(2, buoy_set:mutate(<<"add">>, Set, [Item])).

delete(Set, Item) -> element(2, buoy_set:mutate(<<"delete">>, Set, [Item])).

order_test_() ->
    %% const s = new Set([3, 1, 3, 2]); s.add(1); s.delete(3); s.add(3)
    Set = add(delete(add(buoy_set:new([[3, 1, 3, 2]]), 1), 3), 3),
    [
        ?_assertEqual([1, 2, 3], buoy_set:items(Set)),
        ?_assertEqual(3, buoy_set:get(Set, <<"size">>)),
        ?_assert(buoy_set:call(<<"has">>, Set, [2])),
        ?_assert(buoy_set:call(<<"has">>, Set, [2.0])),
        ?_assertNot(buoy_set:call(<<"has">>, Set, [<<"2">>])),
        ?_assertEqual({'$iterator', <<"Set Iterator">>, [1, 2, 3]}, buoy_set:call(<<"values">>, Set, [])),
        ?_assertEqual({'$iterator', <<"Set Iterator">>, [1, 2, 3]}, buoy_set:call(<<"keys">>, Set, [])),
        ?_assertEqual({'$iterator', <<"Set Entries">>, [[1, 1], [2, 2], [3, 3]]}, buoy_set:call(<<"entries">>, Set, []))
    ].

members_test_() ->
    Set = buoy_set:new([[1, 1.0, -0.0, 0, 'NaN', 'NaN', <<"a">>, [1]]]),
    [
        ?_assertEqual([1, 0, 'NaN', <<"a">>, [1]], buoy_set:items(Set)),
        ?_assertEqual([<<"a">>, <<"b">>], buoy_set:items(buoy_set:new([<<"aba">>]))),
        ?_assertEqual([], buoy_set:items(buoy_set:new([null])))
    ].

mutate_test_() ->
    Set = buoy_set:new([[a]]),
    [
        ?_assertMatch({true, {'$set', _} = Empty} when Empty =/= Set, buoy_set:mutate(<<"delete">>, Set, [a])),
        ?_assertEqual([], buoy_set:items(element(2, buoy_set:mutate(<<"delete">>, Set, [a])))),
        ?_assertEqual({false, Set}, buoy_set:mutate(<<"delete">>, Set, [b])),
        ?_assertEqual(Set, add(Set, a)),
        ?_assertEqual(0, buoy_set:get(element(2, buoy_set:mutate(<<"clear">>, Set, [])), <<"size">>)),
        ?_assertEqual({true, Set}, buoy_set:mutate(<<"has">>, Set, [a])),
        ?_assertEqual(2, buoy_set:get(buoy_set:call(<<"add">>, Set, [b]), <<"size">>))
    ].

for_each_test_() ->
    Set = buoy_set:new([[x, y]]),
    Self = self(),
    [
        ?_assertEqual(
            [x, y],
            begin
                undefined = buoy_set:call(<<"forEach">>, Set, [fun([V, V, S]) -> Self ! {V, S =:= Set} end]),
                [receive {V, true} -> V end || _ <- [1, 2]]
            end
        )
    ].
