-module(bouy_app).
-behaviour(application).

%% Starts the runtime: bouy_root_sup and the ETS table of actors. A program
%% without bouy.app on its code path calls start(normal, []) directly.

-export([start/2, stop/1, drop_supervisor_reports/2]).

-define(FILTER, bouy_supervisor_reports).

-spec start(application:start_type(), term()) -> supervisor:startlink_ret().
start(_Type, _Args) ->
    ok = quiet_supervisors(),
    bouy_sup:start_root().

-spec stop(term()) -> ok.
stop(_State) ->
    _ = logger:remove_primary_filter(?FILTER),
    ok.

%% Bouy prints one line for each crash, and OTP would add a multi-line report
%% for every restart and every used-up budget of a bouy supervisor.
quiet_supervisors() ->
    case logger:add_primary_filter(?FILTER, {fun ?MODULE:drop_supervisor_reports/2, []}) of
        ok -> ok;
        {error, {already_exist, ?FILTER}} -> ok
    end.

-spec drop_supervisor_reports(logger:log_event(), []) -> logger:filter_return().
drop_supervisor_reports(#{msg := {report, #{label := {supervisor, _}, report := Report}}}, []) ->
    case lists:keyfind(supervisor, 1, Report) of
        {supervisor, {_, bouy_sup}} -> stop;
        {supervisor, {local, bouy_root_sup}} -> stop;
        {supervisor, {local, bouy_groups}} -> stop;
        _ -> ignore
    end;
drop_supervisor_reports(_Event, []) ->
    ignore.
