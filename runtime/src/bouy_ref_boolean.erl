%% The Boolean family: the Boolean function, Boolean objects, and
%% Boolean.prototype, which is itself a Boolean object holding false.
-module(bouy_ref_boolean).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, wrap/2]).

-import(bouy_ref_realm, [arg/2, record/4, ctor_record/5]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Boolean.prototype', record(boolean, ?OBJECT_PROTO, ?METHODS(<<"Boolean.prototype">>, [{<<"toString">>, 0}, {<<"valueOf">>, 0}]) ++ [{<<"constructor">>, constructor()}], false)},
     {{builtin, <<"Boolean">>}, ctor_record(<<"Boolean">>, 1, {'$o', 'Boolean.prototype'}, [], fun construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Boolean">>, constructor()}].

constructor() -> bouy_ref_realm:constructor(?MODULE, <<"Boolean">>).

-spec call_constructor(binary(), term(), list()) -> boolean().
call_constructor(<<"Boolean">>, _This, Args) -> bouy_ref:truthy(arg(1, Args)).

construct(NewTarget, Args) ->
    wrap(bouy_ref:truthy(arg(1, Args)), bouy_ref_realm:proto_for(NewTarget, 'Boolean.prototype')).

%% A Boolean object: the class boolean, its [[BooleanData]] in the slots.
-spec wrap(boolean(), term()) -> term().
wrap(B, Proto) -> bouy_heap:new_exotic(boolean, Proto, B).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Boolean.prototype">>, <<"toString">>, This, _) -> atom_to_binary(this_boolean(This, <<"toString">>));
method(<<"Boolean.prototype">>, <<"valueOf">>, This, _) -> this_boolean(This, <<"valueOf">>).

%% thisBooleanValue: a boolean, or the [[BooleanData]] of a Boolean object.
this_boolean(B, _Name) when is_boolean(B) -> B;
this_boolean({'$o', _} = O, Name) ->
    case bouy_heap:class_of(O) of
        boolean -> bouy_heap:slots(O);
        _ -> not_a_boolean(Name)
    end;
this_boolean(_, Name) -> not_a_boolean(Name).

-spec not_a_boolean(binary()) -> no_return().
not_a_boolean(Name) -> bouy_ref:type_error(<<"Boolean.prototype.", Name/binary, " requires that 'this' be a Boolean">>).
