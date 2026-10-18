%% The job queue of one realm (spike: reference semantics).
%%
%% A realm runs one job at a time: a macrotask (the module body, a timer
%% callback, an actor turn, the arrival of a reply), then every microtask
%% that it queued, until the microtask queue is empty. Promises follow the
%% ECMAScript job semantics, so the order of reactions matches V8. Timers are
%% BEAM messages from erlang:send_after/3 to the realm itself, and the realm
%% runs the timers that are due in the order of their due time and creation,
%% as libuv does. There is no global event loop: each realm process waits in
%% its own receive, and BEAM preempts it as any process.
%%
%% Between jobs the stack is empty, so the realm collects its heap there.
-module(buoy_jobs).

-export([new_promise/0, new_promise/1, capability/0, promise_resolve/1, perform_then/4, is_promise/1]).
-export([resolve_promise/2, reject_promise/2, resolving_functions/1, js_function/1, invoke/2, fulfilled/1, rejected/1]).
-export([await/3, async_call/1, enqueue/1, drain/0]).
-export([set_timer/4, clear_timer/1]).
-export([run_main/1, run_job/1, event_step/1, loop/0, has_work/0]).
-export([spawn_actor/2, actor_call/3, stop_actor/1]).
-export([all/1]).

-define(QUEUE, '$buoy_microtasks').
-define(TIMERS, '$buoy_timers').
-define(TIMER_SEQ, '$buoy_timer_seq').
-define(NOW, '$buoy_now').
-define(PENDING, '$buoy_pending').
-define(UNHANDLED, '$buoy_unhandled').
-define(THIS, '$buoy_this').
-define(BUSY, '$buoy_busy').
-define(CALLS, '$buoy_calls').
-define(LAST_GC, '$buoy_last_gc').
-define(MAIN, '$buoy_main_result').
-define(PROMISE_PROTO, {'$o', 'Promise.prototype'}).
-define(MAX_DELAY, 2147483647).
-define(GC_MIN, 20000).

%%% Microtasks

-spec enqueue(fun(() -> term())) -> ok.
enqueue(Job) ->
    case erlang:get(?QUEUE) of
        undefined -> erlang:put(?QUEUE, {[Job], []});
        {In, Out} -> erlang:put(?QUEUE, {[Job | In], Out})
    end,
    ok.

%% Runs microtasks until the queue is empty. A job that a job queues runs in
%% the same drain.
-spec drain() -> ok.
drain() ->
    case erlang:get(?QUEUE) of
        {In, [Job | Out]} ->
            erlang:put(?QUEUE, {In, Out}),
            Job(),
            drain();
        {[_ | _] = In, []} ->
            erlang:put(?QUEUE, {[], lists:reverse(In)}),
            drain();
        _ ->
            ok
    end.

%%% Promises
%%
%% The slots of a promise: {pending, FulfillReactions, RejectReactions,
%% IsHandled} with the reactions newest first, {fulfilled, Value, IsHandled},
%% or {rejected, Reason, IsHandled}. A reaction is {Kind, Capability,
%% Handler}. Capability is undefined for await, which has no derived
%% promise, or {Promise, Resolve, Reject}. A handler or a resolving function
%% is a JavaScript function or an Erlang fun of one argument.

-spec new_promise() -> term().
new_promise() -> new_promise(?PROMISE_PROTO).

%% A pending promise whose prototype is Proto, as for a subclass.
-spec new_promise(term()) -> term().
new_promise(Proto) -> buoy_heap:new_exotic(promise, Proto, {pending, [], [], false}).

-spec is_promise(term()) -> boolean().
is_promise({'$o', _} = V) -> buoy_heap:class_of(V) =:= promise;
is_promise(_) -> false.

%% NewPromiseCapability(%Promise%).
-spec capability() -> {term(), fun((term()) -> term()), fun((term()) -> term())}.
capability() ->
    P = new_promise(),
    {Resolve, Reject} = resolving_functions(P),
    {P, Resolve, Reject}.

%% CreateResolvingFunctions: the pair shares one alreadyResolved flag, a cell.
-spec resolving_functions(term()) -> {fun((term()) -> term()), fun((term()) -> term())}.
resolving_functions(P) ->
    Done = buoy_heap:cell(false),
    Resolve = fun(V) ->
                      case buoy_heap:cell_get(Done) of
                          true -> undefined;
                          false -> buoy_heap:cell_set(Done, true), resolve_promise(P, V), undefined
                      end
              end,
    Reject = fun(R) ->
                     case buoy_heap:cell_get(Done) of
                         true -> undefined;
                         false -> buoy_heap:cell_set(Done, true), reject_promise(P, R), undefined
                     end
             end,
    {Resolve, Reject}.

%% The steps of a promise resolve function after the alreadyResolved check.
-spec resolve_promise(term(), term()) -> ok.
resolve_promise(P, P) ->
    reject_promise(P, buoy_heap:error_object('TypeError', <<"Chaining cycle detected for promise #<Promise>">>, <<>>));
resolve_promise(P, V) ->
    case buoy_heap:is_object(V) of
        false ->
            fulfill(P, V);
        true ->
            try buoy_heap:get(V, <<"then">>) of
                Then ->
                    case buoy_heap:is_callable(Then) of
                        true -> enqueue(fun() -> resolve_thenable_job(P, V, Then) end);
                        false -> fulfill(P, V)
                    end
            catch
                error:Reason:Stack -> reject_promise(P, buoy_ref:caught(Reason, Stack))
            end
    end.

%% NewPromiseResolveThenableJob.
resolve_thenable_job(P, Thenable, Then) ->
    {Resolve, Reject} = resolving_functions(P),
    try buoy_heap:call(Then, Thenable, [js_function(Resolve), js_function(Reject)]) of
        _ -> ok
    catch
        error:Reason:Stack -> Reject(buoy_ref:caught(Reason, Stack))
    end.

%% A promise resolve or reject function, or another builtin of one
%% parameter that the promise machinery hands to user code: length 1 and an
%% empty name, as CreateBuiltinFunction gives.
-spec js_function(fun((term()) -> term())) -> term().
js_function(Fun) -> buoy_heap:function(fun(_This, Args) -> Fun(arg(Args)) end, <<>>, 1, #{}).

arg([V | _]) -> V;
arg([]) -> undefined.

fulfill(P, V) ->
    {pending, Fulfill, _, Handled} = buoy_heap:slots(P),
    buoy_heap:set_slots(P, {fulfilled, V, Handled}),
    trigger(Fulfill, V).

-spec reject_promise(term(), term()) -> ok.
reject_promise(P, Reason) ->
    {pending, _, Reject, Handled} = buoy_heap:slots(P),
    buoy_heap:set_slots(P, {rejected, Reason, Handled}),
    Handled orelse track(P),
    trigger(Reject, Reason).

trigger(Reactions, Argument) ->
    lists:foreach(fun(Reaction) -> enqueue(fun() -> reaction_job(Reaction, Argument) end) end, lists:reverse(Reactions)).

%% PromiseReactionJob.
reaction_job({_Kind, undefined, Handler}, Argument) ->
    invoke(Handler, Argument);
reaction_job({Kind, {_, Resolve, Reject}, Handler}, Argument) ->
    Outcome = case Handler of
        undefined when Kind =:= fulfill -> {ok, Argument};
        undefined -> {error, Argument};
        _ ->
            try invoke(Handler, Argument) of
                V -> {ok, V}
            catch
                error:Reason:Stack -> {error, buoy_ref:caught(Reason, Stack)}
            end
    end,
    case Outcome of
        {ok, Value} -> invoke(Resolve, Value);
        {error, Error} -> invoke(Reject, Error)
    end.

%% Calls a handler or a resolving function: an Erlang fun of one argument or
%% a JavaScript function.
-spec invoke(term(), term()) -> term().
invoke(F, Argument) when is_function(F, 1) -> F(Argument);
invoke(F, Argument) -> buoy_heap:call(F, undefined, [Argument]).

-spec perform_then(term(), term(), term(), undefined | tuple()) -> ok.
perform_then(P, OnFulfilled, OnRejected, Capability) ->
    FulfillReaction = {fulfill, Capability, handler(OnFulfilled)},
    RejectReaction = {reject, Capability, handler(OnRejected)},
    case buoy_heap:slots(P) of
        {pending, Fulfill, Reject, _} ->
            buoy_heap:set_slots(P, {pending, [FulfillReaction | Fulfill], [RejectReaction | Reject], true});
        {fulfilled, V, _} ->
            buoy_heap:set_slots(P, {fulfilled, V, true}),
            enqueue(fun() -> reaction_job(FulfillReaction, V) end);
        {rejected, R, Handled} ->
            Handled orelse untrack(P),
            buoy_heap:set_slots(P, {rejected, R, true}),
            enqueue(fun() -> reaction_job(RejectReaction, R) end)
    end,
    ok.

handler(F) when is_function(F, 1) -> F;
handler({'$f', _, _} = F) -> F;
handler(_) -> undefined.

%% PromiseResolve(%Promise%, V): a promise of the intrinsic constructor is
%% itself, anything else a new promise resolved with V.
-spec promise_resolve(term()) -> term().
promise_resolve(V) ->
    case is_promise(V) andalso buoy_heap:get(V, <<"constructor">>) =:= buoy_ref_promise:constructor() of
        true ->
            V;
        false ->
            {P, Resolve, _} = capability(),
            Resolve(V),
            P
    end.

-spec fulfilled(term()) -> term().
fulfilled(V) -> promise_resolve(V).

-spec rejected(term()) -> term().
rejected(Reason) ->
    {P, _, Reject} = capability(),
    Reject(Reason),
    P.

%% Await(V) with the continuations of the async function: Erlang funs of one
%% argument. The function goes on in a later microtask.
-spec await(term(), fun((term()) -> term()), fun((term()) -> term())) -> ok.
await(V, OnFulfilled, OnRejected) ->
    perform_then(promise_resolve(V), OnFulfilled, OnRejected, undefined).

%% The body of an async function: Body(Resolve, Reject) runs until its first
%% await, and the call returns the promise of the function.
-spec async_call(fun((fun((term()) -> term()), fun((term()) -> term())) -> term())) -> term().
async_call(Body) ->
    {P, Resolve, Reject} = capability(),
    try Body(Resolve, Reject) of
        _ -> ok
    catch
        error:Reason:Stack -> Reject(buoy_ref:caught(Reason, Stack))
    end,
    P.

%% A promise that fulfills when every promise of the list has, or rejects
%% with the first rejection. Module evaluation waits for its async
%% dependencies with it, and no user code observes its steps, so it skips
%% the lookups of Promise.all (buoy_ref_promise).
-spec all([term()]) -> term().
all(Promises) ->
    {P, Resolve, Reject} = capability(),
    Left = buoy_heap:cell(length(Promises) + 1),
    Done = fun(_) ->
                   case buoy_heap:cell_set(Left, buoy_heap:cell_get(Left) - 1) of
                       0 -> Resolve(undefined);
                       _ -> undefined
                   end
           end,
    [perform_then(promise_resolve(Item), Done, Reject, undefined) || Item <- Promises],
    _ = Done(undefined),
    P.

%%% Unhandled rejections: a promise rejected without a handler at the end of
%%% a job ends the program, as in Node.

%% In a realm that runs Node's lib, its rejection callback tracks them instead.
track(P) ->
    {rejected, Reason, _} = buoy_heap:slots(P),
    buoy_node_loop:reject_hook(0, P, Reason)
        orelse erlang:put(?UNHANDLED, [P | pending_list(?UNHANDLED)]).

untrack(P) ->
    buoy_node_loop:reject_hook(1, P, undefined)
        orelse erlang:put(?UNHANDLED, lists:delete(P, pending_list(?UNHANDLED))).

pending_list(Key) ->
    case erlang:get(Key) of
        undefined -> [];
        L -> L
    end.

%% A test262 host, as buoy_test262 is, sets '$buoy_rejections' to ignore: such hosts
%% do not end a test for a rejection that no handler takes.
check_unhandled() ->
    case {pending_list(?UNHANDLED), erlang:get('$buoy_rejections')} of
        {[], _} ->
            ok;
        {_, ignore} ->
            erlang:erase(?UNHANDLED),
            ok;
        {[P | _], _} ->
            {rejected, Reason, _} = buoy_heap:slots(P),
            buoy_ref:report_uncaught(Reason)
    end.

%%% Timers

loop_now() ->
    case erlang:get(?NOW) of
        undefined -> update_now();
        Now -> Now
    end.

update_now() ->
    Now = erlang:monotonic_time(millisecond),
    erlang:put(?NOW, Now),
    Now.

%% setTimeout and setInterval: a delay below 1 or above 2^31 - 1 is 1, as in Node.
-spec set_timer(term(), term(), list(), boolean()) -> pos_integer().
set_timer(Callback, Delay, Args, Repeat) ->
    Ms = case Delay of
        D when is_number(D), D >= 1, D =< ?MAX_DELAY -> trunc(D);
        _ -> 1
    end,
    Id = case erlang:get(?TIMER_SEQ) of
        undefined -> 1;
        N -> N + 1
    end,
    erlang:put(?TIMER_SEQ, Id),
    Timers = timers(),
    Due = loop_now() + Ms,
    _ = erlang:send_after(max(0, Due - erlang:monotonic_time(millisecond)), self(), {'$buoy_timer', Id}),
    erlang:put(?TIMERS, Timers#{Id => {Due, Callback, Args, case Repeat of true -> Ms; false -> none end}}),
    Id.

-spec clear_timer(term()) -> undefined.
clear_timer(Id) ->
    erlang:put(?TIMERS, maps:remove(Id, timers())),
    undefined.

timers() ->
    case erlang:get(?TIMERS) of
        undefined -> #{};
        T -> T
    end.

%% The timers phase: every timer due by now, in due order and then creation
%% order. A stale message, of a cleared or rearmed timer, finds nothing due.
run_due_timers() ->
    Now = update_now(),
    Due = lists:sort([{At, Id} || Id := {At, _, _, _} <- timers(), At =< Now]),
    lists:foreach(fun({_, Id}) -> run_timer(Id) end, Due).

run_timer(Id) ->
    case timers() of
        #{Id := {_, Callback, Args, Repeat}} = Timers ->
            case Repeat of
                none ->
                    erlang:put(?TIMERS, maps:remove(Id, Timers));
                Ms ->
                    Next = loop_now() + Ms,
                    _ = erlang:send_after(Ms, self(), {'$buoy_timer', Id}),
                    erlang:put(?TIMERS, Timers#{Id := {Next, Callback, Args, Repeat}})
            end,
            run_job(fun() -> buoy_heap:call(Callback, undefined, Args) end);
        _ ->
            ok
    end.

%%% The realm loop

%% Node bootstraps before the code of -e and -p runs, and internal/main/buoy
%% hands that code each built-in module as a global, as eval_string does.
eval_bootstrap() ->
    init:get_argument(buoy_eval) =:= error orelse buoy_node:ensure().

%% Runs the top-level code of the entry module as the first job, then serves
%% timers and replies until no work is left, as Node does.
-spec run_main(fun(() -> term())) -> ok.
run_main(Body) ->
    buoy_ref:init_realm(),
    update_now(),
    %% The result lives under a pdict key, a root, so a collection keeps it.
    run_job(fun() -> eval_bootstrap(), erlang:put(?MAIN, Body()) end),
    loop_until_exit(),
    case erlang:get(?MAIN) of
        {'$o', _} = P ->
            case is_promise(P) andalso buoy_heap:slots(P) of
                {pending, _, _, _} ->
                    io:put_chars(buoy_ref:stderr(), "Warning: Detected unsettled top-level await\n"),
                    buoy_ref:exit_program(13);
                _ ->
                    ok
            end;
        _ ->
            ok
    end.

%% One macrotask: the job, every microtask it queues, and then a collection
%% when the heap grew enough since the last one.
-spec run_job(fun(() -> term())) -> ok.
run_job(Job) ->
    try
        _ = Job(),
        after_job()
    catch
        error:Reason:Stack -> uncaught(buoy_ref:caught(Reason, Stack))
    end,
    check_unhandled(),
    maybe_gc().

%% After a job: the microtasks, and in a realm that runs Node's lib, its
%% ticks (buoy_node_loop).
after_job() ->
    case buoy_node:ready() of
        true -> buoy_node_loop:after_callback();
        false -> drain()
    end.

%% An exception that reached the top of a job: Node's lib decides in a realm
%% that runs it, else the program ends.
uncaught(Error) ->
    case buoy_node:ready() of
        true -> buoy_node_loop:uncaught(Error, false);
        false -> buoy_ref:report_uncaught(Error)
    end.

%% The loop, then Node's 'beforeExit', which may queue more work.
loop_until_exit() ->
    loop(),
    case buoy_node:ready() of
        true ->
            buoy_node_loop:finish(),
            loop_until_exit();
        false ->
            ok
    end.

%% Collects when the realm allocated more ids since the last collection than
%% twice the live count then, and at least ?GC_MIN, so the cost stays in
%% proportion to the allocation.
maybe_gc() ->
    {At, Live} = case erlang:get(?LAST_GC) of
        undefined -> {0, 0};
        L -> L
    end,
    Allocated = buoy_heap:allocated(),
    case Allocated - At >= max(?GC_MIN, 2 * Live) of
        true ->
            #{live := Live1} = buoy_heap:gc([]),
            erlang:put(?LAST_GC, {Allocated, Live1});
        false ->
            ok
    end.

%% Waits for messages while the realm has work: timers, replies it waits
%% for, or, in an actor, always. Without work, it still takes the messages
%% that have arrived, such as the wake of an async wait that the realm
%% notified itself.
-spec loop() -> ok.
loop() ->
    case has_work() of
        false ->
            receive
                Message -> event_step(Message), loop()
            after 0 ->
                ok
            end;
        true ->
            receive
                stop -> ok;
                Message -> event_step(Message), buoy_node_loop:check(), loop()
            after buoy_node_loop:poll_timeout() ->
                buoy_node_loop:check(),
                loop()
            end
    end.

-spec has_work() -> boolean().
has_work() ->
    erlang:get(?THIS) =/= undefined orelse map_size(timers()) > 0 orelse map_size(pending()) > 0
        orelse buoy_node_loop:has_work().

pending() ->
    case erlang:get(?PENDING) of
        undefined -> #{};
        P -> P
    end.

%% One BEAM message becomes at most one job.
-spec event_step(term()) -> ok.
event_step({'$buoy_node_timer', _} = Message) ->
    _ = buoy_node_loop:event(Message),
    ok;
event_step({'$buoy_node_deferred', _} = Message) ->
    _ = buoy_node_loop:event(Message),
    ok;
event_step({'$buoy_node_call', _} = Message) ->
    update_now(),
    _ = buoy_node_loop:event(Message),
    ok;
event_step({'$buoy_timer', _Id}) ->
    run_due_timers();
event_step({'$buoy_atomics_wake', _} = Event) ->
    update_now(),
    buoy_ref_atomics:async_event(Event);
event_step({'$buoy_atomics_timeout', _} = Event) ->
    update_now(),
    buoy_ref_atomics:async_event(Event);
event_step({'$buoy_reply', Tag, Outcome}) ->
    update_now(),
    case maps:take(Tag, pending()) of
        {{Resolve, Reject, Monitor}, Rest} ->
            erlang:demonitor(Monitor, [flush]),
            erlang:put(?PENDING, Rest),
            run_job(fun() ->
                            case Outcome of
                                {ok, Term} -> Resolve(buoy_heap:clone_in(Term));
                                {error, Term} -> Reject(buoy_heap:clone_in(Term))
                            end
                    end);
        error ->
            ok
    end;
event_step({'DOWN', Monitor, process, _Pid, Reason}) ->
    update_now(),
    Failed = [{Tag, Reject} || Tag := {_, Reject, M} <- pending(), M =:= Monitor],
    erlang:put(?PENDING, maps:without([Tag || {Tag, _} <- Failed], pending())),
    [run_job(fun() -> Reject(buoy_heap:error_object('Error', iolist_to_binary(io_lib:format("actor stopped: ~p", [Reason])), <<>>)) end) || {_, Reject} <- Failed],
    ok;
event_step({'$buoy_call', From, Tag, Method, Args}) ->
    update_now(),
    case erlang:get(?BUSY) of
        true -> erlang:put(?CALLS, pending_list(?CALLS) ++ [{From, Tag, Method, Args}]);
        _ -> start_turn(From, Tag, Method, Args)
    end;
event_step('$buoy_next_turn') ->
    update_now(),
    case pending_list(?CALLS) of
        [{From, Tag, Method, Args} | Rest] ->
            erlang:put(?CALLS, Rest),
            start_turn(From, Tag, Method, Args);
        [] ->
            ok
    end;
event_step(_Other) ->
    ok.

%%% Actors: one realm each. A turn is one call, from its start until the
%%% promise of the method settles, and the next call waits for it, so turns
%%% never interleave even when a method awaits.

%% The class is {Module, Name}, a class of Module, or {export, Module, Key}, an
%% export of Module that the actor's module imports.
-spec spawn_actor({module(), binary() | {export, binary()}} | {export, module(), binary()}, list()) -> {'$actor', pid()}.
spawn_actor({export, Module, Key}, Args) ->
    spawn_actor({Module, {export, Key}}, Args);
spawn_actor({Module, Class}, Args) ->
    Term = buoy_heap:clone_out(buoy_heap:new_array(Args)),
    Parent = self(),
    Tag = make_ref(),
    Pid = spawn(fun() -> actor_init(Parent, Tag, Module, Class, Term) end),
    Monitor = erlang:monitor(process, Pid),
    receive
        {Tag, ok} ->
            erlang:demonitor(Monitor, [flush]),
            {'$actor', Pid};
        {Tag, {error, Error}} ->
            erlang:demonitor(Monitor, [flush]),
            erlang:error({'$throw', buoy_heap:clone_in(Error)});
        {'DOWN', Monitor, process, Pid, Reason} ->
            buoy_heap:throw_error('Error', iolist_to_binary(io_lib:format("actor failed to start: ~p", [Reason])))
    end.

actor_init(Parent, Tag, Module, Class, ArgsTerm) ->
    buoy_ref:init_realm(),
    update_now(),
    try
        buoy_module:evaluate_dependencies(Module),
        C = case Class of
            {export, Key} -> Module:'$export'(Key);
            _ -> Module:'$class'(Class)
        end,
        This = buoy_heap:construct(C, buoy_heap:array_items(buoy_heap:clone_in(ArgsTerm)), C),
        erlang:put(?THIS, This),
        drain(),
        Parent ! {Tag, ok}
    catch
        error:Reason:Stack -> Parent ! {Tag, {error, buoy_heap:clone_out(buoy_ref:caught(Reason, Stack))}}
    end,
    loop().

start_turn(From, Tag, Method, ArgsTerm) ->
    erlang:put(?BUSY, true),
    Reply = fun(Outcome) ->
                    From ! {'$buoy_reply', Tag, Outcome},
                    erlang:put(?BUSY, false),
                    self() ! '$buoy_next_turn',
                    undefined
            end,
    run_job(fun() ->
                    This = erlang:get(?THIS),
                    try buoy_ref:call_method(This, Method, buoy_heap:array_items(buoy_heap:clone_in(ArgsTerm))) of
                        Result ->
                            case is_promise(Result) of
                                true ->
                                    perform_then(Result, fun(V) -> Reply(outcome(ok, V)) end,
                                                 fun(E) -> Reply(outcome(error, E)) end, undefined);
                                false ->
                                    Reply(outcome(ok, Result))
                            end
                    catch
                        error:Reason:Stack -> Reply(outcome(error, buoy_ref:caught(Reason, Stack)))
                    end
            end).

outcome(Kind, Value) ->
    try {Kind, buoy_heap:clone_out(Value)}
    catch
        error:{'$throw', CloneError} -> {error, buoy_heap:clone_out(CloneError)}
    end.

%% ref.method(...args) from any realm: a promise of the reply.
-spec actor_call(pid(), binary(), list()) -> term().
actor_call(Pid, Method, Args) ->
    Term = buoy_heap:clone_out(buoy_heap:new_array(Args)),
    {P, Resolve, Reject} = capability(),
    Tag = make_ref(),
    Monitor = erlang:monitor(process, Pid),
    erlang:put(?PENDING, (pending())#{Tag => {Resolve, Reject, Monitor}}),
    Pid ! {'$buoy_call', self(), Tag, Method, Term},
    P.

-spec stop_actor(pid()) -> undefined.
stop_actor(Pid) ->
    Pid ! stop,
    undefined.
