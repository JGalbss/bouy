-module(bouy_sup_tests).

-include_lib("eunit/include/eunit.hrl").

-import(bouy_test_runtime, [counter/0, broken/0, thrown/1, tag/1, entry/1, await/1]).

supervision_test_() ->
    {setup, fun bouy_test_runtime:start/0, fun bouy_test_runtime:stop/1, [
        {"supervise returns a ref for each child key", fun supervise_returns_refs/0},
        {"one-for-one restarts only the failed child", fun one_for_one_restarts_one/0},
        {"one-for-all restarts every child", fun one_for_all_restarts_all/0},
        {"rest-for-one restarts the failed child and the later ones", fun rest_for_one_restarts_rest/0},
        {"a used-up tree budget stops every child", fun tree_budget_stops_children/0},
        {"a temporary child is not restarted", fun temporary_child_stops/0},
        {"a stopped child stays stopped when a sibling restarts", fun stopped_child_stays_stopped/0},
        {"each top-level actor has its own budget", fun budgets_are_separate/0},
        {"a throwing child constructor fails supervise", fun throwing_child_fails_supervise/0},
        {"supervise validates its options", fun supervise_validates_options/0},
        {"a group ends with its last actor", fun groups_end_with_actors/0}
    ]}.

supervise_returns_refs() ->
    Refs = bouy:supervise([#{<<"children">> => children([<<"left">>, <<"right">>])}]),
    ?assertEqual([<<"left">>, <<"right">>], lists:sort(maps:keys(Refs))),
    #{<<"left">> := Left, <<"right">> := Right} = Refs,
    ?assertMatch(#{<<"name">> := <<"left">>, <<"class">> := <<"Counter">>}, entry(Left)),
    ?assertEqual(1, bouy_actor:call(Right, <<"inc">>, [])).

one_for_one_restarts_one() ->
    #{<<"a">> := A, <<"b">> := B} = tree(<<"one-for-one">>, [<<"a">>, <<"b">>]),
    5 = bouy_actor:call(B, <<"inc">>, [5]),
    fail(A),
    await(fun() -> restarts(A) =:= 1 end),
    ?assertEqual(5, bouy_actor:call(B, <<"get">>, [])),
    ?assertEqual(0, restarts(B)).

one_for_all_restarts_all() ->
    #{<<"a">> := A, <<"b">> := B} = tree(<<"one-for-all">>, [<<"a">>, <<"b">>]),
    5 = bouy_actor:call(B, <<"inc">>, [5]),
    fail(A),
    await(fun() -> restarts(A) =:= 1 andalso restarts(B) =:= 1 end),
    ?assertEqual(0, bouy_actor:call(B, <<"get">>, [])),
    ?assertEqual(0, bouy_actor:call(A, <<"get">>, [])).

rest_for_one_restarts_rest() ->
    #{<<"a">> := A, <<"b">> := B, <<"c">> := C} = tree(<<"rest-for-one">>, [<<"a">>, <<"b">>, <<"c">>]),
    [1 = bouy_actor:call(Ref, <<"inc">>, []) || Ref <- [A, B, C]],
    fail(B),
    await(fun() -> restarts(B) =:= 1 andalso restarts(C) =:= 1 end),
    ?assertEqual(1, bouy_actor:call(A, <<"get">>, [])),
    ?assertEqual(0, bouy_actor:call(B, <<"get">>, [])),
    ?assertEqual(0, bouy_actor:call(C, <<"get">>, [])),
    ?assertEqual(0, restarts(A)).

tree_budget_stops_children() ->
    #{<<"a">> := A, <<"b">> := B} = bouy:supervise([
        #{
            <<"maxRestarts">> => 1,
            <<"withinMs">> => 10000,
            <<"children">> => children([<<"a">>, <<"b">>])
        }
    ]),
    fail(A),
    fail(A),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> bouy_actor:call(A, <<"get">>, []) end)),
    await(fun() -> status(B) =:= <<"stopped">> end),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> bouy_actor:call(B, <<"get">>, []) end)).

temporary_child_stops() ->
    #{<<"a">> := A, <<"b">> := B} = bouy:supervise([
        #{
            <<"strategy">> => <<"one-for-all">>,
            <<"children">> => #{
                <<"a">> => bouy:child([counter(), #{<<"restart">> => <<"temporary">>}]),
                <<"b">> => bouy:child([counter()])
            }
        }
    ]),
    2 = bouy_actor:call(B, <<"inc">>, [2]),
    fail(A),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> bouy_actor:call(A, <<"get">>, []) end)),
    ?assertEqual(<<"stopped">>, status(A)),
    %% OTP never restarts a temporary child, so its exit does not touch siblings.
    ?assertEqual(2, bouy_actor:call(B, <<"get">>, [])),
    ?assertEqual(0, restarts(B)).

stopped_child_stays_stopped() ->
    #{<<"a">> := A, <<"b">> := B} = tree(<<"one-for-all">>, [<<"a">>, <<"b">>]),
    undefined = bouy:stop([B]),
    fail(A),
    await(fun() -> restarts(A) =:= 1 end),
    ?assertEqual(0, bouy_actor:call(A, <<"get">>, [])),
    ?assertEqual(<<"stopped">>, status(B)),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> bouy_actor:call(B, <<"get">>, []) end)).

budgets_are_separate() ->
    Looping = bouy:spawn([counter()]),
    Steady = bouy:spawn([counter()]),
    3 = bouy_actor:call(Steady, <<"inc">>, [3]),
    [fail(Looping) || _ <- lists:seq(1, 4)],
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> bouy_actor:call(Looping, <<"get">>, []) end)),
    ?assertEqual(3, bouy_actor:call(Steady, <<"get">>, [])),
    ?assertMatch(#{<<"status">> := <<"running">>, <<"restarts">> := 0}, entry(Steady)).

%% The children stay listed as stopped, so a ref that escaped a constructor
%% still names its actor.
throwing_child_fails_supervise() ->
    Before = length(bouy:inspect([])),
    Children = #{<<"a">> => bouy:child([counter()]), <<"b">> => bouy:child([broken()])},
    ?assertMatch(
        #{<<"_tag">> := <<"ActorFailed">>, <<"method">> := <<"constructor">>},
        thrown(fun() -> bouy:supervise([#{<<"children">> => Children}]) end)
    ),
    Added = lists:nthtail(Before, bouy:inspect([])),
    ?assertMatch([#{<<"name">> := <<"a">>, <<"status">> := <<"stopped">>}, #{<<"name">> := <<"b">>, <<"status">> := <<"stopped">>}], Added).

supervise_validates_options() ->
    Children = children([<<"a">>]),
    ?assertMatch(
        #{<<"name">> := <<"TypeError">>},
        thrown(fun() -> bouy:supervise([#{<<"strategy">> => <<"all-for-one">>, <<"children">> => Children}]) end)
    ),
    ?assertMatch(
        #{<<"name">> := <<"TypeError">>},
        thrown(fun() -> bouy:supervise([#{<<"children">> => #{<<"a">> => counter()}}]) end)
    ),
    ?assertMatch(
        #{<<"name">> := <<"TypeError">>},
        thrown(fun() -> bouy:child([not_a_class]) end)
    ).

tree(Strategy, Keys) ->
    bouy:supervise([#{<<"strategy">> => Strategy, <<"children">> => children(Keys)}]).

children(Keys) ->
    maps:from_list([{Key, bouy:child([counter()])} || Key <- Keys]).

fail(Ref) ->
    ?assertEqual(<<"ActorFailed">>, tag(fun() -> bouy_actor:call(Ref, <<"fail">>, [<<"x">>]) end)).

restarts(Ref) ->
    maps:get(<<"restarts">>, entry(Ref)).

status(Ref) ->
    maps:get(<<"status">>, entry(Ref)).

%% No group outlives its actors: a supervise() group whose children are all
%% stopped, the group of a temporary actor that crashed, and the group of a
%% stopped actor all end.
groups_end_with_actors() ->
    Before = active_groups(),
    #{<<"a">> := A, <<"b">> := B} = bouy:supervise([#{<<"children">> => children([<<"a">>, <<"b">>])}]),
    undefined = bouy:stop([A]),
    ?assertEqual(Before + 1, active_groups()),
    undefined = bouy:stop([B]),
    Temporary = bouy:spawn([counter(), #{<<"restart">> => <<"temporary">>}]),
    <<"ActorFailed">> = tag(fun() -> bouy_actor:call(Temporary, <<"fail">>, [<<"x">>]) end),
    ?assertMatch(#{<<"status">> := <<"stopped">>}, entry(Temporary)),
    undefined = bouy:stop([bouy:spawn([counter()])]),
    await(fun() -> active_groups() =:= Before end).

active_groups() ->
    proplists:get_value(active, supervisor:count_children(bouy_root_sup)).
