%% The keyed collections Map and Set, and the Map and Set iterators. WeakMap
%% and WeakSet are in bouy_ref_weak.
%%
%% The slots of a Map or a Set are {Index, Order}. Index maps each key to
%% {Seq, Value} for a Map and to Seq for a Set: Seq is the position of the
%% entry in insertion order, and each new entry gets the next one. Order is
%% {Next, Tree}, where the gb_tree maps each live Seq to its key. An
%% iterator, forEach, and the Set methods remember the last Seq they
%% visited and ask the tree for the next one, so they see the entries that
%% a callback adds and skip the ones it deletes, as the specification's
%% list of entries with empty slots does. The structured clone and the
%% console read only Index.
-module(bouy_ref_collection).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, collection_size/1, remaining/1, step/1]).

-import(bouy_ref_realm, [arg/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

-define(NAMES, [<<"Map">>, <<"Set">>]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    MapMethods = ?METHODS(<<"Map.prototype">>, [{<<"clear">>, 0}, {<<"delete">>, 1}, {<<"entries">>, 0}, {<<"forEach">>, 1}, {<<"get">>, 1},
                                                {<<"getOrInsert">>, 2}, {<<"getOrInsertComputed">>, 2}, {<<"has">>, 1}, {<<"keys">>, 0},
                                                {<<"set">>, 2}, {<<"values">>, 0}]),
    SetMethods = ?METHODS(<<"Set.prototype">>, [{<<"add">>, 1}, {<<"clear">>, 0}, {<<"delete">>, 1}, {<<"difference">>, 1}, {<<"entries">>, 0},
                                                {<<"forEach">>, 1}, {<<"has">>, 1}, {<<"intersection">>, 1}, {<<"isDisjointFrom">>, 1},
                                                {<<"isSubsetOf">>, 1}, {<<"isSupersetOf">>, 1}, {<<"symmetricDifference">>, 1},
                                                {<<"union">>, 1}, {<<"values">>, 0}]),
    {_, Entries} = lists:keyfind(<<"entries">>, 1, MapMethods),
    {_, Values} = lists:keyfind(<<"values">>, 1, SetMethods),
    [{'Map.prototype', record(object, ?OBJECT_PROTO, MapMethods
         ++ [{<<"size">>, size_getter(<<"Map">>), 4}, {<<"constructor">>, constructor(<<"Map">>)}, {?SYM(toStringTag), <<"Map">>, 4},
             {?SYM(iterator), Entries}], none)},
     {'Set.prototype', record(object, ?OBJECT_PROTO, SetMethods
         ++ [{<<"keys">>, Values}, {<<"size">>, size_getter(<<"Set">>), 4}, {<<"constructor">>, constructor(<<"Set">>)},
             {?SYM(toStringTag), <<"Set">>, 4}, {?SYM(iterator), Values}], none)},
     {'MapIterator.prototype', record(object, ?ITERATOR_PROTO, ?METHODS(<<"MapIterator.prototype">>, [{<<"next">>, 0}]) ++ [{?SYM(toStringTag), <<"Map Iterator">>, 4}], none)},
     {'SetIterator.prototype', record(object, ?ITERATOR_PROTO, ?METHODS(<<"SetIterator.prototype">>, [{<<"next">>, 0}]) ++ [{?SYM(toStringTag), <<"Set Iterator">>, 4}], none)},
     {{builtin, <<"Map">>}, ctor_record(<<"Map">>, 0, {'$o', 'Map.prototype'}, ?METHODS(<<"Map">>, [{<<"groupBy">>, 2}]) ++ [{?SYM(species), species_getter(<<"Map">>), 4}], fun(NT, Args) -> construct(map, NT, Args) end)},
     {{builtin, <<"Set">>}, ctor_record(<<"Set">>, 0, {'$o', 'Set.prototype'}, [{?SYM(species), species_getter(<<"Set">>), 4}], fun(NT, Args) -> construct(set, NT, Args) end)}].

size_getter(Name) ->
    {'$accessor', bouy_ref_realm:builtin(<<"get ", Name/binary, ".prototype.size">>, <<"get size">>, 0,
                                          fun(This, _) -> ?MODULE:method(<<Name/binary, ".prototype">>, <<"size">>, This, []) end), undefined}.

species_getter(Name) ->
    {'$accessor', bouy_ref_realm:builtin(<<"get ", Name/binary, "[Symbol.species]">>, <<"get [Symbol.species]">>, 0, fun(This, _) -> This end), undefined}.

-spec globals() -> [{binary(), term()}].
globals() -> [{N, constructor(N)} || N <- ?NAMES].

constructor(Name) -> bouy_ref_realm:constructor(?MODULE, Name).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(Name, _This, _Args) -> type_error(<<"Constructor ", Name/binary, " requires 'new'">>).

-spec collection_size(term()) -> non_neg_integer().
collection_size(O) ->
    {Index, _} = bouy_heap:slots(O),
    map_size(Index).

%%% Construction

construct(Class, NewTarget, Args) ->
    Default = case Class of
        map -> 'Map.prototype';
        set -> 'Set.prototype'
    end,
    C = bouy_heap:new_exotic(Class, bouy_ref_realm:proto_for(NewTarget, Default), empty()),
    case arg(1, Args) of
        V when V =:= undefined; V =:= null -> C;
        Iterable ->
            AdderName = case Class of
                map -> <<"set">>;
                set -> <<"add">>
            end,
            Adder = bouy_ref:get(C, AdderName),
            bouy_heap:is_callable(Adder) orelse type_error(<<"'", AdderName/binary, "' is not a function">>),
            Intrinsic = case {Class, Adder} of
                {map, {'$f', {builtin, <<"Map.prototype.set">>}, _}} -> true;
                {set, {'$f', {builtin, <<"Set.prototype.add">>}, _}} -> true;
                _ -> false
            end,
            case Intrinsic of
                %% The intrinsic adder runs no user code and nothing can reach the
                %% new collection yet, so its entries go in at once.
                true -> fill(Class, C, Iterable);
                false -> add_all(Class, C, Adder, Iterable)
            end,
            C
    end.

%% Fills a new Map or Set from an iterable in one write: a repeated key
%% keeps its first position and, in a Map, its last value.
fill(Class, C, Iterable) ->
    Entries = collect(Class, bouy_ref_iterator:iterate(Iterable), []),
    {Index, Order, Next} = lists:foldl(fun({K, V}, {Index0, Order0, Next0}) ->
                                               case Index0 of
                                                   #{K := {Seq, _}} -> {Index0#{K := {Seq, V}}, Order0, Next0};
                                                   #{K := _} -> {Index0, Order0, Next0};
                                                   _ ->
                                                       Entry = case Class of
                                                           map -> {Next0, V};
                                                           set -> Next0
                                                       end,
                                                       {Index0#{K => Entry}, [{Next0, K} | Order0], Next0 + 1}
                                               end
                                       end, {#{}, [], 0}, Entries),
    bouy_heap:set_slots(C, {Index, {Next, gb_trees:from_orddict(lists:reverse(Order))}}).

collect(Class, State, Acc) ->
    case bouy_ref_iterator:step(State) of
        done -> lists:reverse(Acc);
        {value, V, State1} ->
            Entry = closing(State1, fun() ->
                                            case Class of
                                                set -> {key(V), V};
                                                map ->
                                                    ?IS_OBJECT(V) orelse type_error(bouy_ref_string:concat([<<"Iterator value ">>, bouy_ref:describe(V), <<" is not an entry object">>])),
                                                    K = bouy_ref:get(V, 0),
                                                    {key(K), bouy_ref:get(V, 1)}
                                            end
                                    end),
            collect(Class, State1, [Entry | Acc])
    end.

empty() -> {#{}, {0, gb_trees:empty()}}.

add_all(map, C, Adder, Iterable) ->
    each_value(Iterable, fun(Entry) ->
                                 ?IS_OBJECT(Entry) orelse type_error(bouy_ref_string:concat([<<"Iterator value ">>, bouy_ref:describe(Entry), <<" is not an entry object">>])),
                                 K = bouy_ref:get(Entry, 0),
                                 V = bouy_ref:get(Entry, 1),
                                 bouy_ref:call(Adder, C, [K, V])
                         end);
add_all(_Class, C, Adder, Iterable) ->
    each_value(Iterable, fun(V) -> bouy_ref:call(Adder, C, [V]) end).

%% Calls F with each value of the iterable; when F throws, the iterator
%% closes and the error goes on.
each_value(Iterable, F) ->
    State = bouy_ref_iterator:iterate(Iterable),
    each_step(State, F).

each_step(State, F) ->
    case bouy_ref_iterator:step(State) of
        done -> ok;
        {value, V, State1} ->
            closing(State1, fun() -> F(V) end),
            each_step(State1, F)
    end.

closing(State, Step) ->
    try Step()
    catch
        error:{'$throw', _} = Reason:Stack ->
            close(State),
            erlang:raise(error, Reason, Stack)
    end.

close({protocol, Iterator, _}) ->
    try
        case bouy_ref:get(Iterator, <<"return">>) of
            R when R =:= undefined; R =:= null -> ok;
            Return -> bouy_ref:call(Return, Iterator, [])
        end
    catch
        error:{'$throw', _} -> ok
    end;
close(_) -> ok.

%%% The entries

%% SameValueZero keys: -0 is 0, and canonical numbers compare as terms.
key(F) when is_float(F), F == 0 -> 0;
key(K) -> K.

%% The slots, with the order tree built for a collection that a structured
%% clone made.
slots(C) ->
    case bouy_heap:slots(C) of
        {Index, {_, _} = Order} -> {Index, Order};
        {Index, _} -> {Index, rebuild(Index)}
    end.

rebuild(Index) ->
    Pairs = lists:sort([{seq_of(E), K} || K := E <- Index]),
    Next = case Pairs of
        [] -> 0;
        _ -> element(1, lists:last(Pairs)) + 1
    end,
    {Next, gb_trees:from_orddict(Pairs)}.

seq_of({Seq, _}) -> Seq;
seq_of(Seq) -> Seq.

%% The entry after the position Seq: {Seq1, Key}, or none.
next_after(C, Seq) ->
    {_, {_, Tree}} = slots(C),
    case gb_trees:next(gb_trees:iterator_from(Seq + 1, Tree)) of
        {Seq1, K, _} -> {Seq1, K};
        none -> none
    end.

put_entry(C, K, Entry) ->
    {Index, {Next, Tree}} = slots(C),
    case Index of
        #{K := Old} -> bouy_heap:set_slots(C, {Index#{K := replace(Old, Entry)}, {Next, Tree}});
        _ -> bouy_heap:set_slots(C, {Index#{K => entry(Next, Entry)}, {Next + 1, gb_trees:insert(Next, K, Tree)}})
    end.

replace({Seq, _}, {value, V}) -> {Seq, V};
replace(Seq, member) -> Seq.

entry(Seq, {value, V}) -> {Seq, V};
entry(Seq, member) -> Seq.

remove_entry(C, K) ->
    {Index, {Next, Tree}} = slots(C),
    case Index of
        #{K := E} ->
            bouy_heap:set_slots(C, {maps:remove(K, Index), {Next, gb_trees:delete(seq_of(E), Tree)}}),
            true;
        _ -> false
    end.

clear(C) ->
    {_, {Next, _}} = slots(C),
    bouy_heap:set_slots(C, {#{}, {Next, gb_trees:empty()}}).

has_key(C, K) ->
    {Index, _} = slots(C),
    is_map_key(K, Index).

lookup(C, K) ->
    {Index, _} = slots(C),
    case Index of
        #{K := {_, V}} -> {ok, V};
        _ -> error
    end.

%% Calls F with each live key in order, seeing the changes F makes.
each_key(C, F) -> each_key(C, F, -1).

each_key(C, F, Seq) ->
    case next_after(C, Seq) of
        none -> ok;
        {Seq1, K} ->
            F(K),
            each_key(C, F, Seq1)
    end.

%% Like each_key, but stops with Result when F returns {stop, Result}.
find_key(C, F, Seq, Default) ->
    case next_after(C, Seq) of
        none -> Default;
        {Seq1, K} ->
            case F(K) of
                {stop, Result} -> Result;
                continue -> find_key(C, F, Seq1, Default)
            end
    end.

keys(C) ->
    {_, {_, Tree}} = slots(C),
    gb_trees:values(Tree).

%%% Methods

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Map.prototype">>, Name, This, Args) -> map_proto(Name, this(This, map, Name), Args);
method(<<"Set.prototype">>, Name, This, Args) -> set_proto(Name, this(This, set, Name), Args);
method(<<"MapIterator.prototype">>, <<"next">>, This, _) -> iterator_next(This, map_iterator);
method(<<"SetIterator.prototype">>, <<"next">>, This, _) -> iterator_next(This, set_iterator);
method(<<"Map">>, <<"groupBy">>, _This, Args) -> group_by(arg(1, Args), arg(2, Args)).

%% RequireInternalSlot for the class Class.
this({'$o', _} = O, Class, Name) ->
    case bouy_heap:class_of(O) of
        Class -> O;
        _ -> incompatible(Class, Name)
    end;
this(_, Class, Name) -> incompatible(Class, Name).

-spec incompatible(atom(), binary()) -> no_return().
incompatible(Class, Name) ->
    Owner = case Class of
        map -> <<"Map">>;
        set -> <<"Set">>
    end,
    type_error(<<"Method ", Owner/binary, ".prototype.", Name/binary, " called on incompatible receiver">>).

map_proto(<<"size">>, M, _) -> collection_size(M);
map_proto(<<"get">>, M, Args) ->
    case lookup(M, key(arg(1, Args))) of
        {ok, V} -> V;
        error -> undefined
    end;
map_proto(<<"set">>, M, Args) ->
    put_entry(M, key(arg(1, Args)), {value, arg(2, Args)}),
    M;
map_proto(<<"has">>, M, Args) -> has_key(M, key(arg(1, Args)));
map_proto(<<"delete">>, M, Args) -> remove_entry(M, key(arg(1, Args)));
map_proto(<<"clear">>, M, _) ->
    clear(M),
    undefined;
map_proto(<<"getOrInsert">>, M, Args) -> get_or_insert(M, key(arg(1, Args)), arg(2, Args));
map_proto(<<"getOrInsertComputed">>, M, Args) -> get_or_insert_computed(M, arg(1, Args), arg(2, Args));
map_proto(<<"forEach">>, M, Args) ->
    F = callable(arg(1, Args)),
    This = arg(2, Args),
    each_key(M, fun(K) ->
                        case lookup(M, K) of
                            {ok, V} -> bouy_ref:call(F, This, [V, K, M]);
                            error -> ok
                        end
                end),
    undefined;
map_proto(<<"keys">>, M, _) -> iterator(map_iterator, M, keys);
map_proto(<<"values">>, M, _) -> iterator(map_iterator, M, values);
map_proto(<<"entries">>, M, _) -> iterator(map_iterator, M, entries).

get_or_insert(M, K, V) ->
    case lookup(M, K) of
        {ok, Existing} -> Existing;
        error ->
            put_entry(M, K, {value, V}),
            V
    end.

get_or_insert_computed(M, Key, F) ->
    callable(F),
    K = key(Key),
    case lookup(M, K) of
        {ok, Existing} -> Existing;
        error ->
            V = bouy_ref:call(F, undefined, [K]),
            put_entry(M, K, {value, V}),
            V
    end.

set_proto(<<"size">>, S, _) -> collection_size(S);
set_proto(<<"add">>, S, Args) ->
    put_entry(S, key(arg(1, Args)), member),
    S;
set_proto(<<"has">>, S, Args) -> has_key(S, key(arg(1, Args)));
set_proto(<<"delete">>, S, Args) -> remove_entry(S, key(arg(1, Args)));
set_proto(<<"clear">>, S, _) ->
    clear(S),
    undefined;
set_proto(<<"forEach">>, S, Args) ->
    F = callable(arg(1, Args)),
    This = arg(2, Args),
    each_key(S, fun(K) -> bouy_ref:call(F, This, [K, K, S]) end),
    undefined;
set_proto(<<"values">>, S, _) -> iterator(set_iterator, S, values);
set_proto(<<"keys">>, S, _) -> iterator(set_iterator, S, values);
set_proto(<<"entries">>, S, _) -> iterator(set_iterator, S, entries);
set_proto(<<"union">>, S, Args) ->
    Other = set_record(arg(1, Args)),
    Result = copy(S),
    other_keys(Other, fun(K) -> put_entry(Result, K, member), continue end),
    Result;
set_proto(<<"intersection">>, S, Args) ->
    Other = set_record(arg(1, Args)),
    Result = new_set(),
    case collection_size(S) =< size_of(Other) of
        true ->
            find_key(S, fun(K) ->
                                case in_other(Other, K) of
                                    true -> put_entry(Result, K, member);
                                    false -> ok
                                end,
                                continue
                        end, -1, ok);
        false ->
            other_keys(Other, fun(K) ->
                                      case has_key(S, K) of
                                          true -> put_entry(Result, K, member);
                                          false -> ok
                                      end,
                                      continue
                              end)
    end,
    Result;
set_proto(<<"difference">>, S, Args) ->
    Other = set_record(arg(1, Args)),
    Result = copy(S),
    case collection_size(S) =< size_of(Other) of
        true ->
            [case in_other(Other, K) of
                 true -> remove_entry(Result, K);
                 false -> ok
             end || K <- keys(S)];
        false ->
            other_keys(Other, fun(K) -> remove_entry(Result, K), continue end)
    end,
    Result;
set_proto(<<"symmetricDifference">>, S, Args) ->
    Other = set_record(arg(1, Args)),
    Result = copy(S),
    other_keys(Other, fun(K) ->
                              case has_key(S, K) of
                                  true -> remove_entry(Result, K);
                                  false -> put_entry(Result, K, member)
                              end,
                              continue
                      end),
    Result;
set_proto(<<"isSubsetOf">>, S, Args) ->
    Other = set_record(arg(1, Args)),
    case collection_size(S) > size_of(Other) of
        true -> false;
        false ->
            find_key(S, fun(K) ->
                                case in_other(Other, K) of
                                    true -> continue;
                                    false -> {stop, false}
                                end
                        end, -1, true)
    end;
set_proto(<<"isSupersetOf">>, S, Args) ->
    Other = set_record(arg(1, Args)),
    case collection_size(S) < size_of(Other) of
        true -> false;
        false ->
            other_keys(Other, fun(K) ->
                                      case has_key(S, K) of
                                          true -> continue;
                                          false -> {stop, false}
                                      end
                              end, true)
    end;
set_proto(<<"isDisjointFrom">>, S, Args) ->
    Other = set_record(arg(1, Args)),
    case collection_size(S) =< size_of(Other) of
        true ->
            find_key(S, fun(K) ->
                                case in_other(Other, K) of
                                    true -> {stop, false};
                                    false -> continue
                                end
                        end, -1, true);
        false ->
            other_keys(Other, fun(K) ->
                                      case has_key(S, K) of
                                          true -> {stop, false};
                                          false -> continue
                                      end
                              end, true)
    end.

new_set() -> bouy_heap:new_exotic(set, {'$o', 'Set.prototype'}, empty()).

copy(S) -> bouy_heap:new_exotic(set, {'$o', 'Set.prototype'}, slots(S)).

%% GetSetRecord: {Object, Size, Has, Keys}.
set_record(V) ->
    ?IS_OBJECT(V) orelse type_error(bouy_ref_string:concat(bouy_ref:describe(V), <<" is not an object">>)),
    Size = case bouy_ref:to_number(bouy_ref:get(V, <<"size">>)) of
        'NaN' -> type_error(<<"The 'size' property must be a number">>);
        N -> bouy_ref_number:to_integer_or_infinity(N)
    end,
    case Size of
        '-Infinity' -> bouy_heap:throw_error('RangeError', <<"'size' must not be negative">>);
        I when is_integer(I), I < 0 -> bouy_heap:throw_error('RangeError', <<"'size' must not be negative">>);
        _ -> ok
    end,
    Has = bouy_ref:get(V, <<"has">>),
    bouy_heap:is_callable(Has) orelse type_error(<<"The 'has' property must be a function">>),
    Keys = bouy_ref:get(V, <<"keys">>),
    bouy_heap:is_callable(Keys) orelse type_error(<<"The 'keys' property must be a function">>),
    {V, Size, Has, Keys}.

size_of({_, 'Infinity', _, _}) -> infinity;
size_of({_, Size, _, _}) -> Size.

in_other({Object, _, Has, _}, K) -> bouy_ref:truthy(bouy_ref:call(Has, Object, [K])).

%% Calls F with each key of the keys iterator of the set record; F returns
%% continue, or {stop, Result} to close the iterator and return Result.
other_keys(Record, F) -> other_keys(Record, F, ok).

other_keys({Object, _, _, Keys}, F, Default) ->
    Iterator = bouy_ref:call(Keys, Object, []),
    ?IS_OBJECT(Iterator) orelse type_error(<<"The keys iterator must be an object">>),
    Next = bouy_ref:get(Iterator, <<"next">>),
    bouy_heap:is_callable(Next) orelse type_error(<<"The next method of the keys iterator must be a function">>),
    key_steps(Iterator, Next, F, Default).

key_steps(Iterator, Next, F, Default) ->
    Result = bouy_ref:call(Next, Iterator, []),
    ?IS_OBJECT(Result) orelse type_error(bouy_ref_string:concat([<<"Iterator result ">>, bouy_ref:describe(Result), <<" is not an object">>])),
    case bouy_ref:truthy(bouy_ref:get(Result, <<"done">>)) of
        true -> Default;
        false ->
            case F(key(bouy_ref:get(Result, <<"value">>))) of
                continue -> key_steps(Iterator, Next, F, Default);
                {stop, Value} ->
                    close({protocol, Iterator, Next}),
                    Value
            end
    end.

%%% Iterators

iterator(Class, C, Kind) ->
    Proto = case Class of
        map_iterator -> {'$o', 'MapIterator.prototype'};
        set_iterator -> {'$o', 'SetIterator.prototype'}
    end,
    bouy_heap:new_exotic(Class, Proto, {C, -1, Kind}).

%% The entries that a Map or Set iterator has yet to give, without moving
%% it, for the console: {Label, Items}, each item a value or a [K, V] list.
-spec remaining(term()) -> {binary(), list()}.
remaining(It) ->
    Class = bouy_heap:class_of(It),
    Kind = case bouy_heap:slots(It) of
        done -> values;
        {_, _, K} -> K;
        {_, _, K, _} -> K
    end,
    Items = case bouy_heap:slots(It) of
        done -> [];
        {C, Seq, _} -> collect_after(C, Seq, Class, Kind, []);
        {C, Seq, _, _} -> collect_after(C, Seq, Class, Kind, [])
    end,
    Label = case {Class, Kind} of
        {map_iterator, entries} -> <<"Map Entries">>;
        {map_iterator, _} -> <<"Map Iterator">>;
        {set_iterator, entries} -> <<"Set Entries">>;
        {set_iterator, _} -> <<"Set Iterator">>
    end,
    {Label, Items}.

collect_after(C, Seq, Class, Kind, Acc) ->
    case next_after(C, Seq) of
        none -> lists:reverse(Acc);
        {Seq1, K} ->
            Item = case {Class, Kind} of
                {_, keys} -> K;
                {set_iterator, values} -> K;
                {set_iterator, entries} -> [K, K];
                {map_iterator, values} -> element(2, lookup(C, K));
                {map_iterator, entries} -> [K, element(2, lookup(C, K))]
            end,
            collect_after(C, Seq1, Class, Kind, [Item | Acc])
    end.

iterator_next(It, Class) ->
    ?IS_OBJECT(It) andalso bouy_heap:class_of(It) =:= Class orelse
        type_error(<<"next method called on incompatible receiver">>),
    case step(It) of
        {value, V} -> bouy_ref_iterator:result(V, false);
        done -> bouy_ref_iterator:result(undefined, true)
    end.

%% The next value of a Map or Set iterator: {value, V}, or done.
-spec step(term()) -> {value, term()} | done.
%%
%% The iterator buffers the next entries of the order tree, and checks that
%% each is still live before it gives it: a deleted entry is gone from the
%% index, and a key set again after a delete has a new position, which a
%% later refill finds.
step(It) ->
    case bouy_heap:slots(It) of
        done -> done;
        {C, Seq, Kind} -> step(It, C, Seq, Kind, []);
        {C, Seq, Kind, Buffer} -> step(It, C, Seq, Kind, Buffer)
    end.

step(It, C, Seq, Kind, [{Seq1, K} | Rest]) ->
    {Index, _} = slots(C),
    case maps:find(K, Index) of
        {ok, Entry} when Entry =:= Seq1; element(1, Entry) =:= Seq1 ->
            bouy_heap:set_slots(It, {C, Seq1, Kind, Rest}),
            {value, case {bouy_heap:class_of(It), Kind} of
                        {_, keys} -> K;
                        {set_iterator, values} -> K;
                        {set_iterator, entries} -> bouy_heap:new_array([K, K]);
                        {map_iterator, values} -> element(2, Entry);
                        {map_iterator, entries} -> bouy_heap:new_array([K, element(2, Entry)])
                    end};
        _ -> step(It, C, Seq, Kind, Rest)
    end;
step(It, C, Seq, Kind, []) ->
    case entries_after(C, Seq, 64) of
        [] ->
            bouy_heap:set_slots(It, done),
            done;
        Buffer -> step(It, C, Seq, Kind, Buffer)
    end.

%% Up to Count entries {Seq, Key} after the position Seq, in order.
entries_after(C, Seq, Count) ->
    {_, {_, Tree}} = slots(C),
    take(gb_trees:iterator_from(Seq + 1, Tree), Count).

take(_Iter, 0) -> [];
take(Iter, Count) ->
    case gb_trees:next(Iter) of
        {Seq, K, Iter1} -> [{Seq, K} | take(Iter1, Count - 1)];
        none -> []
    end.

%%% Map.groupBy

group_by(Items, F) ->
    (Items =:= undefined orelse Items =:= null) andalso type_error(<<"Map.groupBy called on null or undefined">>),
    callable(F),
    M = bouy_heap:new_exotic(map, {'$o', 'Map.prototype'}, empty()),
    State = bouy_ref_iterator:iterate(Items),
    group_steps(State, F, M, 0),
    M.

group_steps(State, F, M, K) ->
    case bouy_ref_iterator:step(State) of
        done -> ok;
        {value, V, State1} ->
            Key = closing(State1, fun() -> key(bouy_ref:call(F, undefined, [V, K])) end),
            case lookup(M, Key) of
                {ok, Group} -> bouy_heap:array_push(Group, [V]);
                error -> put_entry(M, Key, {value, bouy_heap:new_array([V])})
            end,
            group_steps(State1, F, M, K + 1)
    end.
