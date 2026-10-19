%% The JavaScript heap of one realm (spike: reference semantics).
%%
%% A realm is one BEAM process. Its objects live in the process dictionary of
%% that process, so they are mutable and have identity, and no other process
%% can reach them. Values:
%%
%%   {'$o', Id}           an object. Id is a positive integer, or an atom for
%%                        an intrinsic such as 'Object.prototype', or {N, Atom}
%%                        for that intrinsic of the realm N > 0 of the process
%%                        (buoy_ref_realm:create/0).
%%   {'$f', Id, Fun}      a function. Fun is fun((This, Args) -> Result). A
%%                        function gets a record only when it needs one, so
%%                        an arrow function costs one id and no record.
%%   {'$sym', Tag, Desc}  a symbol. Tag is an integer for Symbol(), the atom
%%                        registered for Symbol.for(), an atom such as
%%                        iterator for a well-known symbol, or {private, N}
%%                        for a private symbol of V8, which Node's bindings
%%                        use: an own key only, no key of ownKeys, and
%%                        writable on a frozen object, as a private name.
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
-module(buoy_heap).

-include("buoy_ref.hrl").

-export([new_object/1, object/2, literal/3, new_array/1, new_array/2, array_items/1, array_length/1]).
-export([array_push/2, array_set_items/2]).
-export([function/1, function/4, call/3, construct/3, is_constructor/1]).
-export([get/2, get/3, set/3, set/4, sloppy_set/3, has/2, has_own/2, delete/2, delete_property/2, own_keys/1, enumerable_keys/1, is_enumerable/1]).
-export([own_named_keys/1]).
-export([define/3, define_own_property/3, validate_and_apply/5, get_own/2, prototype_of/1, set_prototype_of/2, set_prototype/2]).
-export([is_extensible/1, prevent_extensions/1, freeze/1, is_frozen/1, is_accessor_descriptor/1, is_data_descriptor/1]).
-export([class_of/1, slots/1, set_slots/2, new_exotic/3, proxy/2, is_object/1, is_callable/1]).
-export([cell/1, cell_get/1, cell_set/2]).
-export([symbol/1, symbol_for/1, well_known/1, private_symbol/1]).
-export([to_key/1, key_to_value/1]).
-export([install_intrinsic/2, intrinsic/1, intrinsic/2, function_prototype/0, realm/0, throw_error/2, error_object/3]).
-export([gc/1, gc_stats/0, heap_size/0, allocated/0, add_external/1, external/0]).
-export([clone_out/1, clone_in/1, clone_out/2, clone_in/2]).
-export([private_find/2, private_put/3, set_failed/2]).

-export_type([value/0, key/0, property/0]).

-type value() :: term().
-type key() :: non_neg_integer() | binary() | {'$sym', term(), term()} | {'#', term(), binary()}.
%% An own property: its value or accessor functions and its attribute bits.
-type property() :: {data, value(), 0..7} | {accessor, value(), value(), 0..7} | none.

-define(NEXT, '$buoy_next').
-define(STATS, '$buoy_gc').
-define(EXTERNAL, '$buoy_external').
-define(CLONE_HOOK, '$buoy_clone_hook').
-define(WORDS_PER_ID, 16).
-define(MIN_HEAP_WORDS, 4096).
-define(WRITABLE, 1).
-define(ENUMERABLE, 2).
-define(CONFIGURABLE, 4).
-define(ALL, 7).
-define(MAX_INDEX, 4294967294).
-define(EMPTY, {object, null, #{}, [], #{}, none}).
-define(ARRAY_PROTO, {'$o', 'Array.prototype'}).
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
new_array(Items) -> new_array(Items, intrinsic('Array.prototype')).

-spec new_array([value()], value()) -> value().
new_array(Items, Proto) ->
    Elements = maps:from_list(lists:enumerate(0, Items)),
    Id = next_id(),
    erlang:put(Id, {array, Proto, #{}, [], #{}, {map_size(Elements), Elements}}),
    {'$o', Id}.

%% A proxy (buoy_ref_proxy): a function value when Target is callable.
-spec proxy(value(), value()) -> value().
proxy(Target, Handler) ->
    Id = next_id(),
    erlang:put(Id, {proxy, null, #{}, [], #{}, {Target, Handler}}),
    case is_callable(Target) of
        true -> {'$f', Id, fun(This, Args) -> buoy_ref_proxy:call(Id, This, Args) end};
        false -> {'$o', Id}
    end.

%% An object of another class, such as a Map, with its internal slots.
-spec new_exotic(atom(), value(), term()) -> value().
new_exotic(Class, Proto, Slots) ->
    Id = next_id(),
    erlang:put(Id, {Class, Proto, #{}, [], #{}, Slots}),
    {'$o', Id}.

%% The items of an array, holes as undefined. Another object, such as a proxy
%% of an array or an arguments object, gives its elements 0 to length - 1
%% through [[Get]], as the generic array methods read them.
-spec array_items(value()) -> [value()].
array_items({'$o', Id} = O) ->
    case erlang:get(Id) of
        {array, _, _, _, _, {Length, Elements}} -> [element_value(maps:get(I, Elements, undefined), O) || I <- lists:seq(0, Length - 1)];
        _ -> [get(O, I) || I <- lists:seq(0, array_length(O) - 1)]
    end;
array_items(O) ->
    [get(O, I) || I <- lists:seq(0, array_length(O) - 1)].

element_value({'$accessor', _, _} = A, O) -> resolve(A, O);
element_value(V, _O) -> V.

%% Array.prototype.push: one read and one write of the record for any count.
-spec array_push(value(), [value()]) -> non_neg_integer().
array_push({'$o', Id} = O, Items) ->
    case erlang:get(Id) of
        {array, ?ARRAY_PROTO = P, Props, Keys, Attrs, {Length, Elements}}
          when map_size(Attrs) =:= 0, Length + length(Items) =< ?MAX_INDEX + 1 ->
            %% The intrinsic prototypes hold no index until a realm writes them, so
            %% no setter on the chain can see the new elements.
            case erlang:get('Array.prototype') =:= undefined andalso erlang:get('Object.prototype') =:= undefined of
                true ->
                    {Length1, Elements1} = lists:foldl(fun(V, {L, E}) -> {L + 1, E#{L => V}} end, {Length, Elements}, Items),
                    erlang:put(Id, {array, P, Props, Keys, Attrs, {Length1, Elements1}}),
                    Length1;
                false ->
                    generic_push(O, Items)
            end;
        _ ->
            generic_push(O, Items)
    end;
array_push(O, Items) ->
    generic_push(O, Items).

%% Push on any object: Set of each index, then of length.
generic_push(O, Items) ->
    Length = lists:foldl(fun(V, L) -> _ = set(O, index_key(L), V), L + 1 end, array_length(O), Items),
    _ = set(O, <<"length">>, Length),
    Length.

%% The key of index L: a string past the largest array index.
index_key(L) when L =< ?MAX_INDEX -> L;
index_key(L) -> integer_to_binary(L).

%% Replaces every item, as sort, splice, and shift do.
-spec array_set_items(value(), [value()]) -> ok.
array_set_items({'$o', Id} = O, Items) ->
    case erlang:get(Id) of
        {array, P, Props, Keys, Attrs, _} when map_size(Attrs) =:= 0 ->
            Elements = maps:from_list(lists:enumerate(0, Items)),
            erlang:put(Id, {array, P, Props, Keys, Attrs, {length(Items), Elements}}),
            ok;
        _ ->
            generic_set_items(O, Items)
    end;
array_set_items(O, Items) ->
    generic_set_items(O, Items).

%% Writes each item, deletes the indexes past the new length, and sets length.
generic_set_items(O, Items) ->
    Old = array_length(O),
    New = length(Items),
    lists:foreach(fun({I, V}) -> _ = set(O, I, V) end, lists:enumerate(0, Items)),
    lists:foreach(fun(I) -> delete(O, I) end, lists:seq(Old - 1, New, -1)),
    _ = set(O, <<"length">>, New),
    ok.

%% The length of an array, or LengthOfArrayLike of another object.
-spec array_length(value()) -> non_neg_integer().
array_length({'$o', Id} = O) ->
    case erlang:get(Id) of
        {array, _, _, _, _, {Length, _}} -> Length;
        _ -> length_of_array_like(O)
    end;
array_length(O) ->
    length_of_array_like(O).

length_of_array_like(O) ->
    case buoy_ref_number:to_integer_or_infinity(buoy_ref:to_number(get(O, <<"length">>))) of
        L when is_integer(L), L > 0 -> min(L, 9007199254740991);
        'Infinity' -> 9007199254740991;
        _ -> 0
    end.

%%% Functions

%% A function without a record: an arrow function or a method.
-spec function(fun((value(), list()) -> value())) -> value().
function(Fun) -> {'$f', next_id(), Fun}.

%% A function with a record: a name, a length, and internal slots, such as the
%% construct behaviour of a class.
-spec function(fun((value(), list()) -> value()), binary(), value(), map()) -> value().
function(Fun, Name, Length, Slots) ->
    Id = next_id(),
    Props = #{<<"length">> => Length, <<"name">> => Name},
    Attrs = #{<<"length">> => ?CONFIGURABLE, <<"name">> => ?CONFIGURABLE},
    {Fun1, Slots1} = case erlang:get(?REALM_KEY) of
        undefined -> {Fun, Slots};
        N -> {buoy_ref_realm:realm_fun(N, Fun), Slots#{realm => N}}
    end,
    erlang:put(Id, {function, function_prototype(), Props, [<<"name">>, <<"length">>], Attrs, Slots1}),
    {'$f', Id, Fun1}.

-spec call(value(), value(), list()) -> value().
call({'$f', _, Fun}, This, Args) -> Fun(This, Args);
call(V, _This, _Args) -> throw_error('TypeError', text([describe(V), <<" is not a function">>])).

%% [[Construct]]. A class, a builtin, or a function that reads new.target
%% keeps its construct fun in its slots, fun((NewTarget, Args) -> Object).
%% Another ordinary function gets a new this whose prototype comes from
%% NewTarget. A bound function or a proxy constructs through its target.
-spec construct(value(), list(), value()) -> value().
construct({'$f', _, Fun} = F, Args, NewTarget) ->
    case fn_record(F) of
        {function, _, _, _, _, #{construct := Construct}} ->
            Construct(NewTarget, Args);
        {function, _, _, _, _, #{kind := normal}} ->
            construct_ordinary(Fun, Args, NewTarget);
        {proxy, _, _, _, _, Handler} ->
            buoy_ref_proxy:construct(Handler, Args, NewTarget);
        _ ->
            throw_error('TypeError', text([describe(F), <<" is not a constructor">>]))
    end;
construct(V, _Args, _NewTarget) ->
    throw_error('TypeError', text([describe(V), <<" is not a constructor">>])).

construct_ordinary(Fun, Args, NewTarget) ->
    This = new_object(prototype_for(NewTarget)),
    case Fun(This, Args) of
        Object when ?is_obj(Object) -> Object;
        _ -> This
    end.

%% IsConstructor.
-spec is_constructor(term()) -> boolean().
is_constructor({'$f', _, _} = F) ->
    case fn_record(F) of
        {function, _, _, _, _, #{construct := _}} -> true;
        {function, _, _, _, _, #{kind := normal}} -> true;
        {proxy, _, _, _, _, {revoked, IsConstructor}} -> IsConstructor;
        {proxy, _, _, _, _, {Target, _}} -> is_constructor(Target);
        _ -> false
    end;
is_constructor(_) ->
    false.

prototype_for(NewTarget) -> buoy_ref_realm:proto_for(NewTarget, 'Object.prototype').

%%% Properties
%%
%% The internal methods of ECMA-262 §10.1. get/3 is [[Get]], set/4 [[Set]],
%% get_own/2 [[GetOwnProperty]], define_own_property/3 [[DefineOwnProperty]],
%% has/2 [[HasProperty]], delete_property/2 [[Delete]], own_keys/1
%% [[OwnPropertyKeys]], prototype_of/1 and set_prototype/2, and
%% is_extensible/1 and prevent_extensions/1. Each one sends a proxy to
%% buoy_ref_proxy, an array's length and indexes through the array rules of
%% §10.4.2, and a mapped arguments object through §10.4.4. The functions that
%% return a boolean report a failure; set/3, delete/2, and define/3 throw a
%% TypeError instead, as strict code does.

-spec get(value(), key()) -> value().
get(O, K) -> get(O, K, O).

%% [[Get]] with a receiver: a getter runs with Receiver as this.
-spec get(value(), key(), value()) -> value().
get({'$o', Id} = O, K, Receiver) ->
    case erlang:get(Id) of
        undefined -> from_record(intrinsic_record(Id, O), K, Receiver);
        {typed_array, _, _, _, _, _} = R -> typed_get(O, R, K, Receiver);
        R -> from_record(R, K, Receiver)
    end;
get({'$f', Id, _} = F, K, Receiver) ->
    case erlang:get(Id) of
        undefined -> from_record(fn_record(F), K, Receiver);
        R -> from_record(R, K, Receiver)
    end.

from_record({array, Proto, _, _, _, {_, Elements}}, K, Receiver) when is_integer(K) ->
    case Elements of
        #{K := {'$accessor', _, _} = A} -> resolve(A, Receiver);
        #{K := V} -> V;
        _ -> inherited(Proto, K, Receiver)
    end;
from_record({array, _, _, _, _, {Length, _}}, <<"length">>, _Receiver) ->
    Length;
from_record({deferred_namespace, _, Props, _, _, M}, K, Receiver) ->
    deferred_get(M, Props, K, Receiver);
from_record({proxy, _, Props, _, _, _}, {'#', _, _} = K, _Receiver) ->
    maps:get(K, Props, undefined);
from_record({proxy, _, _, _, _, Handler}, K, Receiver) ->
    buoy_ref_proxy:get(Handler, K, Receiver);
from_record({arguments, _, _, _, _, Map}, K, _Receiver) when is_map_key(K, Map) ->
    cell_get(maps:get(K, Map));
from_record({_, Proto, Props, _, _, _}, K, Receiver) ->
    case Props of
        #{K := V} -> resolve(V, Receiver);
        _ -> inherited(Proto, K, Receiver)
    end.

inherited(null, _K, _Receiver) -> undefined;
inherited(_Proto, {'$sym', {private, _}, _}, _Receiver) -> undefined;
inherited(Proto, K, Receiver) -> get(Proto, K, Receiver).

%% [[Get]] of a typed array (ECMA-262 §10.4.5.4): a numeric key reads the
%% element, or undefined, and never the prototype chain.
typed_get(O, R, K, Receiver) ->
    case typed_index(K) of
        {index, N} -> buoy_ref_typed_array:element_get(O, N);
        none -> from_record(R, K, Receiver)
    end.

%% The index of a numeric key of a typed array (CanonicalNumericIndexString).
typed_index({'$sym', _, _}) -> none;
typed_index({'#', _, _}) -> none;
typed_index(K) -> buoy_ref_typed_array:numeric_key(K).

%% A deferred namespace (buoy_module) evaluates its module when code first uses a
%% string key other than "then". "then" and symbols act as on an ordinary object,
%% and the namespace holds no ordinary "then".
deferred_get(M, Props, K, Receiver) ->
    case deferred_key(M, K) of
        absent -> undefined;
        _ ->
            case Props of
                #{K := V} -> resolve(V, Receiver);
                _ -> undefined
            end
    end.

deferred_key(_M, <<"then">>) -> absent;
deferred_key(_M, {'$sym', _, _}) -> ordinary;
deferred_key(M, _K) -> ok = buoy_module:ensure_deferred(M), export.

%% A live binding of a module namespace (buoy_module) reads its module.
resolve({'$live', Read}, _Receiver) -> Read();
resolve({'$accessor', undefined, _}, _Receiver) -> undefined;
resolve({'$accessor', Getter, _}, Receiver) -> call(Getter, Receiver, []);
resolve(V, _Receiver) -> V.

%% `o[k] = v` in strict code: [[Set]] with o as the receiver, and a TypeError
%% when it fails. The common cases write the record at once.
-spec set(value(), key(), value()) -> value().
set(O, K, V) -> assign(O, K, V, strict).

%% `o[k] = v` in sloppy code: a failed write does nothing.
-spec sloppy_set(value(), key(), value()) -> value().
sloppy_set(O, K, V) -> assign(O, K, V, sloppy).

assign({'$o', Id} = O, K, V, Mode) ->
    case erlang:get(Id) of
        {array, P, Props, Keys, Attrs, {Length, Elements}} when is_integer(K), map_size(Attrs) =:= 0 ->
            case Elements of
                #{K := {'$accessor', _, _}} ->
                    strict_set(O, K, V, Mode);
                #{K := _} ->
                    erlang:put(Id, {array, P, Props, Keys, Attrs, {Length, Elements#{K := V}}}),
                    V;
                _ ->
                    case inherited_setter(P, K) of
                        none ->
                            erlang:put(Id, {array, P, Props, Keys, Attrs, {max(K + 1, Length), Elements#{K => V}}}),
                            V;
                        _ ->
                            strict_set(O, K, V, Mode)
                    end
            end;
        {array, P, Props, Keys, Attrs, Slots} when K =:= <<"length">>, map_size(Attrs) =:= 0,
                                                   is_integer(V), V >= 0, V =< ?MAX_INDEX + 1 ->
            erlang:put(Id, {array, P, Props, Keys, Attrs, resize(Slots, V)}),
            V;
        {array, _, _, _, _, _} when is_integer(K); K =:= <<"length">> ->
            strict_set(O, K, V, Mode);
        {Class, _, _, _, _, _} when Class =:= namespace; Class =:= deferred_namespace; Class =:= typed_array ->
            strict_set(O, K, V, Mode);
        {Class, P, Props, Keys, Attrs, Slots} = R when Class =/= proxy, (Class =/= arguments orelse not is_map(Slots)) ->
            case Props of
                #{K := {'$accessor', _, Setter}} ->
                    call_setter(Setter, O, K, V, Mode);
                #{K := _} when map_size(Attrs) =:= 0 ->
                    erlang:put(Id, {Class, P, Props#{K := V}, Keys, Attrs, Slots}),
                    V;
                #{K := _} ->
                    case writable(K, Attrs) of
                        true ->
                            erlang:put(Id, {Class, P, Props#{K := V}, Keys, Attrs, Slots}),
                            V;
                        false ->
                            strict_set(O, K, V, Mode)
                    end;
                _ ->
                    add(Id, R, K, V, O, Mode)
            end;
        undefined ->
            materialize(Id, O),
            assign(O, K, V, Mode);
        _ ->
            strict_set(O, K, V, Mode)
    end;
assign({'$f', Id, _} = F, K, V, Mode) ->
    case erlang:get(Id) of
        {function, P, Props, Keys, Attrs, Slots} = R ->
            case Props of
                #{K := {'$accessor', _, Setter}} ->
                    call_setter(Setter, F, K, V, Mode);
                #{K := _} ->
                    case writable(K, Attrs) of
                        true ->
                            erlang:put(Id, {function, P, Props#{K := V}, Keys, Attrs, Slots}),
                            V;
                        false ->
                            strict_set(F, K, V, Mode)
                    end;
                _ ->
                    add(Id, R, K, V, F, Mode)
            end;
        _ ->
            strict_set(F, K, V, Mode)
    end.

%% A new own key K: a setter or a read-only property up the prototype chain
%% decides, else the object must be extensible.
add(Id, {Class, P, Props, Keys, Attrs, Slots}, K, V, O, Mode) ->
    case inherited_setter(P, K) of
        {setter, Setter} ->
            call_setter(Setter, O, K, V, Mode);
        none ->
            case is_private(K) orelse extensible(Attrs) of
                true ->
                    erlang:put(Id, {Class, P, Props#{K => V}, add_key(K, Props, Keys), Attrs, Slots}),
                    V;
                false ->
                    strict_set(O, K, V, Mode)
            end;
        _ ->
            strict_set(O, K, V, Mode)
    end.

call_setter(undefined, O, K, V, Mode) ->
    failed(O, K, V, Mode);
call_setter(Setter, O, _K, V, _Mode) ->
    _ = call(Setter, O, [V]),
    V.

%% What the prototype chain says about a write of a new own key K: none, a
%% setter, read_only, or slow when a proxy, a typed array, or an array length
%% is in the way.
inherited_setter(null, _K) ->
    none;
inherited_setter(P, K) ->
    case record_of(P) of
        {proxy, _, _, _, _, _} -> slow;
        {typed_array, _, _, _, _, _} -> slow;
        {array, _, _, _, _, _} when K =:= <<"length">> -> slow;
        {array, Proto, _, _, Attrs, {_, Elements}} when is_integer(K) -> setter_from(maps:find(K, Elements), K, Attrs, Proto);
        {arguments, _, _, _, _, Map} when is_map_key(K, Map) -> slow;
        {_, Proto, Props, _, Attrs, _} -> setter_from(maps:find(K, Props), K, Attrs, Proto)
    end.

setter_from({ok, {'$accessor', _, Setter}}, _K, _Attrs, _Proto) ->
    {setter, Setter};
setter_from({ok, _}, K, Attrs, _Proto) ->
    case writable(K, Attrs) of
        true -> none;
        false -> read_only
    end;
setter_from(error, K, _Attrs, Proto) ->
    inherited_setter(Proto, K).

strict_set(O, K, V, Mode) ->
    case set(O, K, V, O) of
        true -> V;
        false -> failed(O, K, V, Mode)
    end.

failed(O, K, _V, strict) -> set_failed(O, K);
failed(_O, _K, V, sloppy) -> V.

-spec set_failed(value(), key()) -> no_return().
set_failed(O, K) ->
    Message = case find_property(O, K) of
        proxy -> text([<<"'set' on proxy: trap returned falsish for property '">>, key_text(K), <<"'">>]);
        {accessor, _, _, _} -> text([<<"Cannot set property ">>, key_text(K), <<" of ">>, describe(O), <<" which has only a getter">>]);
        {data, _, _} -> text([<<"Cannot assign to read only property '">>, key_text(K), <<"' of object">>]);
        none -> text([<<"Cannot add property ">>, key_text(K), <<", object is not extensible">>])
    end,
    throw_error('TypeError', Message).

%% The property K on O or up its chain, without running a proxy trap.
find_property(null, _K) ->
    none;
find_property(O, K) ->
    case record_of(O) of
        {proxy, _, _, _, _, _} -> proxy;
        R ->
            case own_of(R, K) of
                none -> find_property(element(2, R), K);
                Found -> Found
            end
    end.

%% [[Set]] (OrdinarySet, §10.1.9): true when the write happened.
-spec set(value(), key(), value(), value()) -> boolean().
set(O, K, V, Receiver) ->
    case record_of(O) of
        {proxy, _, _, _, _, _} when element(1, K) =:= '#' ->
            put_own(O, K, V, ?ALL),
            true;
        {proxy, _, _, _, _, Handler} ->
            buoy_ref_proxy:set(Handler, K, V, Receiver);
        %% A namespace object has no writable binding.
        {Class, _, _, _, _, _} when Class =:= namespace; Class =:= deferred_namespace ->
            false;
        {typed_array, _, _, _, _, _} = R ->
            typed_set(O, R, K, V, Receiver);
        {arguments, _, _, _, _, Map} = R when is_map_key(K, Map), O =:= Receiver ->
            _ = cell_set(maps:get(K, Map), V),
            ordinary_set(R, K, V, Receiver);
        R ->
            ordinary_set(R, K, V, Receiver)
    end.

ordinary_set(R, K, V, Receiver) ->
    case own_of(R, K) of
        none ->
            case element(2, R) of
                null -> set_on_receiver(K, V, Receiver);
                Parent -> set(Parent, K, V, Receiver)
            end;
        {data, _, Bits} when Bits band ?WRITABLE =:= 0 ->
            false;
        {data, _, _} ->
            set_on_receiver(K, V, Receiver);
        {accessor, _, undefined, _} ->
            false;
        {accessor, _, Setter, _} ->
            _ = call(Setter, Receiver, [V]),
            true
    end.

%% [[Set]] of a typed array (§10.4.5.5): a numeric key writes the element of
%% the array itself, and a write through another receiver defines on it only
%% for a valid index.
typed_set(O, R, K, V, Receiver) ->
    case typed_index(K) of
        {index, N} when O =:= Receiver ->
            buoy_ref_typed_array:element_set(O, N, V),
            true;
        {index, N} ->
            case buoy_ref_typed_array:element_has(O, N) of
                true -> set_on_receiver(K, V, Receiver);
                false -> true
            end;
        none ->
            ordinary_set(R, K, V, Receiver)
    end.

set_on_receiver(K, V, Receiver) when ?is_obj(Receiver) ->
    case get_own(Receiver, K) of
        {accessor, _, _, _} -> false;
        {data, _, Bits} when Bits band ?WRITABLE =:= 0 -> false;
        {data, _, _} -> define_own_property(Receiver, K, #{value => V});
        none -> define_own_property(Receiver, K, #{value => V, writable => true, enumerable => true, configurable => true})
    end;
set_on_receiver(_K, _V, _Receiver) ->
    false.

writable({'#', _, _}, _Attrs) -> true;
writable({'$sym', {private, _}, _}, _Attrs) -> true;
writable(_K, #{'$frozen' := true}) -> false;
writable(K, Attrs) -> maps:get(K, Attrs, ?ALL) band ?WRITABLE =/= 0.

is_private({'#', _, _}) -> true;
is_private({'$sym', {private, _}, _}) -> true;
is_private(_) -> false.

extensible(#{'$frozen' := true}) -> false;
extensible(#{'$noext' := true}) -> false;
extensible(_) -> true.

add_key(K, _Props, Keys) when is_integer(K) -> Keys;
add_key({'#', _, _}, _Props, Keys) -> Keys;
add_key({'$sym', {private, _}, _}, _Props, Keys) -> Keys;
add_key(K, Props, Keys) ->
    case Props of
        #{K := _} -> Keys;
        _ -> [K | Keys]
    end.

resize({Length, Elements}, NewLength) when is_integer(NewLength), NewLength >= Length ->
    {NewLength, Elements};
resize({Length, Elements}, NewLength) when is_integer(NewLength), NewLength >= 0, Length - NewLength < map_size(Elements) ->
    {NewLength, maps:without(lists:seq(NewLength, Length - 1), Elements)};
resize({_, Elements}, NewLength) when is_integer(NewLength), NewLength >= 0 ->
    {NewLength, maps:filter(fun(I, _) -> I < NewLength end, Elements)};
resize(_, NewLength) ->
    throw_error('RangeError', text([<<"Invalid array length: ">>, buoy_ref:to_string(NewLength)])).

%% [[HasProperty]]: the `in` operator.
-spec has(value(), key()) -> boolean().
has(O, K) ->
    case record_of(O) of
        {proxy, _, _, _, _, Handler} ->
            buoy_ref_proxy:has(Handler, K);
        %% [[HasProperty]] of a namespace does not read the binding.
        {namespace, _, Props, _, _, _} ->
            is_map_key(K, Props);
        {deferred_namespace, _, Props, _, _, M} ->
            deferred_key(M, K) =/= absent andalso is_map_key(K, Props);
        {typed_array, _, _, _, _, _} = R ->
            case typed_index(K) of
                {index, N} -> buoy_ref_typed_array:element_has(O, N);
                none -> ordinary_has(R, K)
            end;
        R ->
            ordinary_has(R, K)
    end.

ordinary_has(R, K) ->
    case own_of(R, K) of
        none ->
            case element(2, R) of
                null -> false;
                Proto -> has(Proto, K)
            end;
        _ ->
            true
    end.

-spec has_own(value(), key()) -> boolean().
has_own(O, K) -> get_own(O, K) =/= none.

%% `delete o[k]` in strict code: a property that cannot go throws a TypeError.
-spec delete(value(), key()) -> true.
delete(O, K) ->
    case delete_property(O, K) of
        true -> true;
        false -> cannot_delete(O, K)
    end.

%% [[Delete]]: false for a non-configurable property.
-spec delete_property(value(), key()) -> boolean().
delete_property(O, K) ->
    case record_of(O) of
        {proxy, _, _, _, _, Handler} ->
            buoy_ref_proxy:delete_property(Handler, K);
        {deferred_namespace, _, _, _, _, M} = R ->
            deferred_key(M, K),
            own_of(R, K) =:= none;
        {typed_array, _, _, _, _, _} = R ->
            case typed_index(K) of
                {index, N} -> buoy_ref_typed_array:element_delete(O, N);
                none -> ordinary_delete(O, R, K)
            end;
        R ->
            ordinary_delete(O, R, K)
    end.

ordinary_delete(O, R, K) ->
    case own_of(R, K) of
        none -> true;
        {data, _, Bits} when Bits band ?CONFIGURABLE =:= 0 -> false;
        {accessor, _, _, Bits} when Bits band ?CONFIGURABLE =:= 0 -> false;
        _ -> remove_own(O, K), true
    end.

remove_own(O, K) ->
    Id = id_for_write(O),
    case erlang:get(Id) of
        {array, P, Props, Keys, Attrs, {Length, Elements}} when is_integer(K) ->
            erlang:put(Id, {array, P, Props, Keys, maps:remove(K, Attrs), {Length, maps:remove(K, Elements)}});
        {arguments, P, Props, Keys, Attrs, Map} when is_map(Map) ->
            erlang:put(Id, {arguments, P, maps:remove(K, Props), lists:delete(K, Keys), maps:remove(K, Attrs), maps:remove(K, Map)});
        {Class, P, Props, Keys, Attrs, Slots} ->
            erlang:put(Id, {Class, P, maps:remove(K, Props), lists:delete(K, Keys), maps:remove(K, Attrs), Slots})
    end,
    ok.

%% V8's message names the receiver: #<Class> for an object, [object Array]
%% for an array.
-spec cannot_delete(value(), key()) -> no_return().
cannot_delete(O, K) ->
    Receiver = case O of
        {'$o', _} ->
            case class_of(O) of
                array -> [<<" of [object Array]">>];
                _ -> [<<" of #<">>, receiver_name(O, 0), <<">">>]
            end;
        _ -> []
    end,
    throw_error('TypeError', text([<<"Cannot delete property '">>, key_text(K), <<"'">> | Receiver])).

%% The name of the constructor of the receiver, found without calling code.
receiver_name(_O, 100) -> <<"Object">>;
receiver_name(O, Depth) ->
    case get_own(O, <<"constructor">>) of
        {data, C, _} when element(1, C) =:= '$f' ->
            case get_own(C, <<"name">>) of
                {data, Name, _} when is_binary(Name), Name =/= <<>> -> Name;
                _ -> <<"Object">>
            end;
        _ ->
            case prototype_of(O) of
                null -> <<"Object">>;
                P -> receiver_name(P, Depth + 1)
            end
    end.

%% [[OwnPropertyKeys]] (OrdinaryOwnPropertyKeys): indexes ascending, then
%% strings in insertion order, then symbols in insertion order. An array's
%% length is its first string key. Private names are not keys.
-spec own_keys(value()) -> [key()].
own_keys(O) ->
    case record_of(O) of
        {proxy, _, _, _, _, Handler} -> buoy_ref_proxy:own_keys(Handler);
        {deferred_namespace, _, _, _, _, M} = R -> ok = buoy_module:ensure_deferred(M), record_keys(R);
        {typed_array, _, _, _, _, _} = R -> buoy_ref_typed_array:index_keys(O) ++ record_keys(R);
        R -> record_keys(R)
    end.

%% The own keys of O without its integer indices, in the order of own_keys,
%% as V8's KeyAccumulator collects them with SKIP_INDICES: the elements of an
%% array or a typed array are never listed.
-spec own_named_keys(value()) -> [key()].
own_named_keys(O) ->
    case record_of(O) of
        {Class, _, _, Keys, _, _} when Class =/= proxy, Class =/= deferred_namespace ->
            Ordered = lists:reverse(Keys),
            [<<"length">> || Class =:= array] ++ [K || K <- Ordered, ?IS_STRING(K)] ++ [K || {'$sym', _, _} = K <- Ordered];
        _ ->
            [K || K <- own_keys(O), not is_integer(K)]
    end.

record_keys({Class, _, Props, Keys, _, Slots}) ->
    {Indexes, First} = case Class of
        array ->
            {_, Elements} = Slots,
            {lists:sort(maps:keys(Elements)), [<<"length">>]};
        _ ->
            {lists:sort([K || K <- maps:keys(Props), is_integer(K)]), []}
    end,
    Ordered = lists:reverse(Keys),
    Indexes ++ First ++ [K || K <- Ordered, ?IS_STRING(K)] ++ [K || {'$sym', _, _} = K <- Ordered].

%% The enumerable own string keys, for Object.keys, for-in, spread, and JSON.
-spec enumerable_keys(value()) -> [key()].
enumerable_keys(O) ->
    case record_of(O) of
        {proxy, _, _, _, _, _} ->
            [K || K <- own_keys(O), is_integer(K) orelse ?IS_STRING(K), is_enumerable(get_own(O, K))];
        %% Each key of a namespace reads its binding, as [[GetOwnProperty]] does.
        {Class, _, _, _, _, _} when Class =:= namespace; Class =:= deferred_namespace; Class =:= typed_array ->
            [K || K <- own_keys(O), is_integer(K) orelse ?IS_STRING(K), is_enumerable(get_own(O, K))];
        {Class, _, _, _, Attrs, _} = R ->
            [K || K <- record_keys(R), is_integer(K) orelse ?IS_STRING(K), enumerable(K, Attrs),
                  not (Class =:= array andalso K =:= <<"length">>)]
    end.

enumerable(K, Attrs) -> maps:get(K, Attrs, ?ALL) band ?ENUMERABLE =/= 0.

%% Whether a property from get_own/2 is enumerable; none is not.
-spec is_enumerable(property()) -> boolean().
is_enumerable({data, _, Bits}) -> Bits band ?ENUMERABLE =/= 0;
is_enumerable({accessor, _, _, Bits}) -> Bits band ?ENUMERABLE =/= 0;
is_enumerable(none) -> false.

%% Object.defineProperty for internal use: a descriptor map of value,
%% writable, enumerable, configurable, get, and set, where a missing
%% attribute of a new property is false. A failure throws a TypeError.
-spec define(value(), key(), map()) -> value().
define(O, K, Descriptor) ->
    case define_own_property(O, K, Descriptor) of
        true -> O;
        false -> define_failed(O, K)
    end.

-spec define_failed(value(), key()) -> no_return().
define_failed(O, K) ->
    Message = case record_of(O) of
        {proxy, _, _, _, _, _} ->
            text([<<"'defineProperty' on proxy: trap returned falsish for property '">>, key_text(K), <<"'">>]);
        R ->
            case own_of(R, K) of
                none -> text([<<"Cannot define property ">>, key_text(K), <<", object is not extensible">>]);
                _ -> text([<<"Cannot redefine property: ">>, key_text(K)])
            end
    end,
    throw_error('TypeError', Message).

%% A private name is no property: it takes its value whatever the object's state.
define_private(O, K, Desc) ->
    Slot = case is_accessor_descriptor(Desc) of
        true -> {'$accessor', maps:get(get, Desc, undefined), maps:get(set, Desc, undefined)};
        false -> maps:get(value, Desc, undefined)
    end,
    put_own(O, K, Slot, ?ALL),
    true.

%% [[DefineOwnProperty]]: true when the property now matches the descriptor.
-spec define_own_property(value(), key(), map()) -> boolean().
define_own_property(O, {'#', _, _} = K, Desc) ->
    define_private(O, K, Desc);
define_own_property(O, {'$sym', {private, _}, _} = K, Desc) ->
    define_private(O, K, Desc);
define_own_property(O, K, Desc) ->
    case record_of(O) of
        {namespace, _, _, _, _, _} ->
            buoy_module:define_namespace(O, K, Desc);
        {deferred_namespace, _, _, _, _, M} ->
            deferred_key(M, K),
            buoy_module:define_namespace(O, K, Desc);
        {typed_array, _, _, _, Attrs, _} = R ->
            case typed_index(K) of
                {index, N} -> buoy_ref_typed_array:element_define(O, N, Desc);
                none -> validate_and_apply(O, K, extensible(Attrs), Desc, own_of(R, K))
            end;
        {proxy, _, _, _, _, Handler} ->
            buoy_ref_proxy:define_own_property(Handler, K, Desc);
        {array, _, _, _, _, _} when K =:= <<"length">> ->
            array_set_length(O, Desc);
        {array, _, _, _, Attrs, {Length, _}} = R when is_integer(K), K >= Length ->
            case length_bits(Attrs) band ?WRITABLE of
                0 -> false;
                _ -> validate_and_apply(O, K, extensible(Attrs), Desc, own_of(R, K))
            end;
        {arguments, _, _, _, Attrs, Map} = R when is_map_key(K, Map) ->
            arguments_define(O, K, Desc, maps:get(K, Map), extensible(Attrs), own_of(R, K));
        {_, _, _, _, Attrs, _} = R ->
            validate_and_apply(O, K, extensible(Attrs), Desc, own_of(R, K))
    end.

%% ValidateAndApplyPropertyDescriptor (§10.1.6.3). With O undefined it only
%% validates: IsCompatiblePropertyDescriptor.
-spec validate_and_apply(value(), key(), boolean(), map(), property()) -> boolean().
validate_and_apply(_O, _K, false, _Desc, none) ->
    false;
validate_and_apply(undefined, _K, true, _Desc, none) ->
    true;
validate_and_apply(O, K, true, Desc, none) ->
    case is_accessor_descriptor(Desc) of
        true -> put_own(O, K, {'$accessor', maps:get(get, Desc, undefined), maps:get(set, Desc, undefined)}, merge_bits(Desc, 0));
        false -> put_own(O, K, maps:get(value, Desc, undefined), merge_bits(Desc, 0))
    end,
    true;
validate_and_apply(O, K, _Extensible, Desc, Current) ->
    case compatible(Desc, Current) of
        false ->
            false;
        true when O =:= undefined ->
            true;
        true ->
            apply_descriptor(O, K, Desc, Current),
            true
    end.

%% Whether Desc may change the property Current.
compatible(Desc, Current) ->
    Bits = current_bits(Current),
    case Bits band ?CONFIGURABLE of
        0 ->
            maps:get(configurable, Desc, false) =/= true
                andalso maps:get(enumerable, Desc, Bits band ?ENUMERABLE =/= 0) =:= (Bits band ?ENUMERABLE =/= 0)
                andalso fixed_compatible(Desc, Current);
        _ ->
            true
    end.

fixed_compatible(Desc, {accessor, G, S, _}) ->
    not is_data_descriptor(Desc)
        andalso maps:get(get, Desc, G) =:= G
        andalso maps:get(set, Desc, S) =:= S;
fixed_compatible(Desc, {data, V, Bits}) ->
    case is_accessor_descriptor(Desc) of
        true -> false;
        false when Bits band ?WRITABLE =:= 0 -> maps:get(writable, Desc, false) =/= true andalso maps:get(value, Desc, V) =:= V;
        false -> true
    end.

current_bits({data, _, Bits}) -> Bits;
current_bits({accessor, _, _, Bits}) -> Bits.

apply_descriptor(O, K, Desc, {data, V, Bits}) ->
    case is_accessor_descriptor(Desc) of
        true -> put_own(O, K, {'$accessor', maps:get(get, Desc, undefined), maps:get(set, Desc, undefined)}, merge_bits(Desc, Bits band (?ENUMERABLE bor ?CONFIGURABLE)));
        false -> put_own(O, K, maps:get(value, Desc, V), merge_bits(Desc, Bits))
    end;
apply_descriptor(O, K, Desc, {accessor, G, S, Bits}) ->
    case is_data_descriptor(Desc) of
        true -> put_own(O, K, maps:get(value, Desc, undefined), merge_bits(Desc, Bits band (?ENUMERABLE bor ?CONFIGURABLE)));
        false -> put_own(O, K, {'$accessor', maps:get(get, Desc, G), maps:get(set, Desc, S)}, merge_bits(Desc, Bits) band (bnot ?WRITABLE))
    end.

merge_bits(Desc, Bits) ->
    flag(writable, ?WRITABLE, Desc, Bits) bor flag(enumerable, ?ENUMERABLE, Desc, Bits) bor flag(configurable, ?CONFIGURABLE, Desc, Bits).

flag(Name, Bit, Desc, Bits) ->
    case maps:get(Name, Desc, Bits band Bit =/= 0) of
        true -> Bit;
        _ -> 0
    end.

-spec is_accessor_descriptor(map()) -> boolean().
is_accessor_descriptor(Desc) -> is_map_key(get, Desc) orelse is_map_key(set, Desc).

-spec is_data_descriptor(map()) -> boolean().
is_data_descriptor(Desc) -> is_map_key(value, Desc) orelse is_map_key(writable, Desc).

%% Writes the own property K with its value or accessor and its bits.
put_own(O, K, Slot, Bits) ->
    Id = id_for_write(O),
    {Class, P, Props, Keys, Attrs, Slots} = erlang:get(Id),
    case Class of
        array when is_integer(K) ->
            {Length, Elements} = Slots,
            erlang:put(Id, {array, P, Props, Keys, bits_into(K, Bits, ?ALL, Attrs), {max(K + 1, Length), Elements#{K => Slot}}});
        array when K =:= <<"length">> ->
            erlang:put(Id, {array, P, Props, Keys, bits_into(K, Bits, ?WRITABLE, Attrs), resize(Slots, Slot)});
        _ ->
            erlang:put(Id, {Class, P, Props#{K => Slot}, add_key(K, Props, Keys), bits_into(K, Bits, ?ALL, Attrs), Slots})
    end,
    ok.

bits_into(K, Default, Default, Attrs) -> maps:remove(K, Attrs);
bits_into(K, Bits, _Default, Attrs) -> Attrs#{K => Bits}.

length_bits(#{'$frozen' := true}) -> 0;
length_bits(Attrs) -> maps:get(<<"length">>, Attrs, ?WRITABLE).

%% ArraySetLength (§10.4.2.4). The coercion of the value runs user code, so
%% the current length property is read after it.
array_set_length(O, #{value := Value} = Desc) ->
    NewLength = buoy_ref_number:to_uint32(buoy_ref:to_number(Value)),
    NewLength == buoy_ref:to_number(Value) orelse throw_error('RangeError', <<"Invalid array length">>),
    Desc1 = Desc#{value := NewLength},
    {array, _, _, _, Attrs, {OldLength, _}} = record_of(O),
    Current = {data, OldLength, length_bits(Attrs)},
    case NewLength >= OldLength of
        true -> validate_and_apply(O, <<"length">>, true, Desc1, Current);
        false -> shrink(O, NewLength, Desc1, Current)
    end;
array_set_length(O, Desc) ->
    {array, _, _, _, Attrs, {OldLength, _}} = record_of(O),
    validate_and_apply(O, <<"length">>, true, Desc, {data, OldLength, length_bits(Attrs)}).

%% Deletes the elements from the end down to NewLength, and stops at one that
%% is not configurable.
shrink(_O, _NewLength, _Desc, {data, _, Bits}) when Bits band ?WRITABLE =:= 0 ->
    false;
shrink(O, NewLength, Desc, Current) ->
    case compatible(Desc#{writable => true}, Current) of
        false ->
            false;
        true ->
            Id = id_for_write(O),
            {array, P, Props, Keys, Attrs, {_, Elements}} = erlang:get(Id),
            Doomed = lists:reverse(lists:sort([I || I <- maps:keys(Elements), I >= NewLength])),
            {Final, Kept, Attrs1} = drop_elements(Doomed, NewLength, Elements, Attrs),
            LengthBits = case maps:get(writable, Desc, true) of
                false -> 0;
                _ -> ?WRITABLE
            end,
            erlang:put(Id, {array, P, Props, Keys, bits_into(<<"length">>, LengthBits, ?WRITABLE, Attrs1), {Final, Kept}}),
            Final =:= NewLength
    end.

drop_elements([], NewLength, Elements, Attrs) ->
    {NewLength, Elements, Attrs};
drop_elements([I | Rest], NewLength, Elements, Attrs) ->
    case own_bits(I, Attrs) band ?CONFIGURABLE of
        0 -> {I + 1, Elements, Attrs};
        _ -> drop_elements(Rest, NewLength, maps:remove(I, Elements), maps:remove(I, Attrs))
    end.

%% [[DefineOwnProperty]] of a mapped arguments object (§10.4.4.2) for the
%% index K that Cell maps.
arguments_define(O, K, Desc, Cell, Extensible, Current) ->
    Desc1 = case is_data_descriptor(Desc) andalso not is_map_key(value, Desc) andalso maps:get(writable, Desc, true) =:= false of
        true -> Desc#{value => cell_get(Cell)};
        false -> Desc
    end,
    case validate_and_apply(O, K, Extensible, Desc1, Current) of
        false ->
            false;
        true ->
            case is_accessor_descriptor(Desc) of
                true ->
                    unmap(O, K);
                false ->
                    _ = case Desc of
                        #{value := V} -> cell_set(Cell, V);
                        _ -> ok
                    end,
                    case maps:get(writable, Desc, true) of
                        false -> unmap(O, K);
                        _ -> ok
                    end
            end,
            true
    end.

unmap(O, K) ->
    Id = id_for_write(O),
    {arguments, P, Props, Keys, Attrs, Map} = erlang:get(Id),
    erlang:put(Id, {arguments, P, Props, Keys, Attrs, maps:remove(K, Map)}),
    ok.

%% [[GetOwnProperty]]: {data, Value, Bits}, {accessor, Get, Set, Bits}, or none.
-spec get_own(value(), key()) -> property().
get_own(O, K) ->
    case record_of(O) of
        {proxy, _, _, _, _, Handler} -> buoy_ref_proxy:get_own_property(Handler, K);
        {deferred_namespace, _, _, _, _, M} = R ->
            case deferred_key(M, K) of
                absent -> none;
                _ -> own_of(R, K)
            end;
        {typed_array, _, _, _, _, _} = R ->
            case typed_index(K) of
                {index, N} ->
                    case buoy_ref_typed_array:element_has(O, N) of
                        true -> {data, buoy_ref_typed_array:element_get(O, N), ?ALL};
                        false -> none
                    end;
                none -> own_of(R, K)
            end;
        R -> own_of(R, K)
    end.

own_of({array, _, _, _, Attrs, {_, Elements}}, K) when is_integer(K) ->
    found(maps:find(K, Elements), own_bits(K, Attrs));
own_of({array, _, _, _, Attrs, {Length, _}}, <<"length">>) ->
    {data, Length, length_bits(Attrs)};
own_of({arguments, _, _, _, Attrs, Map}, K) when is_map_key(K, Map) ->
    {data, cell_get(maps:get(K, Map)), own_bits(K, Attrs)};
own_of({_, _, Props, _, Attrs, _}, K) ->
    found(maps:find(K, Props), own_bits(K, Attrs)).

own_bits({'#', _, _}, _Attrs) -> ?ALL;
own_bits({'$sym', {private, _}, _}, _Attrs) -> ?ALL;
own_bits(K, #{'$frozen' := true} = Attrs) -> maps:get(K, Attrs, ?ALL) band ?ENUMERABLE;
own_bits(K, Attrs) -> maps:get(K, Attrs, ?ALL).

found({ok, {'$accessor', G, S}}, Bits) -> {accessor, G, S, Bits};
%% [[GetOwnProperty]] of a namespace reads the binding, which may be uninitialized.
found({ok, {'$live', Read}}, Bits) -> {data, Read(), Bits};
found({ok, V}, Bits) -> {data, V, Bits};
found(error, _Bits) -> none.

%% [[GetPrototypeOf]].
-spec prototype_of(value()) -> value().
prototype_of(O) ->
    case record_of(O) of
        {proxy, _, _, _, _, Handler} -> buoy_ref_proxy:get_prototype_of(Handler);
        R -> element(2, R)
    end.

%% Sets the prototype for internal use, without checks.
-spec set_prototype_of(value(), value()) -> value().
set_prototype_of(O, Proto) ->
    lists:member(class_of(O), [namespace, deferred_namespace]) andalso Proto =/= null andalso
        throw_error('TypeError', <<"Cannot set the prototype of a module namespace object">>),
    Id = id_for_write(O),
    erlang:put(Id, setelement(2, erlang:get(Id), Proto)),
    O.

%% [[SetPrototypeOf]] (OrdinarySetPrototypeOf): false for a non-extensible
%% object, a cycle, or a new prototype of Object.prototype.
-spec set_prototype(value(), value()) -> boolean().
set_prototype(O, Proto) ->
    case record_of(O) of
        {proxy, _, _, _, _, Handler} ->
            buoy_ref_proxy:set_prototype_of(Handler, Proto);
        {_, Proto, _, _, _, _} ->
            true;
        {_, _, _, _, Attrs, _} ->
            case not immutable_prototype(O) andalso extensible(Attrs) andalso not in_chain(Proto, O) of
                true -> _ = set_prototype_of(O, Proto), true;
                false -> false
            end
    end.

%% Object.prototype of every realm is an immutable prototype exotic object.
immutable_prototype({'$o', 'Object.prototype'}) -> true;
immutable_prototype({'$o', {_, 'Object.prototype'}}) -> true;
immutable_prototype(_) -> false.

in_chain(null, _O) -> false;
in_chain(O, O) -> true;
in_chain(P, O) ->
    case record_of(P) of
        {proxy, _, _, _, _, _} -> false;
        R -> in_chain(element(2, R), O)
    end.

%% [[IsExtensible]].
-spec is_extensible(value()) -> boolean().
is_extensible(O) ->
    case record_of(O) of
        {proxy, _, _, _, _, Handler} -> buoy_ref_proxy:is_extensible(Handler);
        {_, _, _, _, Attrs, _} -> extensible(Attrs)
    end.

%% [[PreventExtensions]].
-spec prevent_extensions(value()) -> boolean().
prevent_extensions(O) ->
    case record_of(O) of
        {proxy, _, _, _, _, Handler} ->
            buoy_ref_proxy:prevent_extensions(Handler);
        %% A typed array whose length can change stays extensible (§10.4.5.3).
        {typed_array, _, _, _, _, _} ->
            buoy_ref_typed_array:is_fixed_length(O) andalso ordinary_prevent_extensions(O);
        _ ->
            ordinary_prevent_extensions(O)
    end.

ordinary_prevent_extensions(O) ->
    Id = id_for_write(O),
    {Class, P, Props, Keys, Attrs, Slots} = erlang:get(Id),
    erlang:put(Id, {Class, P, Props, Keys, Attrs#{'$noext' => true}, Slots}),
    true.

%% Object.freeze of an ordinary object: one flag makes every property
%% read-only and non-configurable, and the object non-extensible.
-spec freeze(value()) -> value().
freeze(O) ->
    class_of(O) =:= namespace andalso own_keys(O) =/= [] andalso
        throw_error('TypeError', <<"Cannot freeze a module namespace object">>),
    Id = id_for_write(O),
    {Class, P, Props, Keys, Attrs, Slots} = erlang:get(Id),
    erlang:put(Id, {Class, P, Props, Keys, Attrs#{'$frozen' => true}, Slots}),
    O.

-spec is_frozen(value()) -> boolean().
is_frozen(O) ->
    {_, _, _, _, Attrs, _} = record_of(O),
    maps:get('$frozen', Attrs, false).

%% The private element P of O (buoy_ref_class): {ok, Slot} or error. Private
%% elements are not inherited, and a frozen object can still change them.
-spec private_find(value(), key()) -> {ok, term()} | error.
private_find(O, P) -> maps:find(P, element(3, record_of(O))).

-spec private_put(value(), key(), term()) -> ok.
private_put(O, P, Slot) ->
    Id = id_for_write(O),
    {Class, Proto, Props, Keys, Attrs, Slots} = record_of(O),
    erlang:put(Id, {Class, Proto, Props#{P => Slot}, Keys, Attrs, Slots}),
    ok.

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
record_of({'$f', _, _} = F) ->
    fn_record(F).

fn_record({'$f', Id, _} = F) ->
    case erlang:get(Id) of
        undefined when is_atom(Id) -> intrinsic_record(Id, F);
        undefined when is_tuple(Id) -> static_function_record(F);
        undefined -> {function, ?FUNCTION_PROTO, #{}, [], #{}, #{}};
        R -> R
    end.

%% A builtin function value is {'$f', {builtin, Name}, Fun}: the same term in
%% every process, so its identity holds, and it needs no allocation. Its twin
%% in the realm N > 0 is {'$f', {N, {builtin, Name}}, Fun1}, and Function.prototype
%% of that realm is {'$f', {N, 'Function.prototype'}, Fun}.
static_function_record({'$f', {N, _} = Id, _} = F) when is_integer(N) ->
    intrinsic_record(Id, F);
static_function_record({'$f', {builtin, Name} = Id, _}) ->
    case persistent_term:get({?MODULE, Id}, undefined) of
        undefined ->
            Short = lists:last(binary:split(Name, <<".">>, [global])),
            {function, {'$f', 'Function.prototype', fun buoy_ref_function:prototype_call/2}, #{<<"name">> => Short}, [<<"name">>], #{<<"name">> => ?CONFIGURABLE}, #{}};
        R ->
            R
    end;
%% A module-level normal function of sloppy code is {'$f', {fn, Module, Name,
%% Length, sloppy}, Fun}: it has the caller and arguments properties that V8
%% gives it, both null.
static_function_record({'$f', {fn, _Module, Name, Length, sloppy} = Id, _} = F) ->
    Proto = new_object(?OBJECT_PROTO),
    Props = #{<<"length">> => Length, <<"name">> => Name, <<"prototype">> => Proto, <<"arguments">> => null, <<"caller">> => null},
    Attrs = #{<<"length">> => ?CONFIGURABLE, <<"name">> => ?CONFIGURABLE, <<"prototype">> => ?WRITABLE, <<"arguments">> => 0, <<"caller">> => 0},
    Keys = [<<"prototype">>, <<"caller">>, <<"arguments">>, <<"name">>, <<"length">>],
    Record = {function, ?FUNCTION_PROTO, Props, Keys, Attrs, #{kind => normal}},
    erlang:put(Id, Record),
    define(Proto, <<"constructor">>, #{value => F, writable => true, enumerable => false, configurable => true}),
    Record;
%% A module-level function declaration is {'$f', {fn, Module, Name, Length}, Fun}.
%% Each realm makes its record, with a new prototype object, on first use.
static_function_record({'$f', {fn, _Module, Name, Length} = Id, _} = F) ->
    Proto = new_object(?OBJECT_PROTO),
    Props = #{<<"length">> => Length, <<"name">> => Name, <<"prototype">> => Proto},
    Attrs = #{<<"length">> => ?CONFIGURABLE, <<"name">> => ?CONFIGURABLE, <<"prototype">> => ?WRITABLE},
    Record = {function, ?FUNCTION_PROTO, Props, [<<"prototype">>, <<"name">>, <<"length">>], Attrs, #{kind => normal}},
    erlang:put(Id, Record),
    define(Proto, <<"constructor">>, #{value => F, writable => true, enumerable => false, configurable => true}),
    Record;
%% A generator, an async function, or a function that reads new.target.
static_function_record({'$f', {Form, Module, Name, Length} = Id, _} = F) ->
    Record = buoy_ref_generator:static_record(Form, Module, Name, Length, F),
    erlang:put(Id, Record),
    Record;
static_function_record(_F) ->
    {function, ?FUNCTION_PROTO, #{}, [], #{}, #{}}.

%% A static record {lazy, Module} is an intrinsic that each realm builds on
%% first use: Module:load(Id) puts its record in this realm and returns it.
intrinsic_record(Id, _O) when is_atom(Id) ->
    case persistent_term:get({?MODULE, Id}, ?EMPTY) of
        {lazy, Module} -> Module:load(Id);
        Record -> Record
    end;
%% The realm N > 0 copies the record of realm 0 on first use, with each
%% intrinsic in it replaced by its twin of realm N.
intrinsic_record({N, Base} = Id, _O) when is_integer(N) ->
    Static = case Base of
        {builtin, _} -> static_function_record({'$f', Base, undefined});
        _ -> intrinsic_record(Base, {'$o', Base})
    end,
    Record = buoy_ref_realm:localize(N, Static),
    erlang:put(Id, Record),
    Record;
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
id_for_write({'$f', Id, _} = F) ->
    case erlang:get(Id) of
        undefined -> erlang:put(Id, fn_record(F));
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

%% The current realm: 0 for the first realm of the process.
-spec realm() -> non_neg_integer().
realm() ->
    case erlang:get(?REALM_KEY) of
        undefined -> 0;
        N -> N
    end.

%% The intrinsic object Id of the current realm.
-spec intrinsic(atom()) -> value().
intrinsic(Id) ->
    case erlang:get(?REALM_KEY) of
        undefined -> {'$o', Id};
        N -> {'$o', {N, Id}}
    end.

%% The intrinsic Id of the realm N. Function.prototype is a function.
-spec intrinsic(non_neg_integer(), atom()) -> value().
intrinsic(0, 'Function.prototype') -> {'$f', 'Function.prototype', fun buoy_ref_function:prototype_call/2};
intrinsic(N, 'Function.prototype') -> {'$f', {N, 'Function.prototype'}, fun buoy_ref_function:prototype_call/2};
intrinsic(0, Id) -> {'$o', Id};
intrinsic(N, Id) -> {'$o', {N, Id}}.

%% Function.prototype of the current realm.
-spec function_prototype() -> value().
function_prototype() -> intrinsic(realm(), 'Function.prototype').

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

-spec private_symbol(binary()) -> {'$sym', {private, integer()}, binary()}.
private_symbol(Description) -> {'$sym', {private, erlang:unique_integer()}, Description}.

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
to_key(K) when ?IS_STRING(K) -> K;
to_key({'$sym', _, _} = K) -> K;
to_key(F) when is_float(F), F >= 0, F =< ?MAX_INDEX, F == trunc(F) -> trunc(F);
to_key(K) -> buoy_ref:to_string(K).

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
key_text(K) when ?IS_STRING(K) -> K;
key_text({'$sym', _, undefined}) -> <<"Symbol()">>;
key_text({'$sym', _, Description}) -> text([<<"Symbol(">>, Description, <<")">>]);
key_text({'#', _, Name}) -> text([<<"#">>, Name]).

%% A message from strings of the engine.
text(Parts) -> buoy_ref_string:concat(Parts).

describe({'$f', _, _}) -> <<"function">>;
describe({'$o', _}) -> <<"object">>;
describe(V) -> buoy_ref:describe(V).

%%% Errors

%% An error object of the intrinsic class Name, such as 'TypeError'.
-spec error_object(atom() | value(), binary(), binary()) -> value().
error_object(Name, Message, Stack) when is_atom(Name) ->
    error_object(intrinsic(list_to_atom(atom_to_list(Name) ++ ".prototype")), Message, Stack);
error_object(Proto, Message, Stack) ->
    Props = #{<<"message">> => Message, <<"stack">> => Stack},
    Attrs = #{<<"message">> => ?WRITABLE bor ?CONFIGURABLE, <<"stack">> => ?WRITABLE bor ?CONFIGURABLE},
    Id = next_id(),
    erlang:put(Id, {error, Proto, Props, [<<"message">>, <<"stack">>], Attrs, none}),
    {'$o', Id}.

-spec throw_error(atom(), binary()) -> no_return().
throw_error(Name, Message) ->
    Stack = text([atom_to_binary(Name), <<": ">>, Message, <<"\n    at <buoy>">>]),
    %% BUOY_NODE_DEBUG keeps the Erlang stack of the last error (buoy_node).
    persistent_term:get({buoy_node, debug}, false) andalso
        erlang:put('$buoy_last_throw', {Message, element(2, process_info(self(), current_stacktrace))}),
    erlang:error({'$throw', error_object(Name, Message, Stack)}).

%%% Garbage collection

%% Marks from every pdict entry whose key is not an integer and from Roots,
%% then erases every integer key that marking did not reach. The caller's
%% stack must hold no heap reference that Roots leaves out.
-spec gc([term()]) -> #{live := non_neg_integer(), freed := non_neg_integer(), us := non_neg_integer()}.
gc(Roots) ->
    Start = erlang:monotonic_time(microsecond),
    {Ids, Others} = lists:partition(fun erlang:is_integer/1, erlang:get_keys()),
    {Live0, Chunks0, Weak0} = mark([erlang:get(K) || K <- Others] ++ Roots, #{}, 0, []),
    {Live, Chunks, Weak} = ephemerons(Live0, Chunks0, Weak0),
    clear_weak(Weak, Chunks),
    Freed = sweep(Ids, Chunks, 0),
    %% The data of a dropped buffer is an atomics array that only BEAM's own
    %% collection of this process frees.
    external() >= 1048576 andalso erlang:garbage_collect(),
    erlang:erase(?EXTERNAL),
    Us = erlang:monotonic_time(microsecond) - Start,
    Stats = #{live => Live, freed => Freed, us => Us},
    {Runs, Total, Max} = case erlang:get(?STATS) of
        undefined -> {0, 0, 0};
        #{runs := R, total_us := T, max_us := M} -> {R, T, M}
    end,
    erlang:put(?STATS, Stats#{runs => Runs + 1, total_us => Total + Us, max_us => max(Max, Us), at => allocated()}),
    size_heap(Live),
    Stats.

%% Bytes that the realm allocated outside the heap since the last
%% collection, such as the data of ArrayBuffers: V8's external memory, which
%% paces collection next to the ids, since one id can hold a large buffer.
-spec add_external(non_neg_integer()) -> ok.
add_external(Bytes) ->
    erlang:put(?EXTERNAL, external() + Bytes),
    ok.

-spec external() -> non_neg_integer().
external() ->
    case erlang:get(?EXTERNAL) of
        undefined -> 0;
        N -> N
    end.

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

%% Weak collects the ids of the weak containers that marking reaches: their
%% keys and targets are not marked through them (ephemerons/3).
mark([], Chunks, Live, Weak) ->
    {Live, Chunks, Weak};
mark([{'$o', Id} | Rest], Chunks, Live, Weak) when is_integer(Id) ->
    case first_mark(Id, Chunks) of
        {true, Chunks1} ->
            {Terms, Weak1} = record_terms(erlang:get(Id), Id, Rest, Weak),
            mark(Terms, Chunks1, Live + 1, Weak1);
        {false, Chunks1} ->
            mark(Rest, Chunks1, Live, Weak)
    end;
mark([{'$f', Id, Fun} | Rest], Chunks, Live, Weak) when is_integer(Id) ->
    case first_mark(Id, Chunks) of
        {true, Chunks1} ->
            {Terms, Weak1} = record_terms(erlang:get(Id), Id, [Fun | Rest], Weak),
            mark(Terms, Chunks1, Live + 1, Weak1);
        {false, Chunks1} ->
            mark(Rest, Chunks1, Live, Weak)
    end;
mark([{'$f', _, Fun} | Rest], Chunks, Live, Weak) ->
    mark([Fun | Rest], Chunks, Live, Weak);
mark([{'$c', Id} | Rest], Chunks, Live, Weak) when is_integer(Id) ->
    case first_mark(Id, Chunks) of
        {true, Chunks1} -> mark([erlang:get(Id) | Rest], Chunks1, Live + 1, Weak);
        {false, Chunks1} -> mark(Rest, Chunks1, Live, Weak)
    end;
mark([T | Rest], Chunks, Live, Weak) when is_tuple(T) ->
    mark(tuple_to_list(T) ++ Rest, Chunks, Live, Weak);
mark([[H | T] | Rest], Chunks, Live, Weak) ->
    mark([H, T | Rest], Chunks, Live, Weak);
mark([M | Rest], Chunks, Live, Weak) when is_map(M) ->
    mark(maps:fold(fun(K, V, Acc) -> [K, V | Acc] end, Rest, M), Chunks, Live, Weak);
mark([F | Rest], Chunks, Live, Weak) when is_function(F) ->
    {env, Env} = erlang:fun_info(F, env),
    mark(Env ++ Rest, Chunks, Live, Weak);
mark([_ | Rest], Chunks, Live, Weak) ->
    mark(Rest, Chunks, Live, Weak).

%% The terms of a record that can hold references: the prototype, the
%% values, and the slots. Keys and attributes hold none. A weak container
%% gives only what it holds strongly: a registry's callback and held values.
record_terms({Class, Proto, Props, _, _, Slots}, Id, Rest, Weak)
  when Class =:= weakmap; Class =:= weakset; Class =:= weak_ref; Class =:= finalization_registry ->
    Strong = case {Class, Slots} of
        {finalization_registry, {Cleanup, Cells}} -> [Cleanup | [Held || {_, Held, _} <- Cells]];
        _ -> []
    end,
    {[Proto | Strong ++ maps:values(Props) ++ Rest], [Id | Weak]};
record_terms({_, Proto, Props, _, _, Slots}, _Id, Rest, Weak) ->
    {[Proto, Slots | maps:values(Props) ++ Rest], Weak};
record_terms(_, _Id, Rest, Weak) ->
    {Rest, Weak}.

%% Marks the value of each WeakMap entry whose key is live, until no new
%% object becomes live: the ephemeron semantics of ECMA-262 §9.10.3.
ephemerons(Live, Chunks, Weak) ->
    Values = [V || Id <- Weak, {weakmap, _, _, _, _, Entries} <- [erlang:get(Id)],
                   K := V <- Entries, live_key(K, Chunks)],
    case mark(Values, Chunks, Live, Weak) of
        {Live, Chunks1, Weak} -> {Live, Chunks1, Weak};
        {Live1, Chunks1, Weak1} -> ephemerons(Live1, Chunks1, Weak1)
    end.

%% Whether a weak key or target survives: an object or a function that
%% marking reached, or a value that the collector never frees, such as an
%% intrinsic or a symbol.
live_key({'$o', Id}, Chunks) when is_integer(Id) -> is_marked(Id, Chunks);
live_key({'$f', Id, _}, Chunks) when is_integer(Id) -> is_marked(Id, Chunks);
live_key(_, _Chunks) -> true.

%% Drops the entries of dead keys, empties the WeakRefs of dead targets, and
%% queues the cleanup callback of each registry cell whose target died.
clear_weak(Weak, Chunks) ->
    lists:foreach(fun(Id) -> clear_container(Id, erlang:get(Id), Chunks) end, lists:usort(Weak)).

clear_container(Id, {Class, P, Props, Keys, Attrs, Entries}, Chunks) when Class =:= weakmap; Class =:= weakset ->
    Kept = maps:filter(fun(K, _) -> live_key(K, Chunks) end, Entries),
    map_size(Kept) =:= map_size(Entries) orelse erlang:put(Id, {Class, P, Props, Keys, Attrs, Kept}),
    ok;
clear_container(Id, {weak_ref, P, Props, Keys, Attrs, Target}, Chunks) ->
    live_key(Target, Chunks) orelse erlang:put(Id, {weak_ref, P, Props, Keys, Attrs, undefined}),
    ok;
clear_container(Id, {finalization_registry, P, Props, Keys, Attrs, {Cleanup, Cells}}, Chunks) ->
    {Kept, Dead} = lists:partition(fun({Target, _, _}) -> live_key(Target, Chunks) end, Cells),
    case Dead of
        [] ->
            ok;
        _ ->
            erlang:put(Id, {finalization_registry, P, Props, Keys, Attrs, {Cleanup, Kept}}),
            [buoy_jobs:enqueue(fun() -> call(Cleanup, undefined, [Held]) end) || {_, Held, _} <- Dead],
            ok
    end;
clear_container(_Id, _Record, _Chunks) ->
    ok.

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

%% clone_out with the host objects of an embedder, such as the MessagePorts
%% and the JS transferables of Node's postMessage: Hook(Object) returns none
%% for an ordinary object, or {host, Tag, Data}, whose Data clones with the
%% rest of the value and reaches the Hook of clone_in/2 as {Tag, Clone}.
-spec clone_out(value(), fun((value()) -> none | {host, term(), value()})) -> term().
clone_out(Value, Hook) ->
    Old = erlang:put(?CLONE_HOOK, Hook),
    try clone_out(Value)
    after restore_hook(Old)
    end.

-spec clone_in(term(), fun(({term(), value()}) -> value())) -> value().
clone_in(Term, Hook) ->
    Old = erlang:put(?CLONE_HOOK, Hook),
    try clone_in(Term)
    after restore_hook(Old)
    end.

restore_hook(undefined) -> erlang:erase(?CLONE_HOOK);
restore_hook(Old) -> erlang:put(?CLONE_HOOK, Old).

out({'$o', Id} = O, Seen) ->
    case Seen of
        #{Id := N} ->
            {{'$back', N}, Seen};
        _ ->
            N = map_size(Seen),
            case host_out(O) of
                none ->
                    out_record(record_of(O), O, N, Seen#{Id => N});
                {host, Tag, Data} ->
                    {DataTerm, Seen1} = out(Data, Seen#{Id => N}),
                    {{'$host', N, Tag, DataTerm}, Seen1}
            end
    end;
out({'$f', _, _} = F, _Seen) ->
    throw_error('DataCloneError', text([buoy_ref:to_string(F), <<" could not be cloned.">>]));
out({'$sym', _, _} = S, _Seen) ->
    throw_error('DataCloneError', text([key_text(S), <<" could not be cloned.">>]));
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
out_record({Class, _, _, _, _, Primitive}, _O, N, Seen) when Class =:= number; Class =:= string; Class =:= boolean; Class =:= bigint ->
    {{'$wrapper', N, Class, Primitive}, Seen};
out_record({array_buffer, _, _, _, _, {detached, _, _}}, _O, _N, _Seen) ->
    throw_error('DataCloneError', <<"An ArrayBuffer is detached and could not be cloned.">>);
out_record({array_buffer, _, _, _, _, {_, Length, Max}}, O, N, Seen) ->
    {{'$array_buffer', N, buoy_ref_buffer:read(O, 0, Length), Max}, Seen};
out_record({shared_array_buffer, _, _, _, _, Slots}, _O, N, Seen) ->
    %% A SharedArrayBuffer shares its atomics array with the receiving realm.
    {{'$shared_array_buffer', N, Slots}, Seen};
out_record({typed_array, _, _, _, _, {Kind, Buffer, Offset, Length}}, _O, N, Seen) ->
    {BufferTerm, Seen1} = out(Buffer, Seen),
    {{'$typed_array', N, Kind, BufferTerm, Offset, Length}, Seen1};
out_record({data_view, _, _, _, _, {Buffer, Offset, Length}}, _O, N, Seen) ->
    {BufferTerm, Seen1} = out(Buffer, Seen),
    {{'$data_view', N, BufferTerm, Offset, Length}, Seen1};
out_record({regexp, _, _, _, _, #{source := Source, flags := Flags}}, _O, N, Seen) ->
    {{'$regexp', N, Source, Flags}, Seen};
out_record({error, _, _, _, _, _}, O, N, Seen) ->
    Name = value_text(get(O, <<"name">>)),
    {{'$error', N, Name, value_text(get(O, <<"message">>)), value_text(get(O, <<"stack">>))}, Seen};
out_record({object, _, _, _, _, _}, O, N, Seen) ->
    Pairs = [{K, get(O, K)} || K <- enumerable_keys(O)],
    {Items, Seen1} = out_pairs(Pairs, Seen),
    {{'$object', N, Items}, Seen1};
out_record({Class, _, _, _, _, _}, _O, _N, _Seen) ->
    throw_error('DataCloneError', <<"#<", (atom_to_binary(Class))/binary, "> could not be cloned.">>).

host_out(O) ->
    case erlang:get(?CLONE_HOOK) of
        undefined -> none;
        Hook -> Hook(O)
    end.

value_text(undefined) -> <<>>;
value_text(V) -> buoy_ref:to_string(V).

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
in({'$host', N, Tag, DataTerm}, Made) ->
    {Data, Made1} = in(DataTerm, Made),
    O = (erlang:get(?CLONE_HOOK))({Tag, Data}),
    {O, Made1#{N => O}};
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
in({'$wrapper', N, Class, Primitive}, Made) ->
    Proto = case Class of
        number -> {'$o', 'Number.prototype'};
        string -> {'$o', 'String.prototype'};
        boolean -> {'$o', 'Boolean.prototype'};
        bigint -> {'$o', 'BigInt.prototype'}
    end,
    O = case Class of
        string -> buoy_ref_string:wrap(Primitive, Proto);
        _ -> new_exotic(Class, Proto, Primitive)
    end,
    {O, Made#{N => O}};
in({'$array_buffer', N, Bytes, Max}, Made) ->
    O = buoy_ref_buffer:allocate(byte_size(Bytes), Max),
    buoy_ref_buffer:write(O, 0, Bytes),
    {O, Made#{N => O}};
in({'$shared_array_buffer', N, Slots}, Made) ->
    O = new_exotic(shared_array_buffer, {'$o', 'SharedArrayBuffer.prototype'}, Slots),
    {O, Made#{N => O}};
in({'$typed_array', N, Kind, BufferTerm, Offset, Length}, Made) ->
    {Buffer, Made1} = in(BufferTerm, Made),
    Proto = {'$o', binary_to_atom(<<(buoy_ref_buffer:kind_name(Kind))/binary, ".prototype">>)},
    O = new_exotic(typed_array, Proto, {Kind, Buffer, Offset, Length}),
    {O, Made1#{N => O}};
in({'$data_view', N, BufferTerm, Offset, Length}, Made) ->
    {Buffer, Made1} = in(BufferTerm, Made),
    O = new_exotic(data_view, {'$o', 'DataView.prototype'}, {Buffer, Offset, Length}),
    {O, Made1#{N => O}};
in({'$date', N, Ms}, Made) ->
    O = new_exotic(date, {'$o', 'Date.prototype'}, Ms),
    {O, Made#{N => O}};
in({'$regexp', N, Source, Flags}, Made) ->
    O = buoy_ref_regexp:literal(Source, Flags),
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
