%% Intl.NumberFormat (ECMA-402 section 16): an object of the class
%% intl_number_format whose slots hold the resolved options and the digit
%% slots of buoy_ref_intl_number. Formatting follows ICU's number formatter
%% as V8 drives it, since Node's output is the oracle: the number with its
%% grouping and digits, then the inner modifier (the exponent of scientific
%% notation), the middle modifier (the affixes of the CLDR pattern, with
%% signs, percent, and currency, or the compact pattern), and the outer
%% modifier (the long names of units and currencies). The data comes from
%% CLDR (buoy_intl_cldr) and the plural rules from buoy_intl_plurals.
-module(buoy_ref_intl_number_format).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, constructor/0]).
-export([format_value/3, format_mv/2, number_format/2, partition/2, locale_data/2]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).
-import(buoy_ref_intl, [get_option/5]).

-define(PROTO, 'Intl.NumberFormat.prototype').
-define(NE, <<"NumberElements">>).
-define(LEGACY, <<"IntlLegacyConstructedSymbol">>).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Format = {'$accessor', buoy_ref_realm:builtin(<<"get Intl.NumberFormat.prototype.format">>, <<"get format">>, 0,
                                                   fun(This, _) -> bound_format(This) end), undefined},
    [{?PROTO, record(object, ?OBJECT_PROTO,
                     ?METHODS(<<"Intl.NumberFormat.prototype">>,
                              [{<<"formatToParts">>, 1}, {<<"formatRange">>, 2}, {<<"formatRangeToParts">>, 2},
                               {<<"resolvedOptions">>, 0}])
                     ++ [{<<"format">>, Format, 4}, {<<"constructor">>, constructor()},
                         {?SYM(toStringTag), <<"Intl.NumberFormat">>, 4}],
                     none)},
     {{builtin, <<"Intl.NumberFormat">>}, ctor_record(<<"NumberFormat">>, 0, {'$o', ?PROTO},
                                                      ?METHODS(<<"Intl.NumberFormat">>, [{<<"supportedLocalesOf">>, 1}]),
                                                      fun(NewTarget, Args) -> construct(NewTarget, Args) end)}].

-spec globals() -> [{binary(), term()}].
globals() -> [].

-spec constructor() -> term().
constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Intl.NumberFormat">>).

%% Intl.NumberFormat called as a function: ChainNumberFormat of the
%% normative optional constructor mode (ECMA-402 4.3 Note 1), as V8 does.
-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(_Name, This, Args) ->
    Constructor = buoy_ref_realm:current(constructor()),
    NF = construct(Constructor, Args),
    case ?IS_OBJECT(This) andalso buoy_ref_function:ordinary_has_instance(Constructor, This) of
        true ->
            buoy_heap:define(This, fallback_symbol(), #{value => NF, writable => false, enumerable => false, configurable => false}),
            This;
        false -> NF
    end.

%% %Intl%.[[FallbackSymbol]] of the current realm.
fallback_symbol() -> {'$sym', {intl_fallback, buoy_heap:realm()}, ?LEGACY}.

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Intl.NumberFormat">>, <<"supportedLocalesOf">>, _This, Args) ->
    buoy_ref_intl:filter_locales(buoy_ref_intl_data:available_locales(),
                                 buoy_ref_intl:canonicalize_locale_list(arg(1, Args)), arg(2, Args));
method(<<"Intl.NumberFormat.prototype">>, <<"resolvedOptions">>, This, _Args) ->
    NF = unwrap(This, <<"resolvedOptions">>),
    S = buoy_heap:slots(NF),
    Digits = maps:get(digits, S),
    buoy_ref_intl:options_object(
      [{<<"locale">>, maps:get(locale, S)}, {<<"numberingSystem">>, maps:get(nu, S)}, {<<"style">>, maps:get(style, S)},
       {<<"currency">>, maps:get(currency, S)}, {<<"currencyDisplay">>, maps:get(currency_display, S)},
       {<<"currencySign">>, maps:get(currency_sign, S)}, {<<"unit">>, maps:get(unit, S)},
       {<<"unitDisplay">>, maps:get(unit_display, S)}
       | buoy_ref_intl_number:digit_resolved(Digits)]
      ++ [{<<"useGrouping">>, maps:get(use_grouping, S)}, {<<"notation">>, maps:get(notation, S)},
          {<<"compactDisplay">>, maps:get(compact_display, S)}, {<<"signDisplay">>, maps:get(sign_display, S)},
          {<<"roundingIncrement">>, maps:get(rounding_increment, Digits)}, {<<"roundingMode">>, maps:get(rounding_mode, Digits)},
          {<<"roundingPriority">>, maps:get(rounding_priority, Digits)},
          {<<"trailingZeroDisplay">>, maps:get(trailing_zero_display, Digits)}]);
method(<<"Intl.NumberFormat.prototype">>, <<"formatToParts">>, This, Args) ->
    NF = slots_of(This, <<"formatToParts">>),
    parts_array(partition(NF, buoy_ref_intl_number:to_intl_mv(arg(1, Args))), none);
method(<<"Intl.NumberFormat.prototype">>, <<"formatRange">>, This, Args) ->
    NF = slots_of(This, <<"formatRange">>),
    {X, Y} = range_args(Args),
    text(range_parts(NF, X, Y));
method(<<"Intl.NumberFormat.prototype">>, <<"formatRangeToParts">>, This, Args) ->
    NF = slots_of(This, <<"formatRangeToParts">>),
    {X, Y} = range_args(Args),
    parts_array(range_parts(NF, X, Y), source).

range_args(Args) ->
    (arg(1, Args) =:= undefined orelse arg(2, Args) =:= undefined) andalso
        buoy_ref:type_error(<<"start and end are required">>),
    X = buoy_ref_intl_number:to_intl_mv(arg(1, Args)),
    Y = buoy_ref_intl_number:to_intl_mv(arg(2, Args)),
    (X =:= nan orelse Y =:= nan) andalso buoy_ref_intl:range_error(<<"Invalid number range">>),
    {X, Y}.

%% UnwrapNumberFormat, then the instance.
unwrap(This, Name) ->
    ?IS_OBJECT(This) orelse incompatible(Name),
    case buoy_heap:class_of(This) of
        intl_number_format -> This;
        _ ->
            Constructor = buoy_ref_realm:current(constructor()),
            case buoy_ref_function:ordinary_has_instance(Constructor, This) of
                true ->
                    NF = buoy_ref:get(This, fallback_symbol()),
                    (?IS_OBJECT(NF) andalso buoy_heap:class_of(NF) =:= intl_number_format) orelse incompatible(Name),
                    NF;
                false -> incompatible(Name)
            end
    end.

slots_of(This, Name) ->
    (?IS_OBJECT(This) andalso buoy_heap:class_of(This) =:= intl_number_format) orelse incompatible(Name),
    This.

-spec incompatible(binary()) -> no_return().
incompatible(Name) ->
    buoy_ref:type_error(buoy_ref_string:concat([<<"Method Intl.NumberFormat.prototype.">>, Name,
                                                <<" called on incompatible receiver">>])).

%% get Intl.NumberFormat.prototype.format: one bound function per object.
bound_format(This) ->
    NF = unwrap(This, <<"format">>),
    case maps:get(bound, buoy_heap:slots(NF)) of
        undefined ->
            F = buoy_heap:function(fun(_, Args) -> text(partition(NF, buoy_ref_intl_number:to_intl_mv(arg(1, Args)))) end,
                                   <<>>, 1, #{}),
            buoy_heap:set_slots(NF, (buoy_heap:slots(NF))#{bound => F}),
            F;
        F -> F
    end.

%% The string of Value in a new NumberFormat of Locales and Options, as
%% Number.prototype.toLocaleString and BigInt.prototype.toLocaleString make it.
-spec format_value(term(), term(), term()) -> term().
format_value(Locales, Options, Value) ->
    Constructor = buoy_ref_realm:current(constructor()),
    text(partition(construct(Constructor, [Locales, Options]), buoy_ref_intl_number:to_intl_mv(Value))).

%% The string of an Intl mathematical value in a NumberFormat.
-spec format_mv(term(), buoy_ref_intl_number:mv()) -> term().
format_mv(NF, X) -> text(partition(NF, X)).

%% A NumberFormat of Locales and Options, for the other Intl objects.
-spec number_format(term(), term()) -> term().
number_format(Locales, Options) ->
    Constructor = buoy_ref_realm:current(constructor()),
    construct(Constructor, [Locales, Options]).

%%% The constructor

construct(NewTarget, Args) ->
    Proto = buoy_ref_realm:proto_for(NewTarget, ?PROTO),
    Requested = buoy_ref_intl:canonicalize_locale_list(arg(1, Args)),
    Options = buoy_ref_intl:coerce_options(arg(2, Args)),
    Resolved = buoy_ref_intl:resolve_options(Requested, Options, [{<<"nu">>, <<"numberingSystem">>, string, empty}],
                                             [<<"nu">>], fun locale_data/2),
    Unit = unit_options(Options),
    Style = maps:get(style, Unit),
    Notation = get_option(Options, <<"notation">>, string,
                          [<<"standard">>, <<"scientific">>, <<"engineering">>, <<"compact">>], <<"standard">>),
    {Mnfd, Mxfd} = case {Style, Notation} of
        {<<"currency">>, <<"standard">>} ->
            CurrencyDigits = buoy_intl_cldr:currency_digits(maps:get(currency, Unit)),
            {CurrencyDigits, CurrencyDigits};
        {<<"percent">>, _} -> {0, 0};
        _ -> {0, 3}
    end,
    Digits = buoy_ref_intl_number:digit_options(Options, Mnfd, Mxfd, Notation),
    CompactDisplay = get_option(Options, <<"compactDisplay">>, string, [<<"short">>, <<"long">>], <<"short">>),
    DefaultGrouping = case Notation of
        <<"compact">> -> <<"min2">>;
        _ -> <<"auto">>
    end,
    UseGrouping = grouping_option(Options, DefaultGrouping),
    SignDisplay = get_option(Options, <<"signDisplay">>, string,
                             [<<"auto">>, <<"never">>, <<"always">>, <<"exceptZero">>, <<"negative">>], <<"auto">>),
    buoy_heap:new_exotic(intl_number_format, Proto,
                         Unit#{locale => maps:get(locale, Resolved), data_locale => maps:get(data_locale, Resolved),
                               nu => maps:get(<<"nu">>, Resolved), digits => Digits, notation => Notation,
                               compact_display => case Notation of <<"compact">> -> CompactDisplay; _ -> undefined end,
                               use_grouping => UseGrouping, sign_display => SignDisplay, bound => undefined,
                               formatter => undefined}).

%% [[LocaleData]].[[<locale>]].[[nu]]: the default numbering system of the
%% locale first, then each numbering system with simple digits.
-spec locale_data(binary(), binary()) -> [binary()].
locale_data(Locale, <<"nu">>) ->
    Default = buoy_intl_cldr:get(buoy_ref_intl:base_name(Locale), [?NE, <<"default">>], <<"latn">>),
    [Default | [Nu || Nu <- buoy_ref_intl_data:numbering_systems(), Nu =/= Default]].

%% SetNumberFormatUnitOptions.
unit_options(Options) ->
    Style = get_option(Options, <<"style">>, string, [<<"decimal">>, <<"percent">>, <<"currency">>, <<"unit">>], <<"decimal">>),
    Currency = get_option(Options, <<"currency">>, string, empty, undefined),
    case Currency of
        undefined when Style =:= <<"currency">> -> buoy_ref:type_error(<<"Currency code is required with currency style.">>);
        undefined -> ok;
        _ -> is_currency_code(Currency) orelse buoy_ref_intl:range_error(buoy_ref_string:concat([<<"Invalid currency code : ">>, Currency]))
    end,
    CurrencyDisplay = get_option(Options, <<"currencyDisplay">>, string, [<<"code">>, <<"symbol">>, <<"narrowSymbol">>, <<"name">>], <<"symbol">>),
    CurrencySign = get_option(Options, <<"currencySign">>, string, [<<"standard">>, <<"accounting">>], <<"standard">>),
    Unit = get_option(Options, <<"unit">>, string, empty, undefined),
    case Unit of
        undefined when Style =:= <<"unit">> -> buoy_ref:type_error(<<"Unit is required with unit style.">>);
        undefined -> ok;
        _ -> is_unit(Unit) orelse buoy_ref_intl:range_error(buoy_ref_string:concat([<<"Invalid unit argument for Intl.NumberFormat() '">>, Unit, <<"'">>]))
    end,
    UnitDisplay = get_option(Options, <<"unitDisplay">>, string, [<<"short">>, <<"narrow">>, <<"long">>], <<"short">>),
    Base = #{style => Style, currency => undefined, currency_display => undefined, currency_sign => undefined,
             unit => undefined, unit_display => undefined},
    case Style of
        <<"currency">> ->
            Base#{currency => string:uppercase(Currency), currency_display => CurrencyDisplay, currency_sign => CurrencySign};
        <<"unit">> -> Base#{unit => Unit, unit_display => UnitDisplay};
        _ -> Base
    end.

%% IsWellFormedCurrencyCode.
is_currency_code(Code) ->
    Units = buoy_ref_string:units(Code),
    length(Units) =:= 3 andalso lists:all(fun(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) end, Units).

%% IsWellFormedUnitIdentifier: a sanctioned unit, or one per another.
is_unit(Unit) when not is_binary(Unit) -> false;
is_unit(Unit) ->
    Sanctioned = buoy_ref_intl_data:units(),
    lists:member(Unit, Sanctioned) orelse
        case binary:split(Unit, <<"-per-">>) of
            [A, B] -> lists:member(A, Sanctioned) andalso lists:member(B, Sanctioned);
            _ -> false
        end.

%% GetBooleanOrStringNumberFormatOption for useGrouping.
grouping_option(Options, Default) ->
    case buoy_ref:get(Options, <<"useGrouping">>) of
        undefined -> Default;
        true -> <<"always">>;
        Value ->
            case buoy_ref:truthy(Value) of
                false -> false;
                true ->
                    case buoy_ref:to_string(Value) of
                        V when V =:= <<"min2">>; V =:= <<"auto">>; V =:= <<"always">> -> V;
                        V when V =:= <<"true">>; V =:= <<"false">> -> Default;
                        V -> buoy_ref_intl:range_error(buoy_ref_string:concat([<<"Value ">>, V,
                                                                               <<" out of range for Intl.NumberFormat options property useGrouping">>]))
                    end
            end
    end.

%%% Parts

%% A list of {Type, Text} parts, Text a list of code points, as a string.
text(Parts) ->
    buoy_ref_string:from_code_points(lists:append([element(2, P) || P <- Parts])).

%% The parts as an array of {type, value} objects, with source for a range.
parts_array(Parts, Source) ->
    buoy_heap:new_array([buoy_heap:object(?OBJECT_PROTO,
                                          [{<<"type">>, type_name(Type)}, {<<"value">>, buoy_ref_string:from_code_points(T)}]
                                          ++ case Source of
                                                 source -> [{<<"source">>, atom_to_binary(S)}];
                                                 none -> []
                                             end)
                         || {Type, T, S} <- with_source(Parts)]).

with_source(Parts) -> [case P of {Type, T} -> {Type, T, shared}; {Type, T, S} -> {Type, T, S} end || P <- Parts].

type_name(Type) -> atom_to_binary(Type).

%%% The formatter of an object: its locale data, made once

formatter(NF) ->
    Slots = buoy_heap:slots(NF),
    case maps:get(formatter, Slots) of
        undefined ->
            F = make_formatter(Slots),
            buoy_heap:set_slots(NF, (buoy_heap:slots(NF))#{formatter => F}),
            F;
        F -> F
    end.

make_formatter(S) ->
    Locale = buoy_ref_intl:base_name(maps:get(data_locale, S)),
    Nu = maps:get(nu, S),
    Style = maps:get(style, S),
    Notation = maps:get(notation, S),
    Unit = case Style of
        <<"unit">> -> maps:get(unit, S);
        <<"percent">> when Notation =:= <<"compact">> -> <<"percent">>;
        _ -> undefined
    end,
    Width = case Style of
        <<"unit">> -> maps:get(unit_display, S);
        _ -> <<"short">>
    end,
    %% ICU formats percent with the percent pattern unless a CLDR unit
    %% pattern is needed: in long form or with compact notation.
    UnitPercent = Unit =:= <<"percent">> andalso Width =/= <<"long">> andalso Notation =/= <<"compact">>,
    CldrUnit = Unit =/= undefined andalso not UnitPercent,
    CurrencyDisplay = maps:get(currency_display, S),
    PatternKind = if
        CldrUnit -> decimal;
        UnitPercent; Style =:= <<"percent">> -> percent;
        Style =:= <<"currency">>, CurrencyDisplay =:= <<"name">> -> decimal;
        Style =:= <<"currency">> ->
            case maps:get(currency_sign, S) of
                <<"accounting">> -> accounting;
                _ -> currency
            end;
        true -> decimal
    end,
    Symbols = symbols(Locale, Nu),
    Pattern = parse_pattern(nu_get(Locale, Nu, [<<"patterns">>, pattern_resource(PatternKind)], <<"#,##0.###">>)),
    Plural = fun(Text) -> buoy_ref_intl_plural_rules:select(<<"cardinal">>, Locale, Text, 0) end,
    #{locale => Locale, nu => Nu, symbols => Symbols, digits => buoy_intl_cldr:numbering_digits(Nu),
      style => Style, digit_options => maps:get(digits, S), notation => Notation,
      sign_display => maps:get(sign_display, S), currency_sign => maps:get(currency_sign, S),
      currency => maps:get(currency, S), currency_display => CurrencyDisplay,
      unit_percent => UnitPercent, scale => case Style of <<"percent">> -> 2; _ -> 0 end,
      pattern => Pattern, grouping => grouping(Pattern, maps:get(use_grouping, S), Locale),
      compact => compact_data(Locale, Nu, maps:get(compact_display, S), Style =:= <<"currency">> andalso CurrencyDisplay =/= <<"name">>),
      outer => outer(Locale, Nu, S, CldrUnit, Unit, Width), plural => Plural,
      spacing => spacing(Locale), misc => nu_table(Locale, Nu, [<<"miscPatterns">>])}.

pattern_resource(decimal) -> <<"decimalFormat">>;
pattern_resource(percent) -> <<"percentFormat">>;
pattern_resource(currency) -> <<"currencyFormat">>;
pattern_resource(accounting) -> <<"accountingFormat">>.

%% A resource of a numbering system, else of latn, as ICU falls back.
nu_get(Locale, Nu, Rest, Default) ->
    case buoy_intl_cldr:get(Locale, [?NE, Nu | Rest]) of
        undefined -> buoy_intl_cldr:get(Locale, [?NE, <<"latn">> | Rest], Default);
        Value -> Value
    end.

%% A table of a numbering system over that of latn.
nu_table(Locale, Nu, Rest) ->
    Latn = buoy_intl_cldr:table(Locale, [?NE, <<"latn">> | Rest]),
    case Nu of
        <<"latn">> -> Latn;
        _ -> maps:merge(Latn, buoy_intl_cldr:table(Locale, [?NE, Nu | Rest]))
    end.

%% The number symbols of a numbering system, each missing one from latn.
symbols(Locale, Nu) ->
    maps:map(fun(_, V) -> unicode:characters_to_list(V) end, nu_table(Locale, Nu, [<<"symbols">>])).

%% The currency spacing of the locale: {Before, After}, each {CurrencyMatch,
%% SurroundingMatch, Insert}.
spacing(Locale) ->
    case buoy_intl_cldr:table(Locale, [<<"currencySpacing">>]) of
        #{<<"beforeCurrency">> := Before, <<"afterCurrency">> := After} -> {spacing_side(Before), spacing_side(After)};
        _ -> none
    end.

spacing_side(Side) ->
    {maps:get(<<"currencyMatch">>, Side), maps:get(<<"surroundingMatch">>, Side), maps:get(<<"insertBetween">>, Side)}.

symbol(F, Name) ->
    maps:get(Name, maps:get(symbols, F), default_symbol(Name)).

default_symbol(<<"decimal">>) -> ".";
default_symbol(<<"group">>) -> ",";
default_symbol(<<"minusSign">>) -> "-";
default_symbol(<<"plusSign">>) -> "+";
default_symbol(<<"percentSign">>) -> "%";
default_symbol(<<"perMille">>) -> [16#2030];
default_symbol(<<"approximatelySign">>) -> "~";
default_symbol(<<"exponential">>) -> "E";
default_symbol(<<"infinity">>) -> [16#221E];
default_symbol(<<"nan">>) -> "NaN";
default_symbol(_) -> "".

%% The compact patterns, [{Type, Count, Pattern}], or [] without compact
%% notation. ICU reads the long patterns, else the short ones.
compact_data(_Locale, _Nu, undefined, _Currency) -> [];
compact_data(Locale, Nu, Display, Currency) ->
    Type = case Currency of
        true -> currency;
        false -> decimal
    end,
    Width = case Type of
        currency -> short;
        decimal -> binary_to_atom(Display)
    end,
    Resource = case Type of decimal -> <<"decimalFormat">>; currency -> <<"currencyFormat">> end,
    Lookup = fun(W) ->
                     Table = case W of long -> <<"patternsLong">>; short -> <<"patternsShort">> end,
                     case buoy_intl_cldr:table(Locale, [?NE, Nu, Table, Resource]) of
                         Empty when map_size(Empty) =:= 0 -> buoy_intl_cldr:table(Locale, [?NE, <<"latn">>, Table, Resource]);
                         Found -> Found
                     end
             end,
    Patterns = case Lookup(Width) of
        Empty when map_size(Empty) =:= 0 -> Lookup(short);
        Found -> Found
    end,
    lists:sort([{binary_to_integer(T), Count, P} || {T, Counts} <- maps:to_list(Patterns), is_map(Counts),
                                                    {Count, P} <- maps:to_list(Counts)]).

%%% The outer modifier: unit and currency long names

%% {unit, #{Count => Pattern}} for a unit, {currency_name, #{Count => Pattern}}
%% for the currency name style, else none. Each pattern has {0} for the number.
outer(Locale, _Nu, _S, true, Unit, Width) ->
    {unit, unit_patterns(Locale, Unit, binary_to_atom(Width))};
outer(Locale, _Nu, S, false, _Unit, _Width) ->
    case {maps:get(style, S), maps:get(currency_display, S)} of
        {<<"currency">>, <<"name">>} ->
            Code = maps:get(currency, S),
            Plurals = buoy_intl_cldr:table(Locale, [<<"CurrencyPlurals">>, Code]),
            LongName = case buoy_intl_cldr:get(Locale, [<<"Currencies">>, Code]) of
                [_, Long | _] -> Long;
                _ -> Code
            end,
            Patterns = case buoy_intl_cldr:table(Locale, [<<"CurrencyUnitPatterns">>]) of
                Empty when map_size(Empty) =:= 0 -> #{<<"other">> => <<"{0} {1}">>};
                Found -> Found
            end,
            Name = fun(Count) -> maps:get(Count, Plurals, maps:get(<<"other">>, Plurals, LongName)) end,
            {currency_name, maps:map(fun(Count, P) -> {unicode:characters_to_list(P), unicode:characters_to_list(Name(Count))} end,
                                     Patterns)};
        _ -> none
    end.

%% The patterns of a unit by plural form: the unit of CLDR, or for X-per-Y
%% the patterns of X in the per pattern of Y, else in the compound per
%% pattern with the name of Y (ICU's LongNameHandler::forArbitraryUnit).
unit_patterns(Locale, Unit, Width) ->
    case plural_patterns(unit_data(Locale, Unit, Width)) of
        Own when map_size(Own) > 0 -> maps:map(fun(_, P) -> unicode:characters_to_list(P) end, Own);
        _ ->
            [Numerator, Denominator] = binary:split(Unit, <<"-per-">>),
            Patterns = plural_patterns(unit_data(Locale, Numerator, Width)),
            Den = unit_data(Locale, Denominator, Width),
            Per = case Den of
                #{<<"per">> := P} -> unicode:characters_to_list(P);
                _ ->
                    One = unicode:characters_to_list(maps:get(<<"one">>, Den, maps:get(<<"other">>, Den, <<"{0}">>))),
                    Name = string:trim(string:replace(One, "{0}", "", all), both, [$\s, 16#A0]),
                    Compound = unicode:characters_to_list(buoy_intl_cldr:get(Locale, [units_table(Width), <<"compound">>, <<"per">>],
                                                                            <<"{0}/{1}">>)),
                    lists:flatten(string:replace(Compound, "{1}", Name, all))
            end,
            maps:map(fun(_, P) -> lists:flatten(string:replace(Per, "{0}", unicode:characters_to_list(P), all)) end, Patterns)
    end.

%% The table of a unit in ICU's unit data: its plural patterns, its per
%% pattern, and its display name.
unit_data(Locale, Unit, Width) ->
    case unit_category(Unit) of
        undefined -> #{};
        Category -> buoy_intl_cldr:table(Locale, [units_table(Width), Category, Unit])
    end.

units_table(long) -> <<"units">>;
units_table(short) -> <<"unitsShort">>;
units_table(narrow) -> <<"unitsNarrow">>.

plural_patterns(Table) ->
    maps:with([<<"zero">>, <<"one">>, <<"two">>, <<"few">>, <<"many">>, <<"other">>], Table).

%% The category of a unit in root's unit data, such as length for meter.
unit_category(Unit) ->
    Categories = case persistent_term:get({?MODULE, unit_categories}, undefined) of
        undefined ->
            Made = maps:from_list([{U, C} || {C, Units} <- maps:to_list(buoy_intl_cldr:table(<<"root">>, [<<"units">>])),
                                            is_map(Units), U <- maps:keys(Units)]),
            persistent_term:put({?MODULE, unit_categories}, Made),
            Made;
        Made -> Made
    end,
    maps:get(Unit, Categories, undefined).

%%% Patterns

%% A CLDR number pattern parsed as ICU's PatternParser does: the affixes of
%% the positive and negative subpatterns, as pattern text with their quotes,
%% and the grouping sizes of the positive body.
parse_pattern(Text) ->
    Chars = unicode:characters_to_list(Text),
    {Positive, Negative} = split_subpatterns(Chars, [], false),
    {PPrefix, Body, PSuffix} = subpattern(Positive),
    Neg = case Negative of
        none -> none;
        _ ->
            {NPrefix, _, NSuffix} = subpattern(Negative),
            {NPrefix, NSuffix}
    end,
    #{prefix => PPrefix, suffix => PSuffix, negative => Neg, sizes => grouping_sizes(Body),
      has_currency => lists:member($¤, PPrefix ++ PSuffix)}.

split_subpatterns([], Acc, _) -> {lists:reverse(Acc), none};
split_subpatterns([$' | Rest], Acc, Quoted) -> split_subpatterns(Rest, [$' | Acc], not Quoted);
split_subpatterns([$; | Rest], Acc, false) -> {lists:reverse(Acc), Rest};
split_subpatterns([C | Rest], Acc, Quoted) -> split_subpatterns(Rest, [C | Acc], Quoted).

subpattern(Chars) ->
    {Prefix, Rest} = take_affix(Chars, [], false),
    {Body, Suffix} = lists:splitwith(fun is_body_char/1, Rest),
    {Prefix, Body, Suffix}.

take_affix([], Acc, _) -> {lists:reverse(Acc), []};
take_affix([$' | Rest], Acc, Quoted) -> take_affix(Rest, [$' | Acc], not Quoted);
take_affix([C | _] = All, Acc, false) when C =:= $#; C =:= $0; C =:= $@; C =:= $,; C =:= $.; C >= $1, C =< $9 ->
    {lists:reverse(Acc), All};
take_affix([C | Rest], Acc, Quoted) -> take_affix(Rest, [C | Acc], Quoted).

is_body_char(C) -> lists:member(C, "#0123456789@,.E+").

%% {G1, G2, G3}: the sizes of the last three groups of the integer digits,
%% -1 for a group that is not there, as ICU's groupingSizes.
grouping_sizes(Body) ->
    Integer = lists:takewhile(fun(C) -> C =/= $. andalso C =/= $E end, Body),
    Groups = lists:reverse([length(G) || G <- string:split(Integer, ",", all)]),
    case Groups of
        [G1] -> {G1, -1, -1};
        [G1, G2] -> {G1, G2, -1};
        [G1, G2, G3 | _] -> {G1, G2, G3}
    end.

%% ICU's Grouper for the strategy: {Primary, Secondary, MinGrouping}, with
%% a primary of -1 for no grouping.
grouping(_Pattern, false, _Locale) -> {-1, -1, 0};
grouping(#{sizes := {G1, G2, G3}}, Strategy, Locale) ->
    LocaleMin = binary_to_integer(buoy_intl_cldr:get(Locale, [?NE, <<"minimumGroupingDigits">>], <<"1">>)),
    Min = case Strategy of
        <<"auto">> -> LocaleMin;
        <<"min2">> -> max(2, LocaleMin);
        <<"always">> -> 1
    end,
    Primary = case G2 of
        -1 when Strategy =:= <<"always">> -> 3;
        -1 -> -1;
        _ -> G1
    end,
    Secondary = case G3 of
        -1 -> Primary;
        _ -> G2
    end,
    {Primary, Secondary, Min}.

%%% PartitionNumberPattern

%% PartitionNumberPattern: [{Type, Text}] with Text a list of code points.
-spec partition(term(), buoy_ref_intl_number:mv()) -> [{atom(), [char()]}].
partition(NF, X) ->
    finish(format_parts(formatter(NF), X)).

%% The parts of X, before the whitespace and bidi marks at the edges of each
%% field go to the literal parts, as ICU's FormattedValue trims them.
format_parts(F, X) ->
    {Number, Rounded, Exponent, Plain} = number(F, X),
    Inner = inner(F, X, Exponent),
    {Prefix, Suffix} = middle(F, X, Rounded, Exponent, Number ++ Inner),
    wrap_outer(F, Plain, Prefix ++ Number ++ Inner ++ Suffix).

%% The number parts with their rounding: {Parts, Rounded, Exponent, Plain},
%% where Plain is the formatted string of the unscaled number, whose plural
%% picks the long names.
number(F, Infinite) when Infinite =:= nan; Infinite =:= infinity; Infinite =:= neg_infinity ->
    Text = case Infinite of
        nan -> symbol(F, <<"nan">>);
        _ -> symbol(F, <<"infinity">>)
    end,
    Type = case Infinite of
        nan -> nan;
        _ -> infinity
    end,
    {[{Type, Text}], Infinite, 0, none};
number(F, {Negative, C, E}) ->
    X = {Negative, C, E + maps:get(scale, F)},
    Digits = maps:get(digit_options, F),
    Exponent = exponent(F, X),
    {Rounded, Text} = buoy_ref_intl_number:format_to_string(Digits, scale(X, -Exponent)),
    {_, Plain} = case Exponent of
        0 -> {Rounded, Text};
        _ -> buoy_ref_intl_number:format_to_string(Digits, X)
    end,
    {digit_parts(F, Text), Rounded, Exponent, Plain}.

scale({Negative, C, E}, By) -> {Negative, C, E + By}.

%% ComputeExponent.
exponent(F, {_, 0, _}) when is_map(F) -> 0;
exponent(F, {_, C, E} = X) ->
    case maps:get(notation, F) of
        <<"standard">> -> 0;
        _ ->
            Magnitude = length(integer_to_list(C)) - 1 + E,
            Exponent = exponent_for(F, Magnitude),
            {{_, RC, RE}, _} = buoy_ref_intl_number:format_to_string(maps:get(digit_options, F), scale(X, -Exponent)),
            case RC of
                0 -> Exponent;
                _ ->
                    case length(integer_to_list(RC)) - 1 + RE =:= Magnitude - Exponent of
                        true -> Exponent;
                        false -> exponent_for(F, Magnitude + 1)
                    end
            end
    end.

%% ComputeExponentForMagnitude.
exponent_for(F, Magnitude) ->
    case maps:get(notation, F) of
        <<"scientific">> -> Magnitude;
        <<"engineering">> -> (Magnitude - ((Magnitude rem 3) + 3) rem 3);
        <<"compact">> -> compact_exponent(maps:get(compact, F), Magnitude)
    end.

%% The exponent of the compact patterns for the magnitude: the type of the
%% largest pattern at or below it, less the zeros of the pattern but one.
compact_exponent(_Patterns, Magnitude) when Magnitude < 3 -> 0;
compact_exponent(Patterns, Magnitude) ->
    case [{T, P} || {T, _, P} <- Patterns, type_magnitude(T) =< Magnitude] of
        [] -> 0;
        Below ->
            {Type, Pattern} = lists:last(Below),
            case Pattern =/= <<"0">> andalso zeros(Pattern) of
                Zeros when is_integer(Zeros), Zeros > 0 -> type_magnitude(Type) - Zeros + 1;
                _ -> 0
            end
    end.

type_magnitude(Type) -> length(integer_to_list(Type)) - 1.

zeros(Pattern) -> length([C || C <- unicode:characters_to_list(Pattern), C =:= $0]).

%% The integer, group, decimal, and fraction parts of a formatted string.
digit_parts(F, Text) ->
    {Int, Frac} = case string:split(Text, ".") of
        [I] -> {I, none};
        [I, Fr] -> {I, Fr}
    end,
    IntParts = groups(F, Int),
    Decimal = case Frac of
        none -> [];
        _ ->
            Separator = case maps:get(style, F) of
                <<"currency">> -> maps:get(<<"currencyDecimal">>, maps:get(symbols, F), symbol(F, <<"decimal">>));
                _ -> symbol(F, <<"decimal">>)
            end,
            [{decimal, Separator}, {fraction, localize(F, Frac)}]
    end,
    IntParts ++ Decimal.

groups(F, Int) ->
    {Primary, Secondary, Min} = maps:get(grouping, F),
    Length = length(Int),
    Positions = case Primary > 0 andalso Length - Primary >= Min of
        true -> [P || P <- lists:seq(Primary, Length - 1), (P - Primary) rem Secondary =:= 0];
        false -> []
    end,
    Group = case maps:get(style, F) of
        <<"currency">> -> maps:get(<<"currencyGroup">>, maps:get(symbols, F), symbol(F, <<"group">>));
        _ -> symbol(F, <<"group">>)
    end,
    split_groups(F, Int, lists:reverse(Positions), Length, Group).

%% The integer digits split before each grouping position, counted from the
%% right.
split_groups(F, Int, [], _Length, _Group) -> [{integer, localize(F, Int)}];
split_groups(F, Int, [P | Rest], Length, Group) ->
    {Head, Tail} = lists:split(Length - P, Int),
    [{integer, localize(F, Head)}, {group, Group} | split_groups(F, Tail, Rest, P, Group)].

localize(F, Digits) ->
    case maps:get(digits, F) of
        undefined -> Digits;
        Table -> [lists:nth(D - $0 + 1, Table) || D <- Digits]
    end.

%% The inner modifier: the exponent of scientific and engineering notation.
inner(F, X, Exponent) when is_tuple(X) ->
    case maps:get(notation, F) of
        N when N =:= <<"scientific">>; N =:= <<"engineering">> ->
            Sign = case Exponent < 0 of
                true -> [{exponentMinusSign, symbol(F, <<"minusSign">>)}];
                false -> []
            end,
            [{exponentSeparator, symbol(F, <<"exponential">>)} | Sign] ++ [{exponentInteger, localize(F, integer_to_list(abs(Exponent)))}];
        _ -> []
    end;
inner(_F, _X, _Exponent) -> [].

%%% The middle modifier: the affixes of the pattern

%% {Prefix, Suffix} parts of the pattern, or of the compact pattern that the
%% scaled number takes, with the sign that signDisplay asks for.
middle(F, X, Rounded, Exponent, Body) ->
    {Pattern, Field} = case compact_pattern(F, Rounded, Exponent) of
        none -> {maps:get(pattern, F), literal};
        Compact -> {Compact, compact}
    end,
    SignType = sign_type(maps:get(sign_display, F), maps:get(currency_sign, F), signum(X, Rounded)),
    Prefix = affix_parts(F, affix_text(Pattern, true, SignType, false), Field),
    Suffix = affix_parts(F, affix_text(Pattern, false, SignType, false), Field),
    currency_spacing(F, Prefix, Suffix, Body).

%% The compact pattern of the scaled, rounded number, or none.
compact_pattern(F, Rounded, Exponent) when is_tuple(Rounded) ->
    case maps:get(compact, F) of
        [] -> none;
        Patterns ->
            {_, RC, RE} = Rounded,
            Magnitude = case RC of
                0 -> 0;
                _ -> length(integer_to_list(RC)) - 1 + RE + Exponent
            end,
            case [T || {T, _, _} <- Patterns, type_magnitude(T) =< Magnitude] of
                [] -> none;
                Below ->
                    Type = lists:max(Below),
                    ForType = [{Count, P} || {T, Count, P} <- Patterns, T =:= Type],
                    Scaled = buoy_ref_intl_number:decimal_string(Rounded),
                    Count = case is_integral(Rounded) andalso integer_value(Rounded) of
                        0 -> <<"0">>;
                        1 -> <<"1">>;
                        _ -> none
                    end,
                    Plural = (maps:get(plural, F))(Scaled),
                    Pattern = case lists:keyfind(Count, 1, ForType) of
                        {_, P} -> P;
                        false ->
                            case lists:keyfind(Plural, 1, ForType) of
                                {_, P} -> P;
                                false -> element(2, lists:keyfind(<<"other">>, 1, ForType))
                            end
                    end,
                    case Pattern of
                        <<"0">> -> none;
                        _ -> parse_pattern(Pattern)
                    end
            end
    end;
compact_pattern(_F, _Rounded, _Exponent) -> none.

is_integral({_, _, E}) when E >= 0 -> true;
is_integral({_, C, E}) -> C rem pow10(-E) =:= 0.

integer_value({_, C, E}) when E >= 0 -> C * pow10(E);
integer_value({_, C, E}) -> C div pow10(-E).

pow10(N) -> pow10(N, 1).
pow10(0, Acc) -> Acc;
pow10(N, Acc) -> pow10(N - 1, Acc * 10).

%% The sign of the rounded number: neg, neg_zero, pos_zero, or pos.
signum(nan, _) -> pos_zero;
signum(infinity, _) -> pos;
signum(neg_infinity, _) -> neg;
signum(_X, {Negative, C, _}) ->
    case {Negative, C} of
        {true, 0} -> neg_zero;
        {true, _} -> neg;
        {false, 0} -> pos_zero;
        {false, _} -> pos
    end.

%% PatternStringUtils::resolveSignDisplay: neg, pos, or pos_sign.
sign_type(<<"never">>, _, _) -> pos;
sign_type(<<"auto">>, _, S) when S =:= neg; S =:= neg_zero -> neg;
sign_type(<<"auto">>, _, _) -> pos;
sign_type(<<"always">>, _, S) when S =:= neg; S =:= neg_zero -> neg;
sign_type(<<"always">>, _, _) -> pos_sign;
sign_type(<<"exceptZero">>, _, neg) -> neg;
sign_type(<<"exceptZero">>, _, pos) -> pos_sign;
sign_type(<<"exceptZero">>, _, _) -> pos;
sign_type(<<"negative">>, _, neg) -> neg;
sign_type(<<"negative">>, _, _) -> pos.

%% PatternStringUtils::patternInfoToStringBuilder: the affix as pattern
%% text, with the sign placeholder - in place.
affix_text(Pattern, IsPrefix, SignType, Approximately) ->
    #{prefix := PPrefix, suffix := PSuffix, negative := Negative} = Pattern,
    PositiveHasPlus = has_unquoted($+, PPrefix ++ PSuffix),
    PlusReplacesMinus = SignType =:= pos_sign andalso not PositiveHasPlus,
    NegativeHasMinus = case Negative of
        none -> false;
        {NP, NS} -> has_unquoted($-, NP ++ NS)
    end,
    UseNegative = Negative =/= none andalso
        (SignType =:= neg orelse (NegativeHasMinus andalso (PlusReplacesMinus orelse Approximately))),
    Affix = case {UseNegative, IsPrefix} of
        {true, true} -> element(1, Negative);
        {true, false} -> element(2, Negative);
        {false, true} -> PPrefix;
        {false, false} -> PSuffix
    end,
    PrependSign = IsPrefix andalso not UseNegative andalso
        (SignType =:= neg orelse PlusReplacesMinus orelse Approximately),
    SignSymbols = if
        Approximately, PlusReplacesMinus -> "~+";
        Approximately, SignType =:= neg -> "~-";
        Approximately -> "~";
        PlusReplacesMinus -> "+";
        true -> "-"
    end,
    Chars = case PrependSign of
        true -> [$- | Affix];
        false -> Affix
    end,
    lists:append([case C of $- -> SignSymbols; _ -> [C] end || C <- Chars]).

has_unquoted(Char, Text) -> has_unquoted(Char, Text, false).
has_unquoted(_Char, [], _) -> false;
has_unquoted(Char, [$' | Rest], Quoted) -> has_unquoted(Char, Rest, not Quoted);
has_unquoted(Char, [Char | _], false) -> true;
has_unquoted(Char, [_ | Rest], Quoted) -> has_unquoted(Char, Rest, Quoted).

%% AffixUtils: the parts of affix pattern text, with Field for its literals.
affix_parts(_F, [], _Field) -> [];
affix_parts(F, [$', $' | Rest], Field) -> [{Field, "'"} | affix_parts(F, Rest, Field)];
affix_parts(F, [$' | Rest], Field) ->
    {Quoted, After} = quoted(Rest, []),
    [{Field, Quoted} | affix_parts(F, After, Field)];
affix_parts(F, [$- | Rest], Field) -> [{minusSign, symbol(F, <<"minusSign">>)} | affix_parts(F, Rest, Field)];
affix_parts(F, [$+ | Rest], Field) -> [{plusSign, symbol(F, <<"plusSign">>)} | affix_parts(F, Rest, Field)];
affix_parts(F, [$~ | Rest], Field) -> [{approximatelySign, symbol(F, <<"approximatelySign">>)} | affix_parts(F, Rest, Field)];
affix_parts(F, [$% | Rest], Field) ->
    Type = case maps:get(unit_percent, F) of
        true -> unit;
        false -> percentSign
    end,
    [{Type, symbol(F, <<"percentSign">>)} | affix_parts(F, Rest, Field)];
affix_parts(F, [16#2030 | Rest], Field) -> [{percentSign, symbol(F, <<"perMille">>)} | affix_parts(F, Rest, Field)];
affix_parts(F, [$¤ | _] = All, Field) ->
    {Signs, Rest} = lists:splitwith(fun(C) -> C =:= $¤ end, All),
    [{currency, currency_symbol(F, length(Signs))} | affix_parts(F, Rest, Field)];
affix_parts(F, [C | Rest], Field) -> [{Field, [C]} | affix_parts(F, Rest, Field)].

quoted([], Acc) -> {lists:reverse(Acc), []};
quoted([$', $' | Rest], Acc) -> quoted(Rest, [$' | Acc]);
quoted([$' | Rest], Acc) -> {lists:reverse(Acc), Rest};
quoted([C | Rest], Acc) -> quoted(Rest, [C | Acc]).

%% The currency text of a run of currency signs: one sign follows the
%% currencyDisplay option, two give the ISO code.
currency_symbol(F, Count) ->
    Code = maps:get(currency, F),
    Locale = maps:get(locale, F),
    Symbol = case buoy_intl_cldr:get(Locale, [<<"Currencies">>, Code]) of
        [S | _] -> S;
        _ -> Code
    end,
    Text = case {Count, maps:get(currency_display, F)} of
        {2, _} -> Code;
        {_, <<"code">>} -> Code;
        {_, <<"narrowSymbol">>} -> buoy_intl_cldr:get(Locale, [<<"Currencies%narrow">>, Code], Symbol);
        _ -> Symbol
    end,
    unicode:characters_to_list(Text).

%% CurrencySpacingEnabledModifier: the spacing between a currency symbol and
%% the digits when the symbol's edge is not a symbol or a separator.
currency_spacing(F, Prefix, Suffix, Body) ->
    case maps:get(spacing, F) of
        none -> {Prefix, Suffix};
        {Before, After} ->
            Prefix1 = case {lists:reverse(Prefix), Body} of
                {[{currency, Symbol} | _], [{_, [Lead | _]} | _]} ->
                    spaced(Prefix, lists:last(Symbol), Lead, Before, prefix);
                _ -> Prefix
            end,
            Suffix1 = case {Suffix, lists:reverse(Body)} of
                {[{currency, [Head | _]} | _], [{_, Last} | _]} when Last =/= [] ->
                    spaced(Suffix, Head, lists:last(Last), After, suffix);
                _ -> Suffix
            end,
            {Prefix1, Suffix1}
    end.

spaced(Affix, CurrencyChar, NumberChar, {CurrencyMatch, SurroundingMatch, Insert}, Side) ->
    case in_set(CurrencyMatch, CurrencyChar) andalso in_set(SurroundingMatch, NumberChar) of
        false -> Affix;
        true ->
            case Side of
                prefix -> Affix ++ [{literal, unicode:characters_to_list(Insert)}];
                suffix -> [{literal, unicode:characters_to_list(Insert)} | Affix]
            end
    end.

%% The two sets of CLDR's currency spacing.
in_set(<<"[:digit:]">>, C) -> unicode_util:category(C) =:= {number, decimal};
in_set(<<"[[:^S:]&[:^Z:]]">>, C) ->
    case unicode_util:category(C) of
        {symbol, _} -> false;
        {separator, _} -> false;
        _ -> true
    end;
in_set(_, _) -> false.

%%% The outer modifier

wrap_outer(F, Plain, Parts) ->
    case maps:get(outer, F) of
        none -> Parts;
        {unit, Patterns} ->
            Pattern = plural_pick(F, Patterns, Plain),
            substitute(Pattern, Parts, unit);
        {currency_name, Patterns} ->
            {Pattern, Name} = plural_pick(F, Patterns, Plain),
            substitute(lists:flatten(string:replace(Pattern, "{1}", Name, all)), Parts, currency)
    end.

plural_pick(F, Patterns, Plain) ->
    Plural = case Plain of
        none -> <<"other">>;
        _ -> (maps:get(plural, F))(Plain)
    end,
    maps:get(Plural, Patterns, maps:get(<<"other">>, Patterns, maps:get(<<"one">>, Patterns, "{0}"))).

%% The parts of a long name pattern with the number in place of {0}.
substitute(Pattern, Parts, Field) ->
    case string:split(Pattern, "{0}") of
        [Before, After] -> nonempty(Field, Before) ++ Parts ++ nonempty(Field, After);
        [Only] -> nonempty(Field, Only) ++ Parts
    end.

nonempty(_Field, []) -> [];
nonempty(Field, Text) -> [{Field, Text}].

%%% Trimming

%% The parts as ICU's FormattedValue gives them to V8: each field but the
%% grouping separator without the ignorables at its edges, which become
%% literals, and each run of literals one part.
finish(Parts) ->
    merge([P || Part <- runs(Parts), P <- trim(Part), element(2, P) =/= []]).

%% Adjacent parts of one field as one part, as ICU's spans of a field are.
runs([{Type, A}, {Type, B} | Rest]) -> runs([{Type, A ++ B} | Rest]);
runs([P | Rest]) -> [P | runs(Rest)];
runs([]) -> [].

trim({Type, Text}) when Type =:= literal; Type =:= group -> [{Type, Text}];
trim({Type, Text}) ->
    {Leading, Rest} = lists:splitwith(fun is_ignorable/1, Text),
    {TrailingR, CoreR} = lists:splitwith(fun is_ignorable/1, lists:reverse(Rest)),
    [{literal, Leading}, {Type, lists:reverse(CoreR)}, {literal, lists:reverse(TrailingR)}].

merge([{literal, A}, {literal, B} | Rest]) -> merge([{literal, A ++ B} | Rest]);
merge([{literal, A, S}, {literal, B, S} | Rest]) -> merge([{literal, A ++ B, S} | Rest]);
merge([P | Rest]) -> [P | merge(Rest)];
merge([]) -> [].

%% [[:Zs:][\u0009][:Bidi_Control:][:Variation_Selector:]].
is_ignorable(C) ->
    C =:= 9 orelse unicode_util:category(C) =:= {separator, space} orelse
        lists:member(C, [16#061C, 16#200E, 16#200F, 16#202A, 16#202B, 16#202C, 16#202D, 16#202E,
                         16#2066, 16#2067, 16#2068, 16#2069, 16#180B, 16#180C, 16#180D, 16#180F]) orelse
        (C >= 16#FE00 andalso C =< 16#FE0F) orelse (C >= 16#E0100 andalso C =< 16#E01EF).

%%% Ranges

%% PartitionNumberRangePattern as ICU's NumberRangeFormatter does it: the
%% approximately sign when both ends format the same, else both numbers
%% around the range pattern, with the affixes that are the same and longer
%% than one code point said once.
range_parts(NF, X, Y) ->
    F = formatter(NF),
    One = format_parts(F, X),
    Two = format_parts(F, Y),
    case text_of(One) =:= text_of(Two) of
        true -> [{T, V, shared} || {T, V} <- finish(approximately(F, X))];
        false -> collapse(F, X, Y)
    end.

text_of(Parts) -> lists:append([element(2, P) || P <- Parts]).

%% FormatApproximately: the number with the approximately sign.
approximately(F, X) ->
    {Number, Rounded, Exponent, Plain} = number(F, X),
    Inner = inner(F, X, Exponent),
    {Pattern, Field} = case compact_pattern(F, Rounded, Exponent) of
        none -> {maps:get(pattern, F), literal};
        Compact -> {Compact, compact}
    end,
    SignType = sign_type(maps:get(sign_display, F), maps:get(currency_sign, F), signum(X, Rounded)),
    Prefix = affix_parts(F, affix_text(Pattern, true, SignType, true), Field),
    Suffix = affix_parts(F, affix_text(Pattern, false, SignType, true), Field),
    {P, S} = currency_spacing(F, Prefix, Suffix, Number ++ Inner),
    wrap_outer(F, Plain, P ++ Number ++ Inner ++ S).

%% NumberRangeFormatterImpl::formatRange with UNUM_RANGE_COLLAPSE_AUTO.
collapse(F, X, Y) ->
    {N1, R1, E1, Plain1} = number(F, X),
    {N2, R2, E2, Plain2} = number(F, Y),
    I1 = inner(F, X, E1),
    I2 = inner(F, Y, E2),
    {P1, S1} = middle(F, X, R1, E1, N1 ++ I1),
    {P2, S2} = middle(F, Y, R2, E2, N2 ++ I2),
    Outer1 = outer_pattern(F, Plain1),
    Outer2 = outer_pattern(F, Plain2),
    CollapseOuter = Outer1 =:= Outer2,
    CollapseMiddle = CollapseOuter andalso {P1, S1} =:= {P2, S2} andalso length(text_of(P1 ++ S1)) > 1,
    RepeatInner = I1 =/= [],
    RepeatMiddle = not CollapseMiddle andalso text_of(P1 ++ S1) =/= [],
    RepeatOuter = not CollapseOuter andalso Outer1 =/= none,
    Separator = range_separator(F, RepeatInner orelse RepeatMiddle orelse RepeatOuter),
    {Start, End} = case CollapseMiddle of
        true -> {N1 ++ I1, N2 ++ I2};
        false -> {P1 ++ N1 ++ I1 ++ S1, P2 ++ N2 ++ I2 ++ S2}
    end,
    {Prefix, Suffix} = case CollapseMiddle of
        true -> {P1, S1};
        false -> {[], []}
    end,
    {Start1, End1} = case CollapseOuter of
        true -> {Start, End};
        false -> {wrap_outer(F, Plain1, Start), wrap_outer(F, Plain2, End)}
    end,
    Inner = [{T, V, shared} || {T, V} <- finish(Prefix)]
        ++ [{T, V, startRange} || {T, V} <- finish(Start1)]
        ++ [{literal, Separator, shared}]
        ++ [{T, V, endRange} || {T, V} <- finish(End1)]
        ++ [{T, V, shared} || {T, V} <- finish(Suffix)],
    case CollapseOuter of
        true ->
            Plural = range_plural(F, Plain1, Plain2),
            outer_range(F, Plural, Inner);
        false -> merge(Inner)
    end.

%% The long name pattern of a formatted number, or none.
outer_pattern(F, Plain) ->
    case maps:get(outer, F) of
        none -> none;
        {_, Patterns} -> plural_pick(F, Patterns, Plain)
    end.

%% The plural form of a range for its long name, from CLDR's plural ranges.
range_plural(F, Plain1, Plain2) ->
    Locale = maps:get(locale, F),
    Plural = fun(none) -> <<"other">>; (Plain) -> buoy_ref_intl_plural_rules:select(<<"cardinal">>, Locale, Plain, 0) end,
    Start = Plural(Plain1),
    End = Plural(Plain2),
    buoy_ref_intl_plural_rules:select_range(<<"cardinal">>, Locale, Start, End).

outer_range(F, Plural, Inner) ->
    case maps:get(outer, F) of
        none -> merge(Inner);
        {unit, Patterns} ->
            Pattern = maps:get(Plural, Patterns, maps:get(<<"other">>, Patterns, "{0}")),
            merge(range_substitute(Pattern, Inner, unit));
        {currency_name, Patterns} ->
            {Pattern, Name} = maps:get(Plural, Patterns, maps:get(<<"other">>, Patterns)),
            merge(range_substitute(lists:flatten(string:replace(Pattern, "{1}", Name, all)), Inner, currency))
    end.

range_substitute(Pattern, Inner, Field) ->
    [{T, V, shared} || {T, V} <- finish(case string:split(Pattern, "{0}") of
                                             [Before, _] -> nonempty(Field, Before);
                                             [Only] -> nonempty(Field, Only)
                                         end)]
    ++ Inner
    ++ [{T, V, shared} || {T, V} <- finish(case string:split(Pattern, "{0}") of
                                             [_, After] -> nonempty(Field, After);
                                             [_] -> []
                                         end)].

%% The text between the two numbers: the range pattern of the locale, with
%% a space on each side when an affix repeats and the pattern has none.
range_separator(F, Spaced) ->
    Pattern = unicode:characters_to_list(maps:get(<<"range">>, maps:get(misc, F), <<"{0}–"/utf8, "{1}">>)),
    [_, Rest] = string:split(Pattern, "{0}"),
    [Infix, _] = string:split(Rest, "{1}"),
    case Spaced of
        false -> Infix;
        true ->
            Lead = case is_pattern_space(hd(Infix)) of
                true -> [];
                false -> " "
            end,
            Trail = case is_pattern_space(lists:last(Infix)) of
                true -> [];
                false -> " "
            end,
            Lead ++ Infix ++ Trail
    end.

is_pattern_space(C) ->
    (C >= 9 andalso C =< 13) orelse C =:= 32 orelse C =:= 16#85 orelse C =:= 16#200E orelse C =:= 16#200F
        orelse C =:= 16#2028 orelse C =:= 16#2029.
