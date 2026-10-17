%% The Array family: the Array constructor, its statics, Array.prototype,
%% and the array iterators.
%%
%% Each method follows its algorithm in the specification over any object:
%% it reads the length with LengthOfArrayLike, tests holes with HasProperty,
%% and writes with Set, CreateDataPropertyOrThrow, and DeletePropertyOrThrow.
%% So the methods work on array-likes, see the changes that a callback makes
%% while they run, and create their results through ArraySpeciesCreate.
-module(bouy_ref_array).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).
-export([length_of/1, to_length/1, is_array/1, is_constructor/1, array_create/1, create_property/3, iterator/2]).

-import(bouy_ref_realm, [arg/2, rest/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

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
     {{builtin, <<"Array">>}, ctor_record(<<"Array">>, 1, {'$o', 'Array.prototype'}, ?METHODS(<<"Array">>, [{<<"isArray">>, 1}, {<<"from">>, 1}, {<<"of">>, 0}]) ++ [{?SYM(species), species_getter(), 4}], fun construct/2)}].

%% get Array[Symbol.species]: this.
species_getter() ->
    {'$accessor', bouy_ref_realm:function(<<"get Array[Symbol.species]">>, <<"get [Symbol.species]">>, 0, fun(This, _) -> This end), undefined}.

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Array">>, constructor()}].

constructor() -> bouy_ref_realm:constructor(?MODULE, <<"Array">>).

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
    Proto = bouy_ref_realm:proto_for(NewTarget, 'Array.prototype'),
    case Args of
        [Len] when ?IS_NUMBER(Len) ->
            case bouy_ref_number:to_uint32(Len) of
                L when L == Len ->
                    A = bouy_heap:new_array([], Proto),
                    bouy_heap:set(A, <<"length">>, L),
                    A;
                _ -> invalid_length()
            end;
        _ -> bouy_heap:new_array(Args, Proto)
    end.

-spec invalid_length() -> no_return().
invalid_length() -> bouy_heap:throw_error('RangeError', <<"Invalid array length">>).

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
object(V, _Name) -> bouy_ref:to_object(V).

%%% Abstract operations

%% LengthOfArrayLike.
-spec length_of(term()) -> non_neg_integer().
length_of(O) ->
    case O of
        {'$o', _} ->
            case bouy_heap:class_of(O) of
                array -> bouy_heap:array_length(O);
                _ -> to_length(bouy_ref:get(O, <<"length">>))
            end;
        _ -> to_length(bouy_ref:get(O, <<"length">>))
    end.

%% ToLength.
-spec to_length(term()) -> non_neg_integer().
to_length(V) ->
    case bouy_ref_number:to_integer_or_infinity(bouy_ref:to_number(V)) of
        'Infinity' -> ?MAX_LENGTH;
        I when is_integer(I), I > ?MAX_LENGTH -> ?MAX_LENGTH;
        I when is_integer(I), I > 0 -> I;
        _ -> 0
    end.

-spec is_array(term()) -> boolean().
is_array({'$o', _} = O) -> bouy_heap:class_of(O) =:= array;
is_array(_) -> false.

%% IsConstructor: a function with a [[Construct]].
-spec is_constructor(term()) -> boolean().
is_constructor({'$f', _, _} = F) ->
    case bouy_heap:slots(F) of
        #{construct := _} -> true;
        #{kind := normal} -> true;
        _ -> false
    end;
is_constructor(_) -> false.

%% ArrayCreate with %Array.prototype%.
-spec array_create(non_neg_integer()) -> term().
array_create(Len) when Len > ?MAX_ARRAY -> invalid_length();
array_create(Len) ->
    A = bouy_heap:new_array([]),
    Len > 0 andalso bouy_heap:set(A, <<"length">>, Len),
    A.

%% ArraySpeciesCreate.
species_create(O, Len) ->
    case is_array(O) of
        false -> array_create(Len);
        true ->
            C = case bouy_ref:get(O, <<"constructor">>) of
                C0 when ?IS_OBJECT(C0) ->
                    case bouy_ref:get(C0, ?SYM(species)) of
                        null -> undefined;
                        S -> S
                    end;
                C0 -> C0
            end,
            case C of
                undefined -> array_create(Len);
                _ ->
                    is_constructor(C) orelse type_error(<<"object.constructor[Symbol.species] is not a constructor">>),
                    bouy_ref:construct(C, [Len])
            end
    end.

%% The property key of an index: an array index, or the string of a larger
%% integer.
key(K) when K =< 4294967294 -> K;
key(K) -> integer_to_binary(K).

get(O, K) -> bouy_ref:get(O, key(K)).

has(O, K) -> bouy_heap:has(O, key(K)).

set(O, K, V) -> bouy_ref:set(O, key(K), V).

set_length(O, Len) -> bouy_ref:set(O, <<"length">>, Len).

delete(O, K) -> bouy_heap:delete(O, key(K)).

%% CreateDataPropertyOrThrow.
-spec create_property(term(), non_neg_integer(), term()) -> term().
create_property(A, K, V) ->
    Key = key(K),
    case bouy_heap:get_own(A, Key) of
        {data, _, Bits} when Bits band 4 =:= 0 -> cannot_define(Key);
        {accessor, _, _, Bits} when Bits band 4 =:= 0 -> cannot_define(Key);
        _ -> ok
    end,
    bouy_heap:define(A, Key, #{value => V, writable => true, enumerable => true, configurable => true}).

-spec cannot_define(term()) -> no_return().
cannot_define(K) -> type_error(bouy_ref_string:concat([<<"Cannot redefine property: ">>, bouy_ref:to_string(bouy_heap:key_to_value(K))])).

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
values(O, From, To) -> lists:reverse(fold_up(From, To, fun(K, Acc) -> [get(O, K) | Acc] end, [])).

%% ToIntegerOrInfinity of an argument.
integer(V) -> bouy_ref_number:to_integer_or_infinity(bouy_ref:to_number(V)).

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
    A = species_create(O, 0),
    N = lists:foldl(fun(E, N0) -> concat_item(A, E, N0) end, 0, [O | Args]),
    set_length(A, N),
    A;
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
    each(O, Len, fun(K, V) -> bouy_ref:call(F, This, [V, K, O]) end),
    undefined;
proto(<<"map">>, O, Args) ->
    Len = length_of(O),
    F = callable(arg(1, Args)),
    This = arg(2, Args),
    A = species_create(O, Len),
    each(O, Len, fun(K, V) -> create_property(A, K, bouy_ref:call(F, This, [V, K, O])) end),
    A;
proto(<<"filter">>, O, Args) ->
    Len = length_of(O),
    F = callable(arg(1, Args)),
    This = arg(2, Args),
    A = species_create(O, 0),
    filter(O, F, This, A, 0, Len, 0),
    A;
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
        S -> bouy_ref:to_string(S)
    end,
    guarded(O, fun() -> join(O, Len, Sep, fun join_text/1) end);
proto(<<"toLocaleString">>, O, _Args) ->
    Len = length_of(O),
    guarded(O, fun() -> join(O, Len, <<",">>, fun locale_text/1) end);
proto(<<"toString">>, O, _Args) ->
    case bouy_ref:get(O, <<"join">>) of
        {'$f', _, _} = Join -> bouy_ref:call(Join, O, []);
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
        true -> bouy_heap:array_push(O, Items);
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
    A = species_create(O, Count),
    N = fold_up(K, Final - 1, fun(I, N0) ->
                                      case has(O, I) of
                                          true -> create_property(A, N0, get(O, I));
                                          false -> ok
                                      end,
                                      N0 + 1
                              end, 0),
    set_length(A, N),
    A;
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
    Index >= 0 andalso Index < Len orelse bouy_heap:throw_error('RangeError', <<"Invalid index">>),
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
fast_array({'$o', _} = O) -> bouy_heap:class_of(O) =:= array;
fast_array(_) -> false.

object_to_string(O) -> bouy_ref_object:method(<<"Object.prototype">>, <<"toString">>, O, []).

%% Calls F for each index below Len that the object has, with its value.
each(O, Len, F) -> each(O, 0, Len, F).

each(_O, K, Len, _F) when K >= Len -> ok;
each(O, K, Len, F) ->
    case has(O, K) of
        true -> F(K, get(O, K));
        false -> ok
    end,
    each(O, K + 1, Len, F).

filter(_O, _F, _This, _A, K, Len, _To) when K >= Len -> ok;
filter(O, F, This, A, K, Len, To) ->
    case has(O, K) of
        true ->
            V = get(O, K),
            case bouy_ref:truthy(bouy_ref:call(F, This, [V, K, O])) of
                true ->
                    create_property(A, To, V),
                    filter(O, F, This, A, K + 1, Len, To + 1);
                false -> filter(O, F, This, A, K + 1, Len, To)
            end;
        false -> filter(O, F, This, A, K + 1, Len, To)
    end.

every(_O, _F, _This, K, Len) when K >= Len -> true;
every(O, F, This, K, Len) ->
    case has(O, K) andalso not bouy_ref:truthy(bouy_ref:call(F, This, [get(O, K), K, O])) of
        true -> false;
        false -> every(O, F, This, K + 1, Len)
    end.

some(_O, _F, _This, K, Len) when K >= Len -> false;
some(O, F, This, K, Len) ->
    case has(O, K) andalso bouy_ref:truthy(bouy_ref:call(F, This, [get(O, K), K, O])) of
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
    V = get(O, K),
    case bouy_ref:truthy(bouy_ref:call(F, This, [V, K, O])) of
        true when What =:= value -> V;
        true -> K;
        false -> find_in(O, F, This, What, K + Step, End, Step)
    end.

includes(_O, _Search, K, Len) when K >= Len -> false;
includes(O, Search, K, Len) ->
    case same_value_zero(get(O, K), Search) of
        true -> true;
        false -> includes(O, Search, K + 1, Len)
    end.

same_value_zero(A, B) when is_number(A), is_number(B) -> A == B;
same_value_zero(A, B) -> A =:= B.

index_of(_O, _Search, K, Len) when K >= Len -> -1;
index_of(O, Search, K, Len) ->
    case has(O, K) andalso bouy_ref:strict_eq(get(O, K), Search) of
        true -> K;
        false -> index_of(O, Search, K + 1, Len)
    end.

last_index_of(_O, _Search, K) when K < 0 -> -1;
last_index_of(O, Search, K) ->
    case has(O, K) andalso bouy_ref:strict_eq(get(O, K), Search) of
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
    Acc1 = case has(O, K) of
        true -> bouy_ref:call(F, undefined, [Acc, get(O, K), K, O]);
        false -> Acc
    end,
    reduce_steps(O, F, K + Step, To, Step, Acc1).

first_present(_O, K, To, Step) when (Step > 0 andalso K > To); (Step < 0 andalso K < To) ->
    type_error(<<"Reduce of empty array with no initial value">>);
first_present(O, K, To, Step) ->
    case has(O, K) of
        true -> {get(O, K), K + Step};
        false -> first_present(O, K + Step, To, Step)
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
                                   case has(E, K) of
                                       true -> create_property(A, N + K, get(E, K));
                                       false -> ok
                                   end
                           end),
            N + Len;
        false ->
            N >= ?MAX_LENGTH andalso too_long(),
            create_property(A, N, E),
            N + 1
    end.

is_spreadable(E) when ?IS_OBJECT(E) ->
    case bouy_ref:get(E, ?SYM(isConcatSpreadable)) of
        undefined -> is_array(E);
        V -> bouy_ref:truthy(V)
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
                                    {F, This} -> bouy_ref:call(F, This, [V0, K, Source])
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
    Stack = case erlang:get('$bouy_join') of
        undefined -> [];
        S -> S
    end,
    case lists:member(O, Stack) of
        true -> <<>>;
        false ->
            erlang:put('$bouy_join', [O | Stack]),
            try Join()
            after erlang:put('$bouy_join', Stack)
            end
    end.

join(O, Len, Sep, Text) ->
    bouy_ref_string:concat(lists:join(Sep, [Text(V) || V <- values(O, 0, Len - 1)])).

join_text(undefined) -> <<>>;
join_text(null) -> <<>>;
join_text(V) -> bouy_ref:to_string(V).

locale_text(undefined) -> <<>>;
locale_text(null) -> <<>>;
locale_text(V) -> bouy_ref:to_string(bouy_ref:call_method(V, <<"toLocaleString">>, [])).

%%% Sorting

comparator(undefined) -> undefined;
comparator(F) ->
    bouy_heap:is_callable(F) orelse type_error(<<"The comparison function must be either a function or undefined">>),
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
            Keyed = [{bouy_ref:to_string(V), V} || V <- Defined],
            [V || {_, V} <- lists:sort(fun({X, _}, {Y, _}) -> bouy_ref_string:compare(X, Y) =/= gt end, Keyed)];
        F ->
            bouy_sort:sort(Defined, fun(CallArgs) -> bouy_ref:to_number(bouy_ref:call(F, undefined, CallArgs)) end)
    end,
    Sorted ++ Undefined.

%%% Array iterators

%% CreateArrayIterator: a live iterator over the indexes of O.
-spec iterator(term(), keys | values | entries) -> term().
iterator(O, Kind) -> bouy_heap:new_exotic(array_iterator, {'$o', 'ArrayIterator.prototype'}, {O, 0, Kind}).

iterator_next(It) ->
    ?IS_OBJECT(It) andalso bouy_heap:class_of(It) =:= array_iterator orelse
        type_error(<<"next method called on incompatible receiver">>),
    case bouy_heap:slots(It) of
        done -> bouy_ref_iterator:result(undefined, true);
        {O, Index, Kind} ->
            Len = iterated_length(O),
            case Index < Len of
                false ->
                    bouy_heap:set_slots(It, done),
                    bouy_ref_iterator:result(undefined, true);
                true ->
                    bouy_heap:set_slots(It, {O, Index + 1, Kind}),
                    Value = case Kind of
                        keys -> Index;
                        values -> get(O, Index);
                        entries -> bouy_heap:new_array([Index, get(O, Index)])
                    end,
                    bouy_ref_iterator:result(Value, false)
            end
    end.

iterated_length(O) -> length_of(O).

%%% Array statics

static(<<"isArray">>, _This, Args) -> is_array(arg(1, Args));
static(<<"of">>, C, Items) ->
    Len = length(Items),
    A = case is_constructor(C) of
        true -> bouy_ref:construct(C, [Len]);
        false -> array_create(Len)
    end,
    [create_property(A, K, V) || {K, V} <- lists:enumerate(0, Items)],
    set_length(A, Len),
    A;
static(<<"from">>, C, Args) ->
    Items = arg(1, Args),
    Mapper = case arg(2, Args) of
        undefined -> none;
        F ->
            bouy_heap:is_callable(F) orelse type_error(bouy_ref_string:concat(bouy_ref:describe(F), <<" is not a function">>)),
            {F, arg(3, Args)}
    end,
    case iterator_method(Items) of
        undefined -> from_array_like(C, bouy_ref:to_object(Items), Mapper);
        Method -> from_iterable(C, Items, Method, Mapper)
    end.

iterator_method(V) when V =:= undefined; V =:= null -> undefined;
iterator_method(V) ->
    case bouy_ref:get(V, ?SYM(iterator)) of
        M when M =:= undefined; M =:= null -> undefined;
        M -> callable(M)
    end.

from_array_like(C, O, Mapper) ->
    Len = length_of(O),
    A = case is_constructor(C) of
        true -> bouy_ref:construct(C, [Len]);
        false -> array_create(Len)
    end,
    up(0, Len - 1, fun(K) -> create_property(A, K, mapped(Mapper, get(O, K), K)) end),
    set_length(A, Len),
    A.

mapped(none, V, _K) -> V;
mapped({F, This}, V, K) -> bouy_ref:call(F, This, [V, K]).

from_iterable(C, Items, Method, Mapper) ->
    A = case is_constructor(C) of
        true -> bouy_ref:construct(C, []);
        false -> array_create(0)
    end,
    Iterator = bouy_ref:call(Method, Items, []),
    ?IS_OBJECT(Iterator) orelse type_error(<<"Result of the Symbol.iterator method is not an object">>),
    Next = bouy_ref:get(Iterator, <<"next">>),
    Len = from_steps(A, Iterator, Next, Mapper, 0),
    set_length(A, Len),
    A.

from_steps(A, Iterator, Next, Mapper, K) ->
    Result = bouy_ref:call(Next, Iterator, []),
    ?IS_OBJECT(Result) orelse type_error(bouy_ref_string:concat([<<"Iterator result ">>, bouy_ref:describe(Result), <<" is not an object">>])),
    case bouy_ref:truthy(bouy_ref:get(Result, <<"done">>)) of
        true -> K;
        false ->
            V = bouy_ref:get(Result, <<"value">>),
            closing(Iterator, fun() ->
                                      K >= ?MAX_LENGTH andalso too_long(),
                                      create_property(A, K, mapped(Mapper, V, K))
                              end),
            from_steps(A, Iterator, Next, Mapper, K + 1)
    end.

%% Runs Step; when it throws, IteratorClose calls the return method of the
%% iterator, and the first error wins.
closing(Iterator, Step) ->
    try Step()
    catch
        error:{'$throw', _} = Reason:Stack ->
            try
                case bouy_ref:get(Iterator, <<"return">>) of
                    R when R =:= undefined; R =:= null -> ok;
                    Return -> bouy_ref:call(Return, Iterator, [])
                end
            catch
                error:{'$throw', _} -> ok
            end,
            erlang:raise(error, Reason, Stack)
    end.
