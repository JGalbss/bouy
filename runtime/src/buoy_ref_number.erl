%% The Number family: the representation of JavaScript numbers, the numeric
%% operators, the Number function and its statics, Number.prototype, and the
%% global number functions (parseInt, parseFloat, isNaN, isFinite).
%%
%% A number has exactly one form (contract, "Reference semantics"), as
%% JSC's JSValue(double) keeps an int32 when it can:
%%
%%   an integer I with abs(I) =< 2^53   every integral value in that range
%%   a float F                          any other finite value, and -0.0
%%   'NaN', 'Infinity', '-Infinity'     BEAM floats cannot hold these
%%
%% So =:= is SameValue for numbers other than NaN, and a number is a valid
%% map key. Every operation returns this form: canonical/1 turns an Erlang
%% result into it.
%%
%% The conversions to text are exact. A finite double is M * 2^E for
%% integers M and E, so toFixed, toExponential, and toPrecision round the
%% exact value with integer arithmetic, and toString(radix) follows V8's
%% DoubleToRadixCString step for step, so its digits match Node's.
-module(buoy_ref_number).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, wrap/2]).
-export([canonical/1, add/2, sub/2, mul/2, divide/2, remainder/2, power/2, negate/1]).
-export([to_int32/1, to_uint32/1, bit_and/2, bit_or/2, bit_xor/2, bit_not/1]).
-export([shift_left/2, shift_right/2, shift_right_unsigned/2, compare/2, same_value_zero/2, is_integral/1]).
-export([to_string/1, to_radix_string/2, from_string/1, to_integer_or_infinity/1]).
-export([to_fixed/2, to_exponential/2, to_precision/2, decompose/1, parse_decimal/1]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).

-define(SAFE, 9007199254740992).

%%% The family

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Number.prototype', record(number, ?OBJECT_PROTO, ?METHODS(<<"Number.prototype">>, [{<<"toString">>, 1}, {<<"toFixed">>, 1}, {<<"toPrecision">>, 1}, {<<"toExponential">>, 1}, {<<"toLocaleString">>, 0}, {<<"valueOf">>, 0}]) ++ [{<<"constructor">>, constructor()}], 0)},
     {{builtin, <<"Number">>}, ctor_record(<<"Number">>, 1, {'$o', 'Number.prototype'}, ?METHODS(<<"Number">>, [{<<"isInteger">>, 1}, {<<"isSafeInteger">>, 1}, {<<"isFinite">>, 1}, {<<"isNaN">>, 1}])
         ++ [{<<"parseFloat">>, parse_float_function()}, {<<"parseInt">>, parse_int_function()}]
         ++ [{K, V, 0} || {K, V} <- [{<<"MAX_SAFE_INTEGER">>, 9007199254740991}, {<<"MIN_SAFE_INTEGER">>, -9007199254740991}, {<<"EPSILON">>, 2.220446049250313e-16},
                                     {<<"MAX_VALUE">>, 1.7976931348623157e308}, {<<"MIN_VALUE">>, 5.0e-324}, {<<"POSITIVE_INFINITY">>, 'Infinity'},
                                     {<<"NEGATIVE_INFINITY">>, '-Infinity'}, {<<"NaN">>, 'NaN'}]], fun construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() ->
    [{<<"Number">>, constructor()}, {<<"NaN">>, 'NaN'}, {<<"Infinity">>, 'Infinity'},
     {<<"parseFloat">>, parse_float_function()}, {<<"parseInt">>, parse_int_function()}]
    ++ ?METHODS(<<"globalThis">>, [{<<"isNaN">>, 1}, {<<"isFinite">>, 1}]).

constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Number">>).

%% Number.parseFloat and Number.parseInt are the global functions themselves.
parse_float_function() -> buoy_ref_realm:builtin(<<"parseFloat">>, <<"parseFloat">>, 1, fun(_This, Args) -> ?MODULE:method(<<"globalThis">>, <<"parseFloat">>, undefined, Args) end).
parse_int_function() -> buoy_ref_realm:builtin(<<"parseInt">>, <<"parseInt">>, 2, fun(_This, Args) -> ?MODULE:method(<<"globalThis">>, <<"parseInt">>, undefined, Args) end).

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"Number">>, _This, Args) -> number_of(Args).

number_of([]) -> 0;
number_of([V | _]) ->
    case buoy_ref:to_numeric(V) of
        {'$bigint', I} -> canonical(I);
        N -> N
    end.

construct(NewTarget, Args) ->
    N = number_of(Args),
    wrap(N, buoy_ref_realm:proto_for(NewTarget, 'Number.prototype')).

%% A Number object: the class number, its [[NumberData]] in the slots.
-spec wrap(term(), term()) -> term().
wrap(N, Proto) -> buoy_heap:new_exotic(number, Proto, N).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Number.prototype">>, Name, This, Args) -> proto(Name, this_number(This, Name), Args);
method(<<"Number">>, <<"isInteger">>, _This, Args) -> is_integral(arg(1, Args));
method(<<"Number">>, <<"isSafeInteger">>, _This, Args) ->
    is_integral(arg(1, Args)) andalso abs(arg(1, Args)) =< ?SAFE - 1;
method(<<"Number">>, <<"isFinite">>, _This, Args) -> is_number(arg(1, Args));
method(<<"Number">>, <<"isNaN">>, _This, Args) -> arg(1, Args) =:= 'NaN';
method(<<"globalThis">>, <<"parseFloat">>, _This, Args) -> parse_float(buoy_ref:to_string(arg(1, Args)));
method(<<"globalThis">>, <<"parseInt">>, _This, Args) ->
    S = buoy_ref:to_string(arg(1, Args)),
    parse_int(S, to_int32(buoy_ref:to_number(arg(2, Args))));
method(<<"globalThis">>, <<"isNaN">>, _This, Args) -> buoy_ref:to_number(arg(1, Args)) =:= 'NaN';
method(<<"globalThis">>, <<"isFinite">>, _This, Args) -> is_number(buoy_ref:to_number(arg(1, Args))).

%% thisNumberValue: a number, or the [[NumberData]] of a Number object.
this_number(N, _Name) when ?IS_NUMBER(N) -> N;
this_number({'$o', _} = O, Name) ->
    case buoy_heap:class_of(O) of
        number -> buoy_heap:slots(O);
        _ -> not_a_number(Name)
    end;
this_number(_, Name) -> not_a_number(Name).

-spec not_a_number(binary()) -> no_return().
not_a_number(Name) -> buoy_ref:type_error(<<"Number.prototype.", Name/binary, " requires that 'this' be a Number">>).

proto(<<"valueOf">>, N, _Args) -> N;
proto(<<"toString">>, N, Args) ->
    case arg(1, Args) of
        undefined -> to_string(N);
        R ->
            case to_integer_or_infinity(buoy_ref:to_number(R)) of
                10 -> to_string(N);
                Radix when is_integer(Radix), Radix >= 2, Radix =< 36 -> to_radix_string(N, Radix);
                _ -> range_error(<<"toString() radix argument must be between 2 and 36">>)
            end
    end;
proto(<<"toLocaleString">>, N, Args) -> to_locale_string(N, arg(2, Args));
proto(<<"toFixed">>, N, Args) ->
    F = to_integer_or_infinity(buoy_ref:to_number(arg(1, Args))),
    is_integer(F) andalso F >= 0 andalso F =< 100 orelse range_error(<<"toFixed() digits argument must be between 0 and 100">>),
    to_fixed(N, F);
proto(<<"toExponential">>, N, Args) ->
    Digits = arg(1, Args),
    F = to_integer_or_infinity(buoy_ref:to_number(Digits)),
    case is_number(N) of
        false -> to_string(N);
        true ->
            is_integer(F) andalso F >= 0 andalso F =< 100 orelse range_error(<<"toExponential() argument must be between 0 and 100">>),
            case Digits of
                undefined -> to_exponential(N, shortest);
                _ -> to_exponential(N, F)
            end
    end;
proto(<<"toPrecision">>, N, Args) ->
    case arg(1, Args) of
        undefined -> to_string(N);
        P0 ->
            P = to_integer_or_infinity(buoy_ref:to_number(P0)),
            case is_number(N) of
                false -> to_string(N);
                true ->
                    is_integer(P) andalso P >= 1 andalso P =< 100 orelse range_error(<<"toPrecision() argument must be between 1 and 100">>),
                    to_precision(N, P)
            end
    end.

-spec range_error(binary()) -> no_return().
range_error(Message) -> buoy_heap:throw_error('RangeError', Message).

%% An integral Number: a finite number with no fraction, -0 included.
-spec is_integral(term()) -> boolean().
is_integral(I) when is_integer(I) -> true;
is_integral(F) when is_float(F) -> F == trunc(F);
is_integral(_) -> false.

%%% The representation

%% The canonical form of an Erlang number.
-spec canonical(term()) -> term().
canonical(I) when is_integer(I), I =< ?SAFE, I >= -?SAFE -> I;
canonical(I) when is_integer(I) ->
    try float(I) of
        F -> canonical(F)
    catch
        error:badarg -> infinity(I)
    end;
canonical(F) when is_float(F), F == 0 -> zero(F);
canonical(F) when is_float(F), abs(F) =< ?SAFE ->
    case trunc(F) of
        I when I == F -> I;
        _ -> F
    end;
canonical(V) -> V.

zero(F) when F =:= -0.0 -> -0.0;
zero(_) -> 0.

infinity(N) when N < 0 -> '-Infinity';
infinity(_) -> 'Infinity'.

%% The sign of a number: -1 for negative numbers and -0, else 1. NaN has none.
sign('-Infinity') -> -1;
sign('Infinity') -> 1;
sign(F) when is_float(F), F == 0 ->
    case F =:= -0.0 of
        true -> -1;
        false -> 1
    end;
sign(N) when N < 0 -> -1;
sign(_) -> 1.

%% A finite double as {M, E} with value M * 2^E exactly, M >= 0.
-spec decompose(number()) -> {non_neg_integer(), integer()}.
decompose(I) when is_integer(I) -> {abs(I), 0};
decompose(F) ->
    <<_:1, Exp:11, Frac:52>> = <<F/float>>,
    case Exp of
        0 -> {Frac, -1074};
        _ -> {Frac + (1 bsl 52), Exp - 1075}
    end.

%%% Arithmetic: each operand is a number.

-spec add(term(), term()) -> term().
add(A, B) when is_integer(A), is_integer(B) -> canonical(A + B);
add('NaN', _) -> 'NaN';
add(_, 'NaN') -> 'NaN';
add('Infinity', '-Infinity') -> 'NaN';
add('-Infinity', 'Infinity') -> 'NaN';
add(A, _) when is_atom(A) -> A;
add(_, B) when is_atom(B) -> B;
add(A, B) -> float_result(fun() -> float(A) + float(B) end, fun() -> infinity(A / 2 + B / 2) end).

-spec sub(term(), term()) -> term().
sub(A, B) when is_integer(A), is_integer(B) -> canonical(A - B);
sub(A, B) -> add(A, negate(B)).

-spec mul(term(), term()) -> term().
mul(A, B) when is_integer(A), is_integer(B), A * B =:= 0 ->
    case (A < 0) xor (B < 0) of
        true -> -0.0;
        false -> 0
    end;
mul(A, B) when is_integer(A), is_integer(B) -> canonical(A * B);
mul('NaN', _) -> 'NaN';
mul(_, 'NaN') -> 'NaN';
mul(A, B) when is_atom(A); is_atom(B) ->
    case is_zero(A) orelse is_zero(B) of
        true -> 'NaN';
        false -> infinity(sign(A) * sign(B))
    end;
mul(A, B) -> float_result(fun() -> float(A) * float(B) end, fun() -> infinity(sign(A) * sign(B)) end).

-spec divide(term(), term()) -> term().
divide('NaN', _) -> 'NaN';
divide(_, 'NaN') -> 'NaN';
divide(A, B) when is_atom(A), is_atom(B) -> 'NaN';
divide(A, B) when is_atom(A) -> infinity(sign(A) * sign(B));
divide(A, B) when is_atom(B) -> signed_zero(sign(A) * sign(B));
divide(A, B) when B == 0, A == 0 -> 'NaN';
divide(A, B) when B == 0 -> infinity(sign(A) * sign(B));
divide(A, B) when A == 0 -> signed_zero(sign(A) * sign(B));
divide(A, B) when is_integer(A), is_integer(B), A rem B =:= 0 -> A div B;
divide(A, B) -> float_result(fun() -> A / B end, fun() -> infinity(sign(A) * sign(B)) end).

%% The remainder has the sign of the dividend, as C's fmod.
-spec remainder(term(), term()) -> term().
remainder('NaN', _) -> 'NaN';
remainder(_, 'NaN') -> 'NaN';
remainder(A, _) when is_atom(A) -> 'NaN';
remainder(_, B) when B == 0 -> 'NaN';
remainder(A, B) when is_atom(B) -> A;
remainder(A, B) when is_integer(A), is_integer(B) ->
    case A rem B of
        0 when A < 0 -> -0.0;
        R -> R
    end;
remainder(A, _B) when A == 0 -> A;
remainder(A, B) ->
    case canonical(math:fmod(float(A), float(B))) of
        Z when Z == 0, A < 0 -> -0.0;
        R -> R
    end.

%% Number::exponentiate.
-spec power(term(), term()) -> term().
power(_, E) when E == 0 -> 1;
power(_, 'NaN') -> 'NaN';
power('NaN', _) -> 'NaN';
power(A, B) when is_integer(A), is_integer(B), B >= 0, B =< 64 -> canonical(integer_power(A, B));
power(A, 'Infinity') -> infinite_exponent(abs_compare(A), 'Infinity', 0);
power(A, '-Infinity') -> infinite_exponent(abs_compare(A), 0, 'Infinity');
power('Infinity', B) when B > 0 -> 'Infinity';
power('Infinity', _) -> 0;
power('-Infinity', B) when B > 0 ->
    case is_odd_integer(B) of
        true -> '-Infinity';
        false -> 'Infinity'
    end;
power('-Infinity', B) ->
    case is_odd_integer(B) of
        true -> -0.0;
        false -> 0
    end;
power(A, B) when A == 0 ->
    Negative = A =:= -0.0 andalso is_odd_integer(B),
    case {B > 0, Negative} of
        {true, true} -> -0.0;
        {true, false} -> 0;
        {false, true} -> '-Infinity';
        {false, false} -> 'Infinity'
    end;
power(A, B) when A < 0 ->
    case is_integral(B) of
        false -> 'NaN';
        true ->
            Magnitude = power(-A, B),
            case is_odd_integer(B) of
                true -> negate(Magnitude);
                false -> Magnitude
            end
    end;
power(A, B) ->
    try math:pow(float(A), float(B)) of
        R -> canonical(R)
    catch
        error:badarith ->
            case (A > 1) =:= (B > 0) of
                true -> 'Infinity';
                false -> 0
            end
    end.

abs_compare(A) when is_atom(A) -> gt;
abs_compare(A) when abs(A) > 1 -> gt;
abs_compare(A) when abs(A) == 1 -> eq;
abs_compare(_) -> lt.

infinite_exponent(gt, Big, _Small) -> Big;
infinite_exponent(eq, _, _) -> 'NaN';
infinite_exponent(lt, _Big, Small) -> Small.

is_odd_integer(I) when is_integer(I) -> I rem 2 =/= 0;
is_odd_integer(F) when is_float(F), abs(F) < ?SAFE * 2 -> F == trunc(F) andalso trunc(F) rem 2 =/= 0;
is_odd_integer(_) -> false.

integer_power(_, 0) -> 1;
integer_power(A, B) when B rem 2 =:= 0 -> integer_power(A * A, B div 2);
integer_power(A, B) -> A * integer_power(A * A, B div 2).

-spec negate(term()) -> term().
negate(0) -> -0.0;
negate(I) when is_integer(I) -> -I;
negate(F) when is_float(F) -> canonical(-F);
negate('Infinity') -> '-Infinity';
negate('-Infinity') -> 'Infinity';
negate('NaN') -> 'NaN'.

is_zero(N) -> is_number(N) andalso N == 0.

signed_zero(-1) -> -0.0;
signed_zero(_) -> 0.

%% A float operation that raises badarith on overflow.
float_result(Op, Overflow) ->
    try Op() of
        F -> canonical(F)
    catch
        error:badarith -> Overflow()
    end.

%%% 32-bit integer operations

-spec to_uint32(term()) -> non_neg_integer().
to_uint32(I) when is_integer(I) -> I band 16#FFFFFFFF;
to_uint32(F) when is_float(F) -> trunc(F) band 16#FFFFFFFF;
to_uint32(_) -> 0.

-spec to_int32(term()) -> integer().
to_int32(N) ->
    case to_uint32(N) of
        U when U >= 16#80000000 -> U - 16#100000000;
        U -> U
    end.

-spec bit_and(term(), term()) -> integer().
bit_and(A, B) -> to_int32(A) band to_int32(B).
-spec bit_or(term(), term()) -> integer().
bit_or(A, B) -> to_int32(A) bor to_int32(B).
-spec bit_xor(term(), term()) -> integer().
bit_xor(A, B) -> to_int32(A) bxor to_int32(B).
-spec bit_not(term()) -> integer().
bit_not(A) -> bnot to_int32(A).
-spec shift_left(term(), term()) -> integer().
shift_left(A, B) -> to_int32(to_int32(A) bsl (to_uint32(B) band 31)).
-spec shift_right(term(), term()) -> integer().
shift_right(A, B) -> to_int32(A) bsr (to_uint32(B) band 31).
-spec shift_right_unsigned(term(), term()) -> non_neg_integer().
shift_right_unsigned(A, B) -> to_uint32(A) bsr (to_uint32(B) band 31).

%%% Comparison

%% The order of two numbers, or undefined when either is NaN.
-spec compare(term(), term()) -> lt | eq | gt | undefined.
compare('NaN', _) -> undefined;
compare(_, 'NaN') -> undefined;
compare(A, A) -> eq;
compare('-Infinity', _) -> lt;
compare(_, '-Infinity') -> gt;
compare('Infinity', _) -> gt;
compare(_, 'Infinity') -> lt;
compare(A, B) when A < B -> lt;
compare(A, B) when A > B -> gt;
compare(_, _) -> eq.

%% SameValueZero: the key equality of Map, Set, and includes.
-spec same_value_zero(term(), term()) -> boolean().
same_value_zero(A, B) when is_number(A), is_number(B) -> A == B;
same_value_zero(A, B) -> A =:= B.

%%% Number to text

%% Number::toString with radix 10: the shortest digits that round-trip.
-spec to_string(term()) -> binary().
to_string(I) when is_integer(I) -> integer_to_binary(I);
to_string('NaN') -> <<"NaN">>;
to_string('Infinity') -> <<"Infinity">>;
to_string('-Infinity') -> <<"-Infinity">>;
to_string(F) when F == 0 -> <<"0">>;
to_string(F) when F < 0 -> <<"-", (to_string(-F))/binary>>;
to_string(F) ->
    {Digits, N} = shortest(F),
    K = length(Digits),
    list_to_binary(if
        K =< N, N =< 21 -> Digits ++ lists:duplicate(N - K, $0);
        0 < N, N =< 21 -> {Int, Frac} = lists:split(N, Digits), Int ++ "." ++ Frac;
        -6 < N, N =< 0 -> "0." ++ lists:duplicate(-N, $0) ++ Digits;
        true -> exponent_text(Digits, N - 1)
    end).

%% The shortest digits of a positive double that round-trip, as Digits and N
%% with F = 0.Digits * 10^N, and no trailing zero digit.
shortest(F) ->
    {Mantissa, Exponent} = case string:split(float_to_list(F, [short]), "e") of
        [M] -> {M, 0};
        [M, E] -> {M, list_to_integer(E)}
    end,
    {Int, Frac} = case string:split(Mantissa, ".") of
        [I] -> {I, ""};
        [I, Fr] -> {I, Fr}
    end,
    All = Int ++ Frac,
    Leading = length(All) - length(lists:dropwhile(fun(C) -> C =:= $0 end, All)),
    Digits = string:trim(lists:nthtail(Leading, All), trailing, "0"),
    {Digits, length(Int) - Leading + Exponent}.

exponent_text([D], E) -> [D, $e | exponent_sign(E)];
exponent_text([D | Rest], E) -> [D, $. | Rest] ++ [$e | exponent_sign(E)].

exponent_sign(E) when E >= 0 -> [$+ | integer_to_list(E)];
exponent_sign(E) -> [$- | integer_to_list(-E)].

%% Number::toString with a radix other than 10, as V8's DoubleToRadixCString.
-spec to_radix_string(term(), 2..36) -> binary().
to_radix_string(N, _Radix) when is_atom(N) -> to_string(N);
to_radix_string(I, Radix) when is_integer(I) -> list_to_binary(string:lowercase(integer_to_list(I, Radix)));
to_radix_string(F, Radix) when F < 0 -> <<"-", (to_radix_string(-F, Radix))/binary>>;
to_radix_string(F, Radix) ->
    Integer = math:floor(F),
    Fraction = F - Integer,
    Delta = max(next_double(0.0), 0.5 * (next_double(F) - F)),
    {FractionDigits, Integer1} = case Fraction >= Delta of
        true -> radix_fraction(Fraction, Delta, Radix, [], Integer);
        false -> {[], Integer}
    end,
    IntegerDigits = radix_integer(Integer1, Radix, []),
    Text = case FractionDigits of
        [] -> IntegerDigits;
        _ -> IntegerDigits ++ "." ++ FractionDigits
    end,
    list_to_binary(Text).

%% The fraction digits, most significant first, and the integer part after
%% a carry.
radix_fraction(Fraction0, Delta0, Radix, Acc, Integer) ->
    Fraction1 = Fraction0 * Radix,
    Delta = Delta0 * Radix,
    Digit = trunc(Fraction1),
    Fraction = Fraction1 - Digit,
    Acc1 = [Digit | Acc],
    case Fraction > 0.5 orelse (Fraction == 0.5 andalso Digit band 1 =:= 1) of
        true when Fraction + Delta > 1 ->
            carry(Acc1, Radix, Integer);
        _ when Fraction >= Delta ->
            radix_fraction(Fraction, Delta, Radix, Acc1, Integer);
        _ ->
            {[digit_char(D) || D <- lists:reverse(Acc1)], Integer}
    end.

%% Rounds the written digits up, carrying into the integer part.
carry([], _Radix, Integer) -> {[], Integer + 1};
carry([D | Rest], Radix, Integer) when D + 1 < Radix -> {[digit_char(X) || X <- lists:reverse([D + 1 | Rest])], Integer};
carry([_ | Rest], Radix, Integer) -> carry(Rest, Radix, Integer).

radix_integer(Integer, Radix, Acc) ->
    case exponent_of(Integer / Radix) > 0 of
        true -> radix_integer(Integer / Radix, Radix, [$0 | Acc]);
        false -> radix_digits(Integer, Radix, Acc)
    end.

radix_digits(Integer, Radix, Acc) ->
    Remainder = math:fmod(Integer, float(Radix)),
    Acc1 = [digit_char(trunc(Remainder)) | Acc],
    case (Integer - Remainder) / Radix of
        Next when Next > 0 -> radix_digits(Next, Radix, Acc1);
        _ -> Acc1
    end.

%% The exponent of Double::Exponent() in V8: value = significand * 2^e with
%% a 53-bit significand.
exponent_of(F) ->
    <<_:1, Exp:11, _:52>> = <<F/float>>,
    case Exp of
        0 -> -1074;
        _ -> Exp - 1075
    end.

next_double(F) ->
    <<Bits:64>> = <<F/float>>,
    <<Next/float>> = <<(Bits + 1):64>>,
    Next.

digit_char(D) when D < 10 -> $0 + D;
digit_char(D) -> $a + D - 10.

%% Number.prototype.toFixed with 0 =< F =< 100.
-spec to_fixed(term(), 0..100) -> binary().
to_fixed(N, _F) when is_atom(N) -> to_string(N);
to_fixed(X, F) ->
    Sign = case X < 0 of
        true -> "-";
        false -> ""
    end,
    case abs(X) >= 1.0e21 of
        true -> to_string(X);
        false ->
            Nint = round_scaled(decompose(X), F),
            M = integer_to_list(Nint),
            Text = case F of
                0 -> M;
                _ ->
                    Padded = case length(M) =< F of
                        true -> lists:duplicate(F + 1 - length(M), $0) ++ M;
                        false -> M
                    end,
                    {A, B} = lists:split(length(Padded) - F, Padded),
                    A ++ "." ++ B
            end,
            list_to_binary(Sign ++ Text)
    end.

%% round(x * 10^P) for x = M * 2^E, halves rounded up; P may be negative.
round_scaled({M, E}, P) ->
    {Num, Den} = scaled({M, E}, P),
    (2 * Num + Den) div (2 * Den).

%% x * 10^P as the fraction Num / Den.
scaled({M, E}, P) ->
    {Num0, Den0} = case E >= 0 of
        true -> {M bsl E, 1};
        false -> {M, 1 bsl -E}
    end,
    case P >= 0 of
        true -> {Num0 * pow10(P), Den0};
        false -> {Num0, Den0 * pow10(-P)}
    end.

pow10(N) -> integer_pow(10, N).

integer_pow(_, 0) -> 1;
integer_pow(B, N) when N rem 2 =:= 0 -> integer_pow(B * B, N div 2);
integer_pow(B, N) -> B * integer_pow(B * B, N div 2).

%% The digits of x rounded to P significant digits, and the decimal
%% exponent E of the first: x ~ 0.D1D2...Dp * 10^(E + 1).
significant(X, P) ->
    Parts = decompose(X),
    E0 = estimate_exponent(X),
    E = fix_exponent(Parts, E0),
    N = round_scaled(Parts, P - 1 - E),
    case N >= pow10(P) of
        true -> {integer_to_list(N div 10), E + 1};
        false -> {integer_to_list(N), E}
    end.

estimate_exponent(X) -> floor(math:log10(float(X))).

%% The exponent E with 10^E =< x < 10^(E+1), from an estimate.
fix_exponent(Parts, E) ->
    {Num, Den} = scaled(Parts, -E),
    if
        Num < Den -> fix_exponent(Parts, E - 1);
        Num >= 10 * Den -> fix_exponent(Parts, E + 1);
        true -> E
    end.

%% Number.prototype.toExponential with F fraction digits, or shortest.
-spec to_exponential(term(), shortest | 0..100) -> binary().
to_exponential(X, F) when X < 0 ->
    <<"-", (to_exponential(-X, F))/binary>>;
to_exponential(X, F) when X == 0 ->
    Zeros = case F of
        shortest -> "0";
        _ -> lists:duplicate(F + 1, $0)
    end,
    list_to_binary(point_after_first(Zeros) ++ "e+0");
to_exponential(X, shortest) ->
    {Digits, N} = shortest(float(X)),
    list_to_binary(point_after_first(Digits) ++ [$e | exponent_sign(N - 1)]);
to_exponential(X, F) ->
    {Digits, E} = significant(X, F + 1),
    list_to_binary(point_after_first(Digits) ++ [$e | exponent_sign(E)]).

point_after_first([D]) -> [D];
point_after_first([D | Rest]) -> [D, $. | Rest].

%% Number.prototype.toPrecision with 1 =< P =< 100.
-spec to_precision(term(), 1..100) -> binary().
to_precision(X, P) when X < 0 -> <<"-", (to_precision(-X, P))/binary>>;
to_precision(X, P) when X == 0 ->
    list_to_binary(case P of
        1 -> "0";
        _ -> "0." ++ lists:duplicate(P - 1, $0)
    end);
to_precision(X, P) ->
    {Digits, E} = significant(X, P),
    list_to_binary(if
        E < -6; E >= P -> point_after_first(Digits) ++ [$e | exponent_sign(E)];
        E =:= P - 1 -> Digits;
        E >= 0 -> {A, B} = lists:split(E + 1, Digits), A ++ "." ++ B;
        true -> "0." ++ lists:duplicate(-(E + 1), $0) ++ Digits
    end).

%% Number.prototype.toLocaleString in the en-US locale, with the options of
%% Intl.NumberFormat that it honors: style (decimal, percent, currency),
%% currency, the fraction and integer digits, and useGrouping. As ICU does,
%% it rounds the shortest decimal digits of the number half away from zero.
to_locale_string(N, Options) ->
    Get = fun(Key) ->
                  case ?IS_OBJECT(Options) of
                      true -> buoy_ref:get(Options, Key);
                      false -> undefined
                  end
          end,
    Style = case Get(<<"style">>) of
        undefined -> decimal;
        S0 ->
            case buoy_ref:to_string(S0) of
                <<"percent">> -> percent;
                <<"currency">> -> currency;
                <<"decimal">> -> decimal;
                _ -> range_error(<<"Value of style is out of range">>)
            end
    end,
    Currency = case Style of
        currency ->
            case Get(<<"currency">>) of
                undefined -> buoy_ref:type_error(<<"Currency code is required with currency style.">>);
                Code -> string:uppercase(buoy_ref:to_string(Code))
            end;
        _ -> none
    end,
    {DefaultMin, DefaultMax} = case Style of
        percent -> {0, 0};
        currency when Currency =:= <<"JPY">> -> {0, 0};
        currency -> {2, 2};
        decimal -> {0, 3}
    end,
    Digits = fun(Key) ->
                     case Get(Key) of
                         undefined -> undefined;
                         V ->
                             case to_integer_or_infinity(buoy_ref:to_number(V)) of
                                 I when is_integer(I), I >= 0, I =< 100 -> I;
                                 _ -> range_error(<<Key/binary, " value is out of range.">>)
                             end
                     end
             end,
    {Min, Max} = case {Digits(<<"minimumFractionDigits">>), Digits(<<"maximumFractionDigits">>)} of
        {undefined, undefined} -> {DefaultMin, DefaultMax};
        {Mn, undefined} -> {Mn, max(Mn, DefaultMax)};
        {undefined, Mx} -> {min(DefaultMin, Mx), Mx};
        {Mn, Mx} when Mn =< Mx -> {Mn, Mx};
        _ -> range_error(<<"maximumFractionDigits value is out of range.">>)
    end,
    MinInteger = case Digits(<<"minimumIntegerDigits">>) of
        undefined -> 1;
        I0 -> max(1, I0)
    end,
    Grouping = case Get(<<"useGrouping">>) of
        undefined -> true;
        G -> buoy_ref:truthy(G)
    end,
    Text = case N of
        'NaN' -> "NaN";
        'Infinity' -> [<<"∞"/utf8>>];
        '-Infinity' -> [<<"-∞"/utf8>>];
        _ ->
            Negative = N < 0 orelse N =:= -0.0,
            Scale = case Style of
                percent -> 2;
                _ -> 0
            end,
            {Int, Frac} = locale_digits(abs(N), Scale, Min, Max),
            IntText = lists:duplicate(max(0, MinInteger - length(Int)), $0) ++ Int,
            Grouped = case Grouping of
                true -> group(IntText);
                false -> IntText
            end,
            Body = case Frac of
                "" -> Grouped;
                _ -> Grouped ++ "." ++ Frac
            end,
            Sign = case Negative of
                true -> "-";
                false -> ""
            end,
            case Style of
                percent -> Sign ++ Body ++ "%";
                currency -> [Sign, currency_symbol(Currency), Body];
                decimal -> Sign ++ Body
            end
    end,
    buoy_ref_string:from_utf8(iolist_to_binary(Text)).

currency_symbol(<<"USD">>) -> "$";
currency_symbol(<<"EUR">>) -> [<<"€"/utf8>>];
currency_symbol(<<"GBP">>) -> [<<"£"/utf8>>];
currency_symbol(<<"JPY">>) -> [<<"¥"/utf8>>];
currency_symbol(<<"INR">>) -> [<<"₹"/utf8>>];
currency_symbol(<<"CAD">>) -> "CA$";
currency_symbol(<<"AUD">>) -> "A$";
currency_symbol(Code) -> [Code, <<" "/utf8>>].

%% The integer and fraction digits of a positive number times 10^Scale,
%% rounded to at most Max fraction digits and padded to Min.
locale_digits(X, Scale, Min, Max) ->
    {Digits0, N0} = case X of
        Z when Z == 0 -> {"", 1};
        I when is_integer(I) ->
            All = integer_to_list(I),
            {string:trim(All, trailing, "0"), length(All)};
        F -> shortest(F)
    end,
    N = N0 + Scale,
    Keep = N + Max,
    {Digits, N1} = round_digits(Digits0, N, Keep),
    Padded = Digits ++ lists:duplicate(max(0, N1 + Max - length(Digits)), $0),
    {IntDigits, FracDigits} = case N1 > 0 of
        true -> lists:split(min(N1, length(Padded)), Padded);
        false -> {"", lists:duplicate(-N1, $0) ++ Padded}
    end,
    Int = case string:trim(IntDigits, leading, "0") of
        "" -> "0";
        Trimmed -> Trimmed
    end,
    Frac0 = lists:sublist(FracDigits, Max),
    Frac = trim_fraction(Frac0, Min),
    {Int, Frac}.

%% Rounds 0.Digits x 10^N to Keep significant digits, half away from zero:
%% {Digits, N}.
round_digits(Digits, N, Keep) when Keep >= length(Digits) -> {Digits, N};
round_digits(_Digits, N, Keep) when Keep < 0 -> {"", N};
round_digits(Digits, N, Keep) ->
    {Kept, [First | _]} = lists:split(Keep, Digits),
    case First >= $5 of
        false -> {Kept, N};
        true ->
            case increment(lists:reverse(Kept)) of
                {carry, Up} -> {[$1 | Up], N + 1};
                Up -> {Up, N}
            end
    end.

increment([]) -> {carry, []};
increment([$9 | Rest]) ->
    case increment(Rest) of
        {carry, Up} -> {carry, Up ++ "0"};
        Up -> Up ++ "0"
    end;
increment([D | Rest]) -> lists:reverse(Rest) ++ [D + 1].

trim_fraction(Frac, Min) ->
    {Required, Optional} = lists:split(min(Min, length(Frac)), Frac),
    Required ++ lists:duplicate(Min - length(Required), $0) ++ string:trim(Optional, trailing, "0").

group(Digits) when length(Digits) =< 3 -> Digits;
group(Digits) ->
    {Head, Tail} = lists:split(length(Digits) - 3, Digits),
    group(Head) ++ "," ++ Tail.

%%% Text to number

%% StringToNumber: a string of the engine to a number.
-spec from_string(buoy_ref_string:js_string()) -> term().
from_string(S) ->
    case trim(buoy_ref_string:units(S)) of
        [] -> 0;
        [$0, X | Digits] when X =:= $x; X =:= $X -> non_decimal(Digits, 16);
        [$0, O | Digits] when O =:= $o; O =:= $O -> non_decimal(Digits, 8);
        [$0, B | Digits] when B =:= $b; B =:= $B -> non_decimal(Digits, 2);
        Text ->
            case parse_decimal(Text) of
                {Value, []} -> Value;
                _ -> 'NaN'
            end
    end.

trim(Units) ->
    lists:reverse(lists:dropwhile(fun buoy_ref_string:is_whitespace/1,
                                  lists:reverse(lists:dropwhile(fun buoy_ref_string:is_whitespace/1, Units)))).

non_decimal([], _Radix) -> 'NaN';
non_decimal(Digits, Radix) ->
    case lists:all(fun(D) -> digit_value(D) < Radix end, Digits) of
        true -> canonical(lists:foldl(fun(D, Acc) -> Acc * Radix + digit_value(D) end, 0, Digits));
        false -> 'NaN'
    end.

digit_value(C) when C >= $0, C =< $9 -> C - $0;
digit_value(C) when C >= $a, C =< $z -> C - $a + 10;
digit_value(C) when C >= $A, C =< $Z -> C - $A + 10;
digit_value(_) -> 99.

%% The longest prefix of Units that is a StrDecimalLiteral: {Value, Rest},
%% or none.
-spec parse_decimal([non_neg_integer()]) -> {term(), [non_neg_integer()]} | none.
parse_decimal([$- | Rest]) ->
    case unsigned_decimal(Rest) of
        {Value, Tail} -> {negate(Value), Tail};
        none -> none
    end;
parse_decimal([$+ | Rest]) -> unsigned_decimal(Rest);
parse_decimal(Units) -> unsigned_decimal(Units).

unsigned_decimal("Infinity" ++ Rest) -> {'Infinity', Rest};
unsigned_decimal(Units) ->
    {Int, Rest1} = lists:splitwith(fun is_digit/1, Units),
    {Frac, Rest2} = case Rest1 of
        [$. | After] -> lists:splitwith(fun is_digit/1, After);
        _ -> {none, Rest1}
    end,
    case {Int, Frac} of
        {[], none} -> none;
        {[], []} -> none;
        _ ->
            FracDigits = case Frac of
                none -> [];
                _ -> Frac
            end,
            {Exponent, Rest3} = exponent_part(Rest2),
            {decimal_value(Int ++ FracDigits, Exponent - length(FracDigits)), Rest3}
    end.

exponent_part([E | Rest] = Units) when E =:= $e; E =:= $E ->
    {Sign, Digits} = case Rest of
        [$+ | D] -> {1, D};
        [$- | D] -> {-1, D};
        D -> {1, D}
    end,
    case lists:splitwith(fun is_digit/1, Digits) of
        {[], _} -> {0, Units};
        {Ds, Tail} -> {Sign * list_to_integer(Ds), Tail}
    end;
exponent_part(Units) -> {0, Units}.

is_digit(C) -> C >= $0 andalso C =< $9.

%% The double nearest to Digits * 10^Exponent.
decimal_value(Digits, Exponent) ->
    case lists:dropwhile(fun(C) -> C =:= $0 end, Digits) of
        [] -> 0;
        Significant when Exponent + length(Significant) > 310 -> 'Infinity';
        Significant when Exponent + length(Significant) < -330 -> 0;
        Significant ->
            Text = Significant ++ ".0e" ++ integer_to_list(Exponent),
            try list_to_float(Text) of
                F -> canonical(F)
            catch
                error:badarg -> 'Infinity'
            end
    end.

%% parseFloat: the longest prefix that is a StrDecimalLiteral.
parse_float(S) ->
    Units = lists:dropwhile(fun buoy_ref_string:is_whitespace/1, buoy_ref_string:units(S)),
    case parse_decimal(Units) of
        {Value, _} -> Value;
        none -> 'NaN'
    end.

%% parseInt with the radix R of ToInt32.
parse_int(S, R0) when is_binary(S), byte_size(S) > 0, byte_size(S) =< 15, (R0 =:= 0 orelse R0 =:= 10) ->
    %% Up to 15 decimal digits are exact, so the common case is one BIF.
    case is_decimal(S) of
        true -> binary_to_integer(S);
        false -> parse_int_units(S, R0)
    end;
parse_int(S, R0) -> parse_int_units(S, R0).

is_decimal(<<C, Rest/binary>>) when C >= $0, C =< $9 -> is_decimal(Rest);
is_decimal(<<>>) -> true;
is_decimal(_) -> false.

parse_int_units(S, R0) ->
    Units0 = lists:dropwhile(fun buoy_ref_string:is_whitespace/1, buoy_ref_string:units(S)),
    {Sign, Units1} = case Units0 of
        [$- | T] -> {-1, T};
        [$+ | T] -> {1, T};
        _ -> {1, Units0}
    end,
    {R, Units} = case {R0, Units1} of
        {0, [$0, X | T1]} when X =:= $x; X =:= $X -> {16, T1};
        {16, [$0, X | T1]} when X =:= $x; X =:= $X -> {16, T1};
        {0, _} -> {10, Units1};
        _ -> {R0, Units1}
    end,
    case R >= 2 andalso R =< 36 of
        false -> 'NaN';
        true ->
            case lists:takewhile(fun(C) -> digit_value(C) < R end, Units) of
                [] -> 'NaN';
                Digits when R =:= 10 ->
                    Value = decimal_value(Digits, 0),
                    case Sign of
                        -1 -> negate(Value);
                        1 -> Value
                    end;
                Digits ->
                    Value = canonical(lists:foldl(fun(D, Acc) -> Acc * R + digit_value(D) end, 0, Digits)),
                    case Sign of
                        -1 -> negate(Value);
                        1 -> Value
                    end
            end
    end.

%% ToIntegerOrInfinity of a number: an integer, or an infinity.
-spec to_integer_or_infinity(term()) -> integer() | 'Infinity' | '-Infinity'.
to_integer_or_infinity(I) when is_integer(I) -> I;
to_integer_or_infinity(F) when is_float(F) -> trunc(F);
to_integer_or_infinity('NaN') -> 0;
to_integer_or_infinity(Inf) -> Inf.
