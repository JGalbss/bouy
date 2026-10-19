%% The weak family: WeakMap, WeakSet, WeakRef, and FinalizationRegistry.
%%
%% The heap collector (buoy_heap:gc/1) treats them as weak: it marks the value
%% of a WeakMap entry only while the key is live, drops the entries of dead
%% keys, empties a WeakRef whose target died, and queues the cleanup callback
%% of each registry cell whose target died. A symbol key never dies.
%%
%% A WeakMap is the class weakmap with the slots #{Key => Value}, and a
%% WeakSet the class weakset with #{Key => true}: weak collections have no
%% order, because they cannot be iterated. A WeakRef holds its target, and a
%% registry {Cleanup, [{Target, Held, Token}]}.
-module(buoy_ref_weak).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, can_be_held_weakly/1]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).
-import(buoy_ref, [type_error/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'WeakMap.prototype', proto(<<"WeakMap">>, ?METHODS(<<"WeakMap.prototype">>, [{<<"delete">>, 1}, {<<"get">>, 1}, {<<"has">>, 1}, {<<"set">>, 2},
                                                                              {<<"getOrInsert">>, 2}, {<<"getOrInsertComputed">>, 2}]))},
     {'WeakSet.prototype', proto(<<"WeakSet">>, ?METHODS(<<"WeakSet.prototype">>, [{<<"add">>, 1}, {<<"delete">>, 1}, {<<"has">>, 1}]))},
     {{builtin, <<"WeakMap">>}, ctor_record(<<"WeakMap">>, 0, {'$o', 'WeakMap.prototype'}, [], fun weak_map/2)},
     {{builtin, <<"WeakSet">>}, ctor_record(<<"WeakSet">>, 0, {'$o', 'WeakSet.prototype'}, [], fun weak_set/2)},
     {'WeakRef.prototype', proto(<<"WeakRef">>, ?METHODS(<<"WeakRef.prototype">>, [{<<"deref">>, 0}]))},
     {'FinalizationRegistry.prototype', proto(<<"FinalizationRegistry">>,
                                              ?METHODS(<<"FinalizationRegistry.prototype">>, [{<<"register">>, 2}, {<<"unregister">>, 1}, {<<"cleanupSome">>, 0}]))},
     {{builtin, <<"WeakRef">>}, ctor_record(<<"WeakRef">>, 1, {'$o', 'WeakRef.prototype'}, [], fun weak_ref/2)},
     {{builtin, <<"FinalizationRegistry">>}, ctor_record(<<"FinalizationRegistry">>, 1, {'$o', 'FinalizationRegistry.prototype'}, [], fun registry/2)}].

proto(Name, Methods) ->
    {Class, P, Props, Keys, Attrs, Slots} = record(object, ?OBJECT_PROTO, Methods ++ [{<<"constructor">>, constructor(Name)}, {?SYM(toStringTag), Name}], none),
    {Class, P, Props, Keys, Attrs#{?SYM(toStringTag) => 4}, Slots}.

-spec globals() -> [{binary(), term()}].
globals() -> [{N, constructor(N)} || N <- [<<"WeakMap">>, <<"WeakSet">>, <<"WeakRef">>, <<"FinalizationRegistry">>]].

constructor(Name) -> buoy_ref_realm:constructor(?MODULE, Name).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(Name, _This, _Args) -> type_error(<<"Constructor ", Name/binary, " requires 'new'">>).

weak_map(NewTarget, Args) ->
    M = buoy_heap:new_exotic(weakmap, buoy_ref_realm:proto_for(NewTarget, 'WeakMap.prototype'), #{}),
    fill(M, arg(1, Args), <<"set">>, fun(Adder, Entry) ->
                                             ?IS_OBJECT(Entry) orelse type_error(<<"Iterator value is not an entry object">>),
                                             K = buoy_ref:get(Entry, 0),
                                             V = buoy_ref:get(Entry, 1),
                                             buoy_ref:call(Adder, M, [K, V])
                                     end).

weak_set(NewTarget, Args) ->
    S = buoy_heap:new_exotic(weakset, buoy_ref_realm:proto_for(NewTarget, 'WeakSet.prototype'), #{}),
    fill(S, arg(1, Args), <<"add">>, fun(Adder, Value) -> buoy_ref:call(Adder, S, [Value]) end).

%% AddEntriesFromIterable: the adder of the new collection runs for each
%% item, and an error closes the iterator.
fill(Collection, Iterable, _AdderName, _Add) when Iterable =:= undefined; Iterable =:= null ->
    Collection;
fill(Collection, Iterable, AdderName, Add) ->
    Adder = buoy_ref:get(Collection, AdderName),
    buoy_heap:is_callable(Adder) orelse type_error(<<"'", AdderName/binary, "' returned for property is not a function">>),
    each(buoy_ref_iterator:iterate(Iterable), fun(Item) -> Add(Adder, Item) end),
    Collection.

each(State, Fun) ->
    case buoy_ref_iterator:step(State) of
        done ->
            ok;
        {value, Item, State1} ->
            try
                Fun(Item)
            catch
                error:{'$throw', _} = Reason:Stack ->
                    buoy_ref_iterator:close_quietly(State1),
                    erlang:raise(error, Reason, Stack)
            end,
            each(State1, Fun)
    end.


weak_ref(NewTarget, Args) ->
    Target = arg(1, Args),
    can_be_held_weakly(Target) orelse type_error(<<"WeakRef: invalid target">>),
    buoy_heap:new_exotic(weak_ref, buoy_ref_realm:proto_for(NewTarget, 'WeakRef.prototype'), Target).

registry(NewTarget, Args) ->
    Cleanup = arg(1, Args),
    buoy_heap:is_callable(Cleanup) orelse type_error(<<"FinalizationRegistry: cleanup must be callable">>),
    buoy_heap:new_exotic(finalization_registry, buoy_ref_realm:proto_for(NewTarget, 'FinalizationRegistry.prototype'), {Cleanup, []}).

%% CanBeHeldWeakly: an object, or a symbol that Symbol.for did not make.
-spec can_be_held_weakly(term()) -> boolean().
can_be_held_weakly(V) when ?IS_OBJECT(V) -> true;
can_be_held_weakly({'$sym', registered, _}) -> false;
can_be_held_weakly({'$sym', _, _}) -> true;
can_be_held_weakly(_) -> false.

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"WeakMap.prototype">>, Name, This, Args) ->
    Entries = this_of(This, weakmap, <<"WeakMap.prototype.", Name/binary>>),
    weak_map_method(Name, This, Entries, Args);
method(<<"WeakSet.prototype">>, Name, This, Args) ->
    Members = this_of(This, weakset, <<"WeakSet.prototype.", Name/binary>>),
    weak_set_method(Name, This, Members, Args);
method(<<"WeakRef.prototype">>, <<"deref">>, This, _Args) ->
    this_of(This, weak_ref, <<"WeakRef.prototype.deref">>);
method(<<"FinalizationRegistry.prototype">>, <<"register">>, This, Args) ->
    {Cleanup, Cells} = this_of(This, finalization_registry, <<"FinalizationRegistry.prototype.register">>),
    [Target, Held, Token] = [arg(N, Args) || N <- [1, 2, 3]],
    can_be_held_weakly(Target) orelse type_error(<<"FinalizationRegistry.prototype.register: invalid target">>),
    Target =/= Held orelse type_error(<<"FinalizationRegistry.prototype.register: target and holdings must not be same">>),
    Token =:= undefined orelse can_be_held_weakly(Token) orelse type_error(<<"FinalizationRegistry.prototype.register: invalid unregister token">>),
    buoy_heap:set_slots(This, {Cleanup, [{Target, Held, Token} | Cells]}),
    undefined;
method(<<"FinalizationRegistry.prototype">>, <<"unregister">>, This, Args) ->
    {Cleanup, Cells} = this_of(This, finalization_registry, <<"FinalizationRegistry.prototype.unregister">>),
    Token = arg(1, Args),
    can_be_held_weakly(Token) orelse type_error(<<"Invalid unregisterToken ('", (buoy_ref:to_string(describe(Token)))/binary, "')">>),
    Kept = [Cell || {_, _, T} = Cell <- Cells, T =/= Token],
    buoy_heap:set_slots(This, {Cleanup, Kept}),
    length(Kept) =/= length(Cells);
method(<<"FinalizationRegistry.prototype">>, <<"cleanupSome">>, This, Args) ->
    _ = this_of(This, finalization_registry, <<"FinalizationRegistry.prototype.cleanupSome">>),
    case arg(1, Args) of
        undefined -> ok;
        F -> buoy_heap:is_callable(F) orelse type_error(<<"FinalizationRegistry.prototype.cleanupSome: callback must be callable">>)
    end,
    undefined.

weak_map_method(<<"get">>, _M, Entries, Args) -> maps:get(arg(1, Args), Entries, undefined);
weak_map_method(<<"has">>, _M, Entries, Args) -> is_map_key(arg(1, Args), Entries);
weak_map_method(<<"delete">>, M, Entries, Args) ->
    K = arg(1, Args),
    case Entries of
        #{K := _} -> buoy_heap:set_slots(M, maps:remove(K, Entries)), true;
        _ -> false
    end;
weak_map_method(<<"set">>, M, Entries, Args) ->
    K = weak_key(arg(1, Args), <<"Invalid value used as weak map key">>),
    buoy_heap:set_slots(M, Entries#{K => arg(2, Args)}),
    M;
weak_map_method(<<"getOrInsert">>, M, Entries, Args) ->
    K = weak_key(arg(1, Args), <<"Invalid value used as weak map key">>),
    case Entries of
        #{K := V} -> V;
        _ -> V = arg(2, Args), buoy_heap:set_slots(M, Entries#{K => V}), V
    end;
weak_map_method(<<"getOrInsertComputed">>, M, Entries, Args) ->
    K = weak_key(arg(1, Args), <<"Invalid value used as weak map key">>),
    F = buoy_ref_realm:callable(arg(2, Args)),
    case Entries of
        #{K := V} ->
            V;
        _ ->
            V = buoy_ref:call(F, undefined, [K]),
            buoy_heap:set_slots(M, (buoy_heap:slots(M))#{K => V}),
            V
    end.

weak_set_method(<<"has">>, _S, Members, Args) -> is_map_key(arg(1, Args), Members);
weak_set_method(<<"delete">>, S, Members, Args) ->
    K = arg(1, Args),
    case Members of
        #{K := _} -> buoy_heap:set_slots(S, maps:remove(K, Members)), true;
        _ -> false
    end;
weak_set_method(<<"add">>, S, Members, Args) ->
    K = weak_key(arg(1, Args), <<"Invalid value used in weak set">>),
    buoy_heap:set_slots(S, Members#{K => true}),
    S.

weak_key(K, Message) ->
    can_be_held_weakly(K) orelse type_error(Message),
    K.

this_of(This, Class, Name) ->
    ?IS_OBJECT(This) andalso buoy_heap:class_of(This) =:= Class
        orelse type_error(<<Name/binary, " called on an incompatible receiver">>),
    buoy_heap:slots(This).

describe({'$sym', _, _} = S) -> buoy_ref:describe(S);
describe(V) when ?IS_OBJECT(V) -> <<"[object Object]">>;
describe(V) -> V.
