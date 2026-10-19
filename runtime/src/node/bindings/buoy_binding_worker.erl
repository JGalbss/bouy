%% internalBinding('worker') (src/node_worker.cc): Worker, the handle of a
%% worker thread, and the facts of the thread that this realm runs.
%%
%% A worker is a realm in a BEAM process of its own, as a Bun Worker is a VM
%% on a thread of its own (src/jsc/web_worker.rs): its heap, its job queue,
%% and its loop are its own, and nothing it does blocks the realm that
%% started it. The two talk over a MessageChannel pipe (buoy_binding_messaging)
%% whose second side is the worker's getEnvMessagePort(). The process runs
%% Node's bootstrap for a thread that is not the main one and
%% internal/main/worker_thread, which loads the script when LOAD_SCRIPT
%% arrives. resourceLimits becomes the max_heap_size of the process, so a
%% worker that grows past it dies alone. terminate() kills the process, which
%% BEAM preempts even in a loop that never yields, where V8 needs
%% TerminateExecution. A watcher process reports the end to the parent as
%% onexit, and ends the worker when the parent ends.
-module(buoy_binding_worker).

-export([binding/0, is_worker/0, thread_main/1, exited/2]).

-define(INFO, '$buoy_worker').
-define(STATE, {'#', ?MODULE, <<"worker">>}).
-define(HANDLE(Key), {?MODULE, handle, Key}).
-define(ENV_PORT, {?MODULE, env_port}).
-define(COUNTER, {?MODULE, thread_ids}).
-define(K_YOUNG, 0).
-define(K_OLD, 1).
-define(K_CODE, 2).
-define(K_STACK, 3).
-define(MB, 1048576).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    Info = erlang:get(?INFO),
    Worker = buoy_node:constructor(<<"Worker">>, 7, fun new_worker/2),
    Proto = buoy_heap:get(Worker, <<"prototype">>),
    Methods = [{<<"startThread">>, fun(This, _) -> start_thread(This) end},
               {<<"stopThread">>, fun(This, _) -> stop_thread(This) end},
               {<<"ref">>, fun(This, _) -> set_ref(This, true) end},
               {<<"unref">>, fun(This, _) -> set_ref(This, false) end},
               {<<"hasRef">>, fun(This, _) -> has_ref(This) end},
               {<<"getAsyncId">>, fun(This, _) -> maps:get(async_id, state(This), -1) end},
               {<<"getResourceLimits">>, fun(This, _) -> limits_array(maps:get(limits, state(This))) end},
               {<<"loopStartTime">>, fun(This, _) -> loop_start_time(This) end},
               {<<"loopIdleTime">>, fun(This, _) -> loop_idle_time(This) end},
               {<<"getHeapStatistics">>, fun(This, _) -> heap_statistics(This) end},
               {<<"cpuUsage">>, fun(This, _) -> cpu_usage(This) end}],
    [buoy_heap:define(Proto, Name, #{value => F(Name, 0, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    [buoy_heap:define(Proto, Name, #{value => buoy_node:not_implemented(<<"worker">>, Name), writable => true,
                                     enumerable => true, configurable => true})
     || Name <- [<<"takeHeapSnapshot">>, <<"startCpuProfile">>, <<"stopCpuProfile">>, <<"startHeapProfile">>,
                 <<"stopHeapProfile">>]],
    {ThreadId, Name, Limits} = case Info of
        undefined -> ensure_counter(), {0, <<"main">>, [-1, -1, -1, -1]};
        #{thread_id := Id, name := N, limits := L} -> {Id, N, effective(L)}
    end,
    buoy_node:object([
        {<<"Worker">>, Worker},
        {<<"getEnvMessagePort">>, F(<<"getEnvMessagePort">>, 0, fun(_, _) -> env_port() end)},
        {<<"threadId">>, ThreadId}, {<<"threadName">>, Name}, {<<"isMainThread">>, Info =:= undefined},
        {<<"isInternalThread">>, is_map(Info) andalso maps:get(internal, Info, false)},
        {<<"ownsProcessState">>, Info =:= undefined},
        {<<"kMaxYoungGenerationSizeMb">>, ?K_YOUNG}, {<<"kMaxOldGenerationSizeMb">>, ?K_OLD}, {<<"kCodeRangeSizeMb">>, ?K_CODE},
        {<<"kStackSizeMb">>, ?K_STACK}, {<<"kTotalResourceLimitCount">>, 4},
        {<<"resourceLimits">>, limits_array(Limits)},
        %% Buoy's loader runs the script of a worker: internal/main/worker_thread calls these.
        {<<"runMain">>, F(<<"runMain">>, 1, fun(_, Args) -> run_main(buoy_node:arg(1, Args)) end)},
        {<<"runSource">>, F(<<"runSource">>, 2, fun(_, Args) -> run_source(buoy_node:arg(1, Args), buoy_node:arg(2, Args)) end)}]).

%% Whether this realm is a worker thread.
-spec is_worker() -> boolean().
is_worker() -> erlang:get(?INFO) =/= undefined.

%% The thread ids of the VM count from 1, in the order the workers start, as
%% Node's do. The main realm makes the counter before any worker exists.
ensure_counter() ->
    case persistent_term:get(?COUNTER, undefined) of
        undefined -> persistent_term:put(?COUNTER, counters:new(1, [atomics]));
        _ -> ok
    end.

next_thread_id() ->
    ensure_counter(),
    Counter = persistent_term:get(?COUNTER),
    counters:add(Counter, 1, 1),
    counters:get(Counter, 1).

%%% The handle in the parent

state(This) ->
    case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, ?STATE) of
        {ok, S} -> S;
        _ -> buoy_ref:type_error(<<"Illegal invocation">>)
    end.

save(This, S) -> buoy_heap:private_put(This, ?STATE, S).

%% new Worker(url, env, execArgv, resourceLimits, trackUnmanagedFds,
%% isInternal, name): the handle, with the parent's side of the channel to
%% the worker as messagePort.
new_worker(This, Args) ->
    A = fun(N) -> buoy_node:arg(N, Args) end,
    buoy_heap:is_object(This) orelse
        buoy_node:throw_code('TypeError', <<"ERR_CONSTRUCT_CALL_REQUIRED">>, <<"Class constructor Worker cannot be invoked without 'new'">>),
    %% Only an execArgv of the options is checked; an inherited one is the parent's.
    ExecArgv = case A(3) of
        undefined ->
            buoy_node_process:exec_argv();
        List ->
            Own = [buoy_ref_string:to_utf8(buoy_ref:to_string(V)) || V <- buoy_heap:array_items(List)],
            case invalid_options(Own, exec_argv) of
                [] -> ok;
                Invalid -> buoy_heap:set(This, <<"invalidExecArgv">>, buoy_heap:new_array([buoy_ref_string:from_utf8(I) || I <- Invalid]))
            end,
            Own
    end,
    Env = env_spec(A(2)),
    case Env of
        {entries, Pairs} ->
            case lists:keyfind("NODE_OPTIONS", 1, Pairs) of
                {_, Options} ->
                    case invalid_options([list_to_binary(O) || O <- string:lexemes(Options, " ")], node_options) of
                        [] -> ok;
                        Bad -> buoy_heap:set(This, <<"invalidNodeOptions">>, buoy_heap:new_array([buoy_ref_string:from_utf8(I) || I <- Bad]))
                    end;
                false -> ok
            end;
        _ -> ok
    end,
    Limits = [buoy_ref:to_number(buoy_heap:get(A(4), I)) || I <- lists:seq(0, 3)],
    Name = case A(7) of
        undefined -> <<"WorkerThread">>;
        N -> buoy_ref:to_string(N)
    end,
    ThreadId = next_thread_id(),
    save(This, #{status => created, refed => false, limits => [-1, -1, -1, -1]}),
    AsyncId = buoy_binding_async_wrap:emit_init(This, <<"WORKER">>),
    Pipe = buoy_binding_messaging:pipe(),
    Port = buoy_binding_messaging:new_port(Pipe, 1, []),
    buoy_heap:set(This, <<"messagePort">>, Port),
    buoy_heap:set(This, <<"threadId">>, ThreadId),
    buoy_heap:set(This, <<"threadName">>, Name),
    save(This, #{thread_id => ThreadId, name => Name, pipe => Pipe, env => Env, exec_argv => ExecArgv,
                 limits => Limits, url => A(1), refed => false, status => created, async_id => AsyncId,
                 internal => A(6) =:= true}),
    undefined.

%% The env of the worker: a copy of this realm's (null), this realm's own
%% (undefined, SHARE_ENV), or the pairs of the object.
env_spec(null) ->
    {entries, [split(E) || E <- buoy_node_process:environ()]};
env_spec(undefined) ->
    case erlang:get('$buoy_env') of
        undefined -> os;
        Table -> {table, Table}
    end;
env_spec(Object) ->
    {entries, [{text(K), text(buoy_heap:get(Object, K))} || K <- buoy_heap:enumerable_keys(Object), not is_tuple(K)]}.

text(V) -> unicode:characters_to_list(buoy_ref_string:to_utf8(buoy_ref:to_string(V))).

split(Entry) ->
    case string:split(Entry, "=") of
        [Name, Value] -> {Name, Value};
        [Name] -> {Name, ""}
    end.

%% The node options that a worker cannot take: unknown ones, ones that need a
%% value and have none, and the options of the whole process.
%% The options of Args that a worker rejects. Worker::New parses NODE_OPTIONS
%% with the options of an isolate and reports only its errors, so a V8 or a
%% per-process option there is left out, as `--title` is; execArgv rejects them.
invalid_options(Args, Scope) ->
    Known = known_options(),
    invalid(Args, Known#{scope => Scope}, []).

invalid([], _Known, Acc) ->
    lists:reverse(Acc);
invalid([<<"--", _/binary>> = Arg | Rest], #{scope := Scope} = Known, Acc) ->
    {Name, Value} = case binary:split(Arg, <<"=">>) of
        [N, V] -> {N, V};
        [N] -> {N, none}
    end,
    Dashed = << <<(case C of $_ -> $-; _ -> C end)>> || <<C>> <= Name >>,
    Base = case Dashed of <<"--no-", B/binary>> -> <<"--", B/binary>>; _ -> Dashed end,
    case {maps:find(Dashed, Known), maps:find(Base, Known)} of
        {error, error} ->
            invalid(Rest, Known, [Arg | Acc]);
        {Found, Other} ->
            {ok, Type} = case Found of error -> Other; _ -> Found end,
            %% V8's flags are the process's: a worker cannot take them (Worker::New).
            case Scope =:= exec_argv andalso (Type =:= 1 orelse lists:member(Dashed, per_process_options())) of
                true -> invalid(Rest, Known, [Arg | Acc]);
                false when Value =:= none, Type >= 3, Type =/= 2 ->
                    case Rest of
                        [Next | More] -> invalid(More, Known, case Next of <<"-", _/binary>> -> [Arg | Acc]; _ -> Acc end);
                        [] -> invalid(Rest, Known, [Arg | Acc])
                    end;
                false -> invalid(Rest, Known, Acc)
            end
    end;
invalid([_ | Rest], Known, Acc) ->
    invalid(Rest, Known, Acc).

known_options() ->
    Info = buoy_heap:get(buoy_heap:call(buoy_heap:get(buoy_node:binding(<<"options">>), <<"getCLIOptionsInfo">>), undefined, []),
                         <<"options">>),
    Entries = buoy_heap:call(buoy_heap:get(Info, <<"entries">>), Info, []),
    maps:from_list([{buoy_ref_string:to_utf8(buoy_heap:get(E, 0)), trunc(buoy_ref:to_number(buoy_heap:get(buoy_heap:get(E, 1), <<"type">>)))}
                    || E <- iterate(Entries)]).

iterate(Iterator) ->
    Next = buoy_heap:get(Iterator, <<"next">>),
    iterate(Iterator, Next, []).

iterate(Iterator, Next, Acc) ->
    R = buoy_heap:call(Next, Iterator, []),
    case buoy_ref:truthy(buoy_heap:get(R, <<"done">>)) of
        true -> lists:reverse(Acc);
        false -> iterate(Iterator, Next, [buoy_heap:get(R, <<"value">>) | Acc])
    end.

%% PerProcessOptions of src/node_options.h, which a worker cannot set.
per_process_options() ->
    [<<"--title">>, <<"--trace-event-categories">>, <<"--trace-event-file-pattern">>, <<"--v8-pool-size">>,
     <<"--zero-fill-buffers">>, <<"--build-snapshot">>, <<"--build-snapshot-config">>, <<"--snapshot-blob">>,
     <<"--icu-data-dir">>, <<"--openssl-config">>, <<"--tls-cipher-list">>, <<"--secure-heap">>,
     <<"--secure-heap-min">>, <<"--use-openssl-ca">>, <<"--use-bundled-ca">>, <<"--use-system-ca">>,
     <<"--enable-fips">>, <<"--force-fips">>, <<"--openssl-legacy-provider">>, <<"--openssl-shared-config">>,
     <<"--run">>, <<"--experimental-sea-config">>, <<"--report-on-signal">>, <<"--report-compact">>,
     <<"--report-dir">>, <<"--report-directory">>, <<"--report-filename">>, <<"--v8-options">>, <<"--help">>,
     <<"--version">>, <<"--completion-bash">>, <<"--disable-wasm-trap-handler">>, <<"--node-snapshot">>].

%% The limits of resourceLimits with V8's defaults where the options give none.
effective([Young, Old, Code, Stack]) ->
    [default(Young, 48), default(Old, 2048), default(Code, 0), default(Stack, 4)].

default(V, _D) when is_number(V), V > 0 -> V;
default(_, D) -> D.

limits_array(Limits) ->
    Array = buoy_node:typed_array(<<"Float64Array">>, 4),
    [buoy_heap:set(Array, I, V) || {I, V} <- lists:enumerate(0, Limits)],
    Array.

%% startThread(): the process of the worker, and the watcher that reports its
%% end. The handle stays a root of the heap until then.
start_thread(This) ->
    #{thread_id := ThreadId, name := Name, pipe := Pipe, env := Env, exec_argv := ExecArgv, limits := Limits,
      internal := Internal} = S = state(This),
    Init = #{thread_id => ThreadId, name => Name, pipe => Pipe, env => Env, exec_argv => ExecArgv,
             limits => Limits, graph => buoy_module:graph(), internal => Internal},
    Parent = self(),
    Key = make_ref(),
    Worker = spawn(?MODULE, thread_main, [Init]),
    _ = spawn(fun() -> watch(Worker, Parent, Key) end),
    erlang:put(?HANDLE(Key), This),
    save(This, S#{status => running, pid => Worker, key => Key}),
    set_ref(This, true),
    undefined.

%% stopThread(): ends the worker wherever it runs.
stop_thread(This) ->
    case state(This) of
        #{status := running, pid := Pid} = S ->
            save(This, S#{status => stopping}),
            exit(Pid, '$buoy_terminate');
        _ ->
            ok
    end,
    undefined.

%% HandleWrap::HasRef: undefined once the handle closed after the exit.
has_ref(This) ->
    case state(This) of
        #{status := closed} -> undefined;
        #{refed := Refed} -> Refed
    end.

set_ref(This, Refed) ->
    S = state(This),
    Old = maps:get(refed, S, false),
    New = Refed andalso lists:member(maps:get(status, S), [created, running, stopping]),
    case {Old, New} of
        {false, true} -> buoy_node_loop:ref_handle();
        {true, false} -> buoy_node_loop:unref_handle();
        _ -> ok
    end,
    save(This, S#{refed => New}),
    undefined.

watch(Worker, Parent, Key) ->
    W = erlang:monitor(process, Worker),
    P = erlang:monitor(process, Parent),
    receive
        {'DOWN', W, process, Worker, Reason} ->
            Parent ! {'$buoy_node_call', fun() -> ?MODULE:exited(Key, Reason) end};
        {'DOWN', P, process, Parent, _} ->
            exit(Worker, kill)
    end.

%% The worker ended: onexit(code, customErr, customErrReason) runs in the
%% parent, as Worker::OnThreadStopped calls it.
-spec exited(reference(), term()) -> ok.
exited(Key, Reason) ->
    case erlang:erase(?HANDLE(Key)) of
        undefined ->
            ok;
        This ->
            %% The handle stays ref'd while onexit runs, then closes in this turn's
            %% check phase, as uv_close calls back before the next turn's timers.
            {Code, Error, Why} = exit_code(Reason),
            OnExit = buoy_heap:get(This, <<"onexit">>),
            try buoy_heap:is_callable(OnExit) andalso buoy_heap:call(OnExit, This, [Code, Error, Why])
            after
                set_ref(This, false),
                save(This, (state(This))#{status => exited}),
                buoy_node_loop:set_immediate(fun() -> save(This, (state(This))#{status => closed}) end)
            end,
            ok
    end.

exit_code({'$buoy_exit', Status}) -> {Status, undefined, undefined};
exit_code(normal) -> {0, undefined, undefined};
exit_code('$buoy_terminate') -> {1, undefined, undefined};
exit_code(killed) -> {1, <<"ERR_WORKER_OUT_OF_MEMORY">>, <<"JS heap out of memory">>};
exit_code(Reason) ->
    io:put_chars(buoy_ref:stderr(), io_lib:format("buoy: a worker thread crashed: ~0tP~n", [Reason, 12])),
    {1, undefined, undefined}.

heap_statistics(This) ->
    case state(This) of
        #{status := running, pid := Pid} ->
            Taker = buoy_node:object([]),
            Words = case erlang:process_info(Pid, total_heap_size) of
                {total_heap_size, W} -> W;
                undefined -> 0
            end,
            Bytes = Words * erlang:system_info(wordsize),
            Stats = buoy_node:object([{K, V} || {K, V} <- [
                {<<"total_heap_size">>, Bytes}, {<<"total_heap_size_executable">>, 0}, {<<"total_physical_size">>, Bytes},
                {<<"total_available_size">>, 0}, {<<"used_heap_size">>, Bytes}, {<<"heap_size_limit">>, 0},
                {<<"malloced_memory">>, 0}, {<<"peak_malloced_memory">>, 0}, {<<"does_zap_garbage">>, 0},
                {<<"number_of_native_contexts">>, 1}, {<<"number_of_detached_contexts">>, 0},
                {<<"total_global_handles_size">>, 0}, {<<"used_global_handles_size">>, 0}, {<<"external_memory">>, 0}]]),
            buoy_node_loop:defer(fun() ->
                OnDone = buoy_heap:get(Taker, <<"ondone">>),
                buoy_heap:is_callable(OnDone) andalso buoy_heap:call(OnDone, Taker, [Stats])
            end),
            Taker;
        _ ->
            undefined
    end.

cpu_usage(This) ->
    case state(This) of
        #{status := running, pid := Pid} ->
            Taker = buoy_node:object([]),
            Micros = case erlang:process_info(Pid, reductions) of
                {reductions, R} -> R div 10;
                undefined -> 0
            end,
            Usage = buoy_node:object([{<<"user">>, Micros}, {<<"system">>, 0}]),
            buoy_node_loop:defer(fun() ->
                OnDone = buoy_heap:get(Taker, <<"ondone">>),
                buoy_heap:is_callable(OnDone) andalso buoy_heap:call(OnDone, Taker, [null, Usage])
            end),
            Taker;
        _ ->
            undefined
    end.

%%% The worker thread

%% The process of a worker: a realm whose process.exit ends only it, with the
%% env, execArgv, and argv of a Worker, that runs the worker bootstrap and
%% then its loop.
-spec thread_main(map()) -> no_return().
thread_main(#{env := Env, exec_argv := ExecArgv} = Init) ->
    erlang:put('$buoy_exit', true),
    erlang:put(?INFO, Init),
    erlang:put('$buoy_exec_argv', ExecArgv),
    erlang:put('$buoy_argv', []),
    case Env of
        os -> ok;
        {table, Table} -> erlang:put('$buoy_env', Table);
        {entries, Pairs} ->
            Table = ets:new(buoy_worker_env, [set, public]),
            ets:insert(Table, Pairs),
            erlang:put('$buoy_env', Table)
    end,
    buoy_jobs:run_main(fun() -> buoy_node:ensure() end),
    exit({'$buoy_exit', 0}).

%% getEnvMessagePort(): the worker's side of the channel to its parent.
env_port() ->
    case erlang:get(?INFO) of
        undefined ->
            undefined;
        #{pipe := Pipe} ->
            case erlang:get(?ENV_PORT) of
                undefined ->
                    Port = buoy_binding_messaging:new_port(Pipe, 2, []),
                    erlang:put(?ENV_PORT, Port),
                    Port;
                Port ->
                    Port
            end
    end.

%% Worker::LoopStartTime: the loopStart milestone of the worker's realm in ms,
%% on the clock of the parent's hrtime, or -1 before the loop starts.
loop_start_time(This) ->
    case state(This) of
        #{status := running, pid := Pid} ->
            case buoy_binding_performance:loop_start(Pid) of
                -1 -> -1;
                Ns -> buoy_ref_number:canonical(Ns / 1.0e6)
            end;
        _ ->
            -1
    end.

%% Worker::LoopIdleTime: the idle time of the worker's loop, in ms.
loop_idle_time(This) ->
    case state(This) of
        #{status := running, pid := Pid} -> buoy_ref_number:canonical(buoy_node_loop:idle_time(Pid) / 1.0e6);
        _ ->
            0
    end.

%% runMain(filename): runs the script of the worker as its main module.
run_main(Filename) ->
    Path = buoy_ref_string:to_utf8(buoy_ref:to_string(Filename)),
    #{graph := Known} = erlang:get(?INFO),
    Entry = case maps:find(buoy_ref_string:from_utf8(Path), Known) of
        {ok, Module} -> Module;
        error -> loaded(buoy_ref_eval:load_module(Path, Path, Path, require), Path)
    end,
    run(Entry).

%% runSource(path, source): runs code as the main module at path.
run_source(Path, Source) ->
    P = buoy_ref_string:to_utf8(buoy_ref:to_string(Path)),
    run(loaded(buoy_ref_eval:load_source(P, buoy_ref_string:to_utf8(buoy_ref:to_string(Source))), P)).

loaded({program, _Path, Entry, _Graph}, _) ->
    Entry;
loaded({builtin, _}, Path) ->
    buoy_node:throw_code('Error', <<"MODULE_NOT_FOUND">>, buoy_ref_string:from_utf8(<<"Cannot find module '", Path/binary, "'">>));
loaded({error, Code, Message}, _) ->
    buoy_module:throw_load(Code, buoy_ref_string:from_utf8(Message)).

%% The limits apply from here, so the bootstrap does not count against them.
run(Entry) ->
    #{graph := Known, limits := [Young, Old | _]} = erlang:get(?INFO),
    case [L || L <- [Young, Old], is_number(L), L > 0] of
        [] ->
            ok;
        Set ->
            {total_heap_size, Base} = erlang:process_info(self(), total_heap_size),
            Words = Base + trunc(lists:sum(Set) * ?MB / erlang:system_info(wordsize)),
            erlang:process_flag(max_heap_size, #{size => Words, kill => true, error_logger => false})
    end,
    ok = buoy_node_process:preload(),
    P = buoy_module:run_worker(Entry, Known),
    buoy_jobs:set_main_result(P),
    %% A module that throws as it runs throws here, as an uncaught exception;
    %% one that awaits gives its promise to the main script.
    case buoy_heap:slots(P) of
        {fulfilled, _, _} ->
            undefined;
        {rejected, Reason, _} ->
            buoy_jobs:perform_then(P, fun(_) -> undefined end, fun(_) -> undefined end, undefined),
            erlang:error({'$throw', Reason});
        _ ->
            P
    end.
