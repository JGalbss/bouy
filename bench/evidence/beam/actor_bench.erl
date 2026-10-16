%% BEAM comparison benchmarks for the Bouy architecture decision.
%% Each call to main/1 runs one benchmark and prints one JSON object.
%% run-beam.sh starts a fresh VM per run so runs do not share allocator state.
-module(actor_bench).
-behaviour(gen_server).

-export([main/1]).
-export([idle/0, hibernating_idle/0, echo/0, relay/2]).
-export([init/1, handle_call/3, handle_cast/2]).

main([Mode | Args]) ->
    Result = measure(Mode, [list_to_integer(Arg) || Arg <- Args]),
    io:format("~s~n", [json:encode(Result#{mode => list_to_binary(Mode), vm => vm()})]),
    halt().

measure("spawn", [Count]) ->
    spawn_idle(Count, idle);
measure("spawn-hibernate", [Count]) ->
    spawn_idle(Count, hibernating_idle);
measure("round-trip", [Count, Warmup]) ->
    Server = spawn(?MODULE, echo, []),
    Self = self(),
    round_trip(Count, Warmup, fun() ->
        Server ! {ping, Self},
        receive
            pong -> ok
        end
    end);
measure("gen-server-call", [Count, Warmup]) ->
    {ok, Server} = gen_server:start(?MODULE, [], []),
    round_trip(Count, Warmup, fun() -> pong = gen_server:call(Server, ping) end);
measure("ring", [Size, Laps]) ->
    ring(Size, Laps).

%% Spawn

spawn_idle(Count, Entry) ->
    garbage_collect(),
    Before = snapshot(),
    T0 = now_ns(),
    Pids = spawn_many(Count, Entry, []),
    T1 = now_ns(),
    wait_until_idle(Pids),
    After = snapshot(),
    Delta = fun(Key) -> maps:get(Key, After) - maps:get(Key, Before) end,
    Spawned = fun(Key) -> (Delta(Key) - Delta(self)) / Count end,
    InfoBytes = lists:sum([element(2, process_info(Pid, memory)) || Pid <- Pids]),
    #{count => Count,
      entry => Entry,
      spawn_ns_total => T1 - T0,
      spawn_ns_per_process => (T1 - T0) / Count,
      processes_bytes_per_process => Spawned(processes),
      processes_used_bytes_per_process => Spawned(processes_used),
      total_bytes_per_process => Spawned(total),
      process_info_bytes_per_process => InfoBytes / Count,
      measuring_process_bytes_delta => Delta(self),
      sample => maps:from_list(process_info(hd(Pids), [memory, heap_size, total_heap_size, stack_size]))}.

spawn_many(0, _Entry, Acc) -> Acc;
spawn_many(K, Entry, Acc) -> spawn_many(K - 1, Entry, [spawn(?MODULE, Entry, []) | Acc]).

idle() ->
    receive
        stop -> ok
    end.

hibernating_idle() ->
    erlang:hibernate(?MODULE, idle, []).

wait_until_idle(Pids) ->
    case lists:all(fun(Pid) -> process_info(Pid, status) =:= {status, waiting} end, Pids) of
        true -> ok;
        false -> timer:sleep(10), wait_until_idle(Pids)
    end.

snapshot() ->
    #{processes => erlang:memory(processes),
      processes_used => erlang:memory(processes_used),
      total => erlang:memory(total),
      self => element(2, process_info(self(), memory))}.

%% Request and reply

round_trip(Count, Warmup, Call) ->
    repeat(Call, Warmup),
    T0 = now_ns(),
    repeat(Call, Count),
    T1 = now_ns(),
    Latencies = timed(Call, Count, []),
    TimerOnly = timed(fun() -> ok end, Count, []),
    #{round_trips => Count,
      warmup_round_trips => Warmup,
      untimed_total_ns => T1 - T0,
      untimed_mean_ns => (T1 - T0) / Count,
      round_trips_per_s => Count / ((T1 - T0) / 1.0e9),
      latency_ns => percentiles(Latencies),
      timer_only_ns => percentiles(TimerOnly)}.

repeat(_Call, 0) -> ok;
repeat(Call, K) -> Call(), repeat(Call, K - 1).

timed(_Call, 0, Acc) -> Acc;
timed(Call, K, Acc) ->
    T0 = erlang:monotonic_time(nanosecond),
    Call(),
    timed(Call, K - 1, [erlang:monotonic_time(nanosecond) - T0 | Acc]).

percentiles(Samples) ->
    Sorted = list_to_tuple(lists:sort(Samples)),
    Size = tuple_size(Sorted),
    At = fun(Fraction) -> element(max(1, ceil(Fraction * Size)), Sorted) end,
    #{min => element(1, Sorted),
      p50 => At(0.5),
      p90 => At(0.9),
      p99 => At(0.99),
      p999 => At(0.999),
      max => element(Size, Sorted),
      mean => lists:sum(tuple_to_list(Sorted)) / Size}.

echo() ->
    receive
        {ping, From} -> From ! pong, echo()
    end.

init([]) -> {ok, nil}.
handle_call(ping, _From, State) -> {reply, pong, State}.
handle_cast(_Message, State) -> {noreply, State}.

%% Ring: Size processes pass a counter until it reaches zero.

ring(Size, Laps) ->
    Parent = self(),
    T0 = now_ns(),
    First = spawn(fun() -> ring_first(Size, Parent) end),
    receive
        {ring_ready, First} -> ok
    end,
    T1 = now_ns(),
    Hops = Size * Laps,
    First ! Hops,
    receive
        ring_done -> ok
    end,
    T2 = now_ns(),
    #{size => Size,
      laps => Laps,
      hops => Hops,
      setup_ns => T1 - T0,
      run_ns => T2 - T1,
      ns_per_hop => (T2 - T1) / Hops,
      hops_per_s => Hops / ((T2 - T1) / 1.0e9)}.

ring_first(Size, Parent) ->
    Next = lists:foldl(fun(_, Acc) -> spawn(?MODULE, relay, [Acc, Parent]) end, self(), lists:seq(2, Size)),
    Parent ! {ring_ready, self()},
    relay(Next, Parent).

relay(Next, Parent) ->
    receive
        0 -> Parent ! ring_done;
        K -> Next ! K - 1, relay(Next, Parent)
    end.

%% Environment

now_ns() -> erlang:monotonic_time(nanosecond).

vm() ->
    #{otp_release => list_to_binary(erlang:system_info(otp_release)),
      erts_version => list_to_binary(erlang:system_info(version)),
      emu_flavor => erlang:system_info(emu_flavor),
      schedulers_online => erlang:system_info(schedulers_online),
      process_limit => erlang:system_info(process_limit),
      wordsize => erlang:system_info(wordsize)}.
