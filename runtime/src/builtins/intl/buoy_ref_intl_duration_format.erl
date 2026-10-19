%% Intl.DurationFormat (ECMA-402 section 13): an object of the class
%% intl_duration_format whose slots hold the resolved options. Each unit is
%% a NumberFormat of the unit style, the numeric units share the time
%% separator of the locale, and a ListFormat of the unit type joins them, as
%% the specification lays it out. Values are exact: the fraction of seconds
%% is an Intl mathematical value of nanoseconds.
-module(buoy_ref_intl_duration_format).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, constructor/0]).
-export([format_with/3]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).
-import(buoy_ref_intl, [get_option/5, range_error/1]).

-define(PROTO, 'Intl.DurationFormat.prototype').
%% {Unit, NumberFormat unit, Styles, Digital default} of each unit, largest first.
-define(UNITS, [{<<"years">>, <<"year">>, [<<"long">>, <<"short">>, <<"narrow">>], <<"short">>},
                {<<"months">>, <<"month">>, [<<"long">>, <<"short">>, <<"narrow">>], <<"short">>},
                {<<"weeks">>, <<"week">>, [<<"long">>, <<"short">>, <<"narrow">>], <<"short">>},
                {<<"days">>, <<"day">>, [<<"long">>, <<"short">>, <<"narrow">>], <<"short">>},
                {<<"hours">>, <<"hour">>, [<<"long">>, <<"short">>, <<"narrow">>, <<"numeric">>, <<"2-digit">>], <<"numeric">>},
                {<<"minutes">>, <<"minute">>, [<<"long">>, <<"short">>, <<"narrow">>, <<"numeric">>, <<"2-digit">>], <<"numeric">>},
                {<<"seconds">>, <<"second">>, [<<"long">>, <<"short">>, <<"narrow">>, <<"numeric">>, <<"2-digit">>], <<"numeric">>},
                {<<"milliseconds">>, <<"millisecond">>, [<<"long">>, <<"short">>, <<"narrow">>, <<"numeric">>], <<"numeric">>},
                {<<"microseconds">>, <<"microsecond">>, [<<"long">>, <<"short">>, <<"narrow">>, <<"numeric">>], <<"numeric">>},
                {<<"nanoseconds">>, <<"nanosecond">>, [<<"long">>, <<"short">>, <<"narrow">>, <<"numeric">>], <<"numeric">>}]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{?PROTO, record(object, ?OBJECT_PROTO,
                     ?METHODS(<<"Intl.DurationFormat.prototype">>, [{<<"format">>, 1}, {<<"formatToParts">>, 1}, {<<"resolvedOptions">>, 0}])
                     ++ [{<<"constructor">>, constructor()}, {?SYM(toStringTag), <<"Intl.DurationFormat">>, 4}],
                     none)},
     {{builtin, <<"Intl.DurationFormat">>}, ctor_record(<<"DurationFormat">>, 0, {'$o', ?PROTO},
                                                        ?METHODS(<<"Intl.DurationFormat">>, [{<<"supportedLocalesOf">>, 1}]),
                                                        fun construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [].

-spec constructor() -> term().
constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Intl.DurationFormat">>).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(_Name, _This, _Args) -> buoy_ref:type_error(<<"Constructor Intl.DurationFormat requires 'new'">>).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Intl.DurationFormat">>, <<"supportedLocalesOf">>, _This, Args) ->
    buoy_ref_intl:filter_locales(buoy_ref_intl_data:available_locales(),
                                 buoy_ref_intl:canonicalize_locale_list(arg(1, Args)), arg(2, Args));
method(<<"Intl.DurationFormat.prototype">>, <<"resolvedOptions">>, This, _Args) ->
    S = slots(This, <<"resolvedOptions">>),
    Units = lists:append([[{Unit, case Style of <<"fractional">> -> <<"numeric">>; _ -> Style end},
                           {<<Unit/binary, "Display">>, Display}]
                          || {Unit, _, _, _} <- ?UNITS, {Style, Display} <- [maps:get(Unit, maps:get(units, S))]]),
    buoy_ref_intl:options_object([{<<"locale">>, maps:get(locale, S)}, {<<"numberingSystem">>, maps:get(nu, S)},
                                  {<<"style">>, maps:get(style, S)} | Units]
                                 ++ [{<<"fractionalDigits">>, maps:get(fractional_digits, S)}]);
method(<<"Intl.DurationFormat.prototype">>, <<"format">>, This, Args) ->
    S = slots(This, <<"format">>),
    Parts = partition(S, duration_record(arg(1, Args))),
    buoy_ref_string:concat([V || {_, V, _} <- Parts]);
method(<<"Intl.DurationFormat.prototype">>, <<"formatToParts">>, This, Args) ->
    S = slots(This, <<"formatToParts">>),
    buoy_heap:new_array([buoy_heap:object(?OBJECT_PROTO, [{<<"type">>, atom_to_binary(T)}, {<<"value">>, V}]
                                                         ++ [{<<"unit">>, U} || U =/= none])
                         || {T, V, U} <- partition(S, duration_record(arg(1, Args)))]).

%% The string of a duration in a new DurationFormat of Locales and Options,
%% as Temporal.Duration.prototype.toLocaleString makes it.
-spec format_with(term(), term(), term()) -> term().
format_with(Locales, Options, Duration) ->
    Constructor = buoy_ref_realm:current(constructor()),
    DF = construct(Constructor, [Locales, Options]),
    method(<<"Intl.DurationFormat.prototype">>, <<"format">>, DF, [Duration]).

%%% The constructor

construct(NewTarget, Args) ->
    Proto = buoy_ref_realm:proto_for(NewTarget, ?PROTO),
    Requested = buoy_ref_intl:canonicalize_locale_list(arg(1, Args)),
    Options = buoy_ref_intl:get_options_object(arg(2, Args)),
    Resolved = buoy_ref_intl:resolve_options(Requested, Options, [{<<"nu">>, <<"numberingSystem">>, string, empty}],
                                             [<<"nu">>], fun buoy_ref_intl_number_format:locale_data/2),
    Style = get_option(Options, <<"style">>, string, [<<"long">>, <<"short">>, <<"narrow">>, <<"digital">>], <<"short">>),
    {Units, _} = lists:foldl(
                   fun({Unit, _, Styles, Digital}, {Acc, Prev}) ->
                           {UnitStyle, _} = Record = unit_options(Unit, Options, Style, Styles, Digital, Prev),
                           Next = case lists:member(Unit, [<<"hours">>, <<"minutes">>, <<"seconds">>, <<"milliseconds">>, <<"microseconds">>]) of
                               true -> UnitStyle;
                               false -> Prev
                           end,
                           {Acc#{Unit => Record}, Next}
                   end, {#{}, <<>>}, ?UNITS),
    FractionalDigits = case buoy_ref:get(Options, <<"fractionalDigits">>) of
        undefined -> undefined;
        V ->
            case buoy_ref:to_number(V) of
                N when is_number(N), N >= 0, N =< 9 -> floor(N);
                _ -> range_error(<<"fractionalDigits value is out of range.">>)
            end
    end,
    Locale = maps:get(locale, Resolved),
    Nu = maps:get(<<"nu">>, Resolved),
    DataLocale = maps:get(data_locale, Resolved),
    buoy_heap:new_exotic(intl_duration_format, Proto,
                         #{locale => Locale, data_locale => DataLocale, nu => Nu, style => Style, units => Units,
                           fractional_digits => FractionalDigits, separator => separator(DataLocale, Nu)}).

%% GetDurationUnitOptions: {Style, Display}.
unit_options(Unit, Options, BaseStyle, Styles, DigitalBase, Prev) ->
    Style0 = get_option(Options, Unit, string, Styles, undefined),
    {Style1, DisplayDefault} = case Style0 of
        undefined when BaseStyle =:= <<"digital">> ->
            {DigitalBase, case lists:member(Unit, [<<"hours">>, <<"minutes">>, <<"seconds">>]) of true -> <<"always">>; false -> <<"auto">> end};
        undefined when Prev =:= <<"fractional">>; Prev =:= <<"numeric">>; Prev =:= <<"2-digit">> ->
            {<<"numeric">>, case lists:member(Unit, [<<"minutes">>, <<"seconds">>]) of true -> <<"always">>; false -> <<"auto">> end};
        undefined -> {BaseStyle, <<"auto">>};
        _ -> {Style0, <<"always">>}
    end,
    Fractional = lists:member(Unit, [<<"milliseconds">>, <<"microseconds">>, <<"nanoseconds">>]),
    {Style, Default} = case Style1 =:= <<"numeric">> andalso Fractional of
        true -> {<<"fractional">>, <<"auto">>};
        false -> {Style1, DisplayDefault}
    end,
    Display = get_option(Options, <<Unit/binary, "Display">>, string, [<<"auto">>, <<"always">>], Default),
    Display =:= <<"always">> andalso Style =:= <<"fractional">> andalso
        range_error(buoy_ref_string:concat([Unit, <<"Display must not be always with the fractional style">>])),
    Prev =:= <<"fractional">> andalso Style =/= <<"fractional">> andalso
        range_error(buoy_ref_string:concat([<<"Invalid style for ">>, Unit])),
    (Prev =:= <<"numeric">> orelse Prev =:= <<"2-digit">>) andalso
        not lists:member(Style, [<<"fractional">>, <<"numeric">>, <<"2-digit">>]) andalso
        range_error(buoy_ref_string:concat([<<"Invalid style for ">>, Unit])),
    Final = case Unit of
        _ when (Unit =:= <<"minutes">> orelse Unit =:= <<"seconds">>) andalso
               (Prev =:= <<"numeric">> orelse Prev =:= <<"2-digit">>) -> <<"2-digit">>;
        _ -> Style
    end,
    {Final, Display}.

%% The separator of numeric hours, minutes, and seconds: the time separator
%% of the numbering system when it is one of the four V8 knows, else ":".
separator(Locale, Nu) ->
    Base = buoy_ref_intl:base_name(Locale),
    Symbol = case buoy_intl_cldr:get(Base, [<<"NumberElements">>, Nu, <<"symbols">>, <<"timeSeparator">>]) of
        undefined -> buoy_intl_cldr:get(Base, [<<"NumberElements">>, <<"latn">>, <<"symbols">>, <<"timeSeparator">>], <<":">>);
        T -> T
    end,
    case Symbol of
        <<".">> -> <<".">>;
        <<"："/utf8>> -> <<"："/utf8>>;
        <<"٫"/utf8>> -> <<"٫"/utf8>>;
        _ -> <<":">>
    end.

slots(This, Name) ->
    ?IS_OBJECT(This) andalso buoy_heap:class_of(This) =:= intl_duration_format orelse
        buoy_ref:type_error(buoy_ref_string:concat([<<"Method Intl.DurationFormat.prototype.">>, Name,
                                                    <<" called on incompatible receiver">>])),
    buoy_heap:slots(This).

%%% ToDurationRecord

%% ToDurationRecord with Temporal: a string is an ISO 8601 duration and a
%% Temporal.Duration gives its fields, without its getters.
duration_record(Input) when ?IS_STRING(Input) -> from_slots(buoy_ref_temporal:duration_slots(Input));
duration_record(Input) when not ?IS_OBJECT(Input) -> buoy_ref:type_error(<<"Invalid duration">>);
duration_record(Input) ->
    case buoy_ref_temporal:slots_of(Input) of
        {<<"Duration">>, Slots} -> from_slots(Slots);
        _ -> bag_record(Input)
    end.

from_slots(Slots) ->
    maps:from_list([{F, integral(buoy_ref:get(Slots, atom_to_binary(F)))}
                    || F <- [years, months, weeks, days, hours, minutes, seconds, milliseconds, microseconds, nanoseconds]]).

bag_record(Input) ->
    Read = [{Field, case buoy_ref:get(Input, Field) of
                        undefined -> undefined;
                        V -> integral(V)
                    end}
            || Field <- [<<"days">>, <<"hours">>, <<"microseconds">>, <<"milliseconds">>, <<"minutes">>, <<"months">>,
                         <<"nanoseconds">>, <<"seconds">>, <<"weeks">>, <<"years">>]],
    lists:all(fun({_, V}) -> V =:= undefined end, Read) andalso buoy_ref:type_error(<<"Invalid duration">>),
    Record = maps:from_list([{binary_to_atom(F), case V of undefined -> 0; _ -> V end} || {F, V} <- Read]),
    is_valid(Record) orelse range_error(<<"Invalid duration">>),
    Record.

%% ToIntegerIfIntegral.
integral(V) ->
    case buoy_ref:to_number(V) of
        I when is_integer(I) -> I;
        F when is_float(F), F == trunc(F) -> trunc(F);
        _ -> range_error(<<"Invalid duration value">>)
    end.

%% IsValidDuration, with the seconds counted exactly in nanoseconds.
is_valid(#{years := Y, months := Mo, weeks := W, days := D, hours := H, minutes := Mi, seconds := S,
           milliseconds := Ms, microseconds := Us, nanoseconds := Ns}) ->
    Values = [Y, Mo, W, D, H, Mi, S, Ms, Us, Ns],
    Signs = lists:usort([sign(V) || V <- Values, V =/= 0]),
    Limit = 1 bsl 32,
    Nanos = ((D * 86400 + H * 3600 + Mi * 60 + S) * 1000000000) + Ms * 1000000 + Us * 1000 + Ns,
    length(Signs) =< 1 andalso abs(Y) < Limit andalso abs(Mo) < Limit andalso abs(W) < Limit
        andalso abs(Nanos) < (1 bsl 53) * 1000000000.

sign(V) when V < 0 -> -1;
sign(_) -> 1.

%% DurationSign.
duration_sign(R) ->
    first_sign([maps:get(F, R) || F <- [years, months, weeks, days, hours, minutes, seconds, milliseconds, microseconds, nanoseconds]]).

first_sign([]) -> 0;
first_sign([0 | Rest]) -> first_sign(Rest);
first_sign([V | _]) -> sign(V).

%%% PartitionDurationFormatPattern

%% The parts of a duration: {Type, String, Unit | none}.
partition(S, R) ->
    Groups = groups(S, R, ?UNITS, true, []),
    list_parts(S, Groups).

groups(_S, _R, [], _SignDisplayed, Acc) -> lists:reverse(Acc);
groups(S, R, [{Unit, NFUnit, _, _} | Rest], SignDisplayed, Acc) ->
    {Style, Display} = maps:get(Unit, maps:get(units, S)),
    Value = maps:get(binary_to_atom(Unit), R),
    case Style of
        _ when Style =:= <<"numeric">>; Style =:= <<"2-digit">> ->
            case numeric_units(S, R, Unit, SignDisplayed) of
                [] -> lists:reverse(Acc);
                Numeric -> lists:reverse([Numeric | Acc])
            end;
        _ ->
            {X, Options0, Done} = case next_fractional(S, Unit) of
                true -> {add_fraction(Value, fraction(S, R)), fraction_options(S), true};
                false -> {exact(Value), [], false}
            end,
            case Display =:= <<"always">> orelse not is_zero(X) of
                false when Done -> lists:reverse(Acc);
                false -> groups(S, R, Rest, SignDisplayed, Acc);
                true ->
                    {X1, Sign} = case SignDisplayed of
                        true -> {negative_zero(X, R), true};
                        false -> {X, false}
                    end,
                    Options = Options0 ++ [{<<"numberingSystem">>, maps:get(nu, S)}]
                        ++ [{<<"signDisplay">>, <<"never">>} || not Sign]
                        ++ [{<<"style">>, <<"unit">>}, {<<"unit">>, NFUnit}, {<<"unitDisplay">>, Style}],
                    Group = number_parts(S, Options, X1, NFUnit),
                    case Done of
                        true -> lists:reverse([Group | Acc]);
                        false -> groups(S, R, Rest, SignDisplayed andalso not Sign, [Group | Acc])
                    end
            end
    end.

negative_zero({false, 0, _}, R) ->
    case duration_sign(R) of
        -1 -> {true, 0, 0};
        _ -> {false, 0, 0}
    end;
negative_zero(X, _R) -> X.

is_zero({_, 0, _}) -> true;
is_zero(_) -> false.

exact(V) -> {V < 0, abs(V), 0}.

%% NextUnitFractional.
next_fractional(S, Unit) ->
    Next = case Unit of
        <<"seconds">> -> <<"milliseconds">>;
        <<"milliseconds">> -> <<"microseconds">>;
        <<"microseconds">> -> <<"nanoseconds">>;
        _ -> none
    end,
    Next =/= none andalso element(1, maps:get(Next, maps:get(units, S))) =:= <<"fractional">>.

%% ComputeFractionalDigits as {Nanoseconds-like numerator, Exponent}: the sum
%% of the fractional units in units of 10^-Exponent of the smallest unit
%% that is not fractional.
fraction(S, R) ->
    {Sum, Exponent} = lists:foldl(
                        fun({Unit, Field}, {Acc, Exp}) ->
                                case element(1, maps:get(Unit, maps:get(units, S))) of
                                    <<"fractional">> -> {Acc * 1000 + maps:get(Field, R), Exp + 3};
                                    _ -> {Acc, Exp}
                                end
                        end, {0, 0}, [{<<"milliseconds">>, milliseconds}, {<<"microseconds">>, microseconds},
                                      {<<"nanoseconds">>, nanoseconds}]),
    {Sum, Exponent}.

%% Value + the fraction, as an exact Intl mathematical value.
add_fraction(Value, {Sum, Exponent}) ->
    Total = Value * pow10(Exponent) + Sum,
    {Total < 0, abs(Total), -Exponent}.

pow10(N) -> pow10(N, 1).
pow10(0, Acc) -> Acc;
pow10(N, Acc) -> pow10(N - 1, Acc * 10).

fraction_options(S) ->
    case maps:get(fractional_digits, S) of
        undefined -> [{<<"maximumFractionDigits">>, 9}, {<<"minimumFractionDigits">>, 0}, {<<"roundingMode">>, <<"trunc">>}];
        D -> [{<<"maximumFractionDigits">>, D}, {<<"minimumFractionDigits">>, D}, {<<"roundingMode">>, <<"trunc">>}]
    end.

%% FormatNumericUnits.
numeric_units(S, R, First, SignDisplayed) ->
    Units = maps:get(units, S),
    {_, HoursDisplay} = maps:get(<<"hours">>, Units),
    {_, MinutesDisplay} = maps:get(<<"minutes">>, Units),
    {_, SecondsDisplay} = maps:get(<<"seconds">>, Units),
    Hours = maps:get(hours, R),
    Minutes = maps:get(minutes, R),
    Seconds = case {maps:get(milliseconds, R), maps:get(microseconds, R), maps:get(nanoseconds, R)} of
        {0, 0, 0} -> exact(maps:get(seconds, R));
        _ -> add_fraction(maps:get(seconds, R), fraction(S, R))
    end,
    HoursFormatted = First =:= <<"hours">> andalso (Hours =/= 0 orelse HoursDisplay =:= <<"always">>),
    SecondsFormatted = not is_zero(Seconds) orelse SecondsDisplay =:= <<"always">>,
    MinutesFormatted = (First =:= <<"hours">> orelse First =:= <<"minutes">>) andalso
        ((HoursFormatted andalso SecondsFormatted) orelse Minutes =/= 0 orelse MinutesDisplay =:= <<"always">>),
    {HoursParts, Sign1} = case HoursFormatted of
        true ->
            X = case SignDisplayed of
                true -> negative_zero(exact(Hours), R);
                false -> exact(Hours)
            end,
            {numeric(S, <<"hours">>, X, SignDisplayed, <<"hour">>, []), false};
        false -> {[], SignDisplayed}
    end,
    {MinutesParts, Sign2} = case MinutesFormatted of
        true ->
            Y = case Sign1 of
                true -> negative_zero(exact(Minutes), R);
                false -> exact(Minutes)
            end,
            {separated(S, HoursFormatted) ++ numeric(S, <<"minutes">>, Y, Sign1, <<"minute">>, []), false};
        false -> {[], Sign1}
    end,
    SecondsParts = case SecondsFormatted of
        true -> separated(S, MinutesFormatted) ++ numeric(S, <<"seconds">>, Seconds, Sign2, <<"second">>, fraction_options(S));
        false -> []
    end,
    HoursParts ++ MinutesParts ++ SecondsParts.

separated(_S, false) -> [];
separated(S, true) -> [{literal, maps:get(separator, S), none}].

numeric(S, Unit, X, SignDisplayed, NFUnit, Extra) ->
    {Style, _} = maps:get(Unit, maps:get(units, S)),
    Options = [{<<"numberingSystem">>, maps:get(nu, S)}]
        ++ [{<<"minimumIntegerDigits">>, 2} || Style =:= <<"2-digit">>]
        ++ [{<<"signDisplay">>, <<"never">>} || not SignDisplayed]
        ++ [{<<"useGrouping">>, false}] ++ Extra,
    number_parts(S, Options, X, NFUnit).

%% The parts of X in a NumberFormat of the locale and Options, with Unit.
number_parts(S, Options, X, Unit) ->
    NF = buoy_ref_intl_number_format:number_format(maps:get(locale, S), buoy_heap:object(null, Options)),
    [{T, buoy_ref_string:from_code_points(V), Unit} || {T, V} <- buoy_ref_intl_number_format:partition(NF, X)].

%% ListFormatParts.
list_parts(S, Groups) ->
    ListStyle = case maps:get(style, S) of
        <<"digital">> -> <<"short">>;
        Style -> Style
    end,
    Strings = [buoy_ref_string:concat([V || {_, V, _} <- G]) || G <- Groups],
    Parts = buoy_ref_intl_list_format:format_list(#{data_locale => maps:get(data_locale, S), type => <<"unit">>, style => ListStyle},
                                                  Strings, element),
    flatten(Parts, Groups).

flatten([], _Groups) -> [];
flatten([{element, _} | Rest], [Group | Groups]) -> Group ++ flatten(Rest, Groups);
flatten([{literal, V} | Rest], Groups) -> [{literal, V, none} | flatten(Rest, Groups)].
