%% The BigInt family. BigInt values are {'$bigint', Integer} (contract,
%% "Reference semantics"): the tag keeps 1n and 1 apart, and the Erlang
%% integer has any size, so every operation is exact. Erlang's bitwise
%% operators act on integers as infinite two's complement, as BigInt does.
-module(buoy_ref_bigint).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, wrap/2]).
-export([operate/3, negate/1, bit_not/1, to_big_int/1, from_string/1, compare_number/2, equals_number/2]).
-export([as_int_n/2, as_uint_n/2, to_string/2]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).

%% V8 limits a BigInt to 2^30 bits.
-define(MAX_BITS, 1073741824).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'BigInt.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"BigInt.prototype">>, [{<<"toString">>, 0}, {<<"toLocaleString">>, 0}, {<<"valueOf">>, 0}])
         ++ [{<<"constructor">>, constructor()}, {?SYM(toStringTag), <<"BigInt">>, 4}], none)},
     {{builtin, <<"BigInt">>}, ctor_record(<<"BigInt">>, 1, {'$o', 'BigInt.prototype'}, ?METHODS(<<"BigInt">>, [{<<"asIntN">>, 2}, {<<"asUintN">>, 2}]), fun buoy_ref_realm:not_constructible/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"BigInt">>, constructor()}].

constructor() -> buoy_ref_realm:constructor(?MODULE, <<"BigInt">>).

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"BigInt">>, _This, Args) ->
    case buoy_ref:to_primitive(arg(1, Args), number) of
        N when ?IS_NUMBER(N) -> from_number(N);
        P -> to_big_int(P)
    end.

%% A BigInt object: the class bigint, its [[BigIntData]] in the slots.
-spec wrap(term(), term()) -> term().
wrap(B, Proto) -> buoy_heap:new_exotic(bigint, Proto, B).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"BigInt.prototype">>, <<"valueOf">>, This, _Args) -> this_big_int(This, <<"valueOf">>);
method(<<"BigInt.prototype">>, <<"toLocaleString">>, This, _Args) ->
    {'$bigint', I} = this_big_int(This, <<"toLocaleString">>),
    Sign = case I < 0 of
        true -> "-";
        false -> ""
    end,
    list_to_binary(Sign ++ group(integer_to_list(abs(I))));
method(<<"BigInt.prototype">>, <<"toString">>, This, Args) ->
    B = this_big_int(This, <<"toString">>),
    Radix = case arg(1, Args) of
        undefined -> 10;
        R -> buoy_ref_number:to_integer_or_infinity(buoy_ref:to_number(R))
    end,
    is_integer(Radix) andalso Radix >= 2 andalso Radix =< 36 orelse
        buoy_heap:throw_error('RangeError', <<"toString() radix must be between 2 and 36">>),
    to_string(B, Radix);
method(<<"BigInt">>, <<"asIntN">>, _This, Args) ->
    Bits = to_index(arg(1, Args)),
    {'$bigint', I} = to_big_int(arg(2, Args)),
    {'$bigint', as_int_n(Bits, I)};
method(<<"BigInt">>, <<"asUintN">>, _This, Args) ->
    Bits = to_index(arg(1, Args)),
    {'$bigint', I} = to_big_int(arg(2, Args)),
    {'$bigint', as_uint_n(Bits, I)}.

this_big_int({'$bigint', _} = B, _Name) -> B;
this_big_int({'$o', _} = O, Name) ->
    case buoy_heap:class_of(O) of
        bigint -> buoy_heap:slots(O);
        _ -> not_a_big_int(Name)
    end;
this_big_int(_, Name) -> not_a_big_int(Name).

-spec not_a_big_int(binary()) -> no_return().
not_a_big_int(Name) -> buoy_ref:type_error(<<"BigInt.prototype.", Name/binary, " requires that 'this' be a BigInt">>).

%% The digits grouped by three, as the en-US locale writes them.
group(Digits) when length(Digits) =< 3 -> Digits;
group(Digits) ->
    {Head, Tail} = lists:split(length(Digits) - 3, Digits),
    group(Head) ++ "," ++ Tail.

-spec to_string({'$bigint', integer()}, 2..36) -> binary().
to_string({'$bigint', I}, 10) -> integer_to_binary(I);
to_string({'$bigint', I}, Radix) -> list_to_binary(string:lowercase(integer_to_list(I, Radix))).

%% ToIndex for asIntN and asUintN.
to_index(V) ->
    case buoy_ref_number:to_integer_or_infinity(buoy_ref:to_number(V)) of
        I when is_integer(I), I >= 0, I =< 9007199254740991 -> I;
        _ -> buoy_heap:throw_error('RangeError', <<"Invalid value: not (convertible to) a safe integer">>)
    end.

-spec as_uint_n(non_neg_integer(), integer()) -> non_neg_integer().
as_uint_n(0, _I) -> 0;
as_uint_n(Bits, I) when I >= 0 ->
    case bit_length(I) =< Bits of
        true -> I;
        false -> I band ((1 bsl Bits) - 1)
    end;
as_uint_n(Bits, _I) when Bits > ?MAX_BITS -> too_big();
as_uint_n(Bits, I) -> I band ((1 bsl Bits) - 1).

-spec as_int_n(non_neg_integer(), integer()) -> integer().
as_int_n(0, _I) -> 0;
as_int_n(Bits, I) ->
    case bit_length(abs(I)) < Bits of
        true -> I;
        false ->
            Mod = I band ((1 bsl Bits) - 1),
            case Mod >= 1 bsl (Bits - 1) of
                true -> Mod - (1 bsl Bits);
                false -> Mod
            end
    end.

%% The bits of a non-negative integer.
bit_length(I) when I < 256 -> small_bits(I, 0);
bit_length(I) ->
    <<First, _/binary>> = Bytes = binary:encode_unsigned(I),
    (byte_size(Bytes) - 1) * 8 + small_bits(First, 0).

small_bits(0, N) -> N;
small_bits(I, N) -> small_bits(I bsr 1, N + 1).

%% NumberToBigInt.
from_number(N) when is_integer(N) -> {'$bigint', N};
from_number(F) when is_float(F), F == trunc(F) -> {'$bigint', trunc(F)};
from_number(N) ->
    buoy_heap:throw_error('RangeError', buoy_ref_string:concat([<<"The number ">>, buoy_ref_number:to_string(N),
                                                                 <<" cannot be converted to a BigInt because it is not an integer">>])).

%% ToBigInt.
-spec to_big_int(term()) -> {'$bigint', integer()}.
to_big_int(V) ->
    case buoy_ref:to_primitive(V, number) of
        {'$bigint', _} = B -> B;
        true -> {'$bigint', 1};
        false -> {'$bigint', 0};
        S when ?IS_STRING(S) ->
            case from_string(S) of
                undefined ->
                    buoy_heap:throw_error('SyntaxError', buoy_ref_string:concat([<<"Cannot convert ">>, S, <<" to a BigInt">>]));
                B -> B
            end;
        P -> buoy_ref:type_error(buoy_ref_string:concat([<<"Cannot convert ">>, buoy_ref:describe(P), <<" to a BigInt">>]))
    end.

%% StringToBigInt: the BigInt of a string, or undefined.
-spec from_string(buoy_ref_string:js_string()) -> {'$bigint', integer()} | undefined.
from_string(S) ->
    Units = lists:reverse(lists:dropwhile(fun buoy_ref_string:is_whitespace/1,
                                          lists:reverse(lists:dropwhile(fun buoy_ref_string:is_whitespace/1, buoy_ref_string:units(S))))),
    case Units of
        [] -> {'$bigint', 0};
        [$0, X | Digits] when X =:= $x; X =:= $X -> digits(Digits, 16);
        [$0, O | Digits] when O =:= $o; O =:= $O -> digits(Digits, 8);
        [$0, B | Digits] when B =:= $b; B =:= $B -> digits(Digits, 2);
        [$- | Digits] -> negative(digits(Digits, 10));
        [$+ | Digits] -> digits(Digits, 10);
        Digits -> digits(Digits, 10)
    end.

negative({'$bigint', I}) -> {'$bigint', -I};
negative(undefined) -> undefined.

digits([], _Radix) -> undefined;
digits(Units, Radix) ->
    case lists:all(fun(U) -> U < 128 andalso digit_value(U) < Radix end, Units) of
        true -> {'$bigint', list_to_integer(Units, Radix)};
        false -> undefined
    end.

digit_value(C) when C >= $0, C =< $9 -> C - $0;
digit_value(C) when C >= $a, C =< $z -> C - $a + 10;
digit_value(C) when C >= $A, C =< $Z -> C - $A + 10;
digit_value(_) -> 99.

%%% Operators: each operand is an Erlang integer, and the result a BigInt.

-spec operate(atom(), integer(), integer()) -> {'$bigint', integer()}.
operate(add, X, Y) -> {'$bigint', X + Y};
operate(sub, X, Y) -> {'$bigint', X - Y};
operate(mul, X, Y) ->
    bit_length(abs(X)) + bit_length(abs(Y)) > ?MAX_BITS andalso too_big(),
    {'$bigint', X * Y};
operate(divide, _X, 0) -> division_by_zero();
operate(divide, X, Y) -> {'$bigint', X div Y};
operate(remainder, _X, 0) -> division_by_zero();
operate(remainder, X, Y) -> {'$bigint', X rem Y};
operate(power, _X, Y) when Y < 0 -> buoy_heap:throw_error('RangeError', <<"Exponent must be non-negative">>);
operate(power, X, Y) -> {'$bigint', power(X, Y)};
operate(bit_and, X, Y) -> {'$bigint', X band Y};
operate(bit_or, X, Y) -> {'$bigint', X bor Y};
operate(bit_xor, X, Y) -> {'$bigint', X bxor Y};
operate(shift_left, X, Y) -> {'$bigint', shift(X, Y)};
operate(shift_right, X, Y) -> {'$bigint', shift(X, -Y)};
operate(shift_right_unsigned, _X, _Y) -> buoy_ref:type_error(<<"BigInts have no unsigned right shift, use >> instead">>).

power(_X, 0) -> 1;
power(X, _Y) when X =:= 0; X =:= 1 -> X;
power(-1, Y) when Y rem 2 =:= 0 -> 1;
power(-1, _Y) -> -1;
power(X, Y) ->
    bit_length(abs(X)) * Y > ?MAX_BITS andalso too_big(),
    integer_pow(X, Y).

integer_pow(_, 0) -> 1;
integer_pow(B, N) when N rem 2 =:= 0 -> integer_pow(B * B, N div 2);
integer_pow(B, N) -> B * integer_pow(B * B, N div 2).

%% X * 2^Y, rounded toward -infinity for a negative Y.
shift(0, _Y) -> 0;
shift(X, Y) when Y >= 0 ->
    Y + bit_length(abs(X)) > ?MAX_BITS andalso too_big(),
    X bsl Y;
shift(X, Y) when -Y > ?MAX_BITS ->
    case X < 0 of
        true -> -1;
        false -> 0
    end;
shift(X, Y) -> X bsr -Y.

-spec negate(integer()) -> {'$bigint', integer()}.
negate(X) -> {'$bigint', -X}.

-spec bit_not(integer()) -> {'$bigint', integer()}.
bit_not(X) -> {'$bigint', bnot X}.

-spec division_by_zero() -> no_return().
division_by_zero() -> buoy_heap:throw_error('RangeError', <<"Division by zero">>).

-spec too_big() -> no_return().
too_big() -> buoy_heap:throw_error('RangeError', <<"Maximum BigInt size exceeded">>).

%%% Comparison with numbers

%% The order of the BigInt I and the number N, or undefined for NaN.
-spec compare_number(integer(), term()) -> lt | eq | gt | undefined.
compare_number(_I, 'NaN') -> undefined;
compare_number(_I, 'Infinity') -> lt;
compare_number(_I, '-Infinity') -> gt;
compare_number(I, N) when is_integer(N) -> order(I, N);
compare_number(I, F) ->
    Floor = floor(F),
    case order(I, Floor) of
        eq when Floor == F -> eq;
        eq -> lt;
        Order -> Order
    end.

order(A, B) when A < B -> lt;
order(A, B) when A > B -> gt;
order(_, _) -> eq.

-spec equals_number(integer(), term()) -> boolean().
equals_number(I, N) -> compare_number(I, N) =:= eq.
