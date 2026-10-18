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

%% The time value of a date string, as V8's DateParser reads it
%% (src/date/dateparser-inl.h): the ISO format of the specification first,
%% then, from the first token that format does not take, the legacy forms
%% that browsers accept, such as "Tue Mar 01 2016 10:00:00 GMT+0100" and
%% "1997-3-8 1:1:1".
-spec parse(buoy_ref_string:js_string()) -> integer() | 'NaN'.
parse(S) ->
    Tokens = date_tokens(buoy_ref_string:code_points(S)),
    try
        {Rest, State} = es5(Tokens, #{day => [], month => none, iso => false, time => [], meridiem => none,
                                      sign => none, hour => none, minute => none, numbers => false}),
        date_value(legacy(Rest, State#{numbers := maps:get(day, State) =/= []}))
    catch
        throw:invalid -> 'NaN'
    end.

%% The tokens of DateStringTokenizer: {number, Value, Digits}, {symbol, C},
%% {word, Type, Value, Length}, space, other, and eof.
date_tokens([]) -> [eof];
date_tokens([C | _] = Text) when C >= $0, C =< $9 ->
    {Digits, Rest} = lists:splitwith(fun(X) -> X >= $0 andalso X =< $9 end, Text),
    [{number, numeral(Digits), length(Digits)} | date_tokens(Rest)];
date_tokens([C | Rest]) when C =:= $:; C =:= $-; C =:= $+; C =:= $.; C =:= $) ->
    [{symbol, C} | date_tokens(Rest)];
date_tokens([C | Rest] = Text) ->
    case buoy_ref_string:is_whitespace(C) of
        true -> [space | date_tokens(Rest)];
        false when C >= $A ->
            {Word, Tail} = lists:splitwith(fun(X) -> X >= $A andalso not buoy_ref_string:is_whitespace(X) end, Text),
            [date_word(Word) | date_tokens(Tail)];
        false when C =:= $( -> [other | date_tokens(skip_parentheses(Rest, 1))];
        false -> [other | date_tokens(Rest)]
    end.

%% A numeral keeps its first nine significant digits.
numeral(Digits) ->
    case lists:sublist(lists:dropwhile(fun(X) -> X =:= $0 end, Digits), 9) of
        [] -> 0;
        Significant -> list_to_integer(Significant)
    end.

skip_parentheses([], _) -> [];
skip_parentheses([0 | _] = Rest, _) -> Rest;
skip_parentheses([$) | Rest], 1) -> Rest;
skip_parentheses([$) | Rest], N) -> skip_parentheses(Rest, N - 1);
skip_parentheses([$( | Rest], N) -> skip_parentheses(Rest, N + 1);
skip_parentheses([_ | Rest], N) -> skip_parentheses(Rest, N).

%% A word is a keyword by its first three letters; only a month name may be
%% longer than its keyword.
date_word(Word) ->
    Prefix = [C bor 16#20 || C <- lists:sublist(Word, 3)],
    Length = length(Word),
    case lists:keyfind(Prefix, 1, date_keywords()) of
        {_, month, Month} -> {word, month, Month, Length};
        {_, Type, Value} when Length =< 3 -> {word, Type, Value, Length};
        _ -> {word, none, 0, Length}
    end.

date_keywords() ->
    [{Name, month, I} || {I, Name} <- lists:enumerate(1, ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])]
        ++ [{"am", meridiem, 0}, {"pm", meridiem, 12}, {"ut", zone, 0}, {"utc", zone, 0}, {"z", zone, 0}, {"gmt", zone, 0},
            {"cdt", zone, -5}, {"cst", zone, -6}, {"edt", zone, -4}, {"est", zone, -5}, {"mdt", zone, -6},
            {"mst", zone, -7}, {"pdt", zone, -7}, {"pst", zone, -8}, {"t", separator, 0}].

%% ParseES5DateTime: [+-yy]yyyy[-MM[-DD]][THH:mm[:ss[.sss]][Z|+-hh:mm]].
%% Returns the tokens from the first one the format does not take.
es5([{symbol, Sign} = SignToken | Rest], State) when Sign =:= $+; Sign =:= $- ->
    case Rest of
        [{number, 0, 6} | Rest1] when Sign =:= $- -> {[SignToken | Rest1], State};
        [{number, Y, 6} | Rest1] -> es5_month(Rest1, add_day(sign(Sign) * Y, State));
        _ -> {[SignToken | Rest], State}
    end;
es5([{number, Y, 4} | Rest], State) -> es5_month(Rest, add_day(Y, State));
es5(Tokens, State) -> {Tokens, State}.

es5_month([{symbol, $-} | Rest], State) ->
    case Rest of
        [{number, M, 2} | [{symbol, $-} | Rest2]] when M >= 1, M =< 12 ->
            case Rest2 of
                [{number, D, 2} | Rest3] when D >= 1, D =< 31 -> es5_time(Rest3, add_day(D, add_day(M, State)));
                _ -> {Rest2, add_day(M, State)}
            end;
        [{number, M, 2} | Rest1] when M >= 1, M =< 12 -> es5_time(Rest1, add_day(M, State));
        _ -> {Rest, State}
    end;
es5_month(Rest, State) -> es5_time(Rest, State).

es5_time([{word, separator, _, _} | Rest], State) ->
    {Rest1, State1} = es5_clock(Rest, State),
    es5_end(es5_zone(Rest1, State1));
es5_time([eof], State) -> es5_end({[eof], State});
es5_time(Rest, State) -> {Rest, State}.

es5_clock([{number, H, 2}, {symbol, $:}, {number, Mi, 2} | Rest], State) when H =< 24, Mi =< 59, H < 24 orelse Mi =:= 0 ->
    Clock = State#{time := [H, Mi]},
    case Rest of
        [{symbol, $:}, {number, S, 2} | Rest1] when S =< 59, H < 24 orelse S =:= 0 ->
            case Rest1 of
                [{symbol, $.}, {number, F, Digits} | Rest2] when H < 24 orelse F =:= 0 ->
                    {Rest2, Clock#{time := [H, Mi, S, milliseconds(F, Digits)]}};
                [{symbol, $.} | _] -> throw(invalid);
                _ -> {Rest1, Clock#{time := [H, Mi, S]}}
            end;
        [{symbol, $:} | _] -> throw(invalid);
        _ -> {Rest, Clock}
    end;
es5_clock(_, _) -> throw(invalid).

es5_zone([{word, zone, 0, 1} | Rest], State) -> {Rest, set_zone(0, State)};
es5_zone([{symbol, Sign} | Rest], State) when Sign =:= $+; Sign =:= $- ->
    Signed = State#{sign := sign(Sign)},
    case Rest of
        [{number, HM, 4} | Rest1] when HM div 100 =< 23, HM rem 100 =< 59 ->
            {Rest1, Signed#{hour := HM div 100, minute := HM rem 100}};
        [{number, H, 2}, {symbol, $:}, {number, M, 2} | Rest1] when H =< 23, M =< 59 ->
            {Rest1, Signed#{hour := H, minute := M}};
        _ -> throw(invalid)
    end;
es5_zone(Rest, State) -> {Rest, State}.

%% A date-only form is UTC, and a date-time form without a zone is local.
es5_end({[eof], #{time := Time, hour := Hour} = State}) ->
    Zoned = case Time =:= [] andalso Hour =:= none of
        true -> set_zone(0, State);
        false -> State
    end,
    {[eof], Zoned#{iso := true}};
es5_end(_) -> throw(invalid).

%% ReadMilliseconds: the first three significant digits of the fraction.
milliseconds(F, 1) -> F * 100;
milliseconds(F, 2) -> F * 10;
milliseconds(F, Digits) when Digits =< 3 -> F;
milliseconds(F, Digits) -> F div pow10(min(Digits, 9) - 3).

pow10(N) -> trunc(math:pow(10, N)).

sign($+) -> 1;
sign($-) -> -1.

%% TimeZoneComposer::Set.
set_zone(Hours, State) when Hours < 0 -> State#{sign := -1, hour := -Hours, minute := 0};
set_zone(Hours, State) -> State#{sign := 1, hour := Hours, minute := 0}.

add_day(N, #{day := Day} = State) when length(Day) < 3 -> State#{day := Day ++ [N]};
add_day(_, _) -> throw(invalid).

add_time(N, #{time := Time} = State) when length(Time) < 4 -> State#{time := Time ++ [N]};
add_time(_, _) -> throw(invalid).

%% TimeComposer::AddFinal: the rest of the time is zero.
add_final(N, State) ->
    #{time := Time} = Filled = add_time(N, State),
    Filled#{time := Time ++ lists:duplicate(4 - length(Time), 0)}.

time_expects(N, #{time := Time}) ->
    case length(Time) of
        1 -> N =< 59;
        2 -> N =< 59;
        3 -> N =< 999;
        _ -> false
    end.

zone_expects(N, #{hour := Hour, minute := Minute}) -> Hour =/= none andalso Minute =:= none andalso N =< 59.

%% The legacy forms: numbers with ':' and '.' make the time, a sign after a
%% time or UTC makes the offset, and other numbers make the day.
legacy([eof | _], State) -> State;
legacy([{number, N, _} | Rest], State0) ->
    State = State0#{numbers := true},
    case Rest of
        [{symbol, $:}, {symbol, $:} | Rest1] ->
            maps:get(time, State) =:= [] orelse throw(invalid),
            legacy(Rest1, add_time(0, add_time(N, State)));
        [{symbol, $:}, {symbol, $.} | Rest1] -> legacy(Rest1, add_time(N, State));
        [{symbol, $:} | Rest1] -> legacy(Rest1, add_time(N, State));
        [{symbol, $.} | Rest1] ->
            case time_expects(N, State) of
                true ->
                    case Rest1 of
                        [{number, F, Digits} | Rest2] -> legacy(Rest2, add_final(milliseconds(F, Digits), add_time(N, State)));
                        _ -> throw(invalid)
                    end;
                false -> legacy_number(N, Rest1, State)
            end;
        _ -> legacy_number(N, Rest, State)
    end;
legacy([{word, meridiem, Offset, _} | Rest], #{time := [_ | _]} = State) ->
    legacy(Rest, State#{meridiem := Offset});
legacy([{word, month, Month, _} | Rest], State) ->
    legacy(skip_dash(Rest), State#{month := Month});
legacy([{word, zone, Hours, _} | Rest], #{numbers := true} = State) ->
    legacy(Rest, set_zone(Hours, State));
legacy([{word, _, _, _} | Rest], #{numbers := Numbers} = State) ->
    %% Other words may only come before the first number, apart from it.
    (Numbers orelse is_tuple(hd(Rest)) andalso element(1, hd(Rest)) =:= number) andalso throw(invalid),
    legacy(Rest, State);
legacy([{symbol, Sign} | Rest], #{hour := Hour, minute := Minute, time := Time} = State)
  when (Sign =:= $+ orelse Sign =:= $-) andalso ((Hour =:= 0 andalso Minute =:= 0) orelse Time =/= []) ->
    {N, Digits, Rest1} = case Rest of
        [{number, N0, D0} | R] -> {N0, D0, R};
        _ -> {0, 0, Rest}
    end,
    Signed = State#{sign := sign(Sign), numbers := true},
    Offset = case {Rest1, Digits} of
        {[{symbol, $:} | _], _} -> #{hour => N, minute => none};
        {_, D} when D =:= 1; D =:= 2 -> #{hour => N, minute => 0};
        {_, D} when D =:= 3; D =:= 4 -> #{hour => N div 100, minute => N rem 100};
        _ -> throw(invalid)
    end,
    legacy(Rest1, maps:merge(Signed, Offset));
legacy([{symbol, C} | _], #{numbers := true}) when C =:= $+; C =:= $-; C =:= $) -> throw(invalid);
legacy([_ | Rest], State) -> legacy(Rest, State).

legacy_number(N, Rest, State) ->
    case {zone_expects(N, State), time_expects(N, State)} of
        {true, _} -> legacy(Rest, State#{minute := N});
        {false, true} ->
            case hd(Rest) of
                T when T =:= eof; T =:= space; T =:= {word, zone, 0, 1}; T =:= {symbol, $+}; T =:= {symbol, $-} ->
                    legacy(Rest, add_final(N, State));
                _ -> throw(invalid)
            end;
        {false, false} -> legacy(skip_dash(Rest), add_day(N, State))
    end.

skip_dash([{symbol, $-} | Rest]) -> Rest;
skip_dash(Rest) -> Rest.

%% DayComposer::Write, TimeComposer::Write, and TimeZoneComposer::Write, then
%% the time value as V8's ParseDateTimeString makes it.
date_value(#{day := []}) -> throw(invalid);
date_value(#{day := Day0, month := Named, iso := Iso, time := Time0, meridiem := Meridiem} = State) ->
    [A, B, C] = Day0 ++ lists:duplicate(3 - length(Day0), 1),
    {Year0, Month, Date} = case Named of
        none when Iso; not (A >= 1 andalso A =< 31) -> {A, B, C};
        none -> {C, A, B};
        _ when not (A >= 1 andalso A =< 31) -> {A, Named, B};
        _ -> {B, Named, A}
    end,
    Year = case Iso of
        false when Year0 >= 0, Year0 =< 49 -> Year0 + 2000;
        false when Year0 >= 50, Year0 =< 99 -> Year0 + 1900;
        _ -> Year0
    end,
    (Month >= 1 andalso Month =< 12 andalso Date >= 1 andalso Date =< 31 andalso abs(Year) < 1 bsl 30) orelse throw(invalid),
    [H0, Mi, S, Ms] = Time0 ++ lists:duplicate(4 - length(Time0), 0),
    H = case Meridiem of
        none -> H0;
        _ when H0 =< 12 -> H0 rem 12 + Meridiem;
        _ -> throw(invalid)
    end,
    ((H =< 23 andalso Mi =< 59 andalso S =< 59 andalso Ms =< 999) orelse {H, Mi, S, Ms} =:= {24, 0, 0, 0}) orelse throw(invalid),
    Local = make_date(make_day(Year, Month - 1, Date), make_time(H, Mi, S, Ms)),
    case State of
        _ when Local =:= 'NaN' -> 'NaN';
        #{sign := none} when abs(Local) > ?LIMIT + 864000000 -> 'NaN';
        #{sign := none} -> time_clip(utc(Local));
        #{sign := Sign, hour := Hour, minute := Minute} ->
            Seconds = zero_if_none(Hour) * 3600 + zero_if_none(Minute) * 60,
            Seconds =< 16#3FFFFFFF orelse throw(invalid),
            time_clip(Local - Sign * Seconds * 1000)
    end.

zero_if_none(none) -> 0;
zero_if_none(N) -> N.
