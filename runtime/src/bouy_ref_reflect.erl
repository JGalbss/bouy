%% The Reflect family: one function for each internal method of an object
%% (ECMA-262 §28.1).
-module(bouy_ref_reflect).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, list_from_array_like/1]).

-import(bouy_ref_realm, [arg/2, record/4]).

%% The longest list an array-like may give, so a huge length fails instead
%% of exhausting memory.
-define(MAX_LIST, 1048576).
-import(bouy_ref, [type_error/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Methods = ?METHODS(<<"Reflect">>, [{<<"apply">>, 3}, {<<"construct">>, 2}, {<<"defineProperty">>, 3}, {<<"deleteProperty">>, 2},
                                      {<<"get">>, 2}, {<<"getOwnPropertyDescriptor">>, 2}, {<<"getPrototypeOf">>, 1}, {<<"has">>, 2},
                                      {<<"isExtensible">>, 1}, {<<"ownKeys">>, 1}, {<<"preventExtensions">>, 1}, {<<"set">>, 3},
                                      {<<"setPrototypeOf">>, 2}]),
    {Class, Proto, Props, Keys, Attrs, Slots} = record(object, ?OBJECT_PROTO, Methods ++ [{?SYM(toStringTag), <<"Reflect">>}], none),
    [{'Reflect', {Class, Proto, Props, Keys, Attrs#{?SYM(toStringTag) => 4}, Slots}}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Reflect">>, {'$o', 'Reflect'}}].

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Reflect">>, <<"apply">>, _This, Args) ->
    F = arg(1, Args),
    bouy_heap:is_callable(F) orelse type_error(bouy_ref_string:concat(bouy_ref:describe(F), <<" is not a function">>)),
    bouy_ref:call(F, arg(2, Args), list_from_array_like(arg(3, Args)));
method(<<"Reflect">>, <<"construct">>, _This, Args) ->
    Target = arg(1, Args),
    bouy_heap:is_constructor(Target) orelse type_error(bouy_ref_string:concat(bouy_ref:describe(Target), <<" is not a constructor">>)),
    NewTarget = case Args of
        [_, _, NT | _] -> NT;
        _ -> Target
    end,
    bouy_heap:is_constructor(NewTarget) orelse type_error(bouy_ref_string:concat(bouy_ref:describe(NewTarget), <<" is not a constructor">>)),
    bouy_heap:construct(Target, list_from_array_like(arg(2, Args)), NewTarget);
method(<<"Reflect">>, Name, _This, Args) ->
    Target = arg(1, Args),
    ?IS_OBJECT(Target) orelse type_error(<<"Reflect.", Name/binary, " called on non-object">>),
    reflect(Name, Target, Args).

reflect(<<"defineProperty">>, Target, Args) ->
    K = bouy_ref:to_property_key(arg(2, Args)),
    bouy_heap:define_own_property(Target, K, bouy_ref_object:to_descriptor(arg(3, Args)));
reflect(<<"deleteProperty">>, Target, Args) ->
    bouy_heap:delete_property(Target, bouy_ref:to_property_key(arg(2, Args)));
reflect(<<"get">>, Target, Args) ->
    K = bouy_ref:to_property_key(arg(2, Args)),
    Receiver = case Args of
        [_, _, R | _] -> R;
        _ -> Target
    end,
    bouy_heap:get(Target, K, Receiver);
reflect(<<"getOwnPropertyDescriptor">>, Target, Args) ->
    bouy_ref_object:from_property(bouy_heap:get_own(Target, bouy_ref:to_property_key(arg(2, Args))));
reflect(<<"getPrototypeOf">>, Target, _Args) ->
    bouy_heap:prototype_of(Target);
reflect(<<"has">>, Target, Args) ->
    bouy_heap:has(Target, bouy_ref:to_property_key(arg(2, Args)));
reflect(<<"isExtensible">>, Target, _Args) ->
    bouy_heap:is_extensible(Target);
reflect(<<"ownKeys">>, Target, _Args) ->
    bouy_heap:new_array([bouy_heap:key_to_value(K) || K <- bouy_heap:own_keys(Target)]);
reflect(<<"preventExtensions">>, Target, _Args) ->
    bouy_heap:prevent_extensions(Target);
reflect(<<"set">>, Target, Args) ->
    K = bouy_ref:to_property_key(arg(2, Args)),
    Receiver = case Args of
        [_, _, _, R | _] -> R;
        _ -> Target
    end,
    bouy_heap:set(Target, K, arg(3, Args), Receiver);
reflect(<<"setPrototypeOf">>, Target, Args) ->
    Proto = arg(2, Args),
    ?IS_OBJECT(Proto) orelse Proto =:= null orelse type_error(<<"Object prototype may only be an Object or null">>),
    bouy_heap:set_prototype(Target, Proto).

%% CreateListFromArrayLike: the elements 0 to length - 1 of an object.
-spec list_from_array_like(term()) -> list().
list_from_array_like(O) when ?IS_OBJECT(O) ->
    Length = case bouy_ref_number:to_integer_or_infinity(bouy_ref:to_number(bouy_ref:get(O, <<"length">>))) of
        L when is_integer(L), L > ?MAX_LIST -> bouy_heap:throw_error('RangeError', <<"Too many arguments in function call">>);
        L when is_integer(L), L > 0 -> L;
        'Infinity' -> bouy_heap:throw_error('RangeError', <<"Too many arguments in function call">>);
        _ -> 0
    end,
    [bouy_ref:get(O, I) || I <- lists:seq(0, Length - 1)];
list_from_array_like(_V) ->
    type_error(<<"CreateListFromArrayLike called on non-object">>).
