-module(multicore).

%% Multicore throughput on BEAM: start N processes that each run one kernel at the given
%% size, with no warm-up, and time from the first spawn to the last result. The default N
%% is the count of schedulers, one for each core.
%% Kernels: richards-typed (richards_local), richards-native, nbody-typed (nbody_flat),
%% nbody-native.
%% Usage: erl -noshell -pa <ebin> -run multicore main <kernel> <processes> <size>

-export([main/1]).

-spec main([string()]) -> no_return().
main([Kernel, CountText, SizeText]) ->
    Count = list_to_integer(CountText),
    Size = list_to_integer(SizeText),
    Work = work(Kernel),
    Parent = self(),
    Start = erlang:monotonic_time(microsecond),
    Workers = [spawn_link(fun() -> Parent ! {done, self(), Work(Size)} end) || _ <- lists:seq(1, Count)],
    Checks = [
        receive
            {done, Worker, Check} -> Check
        end
     || Worker <- Workers
    ],
    WallMs = (erlang:monotonic_time(microsecond) - Start) / 1000,
    Line = json:encode(#{
        kernel => list_to_binary(Kernel),
        workers => Count,
        size => Size,
        schedulers => erlang:system_info(schedulers_online),
        wall_ms => WallMs,
        units_per_s => Count * Size * 1000 / WallMs,
        check => hd(Checks)
    }),
    io:put_chars([Line, $\n]),
    erlang:halt(0).

work("richards-typed") -> fun(Runs) -> richards_runs(Runs, 0) end;
work("richards-native") -> fun speed_native:richards/1;
work("nbody-typed") -> fun nbody_flat:iteration/1;
work("nbody-native") -> fun speed_native:nbody/1.

richards_runs(0, Check) -> Check;
richards_runs(Runs, Check) -> richards_runs(Runs - 1, Check + richards_local:run()).
