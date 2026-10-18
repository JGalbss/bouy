%% The Array family: the Array constructor, its statics, Array.prototype,
%% and the array iterators.
%%
%% Each method follows its algorithm in the specification over any object:
%% it reads the length with LengthOfArrayLike, tests holes with HasProperty,
%% and writes with Set, CreateDataPropertyOrThrow, and DeletePropertyOrThrow.
%% So the methods work on array-likes, see the changes that a callback makes
%% while they run, and create their results through ArraySpeciesCreate.
-module(buoy_ref_array).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).
-export([length_of/1, to_length/1, is_array/1, is_constructor/1, array_create/1, create_property/3, iterator/2, step/1]).

-import(buoy_ref_realm, [arg/2, rest/2, record/4, ctor_record/5, callable/1]).
-import(buoy_ref, [type_error/1]).

-define(MAX_LENGTH, 9007199254740991).
-define(MAX_ARRAY, 4294967295).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Methods = ?METHODS(<<"Array.prototype">>, array_methods()),
    {_, Values} = lists:keyfind(<<"values">>, 1, Methods),
    Unscopables = record(object, null, [{N, true, 7} || N <- unscopables()], none),
    [{'Array.prototype', record(array, ?OBJECT_PROTO, Methods ++ [{<<"constructor">>, constructor()}, {?SYM(iterator), Values}, {?SYM(unscopables), {'$o', 'Array.prototype[Symbol.unscopables]'}, 4}], {0, #{}})},
     {'Array.prototype[Symbol.unscopables]', Unscopables},
     {'ArrayIterator.prototype', record(object, ?ITERATOR_PROTO, ?METHODS(<<"ArrayIterator.prototype">>, [{<<"next">>, 0}]) ++ [{?SYM(toStringTag), <<"Array Iterator">>, 4}], none)},
     {{builtin, <<"Array">>}, ctor_record(<<"Array">>, 1, {'$o', 'Array.prototype'}, ?METHODS(<<"Array">>, [{<<"isArray">>, 1}, {<<"from">>, 1}, {<<"fromAsync">>, 1}, {<<"of">>, 0}]) ++ [{?SYM(species), species_getter(), 4}], fun construct/2)}].

%% get Array[Symbol.species]: this.
species_getter() ->
    {'$accessor', buoy_ref_realm:builtin(<<"get Array[Symbol.species]">>, <<"get [Symbol.species]">>, 0, fun(This, _) -> This end), undefined}.

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Array">>, constructor()}].

constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Array">>).

unscopables() ->
    [<<"at">>, <<"copyWithin">>, <<"entries">>, <<"fill">>, <<"find">>, <<"findIndex">>, <<"findLast">>, <<"findLastIndex">>,
     <<"flat">>, <<"flatMap">>, <<"includes">>, <<"keys">>, <<"toReversed">>, <<"toSorted">>, <<"toSpliced">>, <<"values">>].

array_methods() ->
    [{<<"at">>, 1}, {<<"concat">>, 1}, {<<"copyWithin">>, 2}, {<<"entries">>, 0}, {<<"every">>, 1}, {<<"fill">>, 1},
     {<<"filter">>, 1}, {<<"find">>, 1}, {<<"findIndex">>, 1}, {<<"findLast">>, 1}, {<<"findLastIndex">>, 1}, {<<"flat">>, 0},
     {<<"flatMap">>, 1}, {<<"forEach">>, 1}, {<<"includes">>, 1}, {<<"indexOf">>, 1}, {<<"join">>, 1}, {<<"keys">>, 0},
     {<<"lastIndexOf">>, 1}, {<<"map">>, 1}, {<<"pop">>, 0}, {<<"push">>, 1}, {<<"reduce">>, 1}, {<<"reduceRight">>, 1},
     {<<"reverse">>, 0}, {<<"shift">>, 0}, {<<"slice">>, 2}, {<<"some">>, 1}, {<<"sort">>, 1}, {<<"splice">>, 2},
     {<<"toLocaleString">>, 0}, {<<"toReversed">>, 0}, {<<"toSorted">>, 1}, {<<"toSpliced">>, 2}, {<<"toString">>, 0},
     {<<"unshift">>, 1}, {<<"values">>, 0}, {<<"with">>, 2}].

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"Array">>, _This, Args) -> construct(constructor(), Args).

%% The Array constructor, with the prototype of NewTarget.
construct(NewTarget, Args) ->
    Proto = buoy_ref_realm:proto_for(NewTarget, 'Array.prototype'),
    case Args of
        [Len] when ?IS_NUMBER(Len) ->
            case buoy_ref_number:to_uint32(Len) of
                L when L == Len ->
                    A = buoy_heap:new_array([], Proto),
                    buoy_heap:set(A, <<"length">>, L),
                    A;
                _ -> invalid_length()
            end;
        _ -> buoy_heap:new_array(Args, Proto)
    end.

-spec invalid_length() -> no_return().
invalid_length() -> buoy_heap:throw_error('RangeError', <<"Invalid array length">>).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Array.prototype">>, <<"sort">>, This, Args) ->
    Compare = comparator(arg(1, Args)),
    O = object(This, <<"sort">>),
    sort(O, Compare);
method(<<"Array.prototype">>, <<"toSorted">>, This, Args) ->
    Compare = comparator(arg(1, Args)),
    O = object(This, <<"toSorted">>),
    Len = length_of(O),
    A = array_create(Len),
    Sorted = sort_values(values(O, 0, Len - 1), Compare),
    [create_property(A, K, V) || {K, V} <- lists:enumerate(0, Sorted)],
    A;
method(<<"Array.prototype">>, Name, This, Args) ->
    O = object(This, Name),
    proto(Name, O, Args);
method(<<"Array">>, Name, This, Args) -> static(Name, This, Args);
method(<<"ArrayIterator.prototype">>, <<"next">>, This, _Args) -> iterator_next(This).

%% ToObject of this, with the name of the method in the error.
object(V, Name) when V =:= undefined; V =:= null ->
    type_error(<<"Array.prototype.", Name/binary, " called on null or undefined">>);
object(V, _Name) -> buoy_ref:to_object(V).

%%% Abstract operations

%% LengthOfArrayLike.
-spec length_of(term()) -> non_neg_integer().
length_of(O) ->
    case O of
        {'$o', _} ->
            case buoy_heap:class_of(O) of
                array -> buoy_heap:array_length(O);
                _ -> to_length(buoy_ref:get(O, <<"length">>))
            end;
        _ -> to_length(buoy_ref:get(O, <<"length">>))
    end.

%% ToLength.
-spec to_length(term()) -> non_neg_integer().
to_length(V) ->
    case buoy_ref_number:to_integer_or_infinity(buoy_ref:to_number(V)) of
        'Infinity' -> ?MAX_LENGTH;
        I when is_integer(I), I > ?MAX_LENGTH -> ?MAX_LENGTH;
        I when is_integer(I), I > 0 -> I;
        _ -> 0
    end.

%% IsArray sees through a proxy (buoy_ref_object).
-spec is_array(term()) -> boolean().
is_array(V) -> buoy_ref_object:is_array(V).

%% IsConstructor: a function with a [[Construct]].
-spec is_constructor(term()) -> boolean().
is_constructor({'$f', _, _} = F) ->
    case buoy_heap:slots(F) of
        #{construct := _} -> true;
        #{kind := normal} -> true;
        _ -> false
    end;
is_constructor(_) -> false.

%% ArrayCreate with %Array.prototype%.
-spec array_create(non_neg_integer()) -> term().
array_create(Len) when Len > ?MAX_ARRAY -> invalid_length();
array_create(Len) ->
    A = buoy_heap:new_array([]),
    Len > 0 andalso buoy_heap:set(A, <<"length">>, Len),
    A.

%% ArraySpeciesCreate.
species_create(O, Len) ->
    case species(O, Len) of
        {fresh, A} -> A;
        {object, A} -> A
    end.

%% ArraySpeciesCreate, and whether the result is a new array of %Array%:
%% {fresh, A}, which no user code can reach until the method returns, so
%% the method may write its elements at once, or {object, A}.
species(O, Len) ->
    case is_array(O) of
        false -> {fresh, array_create(Len)};
        true ->
            C = case buoy_ref:get(O, <<"constructor">>) of
                C0 when ?IS_OBJECT(C0) ->
                    case foreign_array(C0) orelse buoy_ref:get(C0, ?SYM(species)) of
                        true -> undefined;
                        null -> undefined;
                        S -> S
                    end;
                C0 -> C0
            end,
            Array = buoy_ref_realm:current(constructor()),
            case C of
                undefined -> {fresh, array_create(Len)};
                Array -> {fresh, array_create(Len)};
                _ ->
                    is_constructor(C) orelse type_error(<<"object.constructor[Symbol.species] is not a constructor">>),
                    {object, buoy_ref:construct(C, [Len])}
            end
    end.

%% Whether C is %Array% of a realm other than the current one, which
%% ArraySpeciesCreate replaces with the current realm's.
foreign_array(C) ->
    case C =:= constructor() of
        true ->
            buoy_heap:realm() =/= 0;
        false ->
            buoy_heap:is_constructor(C) andalso
                begin
                    Realm = buoy_ref_realm:function_realm(C),
                    Realm =/= buoy_heap:realm() andalso Realm =/= 0 andalso C =:= buoy_ref_realm:localize(Realm, constructor())
                end
    end.

%% Writes the elements of a fresh array at once.
commit(A, Length, Pairs) ->
    buoy_heap:set_slots(A, {Length, maps:from_list(Pairs)}),
    A.

%% Folds F over the indexes below Len that the object has, with their values.
fold_present(O, Len, F, Acc) -> fold_present(O, 0, Len, F, Acc).

fold_present(_O, K, Len, _F, Acc) when K >= Len -> Acc;
fold_present(O, K, Len, F, Acc) ->
    Acc1 = case el(O, K) of
        {ok, V} -> F(K, V, Acc);
        none -> Acc
    end,
    fold_present(O, K + 1, Len, F, Acc1).

%% The property key of an index: an array index, or the string of a larger
%% integer.
key(K) when K =< 4294967294 -> K;
key(K) -> integer_to_binary(K).

get(O, K) -> buoy_ref:get(O, key(K)).

has(O, K) -> buoy_heap:has(O, key(K)).

%% HasProperty then Get in one step: {ok, Value}, or none for a missing
%% index. An own data element of an array takes one read of its record.
el({'$o', Id} = O, K) when is_integer(Id) ->
    case erlang:get(Id) of
        {array, _, _, _, _, {_, #{K := V}}} when not (is_tuple(V) andalso tuple_size(V) =:= 3 andalso element(1, V) =:= '$accessor') -> {ok, V};
        _ -> el_slow(O, K)
    end;
el(O, K) -> el_slow(O, K).

el_slow(O, K) ->
    case has(O, K) of
        true -> {ok, get(O, K)};
        false -> none
    end.

%% Get alone, with the same fast path.
value_at({'$o', Id} = O, K) when is_integer(Id) ->
    case erlang:get(Id) of
        {array, _, _, _, _, {_, #{K := V}}} when not (is_tuple(V) andalso tuple_size(V) =:= 3 andalso element(1, V) =:= '$accessor') -> V;
        _ -> get(O, K)
    end;
value_at(O, K) -> get(O, K).

set(O, K, V) -> buoy_ref:set(O, key(K), V).

set_length(O, Len) -> buoy_ref:set(O, <<"length">>, Len).

delete(O, K) -> buoy_heap:delete(O, key(K)).

%% CreateDataPropertyOrThrow.
-spec create_property(term(), non_neg_integer(), term()) -> term().
create_property({'$o', Id} = A, K, V) when is_integer(Id), is_integer(K), K =< 4294967294 ->
    %% An array with no attributes has no fixed element and is extensible, so
    %% CreateDataPropertyOrThrow is a plain write of the element.
    case erlang:get(Id) of
        {array, P, Props, Keys, Attrs, {Length, Elements}} when map_size(Attrs) =:= 0 ->
            erlang:put(Id, {array, P, Props, Keys, Attrs, {max(Length, K + 1), Elements#{K => V}}}),
            A;
        _ -> create_slow(A, K, V)
    end;
create_property(A, K, V) -> create_slow(A, K, V).

create_slow(A, K, V) ->
    buoy_heap:define(A, key(K), #{value => V, writable => true, enumerable => true, configurable => true}).

%% Calls F with each index from From up to To, or down to To: a loop, so a
%% length near 2^53 costs nothing until F runs.
up(From, To, _F) when From > To -> ok;
up(From, To, F) ->
    F(From),
    up(From + 1, To, F).

down(From, To, _F) when From < To -> ok;
down(From, To, F) ->
    F(From),
    down(From - 1, To, F).

%% Folds over the indexes From up to To.
fold_up(From, To, _F, Acc) when From > To -> Acc;
fold_up(From, To, F, Acc) -> fold_up(From + 1, To, F, F(From, Acc)).

%% The values at the indexes From up to To, holes read through.
values(O, From, To) -> lists:reverse(fold_up(From, To, fun(K, Acc) -> [value_at(O, K) | Acc] end, [])).

%% ToIntegerOrInfinity of an argument.
integer(V) -> buoy_ref_number:to_integer_or_infinity(buoy_ref:to_number(V)).

%% A relative index argument clamped to [0, Len].
relative(V, Len) ->
    case integer(V) of
        '-Infinity' -> 0;
        'Infinity' -> Len;
        I when I < 0 -> max(Len + I, 0);
        I -> min(I, Len)
    end.

relative_end(undefined, Len) -> Len;
relative_end(V, Len) -> relative(V, Len).

-spec too_long() -> no_return().
too_long() -> type_error(<<"Invalid array length: the result exceeds 2^53 - 1">>).

%%% Array.prototype

proto(<<"at">>, O, Args) ->
    Len = length_of(O),
    K = case integer(arg(1, Args)) of
        I when is_integer(I), I >= 0 -> I;
        I when is_integer(I) -> Len + I;
        _ -> -1
    end,
    case K >= 0 andalso K < Len of
        true -> get(O, K);
        false -> undefined
    end;
proto(<<"concat">>, O, Args) ->
    case species(O, 0) of
        {fresh, A} ->
            {N, Pairs} = lists:foldl(fun concat_pairs/2, {0, []}, [O | Args]),
            commit(A, N, Pairs);
        {object, A} ->
            N = lists:foldl(fun(E, N0) -> concat_item(A, E, N0) end, 0, [O | Args]),
            set_length(A, N),
            A
    end;
proto(<<"copyWithin">>, O, Args) ->
    Len = length_of(O),
    To = relative(arg(1, Args), Len),
    From = relative(arg(2, Args), Len),
    Final = relative_end(arg(3, Args), Len),
    Count = min(Final - From, Len - To),
    case From < To andalso To < From + Count of
        true -> copy_within(O, From + Count - 1, To + Count - 1, -1, Count);
        false -> copy_within(O, From, To, 1, Count)
    end,
    O;
proto(<<"entries">>, O, _) -> iterator(O, entries);
proto(<<"keys">>, O, _) -> iterator(O, keys);
proto(<<"values">>, O, _) -> iterator(O, values);
proto(<<"every">>, O, Args) ->
    Len = length_of(O),
    F = callable(arg(1, Args)),
    every(O, F, arg(2, Args), 0, Len);
proto(<<"some">>, O, Args) ->
    Len = length_of(O),
    F = callable(arg(1, Args)),
    some(O, F, arg(2, Args), 0, Len);
proto(<<"forEach">>, O, Args) ->
    Len = length_of(O),
    F = callable(arg(1, Args)),
    This = arg(2, Args),
    each(O, Len, fun(K, V) -> buoy_ref:call(F, This, [V, K, O]) end),
    undefined;
proto(<<"map">>, O, Args) ->
    Len = length_of(O),
    F = callable(arg(1, Args)),
    This = arg(2, Args),
    case species(O, Len) of
        {fresh, A} ->
            commit(A, Len, fold_present(O, Len, fun(K, V, Acc) -> [{K, buoy_ref:call(F, This, [V, K, O])} | Acc] end, []));
        {object, A} ->
            each(O, Len, fun(K, V) -> create_property(A, K, buoy_ref:call(F, This, [V, K, O])) end),
            A
    end;
proto(<<"filter">>, O, Args) ->
    Len = length_of(O),
    F = callable(arg(1, Args)),
    This = arg(2, Args),
    case species(O, 0) of
        {fresh, A} ->
            Kept = fold_present(O, Len, fun(K, V, Acc) ->
                                               case buoy_ref:truthy(buoy_ref:call(F, This, [V, K, O])) of
                                                   true -> [V | Acc];
                                                   false -> Acc
                                               end
                                       end, []),
            commit(A, length(Kept), lists:enumerate(0, lists:reverse(Kept)));
        {object, A} ->
            filter(O, F, This, A, 0, Len, 0),
            A
    end;
proto(<<"fill">>, O, Args) ->
    Len = length_of(O),
    V = arg(1, Args),
    K = relative(arg(2, Args), Len),
    Final = relative_end(arg(3, Args), Len),
    up(K, Final - 1, fun(I) -> set(O, I, V) end),
    O;
proto(<<"find">>, O, Args) -> find(O, Args, forward, value);
proto(<<"findIndex">>, O, Args) -> find(O, Args, forward, index);
proto(<<"findLast">>, O, Args) -> find(O, Args, backward, value);
proto(<<"findLastIndex">>, O, Args) -> find(O, Args, backward, index);
proto(<<"flat">>, O, Args) ->
    Len = length_of(O),
    Depth = case arg(1, Args) of
        undefined -> 1;
        D ->
            case integer(D) of
                '-Infinity' -> 0;
                I when is_integer(I), I < 0 -> 0;
                I -> I
            end
    end,
    A = species_create(O, 0),
    flatten_into(A, O, Len, 0, Depth, none),
    A;
proto(<<"flatMap">>, O, Args) ->
    Len = length_of(O),
    F = callable(arg(1, Args)),
    A = species_create(O, 0),
    flatten_into(A, O, Len, 0, 1, {F, arg(2, Args)}),
    A;
proto(<<"includes">>, O, Args) ->
    Len = length_of(O),
    case Len of
        0 -> false;
        _ ->
            case integer(arg(2, Args)) of
                'Infinity' -> false;
                N ->
                    Search = arg(1, Args),
                    includes(O, Search, start_index(N, Len), Len)
            end
    end;
proto(<<"indexOf">>, O, Args) ->
    Len = length_of(O),
    case Len of
        0 -> -1;
        _ ->
            case integer(arg(2, Args)) of
                'Infinity' -> -1;
                N -> index_of(O, arg(1, Args), start_index(N, Len), Len)
            end
    end;
proto(<<"lastIndexOf">>, O, Args) ->
    Len = length_of(O),
    case Len of
        0 -> -1;
        _ ->
            N = case Args of
                [_, From | _] -> integer(From);
                _ -> Len - 1
            end,
            K = case N of
                '-Infinity' -> -1;
                'Infinity' -> Len - 1;
                _ when N >= 0 -> min(N, Len - 1);
                _ -> Len + N
            end,
            last_index_of(O, arg(1, Args), K)
    end;
proto(<<"join">>, O, Args) ->
    Len = length_of(O),
    Sep = case arg(1, Args) of
        undefined -> <<",">>;
        S -> buoy_ref:to_string(S)
    end,
    guarded(O, fun() -> join(O, Len, Sep, fun join_text/1) end);
proto(<<"toLocaleString">>, O, _Args) ->
    Len = length_of(O),
    guarded(O, fun() -> join(O, Len, <<",">>, fun locale_text/1) end);
proto(<<"toString">>, O, _Args) ->
    case buoy_ref:get(O, <<"join">>) of
        {'$f', _, _} = Join -> buoy_ref:call(Join, O, []);
        _ -> object_to_string(O)
    end;
proto(<<"pop">>, O, _) ->
    case length_of(O) of
        0 ->
            set_length(O, 0),
            undefined;
        Len ->
            V = get(O, Len - 1),
            delete(O, Len - 1),
            set_length(O, Len - 1),
            V
    end;
proto(<<"push">>, O, Items) ->
    case fast_array(O) of
        true -> buoy_heap:array_push(O, Items);
        false ->
            Len = length_of(O),
            Len + length(Items) > ?MAX_LENGTH andalso too_long(),
            End = lists:foldl(fun(V, K) -> set(O, K, V), K + 1 end, Len, Items),
            set_length(O, End),
            End
    end;
proto(<<"reduce">>, O, Args) ->
    Len = length_of(O),
    F = callable(arg(1, Args)),
    reduce(O, F, Args, 0, Len - 1, 1);
proto(<<"reduceRight">>, O, Args) ->
    Len = length_of(O),
    F = callable(arg(1, Args)),
    reduce(O, F, Args, Len - 1, 0, -1);
proto(<<"reverse">>, O, _) ->
    Len = length_of(O),
    reverse(O, 0, Len - 1),
    O;
proto(<<"shift">>, O, _) ->
    case length_of(O) of
        0 ->
            set_length(O, 0),
            undefined;
        Len ->
            First = get(O, 0),
            move(O, 1, Len - 1, -1),
            delete(O, Len - 1),
            set_length(O, Len - 1),
            First
    end;
proto(<<"unshift">>, O, Items) ->
    Len = length_of(O),
    Count = length(Items),
    case Count of
        0 -> ok;
        _ ->
            Len + Count > ?MAX_LENGTH andalso too_long(),
            down(Len, 1, fun(K) ->
                                 case has(O, K - 1) of
                                     true -> set(O, K + Count - 1, get(O, K - 1));
                                     false -> delete(O, K + Count - 1)
                                 end
                         end),
            [set(O, J, V) || {J, V} <- lists:enumerate(0, Items)]
    end,
    set_length(O, Len + Count),
    Len + Count;
proto(<<"slice">>, O, Args) ->
    Len = length_of(O),
    K = relative(arg(1, Args), Len),
    Final = relative_end(arg(2, Args), Len),
    Count = max(Final - K, 0),
    case species(O, Count) of
        {fresh, A} ->
            {N, Pairs} = fold_up(K, Final - 1, fun(I, {N0, Acc}) ->
                                                       case el(O, I) of
                                                           {ok, V} -> {N0 + 1, [{N0, V} | Acc]};
                                                           none -> {N0 + 1, Acc}
                                                       end
                                               end, {0, []}),
            commit(A, N, Pairs);
        {object, A} ->
            N = fold_up(K, Final - 1, fun(I, N0) ->
                                              case el(O, I) of
                                                  {ok, V} -> create_property(A, N0, V);
                                                  none -> ok
                                              end,
                                              N0 + 1
                                      end, 0),
            set_length(A, N),
            A
    end;
proto(<<"splice">>, O, Args) ->
    Len = length_of(O),
    Start = case Args of
        [] -> 0;
        [S | _] -> relative(S, Len)
    end,
    Items = rest(3, Args),
    DeleteCount = case Args of
        [] -> 0;
        [_] -> Len - Start;
        [_, DC | _] -> bound(integer(DC), 0, Len - Start)
    end,
    ItemCount = length(Items),
    Len + ItemCount - DeleteCount > ?MAX_LENGTH andalso too_long(),
    A = species_create(O, DeleteCount),
    up(0, DeleteCount - 1, fun(K) ->
                                   case has(O, Start + K) of
                                       true -> create_property(A, K, get(O, Start + K));
                                       false -> ok
                                   end
                           end),
    set_length(A, DeleteCount),
    if
        ItemCount < DeleteCount ->
            move(O, Start + DeleteCount, Len - 1, ItemCount - DeleteCount),
            down(Len, Len - DeleteCount + ItemCount + 1, fun(K) -> delete(O, K - 1) end);
        ItemCount > DeleteCount ->
            down(Len - DeleteCount, Start + 1, fun(K) ->
                                                       case has(O, K + DeleteCount - 1) of
                                                           true -> set(O, K + ItemCount - 1, get(O, K + DeleteCount - 1));
                                                           false -> delete(O, K + ItemCount - 1)
                                                       end
                                               end);
        true -> ok
    end,
    [set(O, Start + J, V) || {J, V} <- lists:enumerate(0, Items)],
    set_length(O, Len - DeleteCount + ItemCount),
    A;
proto(<<"toReversed">>, O, _) ->
    Len = length_of(O),
    A = array_create(Len),
    up(0, Len - 1, fun(K) -> create_property(A, K, get(O, Len - K - 1)) end),
    A;
proto(<<"toSpliced">>, O, Args) ->
    Len = length_of(O),
    Start = case Args of
        [] -> 0;
        [S | _] -> relative(S, Len)
    end,
    Items = rest(3, Args),
    Skip = case Args of
        [] -> 0;
        [_] -> Len - Start;
        [_, SC | _] -> bound(integer(SC), 0, Len - Start)
    end,
    NewLen = Len + length(Items) - Skip,
    NewLen > ?MAX_LENGTH andalso too_long(),
    A = array_create(NewLen),
    Before = values(O, 0, Start - 1),
    After = values(O, Start + Skip, Len - 1),
    [create_property(A, K, V) || {K, V} <- lists:enumerate(0, Before ++ Items ++ After)],
    A;
proto(<<"with">>, O, Args) ->
    Len = length_of(O),
    Index = case integer(arg(1, Args)) of
        I when is_integer(I), I >= 0 -> I;
        I when is_integer(I) -> Len + I;
        _ -> -1
    end,
    Index >= 0 andalso Index < Len orelse
        buoy_heap:throw_error('RangeError', buoy_ref_string:concat(<<"Invalid index : ">>, buoy_ref:to_string(buoy_ref:to_number(arg(1, Args))))),
    A = array_create(Len),
    V = arg(2, Args),
    up(0, Len - 1, fun(K) -> create_property(A, K, case K of Index -> V; _ -> get(O, K) end) end),
    A.

bound('-Infinity', Low, _High) -> Low;
bound('Infinity', _Low, High) -> High;
bound(I, Low, High) -> min(max(I, Low), High).

start_index('-Infinity', _Len) -> 0;
start_index(N, _Len) when N >= 0 -> N;
start_index(N, Len) -> max(Len + N, 0).

%% A plain array whose push needs no generic steps.
fast_array({'$o', _} = O) -> buoy_heap:class_of(O) =:= array;
fast_array(_) -> false.

object_to_string(O) -> buoy_ref_object:method(<<"Object.prototype">>, <<"toString">>, O, []).

%% Calls F for each index below Len that the object has, with its value.
each(O, Len, F) -> each(O, 0, Len, F).

each(_O, K, Len, _F) when K >= Len -> ok;
each(O, K, Len, F) ->
    case el(O, K) of
        {ok, V} -> F(K, V);
        none -> ok
    end,
    each(O, K + 1, Len, F).

filter(_O, _F, _This, _A, K, Len, _To) when K >= Len -> ok;
filter(O, F, This, A, K, Len, To) ->
    case el(O, K) of
        {ok, V} ->
            case buoy_ref:truthy(buoy_ref:call(F, This, [V, K, O])) of
                true ->
                    create_property(A, To, V),
                    filter(O, F, This, A, K + 1, Len, To + 1);
                false -> filter(O, F, This, A, K + 1, Len, To)
            end;
        none -> filter(O, F, This, A, K + 1, Len, To)
    end.

every(_O, _F, _This, K, Len) when K >= Len -> true;
every(O, F, This, K, Len) ->
    Stop = case el(O, K) of
        {ok, V} -> not buoy_ref:truthy(buoy_ref:call(F, This, [V, K, O]));
        none -> false
    end,
    case Stop of
        true -> false;
        false -> every(O, F, This, K + 1, Len)
    end.

some(_O, _F, _This, K, Len) when K >= Len -> false;
some(O, F, This, K, Len) ->
    Found = case el(O, K) of
        {ok, V} -> buoy_ref:truthy(buoy_ref:call(F, This, [V, K, O]));
        none -> false
    end,
    case Found of
        true -> true;
        false -> some(O, F, This, K + 1, Len)
    end.

find(O, Args, Direction, What) ->
    Len = length_of(O),
    F = callable(arg(1, Args)),
    This = arg(2, Args),
    case Direction of
        forward -> find_in(O, F, This, What, 0, Len, 1);
        backward -> find_in(O, F, This, What, Len - 1, -1, -1)
    end.

find_in(_O, _F, _This, value, K, End, _Step) when K =:= End -> undefined;
find_in(_O, _F, _This, index, K, End, _Step) when K =:= End -> -1;
find_in(O, F, This, What, K, End, Step) ->
    V = value_at(O, K),
    case buoy_ref:truthy(buoy_ref:call(F, This, [V, K, O])) of
        true when What =:= value -> V;
        true -> K;
        false -> find_in(O, F, This, What, K + Step, End, Step)
    end.

includes(_O, _Search, K, Len) when K >= Len -> false;
includes(O, Search, K, Len) ->
    case same_value_zero(value_at(O, K), Search) of
        true -> true;
        false -> includes(O, Search, K + 1, Len)
    end.

same_value_zero(A, B) when is_number(A), is_number(B) -> A == B;
same_value_zero(A, B) -> A =:= B.

index_of(_O, _Search, K, Len) when K >= Len -> -1;
index_of(O, Search, K, Len) ->
    case matches(el(O, K), Search) of
        true -> K;
        false -> index_of(O, Search, K + 1, Len)
    end.

matches({ok, V}, Search) -> buoy_ref:strict_eq(V, Search);
matches(none, _Search) -> false.

last_index_of(_O, _Search, K) when K < 0 -> -1;
last_index_of(O, Search, K) ->
    case matches(el(O, K), Search) of
        true -> K;
        false -> last_index_of(O, Search, K - 1)
    end.

%% reduce and reduceRight over the indexes From to To, by Step.
reduce(O, F, Args, From, To, Step) ->
    {Acc0, Start} = case Args of
        [_, Init | _] -> {Init, From};
        _ -> first_present(O, From, To, Step)
    end,
    reduce_steps(O, F, Start, To, Step, Acc0).

reduce_steps(_O, _F, K, To, Step, Acc) when (Step > 0 andalso K > To); (Step < 0 andalso K < To) -> Acc;
reduce_steps(O, F, K, To, Step, Acc) ->
    Acc1 = case el(O, K) of
        {ok, V} -> buoy_ref:call(F, undefined, [Acc, V, K, O]);
        none -> Acc
    end,
    reduce_steps(O, F, K + Step, To, Step, Acc1).

first_present(_O, K, To, Step) when (Step > 0 andalso K > To); (Step < 0 andalso K < To) ->
    type_error(<<"Reduce of empty array with no initial value">>);
first_present(O, K, To, Step) ->
    case el(O, K) of
        {ok, V} -> {V, K + Step};
        none -> first_present(O, K + Step, To, Step)
    end.

reverse(O, Lower, Upper) when Lower < Upper ->
    LowerExists = has(O, Lower),
    LowerValue = case LowerExists of
        true -> get(O, Lower);
        false -> undefined
    end,
    UpperExists = has(O, Upper),
    UpperValue = case UpperExists of
        true -> get(O, Upper);
        false -> undefined
    end,
    case {LowerExists, UpperExists} of
        {true, true} -> set(O, Lower, UpperValue), set(O, Upper, LowerValue);
        {false, true} -> set(O, Lower, UpperValue), delete(O, Upper);
        {true, false} -> delete(O, Lower), set(O, Upper, LowerValue);
        {false, false} -> ok
    end,
    reverse(O, Lower + 1, Upper - 1);
reverse(_O, _Lower, _Upper) -> ok.

%% Moves the elements From..To by Shift, in the order that keeps the source
%% intact: ascending for a shift down, descending for a shift up.
move(O, From, To, Shift) ->
    Move = fun(K) ->
                   case has(O, K) of
                       true -> set(O, K + Shift, get(O, K));
                       false -> delete(O, K + Shift)
                   end
           end,
    case Shift < 0 of
        true -> up(From, To, Move);
        false -> down(To, From, Move)
    end.

copy_within(_O, _From, _To, _Direction, Count) when Count =< 0 -> ok;
copy_within(O, From, To, Direction, Count) ->
    case has(O, From) of
        true -> set(O, To, get(O, From));
        false -> delete(O, To)
    end,
    copy_within(O, From + Direction, To + Direction, Direction, Count - 1).

concat_item(A, E, N) ->
    case is_spreadable(E) of
        true ->
            Len = length_of(E),
            N + Len > ?MAX_LENGTH andalso too_long(),
            up(0, Len - 1, fun(K) ->
                                   case el(E, K) of
                                       {ok, V} -> create_property(A, N + K, V);
                                       none -> ok
                                   end
                           end),
            N + Len;
        false ->
            N >= ?MAX_LENGTH andalso too_long(),
            create_property(A, N, E),
            N + 1
    end.

%% concat into a fresh array: {NextIndex, Pairs}.
concat_pairs(E, {N, Acc}) ->
    case is_spreadable(E) of
        true ->
            Len = length_of(E),
            N + Len > ?MAX_LENGTH andalso too_long(),
            {N + Len, fold_present(E, Len, fun(K, V, Pairs) -> [{N + K, V} | Pairs] end, Acc)};
        false ->
            N >= ?MAX_LENGTH andalso too_long(),
            {N + 1, [{N, E} | Acc]}
    end.

is_spreadable(E) when ?IS_OBJECT(E) ->
    case buoy_ref:get(E, ?SYM(isConcatSpreadable)) of
        undefined -> is_array(E);
        V -> buoy_ref:truthy(V)
    end;
is_spreadable(_) -> false.

%% FlattenIntoArray: the next target index.
flatten_into(Target, Source, Len, Start, Depth, Mapper) ->
    fold_up(0, Len - 1, fun(K, TargetIndex) ->
                        case has(Source, K) of
                            false -> TargetIndex;
                            true ->
                                V0 = get(Source, K),
                                V = case Mapper of
                                    none -> V0;
                                    {F, This} -> buoy_ref:call(F, This, [V0, K, Source])
                                end,
                                case (Depth =:= 'Infinity' orelse Depth > 0) andalso is_array(V) of
                                    true ->
                                        Next = case Depth of
                                            'Infinity' -> 'Infinity';
                                            _ -> Depth - 1
                                        end,
                                        flatten_into(Target, V, length_of(V), TargetIndex, Next, none);
                                    false ->
                                        TargetIndex >= ?MAX_LENGTH andalso too_long(),
                                        create_property(Target, TargetIndex, V),
                                        TargetIndex + 1
                                end
                        end
                end, Start).

%% join and toLocaleString return "" for an array that they are already
%% joining, as V8 does, so a cycle ends.
guarded(O, Join) ->
    Stack = case erlang:get('$buoy_join') of
        undefined -> [];
        S -> S
    end,
    case lists:member(O, Stack) of
        true -> <<>>;
        false ->
            erlang:put('$buoy_join', [O | Stack]),
            try Join()
            after erlang:put('$buoy_join', Stack)
            end
    end.

join(O, Len, Sep, Text) ->
    Parts = lists:reverse(fold_up(0, Len - 1, fun(K, Acc) -> [Text(value_at(O, K)) | Acc] end, [])),
    buoy_ref_string:concat(lists:join(Sep, Parts)).

join_text(undefined) -> <<>>;
join_text(null) -> <<>>;
join_text(V) -> buoy_ref:to_string(V).

locale_text(undefined) -> <<>>;
locale_text(null) -> <<>>;
locale_text(V) -> buoy_ref:to_string(buoy_ref:call_method(V, <<"toLocaleString">>, [])).

%%% Sorting

comparator(undefined) -> undefined;
comparator(F) ->
    buoy_heap:is_callable(F) orelse type_error(<<"The comparison function must be either a function or undefined">>),
    F.

%% SortIndexedProperties with holes skipped, then the writes back.
sort(O, Compare) ->
    Len = length_of(O),
    Present = lists:reverse(fold_up(0, Len - 1, fun(K, Acc) ->
                                                          case has(O, K) of
                                                              true -> [get(O, K) | Acc];
                                                              false -> Acc
                                                          end
                                                  end, [])),
    Sorted = sort_values(Present, Compare),
    Count = length(Sorted),
    [set(O, K, V) || {K, V} <- lists:enumerate(0, Sorted)],
    up(Count, Len - 1, fun(K) -> delete(O, K) end),
    O.

%% Undefined values go last; the rest sort by the comparator, or by their
%% strings.
sort_values(Values, Compare) ->
    {Defined, Undefined} = lists:partition(fun(V) -> V =/= undefined end, Values),
    Sorted = case Compare of
        undefined ->
            Keyed = [{buoy_ref:to_string(V), V} || V <- Defined],
            [V || {_, V} <- lists:sort(fun({X, _}, {Y, _}) -> buoy_ref_string:compare(X, Y) =/= gt end, Keyed)];
        F ->
            buoy_sort:sort(Defined, fun(CallArgs) -> buoy_ref:to_number(buoy_ref:call(F, undefined, CallArgs)) end)
    end,
    Sorted ++ Undefined.

%%% Array iterators

%% CreateArrayIterator: a live iterator over the indexes of O.
-spec iterator(term(), keys | values | entries) -> term().
iterator(O, Kind) -> buoy_heap:new_exotic(array_iterator, {'$o', 'ArrayIterator.prototype'}, {O, 0, Kind}).

iterator_next(It) ->
    ?IS_OBJECT(It) andalso buoy_heap:class_of(It) =:= array_iterator orelse
        type_error(<<"next method called on incompatible receiver">>),
    case step(It) of
        {value, V} -> buoy_ref_iterator:result(V, false);
        done -> buoy_ref_iterator:result(undefined, true)
    end.

%% The next value of an array iterator: {value, V}, or done.
-spec step(term()) -> {value, term()} | done.
step(It) ->
    case buoy_heap:slots(It) of
        done -> done;
        {O, Index, Kind} ->
            Len = iterated_length(O),
            case Index < Len of
                false ->
                    buoy_heap:set_slots(It, done),
                    done;
                true ->
                    buoy_heap:set_slots(It, {O, Index + 1, Kind}),
                    {value, case Kind of
                                keys -> Index;
                                values -> get(O, Index);
                                entries -> buoy_heap:new_array([Index, get(O, Index)])
                            end}
            end
    end.

iterated_length(O) ->
    case ?IS_OBJECT(O) andalso buoy_heap:class_of(O) of
        typed_array -> buoy_ref_typed_array:iterated_length(O);
        _ -> length_of(O)
    end.

%%% Array statics

static_sync(<<"isArray">>, _This, Args) -> is_array(arg(1, Args));
static_sync(<<"of">>, C, Items) ->
    Len = length(Items),
    A = case is_constructor(C) of
        true -> buoy_ref:construct(C, [Len]);
        false -> array_create(Len)
    end,
    [create_property(A, K, V) || {K, V} <- lists:enumerate(0, Items)],
    set_length(A, Len),
    A;
static_sync(<<"from">>, C, Args) ->
    Items = arg(1, Args),
    Mapper = case arg(2, Args) of
        undefined -> none;
        F ->
            buoy_heap:is_callable(F) orelse type_error(buoy_ref_string:concat(buoy_ref:describe(F), <<" is not a function">>)),
            {F, arg(3, Args)}
    end,
    case iterator_method(Items) of
        undefined -> from_array_like(C, buoy_ref:to_object(Items), Mapper);
        Method -> from_iterable(C, Items, Method, Mapper)
    end.

%% Array.fromAsync: an async function over an async iterator, a sync
%% iterator whose values it awaits, or an array-like, with each step in a
%% later microtask. Each continuation catches its own errors, because an
%% await reaction has no promise to reject.
static(<<"fromAsync">>, C, Args) ->
    buoy_jobs:async_call(fun(Resolve, Reject) -> from_async(C, Args, Resolve, Reject) end);
static(Name, C, Args) -> static_sync(Name, C, Args).

from_async(C, Args, Resolve, Reject) ->
    Items = arg(1, Args),
    Mapper = case arg(2, Args) of
        undefined -> none;
        F ->
            buoy_heap:is_callable(F) orelse type_error(buoy_ref_string:concat(buoy_ref:describe(F), <<" is not a function">>)),
            {F, arg(3, Args)}
    end,
    (Items =:= undefined orelse Items =:= null) andalso type_error(<<"Array.fromAsync requires an array-like or iterable object">>),
    Ctx0 = #{constructor => C, mapper => Mapper, resolve => Resolve, reject => Reject},
    case method_of(Items, ?SYM(asyncIterator)) of
        undefined ->
            case method_of(Items, ?SYM(iterator)) of
                undefined ->
                    O = buoy_ref:to_object(Items),
                    Len = length_of(O),
                    A = case is_constructor(C) of
                        true -> buoy_ref:construct(C, [Len]);
                        false -> array_create(Len)
                    end,
                    like_step(Ctx0#{a => A, source => O, length => Len}, 0);
                Method -> start_iteration(Ctx0, Items, Method, sync)
            end;
        Method -> start_iteration(Ctx0, Items, Method, async)
    end.

%% GetMethod: undefined for undefined or null, else a callable.
method_of(V, K) ->
    case buoy_ref:get(V, K) of
        M when M =:= undefined; M =:= null -> undefined;
        M -> callable(M)
    end.

start_iteration(Ctx, Items, Method, Kind) ->
    Iterator = buoy_ref:call(Method, Items, []),
    ?IS_OBJECT(Iterator) orelse type_error(<<"Result of the Symbol.iterator method is not an object">>),
    Next = buoy_ref:get(Iterator, <<"next">>),
    A = case is_constructor(maps:get(constructor, Ctx)) of
        true -> buoy_ref:construct(maps:get(constructor, Ctx), []);
        false -> array_create(0)
    end,
    iterator_step(Ctx#{a => A, iterator => Iterator, next => Next, kind => Kind}, 0).

%% Runs Step, and rejects the promise of fromAsync when it throws, after
%% closing the iterator when Close is true.
attempt(#{reject := Reject} = Ctx, Close, Step) ->
    try Step()
    catch
        error:Reason:Stack ->
            Error = buoy_ref:caught(Reason, Stack),
            case Close of
                true -> close_async(Ctx, fun() -> Reject(Error) end);
                false -> Reject(Error)
            end
    end.

%% AsyncIteratorClose with a throw completion: the return method runs, its
%% result is awaited for an async iterator, and the first error wins.
close_async(#{iterator := Iterator, kind := Kind}, Then) ->
    try buoy_ref:get(Iterator, <<"return">>) of
        R when R =:= undefined; R =:= null -> Then();
        Return ->
            try buoy_ref:call(Return, Iterator, []) of
                Result when Kind =:= async -> buoy_jobs:await(Result, fun(_) -> Then() end, fun(_) -> Then() end);
                _ -> Then()
            catch
                error:_ -> Then()
            end
    catch
        error:_ -> Then()
    end.

iterator_step(#{iterator := Iterator, next := Next, kind := Kind, reject := Reject} = Ctx, K) ->
    attempt(Ctx, false, fun() ->
        K >= ?MAX_LENGTH andalso type_error(<<"Invalid array length: the result exceeds 2^53 - 1">>),
        Result = buoy_ref:call(Next, Iterator, []),
        case Kind of
            async -> buoy_jobs:await(Result, fun(R) -> attempt(Ctx, false, fun() -> iterator_result(Ctx, K, R) end) end, Reject);
            sync -> iterator_result(Ctx, K, Result)
        end
    end).

iterator_result(#{kind := Kind, reject := Reject} = Ctx, K, Result) ->
    ?IS_OBJECT(Result) orelse type_error(buoy_ref_string:concat([<<"Iterator result ">>, buoy_ref:describe(Result), <<" is not an object">>])),
    case buoy_ref:truthy(buoy_ref:get(Result, <<"done">>)) of
        true -> finish(Ctx, K);
        false ->
            Value = buoy_ref:get(Result, <<"value">>),
            case Kind of
                async -> map_value(Ctx, K, Value);
                sync ->
                    %% The async-from-sync iterator awaits each value, and closes the
                    %% sync iterator when the value rejects.
                    buoy_jobs:await(Value, fun(V) -> map_value(Ctx, K, V) end,
                                    fun(E) -> close_async(Ctx, fun() -> Reject(E) end) end)
            end
    end.

map_value(#{mapper := none} = Ctx, K, V) -> define_next(Ctx, K, V);
map_value(#{mapper := {F, This}} = Ctx, K, V) ->
    attempt(Ctx, true, fun() ->
        Mapped = buoy_ref:call(F, This, [V, K]),
        buoy_jobs:await(Mapped, fun(M) -> define_next(Ctx, K, M) end,
                        fun(E) -> close_async(Ctx, fun() -> (maps:get(reject, Ctx))(E) end) end)
    end).

define_next(#{a := A} = Ctx, K, V) ->
    attempt(Ctx, true, fun() ->
        create_property(A, K, V),
        iterator_step(Ctx, K + 1)
    end).

finish(#{a := A, resolve := Resolve} = Ctx, K) ->
    attempt(Ctx, false, fun() ->
        set_length(A, K),
        Resolve(A)
    end).

%% The array-like form: each value, then each mapped value, is awaited.
like_step(#{length := Len} = Ctx, K) when K >= Len -> finish(Ctx, Len);
like_step(#{source := O, reject := Reject} = Ctx, K) ->
    attempt(Ctx, false, fun() ->
        buoy_jobs:await(get(O, K), fun(V) -> like_map(Ctx, K, V) end, Reject)
    end).

like_map(#{mapper := Mapper, a := A, reject := Reject} = Ctx, K, V) ->
    attempt(Ctx, false, fun() ->
        case Mapper of
            none ->
                create_property(A, K, V),
                like_step(Ctx, K + 1);
            {F, This} ->
                buoy_jobs:await(buoy_ref:call(F, This, [V, K]),
                                fun(M) -> attempt(Ctx, false, fun() -> create_property(A, K, M), like_step(Ctx, K + 1) end) end,
                                Reject)
        end
    end).

iterator_method(V) when V =:= undefined; V =:= null -> undefined;
iterator_method(V) ->
    case buoy_ref:get(V, ?SYM(iterator)) of
        M when M =:= undefined; M =:= null -> undefined;
        M -> callable(M)
    end.

from_array_like(C, O, Mapper) ->
    Len = length_of(O),
    case fresh_constructor(C) of
        true ->
            A = array_create(Len),
            Pairs = fold_up(0, Len - 1, fun(K, Acc) -> [{K, mapped(Mapper, value_at(O, K), K)} | Acc] end, []),
            commit(A, Len, Pairs);
        false ->
            A = buoy_ref:construct(C, [Len]),
            up(0, Len - 1, fun(K) -> create_property(A, K, mapped(Mapper, get(O, K), K)) end),
            set_length(A, Len),
            A
    end.

%% Whether Array.from and Array.of make a new array of %Array%: this is not
%% a constructor, or is %Array% itself.
fresh_constructor(C) -> C =:= constructor() orelse not is_constructor(C).

mapped(none, V, _K) -> V;
mapped({F, This}, V, K) -> buoy_ref:call(F, This, [V, K]).

from_iterable(C, Items, Method, Mapper) ->
    Fresh = fresh_constructor(C),
    A = case Fresh of
        false -> buoy_ref:construct(C, []);
        true -> array_create(0)
    end,
    Iterator = buoy_ref:call(Method, Items, []),
    ?IS_OBJECT(Iterator) orelse type_error(<<"Result of the Symbol.iterator method is not an object">>),
    Next = buoy_ref:get(Iterator, <<"next">>),
    Step = stepper(Iterator, Next),
    case Fresh of
        true ->
            %% No user code can reach a new array of %Array% yet, so the
            %% elements go in at once.
            {Len, Pairs} = from_pairs(Step, Iterator, Mapper, 0, []),
            commit(A, Len, Pairs);
        false ->
            Len = from_steps(A, Step, Iterator, Mapper, 0),
            set_length(A, Len),
            A
    end.

%% The step of an iterator: the native step of a builtin iterator whose next
%% method is the intrinsic one, else IteratorStepValue.
stepper(Iterator, Next) ->
    Native = case {buoy_heap:class_of(Iterator), Next} of
        {array_iterator, {'$f', {builtin, <<"ArrayIterator.prototype.next">>}, _}} -> ?MODULE;
        {map_iterator, {'$f', {builtin, <<"MapIterator.prototype.next">>}, _}} -> buoy_ref_collection;
        {set_iterator, {'$f', {builtin, <<"SetIterator.prototype.next">>}, _}} -> buoy_ref_collection;
        {string_iterator, {'$f', {builtin, <<"StringIterator.prototype.next">>}, _}} -> buoy_ref_string;
        _ -> none
    end,
    case Native of
        none -> fun() -> step_value(Iterator, Next) end;
        Module -> fun() -> Module:step(Iterator) end
    end.

step_value(Iterator, Next) ->
    Result = buoy_ref:call(Next, Iterator, []),
    ?IS_OBJECT(Result) orelse type_error(buoy_ref_string:concat([<<"Iterator result ">>, buoy_ref:describe(Result), <<" is not an object">>])),
    case buoy_ref:truthy(buoy_ref:get(Result, <<"done">>)) of
        true -> done;
        false -> {value, buoy_ref:get(Result, <<"value">>)}
    end.

from_steps(A, Step, Iterator, Mapper, K) ->
    case Step() of
        done -> K;
        {value, V} ->
            closing(Iterator, fun() ->
                                      K >= ?MAX_LENGTH andalso too_long(),
                                      create_property(A, K, mapped(Mapper, V, K))
                              end),
            from_steps(A, Step, Iterator, Mapper, K + 1)
    end.

from_pairs(Step, Iterator, Mapper, K, Acc) ->
    case Step() of
        done -> {K, Acc};
        {value, V} ->
            Mapped = closing(Iterator, fun() ->
                                               K >= ?MAX_LENGTH andalso too_long(),
                                               mapped(Mapper, V, K)
                                       end),
            from_pairs(Step, Iterator, Mapper, K + 1, [{K, Mapped} | Acc])
    end.

%% Runs Step; when it throws, IteratorClose calls the return method of the
%% iterator, and the first error wins.
closing(Iterator, Step) ->
    try Step()
    catch
        error:{'$throw', _} = Reason:Stack ->
            try
                case buoy_ref:get(Iterator, <<"return">>) of
                    R when R =:= undefined; R =:= null -> ok;
                    Return -> buoy_ref:call(Return, Iterator, [])
                end
            catch
                error:{'$throw', _} -> ok
            end,
            erlang:raise(error, Reason, Stack)
    end.
