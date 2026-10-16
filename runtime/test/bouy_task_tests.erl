-module(bouy_task_tests).

-include_lib("eunit/include/eunit.hrl").

-import(bouy_test_runtime, [counter/0, slow/0, thrown/1, tag/1]).

task_test_() ->
    {setup, fun bouy_test_runtime:start/0, fun bouy_test_runtime:stop/1, [
        {"all runs in parallel and keeps input order", fun all_keeps_input_order/0},
        {"all throws the first error in input order after every thunk ends", fun all_throws_first_error/0},
        {"all keeps an Effect failure out of the catch", fun all_keeps_effect_failure/0},
        {"map passes the item and its index", fun map_passes_item_and_index/0},
        {"map_settled and map_race pass the item and its index", fun map_forms/0},
        {"allSettled returns JavaScript result objects", fun all_settled_shapes/0},
        {"race returns the first value to settle", fun race_returns_first_value/0},
        {"race throws the first error to settle", fun race_throws_first_error/0},
        {"empty lists settle at once", fun empty_lists/0},
        {"resolve returns the value and reject throws the reason", fun resolve_and_reject/0},
        {"workers inherit the call chain", fun workers_inherit_chain/0},
        {"workers end with their caller", fun workers_end_with_caller/0},
        {"withTimeout returns the value or throws the error of the function", fun with_timeout_returns/0},
        {"withTimeout kills the worker and throws CallTimedOut", fun with_timeout_kills_worker/0},
        {"an actor keeps working after a call times out", fun actor_survives_timeout/0}
    ]}.

all_keeps_input_order() ->
    Started = erlang:monotonic_time(millisecond),
    Values = bouy_task:all([sleeper(300, a), sleeper(100, b), sleeper(200, c)]),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    ?assertEqual([a, b, c], Values),
    ?assert(Elapsed < 600).

all_throws_first_error() ->
    Test = self(),
    Thunks = [
        fun() ->
            timer:sleep(100),
            erlang:error({'$throw', bouy_error:new(<<"Error">>, <<"first">>)})
        end,
        fun() -> erlang:error({'$throw', bouy_error:new(<<"Error">>, <<"second">>)}) end,
        fun() ->
            timer:sleep(200),
            Test ! third_ended,
            third
        end
    ],
    ?assertMatch(#{<<"message">> := <<"first">>}, thrown(fun() -> bouy_task:all(Thunks) end)),
    receive
        third_ended -> ok
    after 0 -> erlang:error(all_did_not_wait)
    end.

all_keeps_effect_failure() ->
    Thunks = [fun() -> 1 end, fun() -> throw({'$fail', not_found}) end],
    ?assertEqual({'$fail', not_found}, catch_throw(fun() -> bouy_task:all(Thunks) end)),
    ?assertEqual({'$fail', not_found}, catch_throw(fun() -> bouy_task:all_settled(Thunks) end)).

map_passes_item_and_index() ->
    ?assertEqual([10, 21, 32], bouy_task:map([10, 20, 30], fun([Item, Index]) -> Item + Index end)).

map_forms() ->
    Check = fun
        ([Item, _Index]) when Item > 15 -> erlang:error({'$throw', bouy_error:new(<<"Error">>, <<"big">>)});
        ([Item, Index]) -> Item + Index
    end,
    ?assertMatch(
        [#{<<"value">> := 10}, #{<<"status">> := <<"rejected">>}],
        bouy_task:map_settled([10, 20], Check)
    ),
    ?assertEqual(1, bouy_task:map_race([500, 10], fun([Ms, Index]) -> timer:sleep(Ms), Index end)).

all_settled_shapes() ->
    Error = bouy_error:new(<<"Error">>, <<"no">>),
    Settled = bouy_task:all_settled([
        fun() -> 1 end,
        fun() -> erlang:error({'$throw', Error}) end,
        fun() -> erlang:error(badarith) end
    ]),
    ?assertMatch(
        [
            #{<<"status">> := <<"fulfilled">>, <<"value">> := 1},
            #{<<"status">> := <<"rejected">>, <<"reason">> := Error},
            #{<<"status">> := <<"rejected">>, <<"reason">> := #{<<"name">> := <<"TypeError">>}}
        ],
        Settled
    ),
    [?assertEqual(2, map_size(Result)) || Result <- Settled].

race_returns_first_value() ->
    ?assertEqual(fast, bouy_task:race([sleeper(500, slow), sleeper(10, fast)])).

race_throws_first_error() ->
    Thunks = [
        sleeper(500, slow),
        fun() ->
            timer:sleep(10),
            erlang:error({'$throw', bouy_error:new(<<"Error">>, <<"lost">>)})
        end
    ],
    ?assertMatch(#{<<"message">> := <<"lost">>}, thrown(fun() -> bouy_task:race(Thunks) end)).

empty_lists() ->
    ?assertEqual([], bouy_task:all([])),
    ?assertEqual([], bouy_task:all_settled([])),
    ?assertEqual([], bouy_task:map([], fun(_) -> erlang:error(unreachable) end)).

resolve_and_reject() ->
    ?assertEqual(5, bouy_task:resolve([5])),
    ?assertEqual(undefined, bouy_task:resolve([])),
    Reason = bouy_error:new(<<"Error">>, <<"no">>),
    Thrown =
        try
            bouy_task:reject([Reason])
        catch
            error:{'$throw', Value} -> Value
        end,
    ?assertEqual(Reason, Thrown).

workers_inherit_chain() ->
    Counter = bouy:spawn([counter()]),
    ?assertEqual(<<"CallCycle">>, bouy_actor:call(Counter, <<"parallelSelf">>, [])).

workers_end_with_caller() ->
    Test = self(),
    Caller = spawn(fun() ->
        bouy_task:all([
            fun() ->
                Test ! {worker, self()},
                timer:sleep(infinity)
            end
        ])
    end),
    Worker =
        receive
            {worker, Pid} -> Pid
        end,
    Monitor = monitor(process, Worker),
    true = exit(Caller, kill),
    receive
        {'DOWN', Monitor, process, Worker, Reason} -> ?assertEqual(killed, Reason)
    after 2000 -> erlang:error(worker_outlived_caller)
    end.

with_timeout_returns() ->
    ?assertEqual(42, bouy:withTimeout([1000, fun([]) -> 42 end])),
    ?assertMatch(
        #{<<"message">> := <<"inner">>},
        thrown(fun() ->
            bouy:withTimeout([1000, fun([]) -> erlang:error({'$throw', bouy_error:new(<<"Error">>, <<"inner">>)}) end])
        end)
    ).

with_timeout_kills_worker() ->
    Test = self(),
    Fun = fun([]) ->
        Test ! {worker, self()},
        timer:sleep(infinity)
    end,
    Started = erlang:monotonic_time(millisecond),
    ?assertMatch(
        #{
            <<"name">> := <<"CallTimedOut">>,
            <<"_tag">> := <<"CallTimedOut">>,
            <<"ms">> := 50,
            <<"message">> := <<"the call did not finish within 50 ms">>
        },
        thrown(fun() -> bouy:withTimeout([50, Fun]) end)
    ),
    ?assert(erlang:monotonic_time(millisecond) - Started >= 50),
    Worker =
        receive
            {worker, Pid} -> Pid
        end,
    ?assertNot(is_process_alive(Worker)).

actor_survives_timeout() ->
    Slow = bouy:spawn([slow()]),
    ?assertEqual(
        <<"CallTimedOut">>,
        tag(fun() -> bouy:withTimeout([50, fun([]) -> bouy_actor:call(Slow, <<"work">>, [300]) end]) end)
    ),
    ?assertEqual(<<"pong">>, bouy_actor:call(Slow, <<"ping">>, [])),
    ?assertEqual(1, bouy_actor:call(Slow, <<"done">>, [])).

sleeper(Ms, Value) ->
    fun() ->
        timer:sleep(Ms),
        Value
    end.

catch_throw(Fun) ->
    try Fun() of
        Value -> erlang:error({expected_a_throw, Value})
    catch
        throw:Thrown -> Thrown
    end.
