%% The Proxy family: the Proxy constructor, Proxy.revocable, and the internal
%% methods of a proxy object (ECMA-262 §10.5), with the invariant checks of
%% each trap.
%%
%% A proxy is a heap record of the class proxy whose slots are
%% {Target, Handler}, or {revoked, IsConstructor} after Proxy.revocable's
%% revoke ran. A proxy of a callable target is a function value, so typeof
%% and calls see a function; the other proxies are object values. bouy_heap
%% sends each internal method of a proxy record here.
-module(bouy_ref_proxy).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).
-export([get/3, set/4, has/2, delete_property/2, own_keys/1, get_own_property/2, define_own_property/3]).
-export([get_prototype_of/1, set_prototype_of/2, is_extensible/1, prevent_extensions/1, call/3, construct/3]).
-export([target/1]).

-import(bouy_ref_realm, [arg/2, builtin/2, record/4, ctor_record/5]).
-import(bouy_ref, [type_error/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Statics = ?METHODS(<<"Proxy">>, [{<<"revocable">>, 2}]),
    Entries = [{<<"length">>, 2}, {<<"name">>, <<"Proxy">>} | Statics],
    {Class, Proto, Props, Keys, Attrs, Slots} = record(function, ?FUNCTION_PROTO, Entries, #{construct => fun construct_proxy/2, kind => builtin}),
    [{{builtin, <<"Proxy">>}, {Class, Proto, Props, Keys, Attrs#{<<"length">> => 4, <<"name">> => 4}, Slots}}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Proxy">>, bouy_ref_realm:constructor(?MODULE, <<"Proxy">>)}].

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(<<"Proxy">>, _This, _Args) -> type_error(<<"Constructor Proxy requires 'new'">>).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Proxy">>, <<"revocable">>, _This, Args) ->
    P = create(arg(1, Args), arg(2, Args)),
    Revoke = bouy_heap:function(fun(_, _) -> revoke(P) end, <<>>, 0, #{}),
    bouy_heap:object(?OBJECT_PROTO, [{<<"proxy">>, P}, {<<"revoke">>, Revoke}]).

construct_proxy(_NewTarget, Args) -> create(arg(1, Args), arg(2, Args)).

%% ProxyCreate.
create(Target, Handler) ->
    ?IS_OBJECT(Target) andalso ?IS_OBJECT(Handler)
        orelse type_error(<<"Cannot create proxy with a non-object as target or handler">>),
    bouy_heap:proxy(Target, Handler).

revoke(Proxy) ->
    case bouy_heap:slots(Proxy) of
        {revoked, _} -> ok;
        {Target, _} -> bouy_heap:set_slots(Proxy, {revoked, bouy_heap:is_constructor(Target)})
    end,
    undefined.

%% The target of a proxy, through every level, for IsArray and the tag of
%% Object.prototype.toString. A revoked proxy throws.
-spec target(term()) -> term().
target(P) ->
    case bouy_heap:class_of(P) of
        proxy ->
            {Target, _} = live(bouy_heap:slots(P), <<"IsArray">>),
            target(Target);
        _ ->
            P
    end.

%%% Traps

live({revoked, _}, Name) ->
    type_error(bouy_ref_string:concat([<<"Cannot perform '">>, Name, <<"' on a proxy that has been revoked">>]));
live(Slots, _Name) ->
    Slots.

%% The trap Name of the handler: {Target, Handler, undefined or a function}.
trap({revoked, _} = Slots, Name) ->
    live(Slots, Name);
trap({Target, Handler}, Name) ->
    Trap = case bouy_ref:get(Handler, Name) of
        T when T =:= undefined; T =:= null -> undefined;
        {'$f', _, _} = T -> bouy_ref_realm:callee(T);
        T -> type_error(bouy_ref_string:concat([bouy_ref:describe(T), <<" returned for property '">>, Name, <<"' of object '#<Object>' is not a function">>]))
    end,
    {Target, Handler, Trap}.

key_value(K) -> bouy_heap:key_to_value(K).

-spec invariant(binary(), binary()) -> no_return().
invariant(Trap, Message) ->
    type_error(bouy_ref_string:concat([<<"'">>, Trap, <<"' on proxy: ">>, Message])).

-spec get_prototype_of(term()) -> term().
get_prototype_of(Slots) ->
    case trap(Slots, <<"getPrototypeOf">>) of
        {Target, _, undefined} ->
            bouy_heap:prototype_of(Target);
        {Target, Handler, Trap} ->
            Proto = bouy_ref:call(Trap, Handler, [Target]),
            (?IS_OBJECT(Proto) orelse Proto =:= null) orelse invariant(<<"getPrototypeOf">>, <<"trap returned neither object nor null">>),
            case bouy_heap:is_extensible(Target) of
                true -> Proto;
                false ->
                    Proto =:= bouy_heap:prototype_of(Target)
                        orelse invariant(<<"getPrototypeOf">>, <<"proxy target is non-extensible but the trap did not return its actual prototype">>),
                    Proto
            end
    end.

-spec set_prototype_of(term(), term()) -> boolean().
set_prototype_of(Slots, Proto) ->
    case trap(Slots, <<"setPrototypeOf">>) of
        {Target, _, undefined} ->
            bouy_heap:set_prototype(Target, Proto);
        {Target, Handler, Trap} ->
            case bouy_ref:truthy(bouy_ref:call(Trap, Handler, [Target, Proto])) of
                false -> false;
                true ->
                    bouy_heap:is_extensible(Target)
                        orelse Proto =:= bouy_heap:prototype_of(Target)
                        orelse invariant(<<"setPrototypeOf">>, <<"trap returned truish for setting a new prototype on the non-extensible proxy target">>),
                    true
            end
    end.

-spec is_extensible(term()) -> boolean().
is_extensible(Slots) ->
    case trap(Slots, <<"isExtensible">>) of
        {Target, _, undefined} ->
            bouy_heap:is_extensible(Target);
        {Target, Handler, Trap} ->
            Result = bouy_ref:truthy(bouy_ref:call(Trap, Handler, [Target])),
            Result =:= bouy_heap:is_extensible(Target)
                orelse invariant(<<"isExtensible">>, <<"trap result does not reflect extensibility of proxy target">>),
            Result
    end.

-spec prevent_extensions(term()) -> boolean().
prevent_extensions(Slots) ->
    case trap(Slots, <<"preventExtensions">>) of
        {Target, _, undefined} ->
            bouy_heap:prevent_extensions(Target);
        {Target, Handler, Trap} ->
            Result = bouy_ref:truthy(bouy_ref:call(Trap, Handler, [Target])),
            Result andalso bouy_heap:is_extensible(Target)
                andalso invariant(<<"preventExtensions">>, <<"trap returned truish but the proxy target is extensible">>),
            Result
    end.

-spec get_own_property(term(), bouy_heap:key()) -> bouy_heap:property().
get_own_property(Slots, K) ->
    case trap(Slots, <<"getOwnPropertyDescriptor">>) of
        {Target, _, undefined} ->
            bouy_heap:get_own(Target, K);
        {Target, Handler, Trap} ->
            Result = bouy_ref:call(Trap, Handler, [Target, key_value(K)]),
            (?IS_OBJECT(Result) orelse Result =:= undefined)
                orelse invariant(<<"getOwnPropertyDescriptor">>, <<"trap returned neither object nor undefined for property '", (key_text(K))/binary, "'">>),
            TargetDesc = bouy_heap:get_own(Target, K),
            own_result(Result, TargetDesc, Target, K)
    end.

own_result(undefined, none, _Target, _K) ->
    none;
own_result(undefined, TargetDesc, Target, K) ->
    configurable(TargetDesc)
        orelse invariant(<<"getOwnPropertyDescriptor">>, <<"trap returned undefined for property '", (key_text(K))/binary, "' which is non-configurable in the proxy target">>),
    bouy_heap:is_extensible(Target)
        orelse invariant(<<"getOwnPropertyDescriptor">>, <<"trap returned undefined for property '", (key_text(K))/binary, "' which exists in the non-extensible proxy target">>),
    none;
own_result(Result, TargetDesc, Target, K) ->
    Extensible = bouy_heap:is_extensible(Target),
    Desc = bouy_ref_object:to_descriptor(Result),
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

%% CompletePropertyDescriptor, in the form of bouy_heap:get_own/2.
complete(Desc) ->
    Bits = flag(Desc, writable, 1) bor flag(Desc, enumerable, 2) bor flag(Desc, configurable, 4),
    case bouy_heap:is_accessor_descriptor(Desc) of
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
compatible(Extensible, Desc, Current) -> bouy_heap:validate_and_apply(undefined, <<>>, Extensible, Desc, Current).

-spec define_own_property(term(), bouy_heap:key(), map()) -> boolean().
define_own_property(Slots, K, Desc) ->
    case trap(Slots, <<"defineProperty">>) of
        {Target, _, undefined} ->
            bouy_heap:define_own_property(Target, K, Desc);
        {Target, Handler, Trap} ->
            DescObj = bouy_ref_object:from_descriptor(Desc),
            case bouy_ref:truthy(bouy_ref:call(Trap, Handler, [Target, key_value(K), DescObj])) of
                false ->
                    false;
                true ->
                    TargetDesc = bouy_heap:get_own(Target, K),
                    Extensible = bouy_heap:is_extensible(Target),
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

-spec has(term(), bouy_heap:key()) -> boolean().
has(Slots, K) ->
    case trap(Slots, <<"has">>) of
        {Target, _, undefined} ->
            bouy_heap:has(Target, K);
        {Target, Handler, Trap} ->
            case bouy_ref:truthy(bouy_ref:call(Trap, Handler, [Target, key_value(K)])) of
                true ->
                    true;
                false ->
                    case bouy_heap:get_own(Target, K) of
                        none ->
                            ok;
                        TargetDesc ->
                            configurable(TargetDesc)
                                orelse invariant(<<"has">>, <<"trap returned falsish for property '", (key_text(K))/binary, "' which exists in the proxy target as non-configurable">>),
                            bouy_heap:is_extensible(Target)
                                orelse invariant(<<"has">>, <<"trap returned falsish for property '", (key_text(K))/binary, "' but the proxy target is not extensible">>)
                    end,
                    false
            end
    end.

-spec get(term(), bouy_heap:key(), term()) -> term().
get(Slots, K, Receiver) ->
    case trap(Slots, <<"get">>) of
        {Target, _, undefined} ->
            bouy_heap:get(Target, K, Receiver);
        {Target, Handler, Trap} ->
            Result = bouy_ref:call(Trap, Handler, [Target, key_value(K), Receiver]),
            case bouy_heap:get_own(Target, K) of
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

-spec set(term(), bouy_heap:key(), term(), term()) -> boolean().
set(Slots, K, V, Receiver) ->
    case trap(Slots, <<"set">>) of
        {Target, _, undefined} ->
            bouy_heap:set(Target, K, V, Receiver);
        {Target, Handler, Trap} ->
            case bouy_ref:truthy(bouy_ref:call(Trap, Handler, [Target, key_value(K), V, Receiver])) of
                false ->
                    false;
                true ->
                    case bouy_heap:get_own(Target, K) of
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

-spec delete_property(term(), bouy_heap:key()) -> boolean().
delete_property(Slots, K) ->
    case trap(Slots, <<"deleteProperty">>) of
        {Target, _, undefined} ->
            bouy_heap:delete_property(Target, K);
        {Target, Handler, Trap} ->
            case bouy_ref:truthy(bouy_ref:call(Trap, Handler, [Target, key_value(K)])) of
                false ->
                    false;
                true ->
                    case bouy_heap:get_own(Target, K) of
                        none ->
                            true;
                        TargetDesc ->
                            configurable(TargetDesc)
                                orelse invariant(<<"deleteProperty">>, <<"trap returned truish for property '", (key_text(K))/binary, "' which is non-configurable in the proxy target">>),
                            bouy_heap:is_extensible(Target)
                                orelse invariant(<<"deleteProperty">>, <<"trap returned truish for property '", (key_text(K))/binary, "' but the proxy target is non-extensible">>),
                            true
                    end
            end
    end.

-spec own_keys(term()) -> [bouy_heap:key()].
own_keys(Slots) ->
    case trap(Slots, <<"ownKeys">>) of
        {Target, _, undefined} ->
            bouy_heap:own_keys(Target);
        {Target, Handler, Trap} ->
            Result = bouy_ref:call(Trap, Handler, [Target]),
            ?IS_OBJECT(Result) orelse type_error(<<"CreateListFromArrayLike called on non-object">>),
            Keys = [trap_key(E) || E <- array_like(Result)],
            length(lists:usort(Keys)) =:= length(Keys)
                orelse invariant(<<"ownKeys">>, <<"trap returned duplicate entries">>),
            Extensible = bouy_heap:is_extensible(Target),
            TargetKeys = bouy_heap:own_keys(Target),
            {Fixed, Free} = lists:partition(fun(Key) -> not configurable_or_missing(bouy_heap:get_own(Target, Key)) end, TargetKeys),
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
    Length = bouy_ref_number:to_integer_or_infinity(bouy_ref:get(O, <<"length">>)),
    N = case Length of
        L when is_integer(L), L > 0 -> L;
        _ -> 0
    end,
    [bouy_ref:get(O, I) || I <- lists:seq(0, N - 1)].

trap_key({'$sym', _, _} = S) -> S;
trap_key(S) when ?IS_STRING(S) -> bouy_heap:to_key(S);
trap_key(V) -> type_error(bouy_ref_string:concat(bouy_ref:describe(V), <<" is not a valid property name">>)).

%% [[Call]] of a proxy whose record is under Id.
-spec call(term(), term(), list()) -> term().
call(Id, This, Args) ->
    {proxy, _, _, _, _, Slots} = erlang:get(Id),
    case trap(Slots, <<"apply">>) of
        {Target, _, undefined} -> bouy_ref:call(Target, This, Args);
        {Target, Handler, Trap} -> bouy_ref:call(Trap, Handler, [Target, This, bouy_heap:new_array(Args)])
    end.

-spec construct(term(), list(), term()) -> term().
construct(Slots, Args, NewTarget) ->
    case trap(Slots, <<"construct">>) of
        {Target, _, undefined} ->
            bouy_heap:is_constructor(Target) orelse type_error(<<"proxy target is not a constructor">>),
            bouy_heap:construct(Target, Args, NewTarget);
        {Target, Handler, Trap} ->
            bouy_heap:is_constructor(Target) orelse type_error(<<"proxy target is not a constructor">>),
            Result = bouy_ref:call(Trap, Handler, [Target, bouy_heap:new_array(Args), NewTarget]),
            ?IS_OBJECT(Result) orelse invariant(<<"construct">>, <<"trap returned non-object ('", (bouy_ref:to_string(bouy_ref:typeof(Result)))/binary, "')">>),
            Result
    end.

key_text(K) when is_integer(K) -> integer_to_binary(K);
key_text({'$sym', _, _} = S) -> bouy_ref:describe(S);
key_text(K) -> bouy_ref:to_string(K).
