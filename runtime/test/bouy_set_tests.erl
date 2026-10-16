-module(bouy_set_tests).

-include_lib("eunit/include/eunit.hrl").

add(Set, Item) -> element(2, bouy_set:mutate(<<"add">>, Set, [Item])).

delete(Set, Item) -> element(2, bouy_set:mutate(<<"delete">>, Set, [Item])).

order_test_() ->
    %% const s = new Set([3, 1, 3, 2]); s.add(1); s.delete(3); s.add(3)
    Set = add(delete(add(bouy_set:new([[3, 1, 3, 2]]), 1), 3), 3),
    [
        ?_assertEqual([1, 2, 3], bouy_set:items(Set)),
        ?_assertEqual(3, bouy_set:get(Set, <<"size">>)),
        ?_assert(bouy_set:call(<<"has">>, Set, [2])),
        ?_assert(bouy_set:call(<<"has">>, Set, [2.0])),
        ?_assertNot(bouy_set:call(<<"has">>, Set, [<<"2">>])),
        ?_assertEqual([1, 2, 3], bouy_set:call(<<"values">>, Set, [])),
        ?_assertEqual([1, 2, 3], bouy_set:call(<<"keys">>, Set, [])),
        ?_assertEqual([[1, 1], [2, 2], [3, 3]], bouy_set:call(<<"entries">>, Set, []))
    ].

members_test_() ->
    Set = bouy_set:new([[1, 1.0, -0.0, 0, 'NaN', 'NaN', <<"a">>, [1]]]),
    [
        ?_assertEqual([1, 0, 'NaN', <<"a">>, [1]], bouy_set:items(Set)),
        ?_assertEqual([<<"a">>, <<"b">>], bouy_set:items(bouy_set:new([<<"aba">>]))),
        ?_assertEqual([], bouy_set:items(bouy_set:new([null])))
    ].

mutate_test_() ->
    Set = bouy_set:new([[a]]),
    [
        ?_assertMatch({true, {'$set', _} = Empty} when Empty =/= Set, bouy_set:mutate(<<"delete">>, Set, [a])),
        ?_assertEqual([], bouy_set:items(element(2, bouy_set:mutate(<<"delete">>, Set, [a])))),
        ?_assertEqual({false, Set}, bouy_set:mutate(<<"delete">>, Set, [b])),
        ?_assertEqual(Set, add(Set, a)),
        ?_assertEqual(0, bouy_set:get(element(2, bouy_set:mutate(<<"clear">>, Set, [])), <<"size">>)),
        ?_assertEqual({true, Set}, bouy_set:mutate(<<"has">>, Set, [a])),
        ?_assertEqual(2, bouy_set:get(bouy_set:call(<<"add">>, Set, [b]), <<"size">>))
    ].

for_each_test_() ->
    Set = bouy_set:new([[x, y]]),
    Self = self(),
    [
        ?_assertEqual(
            [x, y],
            begin
                undefined = bouy_set:call(<<"forEach">>, Set, [fun([V, V, S]) -> Self ! {V, S =:= Set} end]),
                [receive {V, true} -> V end || _ <- [1, 2]]
            end
        )
    ].
