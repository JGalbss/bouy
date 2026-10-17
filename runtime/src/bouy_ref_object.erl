%% The Object family: the Object constructor, its static functions, and
%% Object.prototype.
-module(bouy_ref_object).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, constructor/0, same_value/2]).

-import(bouy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Object.prototype', record(object, null, ?METHODS(<<"Object.prototype">>, [<<"hasOwnProperty">>, <<"isPrototypeOf">>, <<"propertyIsEnumerable">>, <<"toString">>, <<"toLocaleString">>, <<"valueOf">>]) ++ [{<<"constructor">>, constructor()}], none)},
     {{builtin, <<"Object">>}, ctor_record(<<"Object">>, 1, ?OBJECT_PROTO, ?METHODS(<<"Object">>, object_statics()), fun(_NT, Args) -> object_call(undefined, Args) end)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Object">>, constructor()}].

-spec constructor() -> term().
constructor() -> bouy_ref_realm:constructor(?MODULE, <<"Object">>).

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"Object">>, This, Args) -> object_call(This, Args).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Object.prototype">>, Name, This, Args) -> object_proto(Name, This, Args);
method(<<"Object">>, Name, _This, Args) -> object_static(Name, Args).

object_call(_This, Args) ->
    case arg(1, Args) of
        V when ?IS_OBJECT(V) -> V;
        _ -> bouy_heap:new_object(?OBJECT_PROTO)
    end.

object_proto(<<"hasOwnProperty">>, This, Args) -> has_own(This, bouy_ref:to_property_key(arg(1, Args)));
object_proto(<<"isPrototypeOf">>, This, Args) ->
    case arg(1, Args) of
        V when ?IS_OBJECT(V) -> chain_has(bouy_heap:prototype_of(V), This);
        _ -> false
    end;
object_proto(<<"propertyIsEnumerable">>, This, Args) ->
    case bouy_heap:get_own(This, bouy_ref:to_property_key(arg(1, Args))) of
        {data, _, Bits} -> Bits band 2 =/= 0;
        {accessor, _, _, Bits} -> Bits band 2 =/= 0;
        none -> false
    end;
object_proto(<<"toString">>, This, _Args) -> <<"[object ", (tag(This))/binary, "]">>;
object_proto(<<"toLocaleString">>, This, _Args) -> bouy_ref:call_method(This, <<"toString">>, []);
object_proto(<<"valueOf">>, This, _Args) -> This.

has_own(O, K) when ?IS_OBJECT(O) -> bouy_heap:has_own(O, K);
has_own(S, K) when is_binary(S) -> K =:= <<"length">> orelse (is_integer(K) andalso K < bouy_string:char_count(S));
has_own(_, _) -> false.

chain_has(null, _) -> false;
chain_has(P, P) -> true;
chain_has(O, P) -> chain_has(bouy_heap:prototype_of(O), P).

tag(undefined) -> <<"Undefined">>;
tag(null) -> <<"Null">>;
tag(V) when ?IS_OBJECT(V) ->
    case bouy_ref:get(V, ?SYM(toStringTag)) of
        T when is_binary(T) -> T;
        _ ->
            case bouy_heap:class_of(V) of
                array -> <<"Array">>;
                function -> <<"Function">>;
                error -> <<"Error">>;
                date -> <<"Date">>;
                _ -> <<"Object">>
            end
    end;
tag(V) when is_binary(V) -> <<"String">>;
tag(V) when is_boolean(V) -> <<"Boolean">>;
tag({'$sym', _, _}) -> <<"Symbol">>;
tag(_) -> <<"Number">>.

object_statics() ->
    [<<"keys">>, <<"values">>, <<"entries">>, <<"assign">>, <<"freeze">>, <<"isFrozen">>, <<"create">>, <<"getPrototypeOf">>,
     <<"setPrototypeOf">>, <<"defineProperty">>, <<"getOwnPropertyNames">>, <<"getOwnPropertySymbols">>,
     <<"getOwnPropertyDescriptor">>, <<"fromEntries">>, <<"hasOwn">>, <<"is">>].

object_static(<<"keys">>, Args) -> bouy_heap:new_array([bouy_heap:key_to_value(K) || K <- enumerable(arg(1, Args))]);
object_static(<<"values">>, Args) ->
    O = arg(1, Args),
    bouy_heap:new_array([bouy_ref:get(O, K) || K <- enumerable(O)]);
object_static(<<"entries">>, Args) ->
    O = arg(1, Args),
    bouy_heap:new_array([bouy_heap:new_array([bouy_heap:key_to_value(K), bouy_ref:get(O, K)]) || K <- enumerable(O)]);
object_static(<<"assign">>, [Target | Sources]) ->
    [bouy_ref:set(Target, K, bouy_ref:get(S, K)) || S <- Sources, ?IS_OBJECT(S), K <- enumerable(S) ++ enumerable_symbols(S)],
    Target;
object_static(<<"freeze">>, Args) ->
    case arg(1, Args) of
        O when ?IS_OBJECT(O) -> bouy_heap:freeze(O);
        V -> V
    end;
object_static(<<"isFrozen">>, Args) ->
    case arg(1, Args) of
        O when ?IS_OBJECT(O) -> bouy_heap:is_frozen(O);
        _ -> true
    end;
object_static(<<"create">>, Args) ->
    case arg(1, Args) of
        P when ?IS_OBJECT(P); P =:= null ->
            O = bouy_heap:new_object(P),
            case arg(2, Args) of
                undefined -> ok;
                Props -> object_static(<<"defineProperties">>, [O, Props])
            end,
            O;
        P ->
            type_error(<<"Object prototype may only be an Object or null: ", (bouy_ref:describe(P))/binary>>)
    end;
object_static(<<"defineProperties">>, [O, Props]) ->
    [object_static(<<"defineProperty">>, [O, bouy_heap:key_to_value(K), bouy_ref:get(Props, K)]) || K <- enumerable(Props)],
    O;
object_static(<<"getPrototypeOf">>, Args) ->
    case arg(1, Args) of
        O when ?IS_OBJECT(O) -> bouy_heap:prototype_of(O);
        S when is_binary(S) -> {'$o', 'String.prototype'};
        B when is_boolean(B) -> {'$o', 'Boolean.prototype'};
        {'$sym', _, _} -> {'$o', 'Symbol.prototype'};
        undefined -> type_error(<<"Cannot convert undefined or null to object">>);
        null -> type_error(<<"Cannot convert undefined or null to object">>);
        _ -> {'$o', 'Number.prototype'}
    end;
object_static(<<"setPrototypeOf">>, Args) ->
    case arg(1, Args) of
        O when ?IS_OBJECT(O) -> bouy_heap:set_prototype_of(O, arg(2, Args));
        V -> V
    end;
object_static(<<"defineProperty">>, Args) ->
    O = arg(1, Args),
    ?IS_OBJECT(O) orelse type_error(<<"Object.defineProperty called on non-object">>),
    D = arg(3, Args),
    Descriptor = maps:from_list([{binary_to_atom(F), bouy_ref:get(D, F)}
                                 || F <- [<<"value">>, <<"writable">>, <<"enumerable">>, <<"configurable">>, <<"get">>, <<"set">>],
                                    bouy_heap:has(D, F)]),
    Flags = maps:map(fun(K, V) when K =:= writable; K =:= enumerable; K =:= configurable -> bouy_ref:truthy(V); (_, V) -> V end, Descriptor),
    bouy_heap:define(O, bouy_ref:to_property_key(arg(2, Args)), Flags);
object_static(<<"getOwnPropertyNames">>, Args) ->
    bouy_heap:new_array([bouy_heap:key_to_value(K) || K <- bouy_heap:own_keys(arg(1, Args)), not is_tuple(K)]);
object_static(<<"getOwnPropertySymbols">>, Args) ->
    bouy_heap:new_array([K || {'$sym', _, _} = K <- bouy_heap:own_keys(arg(1, Args))]);
object_static(<<"getOwnPropertyDescriptor">>, Args) ->
    case bouy_heap:get_own(arg(1, Args), bouy_ref:to_property_key(arg(2, Args))) of
        none -> undefined;
        {data, V, Bits} ->
            bouy_heap:object(?OBJECT_PROTO, [{<<"value">>, V}, {<<"writable">>, Bits band 1 =/= 0},
                                             {<<"enumerable">>, Bits band 2 =/= 0}, {<<"configurable">>, Bits band 4 =/= 0}]);
        {accessor, G, S, Bits} ->
            bouy_heap:object(?OBJECT_PROTO, [{<<"get">>, G}, {<<"set">>, S},
                                             {<<"enumerable">>, Bits band 2 =/= 0}, {<<"configurable">>, Bits band 4 =/= 0}])
    end;
object_static(<<"fromEntries">>, Args) ->
    O = bouy_heap:new_object(?OBJECT_PROTO),
    [bouy_ref:define_field(O, bouy_ref:to_property_key(bouy_ref:get(E, 0)), bouy_ref:get(E, 1)) || E <- bouy_ref_iterator:to_list(arg(1, Args))],
    O;
object_static(<<"hasOwn">>, Args) -> has_own(arg(1, Args), bouy_ref:to_property_key(arg(2, Args)));
object_static(<<"is">>, Args) -> same_value(arg(1, Args), arg(2, Args)).

same_value(A, B) when is_float(A), is_float(B) -> <<A/float>> =:= <<B/float>>;
same_value(A, B) -> bouy_ref:strict_eq(A, B) orelse (A =:= 'NaN' andalso B =:= 'NaN').

enumerable(O) when ?IS_OBJECT(O) -> bouy_heap:enumerable_keys(O);
enumerable(S) when is_binary(S) -> lists:seq(0, bouy_string:char_count(S) - 1);
enumerable(undefined) -> type_error(<<"Cannot convert undefined or null to object">>);
enumerable(null) -> type_error(<<"Cannot convert undefined or null to object">>);
enumerable(_) -> [].

enumerable_symbols(O) ->
    [K || {'$sym', _, _} = K <- bouy_heap:own_keys(O),
          case bouy_heap:get_own(O, K) of
              {data, _, B} -> B band 2 =/= 0;
              {accessor, _, _, B} -> B band 2 =/= 0;
              none -> false
          end].
