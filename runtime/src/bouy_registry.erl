-module(bouy_registry).

%% The ETS table `bouy_actors` maps an actor id to the current process of the
%% actor and to the facts that stay fixed for its life. A row outlives its
%% processes, so a ref stays valid across restarts and inspect/1 can report a
%% stopped actor.

-export([create/0, allocate/0, enter/3, vacate/1, mark_stopped/1, delete/1, find/1, all/0]).

-export_type([actor/0, info/0, mailbox/0, restart/0]).

-define(TABLE, bouy_actors).

-type restart() :: permanent | transient | temporary.
-type mailbox() :: {Capacity :: pos_integer(), Overflow :: backpressure | reject}.
-type info() :: #{
    supervisor := pid(),
    group := alone | tree,
    class := binary(),
    name := binary() | undefined,
    mailbox := mailbox(),
    restart := restart()
}.
-type actor() :: #{
    id := pos_integer(),
    pid := pid() | undefined,
    starts := non_neg_integer(),
    stopped := boolean(),
    supervisor := pid(),
    group := alone | tree,
    class := binary(),
    name := binary() | undefined,
    mailbox := mailbox(),
    restart := restart()
}.

%% Row positions.
-define(PID, 2).
-define(STARTS, 3).
-define(STOPPED, 4).

%% The calling process owns the table.
-spec create() -> ok.
create() ->
    ?TABLE = ets:new(?TABLE, [
        ordered_set, public, named_table, {read_concurrency, true}, {write_concurrency, true}
    ]),
    case persistent_term:get(?MODULE, undefined) of
        undefined -> persistent_term:put(?MODULE, atomics:new(1, [{signed, false}]));
        _ -> ok
    end.

-spec allocate() -> pos_integer().
allocate() ->
    atomics:add_get(persistent_term:get(?MODULE), 1, 1).

%% Records that Pid is the new process of actor Id. Returns how many processes
%% the actor has started, or `stopped` when stop/1 has ended the actor.
-spec enter(pos_integer(), pid(), info()) -> pos_integer() | stopped.
enter(Id, Pid, Info) ->
    case ets:insert_new(?TABLE, {Id, Pid, 1, false, Info}) of
        true -> 1;
        false -> reenter(Id, Pid)
    end.

reenter(Id, Pid) ->
    case ets:lookup_element(?TABLE, Id, ?STOPPED) of
        true ->
            stopped;
        false ->
            true = ets:update_element(?TABLE, Id, {?PID, Pid}),
            ets:update_counter(?TABLE, Id, {?STARTS, 1})
    end.

%% Clears the process of actor Id, so that callers wait for the restart
%% instead of sending to a process that is about to exit.
-spec vacate(pos_integer()) -> boolean().
vacate(Id) ->
    ets:update_element(?TABLE, Id, {?PID, undefined}).

-spec mark_stopped(pos_integer()) -> boolean().
mark_stopped(Id) ->
    ets:update_element(?TABLE, Id, {?STOPPED, true}).

-spec delete(pos_integer()) -> true.
delete(Id) ->
    ets:delete(?TABLE, Id).

-spec find(pos_integer()) -> {ok, actor()} | error.
find(Id) ->
    case ets:lookup(?TABLE, Id) of
        [Row] -> {ok, actor(Row)};
        [] -> error
    end.

%% Every actor, in id order.
-spec all() -> [actor()].
all() ->
    [actor(Row) || Row <- ets:tab2list(?TABLE)].

actor({Id, Pid, Starts, Stopped, Info}) ->
    Info#{id => Id, pid => Pid, starts => Starts, stopped => Stopped}.
