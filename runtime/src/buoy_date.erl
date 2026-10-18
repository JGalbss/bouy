%% `Date`, minimal: `Date.now()`, `new Date()`, `new Date(ms)`,
%% `new Date(isoString)`, `getTime`, `valueOf`, `toISOString`, `toJSON`, and
%% `toString` in UTC. A Date is `{'$date', Ms}`, where Ms is 'NaN' for an
%% invalid date. Other methods throw a TypeError.
-module(buoy_date).

-export(['$member'/1, '$call'/1, new/1, now/1, call/3, get/2, to_string/1]).

-type date() :: {'$date', integer() | 'NaN'}.
-export_type([date/0]).

%% The largest time value: 100,000,000 days from the epoch.
-define(MAX_TIME, 8640000000000000).
-define(DAY, 86400000).
-define(DAYS, {<<"Sun">>, <<"Mon">>, <<"Tue">>, <<"Wed">>, <<"Thu">>, <<"Fri">>, <<"Sat">>}).
-define(MONTHS, {<<"Jan">>, <<"Feb">>, <<"Mar">>, <<"Apr">>, <<"May">>, <<"Jun">>, <<"Jul">>, <<"Aug">>, <<"Sep">>, <<"Oct">>, <<"Nov">>, <<"Dec">>}).
-define(METHODS, [<<"getTime">>, <<"toISOString">>, <<"toJSON">>, <<"toString">>, <<"valueOf">>]).
-define(IS_DIGIT(C), (C >= $0 andalso C =< $9)).

-spec '$member'(binary()) -> term().
'$member'(Name) -> buoy_rt:member_function(?MODULE, Name, [<<"now">>]).

-spec now(list()) -> integer().
now(_Args) -> erlang:system_time(millisecond).

%% `Date()` without `new` yields the current time as a string.
-spec '$call'(list()) -> binary().
'$call'(_Args) -> to_string(new([])).

-spec new(list()) -> date().
new([]) -> {'$date', now([])};
new([{'$date', Time}]) -> {'$date', Time};
new([Text]) when is_binary(Text) -> {'$date', parse(Text)};
new([Value]) -> {'$date', time_clip(buoy_rt:to_number(Value))};
new(_Fields) -> unsupported(<<"new Date(year, month, ...)">>).

time_clip(N) when is_number(N), abs(N) =< ?MAX_TIME -> trunc(N);
time_clip(_) -> 'NaN'.

%%% Parsing

%% The date time string format of ECMAScript, with V8's leniencies: a day
%% up to 31 rolls into the next month, 24:00 ends the day, `t`, `z`, and a
%% space separator are accepted, the fraction may have any number of
%% digits, and an offset may omit its colon. A date alone, and a date-time
%% without an offset, are UTC. Text in another format is an invalid date.
parse(Text) ->
    try date_time(Text) of
        Time -> time_clip(Time)
    catch
        throw:invalid -> 'NaN'
    end.

date_time(Text) ->
    {Year, AfterYear} = year(Text),
    {Month, AfterMonth} = field(AfterYear, 1, 12),
    {Day, AfterDay} =
        case AfterMonth =:= AfterYear of
            true -> {1, AfterYear};
            false -> field(AfterMonth, 1, 31)
        end,
    days_from_civil(Year, Month, Day) * ?DAY + clock(AfterDay).

year(<<Sign, Digits:6/binary, Rest/binary>>) when Sign =:= $+; Sign =:= $- ->
    case {Sign, digits(Digits)} of
        {$-, 0} -> throw(invalid);
        {$-, Year} -> {-Year, Rest};
        {$+, Year} -> {Year, Rest}
    end;
year(<<Digits:4/binary, Rest/binary>>) ->
    {digits(Digits), Rest};
year(_) ->
    throw(invalid).

%% `-NN` in [Min, Max], or nothing, which counts as 1.
field(<<$-, Digits:2/binary, Rest/binary>>, Min, Max) ->
    {in_range(digits(Digits), Min, Max), Rest};
field(Rest, _Min, _Max) ->
    {1, Rest}.

clock(<<>>) ->
    0;
clock(<<Separator, Hours:2/binary, $:, Minutes:2/binary, Rest/binary>>) when Separator =:= $T; Separator =:= $t; Separator =:= $\s ->
    {Seconds, AfterSeconds} = seconds(Rest),
    {Millis, AfterMillis} = fraction(AfterSeconds),
    time_of_day(digits(Hours), in_range(digits(Minutes), 0, 59), Seconds, Millis) - offset(AfterMillis);
clock(_) ->
    throw(invalid).

seconds(<<$:, Digits:2/binary, Rest/binary>>) -> {in_range(digits(Digits), 0, 59), Rest};
seconds(Rest) -> {0, Rest}.

%% The first three digits of the fraction count, and the others are cut.
fraction(<<$., Rest/binary>>) ->
    case digit_run(Rest, 0) of
        0 ->
            throw(invalid);
        Size ->
            <<Digits:Size/binary, After/binary>> = Rest,
            {digits(binary:part(<<Digits/binary, "00">>, 0, 3)), After}
    end;
fraction(Rest) ->
    {0, Rest}.

digit_run(<<C, Rest/binary>>, N) when ?IS_DIGIT(C) -> digit_run(Rest, N + 1);
digit_run(_, N) -> N.

time_of_day(24, 0, 0, 0) -> ?DAY;
time_of_day(Hours, Minutes, Seconds, Millis) when Hours < 24 ->
    ((Hours * 60 + Minutes) * 60 + Seconds) * 1000 + Millis;
time_of_day(_, _, _, _) ->
    throw(invalid).

%% The offset of the zone in ms: none and `Z` are UTC.
offset(<<>>) -> 0;
offset(<<Z>>) when Z =:= $Z; Z =:= $z -> 0;
offset(<<Sign, Hours:2/binary, $:, Minutes:2/binary>>) -> zone(Sign, Hours, Minutes);
offset(<<Sign, Hours:2/binary, Minutes:2/binary>>) -> zone(Sign, Hours, Minutes);
offset(_) -> throw(invalid).

zone(Sign, Hours, Minutes) ->
    Ms = (in_range(digits(Hours), 0, 23) * 60 + in_range(digits(Minutes), 0, 59)) * 60000,
    case Sign of
        $+ -> Ms;
        $- -> -Ms;
        _ -> throw(invalid)
    end.

%% A run of decimal digits as an integer; anything else is invalid.
digits(Text) ->
    case Text =/= <<>> andalso digit_run(Text, 0) =:= byte_size(Text) of
        true -> binary_to_integer(Text);
        false -> throw(invalid)
    end.

in_range(N, Min, Max) when N >= Min, N =< Max -> N;
in_range(_, _, _) -> throw(invalid).

%%% The proleptic Gregorian calendar for any year, after Howard Hinnant's
%%% days_from_civil and civil_from_days.

days_from_civil(Year0, Month, Day) ->
    Year = case Month =< 2 of true -> Year0 - 1; false -> Year0 end,
    Era = floor_div(Year, 400),
    YearOfEra = Year - Era * 400,
    Shifted = case Month > 2 of true -> Month - 3; false -> Month + 9 end,
    DayOfYear = (153 * Shifted + 2) div 5 + Day - 1,
    DayOfEra = YearOfEra * 365 + YearOfEra div 4 - YearOfEra div 100 + DayOfYear,
    Era * 146097 + DayOfEra - 719468.

civil_from_days(Days0) ->
    Days = Days0 + 719468,
    Era = floor_div(Days, 146097),
    DayOfEra = Days - Era * 146097,
    YearOfEra = (DayOfEra - DayOfEra div 1460 + DayOfEra div 36524 - DayOfEra div 146096) div 365,
    DayOfYear = DayOfEra - (365 * YearOfEra + YearOfEra div 4 - YearOfEra div 100),
    Shifted = (5 * DayOfYear + 2) div 153,
    Day = DayOfYear - (153 * Shifted + 2) div 5 + 1,
    Month = case Shifted < 10 of true -> Shifted + 3; false -> Shifted - 9 end,
    Year = YearOfEra + Era * 400 + case Month =< 2 of true -> 1; false -> 0 end,
    {Year, Month, Day}.

floor_div(A, B) when A >= 0 -> A div B;
floor_div(A, B) -> -((B - 1 - A) div B).

%% The fields of a time value in UTC. 1970-01-01 was a Thursday.
fields(Time) ->
    Days = floor_div(Time, ?DAY),
    Ms = Time - Days * ?DAY,
    {Year, Month, Day} = civil_from_days(Days),
    {Year, Month, Day, Ms div 3600000, Ms div 60000 rem 60, Ms div 1000 rem 60, Ms rem 1000, (Days rem 7 + 11) rem 7}.

%%% Methods

-spec get(date(), term()) -> term().
get(_Date, Key) -> buoy_rt:member(?MODULE, Key, ?METHODS).

-spec call(binary(), date(), list()) -> term().
call(Name, {'$date', Time}, _Args) when Name =:= <<"getTime">>; Name =:= <<"valueOf">> ->
    Time;
call(<<"toISOString">>, {'$date', 'NaN'}, _Args) ->
    buoy_error:throw(<<"RangeError">>, <<"Invalid time value">>);
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

%% `YYYY-MM-DDTHH:mm:ss.sssZ`, with a signed six-digit year outside 0 to 9999.
iso(Time) ->
    {Year, Month, Day, Hours, Minutes, Seconds, Millis, _Weekday} = fields(Time),
    iolist_to_binary([
        iso_year(Year), $-, pad(Month, 2), $-, pad(Day, 2), $T,
        pad(Hours, 2), $:, pad(Minutes, 2), $:, pad(Seconds, 2), $., pad(Millis, 3), $Z
    ]).

iso_year(Year) when Year >= 0, Year =< 9999 -> pad(Year, 4);
iso_year(Year) when Year < 0 -> [$-, pad(-Year, 6)];
iso_year(Year) -> [$+, pad(Year, 6)].

%% Date.prototype.toString, in UTC.
-spec to_string(date()) -> binary().
to_string({'$date', 'NaN'}) ->
    <<"Invalid Date">>;
to_string({'$date', Time}) ->
    {Year, Month, Day, Hours, Minutes, Seconds, _Millis, Weekday} = fields(Time),
    iolist_to_binary([
        element(Weekday + 1, ?DAYS), $\s, element(Month, ?MONTHS), $\s, pad(Day, 2), $\s, display_year(Year), $\s,
        pad(Hours, 2), $:, pad(Minutes, 2), $:, pad(Seconds, 2), " GMT+0000 (Coordinated Universal Time)"
    ]).

%% At least four digits, after a minus sign for a year before 0.
display_year(Year) when Year < 0 -> [$-, pad(-Year, 4)];
display_year(Year) -> pad(Year, 4).

pad(N, Width) ->
    Digits = integer_to_binary(N),
    [lists:duplicate(max(0, Width - byte_size(Digits)), $0), Digits].

-spec unsupported(binary()) -> no_return().
unsupported(What) ->
    buoy_error:throw(<<"TypeError">>, <<What/binary, " is not supported by Buoy">>).
