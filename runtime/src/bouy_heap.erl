%% The JavaScript heap of one realm (spike: reference semantics).
%%
%% A realm is one BEAM process. Its objects live in the process dictionary of
%% that process, so they are mutable and have identity, and no other process
%% can reach them. Values:
%%
%%   {'$o', Id}           an object. Id is a positive integer, or an atom for
%%                        an intrinsic such as 'Object.prototype'.
%%   {'$f', Id, Fun}      a function. Fun is fun((This, Args) -> Result). A
%%                        function gets a record only when it needs one, so
%%                        an arrow function costs one id and no record.
%%   {'$sym', Tag, Desc}  a symbol. Tag is an integer for Symbol(), the atom
%%                        registered for Symbol.for(), or an atom such as
%%                        iterator for a well-known symbol.
%%   {'$c', Id}           a heap cell for a captured mutable variable. It is
%%                        never a JavaScript value; it appears in fun envs.
%%
%% The record of an object, under the key Id:
%%
%%   {Class, Proto, Props, Keys, Attrs, Slots}
%%
%% Class is object, array, function, error, map, set, promise, generator, or
%% date. Proto is null or an object or function value. Props maps a key to a
%% value or to {'$accessor', Get, Set}. A key is an integer for an array index
%% (0 =< K < 2^32 - 1), a binary for another string, a symbol, or a
%% {'#', ClassId, Name} tuple for a private name. Keys holds the string and
%% symbol keys, newest first, for insertion order. Attrs maps a key to its
%% attribute bits when they are not all set, and holds '$frozen' or '$noext'.
%% Slots holds the internal slots of the class: {Length, Elements} for an
%% array, where Elements maps each index to its value and a missing index is
%% a hole.
%%
%% The heap collects garbage with gc/1, a mark and sweep that the owner runs
%% when its stack is empty, between jobs. Every pdict entry whose key is not
%% an integer is a root, and so is each term that the caller passes.
-module(bouy_heap).

-export([new_object/1, object/2, literal/3, new_array/1, new_array/2, array_items/1, array_length/1]).
-export([array_push/2, array_set_items/2]).
-export([function/1, function/4, call/3, construct/3]).
-export([get/2, set/3, has/2, has_own/2, delete/2, own_keys/1, enumerable_keys/1]).
-export([define/3, get_own/2, prototype_of/1, set_prototype_of/2, freeze/1, is_frozen/1]).
-export([class_of/1, slots/1, set_slots/2, new_exotic/3, is_object/1, is_callable/1]).
-export([cell/1, cell_get/1, cell_set/2]).
-export([symbol/1, symbol_for/1, well_known/1]).
-export([to_key/1, key_to_value/1]).
-export([install_intrinsic/2, intrinsic/1, throw_error/2, error_object/3]).
-export([gc/1, gc_stats/0, heap_size/0, allocated/0]).
-export([clone_out/1, clone_in/1]).

-export_type([value/0, key/0]).

-type value() :: term().
-type key() :: non_neg_integer() | binary() | {'$sym', term(), term()} | {'#', term(), binary()}.

-define(NEXT, '$bouy_next').
-define(STATS, '$bouy_gc').
-define(WORDS_PER_ID, 16).
-define(MIN_HEAP_WORDS, 4096).
-define(WRITABLE, 1).
-define(ENUMERABLE, 2).
-define(CONFIGURABLE, 4).
-define(ALL, 7).
-define(MAX_INDEX, 4294967294).
-define(EMPTY, {object, null, #{}, [], #{}, none}).
-define(OBJECT_PROTO, {'$o', 'Object.prototype'}).
-define(ARRAY_PROTO, {'$o', 'Array.prototype'}).
-define(FUNCTION_PROTO, {'$o', 'Function.prototype'}).
-define(is_obj(V), (is_tuple(V) andalso (element(1, V) =:= '$o' orelse element(1, V) =:= '$f'))).

%%% Allocation

next_id() ->
    case erlang:get(?NEXT) of
        undefined ->
            erlang:put(?NEXT, 2),
            1;
        Id when Id band 4095 =:= 0 ->
            grow(Id),
            erlang:put(?NEXT, Id + 1),
            Id;
        Id ->
            erlang:put(?NEXT, Id + 1),
            Id
    end.

%% Every pdict entry is a GC root that each minor collection of the process scans, so a
%% realm with a large heap must not collect its young generation often. Every 4096 ids,
%% the realm sizes its minimum process heap to ?WORDS_PER_ID words for each entry it may
%% hold: the live count at the last collection plus the ids handed out since. The size
%% moves in powers of two, and a collection shrinks it again (size_heap/1).
grow(Id) ->
    #{at := At, live := Live} = gc_stats(),
    size_heap(Live + Id - At).

size_heap(Entries) ->
    Words = max(?MIN_HEAP_WORDS, Entries * ?WORDS_PER_ID),
    Size = 1 bsl bit_length(Words, 0),
    case erlang:process_info(self(), min_heap_size) of
        {min_heap_size, Size} -> ok;
        _ -> _ = erlang:process_flag(min_heap_size, Size), ok
    end.

bit_length(0, N) -> N;
bit_length(W, N) -> bit_length(W bsr 1, N + 1).

%% How many ids the realm has handed out. The jobs loop compares it with the
%% count at the last collection to decide when to collect.
-spec allocated() -> non_neg_integer().
allocated() ->
    case erlang:get(?NEXT) of
        undefined -> 0;
        Next -> Next - 1
    end.

-spec new_object(value()) -> value().
new_object(Proto) ->
    Id = next_id(),
    erlang:put(Id, {object, Proto, #{}, [], #{}, none}),
    {'$o', Id}.

%% An object from {Key, Value} pairs in source order. A repeated key keeps its
%% first position and its last value, as in an object literal.
-spec object(value(), [{key(), value()}]) -> value().
object(Proto, Pairs) ->
    {Props, Keys} = lists:foldl(fun({K, V}, {Ps, Ks}) -> {Ps#{K => V}, add_key(K, Ps, Ks)} end, {#{}, []}, Pairs),
    Id = next_id(),
    erlang:put(Id, {object, Proto, Props, Keys, #{}, none}),
    {'$o', Id}.

%% An object literal whose keys the compiler knows: Props is the map and Keys
%% the string keys newest first.
-spec literal(value(), map(), [key()]) -> value().
literal(Proto, Props, Keys) ->
    Id = next_id(),
    erlang:put(Id, {object, Proto, Props, Keys, #{}, none}),
    {'$o', Id}.

-spec new_array([value()]) -> value().
new_array(Items) -> new_array(Items, ?ARRAY_PROTO).

-spec new_array([value()], value()) -> value().
new_array(Items, Proto) ->
    Elements = maps:from_list(lists:enumerate(0, Items)),
    Id = next_id(),
    erlang:put(Id, {array, Proto, #{}, [], #{}, {map_size(Elements), Elements}}),
    {'$o', Id}.

%% An object of another class, such as a Map, with its internal slots.
-spec new_exotic(atom(), value(), term()) -> value().
new_exotic(Class, Proto, Slots) ->
    Id = next_id(),
    erlang:put(Id, {Class, Proto, #{}, [], #{}, Slots}),
    {'$o', Id}.

%% The items of an array, holes as undefined.
-spec array_items(value()) -> [value()].
array_items({'$o', Id}) ->
    {array, _, _, _, _, {Length, Elements}} = erlang:get(Id),
    [maps:get(I, Elements, undefined) || I <- lists:seq(0, Length - 1)].

%% Array.prototype.push: one read and one write of the record for any count.
-spec array_push(value(), [value()]) -> non_neg_integer().
array_push({'$o', Id} = O, Items) ->
    case erlang:get(Id) of
        {array, P, Props, Keys, Attrs, {Length, Elements}} when map_size(Attrs) =:= 0 ->
            {Length1, Elements1} = lists:foldl(fun(V, {L, E}) -> {L + 1, E#{L => V}} end, {Length, Elements}, Items),
            erlang:put(Id, {array, P, Props, Keys, Attrs, {Length1, Elements1}}),
            Length1;
        _ ->
            lists:foreach(fun(V) -> set(O, array_length(O), V) end, Items),
            array_length(O)
    end.

%% Replaces every item, as sort, splice, and shift do.
-spec array_set_items(value(), [value()]) -> ok.
array_set_items({'$o', Id} = O, Items) ->
    {array, P, Props, Keys, Attrs, _} = record_of(O),
    map_size(Attrs) =:= 0 orelse read_only(0),
    Elements = maps:from_list(lists:enumerate(0, Items)),
    erlang:put(Id, {array, P, Props, Keys, Attrs, {length(Items), Elements}}),
    ok.

-spec array_length(value()) -> non_neg_integer().
array_length({'$o', Id}) ->
    {array, _, _, _, _, {Length, _}} = erlang:get(Id),
    Length.

%%% Functions

%% A function without a record: an arrow function or a method.
-spec function(fun((value(), list()) -> value())) -> value().
function(Fun) -> {'$f', next_id(), Fun}.

%% A function with a record: a name, a length, and internal slots, such as the
%% construct behaviour of a class.
-spec function(fun((value(), list()) -> value()), binary(), non_neg_integer(), map()) -> value().
function(Fun, Name, Length, Slots) ->
    Id = next_id(),
    Props = #{<<"length">> => Length, <<"name">> => Name},
    Attrs = #{<<"length">> => ?CONFIGURABLE, <<"name">> => ?CONFIGURABLE},
    erlang:put(Id, {function, ?FUNCTION_PROTO, Props, [<<"name">>, <<"length">>], Attrs, Slots}),
    {'$f', Id, Fun}.

-spec call(value(), value(), list()) -> value().
call({'$f', _, Fun}, This, Args) -> Fun(This, Args);
call(V, _This, _Args) -> throw_error('TypeError', <<(describe(V))/binary, " is not a function">>).

%% [[Construct]] for a function whose slots hold construct => fun((NewTarget, Args) -> Object).
-spec construct(value(), list(), value()) -> value().
construct({'$f', Id, Fun} = F, Args, NewTarget) ->
    case fn_record(Id) of
        {function, _, _, _, _, #{construct := Construct}} ->
            Construct(NewTarget, Args);
        {function, _, _, _, _, #{kind := normal}} ->
            This = new_object(prototype_for(NewTarget)),
            case Fun(This, Args) of
                Object when ?is_obj(Object) -> Object;
                _ -> This
            end;
        _ ->
            throw_error('TypeError', <<(describe(F))/binary, " is not a constructor">>)
    end;
construct(V, _Args, _NewTarget) ->
    throw_error('TypeError', <<(describe(V))/binary, " is not a constructor">>).

prototype_for(NewTarget) ->
    case get(NewTarget, <<"prototype">>) of
        Proto when ?is_obj(Proto) -> Proto;
        _ -> ?OBJECT_PROTO
    end.

%%% Properties

-spec get(value(), key()) -> value().
get({'$o', Id} = O, K) ->
    case erlang:get(Id) of
        {array, _, _, _, _, {_, Elements}} = R when is_integer(K) ->
            case Elements of
                #{K := V} -> V;
                _ -> inherited(element(2, R), K, O)
            end;
        {array, _, _, _, _, {Length, _}} when K =:= <<"length">> ->
            Length;
        {_, Proto, Props, _, _, _} ->
            case Props of
                #{K := V} -> resolve(V, O);
                _ -> inherited(Proto, K, O)
            end;
        undefined ->
            from_record(intrinsic_record(Id, O), K, O)
    end;
get({'$f', Id, _} = F, K) ->
    case erlang:get(Id) of
        {_, Proto, Props, _, _, _} ->
            case Props of
                #{K := V} -> resolve(V, F);
                _ -> inherited(Proto, K, F)
            end;
        undefined ->
            fn_default_get(Id, K, F)
    end.

fn_default_get(Id, K, F) ->
    case fn_record(Id) of
        {_, Proto, Props, _, _, _} ->
            case Props of
                #{K := V} -> resolve(V, F);
                _ -> inherited(Proto, K, F)
            end
    end.

from_record({array, _, _, _, _, {_, Elements}} = R, K, O) when is_integer(K) ->
    case Elements of
        #{K := V} -> V;
        _ -> inherited(element(2, R), K, O)
    end;
from_record({array, _, _, _, _, {Length, _}}, <<"length">>, _O) ->
    Length;
from_record({_, Proto, Props, _, _, _}, K, O) ->
    case Props of
        #{K := V} -> resolve(V, O);
        _ -> inherited(Proto, K, O)
    end.

inherited(null, _K, _Receiver) ->
    undefined;
inherited({'$o', Id} = O, K, Receiver) ->
    case erlang:get(Id) of
        undefined -> inherited_from(intrinsic_record(Id, O), K, Receiver);
        R -> inherited_from(R, K, Receiver)
    end;
inherited({'$f', Id, _}, K, Receiver) ->
    inherited_from(fn_record(Id), K, Receiver).

inherited_from({_, Proto, Props, _, _, _}, K, Receiver) ->
    case Props of
        #{K := V} -> resolve(V, Receiver);
        _ -> inherited(Proto, K, Receiver)
    end.

resolve({'$accessor', undefined, _}, _Receiver) -> undefined;
resolve({'$accessor', Getter, _}, Receiver) -> call(Getter, Receiver, []);
resolve(V, _Receiver) -> V.

%% [[Set]] in strict mode: a failed write throws a TypeError.
-spec set(value(), key(), value()) -> value().
set({'$o', Id} = O, K, V) ->
    case erlang:get(Id) of
        {array, P, Props, Keys, Attrs, {Length, Elements}} when is_integer(K), map_size(Attrs) =:= 0 ->
            erlang:put(Id, {array, P, Props, Keys, Attrs, {max(K + 1, Length), Elements#{K => V}}}),
            V;
        {array, P, Props, Keys, Attrs, Slots} when K =:= <<"length">>, map_size(Attrs) =:= 0 ->
            erlang:put(Id, {array, P, Props, Keys, Attrs, resize(Slots, V)}),
            V;
        {Class, P, Props, Keys, Attrs, Slots} = R ->
            case Props of
                #{K := {'$accessor', _, Setter}} ->
                    call_setter(Setter, O, K, V);
                #{K := _} when map_size(Attrs) =:= 0 ->
                    erlang:put(Id, {Class, P, Props#{K := V}, Keys, Attrs, Slots}),
                    V;
                #{K := _} ->
                    write_checked(Id, R, K, V);
                _ ->
                    add(Id, R, K, V, O)
            end;
        undefined ->
            materialize(Id, O),
            set(O, K, V)
    end;
set({'$f', Id, _} = F, K, V) ->
    R = fn_record(Id),
    {_, _, Props, _, _, _} = R,
    case Props of
        #{K := {'$accessor', _, Setter}} -> call_setter(Setter, F, K, V);
        #{K := _} -> write_checked(Id, R, K, V);
        _ -> add(Id, R, K, V, F)
    end.

write_checked(Id, {array, P, Props, Keys, Attrs, {Length, Elements}}, K, V) when is_integer(K) ->
    writable(K, Attrs) orelse read_only(K),
    erlang:put(Id, {array, P, Props, Keys, Attrs, {max(K + 1, Length), Elements#{K => V}}}),
    V;
write_checked(Id, {Class, P, Props, Keys, Attrs, Slots}, K, V) ->
    writable(K, Attrs) orelse read_only(K),
    erlang:put(Id, {Class, P, Props#{K => V}, Keys, Attrs, Slots}),
    V.

writable(_K, #{'$frozen' := true}) -> false;
writable(K, Attrs) -> maps:get(K, Attrs, ?ALL) band ?WRITABLE =/= 0.

-spec read_only(key()) -> no_return().
read_only(K) ->
    throw_error('TypeError', <<"Cannot assign to read only property '", (key_text(K))/binary, "' of object">>).

add(Id, {Class, P, Props, Keys, Attrs, Slots} = R, K, V, O) ->
    case inherited_setter(P, K) of
        {setter, Setter} ->
            call_setter(Setter, O, K, V);
        read_only ->
            read_only(K);
        none when Class =:= array, is_integer(K) ->
            write_checked(Id, R, K, V);
        none ->
            extensible(Attrs) orelse
                throw_error('TypeError', <<"Cannot add property ", (key_text(K))/binary, ", object is not extensible">>),
            erlang:put(Id, {Class, P, Props#{K => V}, add_key(K, Props, Keys), Attrs, Slots}),
            V
    end.

extensible(#{'$frozen' := true}) -> false;
extensible(#{'$noext' := true}) -> false;
extensible(_) -> true.

call_setter(undefined, _O, K, _V) ->
    throw_error('TypeError', <<"Cannot set property ", (key_text(K))/binary, " which has only a getter">>);
call_setter(Setter, O, _K, V) ->
    _ = call(Setter, O, [V]),
    V.

%% Whether a write of a new own key K must go to a setter or fail, from the
%% prototype chain.
inherited_setter(null, _K) ->
    none;
inherited_setter({'$o', Id} = O, K) ->
    case erlang:get(Id) of
        undefined -> setter_in(intrinsic_record(Id, O), K);
        R -> setter_in(R, K)
    end;
inherited_setter({'$f', Id, _}, K) ->
    setter_in(fn_record(Id), K).

setter_in({_, Proto, Props, _, Attrs, _}, K) ->
    case Props of
        #{K := {'$accessor', _, Setter}} -> {setter, Setter};
        #{K := _} ->
            case writable(K, Attrs) of
                true -> none;
                false -> read_only
            end;
        _ -> inherited_setter(Proto, K)
    end.

add_key(K, _Props, Keys) when is_integer(K) -> Keys;
add_key({'#', _, _}, _Props, Keys) -> Keys;
add_key(K, Props, Keys) ->
    case Props of
        #{K := _} -> Keys;
        _ -> [K | Keys]
    end.

resize({Length, Elements}, NewLength) when is_integer(NewLength), NewLength >= Length ->
    {NewLength, Elements};
resize({_, Elements}, NewLength) when is_integer(NewLength), NewLength >= 0 ->
    {NewLength, maps:filter(fun(I, _) -> I < NewLength end, Elements)};
resize(_, NewLength) ->
    throw_error('RangeError', <<"Invalid array length: ", (text(NewLength))/binary>>).

%% The `in` operator.
-spec has(value(), key()) -> boolean().
has(O, K) ->
    case has_own(O, K) of
        true -> true;
        false ->
            case prototype_of(O) of
                null -> false;
                Proto -> has(Proto, K)
            end
    end.

-spec has_own(value(), key()) -> boolean().
has_own(O, K) ->
    case record_of(O) of
        {array, _, _, _, _, {_, Elements}} when is_integer(K) -> is_map_key(K, Elements);
        {array, _, _, _, _, _} when K =:= <<"length">> -> true;
        {_, _, Props, _, _, _} -> is_map_key(K, Props)
    end.

%% `delete o[k]`. A non-configurable property throws a TypeError, as in strict mode.
-spec delete(value(), key()) -> true.
delete(O, K) ->
    Id = id_for_write(O),
    case erlang:get(Id) of
        {array, P, Props, Keys, Attrs, {Length, Elements}} when is_integer(K) ->
            configurable(K, Attrs) orelse cannot_delete(K),
            erlang:put(Id, {array, P, Props, Keys, Attrs, {Length, maps:remove(K, Elements)}});
        {Class, P, Props, Keys, Attrs, Slots} when is_map_key(K, Props) ->
            configurable(K, Attrs) orelse cannot_delete(K),
            erlang:put(Id, {Class, P, maps:remove(K, Props), lists:delete(K, Keys), maps:remove(K, Attrs), Slots});
        _ ->
            ok
    end,
    true.

configurable(_K, #{'$frozen' := true}) -> false;
configurable(K, Attrs) -> maps:get(K, Attrs, ?ALL) band ?CONFIGURABLE =/= 0.

-spec cannot_delete(key()) -> no_return().
cannot_delete(K) ->
    throw_error('TypeError', <<"Cannot delete property '", (key_text(K))/binary, "'">>).

%% OrdinaryOwnPropertyKeys: indexes ascending, then strings in insertion
%% order, then symbols in insertion order. Private names are not keys.
-spec own_keys(value()) -> [key()].
own_keys(O) ->
    {_, _, Props, Keys, _, _} = R = record_of(O),
    Indexes = case R of
        {array, _, _, _, _, {_, Elements}} -> lists:sort(maps:keys(Elements));
        _ -> []
    end,
    Ordered = lists:reverse(Keys),
    Indexes ++ lists:sort([K || K <- maps:keys(Props), is_integer(K)])
        ++ [K || K <- Ordered, is_binary(K)]
        ++ [K || {'$sym', _, _} = K <- Ordered].

%% The enumerable own string keys, for Object.keys, for-in, spread, and JSON.
-spec enumerable_keys(value()) -> [key()].
enumerable_keys(O) ->
    {_, _, _, _, Attrs, _} = record_of(O),
    [K || K <- own_keys(O), not is_tuple(K), enumerable(K, Attrs)].

enumerable(K, Attrs) -> maps:get(K, Attrs, ?ALL) band ?ENUMERABLE =/= 0.

%% Object.defineProperty with a descriptor map: value, writable, enumerable,
%% configurable, get, set. A missing attribute is false for a new property.
-spec define(value(), key(), map()) -> value().
define(O, K, Descriptor) ->
    Id = id_for_write(O),
    {Class, P, Props, Keys, Attrs, Slots} = record_of(O),
    Existing = maps:get(K, Attrs, case is_map_key(K, Props) of true -> ?ALL; false -> 0 end),
    Bits = bit(writable, ?WRITABLE, Descriptor, Existing)
        bor bit(enumerable, ?ENUMERABLE, Descriptor, Existing)
        bor bit(configurable, ?CONFIGURABLE, Descriptor, Existing),
    Slot = case Descriptor of
        #{get := G} -> {'$accessor', G, maps:get(set, Descriptor, undefined)};
        #{set := S} -> {'$accessor', undefined, S};
        #{value := V} -> V;
        _ -> maps:get(K, Props, undefined)
    end,
    Attrs1 = case Bits of
        ?ALL -> maps:remove(K, Attrs);
        _ -> Attrs#{K => Bits}
    end,
    case {Class, K} of
        {array, I} when is_integer(I) ->
            {Length, Elements} = Slots,
            erlang:put(Id, {Class, P, Props, Keys, Attrs1, {max(I + 1, Length), Elements#{I => Slot}}});
        _ ->
            erlang:put(Id, {Class, P, Props#{K => Slot}, add_key(K, Props, Keys), Attrs1, Slots})
    end,
    O.

bit(Name, Bit, Descriptor, Existing) ->
    case maps:get(Name, Descriptor, Existing band Bit =/= 0) of
        true -> Bit;
        _ -> 0
    end.

%% The own property K: {data, Value, Bits}, {accessor, Get, Set, Bits}, or none.
-spec get_own(value(), key()) -> {data, value(), 0..7} | {accessor, value(), value(), 0..7} | none.
get_own(O, K) ->
    {_, _, Props, _, Attrs, _} = R = record_of(O),
    Found = case R of
        {array, _, _, _, _, {_, Elements}} when is_integer(K) -> maps:find(K, Elements);
        {array, _, _, _, _, {Length, _}} when K =:= <<"length">> -> {ok, Length};
        _ -> maps:find(K, Props)
    end,
    Bits = case Attrs of
        #{'$frozen' := true} -> maps:get(K, Attrs, ?ALL) band ?ENUMERABLE;
        _ -> maps:get(K, Attrs, ?ALL)
    end,
    case Found of
        {ok, {'$accessor', G, S}} -> {accessor, G, S, Bits};
        {ok, V} -> {data, V, Bits};
        error -> none
    end.

-spec prototype_of(value()) -> value().
prototype_of(O) -> element(2, record_of(O)).

-spec set_prototype_of(value(), value()) -> value().
set_prototype_of(O, Proto) ->
    Id = id_for_write(O),
    erlang:put(Id, setelement(2, record_of(O), Proto)),
    O.

-spec freeze(value()) -> value().
freeze(O) ->
    Id = id_for_write(O),
    {Class, P, Props, Keys, Attrs, Slots} = record_of(O),
    erlang:put(Id, {Class, P, Props, Keys, Attrs#{'$frozen' => true}, Slots}),
    O.

-spec is_frozen(value()) -> boolean().
is_frozen(O) ->
    {_, _, _, _, Attrs, _} = record_of(O),
    maps:get('$frozen', Attrs, false).

-spec class_of(value()) -> atom().
class_of(O) -> element(1, record_of(O)).

-spec slots(value()) -> term().
slots(O) -> element(6, record_of(O)).

-spec set_slots(value(), term()) -> ok.
set_slots(O, Slots) ->
    Id = id_for_write(O),
    erlang:put(Id, setelement(6, record_of(O), Slots)),
    ok.

-spec is_object(term()) -> boolean().
is_object({'$o', _}) -> true;
is_object({'$f', _, _}) -> true;
is_object(_) -> false.

-spec is_callable(term()) -> boolean().
is_callable({'$f', _, _}) -> true;
is_callable(_) -> false.

record_of({'$o', Id} = O) ->
    case erlang:get(Id) of
        undefined -> intrinsic_record(Id, O);
        R -> R
    end;
record_of({'$f', Id, _}) ->
    fn_record(Id).

fn_record(Id) ->
    case erlang:get(Id) of
        undefined when is_tuple(Id) -> static_function_record(Id);
        undefined -> {function, ?FUNCTION_PROTO, #{}, [], #{}, #{}};
        R -> R
    end.

%% A builtin function value is {'$f', {builtin, Name}, Fun}: the same term in
%% every realm, so its identity holds, and it needs no allocation.
static_function_record({builtin, Name} = Id) ->
    case persistent_term:get({?MODULE, Id}, undefined) of
        undefined ->
            Short = lists:last(binary:split(Name, <<".">>, [global])),
            {function, ?FUNCTION_PROTO, #{<<"name">> => Short}, [<<"name">>], #{<<"name">> => ?CONFIGURABLE}, #{}};
        R ->
            R
    end;
static_function_record({fn, _Module, Name}) ->
    {function, ?FUNCTION_PROTO, #{<<"name">> => Name}, [<<"name">>], #{<<"name">> => ?CONFIGURABLE}, #{kind => normal}};
static_function_record(_Id) ->
    {function, ?FUNCTION_PROTO, #{}, [], #{}, #{}}.

intrinsic_record(Id, _O) when is_atom(Id) ->
    persistent_term:get({?MODULE, Id}, ?EMPTY);
intrinsic_record(Id, O) ->
    erlang:error({dangling_reference, O, Id}).

%% A write to an intrinsic, such as Array.prototype.last = ..., copies its
%% static record into this realm first.
materialize(Id, O) ->
    erlang:put(Id, intrinsic_record(Id, O)).

id_for_write({'$o', Id} = O) ->
    case erlang:get(Id) of
        undefined -> materialize(Id, O);
        _ -> ok
    end,
    Id;
id_for_write({'$f', Id, _}) ->
    case erlang:get(Id) of
        undefined -> erlang:put(Id, fn_record(Id));
        _ -> ok
    end,
    Id.

%% The runtime installs the static record of each intrinsic once per VM.
-spec install_intrinsic(term(), tuple()) -> ok.
install_intrinsic(Id, Record) ->
    case persistent_term:get({?MODULE, Id}, undefined) of
        Record -> ok;
        _ -> persistent_term:put({?MODULE, Id}, Record)
    end.

-spec intrinsic(atom()) -> value().
intrinsic(Id) -> {'$o', Id}.

%%% Cells

-spec cell(value()) -> {'$c', pos_integer()}.
cell(V) ->
    Id = next_id(),
    erlang:put(Id, V),
    {'$c', Id}.

-spec cell_get({'$c', pos_integer()}) -> value().
cell_get({'$c', Id}) -> erlang:get(Id).

-spec cell_set({'$c', pos_integer()}, value()) -> value().
cell_set({'$c', Id}, V) ->
    erlang:put(Id, V),
    V.

%%% Symbols

-spec symbol(value()) -> {'$sym', integer(), value()}.
symbol(Description) -> {'$sym', erlang:unique_integer(), Description}.

%% Symbol.for: the key is the identity, so every realm agrees without a registry.
-spec symbol_for(binary()) -> {'$sym', registered, binary()}.
symbol_for(Key) -> {'$sym', registered, Key}.

-spec well_known(atom()) -> {'$sym', atom(), binary()}.
well_known(Name) -> {'$sym', Name, <<"Symbol.", (atom_to_binary(Name))/binary>>}.

%%% Keys

%% ToPropertyKey for a primitive: an array index is an integer, any other
%% number its string, a symbol itself.
-spec to_key(term()) -> key().
to_key(K) when is_integer(K), K >= 0, K =< ?MAX_INDEX -> K;
to_key(<<C, _/binary>> = K) when C >= $0, C =< $9 -> index_or_string(K);
to_key(K) when is_binary(K) -> K;
to_key({'$sym', _, _} = K) -> K;
to_key(F) when is_float(F), F >= 0, F =< ?MAX_INDEX, F == trunc(F) -> trunc(F);
to_key(K) -> text(K).

index_or_string(<<"0">>) -> 0;
index_or_string(<<"0", _/binary>> = K) -> K;
index_or_string(K) when byte_size(K) =< 10 ->
    try binary_to_integer(K) of
        I when I =< ?MAX_INDEX -> I;
        _ -> K
    catch
        error:badarg -> K
    end;
index_or_string(K) -> K.

%% The JavaScript value of a key, as Object.keys returns it.
-spec key_to_value(key()) -> value().
key_to_value(K) when is_integer(K) -> integer_to_binary(K);
key_to_value(K) -> K.

key_text(K) when is_integer(K) -> integer_to_binary(K);
key_text(K) when is_binary(K) -> K;
key_text({'$sym', _, Description}) -> <<"Symbol(", (text(Description))/binary, ")">>;
key_text({'#', _, Name}) -> <<"#", Name/binary>>.

text(V) when is_binary(V) -> V;
text(undefined) -> <<>>;
text(V) -> bouy_rt:to_string(V).

describe({'$f', _, _}) -> <<"function">>;
describe({'$o', _}) -> <<"object">>;
describe(V) when is_binary(V) -> <<"\"", V/binary, "\"">>;
describe(V) -> text(V).

%%% Errors

%% An error object of the intrinsic class Name, such as 'TypeError'.
-spec error_object(atom() | value(), binary(), binary()) -> value().
error_object(Name, Message, Stack) when is_atom(Name) ->
    error_object({'$o', list_to_atom(atom_to_list(Name) ++ ".prototype")}, Message, Stack);
error_object(Proto, Message, Stack) ->
    Props = #{<<"message">> => Message, <<"stack">> => Stack},
    Attrs = #{<<"message">> => ?WRITABLE bor ?CONFIGURABLE, <<"stack">> => ?WRITABLE bor ?CONFIGURABLE},
    Id = next_id(),
    erlang:put(Id, {error, Proto, Props, [<<"message">>, <<"stack">>], Attrs, none}),
    {'$o', Id}.

-spec throw_error(atom(), binary()) -> no_return().
throw_error(Name, Message) ->
    Stack = <<(atom_to_binary(Name))/binary, ": ", Message/binary, "\n    at <bouy>">>,
    erlang:error({'$throw', error_object(Name, Message, Stack)}).

%%% Garbage collection

%% Marks from every pdict entry whose key is not an integer and from Roots,
%% then erases every integer key that marking did not reach. The caller's
%% stack must hold no heap reference that Roots leaves out.
-spec gc([term()]) -> #{live := non_neg_integer(), freed := non_neg_integer(), us := non_neg_integer()}.
gc(Roots) ->
    Start = erlang:monotonic_time(microsecond),
    {Ids, Others} = lists:partition(fun erlang:is_integer/1, erlang:get_keys()),
    {Live, Chunks} = mark([erlang:get(K) || K <- Others] ++ Roots, #{}, 0),
    Freed = sweep(Ids, Chunks, 0),
    Us = erlang:monotonic_time(microsecond) - Start,
    Stats = #{live => Live, freed => Freed, us => Us},
    {Runs, Total, Max} = case erlang:get(?STATS) of
        undefined -> {0, 0, 0};
        #{runs := R, total_us := T, max_us := M} -> {R, T, M}
    end,
    erlang:put(?STATS, Stats#{runs => Runs + 1, total_us => Total + Us, max_us => max(Max, Us), at => allocated()}),
    size_heap(Live),
    Stats.

-spec gc_stats() -> map().
gc_stats() ->
    case erlang:get(?STATS) of
        undefined -> #{runs => 0, total_us => 0, max_us => 0, at => 0, live => 0};
        Stats -> Stats
    end.

%% The count of heap entries: objects, cells, and function records.
-spec heap_size() -> non_neg_integer().
heap_size() -> length([K || K <- erlang:get_keys(), is_integer(K)]).

%% Mark bits live off the process heap, in one atomics array of 32-bit words
%% per chunk of 2^16 ids, so marking allocates little and the bits of a
%% sparse id range cost nothing. 32 bits keep each word a small integer.
%% Chunks maps a chunk number to its array.
-define(CHUNK, 16).
-define(CHUNK_WORDS, 2048).

%% Sets the mark bit of Id: {WasClear, Chunks1}.
first_mark(Id, Chunks) ->
    Chunk = Id bsr ?CHUNK,
    {Ref, Chunks1} = case Chunks of
        #{Chunk := R} -> {R, Chunks};
        _ -> R = atomics:new(?CHUNK_WORDS, [{signed, false}]), {R, Chunks#{Chunk => R}}
    end,
    Word = ((Id band 16#FFFF) bsr 5) + 1,
    Bit = 1 bsl (Id band 31),
    Old = atomics:get(Ref, Word),
    case Old band Bit of
        0 ->
            atomics:put(Ref, Word, Old bor Bit),
            {true, Chunks1};
        _ ->
            {false, Chunks1}
    end.

is_marked(Id, Chunks) ->
    case Chunks of
        #{(Id bsr ?CHUNK) := Ref} -> atomics:get(Ref, ((Id band 16#FFFF) bsr 5) + 1) band (1 bsl (Id band 31)) =/= 0;
        _ -> false
    end.

mark([], Chunks, Live) ->
    {Live, Chunks};
mark([{'$o', Id} | Rest], Chunks, Live) when is_integer(Id) ->
    case first_mark(Id, Chunks) of
        {true, Chunks1} -> mark(record_terms(erlang:get(Id), Rest), Chunks1, Live + 1);
        {false, Chunks1} -> mark(Rest, Chunks1, Live)
    end;
mark([{'$f', Id, Fun} | Rest], Chunks, Live) when is_integer(Id) ->
    case first_mark(Id, Chunks) of
        {true, Chunks1} -> mark(record_terms(erlang:get(Id), [Fun | Rest]), Chunks1, Live + 1);
        {false, Chunks1} -> mark(Rest, Chunks1, Live)
    end;
mark([{'$f', _, Fun} | Rest], Chunks, Live) ->
    mark([Fun | Rest], Chunks, Live);
mark([{'$c', Id} | Rest], Chunks, Live) when is_integer(Id) ->
    case first_mark(Id, Chunks) of
        {true, Chunks1} -> mark([erlang:get(Id) | Rest], Chunks1, Live + 1);
        {false, Chunks1} -> mark(Rest, Chunks1, Live)
    end;
mark([T | Rest], Chunks, Live) when is_tuple(T) ->
    mark(tuple_to_list(T) ++ Rest, Chunks, Live);
mark([[H | T] | Rest], Chunks, Live) ->
    mark([H, T | Rest], Chunks, Live);
mark([M | Rest], Chunks, Live) when is_map(M) ->
    mark(maps:fold(fun(K, V, Acc) -> [K, V | Acc] end, Rest, M), Chunks, Live);
mark([F | Rest], Chunks, Live) when is_function(F) ->
    {env, Env} = erlang:fun_info(F, env),
    mark(Env ++ Rest, Chunks, Live);
mark([_ | Rest], Chunks, Live) ->
    mark(Rest, Chunks, Live).

%% The terms of a record that can hold references: the prototype, the
%% values, and the slots. Keys and attributes hold none.
record_terms({_, Proto, Props, _, _, Slots}, Rest) ->
    [Proto, Slots | maps:values(Props) ++ Rest];
record_terms(_, Rest) ->
    Rest.

sweep([], _Chunks, Freed) ->
    Freed;
sweep([Id | Rest], Chunks, Freed) ->
    case is_marked(Id, Chunks) of
        true ->
            sweep(Rest, Chunks, Freed);
        false ->
            erlang:erase(Id),
            sweep(Rest, Chunks, Freed + 1)
    end.

%%% Structured clone

%% The term that carries Value to another realm. Objects become plain data
%% with back references, so cycles and shared objects survive the copy.
-spec clone_out(value()) -> term().
clone_out(Value) ->
    {Term, _} = out(Value, #{}),
    Term.

out({'$o', Id} = O, Seen) ->
    case Seen of
        #{Id := N} ->
            {{'$back', N}, Seen};
        _ ->
            N = map_size(Seen),
            out_record(record_of(O), O, N, Seen#{Id => N})
    end;
out({'$f', _, _}, _Seen) ->
    throw_error('DataCloneError', <<"function could not be cloned.">>);
out({'$sym', _, _} = S, _Seen) ->
    throw_error('DataCloneError', <<(key_text(S))/binary, " could not be cloned.">>);
out(V, Seen) ->
    {V, Seen}.

out_record({array, _, _, _, _, {Length, Elements}}, _O, N, Seen) ->
    {Items, Seen1} = out_pairs(lists:sort(maps:to_list(Elements)), Seen),
    {{'$array', N, Length, Items}, Seen1};
out_record({map, _, _, _, _, {Index, _}}, _O, N, Seen) ->
    Entries = [{K, V} || {_, {K, V}} <- lists:sort([{Seq, {K, V}} || K := {Seq, V} <- Index])],
    {Items, Seen1} = out_entries(Entries, Seen),
    {{'$map', N, Items}, Seen1};
out_record({set, _, _, _, _, {Index, _}}, _O, N, Seen) ->
    Members = [K || {_, K} <- lists:sort([{Seq, K} || K := Seq <- Index])],
    {Items, Seen1} = out_list(Members, Seen),
    {{'$set', N, Items}, Seen1};
out_record({date, _, _, _, _, Ms}, _O, N, Seen) ->
    {{'$date', N, Ms}, Seen};
out_record({error, _, _, _, _, _}, O, N, Seen) ->
    Name = text(get(O, <<"name">>)),
    {{'$error', N, Name, text(get(O, <<"message">>)), text(get(O, <<"stack">>))}, Seen};
out_record({object, _, _, _, _, _}, O, N, Seen) ->
    Pairs = [{K, get(O, K)} || K <- enumerable_keys(O)],
    {Items, Seen1} = out_pairs(Pairs, Seen),
    {{'$object', N, Items}, Seen1};
out_record({Class, _, _, _, _, _}, _O, _N, _Seen) ->
    throw_error('DataCloneError', <<"#<", (atom_to_binary(Class))/binary, "> could not be cloned.">>).

out_pairs(Pairs, Seen) ->
    lists:mapfoldl(fun({K, V}, S) -> {V1, S1} = out(V, S), {{K, V1}, S1} end, Seen, Pairs).

out_entries(Entries, Seen) ->
    lists:mapfoldl(fun({K, V}, S) ->
                           {K1, S1} = out(K, S),
                           {V1, S2} = out(V, S1),
                           {{K1, V1}, S2}
                   end, Seen, Entries).

out_list(Items, Seen) ->
    lists:mapfoldl(fun out/2, Seen, Items).

%% Builds the clone of Term in this realm.
-spec clone_in(term()) -> value().
clone_in(Term) ->
    {Value, _} = in(Term, #{}),
    Value.

in({'$back', N}, Made) ->
    {maps:get(N, Made), Made};
in({'$object', N, Pairs}, Made) ->
    O = new_object(?OBJECT_PROTO),
    {Values, Made1} = lists:mapfoldl(fun({K, V}, M) -> {V1, M1} = in(V, M), {{K, V1}, M1} end, Made#{N => O}, Pairs),
    {'$o', Id} = O,
    {Props, Keys} = lists:foldl(fun({K, V}, {Ps, Ks}) -> {Ps#{K => V}, add_key(K, Ps, Ks)} end, {#{}, []}, Values),
    erlang:put(Id, {object, ?OBJECT_PROTO, Props, Keys, #{}, none}),
    {O, Made1};
in({'$array', N, Length, Pairs}, Made) ->
    O = new_array([]),
    {Values, Made1} = lists:mapfoldl(fun({K, V}, M) -> {V1, M1} = in(V, M), {{K, V1}, M1} end, Made#{N => O}, Pairs),
    {'$o', Id} = O,
    erlang:put(Id, {array, ?ARRAY_PROTO, #{}, [], #{}, {Length, maps:from_list(Values)}}),
    {O, Made1};
in({'$map', N, Entries}, Made) ->
    O = new_exotic(map, {'$o', 'Map.prototype'}, {#{}, 0}),
    {Values, Made1} = lists:mapfoldl(fun({K, V}, M) ->
                                             {K1, M1} = in(K, M),
                                             {V1, M2} = in(V, M1),
                                             {{K1, V1}, M2}
                                     end, Made#{N => O}, Entries),
    Index = maps:from_list([{K, {Seq, V}} || {Seq, {K, V}} <- lists:enumerate(0, Values)]),
    set_slots(O, {Index, length(Values)}),
    {O, Made1};
in({'$set', N, Members}, Made) ->
    O = new_exotic(set, {'$o', 'Set.prototype'}, {#{}, 0}),
    {Values, Made1} = lists:mapfoldl(fun in/2, Made#{N => O}, Members),
    set_slots(O, {maps:from_list([{K, Seq} || {Seq, K} <- lists:enumerate(0, Values)]), length(Values)}),
    {O, Made1};
in({'$date', N, Ms}, Made) ->
    O = new_exotic(date, {'$o', 'Date.prototype'}, Ms),
    {O, Made#{N => O}};
in({'$error', N, Name, Message, Stack}, Made) ->
    Proto = case lists:member(Name, [<<"Error">>, <<"TypeError">>, <<"RangeError">>, <<"SyntaxError">>, <<"ReferenceError">>]) of
        true -> {'$o', binary_to_atom(<<Name/binary, ".prototype">>)};
        false -> {'$o', 'Error.prototype'}
    end,
    O = error_object(Proto, Message, Stack),
    {O, Made#{N => O}};
in(V, Made) ->
    {V, Made}.
