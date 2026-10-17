-module(bouy_task_tests).

-include_lib("eunit/include/eunit.hrl").

-import(bouy_test_runtime, [counter/0, slow/0, thrown/1, tag/1, capture_stderr/1]).

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
        {"an actor keeps working after a call times out", fun actor_survives_timeout/0},
        {"map_call sends the calls together and keeps input order", fun map_call_keeps_order/0},
        {"map_call runs other items in workers", fun map_call_runs_other_items/0},
        {"map_call throws the first error in input order after every call ends", fun map_call_throws_first_error/0},
        {"map_call waits for an actor that restarts", fun map_call_waits_for_restart/0},
        {"map_call splits a large batch and passes each index", fun map_call_splits_large_batch/0}
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
    ?assertEqual([10, 21, 32], bouy_task:map([10, 20, 30], fun([Item, Index, _Items]) -> Item + Index end)),
    %% The callback gets the array too, and a namespace such as String is callable.
    ?assertEqual([3, 3, 3], bouy_task:map([10, 20, 30], fun([_, _, Items]) -> length(Items) end)),
    ?assertEqual([<<"1">>, <<"2">>], bouy_task:map([1, 2], {'$namespace', bouy_string})),
    %% A function literal with at most two parameters cannot read the array,
    %% so its workers get only the item and the index.
    ?assertEqual([[10, 0], [20, 1]], bouy_task:map([10, 20], fun(Args) -> Args end, 2)),
    ?assertMatch(
        [#{<<"value">> := [10, 0]}, #{<<"value">> := [20, 1]}],
        bouy_task:map_settled([10, 20], fun(Args) -> Args end, 1)
    ),
    ?assertEqual([10, 0, [10]], bouy_task:map_race([10], fun(Args) -> Args end, 3)),
    %% A value that is not an array runs its own map.
    Box = #{<<"map">> => fun([F]) -> [bouy_rt:call(F, [1]), bouy_rt:call(F, [2])] end},
    ?assertEqual([10, 20], bouy_task:map(Box, fun([X | _]) -> X * 10 end)).

map_forms() ->
    Check = fun
        ([Item, _Index, _Items]) when Item > 15 -> erlang:error({'$throw', bouy_error:new(<<"Error">>, <<"big">>)});
        ([Item, Index, _Items]) -> Item + Index
    end,
    ?assertMatch(
        [#{<<"value">> := 10}, #{<<"status">> := <<"rejected">>}],
        bouy_task:map_settled([10, 20], Check)
    ),
    ?assertEqual(1, bouy_task:map_race([500, 10], fun([Ms, Index, _Items]) -> timer:sleep(Ms), Index end)).

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

%% The compiled shape of `(counter, i) => counter.<Method>(i)`.
call_with_index(Method) ->
    fun(Args) -> bouy_rt:call_method(bouy_rt:arg(1, Args), Method, [bouy_rt:arg(2, Args)]) end.

map_call_keeps_order() ->
    Counters = [bouy:spawn([counter()]) || _ <- lists:seq(1, 4)],
    ?assertEqual([0, 1, 2, 3], bouy_task:map_call(Counters, call_with_index(<<"inc">>), 2)),
    ?assertEqual([0, 2, 4, 6], bouy_task:map_call(Counters, call_with_index(<<"inc">>), 2)),
    ?assertEqual([], bouy_task:map_call([], call_with_index(<<"inc">>), 2)).

map_call_runs_other_items() ->
    Counter = bouy:spawn([counter()]),
    Plain = #{<<"inc">> => fun([By]) -> {plain, By} end},
    ?assertEqual([0, {plain, 1}, 2], bouy_task:map_call([Counter, Plain, Counter], call_with_index(<<"inc">>), 2)),
    %% A function that returns something else for the stand-in runs in a worker.
    Echo = fun(Args) -> {echo, bouy_rt:arg(2, Args)} end,
    ?assertEqual([{echo, 0}, {echo, 1}], bouy_task:map_call([Counter, Counter], Echo, 2)).

map_call_throws_first_error() ->
    Counters = [bouy:spawn([counter()]) || _ <- lists:seq(1, 3)],
    Fail = fun(Args) -> bouy_rt:call_method(bouy_rt:arg(1, Args), <<"fail">>, [<<"boom">>]) end,
    {Failure, Text} = capture_stderr(fun() -> thrown(fun() -> bouy_task:map_call(Counters, Fail, 2) end) end),
    [{'$ref', First} | _] = Counters,
    FirstLabel = <<"Counter #", (integer_to_binary(First))/binary>>,
    ?assertMatch(#{<<"_tag">> := <<"ActorFailed">>, <<"actor">> := FirstLabel, <<"method">> := <<"fail">>}, Failure),
    ?assertEqual(3, length(binary:matches(Text, <<"crashed: Error: boom">>))).

map_call_waits_for_restart() ->
    Counter = bouy:spawn([counter(), #{<<"args">> => [7]}]),
    {Values, _Text} = capture_stderr(fun() ->
        _ = thrown(fun() -> bouy_actor:call(Counter, <<"fail">>, [<<"boom">>]) end),
        bouy_task:map_call([Counter, Counter], call_with_index(<<"inc">>), 2)
    end),
    ?assertEqual([7, 8], lists:sort(Values)).

map_call_splits_large_batch() ->
    Counters = [bouy:spawn([counter()]) || _ <- lists:seq(1, 10)],
    Items = lists:append(lists:duplicate(100, Counters)),
    Values = bouy_task:map_call(Items, call_with_index(<<"inc">>), 2),
    ?assertEqual(1000, length(Values)),
    %% Item I adds I, so the counters hold the sum of the indexes 0 to 999.
    ?assertEqual(lists:sum(lists:seq(0, 999)), lists:sum([bouy_actor:call(C, <<"get">>, []) || C <- Counters])).
