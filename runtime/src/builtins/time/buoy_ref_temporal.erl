%% Temporal. The implementation is temporal-polyfill (MIT, fullcalendar),
%% vendored in runtime/vendor/temporal-polyfill. crates/buoy-cli/build.rs
%% compiles it with the reference compiler into the module buoy_temporal:
%% eval code that reads the Intl.DateTimeFormat of this module and a
%% nanosecond clock from its this, and whose value is the namespace.
%%
%% The global Temporal is the intrinsic 'Temporal', whose static record is
%% {lazy, ?MODULE}: the first read of its record in a realm calls load/1
%% (buoy_heap), which runs the polyfill in that realm and puts the record
%% of the namespace under 'Temporal'. A realm that never reads Temporal
%% pays nothing.
%%
%% The Intl.DateTimeFormat here is the part that the polyfill uses, in the
%% en-US locale: the system zone, a zone of the tz database by identifier
%% (buoy_ref_tz), the wall-clock fields of an instant in a zone, and a
%% plain text form for toLocaleString. It is not a global.
-module(buoy_ref_temporal).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, load/1, to_instant/1]).
-export([slots_of/1, duration_slots/1]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).

-define(NAMESPACE, 'Temporal').
-define(PROTO, 'Intl.DateTimeFormat.prototype').
-define(DAY, 86400000).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{?NAMESPACE, {lazy, ?MODULE}},
     {?PROTO, record(object, ?OBJECT_PROTO, ?METHODS(<<"Intl.DateTimeFormat.prototype">>, [{<<"resolvedOptions">>, 0}, {<<"formatToParts">>, 1}, {<<"format">>, 1}]), none)},
     {{builtin, <<"Intl.DateTimeFormat">>}, ctor_record(<<"DateTimeFormat">>, 0, {'$o', ?PROTO}, [], fun construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Temporal">>, {'$o', ?NAMESPACE}}].

%%% The namespace

%% Runs the polyfill in this realm and returns the record of the namespace,
%% which it also puts under Id. While the polyfill runs, Temporal reads as
%% an empty object instead of loading again.
-spec load(atom()) -> tuple().
load(?NAMESPACE = Id) ->
    Module = buoy_temporal,
    code:ensure_loaded(Module) =:= {module, Module}
        orelse buoy_ref:type_error(<<"Temporal needs the buoy_temporal module: run the program with `buoy run`">>),
    erlang:put(Id, {object, ?OBJECT_PROTO, #{}, [], #{}, none}),
    try
        Intl = buoy_heap:object(?OBJECT_PROTO, [{<<"DateTimeFormat">>, buoy_ref_realm:constructor(?MODULE, <<"Intl.DateTimeFormat">>)}]),
        Clock = buoy_ref_realm:builtin(<<"Temporal.nowNanoseconds">>, fun(_, _) -> {'$bigint', erlang:system_time(nanosecond)} end),
        Divide = buoy_ref_realm:builtin(<<"Temporal.exactDivide">>, fun(_, [{'$bigint', N}, {'$bigint', D} | _]) -> exact_divide(N, D) end),
        Host = buoy_heap:object(?OBJECT_PROTO, [{<<"Intl">>, Intl}, {<<"nowNanoseconds">>, Clock}, {<<"exactDivide">>, Divide}]),
        %% The top level of the polyfill runs no program code, so the builtins that
        %% it calls, such as the Set constructor, iterate arrays as a native
        %% Temporal would, whatever a program wrote to the array iterator.
        {'$o', Made} = buoy_ref_iterator:internally(fun() -> Module:'__eval__'(Host, [], #{}) end),
        Record = erlang:get(Made),
        erlang:put(Id, Record),
        erlang:put({?MODULE, instant}, maps:get(<<"Instant">>, element(3, Record))),
        erlang:put({?MODULE, readers, buoy_heap:realm()},
                   {buoy_ref:get(Host, <<"slotsOf">>), buoy_ref:get(Host, <<"toDurationSlots">>)}),
        locale_methods(maps:get(<<"Duration">>, element(3, Record))),
        Record
    catch
        Class:Reason:Stack ->
            erlang:erase(Id),
            erlang:raise(Class, Reason, Stack)
    end.

%% The Number nearest to the exact quotient N / D of two integers, ties to
%% even, as Temporal converts its exact totals (ECMA-262 6.1.6.1, the Number
%% value for a mathematical value). The quotient keeps at least 64 bits and a
%% sticky bit for the rest, so one rounding to 53 bits is exact.
-spec exact_divide(integer(), integer()) -> number().
exact_divide(_N, 0) -> 'NaN';
exact_divide(N, D) when D < 0 -> exact_divide(-N, -D);
exact_divide(0, _D) -> 0;
exact_divide(N, D) ->
    A = abs(N),
    Shift = max(0, 64 - (bits(A) - bits(D))),
    Scaled = A bsl Shift,
    Q = Scaled div D,
    Sticky = Scaled rem D =/= 0,
    Drop = bits(Q) - 53,
    Mantissa0 = Q bsr Drop,
    Rest = Q band ((1 bsl Drop) - 1),
    Half = 1 bsl (Drop - 1),
    Up = Rest > Half orelse (Rest =:= Half andalso (Sticky orelse Mantissa0 band 1 =:= 1)),
    {Mantissa, Exponent} = case Up of
        false -> {Mantissa0, Drop - Shift};
        true when Mantissa0 + 1 =:= 1 bsl 53 -> {(Mantissa0 + 1) bsr 1, Drop - Shift + 1};
        true -> {Mantissa0 + 1, Drop - Shift}
    end,
    Biased = Exponent + 52 + 1023,
    Sign = case N < 0 of true -> 1; false -> 0 end,
    case Biased >= 2047 of
        true when Sign =:= 1 -> '-Infinity';
        true -> 'Infinity';
        false ->
            <<F:64/float>> = <<Sign:1, Biased:11, (Mantissa band ((1 bsl 52) - 1)):52>>,
            buoy_ref_number:canonical(F)
    end.

bits(X) -> bits(X, 0).
bits(0, Count) -> Count;
bits(X, Count) -> bits(X bsr 1, Count + 1).

%% Date.prototype.toTemporalInstant of the time value T: a new instance of
%% the intrinsic Temporal.Instant.
-spec to_instant(integer()) -> term().
to_instant(T) ->
    _ = erlang:get(?NAMESPACE) =/= undefined orelse load(?NAMESPACE),
    buoy_ref:construct(erlang:get({?MODULE, instant}), [{'$bigint', T * 1000000}]).

%% Temporal.Duration.prototype.toLocaleString formats with Intl.DurationFormat,
%% which the polyfill does not have.
locale_methods(Duration) ->
    Proto = buoy_ref:get(Duration, <<"prototype">>),
    Method = buoy_ref_realm:builtin(<<"Temporal.Duration.prototype.toLocaleString">>, <<"toLocaleString">>, 0,
                                    fun(This, Args) ->
                                            case slots_of(This) of
                                                {<<"Duration">>, _} -> ok;
                                                _ -> buoy_ref:type_error(<<"Temporal.Duration.prototype.toLocaleString called on incompatible receiver">>)
                                            end,
                                            buoy_ref_intl_duration_format:format_with(arg(1, Args), arg(2, Args), This)
                                    end),
    buoy_heap:define(Proto, <<"toLocaleString">>, #{value => Method, writable => true, enumerable => false, configurable => true}).

%% {Type, Slots} of a Temporal object of this realm, such as {<<"Duration">>,
%% Slots} with the plain object of its fields, or undefined, without its
%% getters.
-spec slots_of(term()) -> {binary(), term()} | undefined.
slots_of(Value) ->
    {SlotsOf, _} = readers(),
    case buoy_ref:call(SlotsOf, undefined, [Value]) of
        undefined -> undefined;
        Pair -> {buoy_ref:get(Pair, 0), buoy_ref:get(Pair, 1)}
    end.

%% The fields of the Temporal.Duration that a string or a duration-like
%% object gives, as ToTemporalDuration reads them.
-spec duration_slots(term()) -> term().
duration_slots(Value) ->
    {_, ToDuration} = readers(),
    buoy_ref:call(ToDuration, undefined, [Value]).

readers() ->
    Key = {?MODULE, readers, buoy_heap:realm()},
    case erlang:get(Key) of
        undefined ->
            _ = buoy_ref:get(buoy_heap:intrinsic(?NAMESPACE), <<"Duration">>),
            erlang:get(Key);
        Readers -> Readers
    end.

%%% Intl.DateTimeFormat

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"Intl.DateTimeFormat">>, _This, Args) -> construct(undefined, Args).

%% The slots of a format: {TimeZone, Calendar, Shape}, where Shape names
%% the fields and styles that format/1 writes.
construct(NewTarget, Args) ->
    Options = arg(2, Args),
    Zone = case option(Options, <<"timeZone">>) of
        undefined -> buoy_ref_tz:system_id();
        Name -> time_zone(buoy_ref:to_string(Name))
    end,
    Calendar = case option(Options, <<"calendar">>) of
        undefined -> <<"gregory">>;
        C -> buoy_ref:to_string(C)
    end,
    Shape = case [K || K <- [<<"month">>, <<"day">>, <<"year">>, <<"hour">>, <<"minute">>, <<"second">>, <<"dateStyle">>, <<"timeStyle">>],
                       option(Options, K) =/= undefined] of
        [] -> [<<"month">>, <<"day">>, <<"year">>];
        Named -> Named
    end,
    Proto = case NewTarget of
        undefined -> {'$o', ?PROTO};
        _ -> buoy_ref_realm:proto_for(NewTarget, ?PROTO)
    end,
    buoy_heap:new_exotic(date_time_format, Proto, {Zone, Calendar, Shape}).

option(Options, Key) when ?IS_OBJECT(Options) -> buoy_ref:get(Options, Key);
option(_Options, _Key) -> undefined.

%% A zone: the primary identifier of a zone of the tz database, or an
%% offset zone such as "+05:30".
time_zone(Name) ->
    Text = buoy_ref_string:to_utf8(Name),
    case {fixed_offset(Text), buoy_ref_tz:named(Text)} of
        {{ok, _}, _} -> Text;
        {error, {ok, Id}} -> Id;
        {error, error} -> buoy_heap:throw_error('RangeError', buoy_ref_string:concat(<<"Invalid time zone specified: ">>, Name))
    end.

fixed_offset(<<Sign, H1, H2, $:, M1, M2>>) when Sign =:= $+; Sign =:= $- ->
    case [D - $0 || D <- [H1, H2, M1, M2], D >= $0, D =< $9] of
        [A, B, C, D] when A * 10 + B < 24, C < 6 ->
            Ms = ((A * 10 + B) * 60 + C * 10 + D) * 60000,
            {ok, case Sign of $+ -> Ms; $- -> -Ms end};
        _ -> error
    end;
fixed_offset(_) -> error.

offset(Zone, T) ->
    case fixed_offset(Zone) of
        {ok, Ms} -> Ms;
        error -> buoy_ref_tz:offset_in(Zone, T)
    end.

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Intl.DateTimeFormat.prototype">>, <<"resolvedOptions">>, This, _Args) ->
    {Zone, Calendar, _} = slots(This),
    buoy_heap:object(?OBJECT_PROTO, [{<<"locale">>, <<"en-US">>}, {<<"calendar">>, Calendar}, {<<"numberingSystem">>, <<"latn">>}, {<<"timeZone">>, Zone}]);
method(<<"Intl.DateTimeFormat.prototype">>, <<"formatToParts">>, This, Args) ->
    {Zone, Calendar, _} = slots(This),
    buoy_heap:new_array([buoy_heap:object(?OBJECT_PROTO, [{<<"type">>, Type}, {<<"value">>, text(V)}])
                         || {Type, V} <- calendar_parts(Calendar, parts(Zone, arg(1, Args)))]);
method(<<"Intl.DateTimeFormat.prototype">>, <<"format">>, This, Args) ->
    {Zone, _, Shape} = slots(This),
    [{_, M}, {_, D}, {_, Y}, {_, Era}, {_, H}, {_, Min}, {_, S}] = parts(Zone, arg(1, Args)),
    Has = fun(Keys) -> lists:any(fun(K) -> lists:member(K, Shape) end, Keys) end,
    %% shortcut: the numeric en-US form of the fields; a style prints all of
    %% its fields, and the widths of the options are ignored. A real Intl
    %% replaces this.
    Date = lists:join($/, [integer_to_list(V) || {K, V} <- [{<<"month">>, M}, {<<"day">>, D}, {<<"year">>, Y}], Has([K, <<"dateStyle">>])])
        ++ [[$\s, Era] || Era =:= <<"BC">>, Has([<<"year">>, <<"dateStyle">>])],
    Seconds = [io_lib:format(":~2..0b", [S]) || Has([<<"second">>, <<"timeStyle">>])],
    Time = [io_lib:format("~b:~2..0b~ts ~ts", [(H + 11) rem 12 + 1, Min, Seconds, element(H div 12 + 1, {"AM", "PM"})])
            || Has([<<"hour">>, <<"minute">>, <<"second">>, <<"timeStyle">>])],
    iolist_to_binary(lists:join(", ", [Part || Part <- [Date | Time], Part =/= []])).

slots(This) ->
    ?IS_OBJECT(This) andalso buoy_heap:class_of(This) =:= date_time_format
        orelse buoy_ref:type_error(<<"Method Intl.DateTimeFormat.prototype.format called on incompatible receiver">>),
    buoy_heap:slots(This).

%% The wall-clock fields of the epoch milliseconds Value in Zone, as ICU
%% gives them in en-US: the year of the era, and the era.
parts(Zone, Value) ->
    T = case buoy_ref:to_number(Value) of
        N when is_integer(N) -> N;
        N when is_float(N) -> trunc(N);
        _ -> buoy_heap:throw_error('RangeError', <<"Invalid time value">>)
    end,
    Local = T + offset(Zone, T),
    Days = floor_div(Local, ?DAY),
    Seconds = (Local - Days * ?DAY) div 1000,
    {Year, Month, Day} = buoy_ref_tz:civil_from_days(Days),
    {Era, EraYear} = case Year > 0 of
        true -> {<<"AD">>, Year};
        false -> {<<"BC">>, 1 - Year}
    end,
    [{<<"month">>, Month}, {<<"day">>, Day}, {<<"year">>, EraYear}, {<<"era">>, Era},
     {<<"hour">>, Seconds div 3600}, {<<"minute">>, Seconds div 60 rem 60}, {<<"second">>, Seconds rem 60}].

%% The date fields in a calendar other than the Gregorian one, from ICU4X
%% (buoy_native:intl_calendar_date/2), as ICU's en formats them: the related
%% ISO year of a Chinese or Korean year as relatedYear, and the month as its
%% number in the month code, with "bis" after a leap month.
calendar_parts(Calendar, Parts) when Calendar =:= <<"gregory">>; Calendar =:= <<"iso8601">> ->
    Parts;
calendar_parts(Calendar, [{<<"month">>, M}, {<<"day">>, D}, {<<"year">>, EraYear}, {<<"era">>, Era} | Time]) ->
    Year = case Era of
        <<"AD">> -> EraYear;
        <<"BC">> -> 1 - EraYear
    end,
    case buoy_native:intl_calendar_date(Calendar, buoy_ref_tz:days_from_civil(Year, M, D)) of
        nil ->
            buoy_heap:throw_error('RangeError', buoy_ref_string:concat(<<"Invalid calendar : ">>, Calendar));
        {CalendarYear, _Ordinal, Number, Leap, Day} ->
            Month = iolist_to_binary(io_lib:format("M~2..0b~s", [Number, case Leap of true -> "bis"; false -> "" end])),
            Year1 = case lists:member(Calendar, [<<"chinese">>, <<"dangi">>]) of
                true -> [{<<"relatedYear">>, CalendarYear}];
                false -> [{<<"year">>, CalendarYear}]
            end,
            [{<<"month">>, Month}, {<<"day">>, Day} | Year1] ++ Time
    end.

text(V) when is_integer(V) -> integer_to_binary(V);
text(V) -> V.

floor_div(A, B) when A >= 0 -> A div B;
floor_div(A, B) -> -((-A + B - 1) div B).
