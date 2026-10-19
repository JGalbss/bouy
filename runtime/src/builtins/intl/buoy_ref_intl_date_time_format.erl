%% Intl.DateTimeFormat (ECMA-402 section 11): an object of the class
%% intl_date_time_format whose slots hold the resolved options and the CLDR
%% pattern of its fields. The pattern comes from the options as V8 makes it:
%% the styles of the locale, or the best pattern for the skeleton of the
%% components (buoy_ref_intl_date_skeleton), with the hour cycle in place.
%% Formatting writes the fields of the pattern (buoy_ref_intl_date_fields)
%% for the wall-clock time of the time zone, and turns the narrow and thin
%% spaces of CLDR into spaces, as V8 does.
-module(buoy_ref_intl_date_time_format).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, constructor/0]).
-export([to_locale_string/4]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).
-import(buoy_ref_intl, [get_option/5, range_error/1]).

-define(PROTO, 'Intl.DateTimeFormat.prototype').
-define(LEGACY, <<"IntlLegacyConstructedSymbol">>).
-define(DAY, 86400000).
-define(MAX_TIME, 8640000000000000).
%% Table 16 of ECMA-402: {Property, Values, {Value, Skeleton}}, in order.
-define(COMPONENTS,
        [{<<"weekday">>, [{<<"narrow">>, "EEEEE"}, {<<"short">>, "EEE"}, {<<"long">>, "EEEE"}]},
         {<<"era">>, [{<<"narrow">>, "GGGGG"}, {<<"short">>, "GGG"}, {<<"long">>, "GGGG"}]},
         {<<"year">>, [{<<"2-digit">>, "yy"}, {<<"numeric">>, "y"}]},
         {<<"month">>, [{<<"2-digit">>, "MM"}, {<<"numeric">>, "M"}, {<<"narrow">>, "MMMMM"}, {<<"short">>, "MMM"}, {<<"long">>, "MMMM"}]},
         {<<"day">>, [{<<"2-digit">>, "dd"}, {<<"numeric">>, "d"}]},
         {<<"dayPeriod">>, [{<<"narrow">>, "BBBBB"}, {<<"short">>, "B"}, {<<"long">>, "BBBB"}]},
         {<<"hour">>, [{<<"2-digit">>, hour2}, {<<"numeric">>, hour1}]},
         {<<"minute">>, [{<<"2-digit">>, "mm"}, {<<"numeric">>, "m"}]},
         {<<"second">>, [{<<"2-digit">>, "ss"}, {<<"numeric">>, "s"}]},
         {<<"fractionalSecondDigits">>, []},
         {<<"timeZoneName">>, [{<<"short">>, "z"}, {<<"long">>, "zzzz"}, {<<"shortOffset">>, "O"}, {<<"longOffset">>, "OOOO"},
                               {<<"shortGeneric">>, "v"}, {<<"longGeneric">>, "vvvv"}]}]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Format = {'$accessor', buoy_ref_realm:builtin(<<"get Intl.DateTimeFormat.prototype.format">>, <<"get format">>, 0,
                                                   fun(This, _) -> bound_format(This) end), undefined},
    [{?PROTO, record(object, ?OBJECT_PROTO,
                     ?METHODS(<<"Intl.DateTimeFormat.prototype">>,
                              [{<<"formatToParts">>, 1}, {<<"formatRange">>, 2}, {<<"formatRangeToParts">>, 2},
                               {<<"resolvedOptions">>, 0}])
                     ++ [{<<"format">>, Format, 4}, {<<"constructor">>, constructor()},
                         {?SYM(toStringTag), <<"Intl.DateTimeFormat">>, 4}],
                     none)},
     {{builtin, <<"Intl.DateTimeFormat">>}, ctor_record(<<"DateTimeFormat">>, 0, {'$o', ?PROTO},
                                                        ?METHODS(<<"Intl.DateTimeFormat">>, [{<<"supportedLocalesOf">>, 1}]),
                                                        fun(NewTarget, Args) -> create(NewTarget, arg(1, Args), arg(2, Args), any, date) end)}].

-spec globals() -> [{binary(), term()}].
globals() -> [].

-spec constructor() -> term().
constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Intl.DateTimeFormat">>).

%% Intl.DateTimeFormat called as a function: ChainDateTimeFormat of the
%% normative optional constructor mode, as V8 does.
-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(_Name, This, Args) ->
    Constructor = buoy_ref_realm:current(constructor()),
    DTF = create(Constructor, arg(1, Args), arg(2, Args), any, date),
    case ?IS_OBJECT(This) andalso buoy_ref_function:ordinary_has_instance(Constructor, This) of
        true ->
            buoy_heap:define(This, fallback_symbol(), #{value => DTF, writable => false, enumerable => false, configurable => false}),
            This;
        false -> DTF
    end.

fallback_symbol() -> {'$sym', {intl_fallback, buoy_heap:realm()}, ?LEGACY}.

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Intl.DateTimeFormat">>, <<"supportedLocalesOf">>, _This, Args) ->
    buoy_ref_intl:filter_locales(buoy_ref_intl_data:available_locales(),
                                 buoy_ref_intl:canonicalize_locale_list(arg(1, Args)), arg(2, Args));
method(<<"Intl.DateTimeFormat.prototype">>, <<"resolvedOptions">>, This, _Args) ->
    resolved_options(buoy_heap:slots(unwrap(This, <<"resolvedOptions">>)));
method(<<"Intl.DateTimeFormat.prototype">>, <<"formatToParts">>, This, Args) ->
    DTF = slots_of(This, <<"formatToParts">>),
    Parts = format_parts(buoy_heap:slots(DTF), date_value(arg(1, Args))),
    buoy_heap:new_array([buoy_heap:object(?OBJECT_PROTO, [{<<"type">>, atom_to_binary(T)}, {<<"value">>, text([P])}])
                         || {T, _} = P <- Parts]);
method(<<"Intl.DateTimeFormat.prototype">>, Name, This, Args) when Name =:= <<"formatRange">>; Name =:= <<"formatRangeToParts">> ->
    DTF = slots_of(This, Name),
    (arg(1, Args) =:= undefined orelse arg(2, Args) =:= undefined) andalso buoy_ref:type_error(<<"Invalid time value">>),
    X = buoy_ref:to_number(arg(1, Args)),
    Y = buoy_ref:to_number(arg(2, Args)),
    Parts = range_parts(buoy_heap:slots(DTF), X, Y),
    case Name of
        <<"formatRange">> -> text(Parts);
        _ ->
            buoy_heap:new_array([buoy_heap:object(?OBJECT_PROTO, [{<<"type">>, atom_to_binary(T)}, {<<"value">>, text([{T, V}])},
                                                                  {<<"source">>, atom_to_binary(S)}])
                                 || {T, V, S} <- Parts])
    end.

%% The parts as a string.
text(Parts) -> buoy_ref_string:from_code_points(lists:append([element(2, P) || P <- Parts])).

%% UnwrapDateTimeFormat.
unwrap(This, Name) ->
    ?IS_OBJECT(This) orelse incompatible(Name),
    case buoy_heap:class_of(This) of
        intl_date_time_format -> This;
        _ ->
            Constructor = buoy_ref_realm:current(constructor()),
            case buoy_ref_function:ordinary_has_instance(Constructor, This) of
                true ->
                    DTF = buoy_ref:get(This, fallback_symbol()),
                    (?IS_OBJECT(DTF) andalso buoy_heap:class_of(DTF) =:= intl_date_time_format) orelse incompatible(Name),
                    DTF;
                false -> incompatible(Name)
            end
    end.

slots_of(This, Name) ->
    (?IS_OBJECT(This) andalso buoy_heap:class_of(This) =:= intl_date_time_format) orelse incompatible(Name),
    This.

-spec incompatible(binary()) -> no_return().
incompatible(Name) ->
    buoy_ref:type_error(buoy_ref_string:concat([<<"Method Intl.DateTimeFormat.prototype.">>, Name,
                                                <<" called on incompatible receiver">>])).

bound_format(This) ->
    DTF = unwrap(This, <<"format">>),
    case maps:get(bound, buoy_heap:slots(DTF)) of
        undefined ->
            F = buoy_heap:function(fun(_, Args) -> text(format_parts(buoy_heap:slots(DTF), date_value(arg(1, Args)))) end,
                                   <<>>, 1, #{}),
            buoy_heap:set_slots(DTF, (buoy_heap:slots(DTF))#{bound => F}),
            F;
        F -> F
    end.

%% The time value of the argument of format and formatToParts: now for
%% undefined.
date_value(undefined) -> erlang:system_time(millisecond);
date_value(Date) -> buoy_ref:to_number(Date).

%% Date.prototype.toLocaleString, toLocaleDateString, and
%% toLocaleTimeString of the time value T: Required and Defaults are any and
%% all, date and date, or time and time.
-spec to_locale_string(term(), term(), term(), any | date | time) -> term().
to_locale_string('NaN', _Locales, _Options, _Kind) -> <<"Invalid Date">>;
to_locale_string(T, Locales, Options, Kind) ->
    Defaults = case Kind of any -> all; _ -> Kind end,
    DTF = create(buoy_ref_realm:current(constructor()), Locales, Options, Kind, Defaults),
    text(format_parts(buoy_heap:slots(DTF), T)).

%%% CreateDateTimeFormat

create(NewTarget, Locales, Options0, Required, Defaults) ->
    Proto = buoy_ref_realm:proto_for(NewTarget, ?PROTO),
    Requested = buoy_ref_intl:canonicalize_locale_list(Locales),
    Options = buoy_ref_intl:coerce_options(Options0),
    _Matcher = get_option(Options, <<"localeMatcher">>, string, [<<"lookup">>, <<"best fit">>], <<"best fit">>),
    Calendar = type_option(Options, <<"calendar">>),
    Nu = type_option(Options, <<"numberingSystem">>),
    Hour12 = get_option(Options, <<"hour12">>, boolean, empty, undefined),
    HourCycle = get_option(Options, <<"hourCycle">>, string, [<<"h11">>, <<"h12">>, <<"h23">>, <<"h24">>], undefined),
    Hc = case Hour12 of
        undefined -> HourCycle;
        _ -> null
    end,
    Resolved = buoy_ref_intl:resolve_locale(buoy_ref_intl_data:available_locales(), Requested,
                                            #{<<"ca">> => Calendar, <<"nu">> => Nu, <<"hc">> => Hc},
                                            [<<"ca">>, <<"hc">>, <<"nu">>], fun locale_data/2),
    DataLocale = buoy_ref_intl:base_name(maps:get(data_locale, Resolved)),
    Cal = maps:get(<<"ca">>, Resolved),
    NuResolved = maps:get(<<"nu">>, Resolved),
    HcData = hour_cycles(DataLocale),
    HourCycleResolved = case {Hour12, maps:get(<<"hc">>, Resolved)} of
        {true, _} -> maps:get(h12, HcData);
        {false, _} -> maps:get(h24, HcData);
        {undefined, null} -> maps:get(default, HcData);
        {undefined, Value} -> Value
    end,
    {TimeZone, Zone} = time_zone(buoy_ref:get(Options, <<"timeZone">>)),
    Components = components(Options, HourCycleResolved),
    _FormatMatcher = get_option(Options, <<"formatMatcher">>, string, [<<"basic">>, <<"best fit">>], <<"best fit">>),
    DateStyle = get_option(Options, <<"dateStyle">>, string, [<<"full">>, <<"long">>, <<"medium">>, <<"short">>], undefined),
    TimeStyle = get_option(Options, <<"timeStyle">>, string, [<<"full">>, <<"long">>, <<"medium">>, <<"short">>], undefined),
    DefaultHour = default_hour(maps:get(locale, Resolved), DataLocale),
    {{Pattern, Override}, DtfHourCycle} =
        case DateStyle =/= undefined orelse TimeStyle =/= undefined of
            true ->
                Components =:= [] orelse buoy_ref:type_error(<<"Invalid option : option">>),
                Required =:= date andalso TimeStyle =/= undefined andalso buoy_ref:type_error(<<"Invalid option : timeStyle">>),
                Required =:= time andalso DateStyle =/= undefined andalso buoy_ref:type_error(<<"Invalid option : dateStyle">>),
                StyleHc = case TimeStyle of undefined -> undefined; _ -> HourCycleResolved end,
                {style_pattern(DataLocale, Cal, NuResolved, DateStyle, TimeStyle, StyleHc, DefaultHour), StyleHc};
            false ->
                Present = [P || {P, _} <- Components],
                Keys = case Required of
                    date -> [<<"weekday">>, <<"year">>, <<"month">>, <<"day">>];
                    time -> [<<"dayPeriod">>, <<"hour">>, <<"minute">>, <<"second">>, <<"fractionalSecondDigits">>];
                    any -> [<<"weekday">>, <<"year">>, <<"month">>, <<"day">>, <<"dayPeriod">>, <<"hour">>, <<"minute">>,
                            <<"second">>, <<"fractionalSecondDigits">>]
                end,
                NeedDefaults = not lists:any(fun(K) -> lists:member(K, Present) end, Keys),
                Skeleton = lists:append([S || {_, S} <- Components])
                    ++ case NeedDefaults andalso (Defaults =:= date orelse Defaults =:= all) of true -> "yMd"; false -> "" end
                    ++ case NeedDefaults andalso (Defaults =:= time orelse Defaults =:= all) of
                           true -> [hour_char(HourCycleResolved), $m, $s];
                           false -> ""
                       end,
                Hc1 = case lists:member(<<"hour">>, Present) of true -> HourCycleResolved; false -> undefined end,
                Best = buoy_ref_intl_date_skeleton:best_pattern(DataLocale, Cal, NuResolved, Skeleton, DefaultHour),
                {{replace_hour_cycle(Best, Hc1), undefined}, Hc1}
        end,
    buoy_heap:new_exotic(intl_date_time_format, Proto,
                         #{locale => maps:get(locale, Resolved), data_locale => DataLocale, calendar => Cal,
                           nu => NuResolved, time_zone => TimeZone, zone => Zone, hour_cycle => DtfHourCycle,
                           date_style => DateStyle, time_style => TimeStyle, pattern => Pattern,
                           overrides => overrides(Override, DataLocale, Cal, Pattern), bound => undefined,
                           %% DateIntervalFormat reads the hour cycle from the locale's hc keyword.
                           interval_hour => case DtfHourCycle of undefined -> DefaultHour; _ -> hour_char(DtfHourCycle) end}).

%% The numbering systems that write the numbers of fields, by pattern letter
%% or all: the override of a style pattern, as "hebr" or "d=hanidays", else
%% y=jpanyear for a Japanese pattern with 年 in Japanese, as ICU's
%% SimpleDateFormat sets them.
overrides(undefined, Locale, Cal, Pattern) ->
    case Cal =:= <<"japanese">> andalso buoy_ref_intl:language(Locale) =:= <<"ja">> andalso lists:member(16#5E74, Pattern) of
        true -> #{$y => <<"jpanyear">>};
        false -> #{}
    end;
overrides(Override, _Locale, _Cal, _Pattern) ->
    maps:from_list([case binary:split(Item, <<"=">>) of
                        [<<Letter>>, Nu] -> {Letter, Nu};
                        [Nu] -> {all, Nu}
                    end || Item <- binary:split(Override, <<";">>, [global])]).

%% A calendar or numbering system option, which must match the type
%% nonterminal of UTS #35.
type_option(Options, Key) ->
    case get_option(Options, Key, string, empty, undefined) of
        undefined -> undefined;
        Value ->
            buoy_ref_intl:is_type(Value) orelse range_error(buoy_ref_string:concat([<<"Invalid ">>, Key, <<" : ">>, Value])),
            Value
    end.

%% [[LocaleData]] of DateTimeFormat for the relevant keys.
locale_data(Locale, <<"ca">>) ->
    Default = default_calendar(Locale),
    [Default | [C || C <- buoy_ref_intl_data:calendars(), C =/= Default]];
locale_data(Locale, <<"nu">>) -> buoy_ref_intl_number_format:locale_data(Locale, <<"nu">>);
locale_data(_Locale, <<"hc">>) -> [null, <<"h11">>, <<"h12">>, <<"h23">>, <<"h24">>].

%% The first calendar that the region of the locale prefers.
default_calendar(Locale) ->
    case [C || C <- buoy_ref_intl_data:region_calendars(region(Locale)), lists:member(C, buoy_ref_intl_data:calendars())] of
        [C | _] -> C;
        [] -> <<"gregory">>
    end.

%% The region of the locale or of its likely subtags, else 001.
region(Locale) ->
    case buoy_ref_intl:region(Locale) of
        undefined ->
            case buoy_native:intl_maximize(buoy_ref_intl:base_name(Locale)) of
                Max when is_binary(Max) -> case buoy_ref_intl:region(Max) of undefined -> <<"001">>; R -> R end;
                _ -> <<"001">>
            end;
        R -> R
    end.

%% [[hourCycle]], [[hourCycle12]], and [[hourCycle24]] of the locale, from
%% CLDR's timeData of its language and region, else of its region.
hour_cycles(Locale) ->
    Region = region(Locale),
    Lookup = fun(F) ->
                     Keys = [<<(buoy_ref_intl:language(Locale))/binary, "_", Region/binary>>, Region, <<"001">>],
                     hd([V || K <- Keys, V <- [buoy_ref_intl_data:F(K)], V =/= none] ++ [none])
             end,
    Default = case Lookup(hour_cycle) of none -> <<"h23">>; D -> D end,
    H12 = case Default of
        _ when Default =:= <<"h11">>; Default =:= <<"h12">> -> Default;
        _ -> case Lookup(hour_cycle_12) of none -> <<"h12">>; C -> C end
    end,
    H24 = case Default of
        _ when Default =:= <<"h23">>; Default =:= <<"h24">> -> Default;
        _ -> <<"h23">>
    end,
    #{default => Default, h12 => H12, h24 => H24}.

%% The hour character that the generator uses for the locale: that of its
%% -u-hc- keyword, else that of its region's preferred hour cycle.
default_hour(Locale, DataLocale) ->
    Keyword = case buoy_ref_intl:unicode_extension(Locale) of
        none -> undefined;
        Ext -> proplists:get_value(<<"hc">>, element(2, buoy_ref_intl:extension_components(Ext)))
    end,
    hour_char(case Keyword of undefined -> maps:get(default, hour_cycles(DataLocale)); K -> K end).

hour_char(<<"h11">>) -> $K;
hour_char(<<"h12">>) -> $h;
hour_char(<<"h23">>) -> $H;
hour_char(<<"h24">>) -> $k.

%% The time zone option: {Identifier, Zone}, with an offset zone as
%% {offset, Minutes} and a named zone as its primary identifier.
time_zone(undefined) ->
    Id = buoy_ref_tz:system_id(),
    {Id, Id};
time_zone(Value) ->
    Text = buoy_ref:to_string(Value),
    case offset_minutes(Text) of
        {ok, Minutes} -> {offset_identifier(Minutes), {offset, Minutes}};
        error ->
            case is_binary(Text) andalso buoy_ref_tz:identifier(Text) of
                {ok, Id, Primary} -> {Id, Primary};
                _ -> range_error(buoy_ref_string:concat([<<"Invalid time zone specified: ">>, Text]))
            end
    end.

%% IsTimeZoneOffsetString with at most minutes: ±HH, ±HHMM, or ±HH:MM.
offset_minutes(Text) when is_binary(Text) ->
    case binary_to_list(Text) of
        [Sign | Rest] when Sign =:= $+; Sign =:= $-; Sign =:= 16#2212 ->
            Digits = [C || C <- Rest, C =/= $:],
            Colons = length(Rest) - length(Digits),
            Valid = lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Digits) andalso
                ((length(Digits) =:= 2 andalso Colons =:= 0) orelse
                 (length(Digits) =:= 4 andalso (Rest =:= Digits orelse lists:nth(3, Rest) =:= $:) andalso Colons =< 1)),
            case Valid of
                false -> error;
                true ->
                    H = list_to_integer(lists:sublist(Digits, 2)),
                    M = case length(Digits) of 4 -> list_to_integer(lists:nthtail(2, Digits)); _ -> 0 end,
                    case H =< 23 andalso M =< 59 of
                        true -> {ok, case Sign of $+ -> 1; _ -> -1 end * (H * 60 + M)};
                        false -> error
                    end
            end;
        _ -> error
    end;
offset_minutes(_) -> error.

%% FormatOffsetTimeZoneIdentifier.
offset_identifier(Minutes) ->
    Sign = case Minutes >= 0 of true -> "+"; false -> "-" end,
    A = abs(Minutes),
    list_to_binary(io_lib:format("~s~2..0B:~2..0B", [Sign, A div 60, A rem 60])).

%% The components of the options in table order: [{Property, Skeleton}].
components(Options, Hc) ->
    lists:append([component(Options, Property, Values, Hc) || {Property, Values} <- ?COMPONENTS]).

component(Options, <<"fractionalSecondDigits">>, _, _) ->
    case buoy_ref:get(Options, <<"fractionalSecondDigits">>) of
        undefined -> [];
        V ->
            case buoy_ref:to_number(V) of
                N when is_number(N), N >= 1, N =< 3 -> [{<<"fractionalSecondDigits">>, lists:duplicate(floor(N), $S)}];
                _ -> range_error(<<"fractionalSecondDigits value is out of range.">>)
            end
    end;
component(Options, Property, Values, Hc) ->
    case get_option(Options, Property, string, [V || {V, _} <- Values], undefined) of
        undefined -> [];
        Value ->
            Skeleton = case proplists:get_value(Value, Values) of
                hour1 -> [hour_char(Hc)];
                hour2 -> [hour_char(Hc), hour_char(Hc)];
                S -> S
            end,
            [{Property, Skeleton}]
    end.

%% DateTimeStylePattern as V8 builds it: the style patterns of the locale,
%% the date and time joined by the glue of the date style, and a pattern of
%% the generator when the time style's hour cycle is not the one asked for.
style_pattern(Locale, Cal, Nu, DateStyle, TimeStyle, Hc, DefaultHour) ->
    Patterns = buoy_ref_intl_date_skeleton:calendar_resource(Locale, Cal, [<<"DateTimePatterns">>], []),
    %% An entry is a pattern, or [Pattern, Override] with the numbering override.
    Get = fun(Offset, Style) ->
                  Index = Offset + case Style of <<"full">> -> 1; <<"long">> -> 2; <<"medium">> -> 3; <<"short">> -> 4 end,
                  case lists:nth(Index, Patterns) of
                      [P, Override | _] -> {unicode:characters_to_list(P), Override};
                      P -> {unicode:characters_to_list(P), undefined}
                  end
          end,
    {Pattern, Override} = case {DateStyle, TimeStyle} of
        {_, undefined} -> Get(4, DateStyle);
        {undefined, _} -> Get(0, TimeStyle);
        _ ->
            Glue = buoy_ref_intl_date_skeleton:date_time_glue(Locale, Cal, binary_to_atom(DateStyle)),
            {Date, DateOverride} = Get(4, DateStyle),
            {Time, _} = Get(0, TimeStyle),
            {lists:flatten(string:replace(string:replace(Glue, "{1}", Date), "{0}", Time)), DateOverride}
    end,
    case TimeStyle =:= undefined orelse Hc =:= pattern_hour_cycle(Pattern) of
        true -> {Pattern, Override};
        false ->
            Skeleton = [case C of _ when C =:= $h; C =:= $H; C =:= $K; C =:= $k -> hour_char(Hc); _ -> C end
                        || C <- buoy_ref_intl_date_skeleton:skeleton_of(Pattern), C =/= $a, C =/= $b, C =/= $B],
            {replace_hour_cycle(buoy_ref_intl_date_skeleton:best_pattern(Locale, Cal, Nu, Skeleton, DefaultHour), Hc), undefined}
    end.

%% HourCycleFromPattern.
pattern_hour_cycle(Pattern) -> pattern_hour_cycle(Pattern, false).
pattern_hour_cycle([], _) -> undefined;
pattern_hour_cycle([$' | Rest], Quoted) -> pattern_hour_cycle(Rest, not Quoted);
pattern_hour_cycle([$K | _], false) -> <<"h11">>;
pattern_hour_cycle([$h | _], false) -> <<"h12">>;
pattern_hour_cycle([$H | _], false) -> <<"h23">>;
pattern_hour_cycle([$k | _], false) -> <<"h24">>;
pattern_hour_cycle([_ | Rest], Quoted) -> pattern_hour_cycle(Rest, Quoted).

%% ReplaceHourCycleInPattern: every hour field in the hour cycle, with a
%% space after a day field that meets it.
replace_hour_cycle(Pattern, undefined) -> Pattern;
replace_hour_cycle(Pattern, Hc) -> replace_hour_cycle(Pattern, hour_char(Hc), true, 0, []).

replace_hour_cycle([], _H, _Replace, _Last, Acc) -> lists:reverse(Acc);
replace_hour_cycle([$' | Rest], H, Replace, _Last, Acc) -> replace_hour_cycle(Rest, H, not Replace, $', [$' | Acc]);
replace_hour_cycle([C | Rest], H, true, Last, Acc) when C =:= $H; C =:= $h; C =:= $K; C =:= $k ->
    Acc1 = case Last of $d -> [$\s | Acc]; _ -> Acc end,
    replace_hour_cycle(Rest, H, true, C, [H | Acc1]);
replace_hour_cycle([C | Rest], H, Replace, _Last, Acc) -> replace_hour_cycle(Rest, H, Replace, C, [C | Acc]).

%%% resolvedOptions

%% The resolved options, the components found in the pattern as V8 finds
%% them.
resolved_options(S) ->
    Pattern = maps:get(pattern, S),
    Styled = maps:get(date_style, S) =/= undefined orelse maps:get(time_style, S) =/= undefined,
    Hc = maps:get(hour_cycle, S),
    Components = case Styled of
        true -> [];
        false ->
            lists:append([found(Property, Pattern) || {Property, _} <- ?COMPONENTS])
    end,
    buoy_ref_intl:options_object(
      [{<<"locale">>, maps:get(locale, S)}, {<<"calendar">>, maps:get(calendar, S)}, {<<"numberingSystem">>, maps:get(nu, S)},
       {<<"timeZone">>, maps:get(time_zone, S)}, {<<"hourCycle">>, Hc},
       {<<"hour12">>, case Hc of undefined -> undefined; _ -> Hc =:= <<"h11">> orelse Hc =:= <<"h12">> end}]
      ++ Components
      ++ [{<<"dateStyle">>, maps:get(date_style, S)}, {<<"timeStyle">>, maps:get(time_style, S)}]).

%% The value of a component whose pattern letters occur in the pattern.
found(<<"fractionalSecondDigits">>, Pattern) ->
    case [length(Run) || Run <- runs(Pattern), hd(Run) =:= $S] of
        [N | _] -> [{<<"fractionalSecondDigits">>, N}];
        [] -> []
    end;
found(Property, Pattern) ->
    Pairs = case Property of
        <<"weekday">> -> [{"EEEEE", <<"narrow">>}, {"EEEE", <<"long">>}, {"EEE", <<"short">>}, {"ccccc", <<"narrow">>},
                          {"cccc", <<"long">>}, {"ccc", <<"short">>}];
        <<"era">> -> [{"GGGGG", <<"narrow">>}, {"GGGG", <<"long">>}, {"GGG", <<"short">>}];
        <<"year">> -> [{"yy", <<"2-digit">>}, {"y", <<"numeric">>}, {"YY", <<"2-digit">>}, {"Y", <<"numeric">>}];
        <<"month">> -> [{"MMMMM", <<"narrow">>}, {"MMMM", <<"long">>}, {"MMM", <<"short">>}, {"MM", <<"2-digit">>}, {"M", <<"numeric">>},
                        {"LLLLL", <<"narrow">>}, {"LLLL", <<"long">>}, {"LLL", <<"short">>}, {"LL", <<"2-digit">>}, {"L", <<"numeric">>}];
        <<"day">> -> [{"dd", <<"2-digit">>}, {"d", <<"numeric">>}];
        <<"dayPeriod">> -> [{"BBBBB", <<"narrow">>}, {"bbbbb", <<"narrow">>}, {"BBBB", <<"long">>}, {"bbbb", <<"long">>},
                            {"B", <<"short">>}, {"b", <<"short">>}];
        <<"hour">> -> [{"HH", <<"2-digit">>}, {"H", <<"numeric">>}, {"hh", <<"2-digit">>}, {"h", <<"numeric">>},
                       {"kk", <<"2-digit">>}, {"k", <<"numeric">>}, {"KK", <<"2-digit">>}, {"K", <<"numeric">>}];
        <<"minute">> -> [{"mm", <<"2-digit">>}, {"m", <<"numeric">>}];
        <<"second">> -> [{"ss", <<"2-digit">>}, {"s", <<"numeric">>}];
        <<"timeZoneName">> -> [{"zzzz", <<"long">>}, {"z", <<"short">>}, {"OOOO", <<"longOffset">>}, {"O", <<"shortOffset">>},
                               {"vvvv", <<"longGeneric">>}, {"v", <<"shortGeneric">>}]
    end,
    case [V || {Letters, V} <- Pairs, string:find(Pattern, Letters) =/= nomatch] of
        [V | _] -> [{Property, V}];
        [] -> []
    end.

runs([]) -> [];
runs([C | _] = All) ->
    {Run, Rest} = lists:splitwith(fun(X) -> X =:= C end, All),
    [Run | runs(Rest)].

%%% FormatDateTime

%% The parts of the time value X: TimeClip, then the fields of the pattern
%% for the wall-clock time of the time zone.
format_parts(S, X) ->
    T = time_clip(X),
    spaces(buoy_ref_intl_date_fields:format(maps:get(pattern, S), date_fields(S, T), context(S))).

time_clip(X) when is_number(X), abs(X) =< ?MAX_TIME -> trunc(X) + 0;
time_clip(_) -> range_error(<<"Invalid time value">>).

context(S) ->
    #{locale => maps:get(data_locale, S), cal => maps:get(calendar, S), zone => maps:get(zone, S),
      digits => buoy_intl_cldr:numbering_digits(maps:get(nu, S)), overrides => maps:get(overrides, S)}.

%% The fields of the instant T in the time zone and calendar of the format.
date_fields(S, T) ->
    {Offset, Dst} = case maps:get(zone, S) of
        {offset, Minutes} -> {Minutes * 60000, false};
        Zone -> buoy_ref_tz:info_in(Zone, T)
    end,
    Local = T + Offset,
    Days = floor_div(Local, ?DAY),
    Ms = Local - Days * ?DAY,
    {Y, M, D} = buoy_ref_tz:civil_from_days(Days),
    maps:merge(calendar_date(maps:get(calendar, S), Days, {Y, M, D}),
               #{year => Y, weekday => ((Days + 4) rem 7 + 7) rem 7 + 1,
                 hour => Ms div 3600000, minute => Ms div 60000 rem 60, second => Ms div 1000 rem 60, millisecond => Ms rem 1000,
                 offset => Offset, dst => Dst, instant => T}).

%% The fields of ICU's Calendar for the day: the era index and the year in
%% the era, the month as a number and as the index of its name, whether it
%% is a leap month, the day, and the related ISO year and the year in the
%% cycle of the Chinese and Korean calendars. The eras follow test262 where
%% ICU 78 differs: one era for the Coptic calendar, and BH before the
%% Islamic epoch.
calendar_date(Cal, Days, Date) when Cal =:= <<"buddhist">>; Cal =:= <<"roc">>; Cal =:= <<"japanese">> ->
    %% V8 makes the Gregorian calendar proleptic, but these keep ICU's switch
    %% from the Julian calendar on 1582-10-15.
    solar_date(Cal, case Days < -141427 of true -> julian(Days); false -> Date end);
calendar_date(Cal, _Days, Date) when Cal =:= <<"gregory">>; Cal =:= <<"iso8601">> ->
    solar_date(Cal, Date);
calendar_date(Cal, Days, _Date) ->
    {Year, Cyclic, Ordinal, Number, Leap, Day} = buoy_native:intl_calendar_date(Cal, Days),
    Fields = #{month => Number, month_name => Number - 1, leap => Leap, day => Day},
    case Cal of
        _ when Cyclic > 0 -> Fields#{era => 0, era_year => Cyclic, related_year => Year, cyclic => Cyclic};
        <<"hebrew">> -> Fields#{era => 0, era_year => Year, month => Ordinal, month_name => hebrew_month(Ordinal, Number, Leap)};
        _ ->
            {Era, EraYear} = lunar_era(Cal, Year),
            Fields#{era => Era, era_year => EraYear}
    end.

solar_date(Cal, {_, M, D} = Date) ->
    {Era, EraYear} = solar_era(Cal, Date),
    #{era => Era, era_year => EraYear, month => M, month_name => M - 1, leap => false, day => D}.

%% The Julian calendar date of a day after 1970-01-01.
julian(Days) ->
    C = Days + 2440588 + 32082,
    D = floor_div(4 * C + 3, 1461),
    E = C - floor_div(1461 * D, 4),
    M = (5 * E + 2) div 153,
    {D - 4800 + M div 10, M + 3 - 12 * (M div 10), E - (153 * M + 2) div 5 + 1}.

solar_era(<<"buddhist">>, {Y, _, _}) -> {0, Y + 543};
solar_era(<<"roc">>, {Y, _, _}) when Y > 1911 -> {1, Y - 1911};
solar_era(<<"roc">>, {Y, _, _}) -> {0, 1912 - Y};
solar_era(<<"japanese">>, Date) ->
    Starts = buoy_intl_cldr:supplemental(japanese_eras),
    Era = max(0, length(lists:takewhile(fun(Start) -> Start =< Date end, Starts)) - 1),
    {Era, element(1, Date) - element(1, lists:nth(Era + 1, Starts)) + 1};
solar_era(_, {Y, _, _}) when Y > 0 -> {1, Y};
solar_era(_, {Y, _, _}) -> {0, 1 - Y}.

%% The era and era year of the extended year of a calendar of ICU4X.
lunar_era(<<"coptic">>, Year) -> {1, Year};
lunar_era(<<"ethiopic">>, Year) when Year > 0 -> {1, Year};
lunar_era(<<"ethiopic">>, Year) -> {0, Year + 5500};
lunar_era(<<"islamic", _/binary>>, Year) when Year < 1 -> {1, 1 - Year};
lunar_era(_, Year) -> {0, Year}.

%% ICU's index of a Hebrew month name: Adar I is 5 and is skipped in a
%% common year, and Adar of a leap year is Adar II, 13.
hebrew_month(_Ordinal, _Number, true) -> 5;
hebrew_month(_Ordinal, Number, false) when Number =< 5 -> Number - 1;
hebrew_month(7, 6, false) -> 13;
hebrew_month(_Ordinal, Number, false) -> Number.

floor_div(A, B) when A >= 0 -> A div B;
floor_div(A, B) -> -((-A + B - 1) div B).

%% V8 writes a space for the narrow no-break space and the thin space of
%% CLDR's patterns, in strings and parts alike (ReplaceUnicodeSpaces).
spaces(Parts) ->
    [setelement(2, Part, [case C of 16#202F -> $\s; 16#2009 -> $\s; _ -> C end || C <- element(2, Part)]) || Part <- Parts].

%%% formatRange

range_parts(S, X, Y) ->
    T1 = time_clip(X),
    T2 = time_clip(Y),
    Ctx = context(S),
    Generator = {maps:get(data_locale, S), maps:get(calendar, S), maps:get(nu, S), maps:get(interval_hour, S)},
    case buoy_ref_intl_date_interval:format(Generator, maps:get(pattern, S), date_fields(S, T1), date_fields(S, T2),
                                            fun(Pattern, F) -> buoy_ref_intl_date_fields:format(Pattern, F, Ctx) end) of
        single -> [{T, V, shared} || {T, V} <- format_parts(S, T1)];
        Parts -> spaces(Parts)
    end.
