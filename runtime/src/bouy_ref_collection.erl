%% The keyed collections: Map, Set, WeakMap, and WeakSet.
-module(bouy_ref_collection).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, collection_size/1]).

-import(bouy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

-define(NAMES, [<<"Map">>, <<"Set">>, <<"WeakMap">>, <<"WeakSet">>]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Map.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"Map.prototype">>, [<<"get">>, <<"set">>, <<"has">>, <<"delete">>, <<"clear">>, <<"forEach">>, <<"keys">>, <<"values">>, <<"entries">>])
         ++ [{<<"size">>, {'$accessor', builtin(<<"get size">>, fun(This, _) -> ?MODULE:collection_size(This) end), undefined}},
             {<<"constructor">>, constructor(<<"Map">>)}, {?SYM(toStringTag), <<"Map">>},
             {?SYM(iterator), builtin(<<"Map.prototype.entries">>, fun(This, Args) -> ?MODULE:method(<<"Map.prototype">>, <<"entries">>, This, Args) end)}], none)},
     {'Set.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"Set.prototype">>, [<<"add">>, <<"has">>, <<"delete">>, <<"clear">>, <<"forEach">>, <<"keys">>, <<"values">>, <<"entries">>])
         ++ [{<<"size">>, {'$accessor', builtin(<<"get size">>, fun(This, _) -> ?MODULE:collection_size(This) end), undefined}},
             {<<"constructor">>, constructor(<<"Set">>)}, {?SYM(toStringTag), <<"Set">>},
             {?SYM(iterator), builtin(<<"Set.prototype.values">>, fun(This, Args) -> ?MODULE:method(<<"Set.prototype">>, <<"values">>, This, Args) end)}], none)},
     {'WeakMap.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"Map.prototype">>, [<<"get">>, <<"set">>, <<"has">>, <<"delete">>]) ++ [{<<"constructor">>, constructor(<<"WeakMap">>)}], none)},
     {'WeakSet.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"Set.prototype">>, [<<"add">>, <<"has">>, <<"delete">>]) ++ [{<<"constructor">>, constructor(<<"WeakSet">>)}], none)},
     {{builtin, <<"Map">>}, ctor_record(<<"Map">>, 0, {'$o', 'Map.prototype'}, ?METHODS(<<"Map">>, [<<"groupBy">>]), fun map_construct/2)},
     {{builtin, <<"Set">>}, ctor_record(<<"Set">>, 0, {'$o', 'Set.prototype'}, [], fun set_construct/2)},
     {{builtin, <<"WeakMap">>}, ctor_record(<<"WeakMap">>, 0, {'$o', 'WeakMap.prototype'}, [], fun map_construct/2)},
     {{builtin, <<"WeakSet">>}, ctor_record(<<"WeakSet">>, 0, {'$o', 'WeakSet.prototype'}, [], fun set_construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{N, constructor(N)} || N <- ?NAMES].

constructor(Name) -> bouy_ref_realm:constructor(?MODULE, Name).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(Name, _This, _Args) -> type_error(<<"Constructor ", Name/binary, " requires 'new'">>).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Map.prototype">>, Name, This, Args) -> map_proto(Name, This, Args);
method(<<"Set.prototype">>, Name, This, Args) -> set_proto(Name, This, Args);
method(<<"Map">>, <<"groupBy">>, _This, Args) ->
    M = map_construct(constructor(<<"Map">>), []),
    lists:foreach(fun({I, V}) ->
                          K = bouy_ref:call(arg(2, Args), undefined, [V, I]),
                          case map_proto(<<"get">>, M, [K]) of
                              undefined -> map_proto(<<"set">>, M, [K, bouy_heap:new_array([V])]);
                              Group -> bouy_heap:array_push(Group, [V])
                          end
                  end, lists:enumerate(0, bouy_ref_iterator:to_list(arg(1, Args)))),
    M.

map_construct(NewTarget, Args) ->
    M = bouy_heap:new_exotic(map, collection_proto(NewTarget, 'Map.prototype'), {#{}, 0}),
    case arg(1, Args) of
        V when V =:= undefined; V =:= null -> ok;
        Iterable -> [map_proto(<<"set">>, M, [bouy_ref:get(E, 0), bouy_ref:get(E, 1)]) || E <- bouy_ref_iterator:to_list(Iterable)]
    end,
    M.

set_construct(NewTarget, Args) ->
    S = bouy_heap:new_exotic(set, collection_proto(NewTarget, 'Set.prototype'), {#{}, 0}),
    case arg(1, Args) of
        V when V =:= undefined; V =:= null -> ok;
        Iterable -> [set_proto(<<"add">>, S, [X]) || X <- bouy_ref_iterator:to_list(Iterable)]
    end,
    S.

collection_proto({'$f', {builtin, <<"WeakMap">>}, _}, _) -> {'$o', 'WeakMap.prototype'};
collection_proto({'$f', {builtin, <<"WeakSet">>}, _}, _) -> {'$o', 'WeakSet.prototype'};
collection_proto({'$f', {builtin, _}, _}, Default) -> {'$o', Default};
collection_proto(NewTarget, _Default) -> bouy_ref:get(NewTarget, <<"prototype">>).

collection_size(O) ->
    {Index, _} = bouy_heap:slots(O),
    map_size(Index).

%% SameValueZero keys: -0 is 0, and canonical numbers compare as terms.
key(F) when is_float(F), F == 0 -> 0;
key(K) -> K.

map_entries(M) ->
    {Index, _} = bouy_heap:slots(M),
    [{K, V} || {_, K, V} <- lists:sort([{Seq, K, V} || K := {Seq, V} <- Index])].

map_proto(<<"get">>, M, Args) ->
    {Index, _} = bouy_heap:slots(M),
    K = key(arg(1, Args)),
    case Index of
        #{K := {_, V}} -> V;
        _ -> undefined
    end;
map_proto(<<"set">>, M, Args) ->
    {Index, Next} = bouy_heap:slots(M),
    K = key(arg(1, Args)),
    V = arg(2, Args),
    case Index of
        #{K := {Seq, _}} -> bouy_heap:set_slots(M, {Index#{K := {Seq, V}}, Next});
        _ -> bouy_heap:set_slots(M, {Index#{K => {Next, V}}, Next + 1})
    end,
    M;
map_proto(<<"has">>, M, Args) ->
    {Index, _} = bouy_heap:slots(M),
    is_map_key(key(arg(1, Args)), Index);
map_proto(<<"delete">>, M, Args) ->
    {Index, Next} = bouy_heap:slots(M),
    K = key(arg(1, Args)),
    case Index of
        #{K := _} -> bouy_heap:set_slots(M, {maps:remove(K, Index), Next}), true;
        _ -> false
    end;
map_proto(<<"clear">>, M, _) ->
    {_, Next} = bouy_heap:slots(M),
    bouy_heap:set_slots(M, {#{}, Next}),
    undefined;
map_proto(<<"forEach">>, M, Args) ->
    F = callable(arg(1, Args)),
    [bouy_ref:call(F, arg(2, Args), [V, K, M]) || {K, V} <- map_entries(M)],
    undefined;
map_proto(<<"keys">>, M, _) -> bouy_ref_iterator:list_iterator(<<"Map Iterator">>, [K || {K, _} <- map_entries(M)]);
map_proto(<<"values">>, M, _) -> bouy_ref_iterator:list_iterator(<<"Map Iterator">>, [V || {_, V} <- map_entries(M)]);
map_proto(<<"entries">>, M, _) -> bouy_ref_iterator:list_iterator(<<"Map Entries">>, [bouy_heap:new_array([K, V]) || {K, V} <- map_entries(M)]).

set_members(S) ->
    {Index, _} = bouy_heap:slots(S),
    [K || {_, K} <- lists:sort([{Seq, K} || K := Seq <- Index])].

set_proto(<<"add">>, S, Args) ->
    {Index, Next} = bouy_heap:slots(S),
    K = key(arg(1, Args)),
    case Index of
        #{K := _} -> ok;
        _ -> bouy_heap:set_slots(S, {Index#{K => Next}, Next + 1})
    end,
    S;
set_proto(<<"has">>, S, Args) ->
    {Index, _} = bouy_heap:slots(S),
    is_map_key(key(arg(1, Args)), Index);
set_proto(<<"delete">>, S, Args) ->
    {Index, Next} = bouy_heap:slots(S),
    K = key(arg(1, Args)),
    case Index of
        #{K := _} -> bouy_heap:set_slots(S, {maps:remove(K, Index), Next}), true;
        _ -> false
    end;
set_proto(<<"clear">>, S, _) ->
    {_, Next} = bouy_heap:slots(S),
    bouy_heap:set_slots(S, {#{}, Next}),
    undefined;
set_proto(<<"forEach">>, S, Args) ->
    F = callable(arg(1, Args)),
    [bouy_ref:call(F, arg(2, Args), [K, K, S]) || K <- set_members(S)],
    undefined;
set_proto(Name, S, _) when Name =:= <<"values">>; Name =:= <<"keys">> -> bouy_ref_iterator:list_iterator(<<"Set Iterator">>, set_members(S));
set_proto(<<"entries">>, S, _) -> bouy_ref_iterator:list_iterator(<<"Set Entries">>, [bouy_heap:new_array([K, K]) || K <- set_members(S)]).
