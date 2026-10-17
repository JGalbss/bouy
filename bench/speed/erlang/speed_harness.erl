-module(speed_harness).

%% The timing loop of the speed kernels, the same protocol as the TypeScript `bench`
%% function: `Warmup` untimed iterations, then `Runs` timed ones, and one JSON line with the
%% median. Usage: erl -noshell -pa <ebin> -run <kernel> main [Warmup] [Runs] [Size]

-export([bench/4]).

-spec bench(binary(), pos_integer(), fun((pos_integer()) -> number()), [string()]) -> no_return().
bench(Name, DefaultSize, Work, Args) ->
    [Warmup, Runs, Size] = arguments(Args, [3, 5, DefaultSize]),
    {Times, Check} = loop(Work, Size, Warmup, Runs, [], 0),
    Sorted = lists:sort(Times),
    Median = lists:nth(length(Sorted) div 2 + 1, Sorted),
    Line = json:encode(#{
        kernel => Name,
        size => Size,
        median_ms => Median,
        times_ms => Sorted,
        check => Check
    }),
    io:put_chars([Line, $\n]),
    erlang:halt(0).

arguments([Text | Rest], [_ | Defaults]) -> [list_to_integer(Text) | arguments(Rest, Defaults)];
arguments([], Defaults) -> Defaults.

loop(_Work, _Size, Warmup, 0, Times, Check) when Warmup =< 0 ->
    {Times, Check};
loop(Work, Size, Warmup, Runs, Times, _Check) ->
    Start = erlang:monotonic_time(nanosecond),
    Check = Work(Size),
    Elapsed = (erlang:monotonic_time(nanosecond) - Start) / 1.0e6,
    case Warmup > 0 of
        true -> loop(Work, Size, Warmup - 1, Runs, Times, Check);
        false -> loop(Work, Size, 0, Runs - 1, [Elapsed | Times], Check)
    end.
