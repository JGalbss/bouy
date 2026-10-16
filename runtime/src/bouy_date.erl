%% `Date`, minimal: `Date.now()`, `new Date()`, `new Date(ms)`,
%% `new Date(isoString)`, `getTime`, `valueOf`, `toISOString`, `toJSON`, and
%% `toString` in UTC. A Date is `{'$date', Ms}`, where Ms is 'NaN' for an
%% invalid date. Other methods throw a TypeError.
-module(bouy_date).

-export(['$member'/1, '$call'/1, new/1, now/1, call/3, get/2, to_string/1]).

-type date() :: {'$date', integer() | 'NaN'}.
-export_type([date/0]).

%% The largest time value: 100,000,000 days from the epoch.
-define(MAX_TIME, 8640000000000000).
-define(DAYS, {<<"Mon">>, <<"Tue">>, <<"Wed">>, <<"Thu">>, <<"Fri">>, <<"Sat">>, <<"Sun">>}).
-define(MONTHS, {<<"Jan">>, <<"Feb">>, <<"Mar">>, <<"Apr">>, <<"May">>, <<"Jun">>, <<"Jul">>, <<"Aug">>, <<"Sep">>, <<"Oct">>, <<"Nov">>, <<"Dec">>}).

-spec '$member'(binary()) -> term().
'$member'(Name) -> bouy_rt:member_function(?MODULE, Name, [<<"now">>]).

-spec now(list()) -> integer().
now(_Args) -> erlang:system_time(millisecond).

%% `Date()` without `new` yields the current time as a string.
-spec '$call'(list()) -> binary().
'$call'(_Args) -> to_string(new([])).

-spec new(list()) -> date().
new([]) -> {'$date', now([])};
new([{'$date', Time}]) -> {'$date', Time};
new([Text]) when is_binary(Text) -> {'$date', parse(Text)};
new([Value]) -> {'$date', time_clip(bouy_rt:to_number(Value))};
new(_Fields) -> unsupported(<<"new Date(year, month, ...)">>).

time_clip(N) when is_number(N), abs(N) =< ?MAX_TIME -> trunc(N);
time_clip(_) -> 'NaN'.

%% ISO 8601: a date alone is UTC midnight, and a date-time without an
%% offset is taken as UTC.
parse(Text) ->
    Candidates = [Text, <<Text/binary, "Z">>, <<Text/binary, "T00:00:00Z">>],
    case lists:filtermap(fun rfc3339/1, Candidates) of
        [Time | _] -> time_clip(Time);
        [] -> 'NaN'
    end.

rfc3339(Text) ->
    try calendar:rfc3339_to_system_time(binary_to_list(Text), [{unit, millisecond}]) of
        Time -> {true, Time}
    catch
        error:_ -> false
    end.

-spec get(date(), term()) -> undefined.
get(_Date, _Key) -> undefined.

-spec call(binary(), date(), list()) -> term().
call(Name, {'$date', Time}, _Args) when Name =:= <<"getTime">>; Name =:= <<"valueOf">> ->
    Time;
call(<<"toISOString">>, {'$date', 'NaN'}, _Args) ->
    bouy_error:throw(<<"RangeError">>, <<"Invalid time value">>);
call(<<"toISOString">>, {'$date', Time}, _Args) ->
    iso(Time);
call(<<"toJSON">>, {'$date', 'NaN'}, _Args) ->
    null;
call(<<"toJSON">>, {'$date', Time}, _Args) ->
    iso(Time);
call(<<"toString">>, Date, _Args) ->
    to_string(Date);
call(Name, _Date, _Args) ->
    unsupported(<<"Date.prototype.", Name/binary>>).

iso(Time) ->
    list_to_binary(calendar:system_time_to_rfc3339(Time, [{unit, millisecond}, {offset, "Z"}])).

%% Date.prototype.toString, in UTC.
-spec to_string(date()) -> binary().
to_string({'$date', 'NaN'}) ->
    <<"Invalid Date">>;
to_string({'$date', Time}) ->
    {{Year, Month, Day} = Date, {Hour, Minute, Second}} = calendar:system_time_to_universal_time(Time, millisecond),
    Weekday = element(calendar:day_of_the_week(Date), ?DAYS),
    iolist_to_binary(
        io_lib:format("~s ~s ~2..0B ~4..0B ~2..0B:~2..0B:~2..0B GMT+0000 (Coordinated Universal Time)", [
            Weekday, element(Month, ?MONTHS), Day, Year, Hour, Minute, Second
        ])
    ).

-spec unsupported(binary()) -> no_return().
unsupported(What) ->
    bouy_error:throw(<<"TypeError">>, <<What/binary, " is not supported by Bouy">>).
