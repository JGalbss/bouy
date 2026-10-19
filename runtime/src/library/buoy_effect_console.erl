%% `Console` from "effect" (contract section 13): each function returns an
%% Effect that writes as the `console` method of the same name when it runs.
-module(buoy_effect_console).

-compile({no_auto_import, [error/1]}).

-export(['$member'/1, log/1, error/1, warn/1, info/1, debug/1]).

-define(FUNCTIONS, [<<"log">>, <<"error">>, <<"warn">>, <<"info">>, <<"debug">>]).

-spec '$member'(binary()) -> term().
'$member'(Name) -> buoy_rt:member_function(?MODULE, Name, ?FUNCTIONS).

-spec log(list()) -> buoy_effect:effect().
log(Args) -> write(fun buoy_console:log/1, Args).

-spec error(list()) -> buoy_effect:effect().
error(Args) -> write(fun buoy_console:error/1, Args).

-spec warn(list()) -> buoy_effect:effect().
warn(Args) -> write(fun buoy_console:warn/1, Args).

-spec info(list()) -> buoy_effect:effect().
info(Args) -> write(fun buoy_console:info/1, Args).

-spec debug(list()) -> buoy_effect:effect().
debug(Args) -> write(fun buoy_console:debug/1, Args).

write(Method, Args) ->
    {'$effect', fun() -> {ok, Method(Args)} end}.
