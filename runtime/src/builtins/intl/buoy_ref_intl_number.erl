%% The numbers of Intl (ECMA-402 section 16.5): Intl mathematical values,
%% SetNumberFormatDigitOptions, and FormatNumericToString, which
%% Intl.NumberFormat and Intl.PluralRules share. An Intl mathematical value
%% is exact: {Negative, Coefficient, Exponent} is (-1)^Negative x Coefficient
%% x 10^Exponent, so {true, 0, 0} is negative-zero, and the atoms nan,
%% infinity, and neg_infinity are the others. The rounding works on these
%% integers, as ICU's DecimalQuantity does for V8 and JavaScriptCore.
-module(buoy_ref_intl_number).

-include("buoy_ref.hrl").

-export([to_intl_mv/1, digit_options/4, digit_resolved/1, format_to_string/2, decimal_string/1]).

-export_type([mv/0, digits/0]).

-type mv() :: {boolean(), non_neg_integer(), integer()} | nan | infinity | neg_infinity.
%% The slots that SetNumberFormatDigitOptions sets.
-type digits() :: #{atom() => term()}.

%%% ToIntlMathematicalValue

%% ToIntlMathematicalValue: a Number goes through Number::toString, and a
%% string reads as a StringNumericLiteral with every digit kept.
-spec to_intl_mv(term()) -> mv().
to_intl_mv(Value) ->
    case buoy_ref:to_primitive(Value, number) of
        {'$bigint', I} -> {I < 0, abs(I), 0};
        S when ?IS_STRING(S) -> round_mv(parse(buoy_ref_string:units(S)));
        P ->
            case buoy_ref:to_number(P) of
                'NaN' -> nan;
                'Infinity' -> infinity;
                '-Infinity' -> neg_infinity;
                Z when Z == 0 -> {is_float(Z) andalso <<Z/float>> =:= <<-0.0/float>>, 0, 0};
                X -> parse(buoy_ref_string:units(buoy_ref:to_string(X)))
            end
    end.

%% StringIntlMV of the text, or nan when it is not a StringNumericLiteral.
parse(Units) ->
    case trim(Units) of
        [] -> {false, 0, 0};
        [$0, R | Digits] when R =:= $x; R =:= $X -> radix(Digits, 16);
        [$0, R | Digits] when R =:= $o; R =:= $O -> radix(Digits, 8);
        [$0, R | Digits] when R =:= $b; R =:= $B -> radix(Digits, 2);
        [$- | Rest] -> negate(unsigned(Rest));
        [$+ | Rest] -> unsigned(Rest);
        Text -> unsigned(Text)
    end.

trim(Units) ->
    Drop = fun(L) -> lists:dropwhile(fun buoy_ref_string:is_whitespace/1, L) end,
    lists:reverse(Drop(lists:reverse(Drop(Units)))).

radix([], _Radix) -> nan;
radix(Digits, Radix) ->
    Values = [digit_value(D) || D <- Digits],
    case lists:all(fun(V) -> V < Radix end, Values) of
        true -> {false, lists:foldl(fun(V, Acc) -> Acc * Radix + V end, 0, Values), 0};
        false -> nan
    end.

digit_value(C) when C >= $0, C =< $9 -> C - $0;
digit_value(C) when C >= $a, C =< $z -> C - $a + 10;
digit_value(C) when C >= $A, C =< $Z -> C - $A + 10;
digit_value(_) -> 99.

negate({false, C, E}) -> {true, C, E};
negate(infinity) -> neg_infinity;
negate(nan) -> nan.

unsigned("Infinity") -> infinity;
unsigned(Units) ->
    {Int, Rest1} = lists:splitwith(fun is_digit/1, Units),
    {Frac, Rest2} = case Rest1 of
        [$. | After] -> lists:splitwith(fun is_digit/1, After);
        _ -> {[], Rest1}
    end,
    case {Int ++ Frac, exponent(Rest2)} of
        {[], _} -> nan;
        {_, error} -> nan;
        {Digits, Exponent} -> {false, list_to_integer(Digits), Exponent - length(Frac)}
    end.

exponent([]) -> 0;
exponent([E | Rest]) when E =:= $e; E =:= $E ->
    {Sign, Digits} = case Rest of
        [$+ | D] -> {1, D};
        [$- | D] -> {-1, D};
        D -> {1, D}
    end,
    case Digits =/= [] andalso lists:all(fun is_digit/1, Digits) of
        true -> Sign * list_to_integer(Digits);
        false -> error
    end;
exponent(_) -> error.

is_digit(C) -> C >= $0 andalso C =< $9.

%% RoundMVResult: a value whose Number is an infinity or a zero becomes it.
%% Doubles end below (2^54 - 1) x 2^970 and round to zero at or below
%% 2^-1075.
round_mv({_, 0, _} = Zero) -> Zero;
round_mv({Negative, C, E}) ->
    Size = length(integer_to_list(C)) + E,
    Overflows = Size > 310 orelse (E >= 0 andalso C * pow10(E) >= ((1 bsl 54) - 1) bsl 970),
    Underflows = Size < -330 orelse (E < 0 andalso Size =< 0 andalso C bsl 1075 =< pow10(-E)),
    if
        Overflows -> infinite(Negative);
        Underflows -> {Negative, 0, 0};
        true -> {Negative, C, E}
    end;
round_mv(Other) -> Other.

infinite(false) -> infinity;
infinite(true) -> neg_infinity.

%%% SetNumberFormatDigitOptions

%% SetNumberFormatDigitOptions: the digit slots of an Intl object, read from
%% Options in the order of the specification.
-spec digit_options(term(), non_neg_integer(), non_neg_integer(), binary()) -> digits().
digit_options(Options, MnfdDefault0, MxfdDefault0, Notation) ->
    Mnid = number_option(Options, <<"minimumIntegerDigits">>, 1, 21, 1),
    Mnfd0 = buoy_ref:get(Options, <<"minimumFractionDigits">>),
    Mxfd0 = buoy_ref:get(Options, <<"maximumFractionDigits">>),
    Mnsd0 = buoy_ref:get(Options, <<"minimumSignificantDigits">>),
    Mxsd0 = buoy_ref:get(Options, <<"maximumSignificantDigits">>),
    Increment = number_option(Options, <<"roundingIncrement">>, 1, 5000, 1),
    lists:member(Increment, [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000]) orelse
        buoy_ref_intl:range_error(<<"roundingIncrement value is out of range.">>),
    Mode = buoy_ref_intl:get_option(Options, <<"roundingMode">>, string,
                                    [<<"ceil">>, <<"floor">>, <<"expand">>, <<"trunc">>, <<"halfCeil">>, <<"halfFloor">>,
                                     <<"halfExpand">>, <<"halfTrunc">>, <<"halfEven">>], <<"halfExpand">>),
    Priority = buoy_ref_intl:get_option(Options, <<"roundingPriority">>, string,
                                        [<<"auto">>, <<"morePrecision">>, <<"lessPrecision">>], <<"auto">>),
    TrailingZeros = buoy_ref_intl:get_option(Options, <<"trailingZeroDisplay">>, string,
                                             [<<"auto">>, <<"stripIfInteger">>], <<"auto">>),
    MxfdDefault = case Increment of
        1 -> MxfdDefault0;
        _ -> MnfdDefault0
    end,
    HasSd = Mnsd0 =/= undefined orelse Mxsd0 =/= undefined,
    HasFd = Mnfd0 =/= undefined orelse Mxfd0 =/= undefined,
    {NeedSd, NeedFd} = case Priority of
        <<"auto">> -> {HasSd, not (HasSd orelse (not HasFd andalso Notation =:= <<"compact">>))};
        _ -> {true, true}
    end,
    Base = #{minimum_integer_digits => Mnid, rounding_increment => Increment, rounding_mode => Mode,
             trailing_zero_display => TrailingZeros},
    Sd = case {NeedSd, HasSd} of
        {false, _} -> #{};
        {true, true} ->
            Mnsd = default_number_option(Mnsd0, 1, 21, 1, <<"minimumSignificantDigits">>),
            #{minimum_significant_digits => Mnsd,
              maximum_significant_digits => default_number_option(Mxsd0, Mnsd, 21, 21, <<"maximumSignificantDigits">>)};
        {true, false} -> #{minimum_significant_digits => 1, maximum_significant_digits => 21}
    end,
    Fd = case {NeedFd, HasFd} of
        {false, _} -> #{};
        {true, true} ->
            Mnfd1 = default_number_option(Mnfd0, 0, 100, undefined, <<"minimumFractionDigits">>),
            Mxfd1 = default_number_option(Mxfd0, 0, 100, undefined, <<"maximumFractionDigits">>),
            {Mnfd, Mxfd} = if
                Mnfd1 =:= undefined -> {min(MnfdDefault0, Mxfd1), Mxfd1};
                Mxfd1 =:= undefined -> {Mnfd1, max(MxfdDefault, Mnfd1)};
                Mnfd1 > Mxfd1 -> buoy_ref_intl:range_error(<<"maximumFractionDigits value is out of range.">>);
                true -> {Mnfd1, Mxfd1}
            end,
            #{minimum_fraction_digits => Mnfd, maximum_fraction_digits => Mxfd};
        {true, false} -> #{minimum_fraction_digits => MnfdDefault0, maximum_fraction_digits => MxfdDefault}
    end,
    {Type, Computed, Rounding} = case {Priority, NeedSd, NeedFd} of
        {<<"auto">>, false, false} ->
            {more_precision, <<"morePrecision">>, #{minimum_fraction_digits => 0, maximum_fraction_digits => 0,
                                                    minimum_significant_digits => 1, maximum_significant_digits => 2}};
        {<<"morePrecision">>, _, _} -> {more_precision, Priority, #{}};
        {<<"lessPrecision">>, _, _} -> {less_precision, Priority, #{}};
        _ when HasSd -> {significant_digits, <<"auto">>, #{}};
        _ -> {fraction_digits, <<"auto">>, #{}}
    end,
    Digits = maps:merge(maps:merge(maps:merge(Base, Sd), Fd), Rounding#{rounding_type => Type, rounding_priority => Computed}),
    case Increment of
        1 -> ok;
        _ ->
            Type =:= fraction_digits orelse
                buoy_ref:type_error(<<"roundingIncrement is only valid with fraction digits rounding">>),
            maps:get(maximum_fraction_digits, Digits) =:= maps:get(minimum_fraction_digits, Digits) orelse
                buoy_ref_intl:range_error(<<"maximumFractionDigits must equal minimumFractionDigits with roundingIncrement">>)
    end,
    Digits.

%% GetNumberOption and DefaultNumberOption.
number_option(Options, Key, Min, Max, Fallback) ->
    default_number_option(buoy_ref:get(Options, Key), Min, Max, Fallback, Key).

default_number_option(undefined, _Min, _Max, Fallback, _Key) -> Fallback;
default_number_option(Value, Min, Max, _Fallback, Key) ->
    case buoy_ref:to_number(Value) of
        N when is_number(N), N >= Min, N =< Max -> floor(N);
        _ -> buoy_ref_intl:range_error(buoy_ref_string:concat([Key, <<" value is out of range.">>]))
    end.

%% The digit rows of the resolved options, in table order, as
%% {Property, Value}: the absent ones are undefined.
-spec digit_resolved(digits()) -> [{binary(), term()}].
digit_resolved(Digits) ->
    [{<<"minimumIntegerDigits">>, maps:get(minimum_integer_digits, Digits)},
     {<<"minimumFractionDigits">>, maps:get(minimum_fraction_digits, Digits, undefined)},
     {<<"maximumFractionDigits">>, maps:get(maximum_fraction_digits, Digits, undefined)},
     {<<"minimumSignificantDigits">>, maps:get(minimum_significant_digits, Digits, undefined)},
     {<<"maximumSignificantDigits">>, maps:get(maximum_significant_digits, Digits, undefined)}].

%%% FormatNumericToString

%% FormatNumericToString: {RoundedNumber, FormattedString}, with the string
%% of ASCII digits and ".".
-spec format_to_string(digits(), mv()) -> {mv(), string()}.
format_to_string(Digits, {Negative, C, E}) ->
    Mode = unsigned_mode(maps:get(rounding_mode, Digits), Negative),
    Precision = fun() -> raw_precision(C, E, maps:get(minimum_significant_digits, Digits),
                                       maps:get(maximum_significant_digits, Digits), Mode) end,
    Fixed = fun() -> raw_fixed(C, E, maps:get(minimum_fraction_digits, Digits), maps:get(maximum_fraction_digits, Digits),
                               maps:get(rounding_increment, Digits), Mode) end,
    {{N, Exponent}, Text0, Int, _} = case maps:get(rounding_type, Digits) of
        significant_digits -> Precision();
        fraction_digits -> Fixed();
        Type ->
            {_, _, _, SigMagnitude} = Sig = Precision(),
            {_, _, _, FixMagnitude} = Fix = Fixed(),
            case {Type, FixMagnitude < SigMagnitude} of
                {more_precision, true} -> Fix;
                {less_precision, false} -> Fix;
                _ -> Sig
            end
    end,
    Text1 = case maps:get(trailing_zero_display, Digits) =:= <<"stripIfInteger">> andalso is_integral(N, Exponent) of
        true -> lists:takewhile(fun(Ch) -> Ch =/= $. end, Text0);
        false -> Text0
    end,
    Text = lists:duplicate(max(0, maps:get(minimum_integer_digits, Digits) - Int), $0) ++ Text1,
    {{Negative, N, Exponent}, Text}.

is_integral(_N, Exponent) when Exponent >= 0 -> true;
is_integral(N, Exponent) -> N rem pow10(-Exponent) =:= 0.

%% GetUnsignedRoundingMode.
unsigned_mode(<<"ceil">>, Negative) -> pick(Negative, zero, infinity);
unsigned_mode(<<"floor">>, Negative) -> pick(Negative, infinity, zero);
unsigned_mode(<<"expand">>, _) -> infinity;
unsigned_mode(<<"trunc">>, _) -> zero;
unsigned_mode(<<"halfCeil">>, Negative) -> pick(Negative, half_zero, half_infinity);
unsigned_mode(<<"halfFloor">>, Negative) -> pick(Negative, half_infinity, half_zero);
unsigned_mode(<<"halfExpand">>, _) -> half_infinity;
unsigned_mode(<<"halfTrunc">>, _) -> half_zero;
unsigned_mode(<<"halfEven">>, _) -> half_even.

pick(true, IfNegative, _) -> IfNegative;
pick(false, _, IfPositive) -> IfPositive.

%% ToRawPrecision of C x 10^E: {{N, Exponent}, String, IntegerDigits,
%% RoundingMagnitude}, where N x 10^Exponent is the rounded value.
raw_precision(0, _E, MinP, P, _Mode) ->
    Text = case P of
        1 -> "0";
        _ -> "0." ++ lists:duplicate(P - 1, $0)
    end,
    {{0, 0}, cut(Text, P - MinP), 1, 1 - P};
raw_precision(C, E, MinP, P, Mode) ->
    Length = length(integer_to_list(C)),
    {A, D} = scaled(C, P - Length),
    N0 = round_up(A div D, A rem D, D, Mode),
    {N, Ex} = case N0 =:= pow10(P) of
        true -> {pow10(P - 1), Length - 1 + E + 1};
        false -> {N0, Length - 1 + E}
    end,
    M = integer_to_list(N),
    {Text, Int} = if
        Ex >= P - 1 -> {M ++ lists:duplicate(Ex - P + 1, $0), Ex + 1};
        Ex >= 0 -> {Head, Tail} = lists:split(Ex + 1, M), {Head ++ "." ++ Tail, Ex + 1};
        true -> {"0." ++ lists:duplicate(-(Ex + 1), $0) ++ M, 1}
    end,
    Cut = case lists:member($., Text) of
        true -> cut(Text, P - MinP);
        false -> Text
    end,
    {{N, Ex - P + 1}, Cut, Int, Ex - P + 1}.

%% ToRawFixed of C x 10^E with MaxF fraction digits and an increment.
raw_fixed(C, E, MinF, MaxF, Increment, Mode) ->
    {A, D} = scaled(C, E + MaxF),
    Step = D * Increment,
    N = round_up(A div Step, A rem Step, Step, Mode) * Increment,
    M = integer_to_list(N),
    {Text, Int} = case MaxF of
        0 -> {M, length(M)};
        _ ->
            Padded = lists:duplicate(max(0, MaxF + 1 - length(M)), $0) ++ M,
            {Head, Tail} = lists:split(length(Padded) - MaxF, Padded),
            {Head ++ "." ++ Tail, length(Head)}
    end,
    {{N, -MaxF}, cut(Text, MaxF - MinF), Int, -MaxF}.

%% C x 10^S as the fraction {A, D}.
scaled(C, S) when S >= 0 -> {C * pow10(S), 1};
scaled(C, S) -> {C, pow10(-S)}.

%% ApplyUnsignedRoundingMode between Q and Q + 1 for the remainder R of a
%% step: the quotient to keep.
round_up(Q, 0, _Step, _Mode) -> Q;
round_up(Q, _R, _Step, zero) -> Q;
round_up(Q, _R, _Step, infinity) -> Q + 1;
round_up(Q, R, Step, Mode) ->
    if
        2 * R < Step -> Q;
        2 * R > Step -> Q + 1;
        Mode =:= half_zero -> Q;
        Mode =:= half_infinity -> Q + 1;
        true -> Q + Q rem 2
    end.

%% Removes up to Cut trailing zeros, then a trailing ".".
cut(Text, Cut) ->
    Reversed = drop_zeros(lists:reverse(Text), Cut),
    lists:reverse(case Reversed of
        [$. | Rest] -> Rest;
        _ -> Reversed
    end).

drop_zeros([$0 | Rest], Cut) when Cut > 0 -> drop_zeros(Rest, Cut - 1);
drop_zeros(Text, _Cut) -> Text.

pow10(N) -> pow10(N, 1).
pow10(0, Acc) -> Acc;
pow10(N, Acc) -> pow10(N - 1, Acc * 10).

%% The decimal string of a finite value, as PluralRuleSelect reads it.
-spec decimal_string(mv()) -> string().
decimal_string({_, C, E}) when E >= 0 -> integer_to_list(C * pow10(E));
decimal_string({_, C, E}) ->
    Padded = lists:duplicate(max(0, -E + 1 - length(integer_to_list(C))), $0) ++ integer_to_list(C),
    {Head, Tail} = lists:split(length(Padded) + E, Padded),
    Head ++ "." ++ Tail.
