%% The Object family: the Object constructor, its static functions, and
%% Object.prototype. The statics go through the internal methods of
%% bouy_heap, so proxies see each step in the order of ECMA-262 §20.1.
-module(bouy_ref_object).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, constructor/0, same_value/2]).
-export([to_descriptor/1, from_descriptor/1, from_property/1, is_array/1, own_property_keys/1, require_object/1]).

-import(bouy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

-define(CONVERT_ERROR, <<"Cannot convert undefined or null to object">>).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Proto = ?METHODS(<<"Object.prototype">>, [{<<"hasOwnProperty">>, 1}, {<<"isPrototypeOf">>, 1}, {<<"propertyIsEnumerable">>, 1},
                                             {<<"toString">>, 0}, {<<"toLocaleString">>, 0}, {<<"valueOf">>, 0},
                                             {<<"__defineGetter__">>, 2}, {<<"__defineSetter__">>, 2},
                                             {<<"__lookupGetter__">>, 1}, {<<"__lookupSetter__">>, 1}])
        ++ [{<<"constructor">>, constructor()},
            {<<"__proto__">>, {'$accessor', accessor(<<"get __proto__">>, 0, <<"proto_get">>),
                               accessor(<<"set __proto__">>, 1, <<"proto_set">>)}}],
    [{'Object.prototype', record(object, null, Proto, none)},
     {{builtin, <<"Object">>}, ctor_record(<<"Object">>, 1, ?OBJECT_PROTO, ?METHODS(<<"Object">>, object_statics()), fun object_construct/2)}].

accessor(Name, Length, Method) ->
    bouy_ref_realm:builtin(<<"Object.prototype.", Method/binary>>, Name, Length,
                           fun(This, Args) -> ?MODULE:method(<<"Object.prototype">>, Method, This, Args) end).

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Object">>, constructor()}].

-spec constructor() -> term().
constructor() -> bouy_ref_realm:constructor(?MODULE, <<"Object">>).

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"Object">>, _This, Args) -> object_value(Args).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Object.prototype">>, Name, This, Args) -> object_proto(Name, This, Args);
method(<<"Object">>, Name, _This, Args) -> object_static(Name, Args).

%% new Object(v) from a subclass makes an object from NewTarget's prototype.
object_construct({'$f', {builtin, <<"Object">>}, _}, Args) -> object_value(Args);
object_construct(NewTarget, _Args) -> bouy_ref:new_this(NewTarget).

object_value(Args) ->
    case arg(1, Args) of
        V when V =:= undefined; V =:= null -> bouy_heap:new_object(?OBJECT_PROTO);
        V -> bouy_ref:to_object(V)
    end.

%%% Object.prototype

object_proto(<<"hasOwnProperty">>, This, Args) ->
    K = bouy_ref:to_property_key(arg(1, Args)),
    get_own(require_object(This), K) =/= none;
object_proto(<<"isPrototypeOf">>, This, Args) ->
    case arg(1, Args) of
        V when ?IS_OBJECT(V) -> chain_has(bouy_heap:prototype_of(V), require_object(This));
        _ -> false
    end;
object_proto(<<"propertyIsEnumerable">>, This, Args) ->
    K = bouy_ref:to_property_key(arg(1, Args)),
    enumerable(get_own(require_object(This), K));
object_proto(<<"toString">>, This, _Args) -> bouy_ref_string:concat([<<"[object ">>, tag(This), <<"]">>]);
object_proto(<<"toLocaleString">>, This, _Args) -> bouy_ref:call_method(This, <<"toString">>, []);
object_proto(<<"valueOf">>, This, _Args) -> to_object(This);
object_proto(<<"proto_get">>, This, _Args) -> prototype(require_object(This));
object_proto(<<"proto_set">>, This, Args) ->
    O = require_object(This),
    Proto = arg(1, Args),
    case ?IS_OBJECT(O) andalso (?IS_OBJECT(Proto) orelse Proto =:= null) of
        true -> bouy_heap:set_prototype(O, Proto) orelse type_error(<<"Object.prototype.__proto__ setter failed: the object is not extensible or the prototype chain would have a cycle">>);
        false -> ok
    end,
    undefined;
object_proto(<<"__defineGetter__">>, This, Args) -> define_legacy(This, Args, get);
object_proto(<<"__defineSetter__">>, This, Args) -> define_legacy(This, Args, set);
object_proto(<<"__lookupGetter__">>, This, Args) -> lookup_legacy(This, Args, get);
object_proto(<<"__lookupSetter__">>, This, Args) -> lookup_legacy(This, Args, set).

define_legacy(This, Args, Which) ->
    O = to_object(This),
    F = arg(2, Args),
    bouy_heap:is_callable(F) orelse type_error(<<"Object.prototype.__define", (case Which of get -> <<"Getter">>; set -> <<"Setter">> end)/binary, "__: Expecting function">>),
    K = bouy_ref:to_property_key(arg(1, Args)),
    bouy_heap:define(O, K, #{Which => F, enumerable => true, configurable => true}),
    undefined.

lookup_legacy(This, Args, Which) ->
    O = to_object(This),
    lookup(O, bouy_ref:to_property_key(arg(1, Args)), Which).

lookup(null, _K, _Which) ->
    undefined;
lookup(O, K, Which) ->
    case get_own(O, K) of
        {accessor, G, _, _} when Which =:= get -> G;
        {accessor, _, S, _} when Which =:= set -> S;
        {data, _, _} -> undefined;
        none -> lookup(prototype(O), K, Which)
    end.

chain_has(null, _) -> false;
chain_has(P, P) -> true;
chain_has(O, P) -> chain_has(bouy_heap:prototype_of(O), P).

%% The tag of Object.prototype.toString: the builtin tag, unless
%% Symbol.toStringTag gives a string.
tag(undefined) -> <<"Undefined">>;
tag(null) -> <<"Null">>;
tag(V) ->
    Builtin = builtin_tag(V),
    case bouy_ref:get(V, ?SYM(toStringTag)) of
        T when ?IS_STRING(T) -> T;
        _ -> Builtin
    end.

builtin_tag(V) when ?IS_OBJECT(V) ->
    case is_array(V) of
        true -> <<"Array">>;
        false ->
            case bouy_heap:class_of(V) of
                _ when element(1, V) =:= '$f' -> <<"Function">>;
                error -> <<"Error">>;
                date -> <<"Date">>;
                arguments -> <<"Arguments">>;
                number -> <<"Number">>;
                string -> <<"String">>;
                boolean -> <<"Boolean">>;
                regexp -> <<"RegExp">>;
                _ -> <<"Object">>
            end
    end;
builtin_tag(V) when ?IS_STRING(V) -> <<"String">>;
builtin_tag(V) when is_boolean(V) -> <<"Boolean">>;
builtin_tag(V) when ?IS_NUMBER(V) -> <<"Number">>;
builtin_tag(_) -> <<"Object">>.

%% IsArray: an array, or a proxy whose target is one.
-spec is_array(term()) -> boolean().
is_array(V) when ?IS_OBJECT(V) ->
    case bouy_heap:class_of(V) of
        array -> true;
        proxy -> bouy_heap:class_of(bouy_ref_proxy:target(V)) =:= array;
        _ -> false
    end;
is_array(_) ->
    false.

%%% Object

object_statics() ->
    [{<<"assign">>, 2}, {<<"create">>, 2}, {<<"defineProperties">>, 2}, {<<"defineProperty">>, 3}, {<<"entries">>, 1},
     {<<"freeze">>, 1}, {<<"fromEntries">>, 1}, {<<"getOwnPropertyDescriptor">>, 2}, {<<"getOwnPropertyDescriptors">>, 1},
     {<<"getOwnPropertyNames">>, 1}, {<<"getOwnPropertySymbols">>, 1}, {<<"getPrototypeOf">>, 1}, {<<"groupBy">>, 2},
     {<<"hasOwn">>, 2}, {<<"is">>, 2}, {<<"isExtensible">>, 1}, {<<"isFrozen">>, 1}, {<<"isSealed">>, 1}, {<<"keys">>, 1},
     {<<"preventExtensions">>, 1}, {<<"seal">>, 1}, {<<"setPrototypeOf">>, 2}, {<<"values">>, 1}].

object_static(<<"keys">>, Args) -> bouy_heap:new_array(enumerable_own(to_object(arg(1, Args)), key));
object_static(<<"values">>, Args) -> bouy_heap:new_array(enumerable_own(to_object(arg(1, Args)), value));
object_static(<<"entries">>, Args) -> bouy_heap:new_array(enumerable_own(to_object(arg(1, Args)), entry));
object_static(<<"assign">>, Args) ->
    Target = to_object(arg(1, Args)),
    lists:foreach(fun(Source) -> assign(Target, Source) end, rest(2, Args)),
    Target;
object_static(<<"freeze">>, Args) -> integrity(arg(1, Args), frozen);
object_static(<<"seal">>, Args) -> integrity(arg(1, Args), sealed);
object_static(<<"isFrozen">>, Args) -> test_integrity(arg(1, Args), frozen);
object_static(<<"isSealed">>, Args) -> test_integrity(arg(1, Args), sealed);
object_static(<<"isExtensible">>, Args) ->
    case arg(1, Args) of
        O when ?IS_OBJECT(O) -> bouy_heap:is_extensible(O);
        _ -> false
    end;
object_static(<<"preventExtensions">>, Args) ->
    case arg(1, Args) of
        O when ?IS_OBJECT(O) ->
            bouy_heap:prevent_extensions(O) orelse type_error(<<"Cannot prevent extensions">>),
            O;
        V ->
            V
    end;
object_static(<<"create">>, Args) ->
    case arg(1, Args) of
        P when ?IS_OBJECT(P); P =:= null ->
            O = bouy_heap:new_object(P),
            case arg(2, Args) of
                undefined -> O;
                Props -> define_properties(O, Props)
            end;
        P ->
            type_error(bouy_ref_string:concat(<<"Object prototype may only be an Object or null: ">>, bouy_ref:describe(P)))
    end;
object_static(<<"defineProperties">>, Args) ->
    O = arg(1, Args),
    ?IS_OBJECT(O) orelse type_error(<<"Object.defineProperties called on non-object">>),
    define_properties(O, arg(2, Args));
object_static(<<"defineProperty">>, Args) ->
    O = arg(1, Args),
    ?IS_OBJECT(O) orelse type_error(<<"Object.defineProperty called on non-object">>),
    K = bouy_ref:to_property_key(arg(2, Args)),
    bouy_heap:define(O, K, to_descriptor(arg(3, Args)));
object_static(<<"getPrototypeOf">>, Args) -> prototype(to_object(arg(1, Args)));
object_static(<<"setPrototypeOf">>, Args) ->
    O = require_object(arg(1, Args)),
    Proto = arg(2, Args),
    ?IS_OBJECT(Proto) orelse Proto =:= null
        orelse type_error(bouy_ref_string:concat(<<"Object prototype may only be an Object or null: ">>, bouy_ref:describe(Proto))),
    case ?IS_OBJECT(O) of
        true -> bouy_heap:set_prototype(O, Proto) orelse type_error(<<"Object.setPrototypeOf failed: the object is not extensible or the prototype chain would have a cycle">>);
        false -> ok
    end,
    O;
object_static(<<"getOwnPropertyNames">>, Args) ->
    bouy_heap:new_array([bouy_heap:key_to_value(K) || K <- own_property_keys(to_object(arg(1, Args))), not is_symbol(K)]);
object_static(<<"getOwnPropertySymbols">>, Args) ->
    bouy_heap:new_array([K || K <- own_property_keys(to_object(arg(1, Args))), is_symbol(K)]);
object_static(<<"getOwnPropertyDescriptor">>, Args) ->
    O = to_object(arg(1, Args)),
    from_property(get_own(O, bouy_ref:to_property_key(arg(2, Args))));
object_static(<<"getOwnPropertyDescriptors">>, Args) ->
    O = to_object(arg(1, Args)),
    Result = bouy_heap:new_object(?OBJECT_PROTO),
    lists:foreach(fun(K) ->
                          case get_own(O, K) of
                              none -> ok;
                              P -> bouy_ref:define_field(Result, K, from_property(P))
                          end
                  end, own_property_keys(O)),
    Result;
object_static(<<"fromEntries">>, Args) ->
    Iterable = require_object(arg(1, Args)),
    O = bouy_heap:new_object(?OBJECT_PROTO),
    each_entry(bouy_ref_iterator:iterate(Iterable), O),
    O;
object_static(<<"groupBy">>, Args) ->
    Items = require_object(arg(1, Args)),
    F = callable(arg(2, Args)),
    {Order, Groups} = group(bouy_ref_iterator:iterate(Items), F, 0, [], #{}),
    O = bouy_heap:new_object(null),
    [bouy_ref:define_field(O, K, bouy_heap:new_array(lists:reverse(maps:get(K, Groups)))) || K <- Order],
    O;
object_static(<<"hasOwn">>, Args) ->
    O = to_object(arg(1, Args)),
    get_own(O, bouy_ref:to_property_key(arg(2, Args))) =/= none;
object_static(<<"is">>, Args) -> same_value(arg(1, Args), arg(2, Args)).

%% SameValue: numbers and strings have one form each, so it is term equality.
-spec same_value(term(), term()) -> boolean().
same_value(A, B) -> A =:= B.

%% Object.assign from one source: Set for each enumerable own key, in order.
assign(_Target, Source) when Source =:= undefined; Source =:= null ->
    ok;
assign(Target, Source) ->
    From = to_object(Source),
    lists:foreach(fun(K) ->
                          case enumerable(get_own(From, K)) of
                              true -> bouy_ref:set(Target, K, bouy_ref:get(From, K));
                              false -> ok
                          end
                  end, own_property_keys(From)).

%% EnumerableOwnProperties: the keys, values, or entries, with each value
%% read right after its key passes.
enumerable_own(O, Kind) ->
    lists:filtermap(fun(K) ->
                            case not is_symbol(K) andalso enumerable(get_own(O, K)) of
                                false -> false;
                                true when Kind =:= key -> {true, bouy_heap:key_to_value(K)};
                                true when Kind =:= value -> {true, bouy_ref:get(O, K)};
                                true -> {true, bouy_heap:new_array([bouy_heap:key_to_value(K), bouy_ref:get(O, K)])}
                            end
                    end, own_property_keys(O)).

%% ObjectDefineProperties: every descriptor is read before the first define.
define_properties(O, Properties) ->
    Props = to_object(Properties),
    Descriptors = lists:filtermap(fun(K) ->
                                          case enumerable(get_own(Props, K)) of
                                              true -> {true, {K, to_descriptor(bouy_ref:get(Props, K))}};
                                              false -> false
                                          end
                                  end, own_property_keys(Props)),
    [bouy_heap:define(O, K, D) || {K, D} <- Descriptors],
    O.

%% SetIntegrityLevel. An ordinary object takes one flag for frozen.
integrity(O, Level) when ?IS_OBJECT(O) ->
    case {Level, bouy_heap:class_of(O)} of
        {frozen, Class} when Class =/= proxy, Class =/= arguments, Class =/= typed_array ->
            bouy_heap:freeze(O);
        _ ->
            bouy_heap:prevent_extensions(O) orelse type_error(<<"Cannot prevent extensions">>),
            lists:foreach(fun(K) -> fix(O, K, Level) end, bouy_heap:own_keys(O)),
            O
    end;
integrity(V, _Level) ->
    V.

fix(O, K, sealed) ->
    bouy_heap:define(O, K, #{configurable => false});
fix(O, K, frozen) ->
    case bouy_heap:get_own(O, K) of
        none -> ok;
        {accessor, _, _, _} -> bouy_heap:define(O, K, #{configurable => false});
        {data, _, _} -> bouy_heap:define(O, K, #{configurable => false, writable => false})
    end.

%% TestIntegrityLevel.
test_integrity(O, Level) when ?IS_OBJECT(O) ->
    not bouy_heap:is_extensible(O)
        andalso lists:all(fun(K) -> fixed(bouy_heap:get_own(O, K), Level) end, bouy_heap:own_keys(O));
test_integrity(_V, _Level) ->
    true.

fixed(none, _Level) -> true;
fixed({data, _, Bits}, frozen) -> Bits band 5 =:= 0;
fixed({data, _, Bits}, sealed) -> Bits band 4 =:= 0;
fixed({accessor, _, _, Bits}, _Level) -> Bits band 4 =:= 0.

each_entry(State, O) ->
    case bouy_ref_iterator:step(State) of
        done ->
            ok;
        {value, Entry, State1} ->
            closing(State1, fun() ->
                                    ?IS_OBJECT(Entry) orelse type_error(bouy_ref_string:concat(<<"Iterator value ">>, <<"is not an entry object">>)),
                                    K = bouy_ref:get(Entry, 0),
                                    V = bouy_ref:get(Entry, 1),
                                    bouy_ref:define_field(O, bouy_ref:to_property_key(K), V)
                            end),
            each_entry(State1, O)
    end.

group(State, F, I, Order, Groups) ->
    case bouy_ref_iterator:step(State) of
        done ->
            {lists:reverse(Order), Groups};
        {value, V, State1} ->
            K = closing(State1, fun() -> bouy_ref:to_property_key(bouy_ref:call(F, undefined, [V, I])) end),
            case Groups of
                #{K := Members} -> group(State1, F, I + 1, Order, Groups#{K := [V | Members]});
                _ -> group(State1, F, I + 1, [K | Order], Groups#{K => [V]})
            end
    end.

%% Runs Fun, and closes the iterator of State when Fun throws.
closing(State, Fun) ->
    try
        Fun()
    catch
        error:{'$throw', _} = Reason:Stack ->
            close(State),
            erlang:raise(error, Reason, Stack)
    end.

close({protocol, Iterator, _}) ->
    case bouy_ref:get(Iterator, <<"return">>) of
        {'$f', _, _} = Return ->
            %% The error that closes the iterator wins over one from return().
            try bouy_ref:call(Return, Iterator, []) of
                _ -> ok
            catch
                error:{'$throw', _} -> ok
            end;
        _ -> ok
    end;
close(_State) ->
    ok.

%%% Descriptors and objects

%% ToPropertyDescriptor: a descriptor map from a descriptor object.
-spec to_descriptor(term()) -> map().
to_descriptor(D) when ?IS_OBJECT(D) ->
    Fields = [{enumerable, <<"enumerable">>}, {configurable, <<"configurable">>}, {value, <<"value">>},
              {writable, <<"writable">>}, {get, <<"get">>}, {set, <<"set">>}],
    Desc = lists:foldl(fun({Name, Key}, Acc) ->
                               case bouy_heap:has(D, Key) of
                                   true -> Acc#{Name => field(Name, bouy_ref:get(D, Key))};
                                   false -> Acc
                               end
                       end, #{}, Fields),
    case bouy_heap:is_accessor_descriptor(Desc) andalso bouy_heap:is_data_descriptor(Desc) of
        true -> type_error(<<"Invalid property descriptor. Cannot both specify accessors and a value or writable attribute">>);
        false -> Desc
    end;
to_descriptor(D) ->
    type_error(bouy_ref_string:concat(<<"Property description must be an object: ">>, bouy_ref:to_string(describe_primitive(D)))).

describe_primitive({'$sym', _, _} = S) -> bouy_ref:describe(S);
describe_primitive(V) -> V.

field(Name, V) when Name =:= enumerable; Name =:= configurable; Name =:= writable -> bouy_ref:truthy(V);
field(get, V) -> accessor_field(<<"Getter">>, V);
field(set, V) -> accessor_field(<<"Setter">>, V);
field(value, V) -> V.

accessor_field(_What, undefined) -> undefined;
accessor_field(_What, {'$f', _, _} = F) -> F;
accessor_field(What, V) -> type_error(bouy_ref_string:concat([What, <<" must be a function: ">>, bouy_ref:to_string(describe_primitive(V))])).

%% FromPropertyDescriptor of a descriptor map.
-spec from_descriptor(map()) -> term().
from_descriptor(Desc) ->
    Fields = [{value, <<"value">>}, {writable, <<"writable">>}, {get, <<"get">>}, {set, <<"set">>},
              {enumerable, <<"enumerable">>}, {configurable, <<"configurable">>}],
    bouy_heap:object(?OBJECT_PROTO, [{Key, maps:get(Name, Desc)} || {Name, Key} <- Fields, is_map_key(Name, Desc)]).

%% FromPropertyDescriptor of a complete own property, or undefined.
-spec from_property(bouy_heap:property()) -> term().
from_property(none) ->
    undefined;
from_property({data, V, Bits}) ->
    bouy_heap:object(?OBJECT_PROTO, [{<<"value">>, V}, {<<"writable">>, Bits band 1 =/= 0},
                                     {<<"enumerable">>, Bits band 2 =/= 0}, {<<"configurable">>, Bits band 4 =/= 0}]);
from_property({accessor, G, S, Bits}) ->
    bouy_heap:object(?OBJECT_PROTO, [{<<"get">>, G}, {<<"set">>, S},
                                     {<<"enumerable">>, Bits band 2 =/= 0}, {<<"configurable">>, Bits band 4 =/= 0}]).

%% RequireObjectCoercible: a TypeError for undefined and null.
-spec require_object(term()) -> term().
require_object(V) when V =:= undefined; V =:= null -> type_error(?CONVERT_ERROR);
require_object(V) -> V.

%% ToObject: a primitive becomes its wrapper object.
to_object(V) -> bouy_ref:to_object(V).

is_symbol({'$sym', _, _}) -> true;
is_symbol(_) -> false.

enumerable({data, _, Bits}) -> Bits band 2 =/= 0;
enumerable({accessor, _, _, Bits}) -> Bits band 2 =/= 0;
enumerable(none) -> false.

%% [[OwnPropertyKeys]] of an object or of a primitive's wrapper.
-spec own_property_keys(term()) -> [bouy_heap:key()].
own_property_keys(O) when ?IS_OBJECT(O) -> bouy_heap:own_keys(O);
own_property_keys(S) when ?IS_STRING(S) -> lists:seq(0, bouy_ref_string:length_of(S) - 1) ++ [<<"length">>];
own_property_keys(_) -> [].

get_own(O, K) when ?IS_OBJECT(O) -> bouy_heap:get_own(O, K);
get_own(S, K) when ?IS_STRING(S) ->
    Length = bouy_ref_string:length_of(S),
    case K of
        <<"length">> -> {data, Length, 0};
        I when is_integer(I), I < Length -> {data, bouy_ref_string:unit_string(S, I), 2};
        _ -> none
    end;
get_own(_, _) -> none.

prototype(O) when ?IS_OBJECT(O) -> bouy_heap:prototype_of(O);
prototype(S) when ?IS_STRING(S) -> {'$o', 'String.prototype'};
prototype(B) when is_boolean(B) -> {'$o', 'Boolean.prototype'};
prototype({'$sym', _, _}) -> {'$o', 'Symbol.prototype'};
prototype(_) -> {'$o', 'Number.prototype'}.
