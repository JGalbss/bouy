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
-module(bouy_ref_number).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).
-export([canonical/1, add/2, sub/2, mul/2, divide/2, remainder/2, power/2, negate/1]).
-export([to_int32/1, to_uint32/1, bit_and/2, bit_or/2, bit_xor/2, bit_not/1]).
-export([shift_left/2, shift_right/2, shift_right_unsigned/2, compare/2, same_value_zero/2]).
-export([to_string/1, from_string/1, to_integer_or_infinity/1]).

-import(bouy_ref_realm, [arg/2, record/4, ctor_record/5]).

-define(SAFE, 9007199254740992).

%%% The family

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Number.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"Number.prototype">>, [<<"toString">>, <<"toFixed">>, <<"toPrecision">>, <<"toExponential">>, <<"toLocaleString">>, <<"valueOf">>]) ++ [{<<"constructor">>, constructor()}], none)},
     {{builtin, <<"Number">>}, ctor_record(<<"Number">>, 1, {'$o', 'Number.prototype'}, ?METHODS(<<"Number">>, [<<"isInteger">>, <<"isSafeInteger">>, <<"isFinite">>, <<"isNaN">>, <<"parseFloat">>, <<"parseInt">>])
         ++ [{<<"MAX_SAFE_INTEGER">>, 9007199254740991}, {<<"MIN_SAFE_INTEGER">>, -9007199254740991}, {<<"EPSILON">>, 2.220446049250313e-16},
             {<<"MAX_VALUE">>, 1.7976931348623157e308}, {<<"MIN_VALUE">>, 5.0e-324}, {<<"POSITIVE_INFINITY">>, 'Infinity'},
             {<<"NEGATIVE_INFINITY">>, '-Infinity'}, {<<"NaN">>, 'NaN'}], fun bouy_ref_realm:not_constructible/2)}].

-spec globals() -> [{binary(), term()}].
globals() ->
    [{<<"Number">>, constructor()}, {<<"NaN">>, 'NaN'}, {<<"Infinity">>, 'Infinity'}]
    ++ ?METHODS(<<"globalThis">>, [<<"parseInt">>, <<"parseFloat">>, <<"isNaN">>, <<"isFinite">>]).

constructor() -> bouy_ref_realm:constructor(?MODULE, <<"Number">>).

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"Number">>, _This, []) -> 0;
call_constructor(<<"Number">>, _This, [V | _]) -> bouy_ref:to_number(V).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Number.prototype">>, Name, This, Args) ->
    N = this_number(This, Name),
    from_value(bouy_number:call(Name, N, [value_arg(A) || A <- Args]));
method(<<"Number">>, <<"isInteger">>, _This, Args) -> is_integral(arg(1, Args));
method(<<"Number">>, <<"isSafeInteger">>, _This, Args) ->
    is_integral(arg(1, Args)) andalso abs(arg(1, Args)) =< ?SAFE - 1;
method(<<"Number">>, <<"isFinite">>, _This, Args) -> is_number(arg(1, Args));
method(<<"Number">>, <<"isNaN">>, _This, Args) -> arg(1, Args) =:= 'NaN';
method(_, <<"parseFloat">>, _This, Args) ->
    canonical(bouy_number:'parseFloat'([utf8_arg(arg(1, Args))]));
method(_, <<"parseInt">>, _This, Args) ->
    canonical(bouy_number:'parseInt'([utf8_arg(arg(1, Args)), value_arg(arg(2, Args))]));
method(<<"globalThis">>, <<"isNaN">>, _This, Args) -> bouy_ref:to_number(arg(1, Args)) =:= 'NaN';
method(<<"globalThis">>, <<"isFinite">>, _This, Args) -> is_number(bouy_ref:to_number(arg(1, Args))).

this_number(N, _Name) when ?IS_NUMBER(N) -> N;
this_number(_, Name) -> bouy_ref:type_error(<<"Number.prototype.", Name/binary, " requires that 'this' be a Number">>).

is_integral(I) when is_integer(I) -> true;
is_integral(F) when is_float(F) -> F == trunc(F);
is_integral(_) -> false.

%% The value runtime implements the formatting methods over UTF-8 strings;
%% its results are ASCII, which is also a one-byte string.
value_arg(S) when ?IS_STRING(S) -> bouy_ref_string:to_utf8(S);
value_arg(V) -> V.

utf8_arg(V) -> bouy_ref_string:to_utf8(bouy_ref:to_string(V)).

from_value(N) when ?IS_NUMBER(N) -> canonical(N);
from_value(V) -> V.

%%% The representation

%% The canonical form of an Erlang number or of a number of the value core.
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
remainder(A, B) -> canonical(math:fmod(float(A), float(B))).

-spec power(term(), term()) -> term().
power(A, B) when is_integer(A), is_integer(B), B >= 0, B =< 64 -> canonical(integer_power(A, B));
power(A, B) -> canonical(bouy_rt:power(A, B)).

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

wrap32(I) -> to_int32(I).

-spec bit_and(term(), term()) -> integer().
bit_and(A, B) -> to_int32(A) band to_int32(B).
-spec bit_or(term(), term()) -> integer().
bit_or(A, B) -> to_int32(A) bor to_int32(B).
-spec bit_xor(term(), term()) -> integer().
bit_xor(A, B) -> to_int32(A) bxor to_int32(B).
-spec bit_not(term()) -> integer().
bit_not(A) -> bnot to_int32(A).
-spec shift_left(term(), term()) -> integer().
shift_left(A, B) -> wrap32(to_int32(A) bsl (to_uint32(B) band 31)).
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

%%% Conversions

%% Number::toString with radix 10: the shortest digits that round-trip.
-spec to_string(term()) -> binary().
to_string(I) when is_integer(I) -> integer_to_binary(I);
to_string(N) -> bouy_number:to_string(N).

%% StringToNumber: a string of the engine to a number.
-spec from_string(bouy_ref_string:js_string()) -> term().
from_string(S) -> canonical(bouy_number:from_string(bouy_ref_string:to_utf8(S))).

%% ToIntegerOrInfinity of a number: an integer, or an infinity.
-spec to_integer_or_infinity(term()) -> integer() | 'Infinity' | '-Infinity'.
to_integer_or_infinity(I) when is_integer(I) -> I;
to_integer_or_infinity(F) when is_float(F) -> trunc(F);
to_integer_or_infinity('NaN') -> 0;
to_integer_or_infinity(Inf) -> Inf.
