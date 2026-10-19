%% The Date family: the Date constructor, Date.now, Date.parse, Date.UTC,
%% and Date.prototype, over the time value that a date object holds in its
%% slots: an integer of milliseconds since the epoch, or 'NaN'.
%%
%% The arithmetic follows the abstract operations of the specification
%% (MakeTime, MakeDay, MakeDate, TimeClip), with the numbers of
%% buoy_ref_number, so huge and fractional arguments behave as IEEE 754
%% doubles. Local time comes from buoy_ref_tz, the TZif data of the zone.
-module(buoy_ref_date).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, inspect/1]).
-export([parse/1, to_iso_string/1]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).

-compile({no_auto_import, [now/0]}).

-define(DAY, 86400000).
-define(LIMIT, 8640000000000000).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Methods = ?METHODS(<<"Date.prototype">>, prototype_methods()),
    {_, ToUTCString} = lists:keyfind(<<"toUTCString">>, 1, Methods),
    ToPrimitive = buoy_ref_realm:builtin(<<"Date.prototype[Symbol.toPrimitive]">>, <<"[Symbol.toPrimitive]">>, 1,
                                          fun(This, Args) -> ?MODULE:method(<<"Date.prototype">>, <<"[Symbol.toPrimitive]">>, This, Args) end),
    [{'Date.prototype', record(object, ?OBJECT_PROTO, Methods ++ [{<<"toGMTString">>, ToUTCString}, {<<"constructor">>, constructor()},
                                                               {?SYM(toPrimitive), ToPrimitive, 4}], none)},
     {{builtin, <<"Date">>}, ctor_record(<<"Date">>, 7, {'$o', 'Date.prototype'}, ?METHODS(<<"Date">>, [{<<"now">>, 0}, {<<"parse">>, 1}, {<<"UTC">>, 7}]), fun construct/2)}].

prototype_methods() ->
    [{<<"getDate">>, 0}, {<<"getDay">>, 0}, {<<"getFullYear">>, 0}, {<<"getHours">>, 0}, {<<"getMilliseconds">>, 0},
     {<<"getMinutes">>, 0}, {<<"getMonth">>, 0}, {<<"getSeconds">>, 0}, {<<"getTime">>, 0}, {<<"getTimezoneOffset">>, 0},
     {<<"getUTCDate">>, 0}, {<<"getUTCDay">>, 0}, {<<"getUTCFullYear">>, 0}, {<<"getUTCHours">>, 0},
     {<<"getUTCMilliseconds">>, 0}, {<<"getUTCMinutes">>, 0}, {<<"getUTCMonth">>, 0}, {<<"getUTCSeconds">>, 0},
     {<<"getYear">>, 0}, {<<"setDate">>, 1}, {<<"setFullYear">>, 3}, {<<"setHours">>, 4}, {<<"setMilliseconds">>, 1},
     {<<"setMinutes">>, 3}, {<<"setMonth">>, 2}, {<<"setSeconds">>, 2}, {<<"setTime">>, 1}, {<<"setUTCDate">>, 1},
     {<<"setUTCFullYear">>, 3}, {<<"setUTCHours">>, 4}, {<<"setUTCMilliseconds">>, 1}, {<<"setUTCMinutes">>, 3},
     {<<"setUTCMonth">>, 2}, {<<"setUTCSeconds">>, 2}, {<<"setYear">>, 1}, {<<"toDateString">>, 0}, {<<"toISOString">>, 0},
     {<<"toJSON">>, 1}, {<<"toLocaleDateString">>, 0}, {<<"toLocaleString">>, 0}, {<<"toLocaleTimeString">>, 0},
     {<<"toString">>, 0}, {<<"toTimeString">>, 0}, {<<"toUTCString">>, 0}, {<<"valueOf">>, 0},
     {<<"toTemporalInstant">>, 0}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Date">>, constructor()}].

constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Date">>).

%% Date() without new: the string of the current time.
-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"Date">>, _This, _Args) -> date_string(now(), full).

now() -> erlang:system_time(millisecond).

construct(NewTarget, Args) ->
    Time = case Args of
        [] -> now();
        [Value] ->
            case ?IS_OBJECT(Value) andalso buoy_heap:class_of(Value) =:= date of
                true -> buoy_heap:slots(Value);
                false ->
                    case buoy_ref:to_primitive(Value, default) of
                        S when ?IS_STRING(S) -> parse(S);
                        P -> time_clip(buoy_ref:to_number(P))
                    end
            end;
        _ ->
            [Y, M | Rest] = [buoy_ref:to_number(A) || A <- lists:sublist(Args, 7)],
            Fields = Rest ++ lists:nthtail(length(Rest), [1, 0, 0, 0, 0]),
            [D, H, Min, S, Ms] = Fields,
            Local = make_date(make_day(full_year(Y), M, D), make_time(H, Min, S, Ms)),
            time_clip(utc(Local))
    end,
    buoy_heap:new_exotic(date, buoy_ref_realm:proto_for(NewTarget, 'Date.prototype'), Time).

%% The console form of a date, as Node prints it.
-spec inspect(term()) -> binary().
inspect(O) ->
    case buoy_heap:slots(O) of
        'NaN' -> <<"Invalid Date">>;
        T -> iso(T)
    end.

%%% Methods

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Date">>, <<"now">>, _This, _Args) -> now();
method(<<"Date">>, <<"parse">>, _This, Args) -> parse(buoy_ref:to_string(arg(1, Args)));
method(<<"Date">>, <<"UTC">>, _This, Args) ->
    [Y | Rest] = [buoy_ref:to_number(A) || A <- lists:sublist(Args, 7)] ++ ['NaN' || Args =:= []],
    Fields = Rest ++ lists:nthtail(length(Rest), [0, 1, 0, 0, 0, 0]),
    [M, D, H, Min, S, Ms] = Fields,
    time_clip(make_date(make_day(full_year(Y), M, D), make_time(H, Min, S, Ms)));
method(<<"Date.prototype">>, <<"toJSON">>, This, _Args) ->
    O = buoy_ref:to_object(This),
    case buoy_ref:to_primitive(O, number) of
        N when ?IS_NUMBER(N), not is_number(N) -> null;
        _ -> buoy_ref:call_method(O, <<"toISOString">>, [])
    end;
method(<<"Date.prototype">>, <<"[Symbol.toPrimitive]">>, This, Args) ->
    ?IS_OBJECT(This) orelse buoy_ref:type_error(<<"Date.prototype[Symbol.toPrimitive] called on non-object">>),
    Order = case arg(1, Args) of
        H when H =:= <<"string">>; H =:= <<"default">> -> [<<"toString">>, <<"valueOf">>];
        <<"number">> -> [<<"valueOf">>, <<"toString">>];
        _ -> buoy_ref:type_error(<<"Invalid hint">>)
    end,
    ordinary_to_primitive(This, Order);
method(<<"Date.prototype">>, Name, This, Args) -> proto(Name, this_time(This, Name), This, Args).

ordinary_to_primitive(_O, []) -> buoy_ref:type_error(<<"Cannot convert object to primitive value">>);
ordinary_to_primitive(O, [Name | Rest]) ->
    case buoy_ref:get(O, Name) of
        {'$f', _, _} = F ->
            case buoy_ref:call(F, O, []) of
                R when ?IS_OBJECT(R) -> ordinary_to_primitive(O, Rest);
                R -> R
            end;
        _ -> ordinary_to_primitive(O, Rest)
    end.

%% thisTimeValue.
this_time({'$o', _} = O, Name) ->
    case buoy_heap:class_of(O) of
        date -> buoy_heap:slots(O);
        _ -> not_a_date(Name)
    end;
this_time(_, Name) -> not_a_date(Name).

-spec not_a_date(binary()) -> no_return().
not_a_date(_Name) -> buoy_ref:type_error(<<"this is not a Date object.">>).

set_time(O, T) ->
    buoy_heap:set_slots(O, T),
    T.

proto(<<"valueOf">>, T, _O, _) -> T;
proto(<<"getTime">>, T, _O, _) -> T;
proto(<<"getTimezoneOffset">>, 'NaN', _O, _) -> 'NaN';
proto(<<"getTimezoneOffset">>, T, _O, _) -> (T - local(T)) div 60000;
proto(<<"getYear">>, 'NaN', _O, _) -> 'NaN';
proto(<<"getYear">>, T, _O, _) -> year(local(T)) - 1900;
proto(<<"get", Field/binary>>, T, _O, _) -> get_field(Field, T);
proto(<<"setTime">>, _T, O, Args) -> set_time(O, time_clip(buoy_ref:to_number(arg(1, Args))));
proto(<<"setMilliseconds">>, T, O, Args) -> set_fields(O, T, local, [{ms, arg(1, Args)}]);
proto(<<"setUTCMilliseconds">>, T, O, Args) -> set_fields(O, T, utc, [{ms, arg(1, Args)}]);
proto(<<"setSeconds">>, T, O, Args) -> set_fields(O, T, local, fields([sec, ms], Args));
proto(<<"setUTCSeconds">>, T, O, Args) -> set_fields(O, T, utc, fields([sec, ms], Args));
proto(<<"setMinutes">>, T, O, Args) -> set_fields(O, T, local, fields([min, sec, ms], Args));
proto(<<"setUTCMinutes">>, T, O, Args) -> set_fields(O, T, utc, fields([min, sec, ms], Args));
proto(<<"setHours">>, T, O, Args) -> set_fields(O, T, local, fields([hour, min, sec, ms], Args));
proto(<<"setUTCHours">>, T, O, Args) -> set_fields(O, T, utc, fields([hour, min, sec, ms], Args));
proto(<<"setDate">>, T, O, Args) -> set_fields(O, T, local, [{date, arg(1, Args)}]);
proto(<<"setUTCDate">>, T, O, Args) -> set_fields(O, T, utc, [{date, arg(1, Args)}]);
proto(<<"setMonth">>, T, O, Args) -> set_fields(O, T, local, fields([month, date], Args));
proto(<<"setUTCMonth">>, T, O, Args) -> set_fields(O, T, utc, fields([month, date], Args));
proto(<<"setFullYear">>, T, O, Args) -> set_fields(O, T, local, fields([year, month, date], Args));
proto(<<"setUTCFullYear">>, T, O, Args) -> set_fields(O, T, utc, fields([year, month, date], Args));
proto(<<"setYear">>, T, O, Args) ->
    Y = buoy_ref:to_number(arg(1, Args)),
    Base = case T of
        'NaN' -> 0;
        _ -> local(T)
    end,
    case Y of
        'NaN' -> set_time(O, 'NaN');
        _ ->
            Year = full_year(Y),
            Day = make_day(Year, month(Base), date(Base)),
            set_time(O, time_clip(utc(make_date(Day, time_within_day(Base)))))
    end;
proto(<<"toISOString">>, 'NaN', _O, _) -> buoy_heap:throw_error('RangeError', <<"Invalid time value">>);
proto(<<"toISOString">>, T, _O, _) -> iso(T);
proto(<<"toTemporalInstant">>, 'NaN', _O, _) -> buoy_heap:throw_error('RangeError', <<"Invalid time value">>);
proto(<<"toTemporalInstant">>, T, _O, _) -> buoy_ref_temporal:to_instant(T);
proto(<<"toString">>, T, _O, _) -> date_string(T, full);
proto(<<"toDateString">>, T, _O, _) -> date_string(T, date);
proto(<<"toTimeString">>, T, _O, _) -> date_string(T, time);
proto(<<"toUTCString">>, 'NaN', _O, _) -> <<"Invalid Date">>;
proto(<<"toUTCString">>, T, _O, _) ->
    iolist_to_binary([weekday_name(T), ", ", pad(date(T), 2), " ", month_name(T), " ", year_text(year(T)), " ", clock(T), " GMT"]);
proto(<<"toLocaleString">>, T, _O, _) -> locale(T, both);
proto(<<"toLocaleDateString">>, T, _O, _) -> locale(T, date);
proto(<<"toLocaleTimeString">>, T, _O, _) -> locale(T, time).

%% The arguments of a setter, by the names of its fields.
fields(Names, Args) ->
    Count = max(1, min(length(Names), length(Args))),
    lists:zip(lists:sublist(Names, Count), lists:sublist(Args ++ [undefined], Count)).

%% A setter: ToNumber of each given argument, in order, then the new time
%% value from the fields of the current one.
set_fields(O, T, Zone, Given) ->
    Numbers = [{Name, buoy_ref:to_number(V)} || {Name, V} <- Given],
    Year = proplists:get_value(year, Numbers),
    case T of
        'NaN' when Year =:= undefined -> 'NaN';
        _ ->
            Base = case {T, Zone} of
                {'NaN', _} -> 0;
                {_, local} -> local(T);
                {_, utc} -> T
            end,
            Get = fun(Name, Default) -> proplists:get_value(Name, Numbers, Default) end,
            Day = make_day(case Year of undefined -> year(Base); _ -> Year end,
                           Get(month, month(Base)), Get(date, date(Base))),
            Time = make_time(Get(hour, hour(Base)), Get(min, minute(Base)), Get(sec, second(Base)), Get(ms, millisecond(Base))),
            New = make_date(Day, Time),
            set_time(O, time_clip(case Zone of
                                      local -> utc(New);
                                      utc -> New
                                  end))
    end.

get_field(_Field, 'NaN') -> 'NaN';
get_field(<<"UTC", Field/binary>>, T) -> field(Field, T);
get_field(Field, T) -> field(Field, local(T)).

field(<<"FullYear">>, T) -> year(T);
field(<<"Month">>, T) -> month(T);
field(<<"Date">>, T) -> date(T);
field(<<"Day">>, T) -> weekday(T);
field(<<"Hours">>, T) -> hour(T);
field(<<"Minutes">>, T) -> minute(T);
field(<<"Seconds">>, T) -> second(T);
field(<<"Milliseconds">>, T) -> millisecond(T).

%%% Time arithmetic of the specification

day(T) -> floor_div(T, ?DAY).
time_within_day(T) -> T - day(T) * ?DAY.

floor_div(A, B) when A >= 0 -> A div B;
floor_div(A, B) -> -((-A + B - 1) div B).

days_in_year(Y) ->
    case is_leap(Y) of
        true -> 366;
        false -> 365
    end.

is_leap(Y) -> (Y rem 4 =:= 0 andalso Y rem 100 =/= 0) orelse Y rem 400 =:= 0.

day_from_year(Y) -> 365 * (Y - 1970) + floor_div(Y - 1969, 4) - floor_div(Y - 1901, 100) + floor_div(Y - 1601, 400).

year(T) ->
    D = day(T),
    Estimate = 1970 + floor_div(D * 400, 146097),
    year_fix(D, Estimate).

year_fix(D, Y) ->
    Start = day_from_year(Y),
    End = Start + days_in_year(Y),
    if
        Start > D -> year_fix(D, Y - 1);
        End =< D -> year_fix(D, Y + 1);
        true -> Y
    end.

month_starts(Y) ->
    Feb = case is_leap(Y) of
        true -> 29;
        false -> 28
    end,
    Lengths = [31, Feb, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31],
    {Starts, _} = lists:mapfoldl(fun(L, Acc) -> {Acc, Acc + L} end, 0, Lengths),
    Starts.

day_in_year(T) -> day(T) - day_from_year(year(T)).

month(T) ->
    Starts = month_starts(year(T)),
    D = day_in_year(T),
    length([S || S <- Starts, S =< D]) - 1.

date(T) ->
    Starts = month_starts(year(T)),
    day_in_year(T) - lists:nth(month(T) + 1, Starts) + 1.

weekday(T) -> floor_mod(day(T) + 4, 7).

floor_mod(A, B) -> A - floor_div(A, B) * B.

hour(T) -> floor_mod(floor_div(T, 3600000), 24).
minute(T) -> floor_mod(floor_div(T, 60000), 60).
second(T) -> floor_mod(floor_div(T, 1000), 60).
millisecond(T) -> floor_mod(T, 1000).

is_finite(N) -> is_number(N).

integer(N) -> buoy_ref_number:to_integer_or_infinity(N).

%% MakeTime.
make_time(H, M, S, Ms) ->
    case lists:all(fun is_finite/1, [H, M, S, Ms]) of
        false -> 'NaN';
        true ->
            N = buoy_ref_number,
            N:add(N:add(N:add(N:mul(integer(H), 3600000), N:mul(integer(M), 60000)), N:mul(integer(S), 1000)), integer(Ms))
    end.

%% MakeDay.
make_day(Y, M, D) ->
    case lists:all(fun is_finite/1, [Y, M, D]) of
        false -> 'NaN';
        true ->
            Year = integer(Y),
            Month = integer(M),
            Date = integer(D),
            YM = Year + floor_div(Month, 12),
            case abs(YM) > 400000 of
                true -> 'NaN';
                false ->
                    MN = floor_mod(Month, 12),
                    Day = day_from_year(YM) + lists:nth(MN + 1, month_starts(YM)),
                    buoy_ref_number:add(Day, buoy_ref_number:sub(Date, 1))
            end
    end.

%% MakeDate.
make_date(Day, Time) ->
    case is_finite(Day) andalso is_finite(Time) of
        false -> 'NaN';
        true ->
            case buoy_ref_number:add(buoy_ref_number:mul(Day, ?DAY), Time) of
                TV when is_number(TV) -> TV;
                _ -> 'NaN'
            end
    end.

%% MakeFullYear.
full_year('NaN') -> 'NaN';
full_year(Y) ->
    case integer(Y) of
        I when is_integer(I), I >= 0, I =< 99 -> 1900 + I;
        I -> I
    end.

%% TimeClip.
time_clip(T) when is_number(T), abs(T) =< ?LIMIT ->
    case integer(T) of
        Z when Z == 0 -> 0;
        I -> I
    end;
time_clip(_) -> 'NaN'.

%% LocalTime and UTC.
local(T) ->
    {Offset, _, _} = buoy_ref_tz:offset(T),
    T + Offset.

utc('NaN') -> 'NaN';
utc(L) when is_integer(L) -> buoy_ref_tz:local_to_utc(L);
utc(L) when is_float(L), abs(L) =< 2 * ?LIMIT -> buoy_ref_tz:local_to_utc(trunc(L)) + (L - trunc(L));
utc(L) -> L.

%%% Text

pad(N, Width) ->
    Digits = integer_to_list(N),
    lists:duplicate(max(0, Width - length(Digits)), $0) ++ Digits.

year_text(Y) when Y >= 0 -> pad(Y, 4);
year_text(Y) -> "-" ++ pad(-Y, 4).

month_name(T) -> lists:nth(month(T) + 1, ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]).

weekday_name(T) -> lists:nth(weekday(T) + 1, ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]).

clock(T) -> [pad(hour(T), 2), ":", pad(minute(T), 2), ":", pad(second(T), 2)].

%% toString, toDateString, and toTimeString.
date_string('NaN', _Part) -> <<"Invalid Date">>;
date_string(T, Part) ->
    L = local(T),
    Date = [weekday_name(L), " ", month_name(L), " ", pad(date(L), 2), " ", year_text(year(L))],
    Offset = (L - T) div 60000,
    Sign = case Offset < 0 of
        true -> "-";
        false -> "+"
    end,
    Zone = [" GMT", Sign, pad(abs(Offset) div 60, 2), pad(abs(Offset) rem 60, 2), " (", buoy_ref_tz:name(T), ")"],
    Time = [clock(L), Zone],
    buoy_ref_string:from_utf8(iolist_to_binary(case Part of
        full -> [Date, " ", Time];
        date -> Date;
        time -> Time
    end)).

-spec to_iso_string(integer()) -> binary().
to_iso_string(T) -> iso(T).

iso(T) ->
    Y = year(T),
    Year = if
        Y >= 0, Y =< 9999 -> pad(Y, 4);
        Y < 0 -> "-" ++ pad(-Y, 6);
        true -> "+" ++ pad(Y, 6)
    end,
    iolist_to_binary([Year, "-", pad(month(T) + 1, 2), "-", pad(date(T), 2), "T", clock(T), ".", pad(millisecond(T), 3), "Z"]).

%% The en-US forms of toLocaleString, as Node prints them.
locale('NaN', _Part) -> <<"Invalid Date">>;
locale(T, Part) ->
    L = local(T),
    %% The year of the era, as ICU writes it: 1 BC is year 0 of the calendar.
    EraYear = case year(L) of
        Y when Y =< 0 -> 1 - Y;
        Y -> Y
    end,
    Date = [integer_to_list(month(L) + 1), "/", integer_to_list(date(L)), "/", integer_to_list(EraYear)],
    H = hour(L),
    {H12, Suffix} = case H of
        0 -> {12, "AM"};
        _ when H < 12 -> {H, "AM"};
        12 -> {12, "PM"};
        _ -> {H - 12, "PM"}
    end,
    Time = [integer_to_list(H12), ":", pad(minute(L), 2), ":", pad(second(L), 2), <<" "/utf8>>, Suffix],
    buoy_ref_string:from_utf8(iolist_to_binary(case Part of
        both -> [Date, ", ", Time];
        date -> Date;
        time -> Time
    end)).

%%% Date.parse

%% The time value of a date string: the ISO format of the specification,
%% then the forms that toString and toUTCString write and the other forms
%% that V8 accepts.
-spec parse(buoy_ref_string:js_string()) -> integer() | 'NaN'.
parse(S) ->
    Text = binary_to_list(buoy_ref_string:to_utf8(S)),
    case iso_parse(Text) of
        {ok, T} -> time_clip(T);
        error ->
            case legacy_parse(Text) of
                {ok, T} -> time_clip(T);
                error -> 'NaN'
            end
    end.

iso_parse(Text) ->
    case iso_date(Text) of
        {ok, {Y, M, D}, ""} -> iso_value(Y, M, D, 0, 0, 0, 0, utc);
        {ok, {Y, M, D}, "T" ++ Rest} ->
            case iso_time(Rest) of
                {ok, {H, Mi, S, Ms}, Zone} -> iso_value(Y, M, D, H, Mi, S, Ms, Zone);
                error -> error
            end;
        _ -> error
    end.

iso_value(Y, M, D, H, Mi, S, Ms, Zone) ->
    %% V8 checks the day against 31, not the month, so 2026-02-30 is March 2.
    Valid = M >= 1 andalso M =< 12 andalso D >= 1 andalso D =< 31
        andalso (H < 24 orelse (H =:= 24 andalso Mi =:= 0 andalso S =:= 0 andalso Ms =:= 0))
        andalso Mi < 60 andalso S < 60,
    case Valid of
        false -> error;
        true ->
            Local = make_date(make_day(Y, M - 1, D), make_time(H, Mi, S, Ms)),
            case Zone of
                utc -> {ok, Local};
                local -> {ok, utc(Local)};
                {offset, Minutes} -> {ok, Local - Minutes * 60000}
            end
    end.

iso_date([Sign, A, B, C, D, E, F | Rest]) when Sign =:= $+; Sign =:= $- ->
    case digits([A, B, C, D, E, F]) of
        {ok, 0} when Sign =:= $- -> error;
        {ok, Y} -> iso_month(case Sign of $- -> -Y; $+ -> Y end, Rest);
        error -> error
    end;
iso_date([A, B, C, D | Rest]) ->
    case digits([A, B, C, D]) of
        {ok, Y} -> iso_month(Y, Rest);
        error -> error
    end;
iso_date(_) -> error.

iso_month(Y, "-" ++ [A, B | Rest]) ->
    case digits([A, B]) of
        {ok, M} ->
            case Rest of
                "-" ++ [C, D | Rest1] ->
                    case digits([C, D]) of
                        {ok, Day} -> {ok, {Y, M, Day}, Rest1};
                        error -> error
                    end;
                _ -> {ok, {Y, M, 1}, Rest}
            end;
        error -> error
    end;
iso_month(Y, Rest) -> {ok, {Y, 1, 1}, Rest}.

iso_time([A, B, $:, C, D | Rest]) ->
    case {digits([A, B]), digits([C, D])} of
        {{ok, H}, {ok, M}} ->
            {S, Ms, Rest1} = case Rest of
                [$:, E, F | R1] ->
                    case digits([E, F]) of
                        {ok, Sec} ->
                            case R1 of
                                [$. | R2] ->
                                    {Frac, R3} = lists:splitwith(fun(X) -> X >= $0 andalso X =< $9 end, R2),
                                    case Frac of
                                        [] -> {bad, 0, R1};
                                        _ -> {Sec, list_to_integer(string:left(Frac ++ "00", 3)), R3}
                                    end;
                                _ -> {Sec, 0, R1}
                            end;
                        error -> {bad, 0, R1}
                    end;
                _ -> {0, 0, Rest}
            end,
            case {S, iso_zone(Rest1)} of
                {bad, _} -> error;
                {_, error} -> error;
                {_, Zone} -> {ok, {H, M, S, Ms}, Zone}
            end;
        _ -> error
    end;
iso_time(_) -> error.

iso_zone("") -> local;
iso_zone("Z") -> utc;
iso_zone([Sign, A, B, $:, C, D]) when Sign =:= $+; Sign =:= $- ->
    case {digits([A, B]), digits([C, D])} of
        {{ok, H}, {ok, M}} when H < 24, M < 60 ->
            Minutes = H * 60 + M,
            {offset, case Sign of $+ -> Minutes; $- -> -Minutes end};
        _ -> error
    end;
iso_zone(_) -> error.

digits(Chars) ->
    case lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Chars) of
        true -> {ok, list_to_integer(Chars)};
        false -> error
    end.

%% The other forms: words for months and weekdays, numbers for the day, the
%% year, and the time, an AM or PM, and a zone of GMT, UTC, Z, or +hhmm.
%% A text in parentheses is a comment.
legacy_parse(Text) ->
    Tokens = tokens(string:lowercase(Text), []),
    try
        legacy(Tokens, #{numbers => []})
    catch
        throw:invalid -> error
    end.

tokens([], Acc) -> lists:reverse(Acc);
tokens([$( | Rest], Acc) -> tokens(skip_comment(Rest, 1), Acc);
tokens([C | Rest], Acc) when C >= $0, C =< $9 ->
    {Digits, Tail} = lists:splitwith(fun(X) -> X >= $0 andalso X =< $9 end, [C | Rest]),
    tokens(Tail, [{number, list_to_integer(Digits), length(Digits)} | Acc]);
tokens([C | Rest], Acc) when C >= $a, C =< $z ->
    {Word, Tail} = lists:splitwith(fun(X) -> X >= $a andalso X =< $z end, [C | Rest]),
    tokens(Tail, [{word, Word} | Acc]);
tokens([C | Rest], Acc) when C =:= $:; C =:= $+; C =:= $-; C =:= $/; C =:= $. ->
    tokens(Rest, [{sym, C} | Acc]);
tokens([_ | Rest], Acc) -> tokens(Rest, Acc).

skip_comment([], _) -> [];
skip_comment([$) | Rest], 1) -> Rest;
skip_comment([$) | Rest], N) -> skip_comment(Rest, N - 1);
skip_comment([$( | Rest], N) -> skip_comment(Rest, N + 1);
skip_comment([_ | Rest], N) -> skip_comment(Rest, N).

legacy([], State) -> legacy_value(State);
legacy([{number, H, _}, {sym, $:}, {number, M, _} | Rest], State) ->
    {S, Rest1} = case Rest of
        [{sym, $:}, {number, Sec, _} | R] -> {Sec, R};
        _ -> {0, Rest}
    end,
    {Ms, Rest2} = case Rest1 of
        [{sym, $.}, {number, Frac, Width} | R2] -> {Frac * pow10(3 - Width), R2};
        _ -> {0, Rest1}
    end,
    legacy(Rest2, State#{time => {H, M, S, Ms}});
legacy([{word, W} | Rest], State) when W =:= "am"; W =:= "pm" ->
    legacy(Rest, State#{meridiem => W});
legacy([{word, W} | Rest], State) when W =:= "gmt"; W =:= "utc"; W =:= "ut"; W =:= "z" ->
    case Rest of
        [{sym, Sign}, {number, N, Width} | R] when Sign =:= $+; Sign =:= $- ->
            legacy(R, State#{zone => zone_minutes(Sign, N, Width)});
        _ -> legacy(Rest, State#{zone => 0})
    end;
legacy([{sym, Sign}, {number, N, Width} | Rest], #{time := _} = State) when Sign =:= $+; Sign =:= $-, not is_map_key(zone, State) ->
    legacy(Rest, State#{zone => zone_minutes(Sign, N, Width)});
legacy([{word, W} | Rest], State) ->
    case month_number(W) of
        {ok, M} -> legacy(Rest, State#{month => M});
        error ->
            case lists:member(string:sub_string(W, 1, 3), ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]) orelse W =:= "t" of
                true -> legacy(Rest, State);
                false ->
                    case us_zone(W) of
                        {ok, Z} -> legacy(Rest, State#{zone => Z});
                        error -> throw(invalid)
                    end
            end
    end;
legacy([{number, Y, 4}, {sym, Sep}, {number, M, _}, {sym, Sep}, {number, D, _} | Rest], State) when Sep =:= $/; Sep =:= $- ->
    legacy(Rest, State#{month => M, day => D, year => Y});
legacy([{number, N, _}, {sym, $/}, {number, D, _}, {sym, $/}, {number, Y, _} | Rest], State) ->
    legacy(Rest, State#{month => N, day => D, year => Y});
legacy([{sym, $-}, {number, N, _} | Rest], #{numbers := Numbers} = State) ->
    legacy(Rest, State#{numbers => Numbers ++ [-N]});
legacy([{number, N, _} | Rest], #{numbers := Numbers} = State) ->
    legacy(Rest, State#{numbers => Numbers ++ [N]});
legacy([{sym, _} | Rest], State) -> legacy(Rest, State).

pow10(N) when N >= 0 -> trunc(math:pow(10, N));
pow10(_) -> 1.

zone_minutes(Sign, N, Width) ->
    Minutes = case Width =< 2 of
        true -> N * 60;
        false -> (N div 100) * 60 + N rem 100
    end,
    case Sign of
        $+ -> Minutes;
        $- -> -Minutes
    end.

us_zone("est") -> {ok, -300};
us_zone("edt") -> {ok, -240};
us_zone("cst") -> {ok, -360};
us_zone("cdt") -> {ok, -300};
us_zone("mst") -> {ok, -420};
us_zone("mdt") -> {ok, -360};
us_zone("pst") -> {ok, -480};
us_zone("pdt") -> {ok, -420};
us_zone(_) -> error.

month_number(W) when length(W) >= 3 ->
    Months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"],
    Prefix = string:sub_string(W, 1, 3),
    case [I || {I, M} <- lists:enumerate(1, Months), M =:= Prefix] of
        [I] -> {ok, I};
        [] -> error
    end;
month_number(_) -> error.

legacy_value(State) ->
    {Month, Day, Year} = case State of
        #{year := Y, month := M, day := D} -> {M, D, Y};
        #{month := M, numbers := [D, Y | _]} -> {M, D, Y};
        #{month := M, numbers := [D]} -> {M, D, 2001};
        _ -> throw(invalid)
    end,
    Year >= 0 orelse throw(invalid),
    FullYear = case Year of
        _ when Year >= 0, Year =< 49 -> 2000 + Year;
        _ when Year >= 50, Year =< 99 -> 1900 + Year;
        _ -> Year
    end,
    {H0, Mi, S, Ms} = maps:get(time, State, {0, 0, 0, 0}),
    H = case maps:get(meridiem, State, none) of
        "am" when H0 =:= 12 -> 0;
        "pm" when H0 < 12 -> H0 + 12;
        _ -> H0
    end,
    (Month >= 1 andalso Month =< 12 andalso Day >= 1 andalso Day =< 31 andalso H =< 24 andalso Mi < 60 andalso S < 60) orelse throw(invalid),
    Local = make_date(make_day(FullYear, Month - 1, Day), make_time(H, Mi, S, Ms)),
    case maps:get(zone, State, local) of
        local -> {ok, utc(Local)};
        Minutes -> {ok, Local - Minutes * 60000}
    end.
