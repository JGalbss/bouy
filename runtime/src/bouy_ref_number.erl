%% The Number family: the Number function and its statics, Number.prototype,
%% and the global number functions (parseInt, parseFloat, isNaN, isFinite).
-module(bouy_ref_number).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).

-import(bouy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

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
method(<<"Number.prototype">>, Name, This, Args) -> bouy_number:call(Name, This, Args);
method(<<"Number">>, Name, _This, Args) -> bouy_number:(binary_to_atom(Name))(Args);
method(<<"globalThis">>, <<"parseInt">>, _This, Args) -> bouy_number:'parseInt'(Args);
method(<<"globalThis">>, <<"parseFloat">>, _This, Args) -> bouy_number:'parseFloat'(Args);
method(<<"globalThis">>, <<"isNaN">>, _This, Args) -> bouy_number:'$isNaN'([bouy_ref:to_number(arg(1, Args))]);
method(<<"globalThis">>, <<"isFinite">>, _This, Args) -> bouy_number:'$isFinite'([bouy_ref:to_number(arg(1, Args))]).
