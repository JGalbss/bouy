%% The Reflect family: one function for each internal method of an object
%% (ECMA-262 §28.1).
-module(buoy_ref_reflect).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, list_from_array_like/1]).

-import(buoy_ref_realm, [arg/2, record/4]).

%% The longest list an array-like may give, so a huge length fails instead
%% of exhausting memory.
-define(MAX_LIST, 1048576).
-import(buoy_ref, [type_error/1]).

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
    buoy_heap:is_callable(F) orelse type_error(buoy_ref_string:concat(buoy_ref:describe(F), <<" is not a function">>)),
    buoy_ref:call(F, arg(2, Args), list_from_array_like(arg(3, Args)));
method(<<"Reflect">>, <<"construct">>, _This, Args) ->
    Target = arg(1, Args),
    buoy_heap:is_constructor(Target) orelse type_error(buoy_ref_string:concat(buoy_ref:describe(Target), <<" is not a constructor">>)),
    NewTarget = case Args of
        [_, _, NT | _] -> NT;
        _ -> Target
    end,
    buoy_heap:is_constructor(NewTarget) orelse type_error(buoy_ref_string:concat(buoy_ref:describe(NewTarget), <<" is not a constructor">>)),
    buoy_heap:construct(Target, list_from_array_like(arg(2, Args)), NewTarget);
method(<<"Reflect">>, Name, _This, Args) ->
    Target = arg(1, Args),
    ?IS_OBJECT(Target) orelse type_error(<<"Reflect.", Name/binary, " called on non-object">>),
    reflect(Name, Target, Args).

reflect(<<"defineProperty">>, Target, Args) ->
    K = buoy_ref:to_property_key(arg(2, Args)),
    buoy_heap:define_own_property(Target, K, buoy_ref_object:to_descriptor(arg(3, Args)));
reflect(<<"deleteProperty">>, Target, Args) ->
    buoy_heap:delete_property(Target, buoy_ref:to_property_key(arg(2, Args)));
reflect(<<"get">>, Target, Args) ->
    K = buoy_ref:to_property_key(arg(2, Args)),
    Receiver = case Args of
        [_, _, R | _] -> R;
        _ -> Target
    end,
    buoy_heap:get(Target, K, Receiver);
reflect(<<"getOwnPropertyDescriptor">>, Target, Args) ->
    buoy_ref_object:from_property(buoy_heap:get_own(Target, buoy_ref:to_property_key(arg(2, Args))));
reflect(<<"getPrototypeOf">>, Target, _Args) ->
    buoy_heap:prototype_of(Target);
reflect(<<"has">>, Target, Args) ->
    buoy_heap:has(Target, buoy_ref:to_property_key(arg(2, Args)));
reflect(<<"isExtensible">>, Target, _Args) ->
    buoy_heap:is_extensible(Target);
reflect(<<"ownKeys">>, Target, _Args) ->
    buoy_heap:new_array([buoy_heap:key_to_value(K) || K <- buoy_heap:own_keys(Target)]);
reflect(<<"preventExtensions">>, Target, _Args) ->
    buoy_heap:prevent_extensions(Target);
reflect(<<"set">>, Target, Args) ->
    K = buoy_ref:to_property_key(arg(2, Args)),
    Receiver = case Args of
        [_, _, _, R | _] -> R;
        _ -> Target
    end,
    buoy_heap:set(Target, K, arg(3, Args), Receiver);
reflect(<<"setPrototypeOf">>, Target, Args) ->
    Proto = arg(2, Args),
    ?IS_OBJECT(Proto) orelse Proto =:= null orelse type_error(<<"Object prototype may only be an Object or null">>),
    buoy_heap:set_prototype(Target, Proto).

%% CreateListFromArrayLike: the elements 0 to length - 1 of an object.
-spec list_from_array_like(term()) -> list().
list_from_array_like(O) when ?IS_OBJECT(O) ->
    Length = case buoy_ref_number:to_integer_or_infinity(buoy_ref:to_number(buoy_ref:get(O, <<"length">>))) of
        L when is_integer(L), L > ?MAX_LIST -> buoy_heap:throw_error('RangeError', <<"Too many arguments in function call">>);
        L when is_integer(L), L > 0 -> L;
        'Infinity' -> buoy_heap:throw_error('RangeError', <<"Too many arguments in function call">>);
        _ -> 0
    end,
    [buoy_ref:get(O, I) || I <- lists:seq(0, Length - 1)];
list_from_array_like(_V) ->
    type_error(<<"CreateListFromArrayLike called on non-object">>).
