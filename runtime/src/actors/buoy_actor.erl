-module(buoy_actor).

%% An actor is a process that runs one JavaScript realm of the reference
%% engine: its heap in the process dictionary, its promise job queue, and
%% `This`, the instance of the actor class. A turn is one call or one cast,
%% from the start of the method until its promise settles. The process takes
%% no other request meanwhile, so turns never interleave, also across an
%% await. While a turn waits, the realm still runs its timers and takes the
%% replies to its own calls. The loop is not a gen_server: a call is one
%% message and one reply to the alias of a monitor, which is all that the
%% contract needs, and it costs less than gen_server.
%%
%% Messages to an actor process:
%%   {'$call', Alias, Method, Args, Chain}  replies {Alias, {ok, V} | {throw, E}}
%%   {'$cast', Method, Args}
%%   {'$cast', Method, Args, Owner}         the cast of a schedule() timer
%%   {'$room', Alias, Method, Args}         a cast that waits: replies {Alias, true}
%%                                          when the actor takes it
%% Args and V are structured clones (clone_out/1), and E is an error term
%% (error_term/4) or the clone of a thrown value.
%%
%% The code of a realm runs with its context in the process dictionary: the
%% actor, and the call chain of the turn that runs, a list of links
%% {Id, Scope}: its own actor first and then the actors that wait on it. The
%% scope of a link is an atomics array that the turn of that actor marks when
%% it ends, so a call that a turn made and did not wait for no longer acts
%% for it. A call to an actor in the live part of the chain rejects with
%% CallCycle instead of a deadlock. A call from a turn also records its wait
%% in the wait-for graph of buoy_registry, so two turns that call each other
%% at once see the cycle.
%%
%% A sender reads only the mode of the actor (buoy_registry). When the actor
%% has no process that can take the request, the sender waits for the next
%% change of the mode, which buoy_registry announces, or for the end of the
%% supervisor of the actor. It never polls.

-export([start/1, start_link/1, spawn_options/1, init_alone/2, init_tree/2]).
-export([call/3, cast/3, offer/4, stop/1, snapshot/1, with_timeout/2]).
-export([report_out_of_memory/1, timed_out/1, reply/1, has_calls/0, uncaught/1]).
-export([context/0, live/1, chain/0, current/0, current_id/0, owner/0, timer_owner/0, constructing/0]).
-export([clone_out/1, clone_in/1, raise/1]).
-export([loop/1]).

-export_type([spec/0, context/0, timer_owner/0, link/0]).

-include("buoy_ref.hrl").

-define(CONTEXT, '$buoy_context').
%% The instance of the actor class.
-define(THIS, '$buoy_this').
%% The turn that runs, and its outcome once the promise of its method settles.
-define(TURN, '$buoy_turn').
-define(OUTCOME, '$buoy_turn_outcome').
%% The calls of this realm that wait for a reply, by the alias of the monitor.
-define(CALLS, '$buoy_actor_calls').
%% The handler of an exception that reached the top of a job of the realm.
-define(UNCAUGHT, '$buoy_uncaught').
%% The module of the actor class, from which an Effect finds its runtime.
-define(MODULE_KEY, '$buoy_actor_module').
%% The message queue of an actor stays off its heap, so a mailbox that fills
%% to its capacity does not grow the heap that each garbage collection copies.
-define(SPAWN, [{message_queue_data, off_heap}]).
%% A group ends a child with an exit signal `shutdown`, so the reason `killed`
%% names the memory limit of the process, unless stop() marked the actor first.
-define(SHUTDOWN, 5000).
-define(IS_REQUEST(M), (is_tuple(M) andalso tuple_size(M) >= 4 andalso
                        (element(1, M) =:= '$call' orelse element(1, M) =:= '$cast' orelse element(1, M) =:= '$room'))).

-type value() :: buoy_heap:value().
%% An error that the runtime makes, such as ActorFailed: its name, its
%% message in UTF-8, and its own fields. A field holds a number, a UTF-8
%% string, or {clone, Term}, a value in the clone format.
-type error_term() :: {'$buoy_error', binary(), binary(), [{binary(), term()}]}.
-type spec() :: #{
    id := pos_integer(),
    module := module(),
    home := {module(), binary()},
    class := binary(),
    args := term(),
    name := binary() | undefined,
    mailbox := buoy_registry:mailbox(),
    restart := buoy_registry:restart(),
    max_memory => pos_integer() | infinity,
    turn_timeout => pos_integer() | infinity,
    supervisor := pid(),
    group := alone | tree,
    chain => [link()],
    owner => pid() | none
}.
%% One actor of a call chain, and the scope of its turn, or `none` for a
%% constructor, whose spawner waits for it.
-type link() :: {pos_integer(), atomics:atomics_ref() | none}.
%% What a caller needs from the mode of an actor before it sends a request.
-type need() :: alive | {ready, [pos_integer()]}.
%% The owner of a schedule() timer: the process of an actor with the id of the
%% actor, or the top-level code, which has no id.
-type timer_owner() :: {pos_integer() | undefined, pid()}.

%% What the code in a process acts for: the actor, the call chain of the turn
%% that runs, the owner (the process of the actor, or of the top-level code),
%% and whether a constructor runs.
-record(context, {
    actor :: pos_integer() | undefined,
    chain = [] :: [link()],
    owner :: pid(),
    constructing = false :: boolean()
}).
-opaque context() :: #context{}.

-record(state, {
    id :: pos_integer(),
    label :: binary(),
    restart :: buoy_registry:restart(),
    supervisor :: pid(),
    group :: alone | tree,
    counter :: atomics:atomics_ref(),
    turn_timeout = infinity :: pos_integer() | infinity
}).
-type state() :: #state{}.

%% A call that waits for its reply: the actor, the process and the counter of
%% the start that took it, the request, the chain it carries, the scope of
%% the turn that recorded its wait, and the functions of its promise.
-record(call, {
    id :: pos_integer(),
    pid :: pid() | undefined,
    counter :: atomics:atomics_ref() | undefined,
    method :: term(),
    args :: term(),
    chain :: [link()],
    wait = none :: none | {pos_integer(), atomics:atomics_ref() | none, reference()},
    resolve :: fun((value()) -> term()),
    reject :: fun((value()) -> term())
}).

%% A turn timer goes to buoy_keeper, which ends the turn when the actor is
%% still in it: the process, the actor, the counter of the start, the turn,
%% the caller that waits on the turn, the method, and the limit in ms.
-type turn() :: {turn, pid(), pos_integer(), atomics:atomics_ref(), pos_integer(), reference() | none, binary(), pos_integer()}.
-export_type([turn/0]).

%%% Starts

%% Starts the actor of Spec and returns when its constructor has finished.
%% When the constructor throws, the start fails with ActorFailed and the
%% actor is stopped. A spawned actor runs as a process linked to buoy_keeper;
%% a child of supervise() runs under its group supervisor.
-spec start(spec()) -> ok | {error, error_term()}.
start(#{group := alone} = Spec) ->
    start_alone(Spec);
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
        {error, {{constructor_failed, Failure}, _Child}} ->
            _ = buoy_registry:mark_stopped(Id),
            {error, Failure};
        {error, {killed, _Child}} ->
            ended_during_constructor(Spec, killed);
        {error, Reason} ->
            ended_during_constructor(Spec, Reason)
    catch
        %% stop() killed the group while the constructor ran.
        exit:_ ->
            _ = buoy_registry:mark_stopped(Id),
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

%% stop() ended the actor while its constructor ran, as when a constructor
%% stops its own actor: the actor exists, stopped. A kill without the mark of
%% stop() is the memory limit. Any other end fails the start.
ended_during_constructor(#{id := Id} = Spec, Reason) ->
    Marked = buoy_registry:mode(Id) =:= stopped,
    _ = buoy_registry:mark_stopped(Id),
    case {Reason, Marked} of
        {killed, true} ->
            ok;
        {killed, false} ->
            {error, report_out_of_memory(Spec)};
        _ ->
            Message = unicode:characters_to_binary(io_lib:format("~0tp", [Reason])),
            Cause = error_term(<<"Error">>, Message, []),
            {error, actor_failed(label(Spec), <<"constructor">>, error_text(Cause), {clone, Cause})}
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
%% constructor) and on each restart by buoy_keeper (Starter is `none`).
-spec init_alone(spec(), pid() | none) -> no_return().
init_alone(#{id := Id, supervisor := Keeper} = Spec, Starter) ->
    true = link(Keeper),
    case begin_process(Spec) of
        {ok, State, Starts} ->
            started(Starter, ok),
            wait_first(State, Starts);
        {failed, Failure} when Starter =/= none ->
            _ = buoy_registry:mark_stopped(Id),
            started(Starter, {error, Failure}),
            exit(crashed(Id));
        {failed, _Failure} ->
            exit(crashed(Id));
        stopped ->
            exit({shutdown, stopped})
    end.

%% The process of a child of supervise(). A constructor that throws fails the
%% start, and the process then ends normally, as a gen_server whose init/1
%% returns an error ends, so the group sees no crash.
-spec init_tree(spec(), pid()) -> ok.
init_tree(Spec, Starter) ->
    case begin_process(Spec) of
        {ok, State, Starts} ->
            started(Starter, {ok, self()}),
            wait_first(State, Starts);
        {failed, Failure} ->
            started(Starter, {error, {constructor_failed, Failure}});
        stopped ->
            started(Starter, ignore)
    end.

%% A first process waits for its first request hibernated, so an actor that
%% takes no request holds only its live data. A restarted process does not:
%% the callers that waited for the restart call it at once.
wait_first(State, 1) -> erlang:hibernate(?MODULE, loop, [State]);
wait_first(State, _Starts) -> loop(State).

started(none, _Outcome) ->
    ok;
started(Starter, Outcome) ->
    Starter ! {started, self(), Outcome},
    ok.

%% A crash exits quietly with the id, so buoy_keeper knows which actor to
%% restart.
crashed(Id) -> {shutdown, {crashed, Id}}.

%% Enters the registry and runs the constructor in the new process. The
%% first process of a spawned actor that a constructor starts belongs to the
%% actor of that constructor, and a temporary child of a group has its end
%% watched, since the group does not restart it.
begin_process(#{id := Id} = Spec) ->
    case buoy_registry:enter(Id, self(), Spec) of
        stopped ->
            stopped;
        {Starts, Counter} ->
            ok = watch(Spec, Starts),
            case construct(Spec, Counter, first_chain(Starts, Spec)) of
                {ok, State} -> {ok, State, Starts};
                Failed -> Failed
            end
    end.

watch(#{id := Id, owner := Owner}, 1) when is_pid(Owner) ->
    buoy_keeper:own(Owner, {actor, Id});
watch(#{id := Id, group := tree, restart := temporary}, _Starts) ->
    buoy_keeper:watch_temporary(self(), Id);
watch(_Spec, _Starts) ->
    ok.

%% buoy_keeper prints the crash line when the memory limit kills a child of a
%% group, since the group restarts it. It watches a spawned actor through its
%% link already.
watch_memory(#{group := tree, max_memory := Bytes, id := Id}) when is_integer(Bytes) ->
    buoy_keeper:watch_memory(self(), Id);
watch_memory(_Spec) ->
    ok.

%% Only the first start runs inside the call to spawn(), so only that
%% constructor waits on the chain of the spawner.
first_chain(1, #{id := Id, chain := Chain}) -> [{Id, none} | Chain];
first_chain(_Starts, #{id := Id}) -> [{Id, none}].

%% The realm of the actor: the modules that its class module imports, then
%% the class, made again in this realm, and the instance.
construct(Spec, Counter, Chain) ->
    #{id := Id, home := {Module, Name}, args := Args, mailbox := Mailbox} = Spec,
    State = state(Spec, Counter),
    put(?CONTEXT, #context{actor = Id, chain = Chain, owner = self(), constructing = true}),
    buoy_ref:init_realm(),
    buoy_jobs:update_now(),
    put(?UNCAUGHT, fun crash_uncaught/1),
    put(?MODULE_KEY, Module),
    try
        buoy_module:evaluate_dependencies(Module),
        Class = Module:'$class'(Name),
        This = buoy_heap:construct(Class, buoy_heap:array_items(clone_in(Args)), Class),
        put(?THIS, This),
        buoy_jobs:drain(),
        put(?CONTEXT, idle(Id)),
        ok = watch_memory(Spec),
        ok = buoy_registry:ready(Id, self(), Counter, Mailbox),
        {ok, State}
    catch
        error:Reason:Stack ->
            Cause = buoy_ref:caught(Reason, Stack),
            {failed, crash(<<"constructor">>, Cause, State)}
    end.

state(Spec, Counter) ->
    #{id := Id, restart := Restart, supervisor := Supervisor, group := Group} = Spec,
    #state{
        id = Id,
        label = label(Spec),
        restart = Restart,
        supervisor = Supervisor,
        group = Group,
        counter = Counter,
        turn_timeout = maps:get(turn_timeout, Spec, infinity)
    }.

%% The context of an actor without a turn: nothing waits on it.
idle(Id) ->
    #context{actor = Id, owner = self()}.

%%% The actor process

%% Waits for the next request and runs it as one turn. Any other message is
%% an event of the realm, such as a timer or the reply to a call that the
%% realm made.
-spec loop(state()) -> no_return().
loop(State) ->
    case buoy_node:ready() of
        false ->
            receive
                Message -> take(Message, State)
            end;
        true ->
            Poll = buoy_node_loop:poll(),
            receive
                Message ->
                    buoy_node_loop:polled(Poll, 1),
                    take(Message, State)
            after buoy_node_loop:poll_timeout() ->
                buoy_node_loop:polled(Poll, 0),
                buoy_node_loop:check(),
                loop(State)
            end
    end.

take({'$call', Alias, Method, Args, Chain}, #state{counter = Counter} = State) ->
    release(Counter),
    turn(Alias, Method, Args, Chain, State);
take({'$cast', Method, Args}, #state{counter = Counter} = State) ->
    release(Counter),
    turn(none, Method, Args, [], State);
take({'$cast', Method, Args, Owner}, #state{counter = Counter} = State) ->
    release(Counter),
    case has_ended(Owner) of
        true -> loop(State);
        false -> turn(none, Method, Args, [], State)
    end;
take({'$room', Alias, Method, Args}, #state{counter = Counter} = State) ->
    release(Counter),
    Alias ! {Alias, true},
    turn(none, Method, Args, [], State);
take(Message, State) ->
    event(Message),
    loop(State).

%% One event of the realm, outside the requests.
event(Message) ->
    buoy_jobs:event_step(Message),
    buoy_node:ready() andalso buoy_node_loop:check(),
    ok.

%% Whether the owner of a timer has ended. A crash and stop() take the
%% process of the owner out of the registry before any caller hears of the
%% end, and a killed process is gone, so no cast of the timer lands after a
%% caller sees the end. The top-level code ends with the program.
has_ended({undefined, _TopLevel}) ->
    false;
has_ended({Id, Pid}) ->
    case buoy_registry:mode(Id) of
        {_Phase, Pid, _Counter, _Mailbox} -> not is_process_alive(Pid);
        _Vacated -> true
    end.

%% Runs one turn: the method, then the events of the realm until its promise
%% settles. Caller is the alias of a call, or `none` for a cast.
turn(Caller, Method, Args, Chain, #state{id = Id} = State) ->
    Scope = atomics:new(1, []),
    put(?CONTEXT, #context{actor = Id, chain = [{Id, Scope} | Chain], owner = self()}),
    Timer = start_turn_timer(Caller, Method, State),
    put(?TURN, {Caller, Method}),
    erase(?OUTCOME),
    buoy_jobs:run_job(fun() -> invoke(Method, Args) end),
    Outcome = settled(),
    atomics:put(Scope, 1, 1),
    erase(?TURN),
    put(?CONTEXT, idle(Id)),
    ok = stop_turn_timer(Timer, State),
    case {Outcome, Caller} of
        {{crashed, Cause}, _} ->
            fail(Caller, method_name(Method), Cause, State);
        {_Reply, none} ->
            loop(State);
        {{ok, Value}, Alias} ->
            Alias ! {Alias, reply_term(Value)},
            loop(State);
        {{failed, Failure}, Alias} ->
            Alias ! {Alias, {throw, clone_term(Failure)}},
            loop(State)
    end.

%% The method on `This`. A promise settles the turn when it settles, and an
%% Effect runs in the turn.
invoke(Method, Args) ->
    This = get(?THIS),
    try buoy_ref:call_method(This, Method, buoy_heap:array_items(clone_in(Args))) of
        Result -> settle(Result)
    catch
        error:Reason:Stack -> put(?OUTCOME, {crashed, buoy_ref:caught(Reason, Stack)})
    end.

settle(Result) ->
    case buoy_jobs:is_promise(Result) of
        true -> then(Result, fun(V) -> put(?OUTCOME, {ok, V}) end);
        false -> settle_value(Result)
    end.

settle_value(Result) ->
    case is_effect(Result) of
        true -> run_effect(Result);
        false -> put(?OUTCOME, {ok, Result})
    end.

%% Runs OnValue with the value of Promise, or crashes the turn with its
%% rejection.
then(Promise, OnValue) ->
    buoy_jobs:perform_then(Promise, fun(V) -> OnValue(V), undefined end,
                           fun(E) -> put(?OUTCOME, {crashed, E}), undefined end, undefined).

%% effect 4 gives every Effect the property `~effect/Effect`.
is_effect(Value) ->
    buoy_heap:is_object(Value) andalso buoy_heap:has(Value, <<"~effect/Effect">>).

%% An Effect that a method returns runs in the turn with Effect.runPromiseExit
%% of the effect package that the module of the class imports. A success
%% replies the value, a typed failure replies the failure and keeps the
%% state, and a defect or an interruption crashes the actor.
run_effect(Effect) ->
    Module = get(?MODULE_KEY),
    then(buoy_module:dynamic_import(Module, <<"effect">>, undefined, evaluation), fun(Package) ->
        Namespace = buoy_ref:get(Package, <<"Effect">>),
        then(buoy_ref:call_method(Namespace, <<"runPromiseExit">>, [Effect]), fun(Exit) ->
            put(?OUTCOME, exit_outcome(Exit))
        end)
    end).

exit_outcome(Exit) ->
    case buoy_ref:get(Exit, <<"_tag">>) of
        <<"Success">> -> {ok, buoy_ref:get(Exit, <<"value">>)};
        _Failure -> cause_outcome(buoy_heap:array_items(buoy_ref:get(buoy_ref:get(Exit, <<"cause">>), <<"reasons">>)))
    end.

%% A Fail reason is a typed failure. Else the first Die reason is the defect.
cause_outcome(Reasons) ->
    Tagged = [{buoy_ref:get(Reason, <<"_tag">>), Reason} || Reason <- Reasons],
    case {lists:keyfind(<<"Fail">>, 1, Tagged), lists:keyfind(<<"Die">>, 1, Tagged)} of
        {{_, Fail}, _} -> {failed, buoy_ref:get(Fail, <<"error">>)};
        {false, {_, Die}} -> {crashed, buoy_ref:get(Die, <<"defect">>)};
        {false, false} -> {crashed, buoy_heap:error_object('Error', <<"the Effect was interrupted">>)}
    end.

%% The outcome of the turn, after the events that its promise waits for.
settled() ->
    case get(?OUTCOME) of
        undefined ->
            receive
                Message when not ?IS_REQUEST(Message) -> event(Message)
            after timeout() ->
                buoy_node_loop:check()
            end,
            settled();
        Outcome ->
            Outcome
    end.

timeout() ->
    case buoy_node:ready() of
        true -> buoy_node_loop:poll_timeout();
        false -> infinity
    end.

%% The reply of a call: the clone of the value, or the error of a value that
%% cannot be cloned.
reply_term(Value) ->
    try {ok, clone_out(Value)}
    catch
        error:{'$throw', Error} -> {throw, clone_out(Error)}
    end.

%% After a thrown error, later callers wait for the restart, the crash line
%% goes to stderr, the caller of the turn gets ActorFailed, and the process
%% exits.
fail(Caller, Method, Cause, #state{id = Id} = State) ->
    Failure = crash(Method, Cause, State),
    case Caller of
        none -> ok;
        Alias -> Alias ! {Alias, {throw, Failure}}
    end,
    exit(crashed(Id)).

%% An exception that reached the top of a job of the realm, such as a throw
%% in a timer, or a rejection that no code handles: the actor crashes, in
%% the method of the turn that runs, if any.
crash_uncaught(Error) ->
    #context{actor = Id} = context(),
    {ok, Actor} = buoy_registry:find(Id),
    State = #state{id = Id, label = label(Actor), restart = maps:get(restart, Actor),
                   supervisor = maps:get(supervisor, Actor), group = maps:get(group, Actor),
                   counter = atomics:new(2, [])},
    case get(?TURN) of
        {Caller, Method} -> fail(Caller, method_name(Method), Error, State);
        undefined -> fail(none, <<"a callback">>, Error, State)
    end.

%% The handler of the realm for an exception that reached the top of a job
%% (buoy_ref:report_uncaught/1), or `none` in the realm of the top-level
%% code, where the program ends.
-spec uncaught(value()) -> none | no_return().
uncaught(Error) ->
    case get(?UNCAUGHT) of
        undefined -> none;
        Handler -> Handler(Error)
    end.

crash(Method, Cause, #state{label = Label} = State) ->
    Text = js_text(Cause),
    ok = record_crash(facts(State), self(), Text),
    actor_failed(Label, Method, Text, cause_term(Cause)).

%% The cause in the clone format, or an Error with its text when it cannot be
%% cloned, as a function cannot.
cause_term(Cause) ->
    try {clone, clone_out(Cause)}
    catch
        error:{'$throw', _} -> {clone, error_term(<<"Error">>, js_text(Cause), [])}
    end.

facts(#state{id = Id, label = Label, restart = Restart, supervisor = Supervisor, group = Group}) ->
    #{id => Id, label => Label, restart => Restart, supervisor => Supervisor, group => Group}.

%% Process Pid of an actor ends after a crash. A temporary actor never
%% restarts, so it is stopped, and the group of a temporary child ends once
%% no actor is left in it.
record_crash(#{id := Id, label := Label, restart := Restart, supervisor := Supervisor, group := Group}, Pid, Text) ->
    ok = buoy_registry:vacate(Id, Pid),
    ok = print_crash(Label, Text),
    case {Restart, Group} of
        {temporary, tree} ->
            _ = buoy_registry:mark_stopped(Id),
            buoy_sup:stop_when_empty(Supervisor, Pid);
        {temporary, alone} ->
            _ = buoy_registry:mark_stopped(Id),
            ok;
        _ ->
            ok
    end.

%% Prints the crash line without waiting for the write. The standard_error
%% server writes requests in the order they arrive, so the line comes before
%% any later write of the caller that gets the error, and buoy_main:finish/2
%% waits for the server before the VM halts.
print_crash(Label, Text) ->
    Line = <<"buoy: ", Label/binary, " crashed: ", Text/binary, "\n">>,
    case whereis(standard_error) of
        undefined -> ok;
        Device -> Device ! {io_request, self(), make_ref(), {put_chars, unicode, Line}}
    end,
    ok.

%% String(V) in UTF-8.
js_text(V) ->
    try buoy_ref_string:to_utf8(buoy_ref:to_string(V))
    catch
        _:_ -> unicode:characters_to_binary(io_lib:format("~0tp", [V]))
    end.

method_name(Method) when ?IS_STRING(Method) -> buoy_ref_string:to_utf8(Method);
method_name(Method) -> js_text(Method).

%%% Turn timeouts

%% Runs a turn under a turn timer when the actor has a turn timeout. The
%% second slot of the counter names the turn that runs, so buoy_keeper ends
%% a turn only while it runs: whichever side swaps the slot first decides.
start_turn_timer(_Caller, _Method, #state{turn_timeout = infinity}) ->
    none;
start_turn_timer(Caller, Method, #state{id = Id, counter = Counter, turn_timeout = Ms}) ->
    Turn = erlang:unique_integer([positive]),
    ok = atomics:put(Counter, 2, Turn),
    Timer = erlang:start_timer(Ms, buoy_keeper, {turn, self(), Id, Counter, Turn, Caller, method_name(Method), Ms}),
    {Turn, Timer}.

stop_turn_timer(none, _State) ->
    ok;
stop_turn_timer({Turn, Timer}, #state{counter = Counter}) ->
    case atomics:compare_exchange(Counter, 2, Turn, 0) of
        ok ->
            ok = erlang:cancel_timer(Timer, [{async, true}, {info, false}]);
        _Ended ->
            %% buoy_keeper has ended this turn, and it ends the process next.
            receive
            after infinity -> ok
            end
    end.

%% buoy_keeper calls this when a turn timer fires. When the actor is still in
%% that turn, the turn ends as a crash ends it: callers wait for the restart,
%% the crash line goes to stderr, the caller of the turn gets ActorTimedOut,
%% and the process exits, so its supervisor restarts the actor within its
%% budget.
-spec timed_out(turn()) -> ok.
timed_out({turn, Pid, Id, Counter, Turn, Caller, Method, Ms}) ->
    case atomics:compare_exchange(Counter, 2, Turn, -1) of
        ok -> end_turn(Pid, Id, Caller, Method, Ms);
        _Ended -> ok
    end.

end_turn(Pid, Id, Caller, Method, Ms) ->
    case buoy_registry:find(Id) of
        {ok, #{mode := {_Phase, Pid, _Counter, _Mailbox}} = Actor} ->
            Label = label(Actor),
            Error = turn_timed_out(Label, Method, Ms),
            ok = record_crash(Actor#{label => Label}, Pid, error_text(Error)),
            case Caller of
                none -> ok;
                Alias -> Alias ! {Alias, {throw, Error}}
            end,
            true = exit(Pid, crashed(Id)),
            ok;
        _StoppedOrRestarted ->
            true = exit(Pid, {shutdown, stopped}),
            ok
    end.

%%% Calls from a realm

%% ref.method(...args): a promise of the reply. The call goes out at once,
%% after a wait for the constructor or the restart of the actor.
-spec call(pos_integer(), term(), list()) -> value().
call(Id, Method, Args) ->
    Term = clone_out(buoy_heap:new_array(Args)),
    {Promise, Resolve, Reject} = buoy_jobs:capability(),
    Call = #call{id = Id, method = Method, args = Term, chain = chain(), resolve = Resolve, reject = Reject},
    send_call(Call, none),
    Promise.

-spec has_calls() -> boolean().
has_calls() ->
    case get(?CALLS) of
        undefined -> false;
        Calls -> map_size(Calls) > 0
    end.

%% Admits and sends Call, or rejects its promise. Dead is a process that the
%% call found dead and that the mode may still name, or `none`.
send_call(#call{reject = Reject} = Call, Dead) ->
    try admit_call(Call, Dead) of
        {Alias, Sent} -> put(?CALLS, (calls())#{Alias => Sent})
    catch
        error:{'$throw', Error} ->
            ok = unwait(Call),
            Reject(Error)
    end,
    ok.

calls() ->
    case get(?CALLS) of
        undefined -> #{};
        Calls -> Calls
    end.

%% The checks of a call before it goes out: a cycle through the chain or the
%% wait-for graph, the mode of the actor, and a full mailbox that rejects.
admit_call(#call{id = Id, method = Method, args = Args, chain = Chain} = Call, Dead) ->
    Ids = ids(Chain),
    lists:member(Id, Ids) andalso raise(call_cycle(known(Id))),
    Waiting = record_wait(Call),
    {Pid, Counter, Count, Mailbox} = admit(Id, {ready, Ids}, Dead),
    case Mailbox of
        {Capacity, reject} when Count > Capacity ->
            release(Counter),
            raise(mailbox_full(known(Id)));
        _ ->
            ok
    end,
    Alias = monitor(process, Pid, [{alias, reply_demonitor}]),
    Pid ! {'$call', Alias, Method, Args, Chain},
    {Alias, Waiting#call{pid = Pid, counter = Counter}}.

%% A call from a turn records its wait in the graph, then looks for a path
%% from the actor back to the chain: of two turns that call each other at
%% once, at least one sees the cycle. A constructor does not look, so the
%% callers that wait for it look again.
record_wait(#call{wait = {_, _, _}} = Call) ->
    Call;
record_wait(#call{id = Id, chain = [{From, Scope} | _] = Chain} = Call) ->
    Tag = make_ref(),
    ok = buoy_registry:wait(From, Id, [Scope], Tag),
    Waiting = Call#call{wait = {From, Scope, Tag}},
    case constructing() of
        true ->
            ok = buoy_registry:notify(From),
            Waiting;
        false ->
            case reaches([Id], ids(Chain), #{}) of
                true ->
                    ok = unwait(Waiting),
                    raise(call_cycle(known(Id)));
                false ->
                    Waiting
            end
    end;
record_wait(Call) ->
    Call.

unwait(#call{wait = {From, Scope, Tag}, id = Id}) ->
    buoy_registry:unwait(From, Id, [Scope], Tag);
unwait(#call{}) ->
    ok.

%% A reply, or the 'DOWN' of the process of a call of this realm: true when
%% the message belongs to one, which then settles or goes again.
-spec reply(term()) -> boolean().
reply({Alias, Reply}) when is_reference(Alias) ->
    settle_call(Alias, Reply);
reply({'DOWN', Alias, process, _Pid, Reason}) ->
    settle_call(Alias, {down, Reason});
reply(_Message) ->
    false.

settle_call(Alias, Reply) ->
    case maps:take(Alias, calls()) of
        {#call{id = Id, counter = Counter, pid = Pid} = Call, Rest} ->
            put(?CALLS, Rest),
            case reply_outcome(Id, Counter, Reply) of
                wait ->
                    buoy_jobs:run_job(fun() -> send_call(Call, Pid) end);
                Outcome ->
                    ok = unwait(Call),
                    buoy_jobs:run_job(fun() -> settle_promise(Call, Outcome) end)
            end,
            true;
        error ->
            false
    end.

settle_promise(#call{resolve = Resolve}, {ok, Term}) -> Resolve(clone_in(Term));
settle_promise(#call{reject = Reject}, {throw, Term}) -> Reject(clone_in(Term)).

%% The outcome of a call from the reply, or from the reason of the 'DOWN' of
%% the process. A process that was already gone gives `wait`: the call goes
%% again, past that process. A kill without the mark of stop() is the memory
%% limit.
reply_outcome(Id, Counter, Reply) ->
    case Reply of
        {ok, _} ->
            Reply;
        {throw, _} ->
            Reply;
        {down, noproc} ->
            release(Counter),
            wait;
        {down, killed} ->
            release(Counter),
            case buoy_registry:find(Id) of
                {ok, #{mode := stopped} = Actor} -> {throw, stopped(Actor)};
                {ok, Actor} -> {throw, out_of_memory(Actor)};
                error -> {throw, stopped(#{class => <<"actor">>, name => undefined, id => Id})}
            end;
        {down, _Reason} ->
            release(Counter),
            case buoy_registry:find(Id) of
                {ok, Actor} -> {throw, stopped(Actor)};
                error -> {throw, stopped(#{class => <<"actor">>, name => undefined, id => Id})}
            end
    end.

%%% Casts

-spec cast(pos_integer(), term(), list()) -> true.
cast(Id, Method, Args) ->
    cast_term(Id, Method, clone_out(buoy_heap:new_array(Args)), none).

cast_term(Id, Method, Args, Dead) ->
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
%% an actor that restarts, skips it, so the timer stays free to stop. The
%% cast names the owner of the timer, so the actor drops it once that owner
%% has ended.
-spec offer(pos_integer(), term(), term(), timer_owner()) -> sent | skipped | stopped.
offer(Id, Method, Args, Owner) ->
    case buoy_registry:mode(Id) of
        {_Phase, Pid, Counter, {Capacity, _}} ->
            case atomics:add_get(Counter, 1, 1) =< Capacity of
                true ->
                    Pid ! {'$cast', Method, Args, Owner},
                    sent;
                false ->
                    release(Counter),
                    skipped
            end;
        restarting ->
            case buoy_registry:find(Id) of
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
    case lists:member(Id, ids(Chain)) of
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
            cast_term(Id, Method, Args, Pid);
        {'DOWN', Alias, process, Pid, _Reason} ->
            release(Counter),
            case buoy_registry:mode(Id) of
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
waiting([{From, Scope} | _] = Chain, Target, Wait) ->
    Tag = make_ref(),
    ok = buoy_registry:wait(From, Target, [Scope], Tag),
    try
        case constructing() of
            true ->
                ok = buoy_registry:notify(From),
                {done, Wait()};
            false ->
                case reaches([Target], ids(Chain), #{}) of
                    true -> cycle;
                    false -> {done, Wait()}
                end
        end
    after
        buoy_registry:unwait(From, Target, [Scope], Tag)
    end.

%% Whether one of Ids waits on an actor of Chain, through the graph.
reaches([Id | Rest], Chain, Seen) ->
    case lists:member(Id, Chain) of
        true -> true;
        false when is_map_key(Id, Seen) -> reaches(Rest, Chain, Seen);
        false -> reaches(buoy_registry:waits_on(Id) ++ Rest, Chain, Seen#{Id => true})
    end;
reaches([], _Chain, _Seen) ->
    false.

%% Counts one request for actor Id and finds its process: the pid, the
%% counter of the start, the count, and the mailbox. A cast needs a live
%% process; a call also waits while the constructor runs, and looks for a
%% wait cycle meanwhile: a constructor never throws CallCycle for one, so
%% the call that waits on it does.
-spec admit(pos_integer(), need(), pid() | none) ->
    {pid(), atomics:atomics_ref(), pos_integer(), buoy_registry:mailbox()}.
admit(Id, Need, Dead) ->
    case buoy_registry:mode(Id) of
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
    ok = buoy_registry:watch(Id, Watch, Ref),
    Outcome = standing(Id, buoy_registry:find(Id), Need, Dead),
    case Outcome of
        {waiting, Supervisor} -> until_change(Supervisor, Ref);
        _ -> ok
    end,
    ok = buoy_registry:unwatch(Id, Watch, Ref),
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
    case buoy_registry:find(Id) of
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

%%% Stop, inspect, and withTimeout

%% Stops actor Id at once, also during a turn. Later calls throw ActorStopped.
%% Another process ends the actor, so an actor can stop itself. Only code
%% outside every actor waits for the end.
-spec stop(pos_integer()) -> ok.
stop(Id) ->
    case buoy_registry:find(Id) of
        error ->
            ok;
        {ok, Actor} ->
            _ = buoy_registry:mark_stopped(Id),
            Teardown = fun() -> stop_process(Actor) end,
            case current_id() of
                undefined ->
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
    ok = end_process(buoy_registry:pid(Id)),
    buoy_registry:drop_waits(Id);
stop_process(#{group := tree, supervisor := Group, id := Id}) ->
    try
        _ = supervisor:terminate_child(Group, Id),
        _ = supervisor:delete_child(Group, Id),
        buoy_sup:stop_when_empty(Group)
    catch
        exit:{noproc, _} -> ok
    end,
    buoy_registry:drop_waits(Id).

%% An actor traps no exits, so the signal ends it at once, and buoy_keeper
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
-spec snapshot(buoy_registry:actor()) -> #{atom() => term()}.
snapshot(#{id := Id, name := Name, class := Class, starts := Starts, pid := Pid} = Actor) ->
    Status = status(Actor),
    {Mailbox, Memory} = usage(Status, Pid),
    #{id => Id, name => Name, class => Class, status => Status, restarts => max(0, Starts - 1),
      mailbox => Mailbox, memory => Memory}.

usage(Status, Pid) when Status =/= stopped, is_pid(Pid) ->
    case erlang:process_info(Pid, [message_queue_len, memory]) of
        [{message_queue_len, Length}, {memory, Bytes}] -> {Length, Bytes};
        undefined -> {0, 0}
    end;
usage(_Status, _Pid) ->
    {0, 0}.

%% Runs Fun in a new process, on a copy of the realm of the caller, so a
%% kill cannot leave the caller's heap half changed. When Ms passes first,
%% the process ends and the call throws CallTimedOut. The value comes back
%% as a structured clone. The new process keeps the context of the caller,
%% so a call cycle through it still throws CallCycle.
-spec with_timeout(non_neg_integer(), value()) -> value().
with_timeout(Ms, Fun) ->
    Copy = [Entry || {Key, _} = Entry <- get(), is_copied(Key)],
    Tag = make_ref(),
    Caller = self(),
    Worker = spawn_link(fun() -> Caller ! {Tag, run_copy(Copy, Fun)} end),
    case timed_outcome(Tag, Ms) of
        {done, {ok, Term}} ->
            clone_in(Term);
        {done, {throw, Term}} ->
            erlang:error({'$throw', clone_in(Term)});
        timeout ->
            true = unlink(Worker),
            true = exit(Worker, kill),
            receive
                {Tag, _Late} -> ok
            after 0 -> ok
            end,
            raise(call_timed_out(Ms))
    end.

%% The keys of the process dictionary that a copy of the realm keeps: its
%% heap and its realm state, without the calls, timers, and turn of the
%% caller, which belong to the caller's process.
is_copied(Key) ->
    not lists:member(Key, ['$ancestors', '$initial_call', ?CALLS, ?TURN, ?OUTCOME, ?UNCAUGHT,
                           '$buoy_timers', '$buoy_pending', '$buoy_microtasks']).

run_copy(Copy, Fun) ->
    lists:foreach(fun({Key, Value}) -> put(Key, Value) end, Copy),
    put(?UNCAUGHT, fun(Error) -> exit({'$buoy_copy_failed', Error}) end),
    try
        erase(?OUTCOME),
        buoy_jobs:run_job(fun() ->
            try buoy_heap:call(Fun, undefined, []) of
                Result -> settle(Result)
            catch
                error:Reason:Stack -> put(?OUTCOME, {crashed, buoy_ref:caught(Reason, Stack)})
            end
        end),
        case settled() of
            {ok, Value} -> reply_term(Value);
            {_Thrown, Error} -> {throw, clone_term(Error)}
        end
    catch
        exit:{'$buoy_copy_failed', Thrown} -> {throw, clone_term(Thrown)}
    end.

clone_term(Value) ->
    try clone_out(Value)
    catch
        error:{'$throw', _} -> error_term(<<"Error">>, js_text(Value), [])
    end.

%% The outcome of the copy, or timeout after Ms, which may exceed the
%% longest timeout of one `receive`.
timed_outcome(Tag, Ms) ->
    Chunk = min(Ms, 16#FFFFFFFF),
    receive
        {Tag, Outcome} -> {done, Outcome}
    after Chunk ->
        case Ms - Chunk of
            0 -> timeout;
            Rest -> timed_outcome(Tag, Rest)
        end
    end.

%%% The context of the calling process

-spec context() -> context().
context() ->
    case get(?CONTEXT) of
        undefined -> #context{owner = self()};
        Context -> Context
    end.

%% Whether every scope is live: no turn that it names has ended.
-spec live([atomics:atomics_ref() | none]) -> boolean().
live(Scopes) ->
    lists:all(fun is_live/1, Scopes).

is_live(none) -> true;
is_live(Scope) -> atomics:get(Scope, 1) =:= 0.

%% The live part of the call chain of the code that runs: the links up to the
%% first turn that has ended.
-spec chain() -> [link()].
chain() ->
    case get(?CONTEXT) of
        undefined -> [];
        #context{chain = Chain} -> live_prefix(Chain)
    end.

live_prefix([{_Id, Scope} = Link | Rest]) ->
    case is_live(Scope) of
        true -> [Link | live_prefix(Rest)];
        false -> []
    end;
live_prefix([]) ->
    [].

ids(Chain) -> [Id || {Id, _} <- Chain].

%% The ref of the actor whose realm runs the code.
-spec current() -> {'$actor', pos_integer()}.
current() ->
    case current_id() of
        undefined -> buoy_heap:throw_error('Error', <<"self() works only inside an actor">>);
        Id -> {'$actor', Id}
    end.

-spec current_id() -> pos_integer() | undefined.
current_id() ->
    (context())#context.actor.

%% The process that the code here acts for, which owns its timers: the
%% actor, or the top-level code.
-spec owner() -> pid().
owner() ->
    (context())#context.owner.

%% The owner of the timers that the code here starts.
-spec timer_owner() -> timer_owner().
timer_owner() ->
    #context{actor = Id, owner = Pid} = context(),
    {Id, Pid}.

%% Whether a constructor runs here, which then owns the actors it starts.
-spec constructing() -> boolean().
constructing() ->
    (context())#context.constructing.

%%% Messages between realms

%% The structured clone of Value for a message to another realm. An error
%% keeps its name, its message, its stack, and its own enumerable
%% properties, so a typed failure such as `{ _tag, balance }` arrives whole.
-spec clone_out(value()) -> term().
clone_out(Value) ->
    buoy_heap:clone_out(Value, fun error_out/1).

-spec clone_in(term()) -> value().
clone_in({'$buoy_error', _, _, _} = Error) ->
    error_value(Error);
clone_in(Term) ->
    buoy_heap:clone_in(Term, fun error_in/1).

error_out(O) ->
    case buoy_heap:class_of(O) of
        error ->
            Own = [{K, buoy_heap:get(O, K)} || K <- buoy_heap:enumerable_keys(O), ?IS_STRING(K)],
            Data = buoy_heap:object(?OBJECT_PROTO, [
                {<<"name">>, buoy_ref:to_string(buoy_heap:get(O, <<"name">>))},
                {<<"message">>, text_of(buoy_heap:get(O, <<"message">>))},
                {<<"stack">>, text_of(buoy_heap:get(O, <<"stack">>))},
                {<<"own">>, buoy_heap:object(?OBJECT_PROTO, Own)}
            ]),
            {host, error, Data};
        _ ->
            none
    end.

text_of(undefined) -> <<>>;
text_of(V) -> buoy_ref:to_string(V).

error_in({error, Data}) ->
    Name = buoy_heap:get(Data, <<"name">>),
    O = buoy_heap:error_object(error_proto(Name), buoy_heap:get(Data, <<"message">>), buoy_heap:get(Data, <<"stack">>)),
    Own = buoy_heap:get(Data, <<"own">>),
    Standard = error_proto(Name) =/= buoy_heap:intrinsic('Error.prototype') orelse Name =:= <<"Error">>,
    Standard orelse buoy_heap:set(O, <<"name">>, Name),
    lists:foreach(fun(K) -> buoy_heap:set(O, K, buoy_heap:get(Own, K)) end, buoy_heap:enumerable_keys(Own)),
    O.

error_proto(Name) ->
    case lists:member(Name, [<<"Error">>, <<"TypeError">>, <<"RangeError">>, <<"SyntaxError">>, <<"ReferenceError">>,
                             <<"EvalError">>, <<"URIError">>]) of
        true -> buoy_heap:intrinsic(binary_to_atom(<<Name/binary, ".prototype">>));
        false -> buoy_heap:intrinsic('Error.prototype')
    end.

%%% Errors of the runtime

-spec error_term(binary(), binary(), [{binary(), term()}]) -> error_term().
error_term(Name, Message, Fields) ->
    {'$buoy_error', Name, Message, Fields}.

%% String(error) of an error term.
error_text({'$buoy_error', Name, <<>>, _}) -> Name;
error_text({'$buoy_error', Name, Message, _}) -> <<Name/binary, ": ", Message/binary>>.

%% The error object of an error term in the current realm: an Error with the
%% name and the fields as own properties.
error_value({'$buoy_error', Name, Message, Fields}) ->
    Text = buoy_ref_string:from_utf8(Message),
    O = buoy_heap:error_object(error_proto(Name), Text, buoy_ref_string:from_utf8(error_text({'$buoy_error', Name, Message, Fields}))),
    error_proto(Name) =:= buoy_heap:intrinsic('Error.prototype') andalso Name =/= <<"Error">>
        andalso buoy_heap:set(O, <<"name">>, buoy_ref_string:from_utf8(Name)),
    lists:foreach(fun({Key, Value}) -> buoy_heap:set(O, Key, field_value(Value)) end, Fields),
    O.

field_value({clone, Term}) -> clone_in(Term);
field_value(Text) when is_binary(Text) -> buoy_ref_string:from_utf8(Text);
field_value(Value) -> Value.

%% Throws an error term, or a value, in the current realm.
-spec raise(error_term() | value()) -> no_return().
raise({'$buoy_error', _, _, _} = Error) ->
    erlang:error({'$throw', error_value(Error)});
raise(Value) ->
    erlang:error({'$throw', Value}).

%% `<class> <name>` or `<class> #<id>`.
label(#{class := Class, name := undefined, id := Id}) ->
    <<Class/binary, " #", (integer_to_binary(Id))/binary>>;
label(#{class := Class, name := Name}) ->
    <<Class/binary, " ", Name/binary>>.

actor_failed(Label, Method, CauseText, Cause) ->
    Message = <<Label/binary, " failed in ", Method/binary, ": ", CauseText/binary>>,
    tagged(<<"ActorFailed">>, Label, Message, [{<<"method">>, Method}, {<<"cause">>, Cause}]).

stopped(Actor) ->
    Label = label(Actor),
    tagged(<<"ActorStopped">>, Label, <<Label/binary, " is stopped">>, []).

%% Prints the crash line of an actor that its memory limit killed, and returns
%% the error.
-spec report_out_of_memory(#{class := binary(), name := binary() | undefined, id := pos_integer(), _ => _}) ->
    error_term().
report_out_of_memory(Actor) ->
    Error = out_of_memory(Actor),
    io:format(standard_error, "buoy: ~ts crashed: ~ts~n", [label(Actor), error_text(Error)]),
    Error.

%% The error of an actor that the memory limit killed: its own maxMemory, or
%% the limit of every process, which BUOY_MAX_MEMORY sets.
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
    tagged(<<"ActorOutOfMemory">>, Label, Message, [{<<"limit">>, Limit}]).

turn_timed_out(Label, Method, Ms) ->
    Message = <<Label/binary, " did not finish ", Method/binary, " within ", (integer_to_binary(Ms))/binary, " ms">>,
    tagged(<<"ActorTimedOut">>, Label, Message, [{<<"method">>, Method}, {<<"ms">>, Ms}]).

mailbox_full(Actor) ->
    Label = label(Actor),
    tagged(<<"MailboxFull">>, Label, <<Label/binary, " has a full mailbox">>, []).

call_cycle(Actor) ->
    Label = label(Actor),
    Message =
        <<Label/binary,
            " is busy with a call that waits on this call."
            " Use cast() or pass the data in the first call.">>,
    tagged(<<"CallCycle">>, Label, Message, []).

call_timed_out(Ms) ->
    Message = <<"the call did not finish within ", (integer_to_binary(Ms))/binary, " ms">>,
    error_term(<<"CallTimedOut">>, Message, [{<<"_tag">>, <<"CallTimedOut">>}, {<<"ms">>, Ms}]).

tagged(Tag, Label, Message, Fields) ->
    error_term(Tag, Message, [{<<"_tag">>, Tag}, {<<"actor">>, Label} | Fields]).
