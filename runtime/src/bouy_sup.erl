-module(bouy_sup).
-behaviour(supervisor).

%% `bouy_root_sup` owns the actor tables and supervises bouy_keeper, which
%% restarts the actors that spawn() starts, and `bouy_groups`, which
%% supervises one group supervisor for each supervise() call. A group
%% supervisor supervises actors, so the crash loop of one group cannot use up
%% the restart budget of another.
%%
%% A group starts empty and receives its actors through supervisor:start_child/2.
%% An actor runs its constructor in init/1, so `bouy_groups` never waits on
%% user code, and a constructor can spawn other actors. To stop a group, a
%% process kills it instead of asking `bouy_groups`, which would wait for a
%% constructor that the group runs.

-export([start_root/0, start_group/1, new_group/1, stop_group/1, stop_when_empty/1, stop_when_empty/2]).
-export([init/1]).

-define(ROOT, bouy_root_sup).
-define(GROUPS, bouy_groups).

-spec start_root() -> supervisor:startlink_ret().
start_root() ->
    supervisor:start_link({local, ?ROOT}, ?MODULE, root).

-spec start_group(supervisor:sup_flags()) -> supervisor:startlink_ret().
start_group(Flags) ->
    supervisor:start_link(?MODULE, {group, Flags}).

-spec new_group(supervisor:sup_flags()) -> pid().
new_group(Flags) ->
    {ok, Group} = supervisor:start_child(?GROUPS, [Flags]),
    Group.

%% Stops a group and every actor in it, and returns when the group is gone.
%% The actors have brutal_kill shutdowns and do not trap exits, so killing
%% the group kills them too.
-spec stop_group(pid()) -> ok.
stop_group(Group) ->
    Monitor = monitor(process, Group),
    true = exit(Group, kill),
    receive
        {'DOWN', Monitor, process, Group, _} -> ok
    end.

%% Stops a group that has no actor left: the last one was stopped, or was
%% temporary and crashed.
-spec stop_when_empty(pid()) -> ok.
stop_when_empty(Group) ->
    case is_empty(Group) of
        true -> stop_group(Group);
        false -> ok
    end.

%% The same, once the process Pid of a crashed actor has exited.
-spec stop_when_empty(pid(), pid()) -> ok.
stop_when_empty(Group, Pid) ->
    _ = spawn(fun() ->
        Monitor = monitor(process, Pid),
        receive
            {'DOWN', Monitor, process, Pid, _} -> stop_when_empty(Group)
        end
    end),
    ok.

%% No child runs or restarts. A child that has exited counts as gone,
%% because the group may not yet have removed it.
is_empty(Group) ->
    try supervisor:which_children(Group) of
        Children -> not lists:any(fun({_, Child, _, _}) -> Child =:= restarting orelse is_pid(Child) andalso is_process_alive(Child) end, Children)
    catch
        exit:_ -> false
    end.

-spec init(root | groups | {group, supervisor:sup_flags()}) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(root) ->
    ok = bouy_registry:create(),
    Keeper = #{
        id => bouy_keeper,
        start => {bouy_keeper, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },
    Groups = #{
        id => ?GROUPS,
        start => {supervisor, start_link, [{local, ?GROUPS}, ?MODULE, groups]},
        restart => permanent,
        shutdown => infinity,
        type => supervisor
    },
    {ok, {#{strategy => one_for_all, intensity => 0, period => 1}, [Keeper, Groups]}};
init(groups) ->
    Group = #{
        id => group,
        start => {?MODULE, start_group, []},
        restart => temporary,
        shutdown => infinity,
        type => supervisor
    },
    {ok, {#{strategy => simple_one_for_one, intensity => 0, period => 1}, [Group]}};
init({group, Flags}) ->
    {ok, {Flags, []}}.
