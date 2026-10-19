%% Intl.Locale (ECMA-402 section 15): an object of the class intl_locale whose
%% slots hold the canonical tag and the values of its locale extension keys.
%% The likely subtags and the text direction come from ICU4X (buoy_native),
%% the region data of the info methods from CLDR (buoy_ref_intl_data).
-module(buoy_ref_intl_locale).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, constructor/0]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).
-import(buoy_ref_intl, [get_option/5, range_error/1]).

-define(PROTO, 'Intl.Locale.prototype').
%% [[LocaleExtensionKeys]] of %Intl.Locale%.
-define(KEYS, [<<"ca">>, <<"co">>, <<"fw">>, <<"hc">>, <<"kf">>, <<"kn">>, <<"nu">>]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Getters = [{Name, {'$accessor', buoy_ref_realm:builtin(<<"get Intl.Locale.prototype.", Name/binary>>, <<"get ", Name/binary>>, 0,
                                                            fun(This, _) -> getter(Name, This) end), undefined}, 4}
               || Name <- [<<"baseName">>, <<"calendar">>, <<"caseFirst">>, <<"collation">>, <<"firstDayOfWeek">>,
                           <<"hourCycle">>, <<"language">>, <<"numberingSystem">>, <<"numeric">>, <<"region">>,
                           <<"script">>, <<"variants">>]],
    Methods = ?METHODS(<<"Intl.Locale.prototype">>,
                       [{<<"maximize">>, 0}, {<<"minimize">>, 0}, {<<"toString">>, 0}, {<<"getCalendars">>, 0},
                        {<<"getCollations">>, 0}, {<<"getHourCycles">>, 0}, {<<"getNumberingSystems">>, 0},
                        {<<"getTimeZones">>, 0}, {<<"getTextInfo">>, 0}, {<<"getWeekInfo">>, 0}]),
    [{?PROTO, record(object, ?OBJECT_PROTO, Methods ++ Getters ++ [{<<"constructor">>, constructor()}, {?SYM(toStringTag), <<"Intl.Locale">>, 4}], none)},
     {{builtin, <<"Intl.Locale">>}, ctor_record(<<"Locale">>, 1, {'$o', ?PROTO}, [], fun construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [].

-spec constructor() -> term().
constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Intl.Locale">>).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(_Name, _This, _Args) -> buoy_ref:type_error(<<"Constructor Intl.Locale requires 'new'">>).

%%% The constructor

construct(NewTarget, Args) ->
    Proto = buoy_ref_realm:proto_for(NewTarget, ?PROTO),
    Tag = case arg(1, Args) of
        T when ?IS_STRING(T) -> T;
        T when ?IS_OBJECT(T) ->
            case is_locale(T) of
                true -> slot(T, locale);
                false -> buoy_ref:to_string(T)
            end;
        _ -> buoy_ref:type_error(<<"First argument to Intl.Locale constructor can't be empty or missing">>)
    end,
    Options = buoy_ref_intl:coerce_options(arg(2, Args)),
    Canonical = case buoy_ref_intl:canonicalize_tag(Tag) of
        {ok, C} -> C;
        error -> range_error(<<"Incorrect locale information provided">>)
    end,
    Updated = update_language_id(Canonical, Options),
    Calendar = type_option(Options, <<"calendar">>),
    Collation = type_option(Options, <<"collation">>),
    FirstDay = case get_option(Options, <<"firstDayOfWeek">>, string, empty, undefined) of
        undefined -> undefined;
        Day ->
            Value = weekday_to_uvalue(Day),
            buoy_ref_intl:is_type(Value) orelse range_error(<<"Incorrect firstDayOfWeek">>),
            Value
    end,
    HourCycle = get_option(Options, <<"hourCycle">>, string, [<<"h11">>, <<"h12">>, <<"h23">>, <<"h24">>], undefined),
    CaseFirst = get_option(Options, <<"caseFirst">>, string, [<<"upper">>, <<"lower">>, <<"false">>], undefined),
    Numeric = case get_option(Options, <<"numeric">>, boolean, empty, undefined) of
        undefined -> undefined;
        B -> atom_to_binary(B)
    end,
    NumberingSystem = type_option(Options, <<"numberingSystem">>),
    Opt = #{<<"ca">> => Calendar, <<"co">> => Collation, <<"fw">> => FirstDay, <<"hc">> => HourCycle,
            <<"kf">> => CaseFirst, <<"kn">> => Numeric, <<"nu">> => NumberingSystem},
    buoy_heap:new_exotic(intl_locale, Proto, make_locale_record(Updated, Opt)).

%% An option that must match the type nonterminal of UTS #35.
type_option(Options, Key) ->
    case get_option(Options, Key, string, empty, undefined) of
        undefined -> undefined;
        Value ->
            is_binary(Value) andalso buoy_ref_intl:is_type(Value) orelse
                range_error(buoy_ref_string:concat([<<"Incorrect locale information provided for ">>, Key])),
            Value
    end.

%% UpdateLanguageId: the language, script, region, and variants of the
%% options in place of those of the tag.
update_language_id(Tag, Options) ->
    Base = buoy_ref_intl:base_name(Tag),
    Language = get_option(Options, <<"language">>, string, empty, buoy_ref_intl:language(Base)),
    valid(Language, fun buoy_ref_intl:is_language/1),
    Script = get_option(Options, <<"script">>, string, empty, buoy_ref_intl:script(Base)),
    Script =:= undefined orelse valid(Script, fun buoy_ref_intl:is_script/1),
    Region = get_option(Options, <<"region">>, string, empty, buoy_ref_intl:region(Base)),
    Region =:= undefined orelse valid(Region, fun buoy_ref_intl:is_region/1),
    Variants = get_option(Options, <<"variants">>, string, empty, buoy_ref_intl:variants(Base)),
    Variants =:= undefined orelse valid_variants(Variants),
    Extensions = binary:part(Tag, byte_size(Base), byte_size(Tag) - byte_size(Base)),
    iolist_to_binary([Language, [[$-, S] || S <- [Script, Region, Variants], S =/= undefined], Extensions]).

valid(Value, Pred) ->
    is_binary(Value) andalso Pred(Value) orelse range_error(<<"Incorrect locale information provided">>).

valid_variants(Variants) ->
    is_binary(Variants) andalso Variants =/= <<>> orelse range_error(<<"Incorrect locale information provided">>),
    Subtags = binary:split(string:lowercase(Variants), <<"-">>, [global]),
    lists:all(fun buoy_ref_intl:is_variant/1, Subtags) andalso length(lists:usort(Subtags)) =:= length(Subtags)
        orelse range_error(<<"Incorrect locale information provided">>).

%% MakeLocaleRecord: the slots of the locale, with the option values in place
%% of the keywords of the tag.
make_locale_record(Tag, Opt) ->
    {Attributes, Keywords0} = case buoy_ref_intl:unicode_extension(Tag) of
        none -> {[], []};
        Extension -> buoy_ref_intl:extension_components(Extension)
    end,
    {Keywords, Values} = lists:foldl(
        fun(Key, {Keywords1, Values1}) ->
                Current = case lists:keyfind(Key, 1, Keywords1) of
                    {_, V} -> V;
                    false -> undefined
                end,
                case maps:get(Key, Opt) of
                    undefined -> {Keywords1, Values1#{Key => Current}};
                    Override ->
                        Value = buoy_ref_intl:canonicalize_uvalue(Key, Override),
                        {lists:keystore(Key, 1, Keywords1, {Key, Value}), Values1#{Key => Value}}
                end
        end, {Keywords0, #{}}, ?KEYS),
    Locale = buoy_ref_intl:insert_extension(buoy_ref_intl:remove_extension(Tag), Attributes, Keywords),
    #{locale => Locale, calendar => maps:get(<<"ca">>, Values), collation => maps:get(<<"co">>, Values),
      first_day => maps:get(<<"fw">>, Values), hour_cycle => maps:get(<<"hc">>, Values),
      case_first => maps:get(<<"kf">>, Values), numbering_system => maps:get(<<"nu">>, Values),
      numeric => lists:member(maps:get(<<"kn">>, Values), [<<"true">>, <<>>])}.

%% WeekdayToUValue: "0" to "7" as the names of the days.
weekday_to_uvalue(Day) ->
    case lists:keyfind(Day, 1, [{<<"0">>, <<"sun">>}, {<<"1">>, <<"mon">>}, {<<"2">>, <<"tue">>}, {<<"3">>, <<"wed">>},
                                {<<"4">>, <<"thu">>}, {<<"5">>, <<"fri">>}, {<<"6">>, <<"sat">>}, {<<"7">>, <<"sun">>}]) of
        {_, Name} -> Name;
        false -> Day
    end.

%%% The prototype

is_locale(V) -> ?IS_OBJECT(V) andalso buoy_heap:class_of(V) =:= intl_locale.

slot(Locale, Key) -> maps:get(Key, buoy_heap:slots(Locale)).

%% RequireInternalSlot(loc, [[InitializedLocale]]).
this_locale(This, Name) ->
    is_locale(This) orelse
        buoy_ref:type_error(buoy_ref_string:concat([<<"Method Intl.Locale.prototype.">>, Name, <<" called on incompatible receiver">>])),
    This.

getter(Name, This) ->
    Loc = this_locale(This, Name),
    Locale = slot(Loc, locale),
    case Name of
        <<"baseName">> -> buoy_ref_intl:base_name(Locale);
        <<"calendar">> -> slot(Loc, calendar);
        <<"caseFirst">> -> slot(Loc, case_first);
        <<"collation">> -> slot(Loc, collation);
        <<"firstDayOfWeek">> -> slot(Loc, first_day);
        <<"hourCycle">> -> slot(Loc, hour_cycle);
        <<"language">> -> buoy_ref_intl:language(Locale);
        <<"numberingSystem">> -> slot(Loc, numbering_system);
        <<"numeric">> -> slot(Loc, numeric);
        <<"region">> -> buoy_ref_intl:region(Locale);
        <<"script">> -> buoy_ref_intl:script(Locale);
        <<"variants">> -> buoy_ref_intl:variants(Locale)
    end.

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Intl.Locale.prototype">>, Name, This, _Args) ->
    Loc = this_locale(This, Name),
    info(Name, Loc, slot(Loc, locale)).

info(<<"toString">>, _Loc, Locale) ->
    Locale;
info(<<"maximize">>, _Loc, Locale) ->
    new_locale(likely(buoy_native:intl_maximize(Locale), Locale));
info(<<"minimize">>, _Loc, Locale) ->
    new_locale(likely(buoy_native:intl_minimize(Locale), Locale));
info(<<"getCalendars">>, Loc, Locale) ->
    case slot(Loc, calendar) of
        undefined ->
            {Region, Override} = region_preference(Locale),
            InUse = first_nonempty([buoy_ref_intl_data:region_calendars(R) || R <- [Override, Region], R =/= undefined]),
            Available = buoy_ref_intl_data:calendars(),
            List = lists:foldl(fun(C, Acc) ->
                                       Canonical = buoy_ref_intl:canonicalize_uvalue(<<"ca">>, C),
                                       case lists:member(Canonical, Available) andalso not lists:member(Canonical, Acc) of
                                           true -> Acc ++ [Canonical];
                                           false -> Acc
                                       end
                               end, [], InUse),
            array(case List of [] -> [<<"gregory">>]; _ -> List end);
        Calendar -> array([Calendar])
    end;
info(<<"getCollations">>, Loc, _Locale) ->
    case slot(Loc, collation) of
        undefined -> array([<<"emoji">>, <<"eor">>]);
        Collation -> array([Collation])
    end;
info(<<"getHourCycles">>, Loc, Locale) ->
    case slot(Loc, hour_cycle) of
        undefined ->
            {Region, Override} = region_preference(Locale),
            Language = buoy_ref_intl:language(Locale),
            Cycles = [C || R <- [Override, Region], R =/= undefined,
                           C <- [buoy_ref_intl_data:hour_cycle(<<Language/binary, "-", R/binary>>), buoy_ref_intl_data:hour_cycle(R)],
                           C =/= none],
            array(case Cycles of [C | _] -> [C]; [] -> [<<"h23">>] end);
        HourCycle -> array([HourCycle])
    end;
info(<<"getNumberingSystems">>, Loc, _Locale) ->
    case slot(Loc, numbering_system) of
        undefined -> array([<<"latn">>]);
        System -> array([System])
    end;
info(<<"getTimeZones">>, _Loc, Locale) ->
    case buoy_ref_intl:region(Locale) of
        undefined -> undefined;
        Region -> array(buoy_ref_intl_data:region_time_zones(Region))
    end;
info(<<"getTextInfo">>, _Loc, Locale) ->
    Info = buoy_heap:new_object(?OBJECT_PROTO),
    Direction = case buoy_native:intl_is_right_to_left(Locale) of
        true -> <<"rtl">>;
        false -> <<"ltr">>;
        nil -> undefined
    end,
    buoy_heap:define(Info, <<"direction">>, #{value => Direction, writable => true, enumerable => true, configurable => true}),
    Info;
info(<<"getWeekInfo">>, Loc, Locale) ->
    {Region, Override} = region_preference(Locale),
    {First, Weekend} = case [W || R <- [Override, Region], R =/= undefined, W <- [buoy_ref_intl_data:week(R)], W =/= none] of
        [W | _] -> W;
        [] -> buoy_ref_intl_data:week(<<"001">>)
    end,
    FirstDay = case slot(Loc, first_day) of
        undefined -> First;
        Day -> case weekday_number(Day) of undefined -> First; N -> N end
    end,
    Info = buoy_heap:new_object(?OBJECT_PROTO),
    buoy_heap:define(Info, <<"firstDay">>, #{value => FirstDay, writable => true, enumerable => true, configurable => true}),
    buoy_heap:define(Info, <<"weekend">>, #{value => array(Weekend), writable => true, enumerable => true, configurable => true}),
    Info.

likely(Tag, _Locale) when is_binary(Tag) -> Tag;
likely(_, Locale) -> Locale.

new_locale(Tag) ->
    Constructor = buoy_ref_realm:current(constructor()),
    buoy_heap:construct(Constructor, [Tag], Constructor).

array(List) -> buoy_heap:new_array(List).

first_nonempty([]) -> [];
first_nonempty([[] | Rest]) -> first_nonempty(Rest);
first_nonempty([L | _]) -> L.

%% WeekdayUValueToNumber.
weekday_number(Day) ->
    case lists:keyfind(Day, 1, [{<<"mon">>, 1}, {<<"tue">>, 2}, {<<"wed">>, 3}, {<<"thu">>, 4}, {<<"fri">>, 5},
                                {<<"sat">>, 6}, {<<"sun">>, 7}]) of
        {_, N} -> N;
        false -> undefined
    end.

%% RegionPreference: {Region, RegionOverride}. The region is that of the tag,
%% of its sd subdivision, of its likely subtags, or 001, and the override that
%% of its rg subdivision.
region_preference(Locale) ->
    Region = case buoy_ref_intl:region(Locale) of
        undefined ->
            case subdivision_region(Locale, <<"sd">>) of
                undefined ->
                    Maximal = likely(buoy_native:intl_maximize(Locale), Locale),
                    case buoy_ref_intl:region(Maximal) of
                        undefined -> <<"001">>;
                        R -> R
                    end;
                R -> R
            end;
        R -> R
    end,
    {Region, subdivision_region(Locale, <<"rg">>)}.

%% CanonicalUnicodeSubdivision: the region of the subdivision of the key.
subdivision_region(Locale, Key) ->
    Value = case buoy_ref_intl:unicode_extension(Locale) of
        none -> <<>>;
        Extension ->
            case lists:keyfind(Key, 1, element(2, buoy_ref_intl:extension_components(Extension))) of
                {_, V} -> V;
                false -> <<>>
            end
    end,
    case Value of
        <<A, B, _Rest/binary>> when byte_size(Value) >= 3, byte_size(Value) =< 6, A >= $a, A =< $z, B >= $a, B =< $z ->
            region_of(<<"und-", A, B>>);
        <<A, B, C, _Rest/binary>> when byte_size(Value) >= 4, A >= $0, A =< $9 ->
            region_of(<<"und-", A, B, C>>);
        _ -> undefined
    end.

region_of(Tag) ->
    case buoy_ref_intl:canonicalize_tag(Tag) of
        {ok, Canonical} -> buoy_ref_intl:region(Canonical);
        error -> undefined
    end.
