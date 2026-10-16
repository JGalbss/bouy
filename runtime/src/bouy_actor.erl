-module(bouy_actor).
-behaviour(gen_server).

%% An actor is a gen_server whose state holds the class module and `This`.
%% A turn is one call or one cast, and the process handles one message at a
%% time, so turns never interleave.
%%
%% A turn runs with its context in the process dictionary: its call chain,
%% its own actor id first and then the ids of the actors that wait on it. A
%% call to an actor in the chain throws CallCycle instead of a deadlock. A
%% call that waits also records the wait in the wait-for graph of
%% bouy_registry, so two turns that call each other at once see the cycle.

-export([start/1, start_link/1, call/3, cast/3, offer/3, stop/1, snapshot/1]).
-export([context/0, adopt/1, within/2, live/1, chain/0, current/0, current_id/0, owner/0, constructing/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([spec/0, context/0]).

-define(CONTEXT, '$bouy_context').
-define(INFO, [supervisor, group, class, name, mailbox, restart]).
%% A {shutdown, _} exit keeps gen_server and proc_lib crash reports quiet.
-define(CRASHED, {shutdown, crashed}).

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
    supervisor := pid(),
    group := alone | tree,
    chain := [pos_integer()]
}.

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
    this :: term()
}).
-type state() :: #state{}.
-type request() :: {call, binary(), list(), [pos_integer()]} | {cast, binary(), list()}.

%% Starts the actor of Spec in its group supervisor. When the constructor
%% throws, the start fails with ActorFailed and the actor is stopped.
-spec start(spec()) -> ok | {error, error_value()}.
start(#{id := Id, supervisor := Group, restart := Restart} = Spec) ->
    Child = #{
        id => Id,
        start => {?MODULE, start_link, [Spec]},
        restart => otp_restart(Restart),
        shutdown => brutal_kill
    },
    try supervisor:start_child(Group, Child) of
        {ok, _Pid} ->
            ok;
        {error, {{constructor_failed, Cause}, _Child}} ->
            _ = bouy_registry:mark_stopped(Id),
            {error, actor_failed(label(Spec), <<"constructor">>, Cause)};
        {error, Reason} ->
            _ = bouy_registry:mark_stopped(Id),
            Message = unicode:characters_to_binary(io_lib:format("~0tp", [Reason])),
            {error, actor_failed(label(Spec), <<"constructor">>, bouy_error:new(<<"Error">>, Message))}
    catch
        %% stop() killed the group while the constructor ran, as when a
        %% constructor stops its own actor: the actor exists, stopped.
        exit:_ ->
            _ = bouy_registry:mark_stopped(Id),
            ok
    end.

%% A crash exits with a {shutdown, _} reason, and OTP restarts a child after
%% such an exit only when the child is permanent. An actor never exits
%% normally, so a transient actor is a permanent OTP child.
otp_restart(temporary) -> temporary;
otp_restart(_) -> permanent.

-spec start_link(spec()) -> gen_server:start_ret().
start_link(Spec) ->
    gen_server:start_link(?MODULE, Spec, []).

-spec call(ref(), binary(), list()) -> term().
call({'$ref', Id}, Method, Args) ->
    Chain = chain(),
    Waited =
        case lists:member(Id, Chain) of
            true -> cycle;
            false -> waiting(Chain, Id, fun() -> request(Id, Method, Args, Chain) end)
        end,
    case Waited of
        {done, Value} -> Value;
        cycle -> raise(call_cycle(known(Id)))
    end.

request(Id, Method, Args, Chain) ->
    {Actor, Pid, Count, Starts} = admit(Id, {ready, Chain}),
    case Actor of
        #{mailbox := {Capacity, reject}} when Count > Capacity ->
            ok = bouy_registry:release(Id, Starts),
            raise(mailbox_full(Actor));
        _ ->
            ok
    end,
    try gen_server:call(Pid, {call, Method, Args, Chain}, infinity) of
        {ok, Value} -> Value;
        {throw, Error} -> erlang:error({'$throw', Error})
    catch
        exit:{noproc, _} ->
            ok = bouy_registry:release(Id, Starts),
            request(Id, Method, Args, Chain);
        exit:{_, {gen_server, call, _}} ->
            ok = bouy_registry:release(Id, Starts),
            raise(stopped(Actor))
    end.

-spec cast({'$cast', pos_integer()}, binary(), list()) -> true.
cast({'$cast', Id} = Cast, Method, Args) ->
    {#{mailbox := {Capacity, Overflow}} = Actor, Pid, Count, Starts} = admit(Id, alive),
    case {Count =< Capacity, Overflow} of
        {true, _} ->
            send(Pid, Method, Args);
        {false, reject} ->
            ok = bouy_registry:release(Id, Starts),
            raise(mailbox_full(Actor));
        {false, backpressure} ->
            wait_for_room(Actor, Pid, Starts, Cast, Method, Args)
    end.

%% A cast that never waits, for the timer of schedule(): a full mailbox, or
%% an actor that restarts, skips it, so the timer stays free to stop.
-spec offer({'$cast', pos_integer()}, binary(), list()) -> sent | skipped | stopped.
offer({'$cast', Id}, Method, Args) ->
    case {bouy_registry:occupy(Id), bouy_registry:find(Id)} of
        {{Count, Starts}, {ok, #{stopped := false, starts := Starts, pid := Pid, mailbox := {Capacity, _}} = Actor}} when is_pid(Pid) ->
            case Count =< Capacity andalso is_process_alive(Pid) of
                true -> send(Pid, Method, Args), sent;
                false -> skip(Actor, Starts)
            end;
        {{_Count, Starts}, {ok, Actor}} ->
            skip(Actor, Starts);
        _Gone ->
            stopped
    end.

skip(#{id := Id} = Actor, Starts) ->
    ok = bouy_registry:release(Id, Starts),
    case status(Actor) of
        stopped -> stopped;
        _ -> skipped
    end.

send(Pid, Method, Args) ->
    ok = gen_server:cast(Pid, {cast, Method, Args}),
    true.

%% With backpressure, the sender waits until the actor takes the cast. An
%% actor that waits on the sender, directly or through other actors, could
%% never take it, so the cast goes in at once.
wait_for_room(#{id := Id} = Actor, Pid, Starts, Cast, Method, Args) ->
    Chain = chain(),
    case lists:member(Id, Chain) of
        true ->
            send(Pid, Method, Args);
        false ->
            case waiting(Chain, Id, fun() -> room(Actor, Pid, Starts, Cast, Method, Args) end) of
                {done, Sent} -> Sent;
                cycle -> send(Pid, Method, Args)
            end
    end.

%% The actor replies as soon as it takes the cast. A cast lost in a crash
%% counts as sent, as any cast does; a stopped actor throws ActorStopped.
room(#{id := Id} = Actor, Pid, Starts, Cast, Method, Args) ->
    try
        gen_server:call(Pid, {cast, Method, Args}, infinity)
    catch
        exit:{noproc, _} ->
            ok = bouy_registry:release(Id, Starts),
            cast(Cast, Method, Args);
        exit:{_, {gen_server, call, _}} ->
            ok = bouy_registry:release(Id, Starts),
            case bouy_registry:find(Id) of
                {ok, #{stopped := true}} -> raise(stopped(Actor));
                _ -> true
            end
    end.

%% Runs Wait, which waits on actor Target, with the wait recorded in the
%% wait-for graph: `{done, Result}`, or `cycle` when Target waits on the
%% chain, directly or through other actors, so the wait would never end.
%% Each side records its wait before it looks, so of two turns that wait on
%% each other at once, at least one sees the cycle.
waiting([], _Target, Wait) ->
    {done, Wait()};
waiting([From | _] = Chain, Target, Wait) ->
    #context{scopes = Scopes, constructing = Constructing} = context(),
    ok = bouy_registry:wait(From, Target, Scopes),
    try
        case not Constructing andalso reaches([Target], Chain, #{}) of
            true -> cycle;
            false -> {done, Wait()}
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

%% Counts one request for actor Id and finds its live process: the actor,
%% the pid, the count, and the start the count belongs to. While a
%% supervisor restarts the actor, the sender waits. A call also waits while
%% the constructor of the actor runs, and looks for a wait cycle meanwhile:
%% a constructor never throws CallCycle for one, so the call that waits on
%% it does.
admit(Id, Need) ->
    admit(Id, Need, 1).

admit(Id, Need, Delay) ->
    case bouy_registry:occupy(Id) of
        stopped ->
            raise(stopped(known(Id)));
        {Count, Starts} ->
            Actor = known(Id),
            case Actor of
                #{stopped := false, starts := Starts, pid := Pid, ready := Ready} when is_pid(Pid) ->
                    case is_process_alive(Pid) of
                        true when Ready; Need =:= alive -> {Actor, Pid, Count, Starts};
                        _ -> readmit(Actor, Starts, Need, Delay)
                    end;
                _ ->
                    readmit(Actor, Starts, Need, Delay)
            end
    end.

readmit(#{id := Id} = Actor, Starts, Need, Delay) ->
    ok = bouy_registry:release(Id, Starts),
    case {status(Actor), Need} of
        {stopped, _} ->
            raise(stopped(Actor));
        {_, {ready, [_ | _] = Chain}} ->
            case reaches([Id], Chain, #{}) of
                true -> raise(call_cycle(Actor));
                false -> pause(Id, Need, Delay)
            end;
        _ ->
            pause(Id, Need, Delay)
    end.

pause(Id, Need, Delay) ->
    timer:sleep(Delay),
    admit(Id, Need, min(2 * Delay, 16)).

%% The row of actor Id. A ref outlives the row of a long-stopped actor, and
%% then its label has only the id.
known(Id) ->
    case bouy_registry:find(Id) of
        {ok, Actor} -> Actor;
        error -> raise(stopped(#{class => <<"actor">>, name => undefined, id => Id}))
    end.

%% An actor runs once its constructor has finished, and restarts while a
%% supervisor brings up its next process.
status(#{stopped := true}) ->
    stopped;
status(#{pid := Pid, ready := Ready, starts := Starts} = Actor) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true when Ready; Starts =:= 1 -> running;
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

%% A group never waits on the root supervisor here, so a constructor that
%% runs in the group cannot block other spawns.
stop_process(#{group := alone, supervisor := Group, id := Id}) ->
    ok = bouy_sup:stop_group(Group),
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

%%% gen_server

-spec init(spec()) -> {ok, state()} | {error, {constructor_failed, term()}} | ignore.
init(#{id := Id} = Spec) ->
    case bouy_registry:enter(Id, self(), maps:with(?INFO, Spec)) of
        stopped -> ignore;
        Starts -> construct(Spec, first_chain(Starts, Spec))
    end.

%% Only the first start runs inside the call to spawn(), so only that
%% constructor waits on the chain of the spawner.
first_chain(1, #{id := Id, chain := Chain}) -> [Id | Chain];
first_chain(_Starts, #{id := Id}) -> [Id].

construct(#{id := Id, module := Module, class := Class, args := Args, restart := Restart, supervisor := Group} = Spec, Chain) ->
    put(?CONTEXT, #context{actor = Id, chain = Chain, owner = self(), constructing = true}),
    State = #state{
        id = Id,
        label = label(Spec),
        module = Module,
        dispatch = method(Class, <<"dispatch">>),
        restart = Restart,
        supervisor = Group
    },
    New = method(Class, <<"new">>),
    try Module:New(Args) of
        This ->
            true = bouy_registry:ready(Id),
            {ok, State#state{this = This}}
    catch
        Kind:Reason:Stack ->
            Cause = cause(Kind, Reason, Stack),
            record_crash(State, Cause),
            {error, {constructor_failed, Cause}}
    end.

-spec handle_call(request(), gen_server:from(), state()) ->
    {reply, {ok, term()} | {throw, term()}, state()}
    | {stop, {shutdown, crashed}, {throw, error_value()}, state()}
    | {noreply, state()}
    | {stop, {shutdown, crashed}, state()}.
handle_call({call, Method, Args, Chain}, _From, #state{id = Id} = State) ->
    ok = bouy_registry:take(Id),
    begin_turn(Id, [Id | Chain]),
    case turn(Method, Args, State) of
        {ok, Value, This} -> {reply, {ok, Value}, State#state{this = This}};
        {failed, Failure, This} -> {reply, {throw, Failure}, State#state{this = This}};
        {crashed, Cause} -> {stop, ?CRASHED, {throw, crash(Method, Cause, State)}, State}
    end;
handle_call({cast, _Method, _Args} = Cast, From, State) ->
    gen_server:reply(From, true),
    handle_cast(Cast, State).

-spec handle_cast({cast, binary(), list()}, state()) ->
    {noreply, state()} | {stop, {shutdown, crashed}, state()}.
handle_cast({cast, Method, Args}, #state{id = Id} = State) ->
    ok = bouy_registry:take(Id),
    begin_turn(Id, [Id]),
    case turn(Method, Args, State) of
        {crashed, Cause} ->
            _ = crash(Method, Cause, State),
            {stop, ?CRASHED, State};
        {_Outcome, _Result, This} ->
            {noreply, State#state{this = This}}
    end.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(_Message, State) ->
    {noreply, State}.

begin_turn(Id, Chain) ->
    put(?CONTEXT, #context{actor = Id, chain = Chain, owner = self()}).

%% Runs one method. A method that returns an Effect runs it in the same turn:
%% a typed failure keeps the state, and an exception crashes the actor.
turn(Method, Args, #state{module = Module, dispatch = Dispatch, this = This}) ->
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
    record_crash(State, Cause),
    actor_failed(Label, Method, Cause).

%% A temporary actor never restarts, so it is stopped, and its group ends
%% once no actor is left in it.
record_crash(#state{id = Id, label = Label, restart = Restart, supervisor = Group}, Cause) ->
    _ = bouy_registry:vacate(Id),
    io:format(standard_error, "bouy: ~ts crashed: ~ts~n", [Label, bouy_rt:to_string(Cause)]),
    case Restart of
        temporary ->
            _ = bouy_registry:mark_stopped(Id),
            bouy_sup:stop_when_empty(Group, self());
        _ ->
            ok
    end.

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

method(Class, Name) ->
    binary_to_atom(<<Class/binary, "#", Name/binary>>).

actor_failed(Label, Method, Cause) ->
    Message = <<Label/binary, " failed in ", Method/binary, ": ",
        (bouy_rt:to_string(Cause))/binary>>,
    tagged(<<"ActorFailed">>, Label, Message, #{<<"method">> => Method, <<"cause">> => Cause}).

stopped(Actor) ->
    Label = label(Actor),
    tagged(<<"ActorStopped">>, Label, <<Label/binary, " is stopped">>, #{}).

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
