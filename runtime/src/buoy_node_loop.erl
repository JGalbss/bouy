%% The event loop of Node on the job queue of a realm (buoy_jobs), after the
%% bootstrap of buoy_node ran: what libuv and src/env.cc do for Node's lib.
%%
%% - Timers: lib/internal/timers keeps every timer in JavaScript and asks for
%%   one native timer with scheduleTimer. Here that timer is one erlang
%%   send_after; when it fires, the realm calls processTimers, whose result
%%   schedules the next one, ref'd or not (Environment::RunTimers).
%% - Immediates: after each poll of the BEAM mailbox, the realm runs
%%   processImmediate while immediateInfo counts any (CheckImmediate).
%% - Ticks: after each macrotask, the realm runs the microtasks and then the
%%   tick callback, processTicksAndRejections, when the tickInfo flags ask
%%   for it (InternalCallbackScope::Close).
%% - Rejections: a promise rejected without a handler, or one that gets a
%%   handler late, goes to the callback of setPromiseRejectCallback.
%% - Exit: when no ref'd timer, immediate, or handle is left, the realm
%%   emits 'beforeExit', runs again if that queued work, and then emits
%%   'exit' and halts with process.exitCode (EmitProcessExitInternal).
-module(buoy_node_loop).

-include("buoy_ref.hrl").

%% The trace category of the phases of the loop (TRACING_CATEGORY_NODE1).
-define(ENVIRONMENT, <<"node,node.environment">>).

-compile({no_auto_import, [now/0]}).

-export([has_work/0, poll_timeout/0, event/1, check/0, after_callback/0, uncaught/2, finish/0, really_exit/1]).
-export([schedule_timer/1, toggle_timer_ref/1, toggle_immediate_ref/1, now/0, set_callback/2, callback/1]).
-export([ref_handle/0, unref_handle/0, reject_hook/3, set_process/1, process/0, defer/1]).
-export([set_immediate/1]).
-export([enter/0, poll/0, polled/2, metrics/0, idle_time/0, idle_time/1]).

-define(TIMER, '$buoy_node_timer').
-define(IMMEDIATE_REF, '$buoy_node_immediate_ref').
-define(HANDLES, '$buoy_node_handles').
-define(BASE, '$buoy_node_timer_base').
-define(PROCESS, '$buoy_node_process').
-define(EXITING, '$buoy_node_exiting').
-define(NATIVE_IMMEDIATES, '$buoy_node_native_immediates').
%% uv_metrics_info and uv_metrics_idle_time: {Iterations, Events,
%% EventsWaiting, IdleNanoseconds}.
-define(METRICS, '$buoy_node_metrics').
%% The fields of immediateInfo: kCount, kRefCount, kHasOutstanding.
-define(K_COUNT, 0).
-define(K_REF_COUNT, 1).
-define(K_HAS_OUTSTANDING, 2).
%% The fields of tickInfo: kHasTickScheduled, kHasRejectionToWarn.
-define(K_HAS_TICK, 0).
-define(K_HAS_REJECTION, 1).

%%% State

trace(Format, Args) ->
    case persistent_term:get({buoy_node, debug}, false) of
        true -> io:format(standard_error, "[loop] " ++ Format, Args);
        false -> ok
    end.

-spec set_process(term()) -> ok.
set_process(Process) ->
    erlang:put(?PROCESS, Process),
    erlang:put(?BASE, erlang:monotonic_time(millisecond)),
    ok.

-spec process() -> term().
process() -> erlang:get(?PROCESS).

%% A callback that a binding registered, such as {timers, processTimers}.
-spec set_callback(term(), term()) -> ok.
set_callback(Key, F) ->
    erlang:put({?MODULE, Key}, F),
    ok.

-spec callback(term()) -> term().
callback(Key) -> erlang:get({?MODULE, Key}).

%% getLibuvNow: the milliseconds since the loop started.
-spec now() -> non_neg_integer().
now() ->
    case erlang:get(?BASE) of
        undefined -> 0;
        Base -> erlang:monotonic_time(millisecond) - Base
    end.

%% A handle that keeps the loop alive, such as an open server, refs and
%% unrefs with these.
-spec ref_handle() -> ok.
ref_handle() -> erlang:put(?HANDLES, handles() + 1), ok.

-spec unref_handle() -> ok.
unref_handle() -> erlang:put(?HANDLES, max(0, handles() - 1)), ok.

handles() ->
    case erlang:get(?HANDLES) of
        undefined -> 0;
        N -> N
    end.

%% Runs Fun as a later macrotask, as a callback of libuv's thread pool, with
%% the async context frame of now; the loop stays alive until it runs.
-spec defer(fun(() -> term())) -> ok.
defer(Fun) ->
    ref_handle(),
    Ref = make_ref(),
    Frame = buoy_jobs:context(),
    erlang:put({?MODULE, deferred, Ref}, fun() ->
        Prior = buoy_jobs:context(),
        buoy_jobs:set_context(Frame),
        try Fun() after buoy_jobs:set_context(Prior) end
    end),
    self() ! {'$buoy_node_deferred', Ref},
    ok.

%% Environment::SetImmediate: Fun runs at the start of the next check
%% phase, before the immediates of JavaScript, and keeps the loop alive.
-spec set_immediate(fun(() -> term())) -> ok.
set_immediate(Fun) ->
    erlang:put(?NATIVE_IMMEDIATES, [Fun | native_immediates()]),
    ok.

native_immediates() ->
    case erlang:get(?NATIVE_IMMEDIATES) of
        undefined -> [];
        L -> L
    end.

%% RunAndClearNativeImmediates: until the queue is empty, so an immediate
%% that one of them queues runs in the same phase.
run_native_immediates() ->
    case erlang:erase(?NATIVE_IMMEDIATES) of
        undefined -> ok;
        Funs ->
            [buoy_jobs:run_job(F) || F <- lists:reverse(Funs)],
            run_native_immediates()
    end.

%%% Timers

%% scheduleTimer(ms): the one native timer fires in Ms milliseconds.
-spec schedule_timer(term()) -> undefined.
schedule_timer(Ms) ->
    Delay = max(1, trunc(buoy_ref:to_number(Ms))),
    %% The timer handle starts unref'd, as Environment::InitializeLibuv
    %% leaves it; toggleTimerRef refs it for the first ref'd Timeout.
    Refed = case erlang:get(?TIMER) of
        {_, _, R} -> R;
        undefined -> false
    end,
    cancel_timer(),
    Ref = make_ref(),
    _ = erlang:send_after(Delay, self(), {'$buoy_node_timer', Ref}),
    erlang:put(?TIMER, {Ref, active, Refed}),
    undefined.

cancel_timer() ->
    case erlang:get(?TIMER) of
        {_Ref, _, Refed} -> erlang:put(?TIMER, {none, idle, Refed});
        undefined -> ok
    end.

%% toggleTimerRef(ref)
-spec toggle_timer_ref(boolean()) -> undefined.
toggle_timer_ref(Ref) ->
    case erlang:get(?TIMER) of
        {T, State, _} -> erlang:put(?TIMER, {T, State, Ref});
        undefined -> erlang:put(?TIMER, {none, idle, Ref})
    end,
    undefined.

%% toggleImmediateRef(ref)
-spec toggle_immediate_ref(boolean()) -> undefined.
toggle_immediate_ref(Ref) ->
    erlang:put(?IMMEDIATE_REF, Ref),
    undefined.

%%% The loop of buoy_jobs

%% The loop starts after the main script, as SpinEventLoop marks it.
-spec enter() -> ok.
enter() -> buoy_binding_performance:mark(loop_start).

%% Before a poll of the mailbox that may wait: one more iteration, and the
%% messages that wait. Returns the time the poll starts.
-spec poll() -> integer().
poll() ->
    {Iterations, Events, _, Idle} = metrics_state(),
    {message_queue_len, Waiting} = erlang:process_info(self(), message_queue_len),
    erlang:put(?METRICS, {Iterations + 1, Events, Waiting, Idle}),
    erlang:monotonic_time(nanosecond).

%% After the poll that started at Started, with Count events: the loop was
%% idle while it waited.
-spec polled(integer(), non_neg_integer()) -> ok.
polled(Started, Count) ->
    {Iterations, Events, Waiting, Idle} = metrics_state(),
    erlang:put(?METRICS, {Iterations, Events + Count, Waiting, Idle + erlang:monotonic_time(nanosecond) - Started}),
    ok.

%% uv_metrics_info: {loop_count, events, events_waiting}.
-spec metrics() -> {non_neg_integer(), non_neg_integer(), non_neg_integer()}.
metrics() ->
    {Iterations, Events, Waiting, _} = metrics_state(),
    {Iterations, Events, Waiting}.

%% uv_metrics_idle_time in nanoseconds.
-spec idle_time() -> non_neg_integer().
idle_time() -> element(4, metrics_state()).

%% The idle time of the loop of another realm, such as a worker's, which
%% Worker::LoopIdleTime reads from the parent.
-spec idle_time(pid()) -> non_neg_integer().
idle_time(Pid) ->
    case erlang:process_info(Pid, {dictionary, ?METRICS}) of
        {{dictionary, ?METRICS}, {_, _, _, Idle}} -> Idle;
        _ -> 0
    end.

metrics_state() ->
    case erlang:get(?METRICS) of
        undefined -> {0, 0, 0, 0};
        M -> M
    end.

%% Whether the loop of Node is alive: a ref'd active timer, a ref'd
%% immediate, or a ref'd handle.
-spec has_work() -> boolean().
has_work() ->
    case buoy_node:ready() of
        false -> false;
        true -> timer_alive() orelse immediates_alive() orelse handles() > 0 orelse native_immediates() =/= []
    end.

timer_alive() ->
    case erlang:get(?TIMER) of
        {_, active, true} -> true;
        _ -> false
    end.

immediates_alive() ->
    erlang:get(?IMMEDIATE_REF) =:= true andalso immediate_field(?K_COUNT) > 0.

%% The time the poll of the mailbox may wait: none while immediates wait.
-spec poll_timeout() -> infinity | 0.
poll_timeout() ->
    case buoy_node:ready() andalso (immediate_field(?K_COUNT) > 0 orelse native_immediates() =/= []) of
        true -> 0;
        false -> infinity
    end.

immediate_field(I) ->
    case callback(immediate_info) of
        undefined -> 0;
        Info -> buoy_heap:get(Info, I)
    end.

%% One BEAM message of the loop of Node, or false for another message.
-spec event(term()) -> boolean().
event({'$buoy_node_timer', Ref}) ->
    case erlang:get(?TIMER) of
        {Ref, active, Refed} ->
            erlang:put(?TIMER, {none, idle, Refed}),
            buoy_trace:scope(?ENVIRONMENT, <<"RunTimers">>, fun() -> buoy_jobs:run_job(fun run_timers/0) end);
        _ ->
            ok
    end,
    true;
event({'$buoy_node_deferred', Ref}) ->
    case erlang:erase({?MODULE, deferred, Ref}) of
        undefined ->
            ok;
        Fun ->
            unref_handle(),
            buoy_jobs:run_job(Fun)
    end,
    true;
%% A callback that a process of a binding sends, such as the data of a pipe.
event({'$buoy_node_call', Fun}) when is_function(Fun, 0) ->
    buoy_jobs:run_job(Fun),
    true;
%% A select message of the socket module, for a socket of buoy_node_socket,
%% which runs each JavaScript callback as a job of its own.
event({'$socket', _, _, _} = Message) ->
    buoy_node_socket:event(Message),
    true;
event(_) ->
    false.

%% Environment::RunTimers: processTimers(now) returns 0 when no timer is
%% left, the next expiry when a ref'd one is, and its negation when only
%% unref'd ones are.
run_timers() ->
    Expiry = process_timers(process(), now()),
    case Expiry of
        0 ->
            toggle_timer_ref(false);
        E when is_number(E) ->
            schedule_timer(max(1, abs(E) - now())),
            toggle_timer_ref(E > 0);
        _ ->
            toggle_timer_ref(false)
    end.

%% An exception of a timer goes to the uncaught exception handler, and then
%% processTimers runs again for the timers that are still due, as the
%% verbose TryCatch of RunTimers loops.
process_timers(Process, Now) ->
    try buoy_heap:call(callback(process_timers), Process, [Now]) of
        Expiry -> buoy_ref:to_number(Expiry)
    catch
        error:Reason:Stack ->
            _ = uncaught(buoy_ref:caught(Reason, Stack), false),
            process_timers(Process, Now)
    end.

%% The check phase: CheckImmediate.
-spec check() -> ok.
check() ->
    case buoy_node:ready() of
        true -> buoy_trace:scope(?ENVIRONMENT, <<"CheckImmediate">>, fun check_immediate/0);
        false -> ok
    end.

%% The native immediates first: the destroy hooks of async_hooks, then
%% those of set_immediate/1.
check_immediate() ->
    _ = buoy_trace:scope(?ENVIRONMENT, <<"RunAndClearNativeImmediates">>, fun() ->
        _ = buoy_binding_async_wrap:destroy_queued(),
        run_native_immediates()
    end),
    immediates().

immediates() ->
    case buoy_node:ready() andalso immediate_field(?K_COUNT) > 0 of
        true ->
            trace("check ~w ~w ~w~n", [immediate_field(0), immediate_field(1), immediate_field(2)]),
            buoy_jobs:run_job(fun() -> buoy_heap:call(callback(process_immediate), process(), []) end),
            case immediate_field(?K_HAS_OUTSTANDING) =/= 0 of
                true -> immediates();
                false -> ok
            end;
        false ->
            ok
    end.

%%% Ticks

%% InternalCallbackScope::Close: after a macrotask, the microtasks, then
%% the tick callback when a tick or a rejection waits.
-spec after_callback() -> ok.
after_callback() ->
    trace("after_callback~n", []),
    case callback(tick_info) of
        undefined ->
            buoy_jobs:drain();
        TickInfo ->
            case waits(TickInfo) of
                true ->
                    ok;
                false ->
                    buoy_jobs:drain()
            end,
            case waits(TickInfo) of
                true ->
                    _ = buoy_heap:call(callback(tick), process(), []),
                    ok;
                false ->
                    ok
            end
    end.

waits(TickInfo) ->
    buoy_heap:get(TickInfo, ?K_HAS_TICK) =/= 0 orelse buoy_heap:get(TickInfo, ?K_HAS_REJECTION) =/= 0.

%%% Rejections

%% The promise hook of V8, for the callback of setPromiseRejectCallback:
%% Type 0 is kPromiseRejectWithNoHandler and 1 kPromiseHandlerAddedAfterReject.
%% Returns false when no callback is registered.
-spec reject_hook(0 | 1, term(), term()) -> boolean().
reject_hook(Type, Promise, Reason) ->
    trace_rejection(Type),
    case callback(promise_reject) of
        undefined ->
            false;
        F ->
            _ = buoy_heap:call(F, undefined, [Type, Promise, Reason]),
            true
    end.

%% The counters of PromiseRejectCallback: the rejections without a handler,
%% and those that got one later.
trace_rejection(Type) ->
    {Unhandled, HandledAfter} = case erlang:get({?MODULE, rejections}) of
        undefined -> {0, 0};
        Counts -> Counts
    end,
    Counts1 = case Type of
        0 -> {Unhandled + 1, HandledAfter};
        1 -> {Unhandled, HandledAfter + 1}
    end,
    erlang:put({?MODULE, rejections}, Counts1),
    buoy_trace:event($C, <<"node,node.promises,node.promises.rejections">>, <<"rejections">>, none,
                     [{<<"unhandled">>, element(1, Counts1)}, {<<"handledAfter">>, element(2, Counts1)}]).

%%% Uncaught exceptions and exit

%% TriggerUncaughtException: process._fatalException decides; an error that
%% no handler takes is printed, and the program exits with process.exitCode,
%% else 1.
-spec uncaught(term(), boolean()) -> term().
uncaught(Error, FromPromise) ->
    Process = process(),
    Fatal = buoy_heap:get(Process, <<"_fatalException">>),
    %% A program that replaced process._fatalException with no function exits
    %% with kInvalidFatalExceptionMonkeyPatching, as TriggerUncaughtException does.
    buoy_heap:is_callable(Fatal) orelse begin print_fatal(Error), really_exit(6) end,
    Handled = try buoy_heap:call(Fatal, Process, [Error, FromPromise])
              catch
                  error:Reason:Stack -> {thrown, buoy_ref:caught(Reason, Stack)}
              end,
    case Handled of
        {thrown, Thrown} ->
            print_fatal(Thrown),
            really_exit(7);
        H ->
            case buoy_ref:truthy(H) of
                true ->
                    undefined;
                false ->
                    print_fatal(Error),
                    really_exit(exit_code(1))
            end
    end.

print_fatal(Error) ->
    Text = case buoy_heap:is_object(Error) andalso buoy_heap:class_of(Error) =:= error of
        true ->
            case buoy_heap:get(Error, <<"stack">>) of
                Stack when ?IS_STRING(Stack) -> buoy_ref_string:to_utf8(Stack);
                _ -> buoy_ref_string:to_utf8(buoy_ref:to_string(Error))
            end;
        false ->
            ["Uncaught ", buoy_ref_console:inspect(Error)]
    end,
    io:put_chars(buoy_ref:stderr(), [Text, "\n\nNode.js ", buoy_node_process:version(), "\n"]),
    case erlang:get('$buoy_last_throw') of
        {LastMessage, LastStack} ->
            trace("last error thrown: ~tp~n~ts", [LastMessage, [io_lib:format("  ~ts:~w~n", [M, proplists:get_value(line, I, 0)]) || {M, _, _, I} <- lists:sublist(LastStack, 14)]]);
        _ ->
            ok
    end.

%% The exit code: process.exitCode when the program set one, else Default.
exit_code(Default) ->
    case buoy_node_process:exit_info() of
        undefined ->
            Default;
        Fields ->
            case buoy_heap:get(Fields, 2) of
                0 -> Default;
                _ -> trunc(buoy_ref:to_number(buoy_heap:get(Fields, 1)))
            end
    end.

%% When the loop has no work left: 'beforeExit', which may queue work, then
%% 'exit', and the halt. Returns when 'beforeExit' queued work.
-spec finish() -> ok.
finish() ->
    trace("finish~n", []),
    Process = process(),
    case exiting() of
        false ->
            buoy_binding_async_wrap:destroy_queued(),
            buoy_trace:complete(?ENVIRONMENT, <<"BeforeExit">>, fun() ->
                buoy_jobs:run_job(fun() -> emit(Process, <<"beforeExit">>, exit_code(0)) end)
            end),
            case buoy_jobs:has_work() of
                true ->
                    ok;
                false ->
                    emit_exit(Process),
                    free_environment(),
                    really_exit(exit_code(0))
            end;
        true ->
            really_exit(exit_code(0))
    end.

%% FreeEnvironment after the loop ends: the cleanup hooks, the AtExit
%% callbacks, and the end of the Environment, which process.exit() skips.
free_environment() ->
    buoy_trace:complete(?ENVIRONMENT, <<"RunCleanup">>, fun() -> ok end),
    buoy_trace:scope(?ENVIRONMENT, <<"AtExit">>, fun() -> ok end),
    buoy_trace:close_scope(?ENVIRONMENT, <<"Environment">>).

exiting() ->
    case buoy_node_process:exit_info() of
        undefined -> erlang:get(?EXITING) =:= true;
        Fields -> buoy_heap:get(Fields, 0) =/= 0
    end.

emit_exit(Process) ->
    buoy_binding_performance:mark(loop_exit),
    Fields = buoy_node_process:exit_info(),
    buoy_heap:set(Fields, 0, 1),
    %% EmitProcessExitInternal: an exit with no code while the entry module
    %% still awaits is kUnsettledTopLevelAwait.
    case exit_code(0) =:= 0 andalso buoy_jobs:unsettled_main() of
        true ->
            io:put_chars(buoy_ref:stderr(), "Warning: Detected unsettled top-level await\n"),
            buoy_heap:set(Fields, 1, 13),
            buoy_heap:set(Fields, 2, 1);
        false ->
            ok
    end,
    buoy_jobs:run_job(fun() -> emit(Process, <<"exit">>, exit_code(0)) end).

emit(Process, Event, Code) ->
    buoy_heap:call(buoy_heap:get(Process, <<"emit">>), Process, [Event, Code]).

%% process.reallyExit(code): ends the program.
-spec really_exit(term()) -> no_return().
really_exit(Code) ->
    Status = case Code of
        N when is_integer(N) -> N band 255;
        F when is_float(F) -> trunc(F) band 255;
        _ -> 0
    end,
    buoy_ref:exit_program(Status).
