-module(gc_share).

%% The time that the garbage collections of BEAM take in a run of the engine. The VM
%% calls start/0 before the program (ERL_AFLAGS="-pa <ebin> -eval gc_share:start()").
%% It traces the collections of every process, and about every 200 ms it writes one
%% JSON line for the process that collected the longest to the file GC_SHARE_OUT: the
%% wall time since the start, the time and count of its minor and major collections,
%% and the size of its heap. The program halts the VM, so the last line written stands.

-export([start/0]).

-spec start() -> ok.
start() ->
    Out = os:getenv("GC_SHARE_OUT", "gc_share.json"),
    Kernel = list_to_binary(os:getenv("GC_SHARE_KERNEL", "")),
    Runs = list_to_integer(os:getenv("GC_SHARE_RUNS", "0")),
    Start = erlang:monotonic_time(),
    _ = spawn(fun() ->
        _ = erlang:trace(all, true, [garbage_collection, monotonic_timestamp]),
        collect(#{out => Out, kernel => Kernel, runs => Runs, start => Start, next => Start}, #{}, #{})
    end),
    ok.

collect(Run, Open, Totals) ->
    receive
        {trace_ts, Pid, Begin, _, At} when Begin =:= gc_minor_start; Begin =:= gc_major_start ->
            collect(Run, Open#{Pid => At}, Totals);
        {trace_ts, Pid, End, _, At} when End =:= gc_minor_end; End =:= gc_major_end ->
            case maps:take(Pid, Open) of
                {Began, Open1} ->
                    Totals1 = add(Pid, End, At - Began, Totals),
                    collect(write(Run, Totals1), Open1, Totals1);
                error ->
                    collect(Run, Open, Totals)
            end;
        _ ->
            collect(Run, Open, Totals)
    end.

add(Pid, Kind, Took, Totals) ->
    {Minor, MinorTime, Major, MajorTime} = maps:get(Pid, Totals, {0, 0, 0, 0}),
    Total = case Kind of
        gc_minor_end -> {Minor + 1, MinorTime + Took, Major, MajorTime};
        gc_major_end -> {Minor, MinorTime, Major + 1, MajorTime + Took}
    end,
    Totals#{Pid => Total}.

write(#{next := Next} = Run, Totals) ->
    Now = erlang:monotonic_time(),
    case Now >= Next of
        true ->
            #{out := Out, kernel := Kernel, runs := Runs, start := Start} = Run,
            [{Pid, {Minor, MinorTime, Major, MajorTime}} | _] =
                lists:sort(fun({_, A}, {_, B}) -> busy(A) >= busy(B) end, maps:to_list(Totals)),
            Heap = case erlang:process_info(Pid, total_heap_size) of
                {total_heap_size, Words} -> Words;
                undefined -> 0
            end,
            Line = json:encode(#{
                kernel => Kernel,
                runs => Runs,
                wall_ms => ms(Now - Start),
                gc_ms => ms(MinorTime + MajorTime),
                minor => Minor,
                minor_ms => ms(MinorTime),
                major => Major,
                major_ms => ms(MajorTime),
                heap_words => Heap
            }),
            %% A rename replaces the file whole, so a halt during the write leaves the last line.
            ok = file:write_file(Out ++ ".part", [Line, $\n]),
            ok = file:rename(Out ++ ".part", Out),
            Run#{next := Now + erlang:convert_time_unit(200, millisecond, native)};
        false ->
            Run
    end.

busy({_, MinorTime, _, MajorTime}) -> MinorTime + MajorTime.

ms(Native) -> erlang:convert_time_unit(Native, native, microsecond) / 1000.
