-module(buoy_keeper).
-behaviour(gen_server).

%% Restarts the actors that spawn() starts. Each one is a single process
%% linked to the keeper, with a restart budget of its own (?INTENSITY
%% restarts within ?PERIOD seconds, as an OTP supervisor counts them), so a
%% crashing actor cannot use up the budget of another one. A restart runs in
%% a new process, so a slow constructor never blocks the keeper.
%%
%% The keeper also ends what an owner leaves behind: the actors and the
%% supervise() groups that a constructor started stop when the process of
%% that constructor ends. It marks the actors of a supervise() group stopped
%% when the group ends, and a temporary child of a group when its process
%% ends, since no supervisor restarts it.
%%
%% An actor process that dies with the reason `killed`, unmarked by stop(),
%% passed its memory limit: the keeper prints its crash line and restarts a
%% spawned actor. The group of a child restarts the child.
%%
%% The turn timers of the actors with a turn timeout fire here. A turn that
%% still runs ends as a crash (buoy_actor:timed_out/1), and the supervisor of
%% the actor restarts it.

-export([start_link/0, own/2, watch_group/2, watch_temporary/2, watch_memory/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(INTENSITY, 3).
-define(PERIOD, 5).

-type owned() :: {actor, pos_integer()} | {group, pid(), [pos_integer()]}.
-type watch() ::
    {owner, pid(), [owned()]} | {group, [pos_integer()]} | {temporary, pos_integer(), pid()} | {memory, pos_integer()}.
-record(keeper, {
    %% The restart times of each actor that restarted, in seconds, the latest first.
    restarts = #{} :: #{pos_integer() => [integer()]},
    watches = #{} :: #{reference() => watch()},
    owners = #{} :: #{pid() => reference()}
}).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% What Owned leaves behind ends when process Owner ends.
-spec own(pid(), owned()) -> ok.
own(Owner, Owned) ->
    gen_server:cast(?MODULE, {own, Owner, Owned}).

-spec watch_group(pid(), [pos_integer()]) -> ok.
watch_group(Group, Ids) ->
    gen_server:cast(?MODULE, {watch, Group, {group, Ids}}).

-spec watch_temporary(pid(), pos_integer()) -> ok.
watch_temporary(Pid, Id) ->
    gen_server:cast(?MODULE, {watch, Pid, {temporary, Id, Pid}}).

%% Prints the crash line when the memory limit kills process Pid of actor Id.
%% A call, so the watch exists before the actor takes a request.
-spec watch_memory(pid(), pos_integer()) -> ok.
watch_memory(Pid, Id) ->
    gen_server:call(?MODULE, {watch, Pid, {memory, Id}}).

-spec init([]) -> {ok, #keeper{}}.
init([]) ->
    process_flag(trap_exit, true),
    {ok, #keeper{}}.

-spec handle_call(term(), gen_server:from(), #keeper{}) -> {reply, ok, #keeper{}}.
handle_call({watch, Pid, Watch}, _From, #keeper{watches = Watches} = State) ->
    {reply, ok, State#keeper{watches = Watches#{monitor(process, Pid) => Watch}}};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast({own, pid(), owned()} | {watch, pid(), watch()}, #keeper{}) -> {noreply, #keeper{}}.
handle_cast({own, Owner, Owned}, #keeper{watches = Watches, owners = Owners} = State) ->
    case Owners of
        #{Owner := Monitor} ->
            {owner, Owner, Before} = maps:get(Monitor, Watches),
            {noreply, State#keeper{watches = Watches#{Monitor := {owner, Owner, [Owned | Before]}}}};
        #{} ->
            Monitor = monitor(process, Owner),
            {noreply, State#keeper{watches = Watches#{Monitor => {owner, Owner, [Owned]}}, owners = Owners#{Owner => Monitor}}}
    end;
handle_cast({watch, Pid, Watch}, #keeper{watches = Watches} = State) ->
    {noreply, State#keeper{watches = Watches#{monitor(process, Pid) => Watch}}}.

-spec handle_info(term(), #keeper{}) -> {noreply, #keeper{}}.
handle_info({timeout, _Timer, {turn, _, _, _, _, _, _, _} = Turn}, State) ->
    ok = buoy_actor:timed_out(Turn),
    {noreply, State};
handle_info({'EXIT', _Pid, {shutdown, {crashed, Id}}}, State) ->
    {noreply, restart(Id, State)};
handle_info({'EXIT', _Pid, {shutdown, stopped}}, State) ->
    {noreply, State};
handle_info({'EXIT', Pid, Reason}, State) ->
    %% A runtime fault, not a JavaScript exception, or the memory limit: the actor
    %% restarts as after a crash.
    case buoy_registry:id_of(Pid) of
        {ok, Id} -> {noreply, fault(Id, Reason, State)};
        error -> {noreply, State}
    end;
handle_info({'DOWN', Monitor, process, _Pid, Reason}, #keeper{watches = Watches, owners = Owners} = State) ->
    case maps:take(Monitor, Watches) of
        {Watch, Rest} ->
            ok = ended(Watch, Reason),
            {noreply, State#keeper{watches = Rest, owners = maps:remove(owner(Watch), Owners)}};
        error ->
            {noreply, State}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

owner({owner, Owner, _Owned}) -> Owner;
owner(_Watch) -> none.

ended({owner, _Owner, Owned}, _Reason) ->
    lists:foreach(fun stop_owned/1, Owned);
ended({group, Ids}, _Reason) ->
    lists:foreach(fun stop_marked/1, Ids);
ended({temporary, Id, Pid}, _Reason) ->
    case buoy_registry:pid(Id) of
        Pid -> stop_marked(Id);
        _Restarted -> ok
    end;
ended({memory, Id}, killed) ->
    case buoy_registry:find(Id) of
        {ok, #{mode := Mode} = Actor} when Mode =/= stopped -> out_of_memory(Actor);
        _StoppedOrForgotten -> ok
    end;
ended({memory, _Id}, _Reason) ->
    ok.

%% A spawned actor whose process ended outside a crash. stop() marks the actor
%% before it kills the process, so a kill without the mark is the memory limit.
%% The spawner reports a kill during the first constructor.
fault(Id, Reason, State) ->
    case {buoy_registry:find(Id), Reason} of
        {{ok, #{mode := stopped}}, _} ->
            State;
        {{ok, #{mode := {starting, _, _, _}, starts := 1}}, killed} ->
            State;
        {{ok, #{restart := temporary} = Actor}, killed} ->
            ok = out_of_memory(Actor),
            _ = buoy_registry:mark_stopped(Id),
            State;
        {{ok, Actor}, killed} ->
            ok = out_of_memory(Actor),
            restart(Id, State);
        _Fault ->
            restart(Id, State)
    end.

out_of_memory(Actor) ->
    _ = buoy_actor:report_out_of_memory(Actor),
    ok.

%% The process is read after the mark, as in buoy_actor:stop/1.
stop_owned({actor, Id}) ->
    _ = buoy_registry:mark_stopped(Id),
    case buoy_registry:pid(Id) of
        Pid when is_pid(Pid) -> true = exit(Pid, {shutdown, stopped});
        undefined -> ok
    end,
    buoy_registry:drop_waits(Id);
stop_owned({group, Group, Ids}) ->
    lists:foreach(fun buoy_registry:mark_stopped/1, Ids),
    true = exit(Group, kill),
    ok.

stop_marked(Id) ->
    case buoy_registry:mode(Id) of
        stopped -> ok;
        _ ->
            _ = buoy_registry:mark_stopped(Id),
            ok
    end.

%% A restart within the budget starts a new process; past the budget, the
%% actor is stopped. A stopped actor never restarts.
restart(Id, #keeper{restarts = Restarts} = State) ->
    case buoy_registry:find(Id) of
        {ok, #{mode := stopped}} ->
            State#keeper{restarts = maps:remove(Id, Restarts)};
        {ok, Actor} ->
            Now = erlang:monotonic_time(second),
            Recent = [Time || Time <- maps:get(Id, Restarts, []), Time >= Now - ?PERIOD],
            case length(Recent) < ?INTENSITY of
                true ->
                    Spec = spec(Actor),
                    _ = erlang:spawn_opt(buoy_actor, init_alone, [Spec, none], [link | buoy_actor:spawn_options(Spec)]),
                    State#keeper{restarts = Restarts#{Id => [Now | Recent]}};
                false ->
                    _ = buoy_registry:mark_stopped(Id),
                    State#keeper{restarts = maps:remove(Id, Restarts)}
            end;
        error ->
            State
    end.

spec(Actor) ->
    maps:with([id, supervisor, group, module, home, class, args, name, mailbox, restart, max_memory, turn_timeout], Actor).
