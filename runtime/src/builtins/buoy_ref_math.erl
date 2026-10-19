%% The Math family: the Math namespace object. The functions convert their
%% arguments with ToNumber, all of them before any result, and the value
%% core's buoy_math computes them with the fdlibm algorithms that V8 uses.
-module(buoy_ref_math).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, f16round/1]).

-import(buoy_ref_realm, [arg/2, record/4]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Constants = [{C, buoy_math:'$member'(C), 0} || C <- [<<"PI">>, <<"E">>, <<"LN2">>, <<"LN10">>, <<"LOG2E">>, <<"LOG10E">>, <<"SQRT2">>, <<"SQRT1_2">>]],
    [{'Math', record(object, ?OBJECT_PROTO, ?METHODS(<<"Math">>, math_functions()) ++ Constants ++ [{?SYM(toStringTag), <<"Math">>, 4}], none)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Math">>, {'$o', 'Math'}}].

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Math">>, <<"sumPrecise">>, _This, Args) -> sum_precise(arg(1, Args));
method(<<"Math">>, <<"f16round">>, _This, Args) -> f16round(buoy_ref:to_number(arg(1, Args)));
method(<<"Math">>, Name, _This, Args) -> math(Name, [buoy_ref:to_number(A) || A <- Args]).

math_functions() ->
    [{<<"abs">>, 1}, {<<"acos">>, 1}, {<<"acosh">>, 1}, {<<"asin">>, 1}, {<<"asinh">>, 1}, {<<"atan">>, 1}, {<<"atan2">>, 2},
     {<<"atanh">>, 1}, {<<"cbrt">>, 1}, {<<"ceil">>, 1}, {<<"clz32">>, 1}, {<<"cos">>, 1}, {<<"cosh">>, 1}, {<<"exp">>, 1},
     {<<"expm1">>, 1}, {<<"f16round">>, 1}, {<<"floor">>, 1}, {<<"fround">>, 1}, {<<"hypot">>, 2}, {<<"imul">>, 2},
     {<<"log">>, 1}, {<<"log10">>, 1}, {<<"log1p">>, 1}, {<<"log2">>, 1}, {<<"max">>, 2}, {<<"min">>, 2}, {<<"pow">>, 2},
     {<<"random">>, 0}, {<<"round">>, 1}, {<<"sign">>, 1}, {<<"sin">>, 1}, {<<"sinh">>, 1}, {<<"sqrt">>, 1},
     {<<"sumPrecise">>, 1}, {<<"tan">>, 1}, {<<"tanh">>, 1}, {<<"trunc">>, 1}].

%% Math.pow converts both arguments, in order, before Number::exponentiate.
math(<<"pow">>, Args) ->
    Base = buoy_ref:to_number(arg(1, Args)),
    Exponent = buoy_ref:to_number(arg(2, Args)),
    buoy_ref_number:power(Base, Exponent);
math(Name, Args) -> buoy_ref_number:canonical(buoy_math:(binary_to_existing_atom(Name))(Args)).

%%% Math.f16round

%% The nearest IEEE 754 binary16 value, ties to even, as a double.
-spec f16round(term()) -> term().
f16round(N) when is_atom(N) -> N;
f16round(N) when N == 0 -> buoy_ref_number:canonical(float(N));
f16round(N) ->
    Sign = case N < 0 of
        true -> -1;
        false -> 1
    end,
    %% N = M * 2^E. A binary16 value is K * 2^Q with K < 2^11, and Q >= -24
    %% for the subnormals; 65504 is the largest.
    {M, E} = buoy_ref_number:decompose(N),
    Q = max(E + bit_length(M) - 11, -24),
    case Q > 5 of
        true -> infinite(Sign);
        false ->
            Magnitude = round_half_even(M, E - Q) * pow2(Q),
            case Magnitude > 65504.0 of
                true -> infinite(Sign);
                false -> buoy_ref_number:canonical(Sign * Magnitude)
            end
    end.

infinite(1) -> 'Infinity';
infinite(-1) -> '-Infinity'.

pow2(Q) when Q >= 0 -> float(1 bsl Q);
pow2(Q) -> 1.0 / float(1 bsl -Q).

%% M * 2^Shift rounded to an integer, ties to even.
round_half_even(M, Shift) when Shift >= 0 -> M bsl Shift;
round_half_even(M, Shift) ->
    Down = M bsr -Shift,
    Rest = M - (Down bsl -Shift),
    Half = 1 bsl (-Shift - 1),
    if
        Rest > Half -> Down + 1;
        Rest < Half -> Down;
        Down band 1 =:= 1 -> Down + 1;
        true -> Down
    end.

bit_length(0) -> 0;
bit_length(M) -> bit_length(M bsr 1) + 1.

%%% Math.sumPrecise

%% The exactly rounded sum of the numbers of an iterable.
sum_precise(Items) ->
    (Items =:= undefined orelse Items =:= null) andalso buoy_ref:type_error(<<"Math.sumPrecise requires an iterable">>),
    State = buoy_ref_iterator:iterate(Items),
    sum_steps(State, {0, minus_zero}).

sum_steps(State, Acc) ->
    case buoy_ref_iterator:step(State) of
        done -> sum_result(Acc);
        {value, V, State1} ->
            ?IS_NUMBER(V) orelse close_and_fail(State1, V),
            sum_steps(State1, add_item(V, Acc))
    end.

-spec close_and_fail(term(), term()) -> no_return().
close_and_fail(State, V) ->
    case State of
        {protocol, Iterator, _} ->
            case buoy_ref:get(Iterator, <<"return">>) of
                R when R =:= undefined; R =:= null -> ok;
                Return -> buoy_ref:call(Return, Iterator, [])
            end;
        _ -> ok
    end,
    buoy_ref:type_error(buoy_ref_string:concat(buoy_ref:describe(V), <<" is not a number">>)).

%% The sum so far: {Integer in units of 2^-1074, Zero}, or a special value.
add_item(_, 'NaN') -> 'NaN';
add_item('NaN', _) -> 'NaN';
add_item('Infinity', '-Infinity') -> 'NaN';
add_item('-Infinity', 'Infinity') -> 'NaN';
add_item(Inf, {_, _}) when is_atom(Inf) -> Inf;
add_item(Inf, Inf) -> Inf;
add_item(_, Inf) when is_atom(Inf) -> Inf;
add_item(V, {Sum, Zero}) when V == 0 ->
    case V =:= -0.0 of
        true -> {Sum, Zero};
        false -> {Sum, plus_zero}
    end;
add_item(V, {Sum, _}) ->
    {M, E} = buoy_ref_number:decompose(V),
    Units = M bsl (E + 1074),
    case V < 0 of
        true -> {Sum - Units, plus_zero};
        false -> {Sum + Units, plus_zero}
    end.

sum_result(Special) when is_atom(Special) -> Special;
sum_result({0, minus_zero}) -> -0.0;
sum_result({0, _}) -> 0;
sum_result({Sum, _}) when abs(Sum) < 1 bsl 53 -> buoy_ref_number:canonical(Sum * 5.0e-324);
sum_result({Sum, _}) ->
    %% Sum is in units of 2^-1074: round it to 53 bits, then scale.
    Magnitude = abs(Sum),
    Shift = bit_length(Magnitude) - 53,
    Rounded = round_half_even(Magnitude, -Shift),
    Exponent = Shift - 1074,
    Value = try float(Rounded) * math:pow(2, Exponent div 2) * math:pow(2, Exponent - Exponent div 2) of
        V -> V
    catch
        error:badarith -> infinity
    end,
    case {Value, Sum > 0} of
        {infinity, true} -> 'Infinity';
        {infinity, false} -> '-Infinity';
        {_, true} -> buoy_ref_number:canonical(Value);
        {_, false} -> buoy_ref_number:canonical(-Value)
    end.
