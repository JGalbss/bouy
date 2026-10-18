-module(buoy_tests).

-include_lib("eunit/include/eunit.hrl").

-import(buoy_test_runtime, [counter/0, thrown/1, await/1]).

api_test_() ->
    {setup, fun buoy_test_runtime:start/0, fun buoy_test_runtime:stop/1, [
        {"schedule every casts until it is cancelled", fun schedule_every_until_cancelled/0},
        {"schedule after casts once", fun schedule_after_casts_once/0},
        {"a schedule ends when its actor stops", fun schedule_ends_with_actor/0},
        {"a schedule ends with the process that created it", fun schedule_ends_with_creator/0},
        {"sleep blocks the calling process", fun sleep_blocks/0},
        {"cast returns a cast ref and true", fun cast_returns_true/0},
        {"spawn validates the class and its options", fun spawn_validates_options/0},
        {"the other functions validate their arguments", fun functions_validate_arguments/0}
    ]}.

schedule_every_until_cancelled() ->
    Counter = buoy:spawn([counter()]),
    {'$schedule', Timer} = Handle = buoy:schedule([Counter, #{<<"every">> => 20}, <<"inc">>]),
    await(fun() -> count(Counter) >= 3 end),
    Monitor = monitor(process, Timer),
    ?assertEqual(undefined, buoy:cancelSchedule([Handle])),
    receive
        {'DOWN', Monitor, process, Timer, normal} -> ok
    after 2000 -> erlang:error(schedule_still_running)
    end,
    Count = count(Counter),
    timer:sleep(100),
    ?assertEqual(Count, count(Counter)).

schedule_after_casts_once() ->
    Counter = buoy:spawn([counter()]),
    {'$schedule', Timer} = buoy:schedule([Counter, #{<<"after">> => 30}, <<"inc">>, 5]),
    await(fun() -> count(Counter) =:= 5 end),
    await(fun() -> not is_process_alive(Timer) end),
    timer:sleep(100),
    ?assertEqual(5, count(Counter)).

schedule_ends_with_actor() ->
    Counter = buoy:spawn([counter()]),
    {'$schedule', Timer} = buoy:schedule([Counter, #{<<"every">> => 10}, <<"inc">>]),
    await(fun() -> count(Counter) >= 1 end),
    undefined = buoy:stop([Counter]),
    await(fun() -> not is_process_alive(Timer) end).

schedule_ends_with_creator() ->
    Counter = buoy:spawn([counter()]),
    Test = self(),
    Creator = spawn(fun() ->
        Test ! {schedule, buoy:schedule([Counter, #{<<"every">> => 10}, <<"inc">>])},
        timer:sleep(infinity)
    end),
    Timer =
        receive
            {schedule, {'$schedule', Pid}} -> Pid
        end,
    true = exit(Creator, kill),
    await(fun() -> not is_process_alive(Timer) end).

sleep_blocks() ->
    Started = erlang:monotonic_time(millisecond),
    ?assertEqual(undefined, buoy:sleep([50])),
    ?assert(erlang:monotonic_time(millisecond) - Started >= 50).

cast_returns_true() ->
    {'$ref', Id} = Counter = buoy:spawn([counter()]),
    ?assertEqual({'$cast', Id}, buoy:cast([Counter])),
    ?assert(buoy_actor:cast(buoy:cast([Counter]), <<"inc">>, [])),
    await(fun() -> count(Counter) =:= 1 end).

spawn_validates_options() ->
    Invalid = [
        [not_a_class],
        [counter(), 42],
        [counter(), #{<<"args">> => 1}],
        [counter(), #{<<"name">> => 7}],
        [counter(), #{<<"restart">> => <<"sometimes">>}],
        [counter(), #{<<"mailbox">> => #{<<"capacity">> => 0}}],
        [counter(), #{<<"mailbox">> => #{<<"overflow">> => <<"drop">>}}]
    ],
    [?assertMatch(#{<<"name">> := <<"TypeError">>}, thrown(fun() -> buoy:spawn(Arguments) end)) || Arguments <- Invalid].

functions_validate_arguments() ->
    Counter = buoy:spawn([counter()]),
    Calls = [
        fun() -> buoy:cast([42]) end,
        fun() -> buoy:stop([42]) end,
        fun() -> buoy:schedule([Counter, #{<<"often">> => 1}, <<"inc">>]) end,
        fun() -> buoy:cancelSchedule([42]) end,
        fun() -> buoy:sleep([<<"soon">>]) end,
        fun() -> buoy:withTimeout([10, 42]) end
    ],
    [?assertMatch(#{<<"name">> := <<"TypeError">>}, thrown(Call)) || Call <- Calls].

count(Counter) ->
    buoy_actor:call(Counter, <<"get">>, []).
