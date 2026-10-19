-module(buoy_app).
-behaviour(application).

%% Starts the runtime: buoy_root_sup and the ETS table of actors. A program
%% without buoy.app on its code path calls start(normal, []) directly.

-export([start/2, stop/1, drop_supervisor_reports/2]).

-define(FILTER, buoy_supervisor_reports).

-spec start(application:start_type(), term()) -> supervisor:startlink_ret().
start(_Type, _Args) ->
    ok = quiet_supervisors(),
    buoy_sup:start_root().

-spec stop(term()) -> ok.
stop(_State) ->
    _ = logger:remove_primary_filter(?FILTER),
    ok.

%% Buoy prints one line for each crash, and OTP would add a multi-line report
%% for every restart and every used-up budget of a buoy supervisor.
quiet_supervisors() ->
    case logger:add_primary_filter(?FILTER, {fun ?MODULE:drop_supervisor_reports/2, []}) of
        ok -> ok;
        {error, {already_exist, ?FILTER}} -> ok
    end.

-spec drop_supervisor_reports(logger:log_event(), []) -> logger:filter_return().
drop_supervisor_reports(#{msg := {report, #{label := {supervisor, _}, report := Report}}}, []) ->
    case lists:keyfind(supervisor, 1, Report) of
        {supervisor, {_, buoy_sup}} -> stop;
        {supervisor, {local, buoy_root_sup}} -> stop;
        {supervisor, {local, buoy_groups}} -> stop;
        _ -> ignore
    end;
drop_supervisor_reports(_Event, []) ->
    ignore.
