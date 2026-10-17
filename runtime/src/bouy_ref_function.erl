%% The Function family: the Function constructor and Function.prototype
%% (call, apply, bind, toString).
-module(bouy_ref_function).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).

-import(bouy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Function.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"Function.prototype">>, [<<"call">>, <<"apply">>, <<"bind">>, <<"toString">>]) ++ [{<<"name">>, <<>>}, {<<"length">>, 0}, {<<"constructor">>, constructor()}], none)},
     {{builtin, <<"Function">>}, ctor_record(<<"Function">>, 1, ?FUNCTION_PROTO, [], fun bouy_ref_realm:not_constructible/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Function">>, constructor()}].

constructor() -> bouy_ref_realm:constructor(?MODULE, <<"Function">>).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(Name, _This, _Args) -> type_error(<<"Constructor ", Name/binary, " requires 'new'">>).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Function.prototype">>, Name, This, Args) -> function_proto(Name, This, Args).

function_proto(<<"call">>, F, Args) -> bouy_ref:call(F, arg(1, Args), rest(2, Args));
function_proto(<<"apply">>, F, Args) ->
    List = case arg(2, Args) of
        A when A =:= undefined; A =:= null -> [];
        A -> bouy_ref_iterator:to_list(A)
    end,
    bouy_ref:call(F, arg(1, Args), List);
function_proto(<<"bind">>, F, Args) ->
    BoundThis = arg(1, Args),
    Bound = rest(2, Args),
    Name = case bouy_ref:get(F, <<"name">>) of
        N when is_binary(N) -> N;
        _ -> <<>>
    end,
    bouy_heap:function(fun(_This, More) -> bouy_ref:call(F, BoundThis, Bound ++ More) end, <<"bound ", Name/binary>>, 0, #{}) ;
function_proto(<<"toString">>, F, _Args) ->
    case bouy_heap:slots(F) of
        #{kind := class} -> <<"class ", (bouy_ref:get(F, <<"name">>))/binary, " { }">>;
        _ -> <<"function ", (bouy_ref:get(F, <<"name">>))/binary, "() { [native code] }">>
    end.
