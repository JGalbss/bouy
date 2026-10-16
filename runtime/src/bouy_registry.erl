-module(bouy_registry).

%% The ETS table `bouy_actors` maps an actor id to the current process of the
%% actor and to the facts that stay fixed for its life. A row outlives its
%% processes, so a ref stays valid across restarts and inspect/1 can report a
%% stopped actor. The table keeps the rows of the ?KEEP stopped actors with
%% the highest ids, so a program that starts and stops actors forever keeps
%% bounded memory.
%%
%% A row also counts the requests that the actor has not taken yet. A sender
%% adds one before it sends and the actor takes one off when it takes the
%% request, so concurrent senders cannot pass the capacity together. The
%% count belongs to one start of the actor: a new process sets it to zero,
%% since the messages of a dead process are lost.
%%
%% The ETS table `bouy_waits` holds the wait-for graph: `{From, To, Waiter,
%% Scopes}` while process Waiter, acting for actor From, waits on actor To.

-export([create/0, allocate/0, enter/3, ready/1, vacate/1, mark_stopped/1, find/1, all/0]).
-export([occupy/1, release/2, take/1]).
-export([wait/3, unwait/3, waits_on/1, drop_waits/1]).

-export_type([actor/0, info/0, mailbox/0, restart/0]).

-define(TABLE, bouy_actors).
-define(STOPPED_TABLE, bouy_stopped_actors).
-define(WAITS, bouy_waits).
-define(KEEP, 1000).

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
    ready := boolean(),
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
-define(SLOTS, 6).
-define(READY, 7).

%% The calling process owns the tables.
-spec create() -> ok.
create() ->
    Options = [public, named_table, {read_concurrency, true}, {write_concurrency, true}],
    ?TABLE = ets:new(?TABLE, [ordered_set | Options]),
    ?STOPPED_TABLE = ets:new(?STOPPED_TABLE, [ordered_set | Options]),
    ?WAITS = ets:new(?WAITS, [bag | Options]),
    case persistent_term:get(?MODULE, undefined) of
        undefined -> persistent_term:put(?MODULE, atomics:new(1, [{signed, false}]));
        _ -> ok
    end.

-spec allocate() -> pos_integer().
allocate() ->
    atomics:add_get(persistent_term:get(?MODULE), 1, 1).

%% Records that Pid is the new process of actor Id, with no request counted.
%% Returns how many processes the actor has started, or `stopped` when
%% stop/1 has ended the actor.
-spec enter(pos_integer(), pid(), info()) -> pos_integer() | stopped.
enter(Id, Pid, Info) ->
    case ets:insert_new(?TABLE, {Id, Pid, 1, false, Info, 0, false}) of
        true -> 1;
        false -> reenter(Id, Pid)
    end.

%% The count of the new start and its zero change together, before the pid
%% names the new process, so a sender that finds the new pid counts in the
%% new start.
reenter(Id, Pid) ->
    case ets:lookup_element(?TABLE, Id, ?STOPPED) of
        true ->
            stopped;
        false ->
            [Starts, 0] = ets:update_counter(?TABLE, Id, [{?STARTS, 1}, {?SLOTS, 0, -16#FFFFFFFF, 0}]),
            true = ets:update_element(?TABLE, Id, [{?PID, Pid}, {?READY, false}]),
            Starts
    end.

%% The constructor of the current process of actor Id has finished.
-spec ready(pos_integer()) -> boolean().
ready(Id) ->
    ets:update_element(?TABLE, Id, {?READY, true}).

%% Clears the process of actor Id, so that callers wait for the restart
%% instead of sending to a process that is about to exit.
-spec vacate(pos_integer()) -> boolean().
vacate(Id) ->
    ets:update_element(?TABLE, Id, [{?PID, undefined}, {?READY, false}]).

%% Marks actor Id stopped, then forgets the stopped actors beyond ?KEEP.
-spec mark_stopped(pos_integer()) -> boolean().
mark_stopped(Id) ->
    Marked = ets:update_element(?TABLE, Id, {?STOPPED, true}),
    true = ets:insert(?STOPPED_TABLE, {Id}),
    forget(ets:info(?STOPPED_TABLE, size) - ?KEEP),
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

actor({Id, Pid, Starts, Stopped, Info, _Slots, Ready}) ->
    Info#{id => Id, pid => Pid, starts => Starts, stopped => Stopped, ready => Ready}.

%%% Requests that an actor has not taken yet

%% Counts one more request for actor Id. Returns the count and the start
%% that it belongs to, or `stopped` when the actor has no row.
-spec occupy(pos_integer()) -> {pos_integer(), pos_integer()} | stopped.
occupy(Id) ->
    try ets:update_counter(?TABLE, Id, [{?SLOTS, 1}, {?STARTS, 0}]) of
        [Count, Starts] -> {Count, Starts}
    catch
        error:badarg -> stopped
    end.

%% Takes back a request that was not sent, unless the actor has started
%% again since, which reset the count.
-spec release(pos_integer(), pos_integer()) -> ok.
release(Id, Starts) ->
    Head = {Id, '$1', Starts, '$2', '$3', '$4', '$5'},
    Body = {{Id, '$1', Starts, '$2', '$3', {'-', '$4', 1}, '$5'}},
    _ = ets:select_replace(?TABLE, [{Head, [], [Body]}]),
    ok.

%% The actor took a request from its mailbox.
-spec take(pos_integer()) -> ok.
take(Id) ->
    try ets:update_counter(?TABLE, Id, {?SLOTS, -1}) of
        _ -> ok
    catch
        error:badarg -> ok
    end.

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
