%% `performance` (contract section 11): `performance.now()` is the time since
%% the VM started, in milliseconds, as a float with microsecond resolution,
%% from the monotonic clock of the VM.
-module(bouy_performance).

-export(['$member'/1, now/1]).

-spec '$member'(binary()) -> term().
'$member'(Name) -> bouy_rt:member_function(?MODULE, Name, [<<"now">>]).

-spec now(list()) -> float().
now(_Args) ->
    Started = erlang:convert_time_unit(erlang:system_info(start_time), native, microsecond),
    (erlang:monotonic_time(microsecond) - Started) / 1000.
