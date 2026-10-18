-module(buoy_sup_tests).

-include_lib("eunit/include/eunit.hrl").

-import(buoy_test_runtime, [counter/0, broken/0, thrown/1, tag/1, entry/1, await/1]).

supervision_test_() ->
    {setup, fun buoy_test_runtime:start/0, fun buoy_test_runtime:stop/1, [
        {"supervise returns a ref for each child key", fun supervise_returns_refs/0},
        {"one-for-one restarts only the failed child", fun one_for_one_restarts_one/0},
        {"one-for-all restarts every child", fun one_for_all_restarts_all/0},
        {"rest-for-one restarts the failed child and the later ones", fun rest_for_one_restarts_rest/0},
        {"a used-up tree budget stops every child", fun tree_budget_stops_children/0},
        {"a temporary child is not restarted", fun temporary_child_stops/0},
        {"a temporary child that a sibling restart ends is stopped", fun temporary_sibling_stops/0},
        {"a stopped child stays stopped when a sibling restarts", fun stopped_child_stays_stopped/0},
        {"each top-level actor has its own budget", fun budgets_are_separate/0},
        {"a throwing child constructor fails supervise", fun throwing_child_fails_supervise/0},
        {"supervise validates its options", fun supervise_validates_options/0},
        {"a group ends with its last actor", fun groups_end_with_actors/0}
    ]}.

supervise_returns_refs() ->
    Refs = buoy:supervise([#{<<"children">> => children([<<"left">>, <<"right">>])}]),
    ?assertEqual([<<"left">>, <<"right">>], lists:sort(maps:keys(Refs))),
    #{<<"left">> := Left, <<"right">> := Right} = Refs,
    ?assertMatch(#{<<"name">> := <<"left">>, <<"class">> := <<"Counter">>}, entry(Left)),
    ?assertEqual(1, buoy_actor:call(Right, <<"inc">>, [])).

one_for_one_restarts_one() ->
    #{<<"a">> := A, <<"b">> := B} = tree(<<"one-for-one">>, [<<"a">>, <<"b">>]),
    5 = buoy_actor:call(B, <<"inc">>, [5]),
    fail(A),
    await(fun() -> restarts(A) =:= 1 end),
    ?assertEqual(5, buoy_actor:call(B, <<"get">>, [])),
    ?assertEqual(0, restarts(B)).

one_for_all_restarts_all() ->
    #{<<"a">> := A, <<"b">> := B} = tree(<<"one-for-all">>, [<<"a">>, <<"b">>]),
    5 = buoy_actor:call(B, <<"inc">>, [5]),
    fail(A),
    await(fun() -> restarts(A) =:= 1 andalso restarts(B) =:= 1 end),
    ?assertEqual(0, buoy_actor:call(B, <<"get">>, [])),
    ?assertEqual(0, buoy_actor:call(A, <<"get">>, [])).

rest_for_one_restarts_rest() ->
    #{<<"a">> := A, <<"b">> := B, <<"c">> := C} = tree(<<"rest-for-one">>, [<<"a">>, <<"b">>, <<"c">>]),
    [1 = buoy_actor:call(Ref, <<"inc">>, []) || Ref <- [A, B, C]],
    fail(B),
    await(fun() -> restarts(B) =:= 1 andalso restarts(C) =:= 1 end),
    ?assertEqual(1, buoy_actor:call(A, <<"get">>, [])),
    ?assertEqual(0, buoy_actor:call(B, <<"get">>, [])),
    ?assertEqual(0, buoy_actor:call(C, <<"get">>, [])),
    ?assertEqual(0, restarts(A)).

tree_budget_stops_children() ->
    #{<<"a">> := A, <<"b">> := B} = buoy:supervise([
        #{
            <<"maxRestarts">> => 1,
            <<"withinMs">> => 10000,
            <<"children">> => children([<<"a">>, <<"b">>])
        }
    ]),
    fail(A),
    fail(A),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> buoy_actor:call(A, <<"get">>, []) end)),
    await(fun() -> status(B) =:= <<"stopped">> end),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> buoy_actor:call(B, <<"get">>, []) end)),
    %% The keeper marks the actors of the ended group, so a cast throws too.
    await(fun() -> buoy_registry:mode(element(2, B)) =:= stopped end),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> buoy_actor:cast(buoy:cast([B]), <<"inc">>, []) end)).

temporary_child_stops() ->
    #{<<"a">> := A, <<"b">> := B} = buoy:supervise([
        #{
            <<"strategy">> => <<"one-for-all">>,
            <<"children">> => #{
                <<"a">> => buoy:child([counter(), #{<<"restart">> => <<"temporary">>}]),
                <<"b">> => buoy:child([counter()])
            }
        }
    ]),
    2 = buoy_actor:call(B, <<"inc">>, [2]),
    fail(A),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> buoy_actor:call(A, <<"get">>, []) end)),
    ?assertEqual(<<"stopped">>, status(A)),
    %% OTP never restarts a temporary child, so its exit does not touch siblings.
    ?assertEqual(2, buoy_actor:call(B, <<"get">>, [])),
    ?assertEqual(0, restarts(B)).

%% OTP ends a temporary child when a sibling restarts under one-for-all, and
%% never restarts it.
temporary_sibling_stops() ->
    #{<<"a">> := A, <<"b">> := B} = buoy:supervise([
        #{
            <<"strategy">> => <<"one-for-all">>,
            <<"children">> => #{
                <<"a">> => buoy:child([counter(), #{<<"restart">> => <<"temporary">>}]),
                <<"b">> => buoy:child([counter()])
            }
        }
    ]),
    fail(B),
    await(fun() -> buoy_registry:mode(element(2, A)) =:= stopped end),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> buoy_actor:call(A, <<"get">>, []) end)),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> buoy_actor:cast(buoy:cast([A]), <<"inc">>, []) end)),
    ?assertEqual(0, buoy_actor:call(B, <<"get">>, [])).

stopped_child_stays_stopped() ->
    #{<<"a">> := A, <<"b">> := B} = tree(<<"one-for-all">>, [<<"a">>, <<"b">>]),
    undefined = buoy:stop([B]),
    fail(A),
    await(fun() -> restarts(A) =:= 1 end),
    ?assertEqual(0, buoy_actor:call(A, <<"get">>, [])),
    ?assertEqual(<<"stopped">>, status(B)),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> buoy_actor:call(B, <<"get">>, []) end)).

budgets_are_separate() ->
    Looping = buoy:spawn([counter()]),
    Steady = buoy:spawn([counter()]),
    3 = buoy_actor:call(Steady, <<"inc">>, [3]),
    [fail(Looping) || _ <- lists:seq(1, 4)],
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> buoy_actor:call(Looping, <<"get">>, []) end)),
    ?assertEqual(3, buoy_actor:call(Steady, <<"get">>, [])),
    ?assertMatch(#{<<"status">> := <<"running">>, <<"restarts">> := 0}, entry(Steady)).

%% The children stay listed as stopped, so a ref that escaped a constructor
%% still names its actor.
throwing_child_fails_supervise() ->
    Before = length(buoy:inspect([])),
    Children = #{<<"a">> => buoy:child([counter()]), <<"b">> => buoy:child([broken()])},
    ?assertMatch(
        #{<<"_tag">> := <<"ActorFailed">>, <<"method">> := <<"constructor">>},
        thrown(fun() -> buoy:supervise([#{<<"children">> => Children}]) end)
    ),
    Added = lists:nthtail(Before, buoy:inspect([])),
    ?assertMatch([#{<<"name">> := <<"a">>, <<"status">> := <<"stopped">>}, #{<<"name">> := <<"b">>, <<"status">> := <<"stopped">>}], Added).

supervise_validates_options() ->
    Children = children([<<"a">>]),
    ?assertMatch(
        #{<<"name">> := <<"TypeError">>},
        thrown(fun() -> buoy:supervise([#{<<"strategy">> => <<"all-for-one">>, <<"children">> => Children}]) end)
    ),
    ?assertMatch(
        #{<<"name">> := <<"TypeError">>},
        thrown(fun() -> buoy:supervise([#{<<"children">> => #{<<"a">> => counter()}}]) end)
    ),
    ?assertMatch(
        #{<<"name">> := <<"TypeError">>},
        thrown(fun() -> buoy:child([not_a_class]) end)
    ).

tree(Strategy, Keys) ->
    buoy:supervise([#{<<"strategy">> => Strategy, <<"children">> => children(Keys)}]).

children(Keys) ->
    maps:from_list([{Key, buoy:child([counter()])} || Key <- Keys]).

fail(Ref) ->
    ?assertEqual(<<"ActorFailed">>, tag(fun() -> buoy_actor:call(Ref, <<"fail">>, [<<"x">>]) end)).

restarts(Ref) ->
    maps:get(<<"restarts">>, entry(Ref)).

status(Ref) ->
    maps:get(<<"status">>, entry(Ref)).

%% No group outlives its actors: a supervise() group whose children are all
%% stopped, the group of a temporary actor that crashed, and the group of a
%% stopped actor all end.
groups_end_with_actors() ->
    Before = active_groups(),
    #{<<"a">> := A, <<"b">> := B} = buoy:supervise([#{<<"children">> => children([<<"a">>, <<"b">>])}]),
    undefined = buoy:stop([A]),
    ?assertEqual(Before + 1, active_groups()),
    undefined = buoy:stop([B]),
    Temporary = buoy:spawn([counter(), #{<<"restart">> => <<"temporary">>}]),
    <<"ActorFailed">> = tag(fun() -> buoy_actor:call(Temporary, <<"fail">>, [<<"x">>]) end),
    ?assertMatch(#{<<"status">> := <<"stopped">>}, entry(Temporary)),
    undefined = buoy:stop([buoy:spawn([counter()])]),
    await(fun() -> active_groups() =:= Before end).

active_groups() ->
    proplists:get_value(active, supervisor:count_children(buoy_groups)).
