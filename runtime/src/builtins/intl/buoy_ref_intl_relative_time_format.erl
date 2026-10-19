%% Intl.RelativeTimeFormat (ECMA-402 section 18): an object of the class
%% intl_relative_time_format whose slots hold the resolved options and the
%% NumberFormat of its numbers. The patterns come from the fields of ICU's
%% data (buoy_intl_cldr), and the number is the magnitude of the value, as
%% ICU's RelativeDateTimeFormatter writes it for V8.
-module(buoy_ref_intl_relative_time_format).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, constructor/0]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).
-import(buoy_ref_intl, [get_option/5]).

-define(PROTO, 'Intl.RelativeTimeFormat.prototype').

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{?PROTO, record(object, ?OBJECT_PROTO,
                     ?METHODS(<<"Intl.RelativeTimeFormat.prototype">>, [{<<"format">>, 2}, {<<"formatToParts">>, 2}, {<<"resolvedOptions">>, 0}])
                     ++ [{<<"constructor">>, constructor()}, {?SYM(toStringTag), <<"Intl.RelativeTimeFormat">>, 4}],
                     none)},
     {{builtin, <<"Intl.RelativeTimeFormat">>}, ctor_record(<<"RelativeTimeFormat">>, 0, {'$o', ?PROTO},
                                                            ?METHODS(<<"Intl.RelativeTimeFormat">>, [{<<"supportedLocalesOf">>, 1}]),
                                                            fun construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [].

-spec constructor() -> term().
constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Intl.RelativeTimeFormat">>).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(_Name, _This, _Args) -> buoy_ref:type_error(<<"Constructor Intl.RelativeTimeFormat requires 'new'">>).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Intl.RelativeTimeFormat">>, <<"supportedLocalesOf">>, _This, Args) ->
    buoy_ref_intl:filter_locales(buoy_ref_intl_data:available_locales(),
                                 buoy_ref_intl:canonicalize_locale_list(arg(1, Args)), arg(2, Args));
method(<<"Intl.RelativeTimeFormat.prototype">>, <<"resolvedOptions">>, This, _Args) ->
    S = slots(This, <<"resolvedOptions">>),
    buoy_ref_intl:options_object([{<<"locale">>, maps:get(locale, S)}, {<<"style">>, maps:get(style, S)},
                                  {<<"numeric">>, maps:get(numeric, S)}, {<<"numberingSystem">>, maps:get(nu, S)}]);
method(<<"Intl.RelativeTimeFormat.prototype">>, <<"format">>, This, Args) ->
    S = slots(This, <<"format">>),
    buoy_ref_string:from_code_points(lists:append([element(2, P) || P <- partition(S, Args)]));
method(<<"Intl.RelativeTimeFormat.prototype">>, <<"formatToParts">>, This, Args) ->
    S = slots(This, <<"formatToParts">>),
    buoy_heap:new_array([buoy_heap:object(?OBJECT_PROTO, [{<<"type">>, atom_to_binary(T)},
                                                          {<<"value">>, buoy_ref_string:from_code_points(V)}]
                                                         ++ case P of
                                                                {_, _, Unit} -> [{<<"unit">>, Unit}];
                                                                _ -> []
                                                            end)
                         || P <- partition(S, Args), {T, V} <- [{element(1, P), element(2, P)}]]).

%%% The constructor

construct(NewTarget, Args) ->
    Proto = buoy_ref_realm:proto_for(NewTarget, ?PROTO),
    Requested = buoy_ref_intl:canonicalize_locale_list(arg(1, Args)),
    Options = buoy_ref_intl:coerce_options(arg(2, Args)),
    Resolved = buoy_ref_intl:resolve_options(Requested, Options, [{<<"nu">>, <<"numberingSystem">>, string, empty}],
                                             [<<"nu">>], fun buoy_ref_intl_number_format:locale_data/2),
    Style = get_option(Options, <<"style">>, string, [<<"long">>, <<"short">>, <<"narrow">>], <<"long">>),
    Numeric = get_option(Options, <<"numeric">>, string, [<<"always">>, <<"auto">>], <<"always">>),
    Locale = maps:get(locale, Resolved),
    NFOptions = buoy_heap:object(null, [{<<"numberingSystem">>, maps:get(<<"nu">>, Resolved)}]),
    buoy_heap:new_exotic(intl_relative_time_format, Proto,
                         #{locale => Locale, data_locale => maps:get(data_locale, Resolved), nu => maps:get(<<"nu">>, Resolved),
                           style => Style, numeric => Numeric,
                           number_format => buoy_ref_intl_number_format:number_format(Locale, NFOptions)}).

slots(This, Name) ->
    ?IS_OBJECT(This) andalso buoy_heap:class_of(This) =:= intl_relative_time_format orelse
        buoy_ref:type_error(buoy_ref_string:concat([<<"Method Intl.RelativeTimeFormat.prototype.">>, Name,
                                                    <<" called on incompatible receiver">>])),
    buoy_heap:slots(This).

%%% PartitionRelativeTimePattern

%% The parts of format(value, unit): {Type, Text} for literals and
%% {Type, Text, Unit} for the parts of the number.
partition(S, Args) ->
    Value = buoy_ref:to_number(arg(1, Args)),
    Unit = singular(buoy_ref:to_string(arg(2, Args))),
    is_number(Value) orelse buoy_ref_intl:range_error(<<"Invalid value for relative time">>),
    Locale = buoy_ref_intl:base_name(maps:get(data_locale, S)),
    Field = case maps:get(style, S) of
        <<"long">> -> Unit;
        Style -> <<Unit/binary, "-", Style/binary>>
    end,
    Fields = buoy_intl_cldr:table(Locale, [<<"fields">>, Field]),
    Relative = case maps:get(numeric, S) of
        <<"auto">> -> maps:get(buoy_ref_number:to_string(Value), maps:get(<<"relative">>, Fields, #{}), undefined);
        _ -> undefined
    end,
    case Relative of
        undefined -> numeric(S, Locale, Fields, Value, Unit);
        Text -> [{literal, unicode:characters_to_list(Text)}]
    end.

numeric(S, Locale, Fields, Value, Unit) ->
    Negative = Value < 0 orelse (is_float(Value) andalso <<Value/float>> =:= <<-0.0/float>>),
    Tense = case Negative of
        true -> past;
        false -> future
    end,
    NF = maps:get(number_format, S),
    Magnitude = buoy_ref_intl_number:to_intl_mv(abs(Value)),
    {_, Plain} = buoy_ref_intl_number:format_to_string(maps:get(digits, buoy_heap:slots(NF)), Magnitude),
    Plural = buoy_ref_intl_plural_rules:select(<<"cardinal">>, Locale, Plain, 0),
    Patterns = maps:get(atom_to_binary(Tense), maps:get(<<"relativeTime">>, Fields, #{}), #{}),
    Pattern = unicode:characters_to_list(maps:get(Plural, Patterns, maps:get(<<"other">>, Patterns, <<"{0}">>))),
    Number = [{T, V, Unit} || {T, V} <- buoy_ref_intl_number_format:partition(NF, Magnitude)],
    {Before, After} = case string:split(Pattern, "{0}") of
        [B, A] -> {B, A};
        [Only] -> {Only, ""}
    end,
    [{literal, Before} || Before =/= ""] ++ Number ++ [{literal, After} || After =/= ""].

%% SingularRelativeTimeUnit.
singular(<<"seconds">>) -> <<"second">>;
singular(<<"minutes">>) -> <<"minute">>;
singular(<<"hours">>) -> <<"hour">>;
singular(<<"days">>) -> <<"day">>;
singular(<<"weeks">>) -> <<"week">>;
singular(<<"months">>) -> <<"month">>;
singular(<<"quarters">>) -> <<"quarter">>;
singular(<<"years">>) -> <<"year">>;
singular(Unit) when Unit =:= <<"second">>; Unit =:= <<"minute">>; Unit =:= <<"hour">>; Unit =:= <<"day">>;
                    Unit =:= <<"week">>; Unit =:= <<"month">>; Unit =:= <<"quarter">>; Unit =:= <<"year">> -> Unit;
singular(Unit) -> buoy_ref_intl:range_error(buoy_ref_string:concat([<<"Invalid unit argument for format() '">>, Unit, <<"'">>])).
