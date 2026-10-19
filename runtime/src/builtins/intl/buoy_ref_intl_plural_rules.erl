%% Intl.PluralRules (ECMA-402 section 17): an object of the class
%% intl_plural_rules whose slots hold the resolved options and the digit
%% slots of buoy_ref_intl_number. PluralRuleSelect and PluralRuleSelectRange
%% run the rules of CLDR (buoy_intl_plurals) for every language, as ICU4C
%% does for V8.
-module(buoy_ref_intl_plural_rules).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, constructor/0]).
-export([select/4]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).
-import(buoy_ref_intl, [get_option/5]).

-define(PROTO, 'Intl.PluralRules.prototype').

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{?PROTO, record(object, ?OBJECT_PROTO,
                     ?METHODS(<<"Intl.PluralRules.prototype">>, [{<<"resolvedOptions">>, 0}, {<<"select">>, 1}, {<<"selectRange">>, 2}])
                     ++ [{<<"constructor">>, constructor()}, {?SYM(toStringTag), <<"Intl.PluralRules">>, 4}],
                     none)},
     {{builtin, <<"Intl.PluralRules">>}, ctor_record(<<"PluralRules">>, 0, {'$o', ?PROTO},
                                                     ?METHODS(<<"Intl.PluralRules">>, [{<<"supportedLocalesOf">>, 1}]),
                                                     fun construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [].

-spec constructor() -> term().
constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Intl.PluralRules">>).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(_Name, _This, _Args) -> buoy_ref:type_error(<<"Constructor Intl.PluralRules requires 'new'">>).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Intl.PluralRules">>, <<"supportedLocalesOf">>, _This, Args) ->
    buoy_ref_intl:filter_locales(buoy_ref_intl_data:available_locales(),
                                 buoy_ref_intl:canonicalize_locale_list(arg(1, Args)), arg(2, Args));
method(<<"Intl.PluralRules.prototype">>, <<"resolvedOptions">>, This, _Args) ->
    Slots = slots(This, <<"resolvedOptions">>),
    Digits = maps:get(digits, Slots),
    buoy_ref_intl:options_object(
      [{<<"locale">>, maps:get(locale, Slots)}, {<<"type">>, maps:get(type, Slots)},
       {<<"notation">>, maps:get(notation, Slots)}, {<<"compactDisplay">>, maps:get(compact_display, Slots)}
       | buoy_ref_intl_number:digit_resolved(Digits)]
      ++ [{<<"pluralCategories">>, buoy_heap:new_array(categories(maps:get(type, Slots), maps:get(locale, Slots)))},
          {<<"roundingIncrement">>, maps:get(rounding_increment, Digits)}, {<<"roundingMode">>, maps:get(rounding_mode, Digits)},
          {<<"roundingPriority">>, maps:get(rounding_priority, Digits)},
          {<<"trailingZeroDisplay">>, maps:get(trailing_zero_display, Digits)}]);
method(<<"Intl.PluralRules.prototype">>, <<"select">>, This, Args) ->
    slots(This, <<"select">>),
    element(1, resolve_plural(This, buoy_ref_intl_number:to_intl_mv(arg(1, Args))));
method(<<"Intl.PluralRules.prototype">>, <<"selectRange">>, This, Args) ->
    slots(This, <<"selectRange">>),
    (arg(1, Args) =:= undefined orelse arg(2, Args) =:= undefined) andalso
        buoy_ref:type_error(<<"start and end are required">>),
    X = buoy_ref_intl_number:to_intl_mv(arg(1, Args)),
    Y = buoy_ref_intl_number:to_intl_mv(arg(2, Args)),
    (X =:= nan orelse Y =:= nan) andalso buoy_ref_intl:range_error(<<"Invalid number range">>),
    case {resolve_plural(This, X), resolve_plural(This, Y)} of
        {{Category, Same}, {_, Same}} -> Category;
        {{Start, _}, {End, _}} -> select_range(maps:get(type, buoy_heap:slots(This)), maps:get(locale, buoy_heap:slots(This)), Start, End)
    end.

%%% The constructor

construct(NewTarget, Args) ->
    Proto = buoy_ref_realm:proto_for(NewTarget, ?PROTO),
    Requested = buoy_ref_intl:canonicalize_locale_list(arg(1, Args)),
    Options = buoy_ref_intl:coerce_options(arg(2, Args)),
    Resolved = buoy_ref_intl:resolve_options(Requested, Options, [], [], fun(_, _) -> [] end),
    Type = get_option(Options, <<"type">>, string, [<<"cardinal">>, <<"ordinal">>], <<"cardinal">>),
    Notation = get_option(Options, <<"notation">>, string,
                          [<<"standard">>, <<"scientific">>, <<"engineering">>, <<"compact">>], <<"standard">>),
    CompactDisplay = get_option(Options, <<"compactDisplay">>, string, [<<"short">>, <<"long">>], <<"short">>),
    Digits = buoy_ref_intl_number:digit_options(Options, 0, 3, Notation),
    buoy_heap:new_exotic(intl_plural_rules, Proto,
                         #{locale => maps:get(locale, Resolved), type => Type, notation => Notation,
                           compact_display => case Notation of <<"compact">> -> CompactDisplay; _ -> undefined end,
                           digits => Digits, rules => undefined}).

%%% select

slots(This, Name) ->
    ?IS_OBJECT(This) andalso buoy_heap:class_of(This) =:= intl_plural_rules orelse
        buoy_ref:type_error(buoy_ref_string:concat([<<"Method Intl.PluralRules.prototype.">>, Name,
                                                    <<" called on incompatible receiver">>])),
    buoy_heap:slots(This).

%% ResolvePlural: {Category, FormattedString}.
resolve_plural(_This, Infinite) when Infinite =:= nan; Infinite =:= infinity; Infinite =:= neg_infinity ->
    {<<"other">>, atom_to_list(Infinite)};
resolve_plural(This, X) ->
    Slots = buoy_heap:slots(This),
    {_, Text} = buoy_ref_intl_number:format_to_string(maps:get(digits, Slots), X),
    Exponent = case maps:get(notation, Slots) of
        <<"compact">> -> compact_exponent(maps:get(locale, Slots), maps:get(compact_display, Slots), Text);
        _ -> 0
    end,
    {select(maps:get(type, Slots), maps:get(locale, Slots), Text, Exponent), Text}.

%% The operand c of a number in compact notation.
compact_exponent(Locale, Display, Text) ->
    case string:trim(hd(string:split(Text, ".")), leading, "0") of
        "" -> 0;
        Int -> buoy_native:intl_compact_exponent(buoy_ref_intl:base_name(Locale), Display =:= <<"long">>, length(Int) - 1)
    end.

%% PluralRuleSelect of a decimal string, such as "1.50", whose compact
%% exponent is C: the rules of the locale's base name, or of its longest
%% prefix that CLDR has rules for, else of root.
-spec select(binary(), binary(), string(), non_neg_integer()) -> binary().
select(Type, Locale, Text, C) ->
    {Int, Frac} = case string:split(Text, ".") of
        [I] -> {I, ""};
        [I, F] -> {I, F}
    end,
    Trimmed = string:trim(Frac, trailing, "0"),
    Operands = {list_to_integer(Int), length(Frac), length(Trimmed), digits(Frac), digits(Trimmed), C},
    rule_set(fun(Name) -> buoy_intl_plurals:(binary_to_atom(Type))(Name, Operands) end, Locale, <<"other">>).

digits("") -> 0;
digits(Ds) -> list_to_integer(Ds).

categories(Type, Locale) ->
    rule_set(fun(Name) -> buoy_intl_plurals:categories(binary_to_atom(Type), Name) end, Locale, [<<"other">>]).

%% PluralRuleSelectRange: CLDR's plural ranges hold cardinal categories, and
%% a pair that they do not list is other, as ICU4C answers.
select_range(Type, Locale, Start, End) ->
    case Type of
        <<"cardinal">> -> rule_set(fun(Name) -> buoy_intl_plurals:range(Name, Start, End) end, Locale, <<"other">>);
        <<"ordinal">> -> <<"other">>
    end.

%% The answer of Find for the base name of Locale, then for each shorter
%% prefix, then for root, or Default.
rule_set(Find, Locale, Default) ->
    prefix_rules(Find, buoy_ref_intl:base_name(Locale), Default).

prefix_rules(Find, <<>>, Default) ->
    case Find(<<"root">>) of
        none -> Default;
        Found -> Found
    end;
prefix_rules(Find, Name, Default) ->
    case Find(Name) of
        none ->
            Shorter = case binary:matches(Name, <<"-">>) of
                [] -> <<>>;
                Matches -> binary:part(Name, 0, element(1, lists:last(Matches)))
            end,
            prefix_rules(Find, Shorter, Default);
        Found -> Found
    end.
