-module(bouy_actor).
-behaviour(gen_server).

%% An actor is a gen_server whose state holds the class module and `This`.
%% A turn is one call or one cast, and the process handles one message at a
%% time, so turns never interleave.
%%
%% A turn runs with its call chain in the process dictionary: its own actor id
%% first, then the ids of the actors that wait on it. A call to an actor in the
%% chain throws CallCycle instead of a deadlock.

-export([start/1, start_link/1, call/3, cast/3, stop/1, snapshot/1]).
-export([context/0, adopt/1, chain/0, current/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([spec/0, context/0]).

-define(ACTOR, '$bouy_actor').
-define(CHAIN, '$bouy_chain').
-define(INFO, [supervisor, group, class, name, mailbox, restart]).
%% A {shutdown, _} exit keeps gen_server and proc_lib crash reports quiet.
-define(CRASHED, {shutdown, crashed}).

-type ref() :: {'$ref', pos_integer()}.
-type error_value() :: #{binary() => term()}.
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
-opaque context() :: {pos_integer() | undefined, [pos_integer()]}.

-record(state, {
    id :: pos_integer(),
    label :: binary(),
    module :: module(),
    dispatch :: atom(),
    this :: term()
}).
-type state() :: #state{}.
-type request() :: {call, binary(), list(), [pos_integer()]} | {cast, binary(), list()}.

%% Starts the actor of Spec in its group supervisor. When the constructor
%% throws, the start fails with ActorFailed and the actor leaves no row.
-spec start(spec()) -> ok | {error, error_value()}.
start(#{id := Id, supervisor := Group, restart := Restart} = Spec) ->
    Child = #{
        id => Id,
        start => {?MODULE, start_link, [Spec]},
        restart => otp_restart(Restart),
        shutdown => brutal_kill
    },
    case supervisor:start_child(Group, Child) of
        {ok, _Pid} ->
            ok;
        {error, {{constructor_failed, Cause}, _Child}} ->
            true = bouy_registry:delete(Id),
            {error, actor_failed(label(Spec), <<"constructor">>, Cause)}
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
    case lists:member(Id, Chain) of
        true -> raise(call_cycle(known(Id)));
        false -> request(Id, {call, Method, Args, Chain})
    end.

request(Id, Request) ->
    {#{pid := Pid} = Actor, Length} = resolve(Id),
    case admission(Actor, Length) of
        reject -> raise(mailbox_full(Actor));
        _Admission -> ok
    end,
    try gen_server:call(Pid, Request, infinity) of
        {ok, Value} -> Value;
        {throw, Error} -> erlang:error({'$throw', Error})
    catch
        exit:{noproc, _} -> request(Id, Request);
        exit:{_, {gen_server, call, _}} -> raise(stopped(Actor))
    end.

-spec cast({'$cast', pos_integer()}, binary(), list()) -> true.
cast({'$cast', Id} = Cast, Method, Args) ->
    {#{pid := Pid} = Actor, Length} = resolve(Id),
    case cast_admission(Actor, Length) of
        accept ->
            ok = gen_server:cast(Pid, {cast, Method, Args}),
            true;
        reject ->
            raise(mailbox_full(Actor));
        wait ->
            wait_for_room(Pid, Cast, Method, Args)
    end.

%% A sender in the chain of the actor cannot wait for it, so its cast goes in
%% at once.
cast_admission(#{id := Id} = Actor, Length) ->
    case admission(Actor, Length) of
        wait ->
            case lists:member(Id, chain()) of
                true -> accept;
                false -> wait
            end;
        Admission ->
            Admission
    end.

%% How a mailbox takes one more message: at once, after the sender waits for
%% the actor to take it, or not at all.
admission(#{mailbox := {Capacity, _}}, Length) when Length < Capacity -> accept;
admission(#{mailbox := {_, reject}}, _Length) -> reject;
admission(#{mailbox := {_, backpressure}}, _Length) -> wait.

%% The actor replies as soon as it takes the message. A message lost in a
%% crash counts as sent, as it does for any cast.
wait_for_room(Pid, Cast, Method, Args) ->
    try
        gen_server:call(Pid, {cast, Method, Args}, infinity)
    catch
        exit:{noproc, _} -> cast(Cast, Method, Args);
        exit:{_, {gen_server, call, _}} -> true
    end.

%% Finds the live process of actor Id and the length of its message queue.
%% While a supervisor restarts the actor, the caller waits.
resolve(Id) ->
    resolve(Id, 1).

resolve(Id, Delay) ->
    Actor = known(Id),
    case queue_length(Actor) of
        undefined -> await_restart(Actor, Delay);
        Length -> {Actor, Length}
    end.

queue_length(#{stopped := true}) ->
    undefined;
queue_length(#{pid := undefined}) ->
    undefined;
queue_length(#{pid := Pid}) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Length} -> Length;
        undefined -> undefined
    end.

await_restart(#{id := Id} = Actor, Delay) ->
    case status(Actor) of
        restarting ->
            timer:sleep(Delay),
            resolve(Id, min(2 * Delay, 16));
        _ ->
            raise(stopped(Actor))
    end.

known(Id) ->
    case bouy_registry:find(Id) of
        {ok, Actor} -> Actor;
        error -> raise(stopped(#{class => <<"actor">>, name => undefined, id => Id}))
    end.

status(#{stopped := true}) ->
    stopped;
status(#{pid := Pid} = Actor) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> running;
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
%% outside every actor waits for the end: a constructor blocks its group
%% supervisor, so a caller that a constructor waits on must not wait for that
%% supervisor.
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

stop_process(#{group := alone, supervisor := Group}) ->
    bouy_sup:stop_group(Group);
stop_process(#{group := tree, supervisor := Group, id := Id}) ->
    try
        _ = supervisor:terminate_child(Group, Id),
        _ = supervisor:delete_child(Group, Id),
        ok
    catch
        exit:{noproc, _} -> ok
    end.

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

usage(running, Pid) ->
    case erlang:process_info(Pid, [message_queue_len, memory]) of
        [{message_queue_len, Length}, {memory, Bytes}] -> {Length, Bytes};
        undefined -> {0, 0}
    end;
usage(_Status, _Pid) ->
    {0, 0}.

%% The actor and call chain of the calling process, for a process that works
%% on its behalf.
-spec context() -> context().
context() ->
    {get(?ACTOR), chain()}.

-spec adopt(context()) -> ok.
adopt({Actor, Chain}) ->
    put(?ACTOR, Actor),
    put(?CHAIN, Chain),
    ok.

-spec chain() -> [pos_integer()].
chain() ->
    case get(?CHAIN) of
        undefined -> [];
        Chain -> Chain
    end.

%% The ref of the actor whose turn runs in the calling process.
-spec current() -> ref().
current() ->
    case get(?ACTOR) of
        undefined -> bouy_error:throw(<<"Error">>, <<"self() works only inside an actor">>);
        Id -> {'$ref', Id}
    end.

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

construct(#{id := Id, module := Module, class := Class, args := Args} = Spec, Chain) ->
    put(?ACTOR, Id),
    put(?CHAIN, Chain),
    New = method(Class, <<"new">>),
    try Module:New(Args) of
        This ->
            {ok, #state{
                id = Id,
                label = label(Spec),
                module = Module,
                dispatch = method(Class, <<"dispatch">>),
                this = This
            }}
    catch
        Kind:Reason:Stack ->
            Cause = cause(Kind, Reason, Stack),
            record_crash(Id, label(Spec), Cause),
            {error, {constructor_failed, Cause}}
    end.

-spec handle_call(request(), gen_server:from(), state()) ->
    {reply, {ok, term()} | {throw, term()}, state()}
    | {stop, {shutdown, crashed}, {throw, error_value()}, state()}
    | {noreply, state()}
    | {stop, {shutdown, crashed}, state()}.
handle_call({call, Method, Args, Chain}, _From, #state{id = Id} = State) ->
    put(?CHAIN, [Id | Chain]),
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
    put(?CHAIN, [Id]),
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
crash(Method, Cause, #state{id = Id, label = Label}) ->
    record_crash(Id, Label, Cause),
    actor_failed(Label, Method, Cause).

record_crash(Id, Label, Cause) ->
    _ = bouy_registry:vacate(Id),
    io:format(standard_error, "bouy: ~ts crashed: ~ts~n", [Label, bouy_rt:to_string(Cause)]).

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
