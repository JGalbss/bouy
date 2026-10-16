%% The `Number` namespace, number methods, and the conversions between
%% numbers and strings (ECMAScript Number::toString and StringToNumber).
-module(bouy_number).

-export(['$member'/1, '$call'/1, new/1, call/3, get/2]).
-export(['isInteger'/1, 'isSafeInteger'/1, 'isFinite'/1, 'isNaN'/1, 'parseFloat'/1, 'parseInt'/1]).
-export(['$isNaN'/1, '$isFinite'/1]).
-export([to_string/1, from_string/1, from_integer_text/2]).

-define(MAX_SAFE, 9007199254740991).
-define(FUNCTIONS, [<<"isInteger">>, <<"isSafeInteger">>, <<"isFinite">>, <<"isNaN">>, <<"parseFloat">>, <<"parseInt">>]).
-define(METHODS, [<<"toExponential">>, <<"toFixed">>, <<"toLocaleString">>, <<"toPrecision">>, <<"toString">>, <<"valueOf">>]).

-type js_number() :: bouy_rt:js_number().

%%% Namespace

-spec '$member'(binary()) -> term().
'$member'(<<"MAX_SAFE_INTEGER">>) -> ?MAX_SAFE;
'$member'(<<"MIN_SAFE_INTEGER">>) -> -?MAX_SAFE;
'$member'(<<"MAX_VALUE">>) -> 1.7976931348623157e308;
'$member'(<<"MIN_VALUE">>) -> 5.0e-324;
'$member'(<<"EPSILON">>) -> 2.220446049250313e-16;
'$member'(<<"POSITIVE_INFINITY">>) -> 'Infinity';
'$member'(<<"NEGATIVE_INFINITY">>) -> '-Infinity';
'$member'(<<"NaN">>) -> 'NaN';
'$member'(Name) -> bouy_rt:member_function(?MODULE, Name, ?FUNCTIONS).

%% `Number(x)`.
-spec '$call'(list()) -> js_number().
'$call'([]) -> 0;
'$call'([Value | _]) -> bouy_rt:to_number(Value).

%% `new Number(x)` yields the primitive: Bouy has no wrapper objects.
-spec new(list()) -> js_number().
new(Args) -> '$call'(Args).

-spec 'isInteger'(list()) -> boolean().
'isInteger'(Args) -> is_integral(bouy_rt:arg(1, Args)).

-spec 'isSafeInteger'(list()) -> boolean().
'isSafeInteger'(Args) ->
    Value = bouy_rt:arg(1, Args),
    is_integral(Value) andalso abs(Value) =< ?MAX_SAFE.

-spec 'isFinite'(list()) -> boolean().
'isFinite'(Args) -> is_number(bouy_rt:arg(1, Args)).

-spec 'isNaN'(list()) -> boolean().
'isNaN'(Args) -> bouy_rt:arg(1, Args) =:= 'NaN'.

%% The global `isNaN`, which converts its argument first.
-spec '$isNaN'(list()) -> boolean().
'$isNaN'(Args) -> bouy_rt:to_number(bouy_rt:arg(1, Args)) =:= 'NaN'.

%% The global `isFinite`, which converts its argument first.
-spec '$isFinite'(list()) -> boolean().
'$isFinite'(Args) -> is_number(bouy_rt:to_number(bouy_rt:arg(1, Args))).

is_integral(I) when is_integer(I) -> true;
is_integral(F) when is_float(F) -> F == trunc(F);
is_integral(_) -> false.

-spec 'parseFloat'(list()) -> js_number().
'parseFloat'(Args) ->
    case decimal_prefix(bouy_string:trim_start(bouy_rt:to_string(bouy_rt:arg(1, Args)))) of
        {Value, _Rest} -> Value;
        nomatch -> 'NaN'
    end.

-spec 'parseInt'(list()) -> js_number().
'parseInt'(Args) ->
    {Sign, Text} = sign(bouy_string:trim_start(bouy_rt:to_string(bouy_rt:arg(1, Args)))),
    case radix(bouy_rt:to_int32(bouy_rt:arg(2, Args)), Text) of
        {Radix, Digits} -> parsed_integer(Sign, digit_prefix(Digits, Radix), Radix);
        invalid -> 'NaN'
    end.

sign(<<"-", Text/binary>>) -> {-1, Text};
sign(<<"+", Text/binary>>) -> {1, Text};
sign(Text) -> {1, Text}.

radix(0, Text) -> hex_prefix(Text, 10);
radix(16, Text) -> hex_prefix(Text, 16);
radix(Radix, Text) when Radix >= 2, Radix =< 36 -> {Radix, Text};
radix(_, _) -> invalid.

hex_prefix(<<"0", X, Text/binary>>, _) when X =:= $x; X =:= $X -> {16, Text};
hex_prefix(Text, Radix) -> {Radix, Text}.

parsed_integer(_, <<>>, _) -> 'NaN';
parsed_integer(1, Digits, Radix) -> from_integer_text(Digits, Radix);
parsed_integer(-1, Digits, Radix) -> negative(from_integer_text(Digits, Radix)).

%%% Methods

-spec call(binary(), js_number(), list()) -> term().
call(<<"toString">>, N, Args) -> radix_string(N, bouy_rt:arg(1, Args));
call(<<"toFixed">>, N, Args) -> fixed(N, bouy_rt:to_integer(bouy_rt:arg(1, Args)));
call(<<"toPrecision">>, N, Args) -> precision(N, bouy_rt:arg(1, Args));
call(<<"toExponential">>, N, Args) -> exponential(N, bouy_rt:arg(1, Args));
call(<<"toLocaleString">>, N, _Args) -> locale(N);
call(<<"valueOf">>, N, _Args) -> N;
call(Name, N, Args) -> bouy_rt:prototype_call(N, Name, Args).

-spec get(js_number(), term()) -> term().
get(_N, Key) -> bouy_rt:member(?MODULE, Key, ?METHODS).

%%% Number to string

-spec to_string(js_number()) -> binary().
to_string(I) when is_integer(I) -> integer_to_binary(I);
to_string('NaN') -> <<"NaN">>;
to_string('Infinity') -> <<"Infinity">>;
to_string('-Infinity') -> <<"-Infinity">>;
to_string(F) when F == 0 -> <<"0">>;
to_string(F) when F < 0 -> <<"-", (to_string(-F))/binary>>;
to_string(F) ->
    {Digits, Point} = shortest(F),
    list_to_binary(decimal(Digits, Point)).

%% The shortest digits that round-trip to F, and the position of the
%% decimal point: F = 0.Digits * 10^Point.
shortest(F) ->
    {Mantissa, Exponent} =
        case string:split(float_to_list(F, [short]), "e") of
            [M] -> {M, 0};
            [M, E] -> {M, list_to_integer(E)}
        end,
    {Integer, Fraction} =
        case string:split(Mantissa, ".") of
            [I] -> {I, ""};
            [I, Fr] -> {I, Fr}
        end,
    strip_zeros(Integer ++ Fraction, length(Integer) + Exponent).

strip_zeros([$0 | Digits], Point) -> strip_zeros(Digits, Point - 1);
strip_zeros(Digits, Point) -> {string:trim(Digits, trailing, "0"), Point}.

%% Number::toString for the digits of a positive number.
decimal(Digits, Point) when length(Digits) =< Point, Point =< 21 ->
    Digits ++ lists:duplicate(Point - length(Digits), $0);
decimal(Digits, Point) when 0 < Point, Point =< 21 ->
    {Integer, Fraction} = lists:split(Point, Digits),
    Integer ++ "." ++ Fraction;
decimal(Digits, Point) when -6 < Point, Point =< 0 ->
    "0." ++ lists:duplicate(-Point, $0) ++ Digits;
decimal(Digits, Point) ->
    scientific(Digits, Point - 1).

scientific([Digit], Exponent) -> [Digit, $e | exponent_sign(Exponent)];
scientific([Digit | Rest], Exponent) -> [Digit, $. | Rest] ++ [$e | exponent_sign(Exponent)].

exponent_sign(E) when E >= 0 -> [$+ | integer_to_list(E)];
exponent_sign(E) -> [$- | integer_to_list(-E)].

%% `toString(radix)`.
radix_string(N, undefined) ->
    to_string(N);
radix_string(N, RadixArg) ->
    case bouy_rt:to_integer(RadixArg) of
        Radix when is_integer(Radix), Radix >= 2, Radix =< 36 -> in_radix(N, Radix);
        _ -> bouy_error:throw(<<"RangeError">>, <<"toString() radix argument must be between 2 and 36">>)
    end.

in_radix(N, 10) -> to_string(N);
in_radix(N, _) when is_atom(N) -> to_string(N);
in_radix(I, Radix) when is_integer(I) -> string:lowercase(integer_to_binary(I, Radix));
in_radix(F, _) when F == 0 -> <<"0">>;
in_radix(F, Radix) when F < 0 -> <<"-", (in_radix(-F, Radix))/binary>>;
in_radix(F, Radix) -> float_in_radix(F, Radix).

%% V8's DoubleToRadixCString: fraction digits up to the precision of the
%% double, rounded to even, then the integer digits.
float_in_radix(F, Radix) ->
    Integer = math:floor(F),
    {Fraction, Carry} = fraction_digits(F - Integer, precision_delta(F), Radix),
    IntegerDigits = integer_digits(Integer + Carry, Radix),
    list_to_binary([IntegerDigits, point(Fraction)]).

point([]) -> [];
point(Digits) -> [$. | [digit_char(D) || D <- Digits]].

%% Half the gap to the next double. Above Number.MAX_VALUE the gap is
%% infinite, so no fraction digit is significant.
precision_delta(F) ->
    case next_double(F) of
        infinity -> infinity;
        Next -> max(next_double(0.0), 0.5 * (Next - F))
    end.

fraction_digits(_Fraction, infinity, _Radix) -> {[], 0};
fraction_digits(Fraction, Delta, _Radix) when Fraction < Delta -> {[], 0};
fraction_digits(Fraction, Delta, Radix) -> fraction_loop(Fraction, Delta, Radix, []).

fraction_loop(Fraction0, Delta0, Radix, Acc) ->
    Scaled = Fraction0 * Radix,
    Delta = Delta0 * Radix,
    Digit = trunc(Scaled),
    Fraction = Scaled - Digit,
    Digits = [Digit | Acc],
    RoundsUp = Fraction > 0.5 orelse (Fraction == 0.5 andalso Digit band 1 =:= 1),
    if
        RoundsUp andalso Fraction + Delta > 1 -> round_up(Digits, Radix);
        Fraction >= Delta -> fraction_loop(Fraction, Delta, Radix, Digits);
        true -> {lists:reverse(Digits), 0}
    end.

round_up([Digit | Rest], Radix) when Digit + 1 < Radix -> {lists:reverse([Digit + 1 | Rest]), 0};
round_up([_ | Rest], Radix) -> round_up(Rest, Radix);
round_up([], _) -> {[], 1}.

%% Digits below the precision of the double print as zeros. The digit
%% loop uses double arithmetic, as V8 does, so large values round the same.
integer_digits(Integer, Radix) when Integer / Radix >= 9007199254740992.0 ->
    [integer_digits(Integer / Radix, Radix), $0];
integer_digits(Integer, Radix) ->
    double_digits(Integer, Radix, []).

double_digits(Integer, Radix, Acc) ->
    Remainder = math:fmod(Integer, float(Radix)),
    Digits = [digit_char(trunc(Remainder)) | Acc],
    case (Integer - Remainder) / Radix of
        Next when Next > 0 -> double_digits(Next, Radix, Digits);
        _ -> Digits
    end.

next_double(F) ->
    <<Bits:64>> = <<F/float>>,
    case <<(Bits + 1):64>> of
        <<Next/float>> -> Next;
        _ -> infinity
    end.

digit_char(D) when D < 10 -> $0 + D;
digit_char(D) -> $a + D - 10.

%% `toFixed(digits)`: exact decimal rounding, ties away from zero.
fixed(_, Digits) when not is_integer(Digits); Digits < 0; Digits > 100 ->
    bouy_error:throw(<<"RangeError">>, <<"toFixed() digits argument must be between 0 and 100">>);
fixed(N, _) when is_atom(N) -> to_string(N);
fixed(N, _) when abs(N) >= 1.0e21 -> to_string(N);
fixed(N, Digits) when N < 0 -> <<"-", (fixed(-N, Digits))/binary>>;
fixed(N, Digits) -> list_to_binary(insert_point(integer_to_list(scaled(ratio(N), Digits)), Digits)).

insert_point(Digits, 0) ->
    Digits;
insert_point(Digits, Places) ->
    Padded = lists:duplicate(max(0, Places + 1 - length(Digits)), $0) ++ Digits,
    {Integer, Fraction} = lists:split(length(Padded) - Places, Padded),
    Integer ++ "." ++ Fraction.

%% `toPrecision(precision)`.
precision(N, undefined) -> to_string(N);
precision(N, _) when is_atom(N) -> to_string(N);
precision(N, PrecisionArg) ->
    case bouy_rt:to_integer(PrecisionArg) of
        P when is_integer(P), P >= 1, P =< 100 -> list_to_binary(precise(N, P));
        _ -> bouy_error:throw(<<"RangeError">>, <<"toPrecision() argument must be between 1 and 100">>)
    end.

precise(N, P) when N < 0 -> [$- | precise(-N, P)];
precise(N, P) when N == 0 -> zero_digits(P - 1);
precise(N, P) ->
    {Digits, E} = significant(N, P),
    if
        E < -6; E >= P -> scientific(Digits, E);
        E =:= P - 1 -> Digits;
        E >= 0 -> insert_point(Digits, P - 1 - E);
        true -> "0." ++ lists:duplicate(-(E + 1), $0) ++ Digits
    end.

zero_digits(0) -> "0";
zero_digits(Places) -> "0." ++ lists:duplicate(Places, $0).

%% `toExponential(fractionDigits)`.
exponential(N, _) when is_atom(N) ->
    to_string(N);
exponential(N, undefined) ->
    list_to_binary(exponent_form(N, undefined));
exponential(N, DigitsArg) ->
    case bouy_rt:to_integer(DigitsArg) of
        F when is_integer(F), F >= 0, F =< 100 -> list_to_binary(exponent_form(N, F));
        _ -> bouy_error:throw(<<"RangeError">>, <<"toExponential() argument must be between 0 and 100">>)
    end.

exponent_form(N, F) when N < 0 -> [$- | exponent_form(-N, F)];
exponent_form(N, undefined) when N == 0 -> "0e+0";
exponent_form(N, F) when N == 0 -> zero_digits(F) ++ "e+0";
exponent_form(N, undefined) when is_integer(N) ->
    Digits = integer_to_list(N),
    scientific(string:trim(Digits, trailing, "0"), length(Digits) - 1);
exponent_form(N, undefined) ->
    {Digits, Point} = shortest(N),
    scientific(Digits, Point - 1);
exponent_form(N, F) ->
    {Digits, E} = significant(N, F + 1),
    scientific(Digits, E).

%% `toLocaleString()` for the en-US locale: grouped integer digits and at
%% most three fraction digits. ICU rounds the shortest decimal digits, not
%% the exact binary value.
locale('NaN') -> <<"NaN">>;
locale('Infinity') -> <<"∞"/utf8>>;
locale('-Infinity') -> <<"-∞"/utf8>>;
locale(N) when is_float(N), N == 0 -> to_string_signed_zero(N);
locale(N) when N < 0 -> <<"-", (locale(-N))/binary>>;
locale(N) ->
    Thousandths = scaled(decimal_ratio(N), 3),
    Fraction = string:trim(lists:flatten(io_lib:format("~3..0B", [Thousandths rem 1000])), trailing, "0"),
    iolist_to_binary([group(integer_to_list(Thousandths div 1000)), point_text(Fraction)]).

to_string_signed_zero(Zero) ->
    case <<Zero/float>> of
        <<1:1, _:63>> -> <<"-0">>;
        _ -> <<"0">>
    end.

point_text("") -> "";
point_text(Fraction) -> [$. | Fraction].

group(Digits) when length(Digits) =< 3 ->
    Digits;
group(Digits) ->
    {Head, Tail} = lists:split(length(Digits) - 3, Digits),
    [group(Head), $, | Tail].

%%% Exact decimal arithmetic on doubles

%% The exact value of a non-negative number as {Numerator, Denominator}.
ratio(I) when is_integer(I) ->
    {I, 1};
ratio(F) ->
    <<_:1, Exponent:11, Fraction:52>> = <<F/float>>,
    {Mantissa, Shift} =
        case Exponent of
            0 -> {Fraction, -1074};
            _ -> {Fraction + (1 bsl 52), Exponent - 1075}
        end,
    case Shift >= 0 of
        true -> {Mantissa bsl Shift, 1};
        false -> {Mantissa, 1 bsl -Shift}
    end.

%% The value of the shortest decimal digits of a non-negative number.
decimal_ratio(N) when is_integer(N); N == 0 ->
    ratio(N);
decimal_ratio(F) ->
    {Digits, Point} = shortest(F),
    case Point - length(Digits) of
        Shift when Shift >= 0 -> {list_to_integer(Digits) * pow10(Shift), 1};
        Shift -> {list_to_integer(Digits), pow10(-Shift)}
    end.

%% round(Ratio * 10^Places), with ties away from zero.
scaled({Numerator, Denominator}, Places) when Places >= 0 ->
    half_up(Numerator * pow10(Places), Denominator);
scaled({Numerator, Denominator}, Places) ->
    half_up(Numerator, Denominator * pow10(-Places)).

half_up(Numerator, Denominator) ->
    (2 * Numerator + Denominator) div (2 * Denominator).

%% The first P significant digits of a positive number, rounded, and the
%% decimal exponent of the first digit.
significant(N, P) ->
    Ratio = ratio(N),
    E = exponent10(Ratio, estimate10(N)),
    Rounded = scaled(Ratio, P - 1 - E),
    case Rounded >= pow10(P) of
        true -> {integer_to_list(Rounded div 10), E + 1};
        false -> {integer_to_list(Rounded), E}
    end.

estimate10(I) when is_integer(I) -> length(integer_to_list(I)) - 1;
estimate10(F) -> floor(math:log10(F)).

%% floor(log10(Ratio)), corrected from an estimate with exact comparisons.
exponent10(Ratio, E) ->
    case {at_least(Ratio, E), at_least(Ratio, E + 1)} of
        {false, _} -> exponent10(Ratio, E - 1);
        {true, true} -> exponent10(Ratio, E + 1);
        {true, false} -> E
    end.

at_least({Numerator, Denominator}, E) when E >= 0 -> Numerator >= Denominator * pow10(E);
at_least({Numerator, Denominator}, E) -> Numerator * pow10(-E) >= Denominator.

pow10(0) -> 1;
pow10(N) -> binary_to_integer(<<"1", (binary:copy(<<"0">>, N))/binary>>).

%%% String to number

%% Integer digits as JavaScript reads them: exact up to 2^53, and the
%% nearest double beyond that.
-spec from_integer_text(binary(), 2..36) -> js_number().
from_integer_text(Digits, Radix) ->
    case binary_to_integer(Digits, Radix) of
        I when abs(I) =< 9007199254740992 -> I;
        _ when Radix =:= 10 -> decimal_double(<<Digits/binary, ".0">>);
        I when Radix band (Radix - 1) =:= 0 -> decimal_double(<<(integer_to_binary(I))/binary, ".0">>);
        _ -> approximate(skip_zeros(Digits), Radix, 0.0)
    end.

%% V8 reads the chunks after the leading zeros, so they do not shift the
%% chunk boundaries.
skip_zeros(<<"0", Rest/binary>>) -> skip_zeros(Rest);
skip_zeros(Digits) -> Digits.

%% V8 reads other radixes in chunks whose multiplier fits in 32 bits and
%% accumulates them in doubles. Node on arm64 fuses `result * multiplier +
%% chunk` into one rounding, which exact arithmetic then one rounding
%% reproduces. (V8 on x86-64 rounds twice and can differ in the last bit.)
approximate(<<>>, _Radix, Result) ->
    Result;
approximate(_Digits, _Radix, 'Infinity') ->
    'Infinity';
approximate(Digits, Radix, Result) ->
    Size = min(byte_size(Digits), chunk_size(Radix, Radix, 1)),
    <<Chunk:Size/binary, Rest/binary>> = Digits,
    Exact = trunc(Result) * pow(Radix, Size) + binary_to_integer(Chunk, Radix),
    approximate(Rest, Radix, decimal_double(<<(integer_to_binary(Exact))/binary, ".0">>)).

%% The number of digits in one chunk: radix^n stays at most 0xFFFFFFFF div 36.
chunk_size(Radix, Multiplier, N) when Multiplier * Radix =< 16#FFFFFFFF div 36 -> chunk_size(Radix, Multiplier * Radix, N + 1);
chunk_size(_Radix, _Multiplier, N) -> N.

pow(_, 0) -> 1;
pow(Base, N) -> Base * pow(Base, N - 1).

decimal_double(Text) ->
    try
        binary_to_float(Text)
    catch
        error:badarg -> 'Infinity'
    end.

%% StringToNumber, the conversion behind `Number(s)` and `+s`. Decimal text
%% without a fraction or an exponent becomes an exact integer.
-spec from_string(binary()) -> js_number().
from_string(Text) ->
    literal(bouy_string:trim(Text)).

literal(<<>>) -> 0;
literal(<<"0", X, Digits/binary>>) when X =:= $x; X =:= $X -> radix_literal(Digits, 16);
literal(<<"0", O, Digits/binary>>) when O =:= $o; O =:= $O -> radix_literal(Digits, 8);
literal(<<"0", B, Digits/binary>>) when B =:= $b; B =:= $B -> radix_literal(Digits, 2);
literal(Text) ->
    case decimal_prefix(Text) of
        {Value, <<>>} -> Value;
        _ -> 'NaN'
    end.

radix_literal(<<>>, _) ->
    'NaN';
radix_literal(Digits, Radix) ->
    case digit_prefix(Digits, Radix) of
        Digits -> from_integer_text(Digits, Radix);
        _ -> 'NaN'
    end.

%% The longest prefix of Text that is a StrDecimalLiteral, as `parseFloat`
%% reads it: {Value, Rest}, or nomatch.
decimal_prefix(<<"-", Text/binary>>) -> negated(unsigned_prefix(Text));
decimal_prefix(<<"+", Text/binary>>) -> unsigned_prefix(Text);
decimal_prefix(Text) -> unsigned_prefix(Text).

negated({Value, Rest}) -> {negative(Value), Rest};
negated(nomatch) -> nomatch.

%% Text such as "-0" denotes negative zero, which only a float can hold.
negative(0) -> -0.0;
negative(Value) -> bouy_rt:negate(Value).

unsigned_prefix(<<"Infinity", Rest/binary>>) ->
    {'Infinity', Rest};
unsigned_prefix(Text) ->
    Integer = digit_prefix(Text, 10),
    {Fraction, AfterFraction} = fraction(after_prefix(Text, Integer)),
    case {Integer, Fraction} of
        {<<>>, <<>>} ->
            nomatch;
        _ ->
            {Exponent, Rest} = exponent(AfterFraction),
            {decimal_value(Integer, Fraction, Exponent), Rest}
    end.

fraction(<<".", Text/binary>>) ->
    Digits = digit_prefix(Text, 10),
    {Digits, after_prefix(Text, Digits)};
fraction(Text) ->
    {<<>>, Text}.

exponent(<<E, Text/binary>> = Original) when E =:= $e; E =:= $E ->
    {Sign, Unsigned} =
        case Text of
            <<"-", T/binary>> -> {<<"-">>, T};
            <<"+", T/binary>> -> {<<>>, T};
            T -> {<<>>, T}
        end,
    case digit_prefix(Unsigned, 10) of
        <<>> -> {none, Original};
        Digits -> {<<Sign/binary, Digits/binary>>, after_prefix(Unsigned, Digits)}
    end;
exponent(Text) ->
    {none, Text}.

decimal_value(Integer, <<>>, none) ->
    from_integer_text(Integer, 10);
decimal_value(Integer, Fraction, Exponent) ->
    Mantissa = <<(or_zero(Integer))/binary, ".", (or_zero(Fraction))/binary>>,
    try
        binary_to_float(<<Mantissa/binary, "e", (or_zero(Exponent))/binary>>)
    catch
        error:badarg -> overflow(Mantissa)
    end.

%% binary_to_float/1 fails only when the value is out of range.
overflow(Mantissa) ->
    case binary:replace(Mantissa, [<<"0">>, <<".">>], <<>>, [global]) of
        <<>> -> 0.0;
        _ -> 'Infinity'
    end.

or_zero(<<>>) -> <<"0">>;
or_zero(none) -> <<"0">>;
or_zero(Digits) -> Digits.

after_prefix(Text, Prefix) ->
    binary:part(Text, byte_size(Prefix), byte_size(Text) - byte_size(Prefix)).

digit_prefix(Text, Radix) ->
    binary:part(Text, 0, digit_run(Text, Radix, 0)).

digit_run(Text, Radix, N) ->
    case Text of
        <<_:N/binary, C, _/binary>> ->
            case digit_value(C) < Radix of
                true -> digit_run(Text, Radix, N + 1);
                false -> N
            end;
        _ ->
            N
    end.

digit_value(C) when C >= $0, C =< $9 -> C - $0;
digit_value(C) when C >= $a, C =< $z -> C - $a + 10;
digit_value(C) when C >= $A, C =< $Z -> C - $A + 10;
digit_value(_) -> 36.
