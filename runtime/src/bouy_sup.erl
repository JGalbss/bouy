-module(bouy_sup).
-behaviour(supervisor).

%% `bouy_root_sup` supervises one group supervisor for each top-level spawn and
%% one for each supervise() call. A group supervisor supervises actors, so one
%% actor's crash loop cannot use up the restart budget of another group.
%%
%% A group starts empty and receives its actors through supervisor:start_child/2.
%% An actor runs its constructor in init/1, so the root supervisor never waits
%% on user code, and a constructor can spawn other actors.

-export([start_root/0, start_group/1, new_group/1, stop_group/1]).
-export([init/1]).

-define(ROOT, bouy_root_sup).

-spec start_root() -> supervisor:startlink_ret().
start_root() ->
    supervisor:start_link({local, ?ROOT}, ?MODULE, root).

-spec start_group(supervisor:sup_flags()) -> supervisor:startlink_ret().
start_group(Flags) ->
    supervisor:start_link(?MODULE, {group, Flags}).

-spec new_group(supervisor:sup_flags()) -> pid().
new_group(Flags) ->
    {ok, Group} = supervisor:start_child(?ROOT, [Flags]),
    Group.

%% Stops a group and every actor in it.
-spec stop_group(pid()) -> ok.
stop_group(Group) ->
    _ = supervisor:terminate_child(?ROOT, Group),
    ok.

-spec init(root | {group, supervisor:sup_flags()}) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(root) ->
    ok = bouy_registry:create(),
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
