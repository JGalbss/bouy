-module(buoy_load_tests).

-include_lib("eunit/include/eunit.hrl").

-import(buoy_test_runtime, [counter/0, slow/0]).

-define(ACTORS, 100000).

load_test_() ->
    {setup, fun buoy_test_runtime:start/0, fun buoy_test_runtime:stop/1, [
        {timeout, 120, {"spinning actors do not delay the replies of another actor", fun spinners_do_not_delay_replies/0}},
        {timeout, 600, {"100000 actors spawn and answer one call each", fun many_actors_answer/0}}
    ]}.

%% Twice as many CPU-bound turns as schedulers, so every scheduler must
%% preempt a spinning turn to serve the ping.
spinners_do_not_delay_replies() ->
    Ping = buoy:spawn([slow()]),
    Idle = latencies(Ping, 50),
    Spinners = [buoy:spawn([slow()]) || _ <- lists:seq(1, 2 * erlang:system_info(schedulers_online))],
    [true = buoy_actor:cast(buoy:cast([Spinner]), <<"spin">>, [3000]) || Spinner <- Spinners],
    timer:sleep(100),
    Busy = latencies(Ping, 50),
    StillSpinning = [Spinner || Spinner <- Spinners, is_spinning(Spinner)],
    io:format(
        user,
        "~nfairness: ~b spinners; ping round trip idle median ~.2f ms max ~.2f ms, "
        "busy median ~.2f ms max ~.2f ms~n",
        [length(Spinners), median(Idle), lists:max(Idle), median(Busy), lists:max(Busy)]
    ),
    ?assertEqual(length(Spinners), length(StillSpinning)),
    ?assert(median(Busy) < 10.0),
    %% Without preemption a reply would wait for a whole 3000 ms spin. The
    %% bound leaves room for the operating system to delay a scheduler thread.
    ?assert(lists:max(Busy) < 250.0).

latencies(Ping, Count) ->
    [latency(Ping) || _ <- lists:seq(1, Count)].

latency(Ping) ->
    timer:sleep(10),
    Started = erlang:monotonic_time(microsecond),
    <<"pong">> = buoy_actor:call(Ping, <<"ping">>, []),
    (erlang:monotonic_time(microsecond) - Started) / 1000.

%% An idle actor waits in receive; a spinning one runs or waits for a scheduler.
is_spinning(Spinner) ->
    {status, Status} = erlang:process_info(buoy_test_runtime:pid(Spinner), status),
    Status =/= waiting.

median(Values) ->
    lists:nth((length(Values) + 1) div 2, lists:sort(Values)).

many_actors_answer() ->
    erlang:garbage_collect(),
    MemoryBefore = erlang:memory(total),
    ProcessesBefore = erlang:system_info(process_count),
    Started = erlang:monotonic_time(millisecond),
    Refs = [buoy:spawn([counter()]) || _ <- lists:seq(1, ?ACTORS)],
    Spawned = erlang:monotonic_time(millisecond),
    MemoryAfter = erlang:memory(total),
    Processes = erlang:system_info(process_count) - ProcessesBefore,
    Replies = [buoy_actor:call(Ref, <<"inc">>, []) || Ref <- Refs],
    Called = erlang:monotonic_time(millisecond),
    ?assertEqual(?ACTORS, length([Reply || Reply <- Replies, Reply =:= 1])),
    ?assert(length(buoy:inspect([])) >= ?ACTORS),
    io:format(
        user,
        "~nload: spawned ~b actors in ~b ms (~.1f us each), called each once in ~b ms (~.1f us each); "
        "~b new processes; ~.1f MiB in total, ~b bytes per actor~n",
        [
            ?ACTORS,
            Spawned - Started,
            1000 * (Spawned - Started) / ?ACTORS,
            Called - Spawned,
            1000 * (Called - Spawned) / ?ACTORS,
            Processes,
            (MemoryAfter - MemoryBefore) / 1048576,
            (MemoryAfter - MemoryBefore) div ?ACTORS
        ]
    ).
