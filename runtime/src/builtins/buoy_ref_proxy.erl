%% The Proxy family: the Proxy constructor, Proxy.revocable, and the internal
%% methods of a proxy object (ECMA-262 §10.5), with the invariant checks of
%% each trap.
%%
%% A proxy is a heap record of the class proxy whose slots are
%% {Target, Handler}, or {revoked, IsConstructor} after Proxy.revocable's
%% revoke ran. A host proxy has the handler {host, Module, State}: Module
%% intercepts get, set, has, deleteProperty, ownKeys, getOwnPropertyDescriptor,
%% and defineProperty as V8's named interceptors do, without the invariant
%% checks of a trap, and the other internal methods go to the target. A proxy of a callable target is a function value, so typeof
%% and calls see a function; the other proxies are object values. buoy_heap
%% sends each internal method of a proxy record here.
-module(buoy_ref_proxy).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).
-export([get/3, set/4, has/2, delete_property/2, own_keys/1, get_own_property/2, define_own_property/3]).
-export([get_prototype_of/1, set_prototype_of/2, is_extensible/1, prevent_extensions/1, call/3, construct/3]).
-export([target/1, is_host/1, has_binding/2]).

-import(buoy_ref_realm, [arg/2, builtin/2, record/4, ctor_record/5]).
-import(buoy_ref, [type_error/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Statics = ?METHODS(<<"Proxy">>, [{<<"revocable">>, 2}]),
    Entries = [{<<"length">>, 2}, {<<"name">>, <<"Proxy">>} | Statics],
    {Class, Proto, Props, Keys, Attrs, Slots} = record(function, ?FUNCTION_PROTO, Entries, #{construct => fun construct_proxy/2, kind => builtin}),
    [{{builtin, <<"Proxy">>}, {Class, Proto, Props, Keys, Attrs#{<<"length">> => 4, <<"name">> => 4}, Slots}}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Proxy">>, buoy_ref_realm:constructor(?MODULE, <<"Proxy">>)}].

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(<<"Proxy">>, _This, _Args) -> type_error(<<"Constructor Proxy requires 'new'">>).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Proxy">>, <<"revocable">>, _This, Args) ->
    P = create(arg(1, Args), arg(2, Args)),
    Revoke = buoy_heap:function(fun(_, _) -> revoke(P) end, <<>>, 0, #{}),
    buoy_heap:object(?OBJECT_PROTO, [{<<"proxy">>, P}, {<<"revoke">>, Revoke}]).

construct_proxy(_NewTarget, Args) -> create(arg(1, Args), arg(2, Args)).

%% ProxyCreate.
create(Target, Handler) ->
    ?IS_OBJECT(Target) andalso ?IS_OBJECT(Handler)
        orelse type_error(<<"Cannot create proxy with a non-object as target or handler">>),
    buoy_heap:proxy(Target, Handler).

revoke(Proxy) ->
    case buoy_heap:slots(Proxy) of
        {revoked, _} -> ok;
        {Target, _} -> buoy_heap:set_slots(Proxy, {revoked, buoy_heap:is_constructor(Target)})
    end,
    undefined.

%% The target of a proxy, through every level, for IsArray and the tag of
%% Object.prototype.toString. A revoked proxy throws.
-spec target(term()) -> term().
target(P) ->
    case buoy_heap:class_of(P) of
        proxy ->
            {Target, _} = live(buoy_heap:slots(P), <<"IsArray">>),
            target(Target);
        _ ->
            P
    end.

%% Whether P is a host proxy, which util.types.isProxy does not report.
-spec is_host(term()) -> boolean().
is_host(P) ->
    case buoy_heap:class_of(P) =:= proxy andalso buoy_heap:slots(P) of
        {_, {host, _, _}} -> true;
        _ -> false
    end.

%% HasBinding of an object environment whose object is P: a host proxy that
%% exports has_binding/3 answers it, and any other object's HasProperty does.
-spec has_binding(term(), buoy_heap:key()) -> boolean().
has_binding(P, K) ->
    case buoy_heap:class_of(P) =:= proxy andalso buoy_heap:slots(P) of
        {Target, {host, M, S}} ->
            case erlang:function_exported(M, has_binding, 3) of
                true -> M:has_binding(S, Target, K);
                false -> M:has(S, Target, K)
            end;
        _ ->
            buoy_heap:has(P, K)
    end.

%%% Traps

live({revoked, _}, Name) ->
    type_error(buoy_ref_string:concat([<<"Cannot perform '">>, Name, <<"' on a proxy that has been revoked">>]));
live(Slots, _Name) ->
    Slots.

%% The trap Name of the handler: {Target, Handler, undefined or a function}.
trap({revoked, _} = Slots, Name) ->
    live(Slots, Name);
trap({Target, {host, _, _} = Host}, _Name) ->
    {Target, Host, undefined};
trap({Target, Handler}, Name) ->
    Trap = case buoy_ref:get(Handler, Name) of
        T when T =:= undefined; T =:= null -> undefined;
        {'$f', _, _} = T -> buoy_ref_realm:callee(T);
        T -> type_error(buoy_ref_string:concat([buoy_ref:describe(T), <<" returned for property '">>, Name, <<"' of object '#<Object>' is not a function">>]))
    end,
    {Target, Handler, Trap}.

key_value(K) -> buoy_heap:key_to_value(K).

-spec invariant(binary(), binary()) -> no_return().
invariant(Trap, Message) ->
    type_error(buoy_ref_string:concat([<<"'">>, Trap, <<"' on proxy: ">>, Message])).

-spec get_prototype_of(term()) -> term().
get_prototype_of(Slots) ->
    case trap(Slots, <<"getPrototypeOf">>) of
        {Target, _, undefined} ->
            buoy_heap:prototype_of(Target);
        {Target, Handler, Trap} ->
            Proto = buoy_ref:call(Trap, Handler, [Target]),
            (?IS_OBJECT(Proto) orelse Proto =:= null) orelse invariant(<<"getPrototypeOf">>, <<"trap returned neither object nor null">>),
            case buoy_heap:is_extensible(Target) of
                true -> Proto;
                false ->
                    Proto =:= buoy_heap:prototype_of(Target)
                        orelse invariant(<<"getPrototypeOf">>, <<"proxy target is non-extensible but the trap did not return its actual prototype">>),
                    Proto
            end
    end.

-spec set_prototype_of(term(), term()) -> boolean().
set_prototype_of(Slots, Proto) ->
    case trap(Slots, <<"setPrototypeOf">>) of
        {Target, _, undefined} ->
            buoy_heap:set_prototype(Target, Proto);
        {Target, Handler, Trap} ->
            case buoy_ref:truthy(buoy_ref:call(Trap, Handler, [Target, Proto])) of
                false -> false;
                true ->
                    buoy_heap:is_extensible(Target)
                        orelse Proto =:= buoy_heap:prototype_of(Target)
                        orelse invariant(<<"setPrototypeOf">>, <<"trap returned truish for setting a new prototype on the non-extensible proxy target">>),
                    true
            end
    end.

-spec is_extensible(term()) -> boolean().
is_extensible(Slots) ->
    case trap(Slots, <<"isExtensible">>) of
        {Target, _, undefined} ->
            buoy_heap:is_extensible(Target);
        {Target, Handler, Trap} ->
            Result = buoy_ref:truthy(buoy_ref:call(Trap, Handler, [Target])),
            Result =:= buoy_heap:is_extensible(Target)
                orelse invariant(<<"isExtensible">>, <<"trap result does not reflect extensibility of proxy target">>),
            Result
    end.

-spec prevent_extensions(term()) -> boolean().
prevent_extensions(Slots) ->
    case trap(Slots, <<"preventExtensions">>) of
        {Target, _, undefined} ->
            buoy_heap:prevent_extensions(Target);
        {Target, Handler, Trap} ->
            Result = buoy_ref:truthy(buoy_ref:call(Trap, Handler, [Target])),
            Result andalso buoy_heap:is_extensible(Target)
                andalso invariant(<<"preventExtensions">>, <<"trap returned truish but the proxy target is extensible">>),
            Result
    end.

-spec get_own_property(term(), buoy_heap:key()) -> buoy_heap:property().
get_own_property({Target, {host, M, S}}, K) -> M:get_own_property(S, Target, K);
get_own_property(Slots, K) ->
    case trap(Slots, <<"getOwnPropertyDescriptor">>) of
        {Target, _, undefined} ->
            buoy_heap:get_own(Target, K);
        {Target, Handler, Trap} ->
            Result = buoy_ref:call(Trap, Handler, [Target, key_value(K)]),
            (?IS_OBJECT(Result) orelse Result =:= undefined)
                orelse invariant(<<"getOwnPropertyDescriptor">>, <<"trap returned neither object nor undefined for property '", (key_text(K))/binary, "'">>),
            TargetDesc = buoy_heap:get_own(Target, K),
            own_result(Result, TargetDesc, Target, K)
    end.

own_result(undefined, none, _Target, _K) ->
    none;
own_result(undefined, TargetDesc, Target, K) ->
    configurable(TargetDesc)
        orelse invariant(<<"getOwnPropertyDescriptor">>, <<"trap returned undefined for property '", (key_text(K))/binary, "' which is non-configurable in the proxy target">>),
    buoy_heap:is_extensible(Target)
        orelse invariant(<<"getOwnPropertyDescriptor">>, <<"trap returned undefined for property '", (key_text(K))/binary, "' which exists in the non-extensible proxy target">>),
    none;
own_result(Result, TargetDesc, Target, K) ->
    Extensible = buoy_heap:is_extensible(Target),
    Desc = buoy_ref_object:to_descriptor(Result),
    Complete = complete(Desc),
    compatible(Extensible, Desc, TargetDesc)
        orelse invariant(<<"getOwnPropertyDescriptor">>, <<"trap returned descriptor for property '", (key_text(K))/binary, "' that is incompatible with the existing property in the proxy target">>),
    case configurable(Complete) of
        true ->
            ok;
        false ->
            (TargetDesc =/= none andalso not configurable(TargetDesc))
                orelse invariant(<<"getOwnPropertyDescriptor">>, <<"trap reported non-configurability for property '", (key_text(K))/binary, "' which is either non-existent or configurable in the proxy target">>),
            case {maps:get(writable, Desc, undefined), TargetDesc} of
                {false, {data, _, Bits}} when Bits band 1 =/= 0 ->
                    invariant(<<"getOwnPropertyDescriptor">>, <<"trap reported non-configurable and writable for property '", (key_text(K))/binary, "' which is non-configurable, non-writable in the proxy target">>);
                _ ->
                    ok
            end
    end,
    Complete.

%% CompletePropertyDescriptor, in the form of buoy_heap:get_own/2.
complete(Desc) ->
    Bits = flag(Desc, writable, 1) bor flag(Desc, enumerable, 2) bor flag(Desc, configurable, 4),
    case buoy_heap:is_accessor_descriptor(Desc) of
        true -> {accessor, maps:get(get, Desc, undefined), maps:get(set, Desc, undefined), Bits band 6};
        false -> {data, maps:get(value, Desc, undefined), Bits}
    end.

flag(Desc, Name, Bit) ->
    case maps:get(Name, Desc, false) of
        true -> Bit;
        _ -> 0
    end.

configurable({data, _, Bits}) -> Bits band 4 =/= 0;
configurable({accessor, _, _, Bits}) -> Bits band 4 =/= 0.

%% IsCompatiblePropertyDescriptor.
compatible(Extensible, _Desc, none) -> Extensible;
compatible(Extensible, Desc, Current) -> buoy_heap:validate_and_apply(undefined, <<>>, Extensible, Desc, Current).

-spec define_own_property(term(), buoy_heap:key(), map()) -> boolean().
define_own_property({Target, {host, M, S}}, K, Desc) -> M:define_own_property(S, Target, K, Desc);
define_own_property(Slots, K, Desc) ->
    case trap(Slots, <<"defineProperty">>) of
        {Target, _, undefined} ->
            buoy_heap:define_own_property(Target, K, Desc);
        {Target, Handler, Trap} ->
            DescObj = buoy_ref_object:from_descriptor(Desc),
            case buoy_ref:truthy(buoy_ref:call(Trap, Handler, [Target, key_value(K), DescObj])) of
                false ->
                    false;
                true ->
                    TargetDesc = buoy_heap:get_own(Target, K),
                    Extensible = buoy_heap:is_extensible(Target),
                    ConfigFalse = maps:get(configurable, Desc, undefined) =:= false,
                    check_define(TargetDesc, Extensible, ConfigFalse, Desc, K),
                    true
            end
    end.

check_define(none, Extensible, ConfigFalse, _Desc, K) ->
    Extensible orelse invariant(<<"defineProperty">>, <<"trap returned truish for adding property '", (key_text(K))/binary, "'  to the non-extensible proxy target">>),
    ConfigFalse andalso invariant(<<"defineProperty">>, <<"trap returned truish for defining non-configurable property '", (key_text(K))/binary, "' which is either non-existent or configurable in the proxy target">>);
check_define(TargetDesc, Extensible, ConfigFalse, Desc, K) ->
    compatible(Extensible, Desc, TargetDesc)
        orelse invariant(<<"defineProperty">>, <<"trap returned truish for adding property '", (key_text(K))/binary, "'  that is incompatible with the existing property in the proxy target">>),
    ConfigFalse andalso configurable(TargetDesc)
        andalso invariant(<<"defineProperty">>, <<"trap returned truish for defining non-configurable property '", (key_text(K))/binary, "' which is either non-existent or configurable in the proxy target">>),
    case TargetDesc of
        {data, _, Bits} when Bits band 4 =:= 0, Bits band 1 =/= 0 ->
            maps:get(writable, Desc, undefined) =:= false
                andalso invariant(<<"defineProperty">>, <<"trap returned truish for defining non-configurable property '", (key_text(K))/binary, "' which cannot be non-writable, unless there exists a corresponding non-configurable, non-writable own property of the target object.">>);
        _ ->
            false
    end.

-spec has(term(), buoy_heap:key()) -> boolean().
has({Target, {host, M, S}}, K) -> M:has(S, Target, K);
has(Slots, K) ->
    case trap(Slots, <<"has">>) of
        {Target, _, undefined} ->
            buoy_heap:has(Target, K);
        {Target, Handler, Trap} ->
            case buoy_ref:truthy(buoy_ref:call(Trap, Handler, [Target, key_value(K)])) of
                true ->
                    true;
                false ->
                    case buoy_heap:get_own(Target, K) of
                        none ->
                            ok;
                        TargetDesc ->
                            configurable(TargetDesc)
                                orelse invariant(<<"has">>, <<"trap returned falsish for property '", (key_text(K))/binary, "' which exists in the proxy target as non-configurable">>),
                            buoy_heap:is_extensible(Target)
                                orelse invariant(<<"has">>, <<"trap returned falsish for property '", (key_text(K))/binary, "' but the proxy target is not extensible">>)
                    end,
                    false
            end
    end.

-spec get(term(), buoy_heap:key(), term()) -> term().
get({Target, {host, M, S}}, K, Receiver) -> M:get(S, Target, K, Receiver);
get(Slots, K, Receiver) ->
    case trap(Slots, <<"get">>) of
        {Target, _, undefined} ->
            buoy_heap:get(Target, K, Receiver);
        {Target, Handler, Trap} ->
            Result = buoy_ref:call(Trap, Handler, [Target, key_value(K), Receiver]),
            case buoy_heap:get_own(Target, K) of
                {data, V, Bits} when Bits band 5 =:= 0 ->
                    Result =:= V
                        orelse invariant(<<"get">>, <<"property '", (key_text(K))/binary, "' is a read-only and non-configurable data property on the proxy target but the proxy did not return its actual value">>);
                {accessor, undefined, _, Bits} when Bits band 4 =:= 0 ->
                    Result =:= undefined
                        orelse invariant(<<"get">>, <<"property '", (key_text(K))/binary, "' is a non-configurable accessor property on the proxy target and does not have a getter function, but the trap did not return 'undefined'">>);
                _ ->
                    ok
            end,
            Result
    end.

-spec set(term(), buoy_heap:key(), term(), term()) -> boolean().
set({Target, {host, M, S}}, K, V, Receiver) -> M:set(S, Target, K, V, Receiver);
set(Slots, K, V, Receiver) ->
    case trap(Slots, <<"set">>) of
        {Target, _, undefined} ->
            buoy_heap:set(Target, K, V, Receiver);
        {Target, Handler, Trap} ->
            case buoy_ref:truthy(buoy_ref:call(Trap, Handler, [Target, key_value(K), V, Receiver])) of
                false ->
                    false;
                true ->
                    case buoy_heap:get_own(Target, K) of
                        {data, Value, Bits} when Bits band 5 =:= 0 ->
                            V =:= Value
                                orelse invariant(<<"set">>, <<"trap returned truish for property '", (key_text(K))/binary, "' which exists in the proxy target as a non-configurable and non-writable data property with a different value">>);
                        {accessor, _, undefined, Bits} when Bits band 4 =:= 0 ->
                            invariant(<<"set">>, <<"trap returned truish for property '", (key_text(K))/binary, "' which exists in the proxy target as a non-configurable and non-writable accessor property without a setter">>);
                        _ ->
                            ok
                    end,
                    true
            end
    end.

-spec delete_property(term(), buoy_heap:key()) -> boolean().
delete_property({Target, {host, M, S}}, K) -> M:delete_property(S, Target, K);
delete_property(Slots, K) ->
    case trap(Slots, <<"deleteProperty">>) of
        {Target, _, undefined} ->
            buoy_heap:delete_property(Target, K);
        {Target, Handler, Trap} ->
            case buoy_ref:truthy(buoy_ref:call(Trap, Handler, [Target, key_value(K)])) of
                false ->
                    false;
                true ->
                    case buoy_heap:get_own(Target, K) of
                        none ->
                            true;
                        TargetDesc ->
                            configurable(TargetDesc)
                                orelse invariant(<<"deleteProperty">>, <<"trap returned truish for property '", (key_text(K))/binary, "' which is non-configurable in the proxy target">>),
                            buoy_heap:is_extensible(Target)
                                orelse invariant(<<"deleteProperty">>, <<"trap returned truish for property '", (key_text(K))/binary, "' but the proxy target is non-extensible">>),
                            true
                    end
            end
    end.

-spec own_keys(term()) -> [buoy_heap:key()].
own_keys({Target, {host, M, S}}) -> M:own_keys(S, Target);
own_keys(Slots) ->
    case trap(Slots, <<"ownKeys">>) of
        {Target, _, undefined} ->
            buoy_heap:own_keys(Target);
        {Target, Handler, Trap} ->
            Result = buoy_ref:call(Trap, Handler, [Target]),
            ?IS_OBJECT(Result) orelse type_error(<<"CreateListFromArrayLike called on non-object">>),
            Keys = [trap_key(E) || E <- array_like(Result)],
            length(lists:usort(Keys)) =:= length(Keys)
                orelse invariant(<<"ownKeys">>, <<"trap returned duplicate entries">>),
            Extensible = buoy_heap:is_extensible(Target),
            TargetKeys = buoy_heap:own_keys(Target),
            {Fixed, Free} = lists:partition(fun(Key) -> not configurable_or_missing(buoy_heap:get_own(Target, Key)) end, TargetKeys),
            case Extensible andalso Fixed =:= [] of
                true -> Keys;
                false -> check_keys(Keys, Fixed, Free, Extensible)
            end
    end.

configurable_or_missing(none) -> true;
configurable_or_missing(Desc) -> configurable(Desc).

check_keys(Keys, Fixed, Free, Extensible) ->
    Unchecked = lists:foldl(fun(Key, Left) ->
                                    lists:member(Key, Left)
                                        orelse invariant(<<"ownKeys">>, <<"trap result did not include '", (key_text(Key))/binary, "'">>),
                                    lists:delete(Key, Left)
                            end, Keys, Fixed),
    case Extensible of
        true ->
            Keys;
        false ->
            Rest = lists:foldl(fun(Key, Left) ->
                                       lists:member(Key, Left)
                                           orelse invariant(<<"ownKeys">>, <<"trap result did not include '", (key_text(Key))/binary, "'">>),
                                       lists:delete(Key, Left)
                               end, Unchecked, Free),
            Rest =:= [] orelse invariant(<<"ownKeys">>, <<"trap returned extra keys but proxy target is non-extensible">>),
            Keys
    end.

%% CreateListFromArrayLike of the ownKeys result: every element a string or a symbol.
array_like(O) ->
    Length = buoy_ref_number:to_integer_or_infinity(buoy_ref:get(O, <<"length">>)),
    N = case Length of
        L when is_integer(L), L > 0 -> L;
        _ -> 0
    end,
    [buoy_ref:get(O, I) || I <- lists:seq(0, N - 1)].

trap_key({'$sym', _, _} = S) -> S;
trap_key(S) when ?IS_STRING(S) -> buoy_heap:to_key(S);
trap_key(V) -> type_error(buoy_ref_string:concat(buoy_ref:describe(V), <<" is not a valid property name">>)).

%% [[Call]] of a proxy whose record is under Id.
-spec call(term(), term(), list()) -> term().
call(Id, This, Args) ->
    {proxy, _, _, _, _, Slots} = erlang:get(Id),
    case trap(Slots, <<"apply">>) of
        {Target, _, undefined} -> buoy_ref:call(Target, This, Args);
        {Target, Handler, Trap} -> buoy_ref:call(Trap, Handler, [Target, This, buoy_heap:new_array(Args)])
    end.

-spec construct(term(), list(), term()) -> term().
construct(Slots, Args, NewTarget) ->
    case trap(Slots, <<"construct">>) of
        {Target, _, undefined} ->
            buoy_heap:is_constructor(Target) orelse type_error(<<"proxy target is not a constructor">>),
            buoy_heap:construct(Target, Args, NewTarget);
        {Target, Handler, Trap} ->
            buoy_heap:is_constructor(Target) orelse type_error(<<"proxy target is not a constructor">>),
            Result = buoy_ref:call(Trap, Handler, [Target, buoy_heap:new_array(Args), NewTarget]),
            ?IS_OBJECT(Result) orelse invariant(<<"construct">>, <<"trap returned non-object ('", (buoy_ref:to_string(buoy_ref:typeof(Result)))/binary, "')">>),
            Result
    end.

key_text(K) when is_integer(K) -> integer_to_binary(K);
key_text({'$sym', _, _} = S) -> buoy_ref:describe(S);
key_text(K) -> buoy_ref:to_string(K).
