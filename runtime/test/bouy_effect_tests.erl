-module(bouy_effect_tests).

-include_lib("eunit/include/eunit.hrl").

-import(bouy_test_runtime, [thrown/1]).

effect_test_() ->
    {setup, fun bouy_test_runtime:start/0, fun bouy_test_runtime:stop/1, [
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

run(Effect) -> bouy_effect:runSync([Effect]).

constructors() ->
    ?assertEqual(1, run(bouy_effect:succeed([1]))),
    ?assertEqual(boom, thrown(fun() -> run(bouy_effect:fail([boom])) end)),
    Sync = bouy_effect:sync([fun([]) -> self() ! ran, 2 end]),
    receive
        ran -> erlang:error(sync_ran_early)
    after 0 -> ok
    end,
    ?assertEqual(2, run(Sync)),
    ?assertEqual([ran], messages()),
    ?assertEqual(dead, thrown(fun() -> run(bouy_effect:die([dead])) end)),
    ?assertEqual(undefined, run(bouy_effect:'$member'(<<"void">>))),
    ?assertEqual(7, run(bouy_effect:promise([fun([]) -> 7 end]))).

try_failures() ->
    Throwing = fun([]) -> bouy_error:throw(<<"Error">>, <<"tried">>) end,
    #{<<"failure">> := Unknown} = run(bouy_effect:result([bouy_effect:'try'([Throwing])])),
    ?assertMatch(#{<<"_tag">> := <<"UnknownError">>, <<"message">> := <<"An error occurred in Effect.try">>}, Unknown),
    ?assertMatch(#{<<"cause">> := #{<<"message">> := <<"tried">>}}, Unknown),
    Mapped = bouy_effect:tryPromise([#{<<"try">> => Throwing, <<"catch">> => fun([_]) -> mapped end}]),
    ?assertEqual(mapped, thrown(fun() -> run(Mapped) end)).

dual_forms() ->
    Double = fun([X]) -> X * 2 end,
    ?assertEqual(4, run(bouy_effect:map([bouy_effect:succeed([2]), Double]))),
    Piped = bouy_effect:pipe([bouy_effect:succeed([3]), bouy_effect:map([Double]), bouy_effect:flatMap([fun([X]) -> bouy_effect:succeed([X + 1]) end])]),
    ?assertEqual(7, run(Piped)),
    ?assertEqual(7, run(bouy_effect:call(<<"pipe">>, bouy_effect:succeed([6]), [bouy_effect:map([fun([X]) -> X + 1 end])]))),
    ?assertEqual(b, run(bouy_effect:andThen([bouy_effect:succeed([a]), bouy_effect:succeed([b])]))),
    ?assertEqual(5, run(bouy_effect:tap([bouy_effect:succeed([5]), fun([_]) -> bouy_effect:succeed([6]) end]))),
    ?assertEqual([1, x], run(bouy_effect:zip([bouy_effect:succeed([1]), bouy_effect:succeed([x])]))),
    ?assertEqual(undefined, run(bouy_effect:asVoid([bouy_effect:succeed([1])]))).

recovery() ->
    Missing = tagged(<<"Missing">>),
    Failing = bouy_effect:fail([Missing]),
    Handler = fun([#{<<"_tag">> := Tag}]) -> bouy_effect:succeed([Tag]) end,
    ?assertEqual(<<"Missing">>, run(bouy_effect:catchTag([Failing, <<"Missing">>, Handler]))),
    ?assertEqual(<<"Missing">>, run(bouy_effect:pipe([Failing, bouy_effect:catchTag([[<<"Other">>, <<"Missing">>], Handler])]))),
    ?assertEqual(Missing, thrown(fun() -> run(bouy_effect:catchTag([Failing, <<"Other">>, Handler])) end)),
    ?assertEqual(<<"Missing">>, run(bouy_effect:catchTags([Failing, #{<<"Missing">> => Handler}]))),
    ?assertEqual(#{<<"_tag">> => <<"Failure">>, <<"failure">> => Missing}, run(bouy_effect:result([Failing]))),
    Options = #{<<"onFailure">> => fun([_]) -> failed end, <<"onSuccess">> => fun([V]) -> {ok, V} end},
    ?assertEqual(failed, run(bouy_effect:match([Failing, Options]))),
    ?assertEqual(recovered, run(bouy_effect:orElseSucceed([Failing, fun([_]) -> recovered end]))),
    ?assertEqual(dead, thrown(fun() -> run(bouy_effect:result([bouy_effect:die([dead])])) end)).

error_values() ->
    Missing = tagged(<<"Missing">>),
    ?assertEqual(Missing, thrown(fun() -> run(Missing) end)),
    ?assertEqual(Missing, thrown(fun() -> run(bouy_effect:flatMap([bouy_effect:succeed([1]), fun([_]) -> Missing end])) end)).

generator_failure() ->
    Effect = bouy_effect:generator(fun() ->
        One = bouy_effect:bind(bouy_effect:succeed([1])),
        self() ! {reached, One},
        try
            bouy_effect:bind(bouy_effect:fail([nope]))
        catch
            error:_ -> self() ! caught
        end,
        self() ! after_failure
    end),
    ?assertMatch(#{<<"failure">> := nope}, run(bouy_effect:result([Effect]))),
    ?assertEqual([{reached, 1}], messages()).

generator_defect() ->
    Throwing = bouy_effect:sync([fun([]) -> bouy_error:throw(<<"Error">>, <<"bad">>) end]),
    Effect = bouy_effect:generator(fun() ->
        try
            bouy_effect:bind(Throwing)
        catch
            error:_ -> caught
        end
    end),
    ?assertMatch(#{<<"message">> := <<"bad">>}, thrown(fun() -> run(Effect) end)).

ensuring_runs() ->
    Finalizer = bouy_effect:sync([fun([]) -> self() ! finalized end]),
    ?assertEqual(1, run(bouy_effect:ensuring([bouy_effect:succeed([1]), Finalizer]))),
    ?assertEqual(no, thrown(fun() -> run(bouy_effect:ensuring([bouy_effect:fail([no]), Finalizer])) end)),
    ?assertEqual(dead, thrown(fun() -> run(bouy_effect:ensuring([bouy_effect:die([dead]), Finalizer])) end)),
    ?assertEqual([finalized, finalized, finalized], messages()).

parallel_all() ->
    Sleepy = fun(Ms, Value) -> bouy_effect:andThen([bouy_effect:sleep([Ms]), bouy_effect:succeed([Value])]) end,
    Started = erlang:monotonic_time(millisecond),
    Values = run(bouy_effect:all([[Sleepy(300, a), Sleepy(100, b), Sleepy(200, c)], #{<<"concurrency">> => <<"unbounded">>}])),
    ?assertEqual([a, b, c], Values),
    ?assert(erlang:monotonic_time(millisecond) - Started < 600),
    Record = run(bouy_effect:all([#{<<"x">> => Sleepy(50, 1), <<"y">> => Sleepy(10, 2)}, #{<<"concurrency">> => 2}])),
    ?assertEqual(#{<<"x">> => 1, <<"y">> => 2}, Record),
    Each = bouy_effect:forEach([[1, 2, 3], fun([N, I]) -> Sleepy(10 * N, N * 10 + I) end, #{<<"concurrency">> => 2}]),
    ?assertEqual([10, 21, 32], run(Each)).

first_failure_stops() ->
    Test = self(),
    Late = bouy_effect:andThen([bouy_effect:sleep([200]), bouy_effect:sync([fun([]) -> Test ! late_ran end])]),
    Early = bouy_effect:andThen([bouy_effect:sleep([10]), bouy_effect:fail([early])]),
    ?assertEqual(early, thrown(fun() -> run(bouy_effect:all([[Late, Early], #{<<"concurrency">> => 2}])) end)),
    receive
        late_ran -> erlang:error(worker_survived)
    after 300 -> ok
    end.

timeout_kills() ->
    Test = self(),
    Slow = bouy_effect:andThen([bouy_effect:sleep([<<"200 millis">>]), bouy_effect:sync([fun([]) -> Test ! slow_ran end])]),
    #{<<"failure">> := Failure} = run(bouy_effect:result([bouy_effect:timeout([Slow, <<"20 millis">>])])),
    ?assertMatch(#{<<"_tag">> := <<"TimeoutError">>, <<"message">> := <<"Operation timed out after '20ms'">>}, Failure),
    receive
        slow_ran -> erlang:error(timed_out_work_ran)
    after 300 -> ok
    end,
    ?assertEqual(ok, run(bouy_effect:timeout([bouy_effect:succeed([ok]), 1000]))).

retry_attempts() ->
    Counting = bouy_effect:sync([fun([]) ->
        Count = case get(attempts) of undefined -> 1; N -> N + 1 end,
        put(attempts, Count),
        Count
    end]),
    Failing = bouy_effect:flatMap([Counting, fun([N]) -> bouy_effect:fail([N]) end]),
    put(attempts, 0),
    ?assertEqual(3, thrown(fun() -> run(bouy_effect:retry([Failing, bouy_schedule:recurs([2])])) end)),
    put(attempts, 0),
    ?assertEqual(4, thrown(fun() -> run(bouy_effect:retry([Failing, #{<<"times">> => 3}])) end)),
    put(attempts, 0),
    Spaced = #{<<"schedule">> => bouy_schedule:spaced([<<"10 millis">>]), <<"times">> => 1},
    ?assertEqual(2, thrown(fun() -> run(bouy_effect:pipe([Failing, bouy_effect:retry([Spaced])])) end)).

race_first_success() ->
    Slow = bouy_effect:andThen([bouy_effect:sleep([100]), bouy_effect:succeed([slow])]),
    Fast = bouy_effect:andThen([bouy_effect:sleep([10]), bouy_effect:succeed([fast])]),
    ?assertEqual(fast, run(bouy_effect:race([Slow, Fast]))),
    ?assertEqual(slow, run(bouy_effect:race([bouy_effect:fail([quick]), Slow]))),
    ?assertEqual(first, thrown(fun() -> run(bouy_effect:race([bouy_effect:fail([first]), bouy_effect:andThen([bouy_effect:sleep([20]), bouy_effect:fail([second])])])) end)).

traced_function() ->
    Body = fun([N]) -> bouy_effect:succeed([N * 2]) end,
    Named = bouy_effect:fn([<<"double">>]),
    Double = Named([Body, bouy_effect:map([fun([X]) -> X + 1 end])]),
    ?assertEqual(11, run(Double([5]))),
    ?assertEqual(10, run((bouy_effect:fn([Body]))([5]))).

tagged(Tag) ->
    bouy_error:new(Tag, <<>>, #{<<"_tag">> => Tag}).

messages() ->
    receive
        Message -> [Message | messages()]
    after 0 -> []
    end.
