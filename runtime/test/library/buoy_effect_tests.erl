-module(buoy_effect_tests).

-include_lib("eunit/include/eunit.hrl").

-import(buoy_test_runtime, [thrown/1]).

effect_test_() ->
    {setup, fun buoy_test_runtime:start/0, fun buoy_test_runtime:stop/1, [
        {"constructors run when the Effect runs", fun constructors/0},
        {"try turns an exception into UnknownError or the catch result", fun try_failures/0},
        {"combinators have data-first and data-last forms", fun dual_forms/0},
        {"catchTag, catchTags, result, and match see only typed failures", fun recovery/0},
        {"an error value is an Effect that fails with itself", fun error_values/0},
        {"a generator body ends at the first failure", fun generator_failure/0},
        {"a defect inside yield* skips the catch of the body", fun generator_defect/0},
        {"ensuring runs the finalizer on every outcome", fun ensuring_runs/0},
        {"all and forEach run in parallel and keep input order", fun parallel_all/0},
        {"the first failure stops the other workers", fun first_failure_stops/0},
        {"timeout fails with TimeoutError and kills the work", fun timeout_kills/0},
        {"retry runs the Effect again as the policy allows", fun retry_attempts/0},
        {"race returns the first success", fun race_first_success/0},
        {"Effect.fn passes the Effect through its pipeables", fun traced_function/0}
    ]}.

run(Effect) -> buoy_effect:runSync([Effect]).

constructors() ->
    ?assertEqual(1, run(buoy_effect:succeed([1]))),
    ?assertEqual(boom, thrown(fun() -> run(buoy_effect:fail([boom])) end)),
    Sync = buoy_effect:sync([fun([]) -> self() ! ran, 2 end]),
    receive
        ran -> erlang:error(sync_ran_early)
    after 0 -> ok
    end,
    ?assertEqual(2, run(Sync)),
    ?assertEqual([ran], messages()),
    ?assertEqual(dead, thrown(fun() -> run(buoy_effect:die([dead])) end)),
    ?assertEqual(undefined, run(buoy_effect:'$member'(<<"void">>))),
    ?assertEqual(7, run(buoy_effect:promise([fun([]) -> 7 end]))).

try_failures() ->
    Throwing = fun([]) -> buoy_error:throw(<<"Error">>, <<"tried">>) end,
    #{<<"failure">> := Unknown} = run(buoy_effect:result([buoy_effect:'try'([Throwing])])),
    ?assertMatch(#{<<"_tag">> := <<"UnknownError">>, <<"message">> := <<"An error occurred in Effect.try">>}, Unknown),
    ?assertMatch(#{<<"cause">> := #{<<"message">> := <<"tried">>}}, Unknown),
    Mapped = buoy_effect:tryPromise([#{<<"try">> => Throwing, <<"catch">> => fun([_]) -> mapped end}]),
    ?assertEqual(mapped, thrown(fun() -> run(Mapped) end)).

dual_forms() ->
    Double = fun([X]) -> X * 2 end,
    ?assertEqual(4, run(buoy_effect:map([buoy_effect:succeed([2]), Double]))),
    Piped = buoy_effect:pipe([buoy_effect:succeed([3]), buoy_effect:map([Double]), buoy_effect:flatMap([fun([X]) -> buoy_effect:succeed([X + 1]) end])]),
    ?assertEqual(7, run(Piped)),
    ?assertEqual(7, run(buoy_effect:call(<<"pipe">>, buoy_effect:succeed([6]), [buoy_effect:map([fun([X]) -> X + 1 end])]))),
    ?assertEqual(b, run(buoy_effect:andThen([buoy_effect:succeed([a]), buoy_effect:succeed([b])]))),
    ?assertEqual(5, run(buoy_effect:tap([buoy_effect:succeed([5]), fun([_]) -> buoy_effect:succeed([6]) end]))),
    ?assertEqual([1, x], run(buoy_effect:zip([buoy_effect:succeed([1]), buoy_effect:succeed([x])]))),
    ?assertEqual(undefined, run(buoy_effect:asVoid([buoy_effect:succeed([1])]))).

recovery() ->
    Missing = tagged(<<"Missing">>),
    Failing = buoy_effect:fail([Missing]),
    Handler = fun([#{<<"_tag">> := Tag}]) -> buoy_effect:succeed([Tag]) end,
    ?assertEqual(<<"Missing">>, run(buoy_effect:catchTag([Failing, <<"Missing">>, Handler]))),
    ?assertEqual(<<"Missing">>, run(buoy_effect:pipe([Failing, buoy_effect:catchTag([[<<"Other">>, <<"Missing">>], Handler])]))),
    ?assertEqual(Missing, thrown(fun() -> run(buoy_effect:catchTag([Failing, <<"Other">>, Handler])) end)),
    ?assertEqual(<<"Missing">>, run(buoy_effect:catchTags([Failing, #{<<"Missing">> => Handler}]))),
    ?assertEqual(#{<<"_tag">> => <<"Failure">>, <<"failure">> => Missing}, run(buoy_effect:result([Failing]))),
    Options = #{<<"onFailure">> => fun([_]) -> failed end, <<"onSuccess">> => fun([V]) -> {ok, V} end},
    ?assertEqual(failed, run(buoy_effect:match([Failing, Options]))),
    ?assertEqual(recovered, run(buoy_effect:orElseSucceed([Failing, fun([_]) -> recovered end]))),
    ?assertEqual(dead, thrown(fun() -> run(buoy_effect:result([buoy_effect:die([dead])])) end)).

error_values() ->
    Missing = tagged(<<"Missing">>),
    ?assertEqual(Missing, thrown(fun() -> run(Missing) end)),
    ?assertEqual(Missing, thrown(fun() -> run(buoy_effect:flatMap([buoy_effect:succeed([1]), fun([_]) -> Missing end])) end)).

generator_failure() ->
    Effect = buoy_effect:generator(fun() ->
        One = buoy_effect:bind(buoy_effect:succeed([1])),
        self() ! {reached, One},
        try
            buoy_effect:bind(buoy_effect:fail([nope]))
        catch
            error:_ -> self() ! caught
        end,
        self() ! after_failure
    end),
    ?assertMatch(#{<<"failure">> := nope}, run(buoy_effect:result([Effect]))),
    ?assertEqual([{reached, 1}], messages()).

generator_defect() ->
    Throwing = buoy_effect:sync([fun([]) -> buoy_error:throw(<<"Error">>, <<"bad">>) end]),
    Effect = buoy_effect:generator(fun() ->
        try
            buoy_effect:bind(Throwing)
        catch
            error:_ -> caught
        end
    end),
    ?assertMatch(#{<<"message">> := <<"bad">>}, thrown(fun() -> run(Effect) end)).

ensuring_runs() ->
    Finalizer = buoy_effect:sync([fun([]) -> self() ! finalized end]),
    ?assertEqual(1, run(buoy_effect:ensuring([buoy_effect:succeed([1]), Finalizer]))),
    ?assertEqual(no, thrown(fun() -> run(buoy_effect:ensuring([buoy_effect:fail([no]), Finalizer])) end)),
    ?assertEqual(dead, thrown(fun() -> run(buoy_effect:ensuring([buoy_effect:die([dead]), Finalizer])) end)),
    ?assertEqual([finalized, finalized, finalized], messages()).

parallel_all() ->
    Sleepy = fun(Ms, Value) -> buoy_effect:andThen([buoy_effect:sleep([Ms]), buoy_effect:succeed([Value])]) end,
    Started = erlang:monotonic_time(millisecond),
    Values = run(buoy_effect:all([[Sleepy(300, a), Sleepy(100, b), Sleepy(200, c)], #{<<"concurrency">> => <<"unbounded">>}])),
    ?assertEqual([a, b, c], Values),
    ?assert(erlang:monotonic_time(millisecond) - Started < 600),
    Record = run(buoy_effect:all([#{<<"x">> => Sleepy(50, 1), <<"y">> => Sleepy(10, 2)}, #{<<"concurrency">> => 2}])),
    ?assertEqual(#{<<"x">> => 1, <<"y">> => 2}, Record),
    Each = buoy_effect:forEach([[1, 2, 3], fun([N, I]) -> Sleepy(10 * N, N * 10 + I) end, #{<<"concurrency">> => 2}]),
    ?assertEqual([10, 21, 32], run(Each)).

first_failure_stops() ->
    Test = self(),
    Late = buoy_effect:andThen([buoy_effect:sleep([200]), buoy_effect:sync([fun([]) -> Test ! late_ran end])]),
    Early = buoy_effect:andThen([buoy_effect:sleep([10]), buoy_effect:fail([early])]),
    ?assertEqual(early, thrown(fun() -> run(buoy_effect:all([[Late, Early], #{<<"concurrency">> => 2}])) end)),
    receive
        late_ran -> erlang:error(worker_survived)
    after 300 -> ok
    end.

timeout_kills() ->
    Test = self(),
    Slow = buoy_effect:andThen([buoy_effect:sleep([<<"200 millis">>]), buoy_effect:sync([fun([]) -> Test ! slow_ran end])]),
    #{<<"failure">> := Failure} = run(buoy_effect:result([buoy_effect:timeout([Slow, <<"20 millis">>])])),
    ?assertMatch(#{<<"_tag">> := <<"TimeoutError">>, <<"message">> := <<"Operation timed out after '20ms'">>}, Failure),
    receive
        slow_ran -> erlang:error(timed_out_work_ran)
    after 300 -> ok
    end,
    ?assertEqual(ok, run(buoy_effect:timeout([buoy_effect:succeed([ok]), 1000]))).

retry_attempts() ->
    Counting = buoy_effect:sync([fun([]) ->
        Count = case get(attempts) of undefined -> 1; N -> N + 1 end,
        put(attempts, Count),
        Count
    end]),
    Failing = buoy_effect:flatMap([Counting, fun([N]) -> buoy_effect:fail([N]) end]),
    put(attempts, 0),
    ?assertEqual(3, thrown(fun() -> run(buoy_effect:retry([Failing, buoy_schedule:recurs([2])])) end)),
    put(attempts, 0),
    ?assertEqual(4, thrown(fun() -> run(buoy_effect:retry([Failing, #{<<"times">> => 3}])) end)),
    put(attempts, 0),
    Spaced = #{<<"schedule">> => buoy_schedule:spaced([<<"10 millis">>]), <<"times">> => 1},
    ?assertEqual(2, thrown(fun() -> run(buoy_effect:pipe([Failing, buoy_effect:retry([Spaced])])) end)).

race_first_success() ->
    Slow = buoy_effect:andThen([buoy_effect:sleep([100]), buoy_effect:succeed([slow])]),
    Fast = buoy_effect:andThen([buoy_effect:sleep([10]), buoy_effect:succeed([fast])]),
    ?assertEqual(fast, run(buoy_effect:race([Slow, Fast]))),
    ?assertEqual(slow, run(buoy_effect:race([buoy_effect:fail([quick]), Slow]))),
    ?assertEqual(first, thrown(fun() -> run(buoy_effect:race([buoy_effect:fail([first]), buoy_effect:andThen([buoy_effect:sleep([20]), buoy_effect:fail([second])])])) end)).

traced_function() ->
    Body = fun([N]) -> buoy_effect:succeed([N * 2]) end,
    Named = buoy_effect:fn([<<"double">>]),
    Double = Named([Body, buoy_effect:map([fun([X]) -> X + 1 end])]),
    ?assertEqual(11, run(Double([5]))),
    ?assertEqual(10, run((buoy_effect:fn([Body]))([5]))).

tagged(Tag) ->
    buoy_error:new(Tag, <<>>, #{<<"_tag">> => Tag}).

messages() ->
    receive
        Message -> [Message | messages()]
    after 0 -> []
    end.
