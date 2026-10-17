%% The Math family: the Math namespace object.
-module(bouy_ref_math).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4]).

-import(bouy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Math', record(object, ?OBJECT_PROTO, ?METHODS(<<"Math">>, math_functions()) ++ [{C, bouy_math:'$member'(C)} || C <- [<<"PI">>, <<"E">>, <<"LN2">>, <<"LN10">>, <<"LOG2E">>, <<"LOG10E">>, <<"SQRT2">>, <<"SQRT1_2">>]] ++ [{?SYM(toStringTag), <<"Math">>}], none)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Math">>, {'$o', 'Math'}}].

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Math">>, Name, _This, Args) -> math(Name, [bouy_ref:to_number(A) || A <- Args]).

math_functions() ->
    [<<"abs">>, <<"acos">>, <<"acosh">>, <<"asin">>, <<"asinh">>, <<"atan">>, <<"atan2">>, <<"atanh">>, <<"cbrt">>, <<"ceil">>,
     <<"clz32">>, <<"cos">>, <<"cosh">>, <<"exp">>, <<"expm1">>, <<"floor">>, <<"fround">>, <<"hypot">>, <<"imul">>, <<"log">>,
     <<"log10">>, <<"log1p">>, <<"log2">>, <<"max">>, <<"min">>, <<"pow">>, <<"random">>, <<"round">>, <<"sign">>, <<"sin">>,
     <<"sinh">>, <<"sqrt">>, <<"tan">>, <<"tanh">>, <<"trunc">>].

math(Name, Args) -> bouy_ref_number:canonical(bouy_math:(binary_to_existing_atom(Name))(Args)).
