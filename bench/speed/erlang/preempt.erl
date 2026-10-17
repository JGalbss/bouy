-module(preempt).

%% The preemption proof. Run it on a VM with one scheduler (+S 1). One process runs a
%% kernel for several seconds. Meanwhile a pinger sends a ping to an echo process, waits
%% for the pong, sleeps 1 ms, and repeats. The output is one JSON line with the round trips,
%% the gaps between two pings (1 ms plus a round trip when nothing holds the scheduler),
%% and the pings that the window allowed.
%% Kernels: native-nbody and native-richards run in time slices, blocking-nbody does not
%% yield (the control), and erlang-nbody is the typed Erlang NBody of nbody_flat.
%% Usage: erl +S 1 -noshell -pa <ebin> -run preempt main <kernel> <size>

-export([main/1]).

-spec main([string()]) -> no_return().
main([Kernel, SizeText]) ->
    1 = erlang:system_info(schedulers_online),
    Size = list_to_integer(SizeText),
    %% Load the kernel modules first: the dlopen of the NIF library would stall the one
    %% scheduler, and that stall belongs to startup, not to the kernel.
    {module, _} = code:ensure_loaded(speed_native),
    {module, _} = code:ensure_loaded(nbody_flat),
    Echo = spawn_link(fun echo/0),
    Pinger = spawn_link(fun() -> ping(Echo, erlang:monotonic_time(microsecond), [], []) end),
    %% Let the pinger start its loop before the kernel takes the scheduler.
    receive
    after 20 -> ok
    end,
    Start = erlang:monotonic_time(microsecond),
    Result = kernel(Kernel, Size),
    KernelMs = (erlang:monotonic_time(microsecond) - Start) / 1000,
    Pinger ! {stop, self()},
    {Samples, Gaps} =
        receive
            {samples, RoundTrips, Intervals} -> {lists:sort(RoundTrips), lists:sort(Intervals)}
        end,
    Count = length(Samples),
    Line = json:encode(#{
        kernel => list_to_binary(Kernel),
        size => Size,
        result => Result,
        kernel_ms => KernelMs,
        schedulers => erlang:system_info(schedulers_online),
        pings => Count,
        p50_ms => percentile(Samples, 50) / 1000,
        p99_ms => percentile(Samples, 99) / 1000,
        max_ms => lists:last(Samples) / 1000,
        gap_p99_ms => percentile(Gaps, 99) / 1000,
        gap_max_ms => lists:last(Gaps) / 1000
    }),
    io:put_chars([Line, $\n]),
    erlang:halt(0).

kernel("native-nbody", Steps) -> speed_native:nbody(Steps);
kernel("native-richards", Runs) -> speed_native:richards(Runs);
kernel("blocking-nbody", Steps) -> speed_native:nbody_blocking(Steps);
kernel("erlang-nbody", Steps) -> nbody_flat:iteration(Steps).

echo() ->
    receive
        {ping, From} ->
            From ! pong,
            echo()
    end.

ping(Echo, Previous, RoundTrips, Gaps) ->
    receive
        {stop, From} ->
            Last = erlang:monotonic_time(microsecond) - Previous,
            From ! {samples, RoundTrips, [Last | Gaps]}
    after 0 ->
        Sent = erlang:monotonic_time(microsecond),
        Echo ! {ping, self()},
        receive
            pong -> ok
        end,
        RoundTrip = erlang:monotonic_time(microsecond) - Sent,
        receive
        after 1 -> ok
        end,
        ping(Echo, Sent, [RoundTrip | RoundTrips], [Sent - Previous | Gaps])
    end.

percentile(Sorted, P) ->
    lists:nth(max(1, min(length(Sorted), ceil(length(Sorted) * P / 100))), Sorted).
