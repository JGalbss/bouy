%% The Boolean family: the Boolean function and Boolean.prototype.
-module(bouy_ref_boolean).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).

-import(bouy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Boolean.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"Boolean.prototype">>, [<<"toString">>, <<"valueOf">>]) ++ [{<<"constructor">>, constructor()}], none)},
     {{builtin, <<"Boolean">>}, ctor_record(<<"Boolean">>, 1, {'$o', 'Boolean.prototype'}, [], fun bouy_ref_realm:not_constructible/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Boolean">>, constructor()}].

constructor() -> bouy_ref_realm:constructor(?MODULE, <<"Boolean">>).

-spec call_constructor(binary(), term(), list()) -> boolean().
call_constructor(<<"Boolean">>, _This, Args) -> bouy_ref:truthy(arg(1, Args)).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Boolean.prototype">>, <<"toString">>, This, _) -> atom_to_binary(This);
method(<<"Boolean.prototype">>, <<"valueOf">>, This, _) -> This.
