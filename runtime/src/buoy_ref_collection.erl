%% The keyed collections Map and Set, and the Map and Set iterators. WeakMap
%% and WeakSet are in buoy_ref_weak.
%%
%% The slots of a Map or a Set are {Index, Order}. Index maps each key to
%% {Seq, Value} for a Map and to Seq for a Set: Seq is the position of the
%% entry in insertion order, and each new entry gets the next one. Order is
%% {Next, Count, Gen, Front, Back}, a log of {Seq, Key} in insertion order:
%% Front holds the older entries oldest first, Back the newer ones newest
%% first, so an insert is one cons. A delete leaves its entry in the log;
%% readers skip each entry whose key no longer has that Seq in Index, and
%% the log is rebuilt from the live entries when more than half of its
%% Count entries are dead. Gen counts the rebuilds of Front. This is the
%% ordered hash table of V8 and of JavaScriptCore: entries in insertion
%% order with deleted markers, compacted later. A Seq never changes, so an
%% iterator, forEach, and the Set methods remember the last Seq they passed
%% and see the entries that a callback adds and skip the ones it deletes,
%% as the specification's list of entries with empty slots does. The
%% structured clone and the console read only Index.
-module(buoy_ref_collection).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, collection_size/1, remaining/1, step/1]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5, callable/1]).
-import(buoy_ref, [type_error/1]).

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
    {'$accessor', buoy_ref_realm:builtin(<<"get ", Name/binary, ".prototype.size">>, <<"get size">>, 0,
                                          fun(This, _) -> ?MODULE:method(<<Name/binary, ".prototype">>, <<"size">>, This, []) end), undefined}.

species_getter(Name) ->
    {'$accessor', buoy_ref_realm:builtin(<<"get ", Name/binary, "[Symbol.species]">>, <<"get [Symbol.species]">>, 0, fun(This, _) -> This end), undefined}.

-spec globals() -> [{binary(), term()}].
globals() -> [{N, constructor(N)} || N <- ?NAMES].

constructor(Name) -> buoy_ref_realm:constructor(?MODULE, Name).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(Name, _This, _Args) -> type_error(<<"Constructor ", Name/binary, " requires 'new'">>).

-spec collection_size(term()) -> non_neg_integer().
collection_size(O) ->
    {Index, _} = buoy_heap:slots(O),
    map_size(Index).

%%% Construction

construct(Class, NewTarget, Args) ->
    Default = case Class of
        map -> 'Map.prototype';
        set -> 'Set.prototype'
    end,
    C = buoy_heap:new_exotic(Class, buoy_ref_realm:proto_for(NewTarget, Default), empty()),
    case arg(1, Args) of
        V when V =:= undefined; V =:= null -> C;
        Iterable ->
            AdderName = case Class of
                map -> <<"set">>;
                set -> <<"add">>
            end,
            Adder = buoy_ref:get(C, AdderName),
            buoy_heap:is_callable(Adder) orelse type_error(<<"'", AdderName/binary, "' is not a function">>),
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
    Entries = collect(Class, buoy_ref_iterator:iterate(Iterable), []),
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
    buoy_heap:set_slots(C, {Index, {Next, Next, 0, [], Order}}).

collect(Class, State, Acc) ->
    case buoy_ref_iterator:step(State) of
        done -> lists:reverse(Acc);
        {value, V, State1} ->
            Entry = closing(State1, fun() ->
                                            case Class of
                                                set -> {key(V), V};
                                                map ->
                                                    ?IS_OBJECT(V) orelse type_error(buoy_ref_string:concat([<<"Iterator value ">>, buoy_ref:describe(V), <<" is not an entry object">>])),
                                                    K = buoy_ref:get(V, 0),
                                                    {key(K), buoy_ref:get(V, 1)}
                                            end
                                    end),
            collect(Class, State1, [Entry | Acc])
    end.

empty() -> {#{}, {0, 0, 0, [], []}}.

add_all(map, C, Adder, Iterable) ->
    each_value(Iterable, fun(Entry) ->
                                 ?IS_OBJECT(Entry) orelse type_error(buoy_ref_string:concat([<<"Iterator value ">>, buoy_ref:describe(Entry), <<" is not an entry object">>])),
                                 K = buoy_ref:get(Entry, 0),
                                 V = buoy_ref:get(Entry, 1),
                                 buoy_ref:call(Adder, C, [K, V])
                         end);
add_all(_Class, C, Adder, Iterable) ->
    each_value(Iterable, fun(V) -> buoy_ref:call(Adder, C, [V]) end).

%% Calls F with each value of the iterable; when F throws, the iterator
%% closes and the error goes on.
each_value(Iterable, F) ->
    State = buoy_ref_iterator:iterate(Iterable),
    each_step(State, F).

each_step(State, F) ->
    case buoy_ref_iterator:step(State) of
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
        case buoy_ref:get(Iterator, <<"return">>) of
            R when R =:= undefined; R =:= null -> ok;
            Return -> buoy_ref:call(Return, Iterator, [])
        end
    catch
        error:{'$throw', _} -> ok
    end;
close(_) -> ok.

%%% The entries

%% SameValueZero keys: -0 is 0, and canonical numbers compare as terms.
key(F) when is_float(F), F == 0 -> 0;
key(K) -> K.

%% The slots, with the order built and stored for a collection that a
%% structured clone or the deserializer made with an index alone.
slots(C) ->
    case buoy_heap:slots(C) of
        {_, {_, _, _, _, _}} = Slots -> Slots;
        {Index, _} ->
            Slots = {Index, rebuild(Index)},
            buoy_heap:set_slots(C, Slots),
            Slots
    end.

index(C) -> element(1, buoy_heap:slots(C)).

rebuild(Index) ->
    Log = lists:sort([{seq_of(E), K} || K := E <- Index]),
    Next = case Log of
        [] -> 0;
        _ -> element(1, lists:last(Log)) + 1
    end,
    {Next, length(Log), 0, Log, []}.

seq_of({Seq, _}) -> Seq;
seq_of(Seq) -> Seq.

is_live(Index, Seq, K) ->
    case Index of
        #{K := Seq} -> true;
        #{K := {Seq, _}} -> true;
        _ -> false
    end.

put_entry(C, K, Entry) ->
    {Index, {Next, Count, Gen, Front, Back} = Order} = slots(C),
    case Index of
        #{K := Old} -> buoy_heap:set_slots(C, {Index#{K := replace(Old, Entry)}, Order});
        _ -> buoy_heap:set_slots(C, {Index#{K => entry(Next, Entry)}, {Next + 1, Count + 1, Gen, Front, [{Next, K} | Back]}})
    end.

replace({Seq, _}, {value, V}) -> {Seq, V};
replace(Seq, member) -> Seq.

entry(Seq, {value, V}) -> {Seq, V};
entry(Seq, member) -> Seq.

remove_entry(C, K) ->
    {Index, {Next, Count, Gen, Front, Back}} = slots(C),
    case Index of
        #{K := _} ->
            Index1 = maps:remove(K, Index),
            {Front1, Dropped} = drop_dead(Index1, Front, 0),
            buoy_heap:set_slots(C, {Index1, compact(Index1, {Next, Count - Dropped, Gen, Front1, Back})}),
            true;
        _ -> false
    end.

%% Drops the dead entries at the head of a Front, so that a new cursor
%% starts at a live entry: a queue that deletes its oldest key stays O(1).
drop_dead(Index, [{Seq, K} | Rest] = Front, N) ->
    case is_live(Index, Seq, K) of
        true -> {Front, N};
        false -> drop_dead(Index, Rest, N + 1)
    end;
drop_dead(_, [], N) -> {[], N}.

%% Rebuilds the log from the live entries once more than half of it is dead.
compact(Index, {Next, Count, Gen, Front, Back}) when Count > 2 * map_size(Index) + 16 ->
    Live = [E || {Seq, K} = E <- Front ++ lists:reverse(Back), is_live(Index, Seq, K)],
    {Next, map_size(Index), Gen + 1, Live, []};
compact(_, Order) -> Order.

clear(C) ->
    {_, {Next, _, Gen, _, _}} = slots(C),
    buoy_heap:set_slots(C, {#{}, {Next, 0, Gen + 1, [], []}}).

has_key(C, K) -> is_map_key(K, index(C)).

lookup(C, K) ->
    case index(C) of
        #{K := {_, V}} -> {ok, V};
        _ -> error
    end.

%% A cursor walks the live entries in order and sees the changes made
%% meanwhile: {Last, Buffer, Gen}. Last is the Seq of the last entry that it
%% took from a buffer, and Buffer holds the entries that it has yet to check.
%% Gen is the generation of the Front whose rest it took last, so once it
%% has passed that Front, it reads only the new entries of Back.
cursor() -> {-1, [], none}.

%% The next live entry and the cursor after it: {Key, Entry, Cursor}, or none.
next_entry(C, {Last, Buffer, Gen}) ->
    next_entry(C, index(C), Last, Buffer, Gen).

next_entry(C, Index, _Last, [{Seq, K} | Rest], Gen) ->
    case Index of
        #{K := Seq} -> {K, Seq, {Seq, Rest, Gen}};
        #{K := {Seq, _} = E} -> {K, E, {Seq, Rest, Gen}};
        _ -> next_entry(C, Index, Seq, Rest, Gen)
    end;
next_entry(C, Index, Last, [], Gen) ->
    case refill(C, Last, Gen) of
        {Buffer, Gen1} -> next_entry(C, Index, Last, Buffer, Gen1);
        none -> none
    end.

%% The entries after Last that a cursor has not seen: {Buffer, Gen}, or none.
%% A Front made of the whole Back is stored, so later cursors start at once.
refill(C, Last, Seen) ->
    {Index, {Next, Count, Gen, Front, Back}} = slots(C),
    case {Seen, Front, Back} of
        {Gen, _, _} -> after_in_back(Last, Back, Gen);
        {_, [], [_ | _]} ->
            {Front1, Dropped} = drop_dead(Index, lists:reverse(Back), 0),
            buoy_heap:set_slots(C, {Index, {Next, Count - Dropped, Gen + 1, Front1, []}}),
            refill(C, Last, Seen);
        _ ->
            case drop_through(Last, Front) of
                [] -> after_in_back(Last, Back, Gen);
                Rest -> {Rest, Gen}
            end
    end.

drop_through(Last, [{Seq, _} | Rest]) when Seq =< Last -> drop_through(Last, Rest);
drop_through(_, Front) -> Front.

after_in_back(Last, Back, Gen) ->
    case take_after(Last, Back, []) of
        [] -> none;
        Buffer -> {Buffer, Gen}
    end.

take_after(Last, [{Seq, _} = E | Rest], Acc) when Seq > Last -> take_after(Last, Rest, [E | Acc]);
take_after(_, _, Acc) -> Acc.

%% Calls F with each live key and its entry in order, seeing the changes F makes.
each_key(C, F) -> each_key(C, F, cursor()).

each_key(C, F, Cursor) ->
    case next_entry(C, Cursor) of
        none -> ok;
        {K, E, Cursor1} ->
            F(K, E),
            each_key(C, F, Cursor1)
    end.

%% Like each_key with F(K), but stops with Result when F returns {stop, Result}.
find_key(C, F, Default) -> find_key(C, F, cursor(), Default).

find_key(C, F, Cursor, Default) ->
    case next_entry(C, Cursor) of
        none -> Default;
        {K, _, Cursor1} ->
            case F(K) of
                {stop, Result} -> Result;
                continue -> find_key(C, F, Cursor1, Default)
            end
    end.

keys(C) ->
    {Index, {_, _, _, Front, Back}} = slots(C),
    [K || {Seq, K} <- Front ++ lists:reverse(Back), is_live(Index, Seq, K)].

%%% Methods

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Map.prototype">>, Name, This, Args) -> map_proto(Name, this(This, map, Name), Args);
method(<<"Set.prototype">>, Name, This, Args) -> set_proto(Name, this(This, set, Name), Args);
method(<<"MapIterator.prototype">>, <<"next">>, This, _) -> iterator_next(This, map_iterator);
method(<<"SetIterator.prototype">>, <<"next">>, This, _) -> iterator_next(This, set_iterator);
method(<<"Map">>, <<"groupBy">>, _This, Args) -> group_by(arg(1, Args), arg(2, Args)).

%% RequireInternalSlot for the class Class.
this({'$o', _} = O, Class, Name) ->
    case buoy_heap:class_of(O) of
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
    each_key(M, fun(K, {_, V}) -> buoy_ref:call(F, This, [V, K, M]) end),
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
            V = buoy_ref:call(F, undefined, [K]),
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
    each_key(S, fun(K, _) -> buoy_ref:call(F, This, [K, K, S]) end),
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
                        end, ok);
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
                        end, true)
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
                        end, true);
        false ->
            other_keys(Other, fun(K) ->
                                      case has_key(S, K) of
                                          true -> {stop, false};
                                          false -> continue
                                      end
                              end, true)
    end.

new_set() -> buoy_heap:new_exotic(set, {'$o', 'Set.prototype'}, empty()).

copy(S) -> buoy_heap:new_exotic(set, {'$o', 'Set.prototype'}, slots(S)).

%% GetSetRecord: {Object, Size, Has, Keys}.
set_record(V) ->
    ?IS_OBJECT(V) orelse type_error(buoy_ref_string:concat(buoy_ref:describe(V), <<" is not an object">>)),
    Size = case buoy_ref:to_number(buoy_ref:get(V, <<"size">>)) of
        'NaN' -> type_error(<<"The 'size' property must be a number">>);
        N -> buoy_ref_number:to_integer_or_infinity(N)
    end,
    case Size of
        '-Infinity' -> buoy_heap:throw_error('RangeError', <<"'size' must not be negative">>);
        I when is_integer(I), I < 0 -> buoy_heap:throw_error('RangeError', <<"'size' must not be negative">>);
        _ -> ok
    end,
    Has = buoy_ref:get(V, <<"has">>),
    buoy_heap:is_callable(Has) orelse type_error(<<"The 'has' property must be a function">>),
    Keys = buoy_ref:get(V, <<"keys">>),
    buoy_heap:is_callable(Keys) orelse type_error(<<"The 'keys' property must be a function">>),
    {V, Size, Has, Keys}.

size_of({_, 'Infinity', _, _}) -> infinity;
size_of({_, Size, _, _}) -> Size.

in_other({Object, _, Has, _}, K) -> buoy_ref:truthy(buoy_ref:call(Has, Object, [K])).

%% Calls F with each key of the keys iterator of the set record; F returns
%% continue, or {stop, Result} to close the iterator and return Result.
other_keys(Record, F) -> other_keys(Record, F, ok).

other_keys({Object, _, _, Keys}, F, Default) ->
    Iterator = buoy_ref:call(Keys, Object, []),
    ?IS_OBJECT(Iterator) orelse type_error(<<"The keys iterator must be an object">>),
    Next = buoy_ref:get(Iterator, <<"next">>),
    buoy_heap:is_callable(Next) orelse type_error(<<"The next method of the keys iterator must be a function">>),
    key_steps(Iterator, Next, F, Default).

key_steps(Iterator, Next, F, Default) ->
    Result = buoy_ref:call(Next, Iterator, []),
    ?IS_OBJECT(Result) orelse type_error(buoy_ref_string:concat([<<"Iterator result ">>, buoy_ref:describe(Result), <<" is not an object">>])),
    case buoy_ref:truthy(buoy_ref:get(Result, <<"done">>)) of
        true -> Default;
        false ->
            case F(key(buoy_ref:get(Result, <<"value">>))) of
                continue -> key_steps(Iterator, Next, F, Default);
                {stop, Value} ->
                    close({protocol, Iterator, Next}),
                    Value
            end
    end.

%%% Iterators

%% The slots of an iterator are done, or {Collection, Kind, Cursor}.
iterator(Class, C, Kind) ->
    Proto = case Class of
        map_iterator -> {'$o', 'MapIterator.prototype'};
        set_iterator -> {'$o', 'SetIterator.prototype'}
    end,
    buoy_heap:new_exotic(Class, Proto, {C, Kind, cursor()}).

%% The entries that a Map or Set iterator has yet to give, without moving
%% it, for the console: {Label, Items}, each item a value or a [K, V] list.
-spec remaining(term()) -> {binary(), list()}.
remaining(It) ->
    Class = buoy_heap:class_of(It),
    {Kind, Items} = case buoy_heap:slots(It) of
        done -> {values, []};
        {C, K, Cursor} -> {K, collect_after(C, Cursor, Class, K, [])}
    end,
    Label = case {Class, Kind} of
        {map_iterator, entries} -> <<"Map Entries">>;
        {map_iterator, _} -> <<"Map Iterator">>;
        {set_iterator, entries} -> <<"Set Entries">>;
        {set_iterator, _} -> <<"Set Iterator">>
    end,
    {Label, Items}.

collect_after(C, Cursor, Class, Kind, Acc) ->
    case next_entry(C, Cursor) of
        none -> lists:reverse(Acc);
        {K, E, Cursor1} ->
            Item = case {Class, Kind, E} of
                {_, keys, _} -> K;
                {set_iterator, values, _} -> K;
                {set_iterator, entries, _} -> [K, K];
                {map_iterator, values, {_, V}} -> V;
                {map_iterator, entries, {_, V}} -> [K, V]
            end,
            collect_after(C, Cursor1, Class, Kind, [Item | Acc])
    end.

iterator_next(It, Class) ->
    ?IS_OBJECT(It) andalso buoy_heap:class_of(It) =:= Class orelse
        type_error(<<"next method called on incompatible receiver">>),
    case step(It) of
        {value, V} -> buoy_ref_iterator:result(V, false);
        done -> buoy_ref_iterator:result(undefined, true)
    end.

%% The next value of a Map or Set iterator: {value, V}, or done.
-spec step(term()) -> {value, term()} | done.
step(It) ->
    case buoy_heap:slots(It) of
        done -> done;
        {C, Kind, Cursor} ->
            case next_entry(C, Cursor) of
                {K, E, Cursor1} ->
                    buoy_heap:set_slots(It, {C, Kind, Cursor1}),
                    {value, item(buoy_heap:class_of(It), Kind, K, E)};
                none ->
                    buoy_heap:set_slots(It, done),
                    done
            end
    end.

item(_, keys, K, _) -> K;
item(set_iterator, values, K, _) -> K;
item(set_iterator, entries, K, _) -> buoy_heap:new_array([K, K]);
item(map_iterator, values, _, {_, V}) -> V;
item(map_iterator, entries, K, {_, V}) -> buoy_heap:new_array([K, V]).

%%% Map.groupBy

group_by(Items, F) ->
    (Items =:= undefined orelse Items =:= null) andalso type_error(<<"Map.groupBy called on null or undefined">>),
    callable(F),
    M = buoy_heap:new_exotic(map, {'$o', 'Map.prototype'}, empty()),
    State = buoy_ref_iterator:iterate(Items),
    group_steps(State, F, M, 0),
    M.

group_steps(State, F, M, K) ->
    case buoy_ref_iterator:step(State) of
        done -> ok;
        {value, V, State1} ->
            Key = closing(State1, fun() -> key(buoy_ref:call(F, undefined, [V, K])) end),
            case lookup(M, Key) of
                {ok, Group} -> buoy_heap:array_push(Group, [V]);
                error -> put_entry(M, Key, {value, buoy_heap:new_array([V])})
            end,
            group_steps(State1, F, M, K + 1)
    end.
