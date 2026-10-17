-module(bouy_registry).

%% The ETS table `bouy_actors` maps an actor id to the state of the actor and
%% to the facts that stay fixed for its life. A row outlives its processes, so
%% a ref stays valid across restarts and inspect/1 can report a stopped actor.
%% The table keeps the rows of the ?KEEP stopped actors with the highest ids,
%% so a program that starts and stops actors forever keeps bounded memory.
%%
%% The mode of a row is all that a call or a cast reads: `{running, Pid,
%% Counter, Mailbox}` once the constructor of process Pid has finished,
%% `{starting, Pid, Counter, Mailbox}` while it runs, `restarting` while no
%% process serves the actor, or `stopped`. Counter is an atomics array of one
%% start of the actor: it counts the requests that the process has not taken.
%% A sender adds one before it sends and the actor takes one off when it takes
%% the request, so concurrent senders cannot pass the capacity together. A new
%% process gets a new counter, since the messages of a dead process are lost.
%%
%% The ETS table `bouy_watchers` holds `{Id, Pid, Ref}` while process Pid
%% waits for the row of actor Id to change. Each change of a mode sends
%% `{Ref, changed}` to those processes and forgets them.
%%
%% The ETS table `bouy_waits` holds the wait-for graph: `{From, To, Waiter,
%% Scopes}` while process Waiter, acting for actor From, waits on actor To.

-export([create/0, allocate/0, enter/3, ready/4, vacate/2, mark_stopped/1]).
-export([mode/1, pid/1, id_of/1, find/1, all/0]).
-export([watch/2, unwatch/2, notify/1]).
-export([wait/3, unwait/3, waits_on/1, drop_waits/1]).

-export_type([actor/0, info/0, mode/0, mailbox/0, restart/0]).

-define(TABLE, bouy_actors).
-define(STOPPED_TABLE, bouy_stopped_actors).
-define(WATCHERS, bouy_watchers).
-define(WAITS, bouy_waits).
-define(KEEP, 1000).

-type restart() :: permanent | transient | temporary.
-type mailbox() :: {Capacity :: pos_integer(), Overflow :: backpressure | reject}.
-type mode() ::
    {running | starting, pid(), atomics:atomics_ref(), mailbox()}
    | restarting
    | stopped.
-type info() :: #{
    supervisor := pid(),
    group := alone | tree,
    module := module(),
    class := binary(),
    args := list(),
    name := binary() | undefined,
    mailbox := mailbox(),
    restart := restart(),
    max_memory => pos_integer() | infinity
}.
-type actor() :: #{
    id := pos_integer(),
    mode := mode(),
    pid := pid(),
    starts := pos_integer(),
    stopped := boolean(),
    supervisor := pid(),
    group := alone | tree,
    module := module(),
    class := binary(),
    args := list(),
    name := binary() | undefined,
    mailbox := mailbox(),
    restart := restart(),
    max_memory => pos_integer() | infinity
}.

%% Row positions: {Id, Mode, Pid, Starts, Stopped, Info}. Pid is the last
%% process that entered, which stop/1 ends. Stopped stays true once the mode
%% is `stopped`.
-define(MODE, 2).
-define(PID, 3).
-define(STARTS, 4).
-define(STOPPED, 5).

%% The calling process owns the tables.
-spec create() -> ok.
create() ->
    Options = [public, named_table, {read_concurrency, true}, {write_concurrency, true}],
    ?TABLE = ets:new(?TABLE, [set | Options]),
    ?STOPPED_TABLE = ets:new(?STOPPED_TABLE, [ordered_set | Options]),
    ?WATCHERS = ets:new(?WATCHERS, [bag | Options]),
    ?WAITS = ets:new(?WAITS, [duplicate_bag | Options]),
    case persistent_term:get(?MODULE, undefined) of
        undefined -> persistent_term:put(?MODULE, atomics:new(1, [{signed, false}]));
        _ -> ok
    end.

-spec allocate() -> pos_integer().
allocate() ->
    atomics:add_get(persistent_term:get(?MODULE), 1, 1).

%% Records that Pid is the new process of actor Id, with a new counter.
%% Returns how many processes the actor has started and the counter, or
%% `stopped` when stop/1 has ended the actor. The mode and the pid change in
%% one write that fails on a stopped row, and stop/1 reads the pid after it
%% marks the row, so either stop/1 sees this process or it sees the mark.
-spec enter(pos_integer(), pid(), info()) -> {pos_integer(), atomics:atomics_ref()} | stopped.
enter(Id, Pid, #{mailbox := Mailbox} = Info) ->
    Counter = atomics:new(1, []),
    Mode = {starting, Pid, Counter, Mailbox},
    case ets:insert_new(?TABLE, {Id, Mode, Pid, 1, false, Info}) of
        true -> {1, Counter};
        false -> reenter(Id, Mode, Pid, Counter)
    end.

reenter(Id, Mode, Pid, Counter) ->
    Replace = {{Id, {const, Mode}, {const, Pid}, {'+', '$1', 1}, false, '$2'}},
    case ets:select_replace(?TABLE, [{{Id, '_', '_', '$1', false, '$2'}, [], [Replace]}]) of
        1 ->
            notify(Id),
            {ets:lookup_element(?TABLE, Id, ?STARTS, 2), Counter};
        0 ->
            stopped
    end.

%% The constructor of process Pid has finished. When stop/1 marked the row
%% before this write, the mark is written again, so the mode ends stopped
%% either way.
-spec ready(pos_integer(), pid(), atomics:atomics_ref(), mailbox()) -> ok.
ready(Id, Pid, Counter, Mailbox) ->
    _ = ets:update_element(?TABLE, Id, {?MODE, {running, Pid, Counter, Mailbox}}),
    case ets:lookup_element(?TABLE, Id, ?STOPPED, true) of
        true -> _ = ets:update_element(?TABLE, Id, {?MODE, stopped});
        false -> ok
    end,
    notify(Id).

%% Process Pid of actor Id is about to exit after a crash, so callers wait for
%% the restart instead of sending to it.
-spec vacate(pos_integer(), pid()) -> ok.
vacate(Id, Pid) ->
    Head = {Id, {'_', Pid, '_', '_'}, '$1', '$2', false, '$3'},
    _ = ets:select_replace(?TABLE, [{Head, [], [{{Id, restarting, '$1', '$2', false, '$3'}}]}]),
    notify(Id).

%% Marks actor Id stopped, then forgets the stopped actors beyond ?KEEP.
-spec mark_stopped(pos_integer()) -> boolean().
mark_stopped(Id) ->
    Marked = ets:update_element(?TABLE, Id, [{?MODE, stopped}, {?STOPPED, true}]),
    true = ets:insert(?STOPPED_TABLE, {Id}),
    forget(ets:info(?STOPPED_TABLE, size) - ?KEEP),
    notify(Id),
    Marked.

forget(Excess) when Excess > 0 ->
    case ets:first(?STOPPED_TABLE) of
        '$end_of_table' ->
            ok;
        Oldest ->
            true = ets:delete(?STOPPED_TABLE, Oldest),
            true = ets:delete(?TABLE, Oldest),
            forget(Excess - 1)
    end;
forget(_Excess) ->
    ok.

%% The mode of actor Id, or `forgotten` when the table has no row for it.
-spec mode(pos_integer()) -> mode() | forgotten.
mode(Id) ->
    ets:lookup_element(?TABLE, Id, ?MODE, forgotten).

%% The last process of actor Id.
-spec pid(pos_integer()) -> pid() | undefined.
pid(Id) ->
    ets:lookup_element(?TABLE, Id, ?PID, undefined).

%% The actor whose last process is Pid. It scans the table, for the rare
%% exit that names no actor.
-spec id_of(pid()) -> {ok, pos_integer()} | error.
id_of(Pid) ->
    case ets:match(?TABLE, {'$1', '_', Pid, '_', '_', '_'}) of
        [[Id]] -> {ok, Id};
        _ -> error
    end.

-spec find(pos_integer()) -> {ok, actor()} | error.
find(Id) ->
    case ets:lookup(?TABLE, Id) of
        [Row] -> {ok, actor(Row)};
        [] -> error
    end.

%% Every actor, in id order.
-spec all() -> [actor()].
all() ->
    [actor(Row) || Row <- lists:sort(ets:tab2list(?TABLE))].

actor({Id, Mode, Pid, Starts, Stopped, Info}) ->
    Info#{id => Id, mode => Mode, pid => Pid, starts => Starts, stopped => Stopped}.

%%% Processes that wait for a change of a row

-spec watch(pos_integer(), reference()) -> ok.
watch(Id, Ref) ->
    true = ets:insert(?WATCHERS, {Id, self(), Ref}),
    ok.

-spec unwatch(pos_integer(), reference()) -> ok.
unwatch(Id, Ref) ->
    true = ets:delete_object(?WATCHERS, {Id, self(), Ref}),
    ok.

-spec notify(pos_integer()) -> ok.
notify(Id) ->
    lists:foreach(fun({_, Pid, Ref}) -> Pid ! {Ref, changed} end, ets:take(?WATCHERS, Id)).

%%% The wait-for graph

-spec wait(pos_integer(), pos_integer(), list()) -> ok.
wait(From, To, Scopes) ->
    true = ets:insert(?WAITS, {From, To, self(), Scopes}),
    ok.

-spec unwait(pos_integer(), pos_integer(), list()) -> ok.
unwait(From, To, Scopes) ->
    true = ets:delete_object(?WAITS, {From, To, self(), Scopes}),
    ok.

%% The actors that actor Id waits on now. A record whose waiter has died, or
%% whose scope has ended, no longer waits, and it is removed.
-spec waits_on(pos_integer()) -> [pos_integer()].
waits_on(Id) ->
    [To || {_, To, Waiter, Scopes} = Wait <- ets:lookup(?WAITS, Id), current(Wait, Waiter, Scopes)].

current(Wait, Waiter, Scopes) ->
    case is_process_alive(Waiter) andalso bouy_actor:live(Scopes) of
        true ->
            true;
        false ->
            true = ets:delete_object(?WAITS, Wait),
            false
    end.

%% Forgets every wait of actor Id, whose processes have ended.
-spec drop_waits(pos_integer()) -> ok.
drop_waits(Id) ->
    true = ets:delete(?WAITS, Id),
    ok.
