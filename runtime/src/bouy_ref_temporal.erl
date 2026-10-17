%% Temporal. The implementation is temporal-polyfill (MIT, fullcalendar),
%% vendored in runtime/vendor/temporal-polyfill. crates/bouy-cli/build.rs
%% compiles it with the reference compiler into the module bouy_temporal:
%% eval code that reads the Intl.DateTimeFormat of this module and a
%% nanosecond clock from its this, and whose value is the namespace.
%%
%% The global Temporal is the intrinsic 'Temporal', whose static record is
%% {lazy, ?MODULE}: the first read of its record in a realm calls load/1
%% (bouy_heap), which runs the polyfill in that realm and puts the record
%% of the namespace under 'Temporal'. A realm that never reads Temporal
%% pays nothing.
%%
%% The Intl.DateTimeFormat here is the part that the polyfill uses, in the
%% en-US locale: the system zone, a zone of the tz database by identifier
%% (bouy_ref_tz), the wall-clock fields of an instant in a zone, and a
%% plain text form for toLocaleString. It is not a global.
-module(bouy_ref_temporal).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, load/1, to_instant/1]).

-import(bouy_ref_realm, [arg/2, record/4, ctor_record/5]).

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
    Module = bouy_temporal,
    code:ensure_loaded(Module) =:= {module, Module}
        orelse bouy_ref:type_error(<<"Temporal needs the bouy_temporal module: run the program with `bouy run`">>),
    erlang:put(Id, {object, ?OBJECT_PROTO, #{}, [], #{}, none}),
    try
        Intl = bouy_heap:object(?OBJECT_PROTO, [{<<"DateTimeFormat">>, bouy_ref_realm:constructor(?MODULE, <<"Intl.DateTimeFormat">>)}]),
        Clock = bouy_ref_realm:builtin(<<"Temporal.nowNanoseconds">>, fun(_, _) -> {'$bigint', erlang:system_time(nanosecond)} end),
        Host = bouy_heap:object(?OBJECT_PROTO, [{<<"Intl">>, Intl}, {<<"nowNanoseconds">>, Clock}]),
        {'$o', Made} = Module:'__eval__'(Host, [], #{}),
        Record = erlang:get(Made),
        erlang:put(Id, Record),
        erlang:put({?MODULE, instant}, maps:get(<<"Instant">>, element(3, Record))),
        Record
    catch
        Class:Reason:Stack ->
            erlang:erase(Id),
            erlang:raise(Class, Reason, Stack)
    end.

%% Date.prototype.toTemporalInstant of the time value T: a new instance of
%% the intrinsic Temporal.Instant.
-spec to_instant(integer()) -> term().
to_instant(T) ->
    _ = erlang:get(?NAMESPACE) =/= undefined orelse load(?NAMESPACE),
    bouy_ref:construct(erlang:get({?MODULE, instant}), [{'$bigint', T * 1000000}]).

%%% Intl.DateTimeFormat

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"Intl.DateTimeFormat">>, _This, Args) -> construct(undefined, Args).

%% The slots of a format: {TimeZone, Calendar, Shape}, where Shape names
%% the fields and styles that format/1 writes.
construct(NewTarget, Args) ->
    Options = arg(2, Args),
    Zone = case option(Options, <<"timeZone">>) of
        undefined -> bouy_ref_tz:system_id();
        Name -> time_zone(bouy_ref:to_string(Name))
    end,
    Calendar = case option(Options, <<"calendar">>) of
        undefined -> <<"gregory">>;
        C -> bouy_ref:to_string(C)
    end,
    Shape = case [K || K <- [<<"month">>, <<"day">>, <<"year">>, <<"hour">>, <<"minute">>, <<"second">>, <<"dateStyle">>, <<"timeStyle">>],
                       option(Options, K) =/= undefined] of
        [] -> [<<"month">>, <<"day">>, <<"year">>];
        Named -> Named
    end,
    Proto = case NewTarget of
        undefined -> {'$o', ?PROTO};
        _ -> bouy_ref_realm:proto_for(NewTarget, ?PROTO)
    end,
    bouy_heap:new_exotic(date_time_format, Proto, {Zone, Calendar, Shape}).

option(Options, Key) when ?IS_OBJECT(Options) -> bouy_ref:get(Options, Key);
option(_Options, _Key) -> undefined.

%% A zone: the primary identifier of a zone of the tz database, or an
%% offset zone such as "+05:30".
time_zone(Name) ->
    Text = bouy_ref_string:to_utf8(Name),
    case {fixed_offset(Text), bouy_ref_tz:named(Text)} of
        {{ok, _}, _} -> Text;
        {error, {ok, Id}} -> Id;
        {error, error} -> bouy_heap:throw_error('RangeError', bouy_ref_string:concat(<<"Invalid time zone specified: ">>, Name))
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
        error -> bouy_ref_tz:offset_in(Zone, T)
    end.

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Intl.DateTimeFormat.prototype">>, <<"resolvedOptions">>, This, _Args) ->
    {Zone, Calendar, _} = slots(This),
    bouy_heap:object(?OBJECT_PROTO, [{<<"locale">>, <<"en-US">>}, {<<"calendar">>, Calendar}, {<<"numberingSystem">>, <<"latn">>}, {<<"timeZone">>, Zone}]);
method(<<"Intl.DateTimeFormat.prototype">>, <<"formatToParts">>, This, Args) ->
    {Zone, _, _} = slots(This),
    bouy_heap:new_array([bouy_heap:object(?OBJECT_PROTO, [{<<"type">>, Type}, {<<"value">>, text(V)}]) || {Type, V} <- parts(Zone, arg(1, Args))]);
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
    ?IS_OBJECT(This) andalso bouy_heap:class_of(This) =:= date_time_format
        orelse bouy_ref:type_error(<<"Method Intl.DateTimeFormat.prototype.format called on incompatible receiver">>),
    bouy_heap:slots(This).

%% The wall-clock fields of the epoch milliseconds Value in Zone, as ICU
%% gives them in en-US: the year of the era, and the era.
parts(Zone, Value) ->
    T = case bouy_ref:to_number(Value) of
        N when is_integer(N) -> N;
        N when is_float(N) -> trunc(N);
        _ -> bouy_heap:throw_error('RangeError', <<"Invalid time value">>)
    end,
    Local = T + offset(Zone, T),
    Days = floor_div(Local, ?DAY),
    Seconds = (Local - Days * ?DAY) div 1000,
    {Year, Month, Day} = bouy_ref_tz:civil_from_days(Days),
    {Era, EraYear} = case Year > 0 of
        true -> {<<"AD">>, Year};
        false -> {<<"BC">>, 1 - Year}
    end,
    [{<<"month">>, Month}, {<<"day">>, Day}, {<<"year">>, EraYear}, {<<"era">>, Era},
     {<<"hour">>, Seconds div 3600}, {<<"minute">>, Seconds div 60 rem 60}, {<<"second">>, Seconds rem 60}].

text(V) when is_integer(V) -> integer_to_binary(V);
text(V) -> V.

floor_div(A, B) when A >= 0 -> A div B;
floor_div(A, B) -> -((-A + B - 1) div B).
