-module(bouy_actor).

%% An actor is a process that runs a receive loop over the class module and
%% `This`. A turn is one call or one cast, and the process handles one
%% message at a time, so turns never interleave. The loop is not a
%% gen_server: a call is one message and one reply to the alias of a monitor,
%% which is all that the contract needs, and it costs less than gen_server.
%%
%% Messages to an actor process:
%%   {'$call', Alias, Method, Args, Chain}  replies {Alias, {ok, V} | {throw, E}}
%%   {'$cast', Method, Args}
%%   {'$room', Alias, Method, Args}         a cast that waits: replies {Alias, true}
%%                                          when the actor takes it
%%
%% A turn runs with its context in the process dictionary: its call chain,
%% its own actor id first and then the ids of the actors that wait on it. A
%% call to an actor in the chain throws CallCycle instead of a deadlock. A
%% call that waits also records the wait in the wait-for graph of
%% bouy_registry, so two turns that call each other at once see the cycle.
%%
%% A sender reads only the mode of the actor (bouy_registry). When the actor
%% has no process that can take the request, the sender waits for the next
%% change of the mode, which bouy_registry announces, or for the end of the
%% supervisor of the actor. It never polls.

-export([start/1, start_link/1, spawn_options/1, init_alone/2, init_tree/2, init_ready/4, class_functions/2, call/3, cast/3, offer/3, stop/1, snapshot/1]).
-export([report_out_of_memory/1, send_call/4, call_outcome/4]).
-export([context/0, adopt/1, within/2, live/1, chain/0, current/0, current_id/0, owner/0, constructing/0]).
-export([loop/2]).

-export_type([spec/0, context/0]).

-define(CONTEXT, '$bouy_context').
%% The message queue of an actor stays off its heap, so a mailbox that fills
%% to its capacity does not grow the heap that each garbage collection copies.
-define(SPAWN, [{message_queue_data, off_heap}]).
%% A group ends a child with an exit signal `shutdown`, so the reason `killed`
%% names the memory limit of the process, unless stop() marked the actor first.
-define(SHUTDOWN, 5000).

-type ref() :: {'$ref', pos_integer()}.
-type error_value() :: #{'$error' := list(), binary() => term()}.
-type spec() :: #{
    id := pos_integer(),
    module := module(),
    class := binary(),
    args := list(),
    name := binary() | undefined,
    mailbox := bouy_registry:mailbox(),
    restart := bouy_registry:restart(),
    max_memory => pos_integer() | infinity,
    supervisor := pid(),
    group := alone | tree,
    chain => [pos_integer()],
    owner => pid() | none,
    functions => {atom(), atom(), boolean()}
}.
%% What a caller needs from the mode of an actor before it sends a request.
-type need() :: alive | {ready, [pos_integer()]}.

%% What the code in a process acts for: the actor and the call chain of the
%% turn, the scopes that must still be live for the chain to hold, the owner
%% (the process of the actor, or of the top-level code), and whether a
%% constructor runs.
-record(context, {
    actor :: pos_integer() | undefined,
    chain = [] :: [pos_integer()],
    scopes = [] :: [atomics:atomics_ref()],
    owner :: pid(),
    constructing = false :: boolean()
}).
-opaque context() :: #context{}.

-record(state, {
    id :: pos_integer(),
    label :: binary(),
    module :: module(),
    dispatch :: atom(),
    restart :: bouy_registry:restart(),
    supervisor :: pid(),
    group :: alone | tree,
    counter :: atomics:atomics_ref(),
    %% The context of a turn whose chain is only this actor: every cast, and
    %% each call from code outside an actor.
    alone :: #context{}
}).
%% The loop holds the state, which stays fixed for the life of the process,
%% and `This` beside it, so a turn does not copy the state.
-type state() :: #state{}.
%% Starts the actor of Spec and returns when its constructor has finished.
%% When the constructor throws, the start fails with ActorFailed and the
%% actor is stopped. A spawned actor runs as a process linked to bouy_keeper;
%% a child of supervise() runs under its group supervisor.
-spec start(spec()) -> ok | {error, error_value()}.
start(#{group := alone, functions := Functions} = Spec) ->
    case {Functions, maps:get(max_memory, Spec, infinity)} of
        {{Dispatch, New, true}, infinity} -> start_ready(Spec, Dispatch, New);
        _Waits -> start_alone(Spec)
    end;
start(#{id := Id, supervisor := Group, restart := Restart} = Spec) ->
    Child = #{
        id => Id,
        start => {?MODULE, start_link, [Spec]},
        restart => otp_restart(Restart),
        shutdown => ?SHUTDOWN
    },
    try supervisor:start_child(Group, Child) of
        {ok, _Pid} ->
            ok;
        {error, {{constructor_failed, Cause}, _Child}} ->
            _ = bouy_registry:mark_stopped(Id),
            {error, actor_failed(label(Spec), <<"constructor">>, Cause)};
        {error, {killed, _Child}} ->
            ended_during_constructor(Spec, killed);
        {error, Reason} ->
            ended_during_constructor(Spec, Reason)
    catch
        %% stop() killed the group while the constructor ran.
        exit:_ ->
            _ = bouy_registry:mark_stopped(Id),
            ok
    end.

%% The constructor runs in the new process, which reports when it has ended.
start_alone(Spec) ->
    {Pid, Monitor} = erlang:spawn_opt(?MODULE, init_alone, [Spec, self()], [monitor | spawn_options(Spec)]),
    receive
        {started, Pid, Outcome} ->
            true = demonitor(Monitor, [flush]),
            Outcome;
        {'DOWN', Monitor, process, Pid, Reason} ->
            ended_during_constructor(Spec, Reason)
    end.

%% A pure constructor (contract section 9) has no effect and cannot throw, so it
%% runs here, and the new process starts with its `This` and enters its loop at
%% once. No one can send to the actor before spawn() returns its ref, so the row
%% is written after the process starts. An actor with a memory limit takes the
%% other path, since the limit could end its process before the link to the
%% keeper.
start_ready(#{id := Id, module := Module, args := Args} = Spec, Dispatch, New) ->
    This = Module:New(Args),
    Counter = atomics:new(1, []),
    Pid = erlang:spawn_opt(?MODULE, init_ready, [Spec, Dispatch, Counter, This], ?SPAWN),
    ok = bouy_registry:enter_ready(Id, Pid, Counter, Spec),
    watch(Spec, 1).

%% stop() ended the actor while its constructor ran, as when a constructor
%% stops its own actor: the actor exists, stopped. A kill without the mark of
%% stop() is the memory limit. Any other end fails the start.
ended_during_constructor(#{id := Id} = Spec, Reason) ->
    Marked = bouy_registry:mode(Id) =:= stopped,
    _ = bouy_registry:mark_stopped(Id),
    case {Reason, Marked} of
        {killed, true} ->
            ok;
        {killed, false} ->
            {error, report_out_of_memory(Spec)};
        _ ->
            Message = unicode:characters_to_binary(io_lib:format("~0tp", [Reason])),
            {error, actor_failed(label(Spec), <<"constructor">>, bouy_error:new(<<"Error">>, Message))}
    end.

%% A crash exits with a {shutdown, _} reason, and OTP restarts a child after
%% such an exit only when the child is permanent. An actor never exits
%% normally, so a transient actor is a permanent OTP child.
otp_restart(temporary) -> temporary;
otp_restart(_) -> permanent.

%% The start function of a child of supervise(), which its group supervisor
%% calls: the process is linked to the supervisor, and the call returns when
%% the constructor has finished.
-spec start_link(spec()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Spec) ->
    {Pid, Monitor} = erlang:spawn_opt(?MODULE, init_tree, [Spec, self()], [link, monitor | spawn_options(Spec)]),
    receive
        {started, Pid, Outcome} ->
            true = demonitor(Monitor, [flush]),
            Outcome;
        {'DOWN', Monitor, process, Pid, Reason} ->
            {error, Reason}
    end.

%% The spawn options of an actor process. A memory limit kills the process at
%% the collection that finds its heap and its binaries past the limit.
-spec spawn_options(#{max_memory => pos_integer() | infinity, _ => _}) -> [erlang:spawn_opt_option()].
spawn_options(#{max_memory := Bytes}) when is_integer(Bytes) ->
    MaxHeap = #{
        size => Bytes div erlang:system_info(wordsize),
        kill => true,
        error_logger => false,
        include_shared_binaries => true
    },
    [{max_heap_size, MaxHeap} | ?SPAWN];
spawn_options(_Spec) ->
    ?SPAWN.

%% The process of a spawned actor, on its first start (Starter waits for the
%% constructor) and on each restart by bouy_keeper (Starter is `none`).
-spec init_alone(spec(), pid() | none) -> no_return().
init_alone(#{id := Id, supervisor := Keeper} = Spec, Starter) ->
    true = link(Keeper),
    case begin_process(Spec) of
        {ok, State, This, Starts} ->
            started(Starter, ok),
            wait_first(State, This, Starts);
        {failed, Cause} when Starter =/= none ->
            _ = bouy_registry:mark_stopped(Id),
            started(Starter, {error, actor_failed(label(Spec), <<"constructor">>, Cause)}),
            exit(crashed(Id));
        {failed, _Cause} ->
            exit(crashed(Id));
        stopped ->
            exit({shutdown, stopped})
    end.

%% The process of a spawned actor whose constructor ran in the spawner.
-spec init_ready(spec(), atom(), atomics:atomics_ref(), term()) -> no_return().
init_ready(#{supervisor := Keeper} = Spec, Dispatch, Counter, This) ->
    true = link(Keeper),
    erlang:hibernate(?MODULE, loop, [state(Spec, Dispatch, Counter), This]).

%% The process of a child of supervise(). A constructor that throws fails the
%% start, and the process then ends normally, as a gen_server whose init/1
%% returns an error ends, so the group sees no crash.
-spec init_tree(spec(), pid()) -> ok.
init_tree(Spec, Starter) ->
    case begin_process(Spec) of
        {ok, State, This, Starts} ->
            started(Starter, {ok, self()}),
            wait_first(State, This, Starts);
        {failed, Cause} ->
            started(Starter, {error, {constructor_failed, Cause}});
        stopped ->
            started(Starter, ignore)
    end.

%% A first process waits for its first request hibernated, so an actor that
%% takes no request holds only its live data. A restarted process does not:
%% the callers that waited for the restart call it at once.
wait_first(State, This, 1) -> erlang:hibernate(?MODULE, loop, [State, This]);
wait_first(State, This, _Starts) -> loop(State, This).

started(none, _Outcome) ->
    ok;
started(Starter, Outcome) ->
    Starter ! {started, self(), Outcome},
    ok.

%% A crash exits quietly with the id, so bouy_keeper knows which actor to
%% restart.
crashed(Id) -> {shutdown, {crashed, Id}}.

-spec call(ref(), binary(), list()) -> term().
call({'$ref', Id}, Method, Args) ->
    case chain() of
        [] -> request(Id, Method, Args, [], none);
        Chain -> chained_call(Id, Method, Args, Chain)
    end.

%% A call from a turn records its wait, and fails at once on a cycle.
chained_call(Id, Method, Args, Chain) ->
    Waited =
        case lists:member(Id, Chain) of
            true -> cycle;
            false -> waiting(Chain, Id, fun() -> request(Id, Method, Args, Chain, none) end)
        end,
    case Waited of
        {done, Value} -> Value;
        cycle -> raise(call_cycle(known(Id)))
    end.

%% Dead is a process that the request found dead and that the mode may still
%% name, or `none`.
request(Id, Method, Args, Chain, Dead) ->
    {Pid, Counter, Count, Mailbox} = admit(Id, {ready, Chain}, Dead),
    case Mailbox of
        {Capacity, reject} when Count > Capacity ->
            release(Counter),
            raise(mailbox_full(known(Id)));
        _ ->
            ok
    end,
    Alias = monitor(process, Pid, [{alias, reply_demonitor}]),
    Pid ! {'$call', Alias, Method, Args, Chain},
    Reply =
        receive
            {Alias, Answer} -> Answer;
            {'DOWN', Alias, process, Pid, Reason} -> {down, Reason}
        end,
    case reply_outcome(Id, Counter, Reply) of
        {ok, Value} -> Value;
        {raised, error, Thrown, _Stack} -> erlang:error(Thrown);
        wait -> request(Id, Method, Args, Chain, Pid)
    end.

%% The outcome of a call from the reply, or from the reason of the 'DOWN' of
%% the process. A process that was already gone gives `wait`: the call goes
%% again, past that process. A kill without the mark of stop() is the memory
%% limit.
reply_outcome(Id, Counter, Reply) ->
    case Reply of
        {ok, Value} ->
            {ok, Value};
        {throw, Error} ->
            {raised, error, {'$throw', Error}, []};
        {down, noproc} ->
            release(Counter),
            wait;
        {down, killed} ->
            release(Counter),
            error_outcome(fun() ->
                case known(Id) of
                    #{mode := stopped} = Actor -> stopped(Actor);
                    Actor -> out_of_memory(Actor)
                end
            end);
        {down, _Reason} ->
            release(Counter),
            error_outcome(fun() -> stopped(known(Id)) end)
    end.

%%% Calls that one process sends together (bouy_task:map_call/3)

%% Sends one call of a batch when the actor runs and the call needs no wait:
%% `{sent, Alias, Pid, Counter}`, and call_outcome/4 takes the reply. A call
%% that would throw at once gives its error, and a call that must wait, for a
%% constructor or a restart, gives `wait`, so the caller makes it with call/3.
%% A call from a turn records its wait in the graph, as call/3 does, until
%% call_outcome/4.
-spec send_call(pos_integer(), binary(), list(), [pos_integer()]) ->
    {sent, reference(), pid(), atomics:atomics_ref()} | {raised, error_value()} | wait.
send_call(Id, Method, Args, []) ->
    send_request(Id, Method, Args, []);
send_call(Id, Method, Args, [From | _] = Chain) ->
    #context{scopes = Scopes, constructing = Constructing} = context(),
    case lists:member(Id, Chain) of
        true ->
            sent_error(fun() -> call_cycle(known(Id)) end);
        false when Constructing ->
            wait;
        false ->
            ok = bouy_registry:wait(From, Id, Scopes),
            Sent =
                case reaches([Id], Chain, #{}) of
                    true -> sent_error(fun() -> call_cycle(known(Id)) end);
                    false -> send_request(Id, Method, Args, Chain)
                end,
            case Sent of
                {sent, _, _, _} -> ok;
                _ -> ok = bouy_registry:unwait(From, Id, Scopes)
            end,
            Sent
    end.

send_request(Id, Method, Args, Chain) ->
    case bouy_registry:mode(Id) of
        {running, Pid, Counter, Mailbox} ->
            Count = atomics:add_get(Counter, 1, 1),
            case Mailbox of
                {Capacity, reject} when Count > Capacity ->
                    release(Counter),
                    sent_error(fun() -> mailbox_full(known(Id)) end);
                _ ->
                    Alias = monitor(process, Pid, [{alias, reply_demonitor}]),
                    Pid ! {'$call', Alias, Method, Args, Chain},
                    {sent, Alias, Pid, Counter}
            end;
        _NotRunning ->
            wait
    end.

%% The outcome of a call that send_call/4 sent, as reply_outcome/3 gives it,
%% once the wait that send_call/4 recorded is gone.
-spec call_outcome(pos_integer(), atomics:atomics_ref(), [pos_integer()], Reply) ->
    {ok, term()} | {raised, error, term(), list()} | wait
when Reply :: {ok, term()} | {throw, term()} | {down, term()}.
call_outcome(Id, Counter, Chain, Reply) ->
    case Chain of
        [From | _] -> ok = bouy_registry:unwait(From, Id, (context())#context.scopes);
        [] -> ok
    end,
    reply_outcome(Id, Counter, Reply).

%% The error that Build() returns, as the result of send_call/4. known/1 may
%% throw ActorStopped instead, for a forgotten actor.
sent_error(Build) ->
    {raised, error, {'$throw', Error}, _Stack} = error_outcome(Build),
    {raised, Error}.

%% The error that Build() returns or throws, as the outcome of a call.
error_outcome(Build) ->
    try Build() of
        Error -> {raised, error, {'$throw', Error}, []}
    catch
        error:{'$throw', Error}:Stack -> {raised, error, {'$throw', Error}, Stack}
    end.

-spec cast({'$cast', pos_integer()}, binary(), list()) -> true.
cast({'$cast', Id}, Method, Args) ->
    cast(Id, Method, Args, none).

cast(Id, Method, Args, Dead) ->
    {Pid, Counter, Count, {Capacity, Overflow}} = admit(Id, alive, Dead),
    case {Count =< Capacity, Overflow} of
        {true, _} ->
            send(Pid, Method, Args);
        {false, reject} ->
            release(Counter),
            raise(mailbox_full(known(Id)));
        {false, backpressure} ->
            wait_for_room(Id, Pid, Counter, Method, Args)
    end.

%% A cast that never waits, for the timer of schedule(): a full mailbox, or
%% an actor that restarts, skips it, so the timer stays free to stop.
-spec offer({'$cast', pos_integer()}, binary(), list()) -> sent | skipped | stopped.
offer({'$cast', Id}, Method, Args) ->
    case bouy_registry:mode(Id) of
        {_Phase, Pid, Counter, {Capacity, _}} ->
            case atomics:add_get(Counter, 1, 1) =< Capacity of
                true ->
                    send(Pid, Method, Args),
                    sent;
                false ->
                    release(Counter),
                    skipped
            end;
        restarting ->
            case bouy_registry:find(Id) of
                {ok, Actor} -> skipped_unless_stopped(status(Actor));
                error -> stopped
            end;
        _StoppedOrForgotten ->
            stopped
    end.

skipped_unless_stopped(stopped) -> stopped;
skipped_unless_stopped(_Status) -> skipped.

send(Pid, Method, Args) ->
    Pid ! {'$cast', Method, Args},
    true.

%% Takes back a request that was not sent.
release(Counter) ->
    atomics:sub(Counter, 1, 1).

%% With backpressure, the sender waits until the actor takes the cast. An
%% actor that waits on the sender, directly or through other actors, could
%% never take it, so the cast goes in at once.
wait_for_room(Id, Pid, Counter, Method, Args) ->
    Chain = chain(),
    case lists:member(Id, Chain) of
        true ->
            send(Pid, Method, Args);
        false ->
            case waiting(Chain, Id, fun() -> room(Id, Pid, Counter, Method, Args) end) of
                {done, Sent} -> Sent;
                cycle -> send(Pid, Method, Args)
            end
    end.

%% The actor replies as soon as it takes the cast. A cast lost in a crash
%% counts as sent, as any cast does; a stopped actor throws ActorStopped.
room(Id, Pid, Counter, Method, Args) ->
    Alias = monitor(process, Pid, [{alias, reply_demonitor}]),
    Pid ! {'$room', Alias, Method, Args},
    receive
        {Alias, true} ->
            true;
        {'DOWN', Alias, process, Pid, noproc} ->
            release(Counter),
            cast(Id, Method, Args, Pid);
        {'DOWN', Alias, process, Pid, _Reason} ->
            release(Counter),
            case bouy_registry:mode(Id) of
                stopped -> raise(stopped(known(Id)));
                _ -> true
            end
    end.

%% Runs Wait, which waits on actor Target, with the wait recorded in the
%% wait-for graph: `{done, Result}`, or `cycle` when Target waits on the
%% chain, directly or through other actors, so the wait would never end.
%% Each side records its wait before it looks, so of two turns that wait on
%% each other at once, at least one sees the cycle. A constructor does not
%% look, so the callers that wait for it look again.
waiting([], _Target, Wait) ->
    {done, Wait()};
waiting([From | _] = Chain, Target, Wait) ->
    #context{scopes = Scopes, constructing = Constructing} = context(),
    ok = bouy_registry:wait(From, Target, Scopes),
    try
        case Constructing of
            true ->
                ok = bouy_registry:notify(From),
                {done, Wait()};
            false ->
                case reaches([Target], Chain, #{}) of
                    true -> cycle;
                    false -> {done, Wait()}
                end
        end
    after
        bouy_registry:unwait(From, Target, Scopes)
    end.

%% Whether one of Ids waits on an actor of Chain, through the graph.
reaches([Id | Rest], Chain, Seen) ->
    case lists:member(Id, Chain) of
        true -> true;
        false when is_map_key(Id, Seen) -> reaches(Rest, Chain, Seen);
        false -> reaches(bouy_registry:waits_on(Id) ++ Rest, Chain, Seen#{Id => true})
    end;
reaches([], _Chain, _Seen) ->
    false.

%% Counts one request for actor Id and finds its process: the pid, the
%% counter of the start, the count, and the mailbox. A cast needs a live
%% process; a call also waits while the constructor runs, and looks for a
%% wait cycle meanwhile: a constructor never throws CallCycle for one, so
%% the call that waits on it does.
-spec admit(pos_integer(), need(), pid() | none) ->
    {pid(), atomics:atomics_ref(), pos_integer(), bouy_registry:mailbox()}.
admit(Id, Need, Dead) ->
    case bouy_registry:mode(Id) of
        {running, Pid, Counter, Mailbox} when Pid =/= Dead ->
            {Pid, Counter, atomics:add_get(Counter, 1, 1), Mailbox};
        {starting, Pid, Counter, Mailbox} when Need =:= alive, Pid =/= Dead ->
            {Pid, Counter, atomics:add_get(Counter, 1, 1), Mailbox};
        stopped ->
            raise(stopped(known(Id)));
        forgotten ->
            raise(stopped(known(Id)));
        _NotYet ->
            await_change(Id, Need, Dead)
    end.

%% Waits for the next change of the mode of actor Id, then admits again. The
%% watch comes before the second look, so a change between the two looks
%% still wakes this caller.
await_change(Id, Need, Dead) ->
    Ref = make_ref(),
    Watch = watch_need(Need),
    ok = bouy_registry:watch(Id, Watch, Ref),
    Outcome = standing(Id, bouy_registry:find(Id), Need, Dead),
    case Outcome of
        {waiting, Supervisor} -> until_change(Supervisor, Ref);
        _ -> ok
    end,
    ok = bouy_registry:unwatch(Id, Watch, Ref),
    flush(Ref),
    case Outcome of
        {raise, Error} -> raise(Error);
        _Retry -> admit(Id, Need, Dead)
    end.

watch_need(alive) -> alive;
watch_need({ready, _Chain}) -> ready.

%% Whether the caller can retry now, must wait for a change, or must throw.
standing(Id, error, _Need, _Dead) ->
    {raise, stopped(#{class => <<"actor">>, name => undefined, id => Id})};
standing(_Id, {ok, #{mode := stopped} = Actor}, _Need, _Dead) ->
    {raise, stopped(Actor)};
standing(_Id, {ok, #{mode := {running, Pid, _, _}}}, _Need, Dead) when Pid =/= Dead ->
    retry;
standing(_Id, {ok, #{mode := {starting, Pid, _, _}}}, alive, Dead) when Pid =/= Dead ->
    retry;
standing(Id, {ok, #{supervisor := Supervisor} = Actor}, Need, _Dead) ->
    case {status(Actor), Need} of
        {stopped, _} ->
            {raise, stopped(Actor)};
        {_, {ready, [_ | _] = Chain}} ->
            case reaches([Id], Chain, #{}) of
                true -> {raise, call_cycle(Actor)};
                false -> {waiting, Supervisor}
            end;
        _ ->
            {waiting, Supervisor}
    end.

%% A change of the mode, or the end of the supervisor, which leaves the actor
%% stopped.
until_change(Supervisor, Ref) ->
    Monitor = monitor(process, Supervisor),
    receive
        {Ref, changed} -> ok;
        {'DOWN', Monitor, process, _, _} -> ok
    end,
    true = demonitor(Monitor, [flush]),
    ok.

flush(Ref) ->
    receive
        {Ref, changed} -> ok
    after 0 -> ok
    end.

%% The row of actor Id. A ref outlives the row of a long-stopped actor, and
%% then its label has only the id.
known(Id) ->
    case bouy_registry:find(Id) of
        {ok, Actor} -> Actor;
        error -> raise(stopped(#{class => <<"actor">>, name => undefined, id => Id}))
    end.

%% An actor runs once its constructor has finished, and restarts while a
%% supervisor brings up its next process.
status(#{mode := stopped}) ->
    stopped;
status(#{mode := {Phase, Pid, _, _}, starts := Starts} = Actor) ->
    case is_process_alive(Pid) of
        true when Phase =:= running; Starts =:= 1 -> running;
        true -> restarting;
        false -> after_exit(Actor)
    end;
status(Actor) ->
    after_exit(Actor).

%% A supervisor restarts an actor without a process, unless the actor is
%% temporary or the supervisor used up its restart budget and exited.
after_exit(#{restart := temporary}) ->
    stopped;
after_exit(#{supervisor := Supervisor}) ->
    case is_process_alive(Supervisor) of
        true -> restarting;
        false -> stopped
    end.

%% Stops actor Id at once, also during a turn. Later calls throw ActorStopped.
%% Another process ends the actor, so an actor can stop itself. Only code
%% outside every actor waits for the end.
-spec stop(pos_integer()) -> ok.
stop(Id) ->
    case bouy_registry:find(Id) of
        error ->
            ok;
        {ok, Actor} ->
            _ = bouy_registry:mark_stopped(Id),
            Teardown = fun() -> stop_process(Actor) end,
            case chain() of
                [] ->
                    {Pid, Monitor} = spawn_monitor(Teardown),
                    receive
                        {'DOWN', Monitor, process, Pid, _} -> ok
                    end;
                _InsideAnActor ->
                    _ = spawn(Teardown),
                    ok
            end
    end.

%% The process is read after the mark: a restart that entered before the
%% mark ends here, and a later one sees the mark and ends itself. A group
%% never waits on the root supervisor here, so a constructor that runs in
%% the group cannot block other spawns.
stop_process(#{group := alone, id := Id}) ->
    ok = end_process(bouy_registry:pid(Id)),
    bouy_registry:drop_waits(Id);
stop_process(#{group := tree, supervisor := Group, id := Id}) ->
    try
        _ = supervisor:terminate_child(Group, Id),
        _ = supervisor:delete_child(Group, Id),
        bouy_sup:stop_when_empty(Group)
    catch
        exit:{noproc, _} -> ok
    end,
    bouy_registry:drop_waits(Id).

%% An actor traps no exits, so the signal ends it at once, and bouy_keeper
%% skips the reason without a look at the table.
end_process(Pid) when is_pid(Pid) ->
    Monitor = monitor(process, Pid),
    true = exit(Pid, {shutdown, stopped}),
    receive
        {'DOWN', Monitor, process, Pid, _} -> ok
    end;
end_process(undefined) ->
    ok.

%% One entry of inspect().
-spec snapshot(bouy_registry:actor()) -> #{binary() => term()}.
snapshot(#{id := Id, name := Name, class := Class, starts := Starts, pid := Pid} = Actor) ->
    Status = status(Actor),
    {Mailbox, Memory} = usage(Status, Pid),
    #{
        <<"id">> => Id,
        <<"name">> => Name,
        <<"class">> => Class,
        <<"status">> => atom_to_binary(Status),
        <<"restarts">> => max(0, Starts - 1),
        <<"mailbox">> => Mailbox,
        <<"memory">> => Memory
    }.

usage(Status, Pid) when Status =/= stopped, is_pid(Pid) ->
    case erlang:process_info(Pid, [message_queue_len, memory]) of
        [{message_queue_len, Length}, {memory, Bytes}] -> {Length, Bytes};
        undefined -> {0, 0}
    end;
usage(_Status, _Pid) ->
    {0, 0}.

%%% The context of the calling process

%% The context of the calling process, for a process that works on its
%% behalf.
-spec context() -> context().
context() ->
    case get(?CONTEXT) of
        undefined -> #context{owner = self()};
        Context -> Context
    end.

-spec adopt(context()) -> ok.
adopt(Context) ->
    put(?CONTEXT, Context),
    ok.

%% Context while Scope is live: Promise.race ends the scope when it returns,
%% and the losers that keep running no longer act for the turn.
-spec within(context(), atomics:atomics_ref()) -> context().
within(#context{scopes = Scopes} = Context, Scope) ->
    Context#context{scopes = [Scope | Scopes]}.

-spec live([atomics:atomics_ref()]) -> boolean().
live(Scopes) ->
    lists:all(fun(Scope) -> atomics:get(Scope, 1) =:= 0 end, Scopes).

-spec chain() -> [pos_integer()].
chain() ->
    case get(?CONTEXT) of
        undefined ->
            [];
        #context{chain = Chain, scopes = Scopes} ->
            case live(Scopes) of
                true -> Chain;
                false -> []
            end
    end.

%% The ref of the actor whose turn runs in the calling process.
-spec current() -> ref().
current() ->
    case current_id() of
        undefined -> bouy_error:throw(<<"Error">>, <<"self() works only inside an actor">>);
        Id -> {'$ref', Id}
    end.

-spec current_id() -> pos_integer() | undefined.
current_id() ->
    (context())#context.actor.

%% The process that the code here acts for, which owns its timers: the
%% actor, or the top-level code.
-spec owner() -> pid().
owner() ->
    (context())#context.owner.

%% Whether a constructor runs here, which then owns the actors it starts.
-spec constructing() -> boolean().
constructing() ->
    (context())#context.constructing.

%%% The actor process

%% Enters the registry and runs the constructor in the new process. The
%% first process of a spawned actor that a constructor starts belongs to the
%% actor of that constructor, and a temporary child of a group has its end
%% watched, since the group does not restart it.
begin_process(#{id := Id} = Spec) ->
    case bouy_registry:enter(Id, self(), Spec) of
        stopped ->
            stopped;
        {Starts, Counter} ->
            ok = watch(Spec, Starts),
            case construct(Spec, Counter, first_chain(Starts, Spec)) of
                {ok, State, This} -> {ok, State, This, Starts};
                Failed -> Failed
            end
    end.

watch(#{id := Id, owner := Owner}, 1) when is_pid(Owner) ->
    bouy_keeper:own(Owner, {actor, Id});
watch(#{id := Id, group := tree, restart := temporary}, _Starts) ->
    bouy_keeper:watch_temporary(self(), Id);
watch(_Spec, _Starts) ->
    ok.

%% bouy_keeper prints the crash line when the memory limit kills a child of a
%% group, since the group restarts it. It watches a spawned actor through its
%% link already.
watch_memory(#{group := tree, max_memory := Bytes, id := Id}) when is_integer(Bytes) ->
    bouy_keeper:watch_memory(self(), Id);
watch_memory(_Spec) ->
    ok.

%% Only the first start runs inside the call to spawn(), so only that
%% constructor waits on the chain of the spawner.
first_chain(1, #{id := Id, chain := Chain}) -> [Id | Chain];
first_chain(_Starts, #{id := Id}) -> [Id].

construct(Spec, Counter, Chain) ->
    #{id := Id, module := Module, class := Class, args := Args, mailbox := Mailbox} = Spec,
    put(?CONTEXT, #context{actor = Id, chain = Chain, owner = self(), constructing = true}),
    {Dispatch, New, _Pure} =
        case Spec of
            #{functions := Functions} -> Functions;
            #{} -> class_functions(Module, Class)
        end,
    State = state(Spec, Dispatch, Counter),
    try Module:New(Args) of
        This ->
            ok = watch_memory(Spec),
            ok = bouy_registry:ready(Id, self(), Counter, Mailbox),
            {ok, State, This}
    catch
        Kind:Reason:Stack ->
            Cause = cause(Kind, Reason, Stack),
            ok = record_crash(facts(State), self(), Cause),
            {failed, Cause}
    end.

state(Spec, Dispatch, Counter) ->
    #{id := Id, module := Module, restart := Restart, supervisor := Supervisor, group := Group} = Spec,
    #state{
        id = Id,
        label = label(Spec),
        module = Module,
        dispatch = Dispatch,
        restart = Restart,
        supervisor = Supervisor,
        group = Group,
        counter = Counter,
        alone = #context{actor = Id, chain = [Id], owner = self()}
    }.

%% Waits for the next request and runs it as one turn. A message that is not
%% a request, such as a late reply to an earlier turn, is dropped.
-spec loop(state(), term()) -> no_return().
loop(#state{counter = Counter} = State, This) ->
    receive
        {'$call', Alias, Method, Args, Chain} ->
            release(Counter),
            call_turn(Alias, Method, Args, Chain, State, This);
        {'$cast', Method, Args} ->
            release(Counter),
            cast_turn(Method, Args, State, This);
        {'$room', Alias, Method, Args} ->
            release(Counter),
            Alias ! {Alias, true},
            cast_turn(Method, Args, State, This);
        _Dropped ->
            loop(State, This)
    end.

call_turn(Alias, Method, Args, Chain, #state{id = Id} = State, This) ->
    begin_turn(Chain, State),
    case turn(Method, Args, State, This) of
        {ok, Value, This1} ->
            Alias ! {Alias, {ok, Value}},
            loop(State, This1);
        {failed, Failure, This1} ->
            Alias ! {Alias, {throw, Failure}},
            loop(State, This1);
        {crashed, Cause} ->
            Alias ! {Alias, {throw, crash(Method, Cause, State)}},
            exit(crashed(Id))
    end.

cast_turn(Method, Args, #state{id = Id} = State, This) ->
    begin_turn([], State),
    case turn(Method, Args, State, This) of
        {crashed, Cause} ->
            _ = crash(Method, Cause, State),
            exit(crashed(Id));
        {_Outcome, _Result, This1} ->
            loop(State, This1)
    end.

begin_turn([], #state{alone = Alone}) ->
    put(?CONTEXT, Alone);
begin_turn(Chain, #state{id = Id}) ->
    put(?CONTEXT, #context{actor = Id, chain = [Id | Chain], owner = self()}).

%% Runs one method. A method that returns an Effect runs it in the same turn:
%% a typed failure keeps the state, and an exception crashes the actor.
turn(Method, Args, #state{module = Module, dispatch = Dispatch}, This) ->
    try
        {Result, This1} = Module:Dispatch(Method, This, Args),
        settle(Result, This1)
    catch
        Kind:Reason:Stack -> {crashed, cause(Kind, Reason, Stack)}
    end.

settle({'$effect', Effect}, This) ->
    case Effect() of
        {ok, Value} -> {ok, Value, This};
        {error, Failure} -> {failed, Failure, This}
    end;
settle(Value, This) ->
    {ok, Value, This}.

%% After a thrown error, later callers wait for the restart, the crash line
%% goes to stderr, and the caller of the turn gets ActorFailed.
crash(Method, Cause, #state{label = Label} = State) ->
    ok = record_crash(facts(State), self(), Cause),
    actor_failed(Label, Method, Cause).

facts(#state{id = Id, label = Label, restart = Restart, supervisor = Supervisor, group = Group}) ->
    #{id => Id, label => Label, restart => Restart, supervisor => Supervisor, group => Group}.

%% Process Pid of an actor ends after a crash. A temporary actor never
%% restarts, so it is stopped, and the group of a temporary child ends once
%% no actor is left in it.
record_crash(#{id := Id, label := Label, restart := Restart, supervisor := Supervisor, group := Group}, Pid, Cause) ->
    ok = bouy_registry:vacate(Id, Pid),
    ok = print_crash(Label, Cause),
    case {Restart, Group} of
        {temporary, tree} ->
            _ = bouy_registry:mark_stopped(Id),
            bouy_sup:stop_when_empty(Supervisor, Pid);
        {temporary, alone} ->
            _ = bouy_registry:mark_stopped(Id),
            ok;
        _ ->
            ok
    end.

%% Prints the crash line without waiting for the write. The standard_error
%% server writes requests in the order they arrive, so the line comes before
%% any later write of the caller that gets the error, and bouy_main:finish/2
%% waits for the server before the VM halts.
print_crash(Label, Cause) ->
    Line = <<"bouy: ", Label/binary, " crashed: ", (bouy_rt:to_string(Cause))/binary, "\n">>,
    case whereis(standard_error) of
        undefined -> ok;
        Device -> Device ! {io_request, self(), make_ref(), {put_chars, unicode, Line}}
    end,
    ok.

%% The JavaScript value of an exception that ended a turn.
cause(error, Reason, Stack) ->
    bouy_rt:caught(Reason, Stack);
cause(throw, {'$fail', Failure}, _Stack) ->
    Failure;
cause(Kind, Reason, _Stack) ->
    Message = unicode:characters_to_binary(io_lib:format("~p: ~0tp", [Kind, Reason])),
    bouy_error:new(<<"Error">>, Message).

%% `<class> <name>` or `<class> #<id>`.
label(#{class := Class, name := undefined, id := Id}) ->
    <<Class/binary, " #", (integer_to_binary(Id))/binary>>;
label(#{class := Class, name := Name}) ->
    <<Class/binary, " ", Name/binary>>.

%% The dispatch and constructor functions of an actor class, `'C#dispatch'/3`
%% and `'C#new'/1`, and whether the constructor is pure (`'C#pure'/0`), or
%% `error` for another class, such as an error class, which has no dispatch.
%% A class is checked once.
-spec class_functions(module(), binary()) -> {atom(), atom(), boolean()} | error.
class_functions(Module, Class) ->
    Key = {?MODULE, Module, Class},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Functions = check_class(Module, Class),
            case Functions of
                error -> ok;
                _ -> persistent_term:put(Key, Functions)
            end,
            Functions;
        Functions ->
            Functions
    end.

check_class(Module, Class) ->
    Loaded = code:ensure_loaded(Module) =:= {module, Module},
    try binary_to_existing_atom(<<Class/binary, "#dispatch">>) of
        Dispatch when Loaded ->
            case erlang:function_exported(Module, Dispatch, 3) of
                true ->
                    Pure = erlang:function_exported(Module, binary_to_atom(<<Class/binary, "#pure">>), 0),
                    {Dispatch, binary_to_atom(<<Class/binary, "#new">>), Pure};
                false ->
                    error
            end;
        _ ->
            error
    catch
        error:badarg -> error
    end.

actor_failed(Label, Method, Cause) ->
    Message = <<Label/binary, " failed in ", Method/binary, ": ",
        (bouy_rt:to_string(Cause))/binary>>,
    tagged(<<"ActorFailed">>, Label, Message, #{<<"method">> => Method, <<"cause">> => Cause}).

stopped(Actor) ->
    Label = label(Actor),
    tagged(<<"ActorStopped">>, Label, <<Label/binary, " is stopped">>, #{}).

%% Prints the crash line of an actor that its memory limit killed, and returns
%% the error.
-spec report_out_of_memory(#{class := binary(), name := binary() | undefined, id := pos_integer(), _ => _}) ->
    error_value().
report_out_of_memory(Actor) ->
    Error = out_of_memory(Actor),
    io:format(standard_error, "bouy: ~ts crashed: ~ts~n", [label(Actor), bouy_rt:to_string(Error)]),
    Error.

%% The error of an actor that the memory limit killed: its own maxMemory, or
%% the limit of every process, which BOUY_MAX_MEMORY sets.
out_of_memory(Actor) ->
    Label = label(Actor),
    Limit =
        case maps:get(max_memory, Actor, infinity) of
            infinity ->
                {max_heap_size, #{size := Words}} = erlang:system_info(max_heap_size),
                Words * erlang:system_info(wordsize);
            Bytes ->
                Bytes
        end,
    Message = <<Label/binary, " used more than its memory limit of ", (integer_to_binary(Limit))/binary, " bytes">>,
    tagged(<<"ActorOutOfMemory">>, Label, Message, #{<<"limit">> => Limit}).

mailbox_full(Actor) ->
    Label = label(Actor),
    tagged(<<"MailboxFull">>, Label, <<Label/binary, " has a full mailbox">>, #{}).

call_cycle(Actor) ->
    Label = label(Actor),
    Message =
        <<Label/binary,
            " is busy with a call that waits on this call."
            " Use cast() or pass the data in the first call.">>,
    tagged(<<"CallCycle">>, Label, Message, #{}).

tagged(Tag, Label, Message, Fields) ->
    bouy_error:new(Tag, Message, Fields#{<<"_tag">> => Tag, <<"actor">> => Label}).

-spec raise(error_value()) -> no_return().
raise(Error) ->
    erlang:error({'$throw', Error}).
