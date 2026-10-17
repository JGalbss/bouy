%% The typed arrays: %TypedArray%, its prototype, the twelve constructors
%% from Int8Array to BigUint64Array, and the integer-indexed exotic object
%% behaviour that bouy_heap calls for their numeric keys.
%%
%% The slots of a typed array are {Kind, Buffer, ByteOffset, Length}: Kind
%% names the element type (bouy_ref_buffer:kinds/0), Buffer is the
%% ArrayBuffer object, and Length is the element count, or auto for an
%% array that tracks the length of a resizable buffer. Each access checks
%% the buffer, so a detached or shrunk buffer reads as out of bounds.
-module(bouy_ref_typed_array).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).
-export([numeric_key/1, element_get/2, element_set/3, element_has/2, element_define/3, element_delete/2, index_keys/1]).
-export([iterated_length/1, create/2]).

-import(bouy_ref_realm, [arg/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

-define(TA_PROTO, {'$o', 'TypedArray.prototype'}).
-define(MAX_LENGTH, 9007199254740991).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Methods = ?METHODS(<<"TypedArray.prototype">>, prototype_methods()),
    {_, Values} = lists:keyfind(<<"values">>, 1, Methods),
    [{_, ToString}] = bouy_ref_realm:methods(bouy_ref_array, <<"Array.prototype">>, [{<<"toString">>, 0}]),
    Getters = [getter(G) || G <- [<<"buffer">>, <<"byteLength">>, <<"byteOffset">>, <<"length">>]],
    Tag = {?SYM(toStringTag), {'$accessor', bouy_ref_realm:function(<<"get TypedArray.prototype[Symbol.toStringTag]">>, <<"get [Symbol.toStringTag]">>, 0,
                                                                   fun(This, _) -> ?MODULE:method(<<"TypedArray.prototype">>, <<"[Symbol.toStringTag]">>, This, []) end), undefined}, 4},
    Species = {?SYM(species), {'$accessor', bouy_ref_realm:function(<<"get TypedArray[Symbol.species]">>, <<"get [Symbol.species]">>, 0, fun(This, _) -> This end), undefined}, 4},
    [{'TypedArray.prototype', record(object, ?OBJECT_PROTO, Methods ++ Getters ++ [Tag, {<<"toString">>, ToString}, {?SYM(iterator), Values}, {<<"constructor">>, abstract()}], none)},
     {{builtin, <<"TypedArray">>}, ctor_record(<<"TypedArray">>, 0, ?TA_PROTO, ?METHODS(<<"TypedArray">>, [{<<"from">>, 1}, {<<"of">>, 0}]) ++ [Species], fun abstract_construct/2)}]
    ++ lists:append([kind_intrinsics(K) || K <- bouy_ref_buffer:kinds()]).

kind_intrinsics(Kind) ->
    Name = bouy_ref_buffer:kind_name(Kind),
    Size = bouy_ref_buffer:element_size(Kind),
    Proto = {'$o', proto_id(Kind)},
    Record = ctor_record(Name, 3, Proto, [{<<"BYTES_PER_ELEMENT">>, Size, 0}], fun(NT, Args) -> construct(Kind, NT, Args) end),
    [{proto_id(Kind), record(object, ?TA_PROTO, [{<<"BYTES_PER_ELEMENT">>, Size, 0}, {<<"constructor">>, constructor(Kind)}], none)},
     {{builtin, Name}, setelement(2, Record, abstract())}].

proto_id(Kind) -> binary_to_atom(<<(bouy_ref_buffer:kind_name(Kind))/binary, ".prototype">>).

getter(Name) ->
    {Name, {'$accessor', bouy_ref_realm:function(<<"get TypedArray.prototype.", Name/binary>>, <<"get ", Name/binary>>, 0,
                                                fun(This, _) -> ?MODULE:method(<<"TypedArray.prototype">>, Name, This, []) end), undefined}, 4}.

prototype_methods() ->
    [{<<"at">>, 1}, {<<"copyWithin">>, 2}, {<<"entries">>, 0}, {<<"every">>, 1}, {<<"fill">>, 1}, {<<"filter">>, 1}, {<<"find">>, 1},
     {<<"findIndex">>, 1}, {<<"findLast">>, 1}, {<<"findLastIndex">>, 1}, {<<"forEach">>, 1}, {<<"includes">>, 1}, {<<"indexOf">>, 1},
     {<<"join">>, 1}, {<<"keys">>, 0}, {<<"lastIndexOf">>, 1}, {<<"map">>, 1}, {<<"reduce">>, 1}, {<<"reduceRight">>, 1},
     {<<"reverse">>, 0}, {<<"set">>, 1}, {<<"slice">>, 2}, {<<"some">>, 1}, {<<"sort">>, 1}, {<<"subarray">>, 2},
     {<<"toLocaleString">>, 0}, {<<"toReversed">>, 0}, {<<"toSorted">>, 1}, {<<"values">>, 0}, {<<"with">>, 2}].

-spec globals() -> [{binary(), term()}].
globals() -> [{bouy_ref_buffer:kind_name(K), constructor(K)} || K <- bouy_ref_buffer:kinds()].

abstract() -> bouy_ref_realm:constructor(?MODULE, <<"TypedArray">>).

constructor(Kind) -> bouy_ref_realm:constructor(?MODULE, bouy_ref_buffer:kind_name(Kind)).

-spec abstract_construct(term(), list()) -> no_return().
abstract_construct(_NewTarget, _Args) -> type_error(<<"Abstract class TypedArray not directly constructable">>).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(<<"TypedArray">>, _This, _Args) -> type_error(<<"Abstract class TypedArray not directly constructable">>);
call_constructor(Name, _This, _Args) -> type_error(<<"Constructor ", Name/binary, " requires 'new'">>).

%%% The records of a typed array

-spec is_typed_array(term()) -> boolean().
is_typed_array({'$o', _} = O) -> bouy_heap:class_of(O) =:= typed_array;
is_typed_array(_) -> false.

slots(O) -> bouy_heap:slots(O).

%% The element count, or out_of_bounds for a detached or shrunk buffer.
length_of({Kind, Buffer, Offset, Length}) ->
    case bouy_ref_buffer:is_detached(Buffer) of
        true -> out_of_bounds;
        false ->
            BufferLength = bouy_ref_buffer:byte_length(Buffer),
            Size = bouy_ref_buffer:element_size(Kind),
            case Length of
                auto when Offset =< BufferLength -> (BufferLength - Offset) div Size;
                auto -> out_of_bounds;
                _ when Offset + Length * Size =< BufferLength -> Length;
                _ -> out_of_bounds
            end
    end.

%% The length of an array iterator's typed array: a TypeError when it is
%% out of bounds.
-spec iterated_length(term()) -> non_neg_integer().
iterated_length(O) ->
    case length_of(slots(O)) of
        out_of_bounds -> type_error(<<"Cannot perform %ArrayIteratorPrototype%.next on a detached or out of bounds TypedArray">>);
        L -> L
    end.

%% ValidateTypedArray: the slots and the length of a typed array that is
%% in bounds.
validate(O, Name) ->
    is_typed_array(O) orelse type_error(<<"this is not a typed array.">>),
    Slots = slots(O),
    case length_of(Slots) of
        out_of_bounds -> type_error(<<"Cannot perform %TypedArray%.prototype.", Name/binary, " on a detached ArrayBuffer">>);
        Length -> {Slots, Length}
    end.

%%% Integer-indexed exotic behaviour

%% The numeric index of a key: {index, N} for an integer index or a
%% canonical numeric string, else none.
-spec numeric_key(term()) -> {index, term()} | none.
numeric_key(K) when is_integer(K) -> {index, K};
numeric_key(<<"-0">>) -> {index, -0.0};
numeric_key(<<C, _/binary>> = K) when C =:= $-; C =:= $I; C =:= $N; C >= $0, C =< $9 ->
    N = bouy_ref_number:from_string(K),
    case bouy_ref_number:to_string(N) =:= K of
        true -> {index, N};
        false -> none
    end;
numeric_key(_) -> none.

%% IsValidIntegerIndex: the integer index, or invalid.
valid_index(Slots, N) when is_integer(N), N >= 0 ->
    case length_of(Slots) of
        L when is_integer(L), N < L -> N;
        _ -> invalid
    end;
valid_index(_Slots, _N) -> invalid.

%% TypedArrayGetElement.
-spec element_get(term(), term()) -> term().
element_get(O, N) ->
    Slots = slots(O),
    case valid_index(Slots, N) of
        invalid -> undefined;
        I -> read_element(Slots, I)
    end.

read_element({Kind, Buffer, Offset, _}, I) ->
    Size = bouy_ref_buffer:element_size(Kind),
    bouy_ref_buffer:decode(Kind, bouy_ref_buffer:read(Buffer, Offset + I * Size, Size)).

%% TypedArraySetElement: the value converts before the index check.
-spec element_set(term(), term(), term()) -> ok.
element_set(O, N, V) ->
    {Kind, _, _, _} = slots(O),
    Value = to_element(Kind, V),
    Slots = slots(O),
    case valid_index(Slots, N) of
        invalid -> ok;
        I -> write_element(Slots, I, Value)
    end.

to_element(Kind, V) ->
    case bouy_ref_buffer:is_big_int_kind(Kind) of
        true -> bouy_ref_bigint:to_big_int(V);
        false -> bouy_ref:to_number(V)
    end.

write_element({Kind, Buffer, Offset, _}, I, Value) ->
    Size = bouy_ref_buffer:element_size(Kind),
    bouy_ref_buffer:write(Buffer, Offset + I * Size, bouy_ref_buffer:encode(Kind, Value)).

-spec element_has(term(), term()) -> boolean().
element_has(O, N) -> valid_index(slots(O), N) =/= invalid.

%% [[DefineOwnProperty]] for a numeric key: false when the descriptor asks
%% for what an element cannot be.
-spec element_define(term(), term(), map()) -> boolean().
element_define(O, N, Descriptor) ->
    case valid_index(slots(O), N) of
        invalid -> false;
        _ ->
            Rejected = maps:get(configurable, Descriptor, true) =:= false
                orelse maps:get(enumerable, Descriptor, true) =:= false
                orelse is_map_key(get, Descriptor) orelse is_map_key(set, Descriptor)
                orelse maps:get(writable, Descriptor, true) =:= false,
            case Rejected of
                true -> false;
                false ->
                    case Descriptor of
                        #{value := V} -> element_set(O, N, V);
                        _ -> ok
                    end,
                    true
            end
    end.

-spec element_delete(term(), term()) -> boolean().
element_delete(O, N) -> valid_index(slots(O), N) =:= invalid.

%% The own index keys of a typed array, for [[OwnPropertyKeys]].
-spec index_keys(term()) -> [non_neg_integer()].
index_keys(O) ->
    case length_of(slots(O)) of
        out_of_bounds -> [];
        L -> lists:seq(0, L - 1)
    end.

%%% Construction

construct(Kind, NewTarget, Args) ->
    Proto = bouy_ref_realm:proto_for(NewTarget, proto_id(Kind)),
    case Args of
        [] -> allocate(Kind, Proto, 0);
        [First | _] when ?IS_OBJECT(First) ->
            case bouy_heap:class_of(First) of
                typed_array -> from_typed_array(Kind, Proto, First);
                C when C =:= array_buffer; C =:= shared_array_buffer -> from_buffer(Kind, Proto, First, arg(2, Args), arg(3, Args));
                _ ->
                    case iterator_method(First) of
                        undefined -> from_array_like(Kind, Proto, First);
                        Method -> from_list(Kind, Proto, iterator_to_list(First, Method))
                    end
            end;
        [First | _] -> allocate(Kind, Proto, bouy_ref_buffer:to_index(First))
    end.

%% IteratorToList of GetIteratorFromMethod.
iterator_to_list(Source, Method) ->
    Iterator = bouy_ref:call(Method, Source, []),
    ?IS_OBJECT(Iterator) orelse type_error(<<"Result of the Symbol.iterator method is not an object">>),
    Next = bouy_ref:get(Iterator, <<"next">>),
    iterator_steps(Iterator, Next, []).

iterator_steps(Iterator, Next, Acc) ->
    Result = bouy_ref:call(Next, Iterator, []),
    ?IS_OBJECT(Result) orelse type_error(bouy_ref_string:concat([<<"Iterator result ">>, bouy_ref:describe(Result), <<" is not an object">>])),
    case bouy_ref:truthy(bouy_ref:get(Result, <<"done">>)) of
        true -> lists:reverse(Acc);
        false -> iterator_steps(Iterator, Next, [bouy_ref:get(Result, <<"value">>) | Acc])
    end.

iterator_method(O) ->
    case bouy_ref:get(O, ?SYM(iterator)) of
        M when M =:= undefined; M =:= null -> undefined;
        M -> callable(M)
    end.

%% A typed array of Length zero elements with a new buffer.
allocate(Kind, Proto, Length) ->
    Buffer = bouy_ref_buffer:allocate(Length * bouy_ref_buffer:element_size(Kind)),
    bouy_heap:new_exotic(typed_array, Proto, {Kind, Buffer, 0, Length}).

%% A new typed array of the kind with %Kind.prototype%.
-spec create(atom(), non_neg_integer()) -> term().
create(Kind, Length) -> allocate(Kind, {'$o', proto_id(Kind)}, Length).

from_typed_array(Kind, Proto, Source) ->
    {SourceKind, _, _, _} = SourceSlots = slots(Source),
    Length = case length_of(SourceSlots) of
        out_of_bounds -> type_error(<<"Cannot construct a typed array from a detached ArrayBuffer">>);
        L -> L
    end,
    bouy_ref_buffer:is_big_int_kind(Kind) =:= bouy_ref_buffer:is_big_int_kind(SourceKind) orelse
        type_error(<<"Cannot mix BigInt and other types, use explicit conversions">>),
    O = allocate(Kind, Proto, Length),
    TargetSlots = slots(O),
    case Kind =:= SourceKind of
        true ->
            {_, SourceBuffer, SourceOffset, _} = SourceSlots,
            {_, Buffer, _, _} = TargetSlots,
            Bytes = Length * bouy_ref_buffer:element_size(Kind),
            Bytes > 0 andalso bouy_ref_buffer:copy(SourceBuffer, SourceOffset, Buffer, 0, Bytes);
        false ->
            [write_element(TargetSlots, I, read_element(SourceSlots, I)) || I <- seq(0, Length - 1)]
    end,
    O.

from_buffer(Kind, Proto, Buffer, OffsetArg, LengthArg) ->
    Size = bouy_ref_buffer:element_size(Kind),
    Offset = bouy_ref_buffer:to_index(OffsetArg),
    Offset rem Size =:= 0 orelse bouy_heap:throw_error('RangeError', <<"start offset of the typed array should be a multiple of the element size">>),
    NewLength = case LengthArg of
        undefined -> undefined;
        _ -> bouy_ref_buffer:to_index(LengthArg)
    end,
    bouy_ref_buffer:is_detached(Buffer) andalso type_error(<<"Cannot perform Construct on a detached ArrayBuffer">>),
    BufferLength = bouy_ref_buffer:byte_length(Buffer),
    Fixed = element(3, bouy_heap:slots(Buffer)) =:= none,
    Length = case NewLength of
        undefined when not Fixed ->
            Offset > BufferLength andalso bouy_heap:throw_error('RangeError', <<"Start offset is outside the bounds of the buffer">>),
            auto;
        undefined ->
            BufferLength rem Size =:= 0 orelse bouy_heap:throw_error('RangeError', <<"byte length of the typed array should be a multiple of the element size">>),
            BufferLength - Offset >= 0 orelse bouy_heap:throw_error('RangeError', <<"Start offset is outside the bounds of the buffer">>),
            (BufferLength - Offset) div Size;
        _ ->
            Offset + NewLength * Size > BufferLength andalso bouy_heap:throw_error('RangeError', <<"Invalid typed array length">>),
            NewLength
    end,
    bouy_heap:new_exotic(typed_array, Proto, {Kind, Buffer, Offset, Length}).

from_list(Kind, Proto, Values) ->
    O = allocate(Kind, Proto, length(Values)),
    [bouy_ref:set(O, I, V) || {I, V} <- lists:enumerate(0, Values)],
    O.

from_array_like(Kind, Proto, Source) ->
    Length = bouy_ref_array:length_of(Source),
    O = allocate(Kind, Proto, Length),
    up(0, Length - 1, fun(I) -> bouy_ref:set(O, I, bouy_ref:get(Source, I)) end),
    O.

seq(From, To) when From > To -> [];
seq(From, To) -> lists:seq(From, To).

up(From, To, _F) when From > To -> ok;
up(From, To, F) ->
    F(From),
    up(From + 1, To, F).

%% TypedArraySpeciesCreate.
species_create(Exemplar, Args, Name) ->
    {Kind, _, _, _} = slots(Exemplar),
    C = bouy_ref_buffer_species(Exemplar, constructor(Kind)),
    Result = create_from_constructor(C, Args, Name),
    {ResultKind, _, _, _} = slots(Result),
    bouy_ref_buffer:is_big_int_kind(ResultKind) =:= bouy_ref_buffer:is_big_int_kind(Kind) orelse
        type_error(<<"Content type of the new typed array does not match">>),
    Result.

bouy_ref_buffer_species(O, Default) ->
    case bouy_ref:get(O, <<"constructor">>) of
        undefined -> Default;
        C when ?IS_OBJECT(C) ->
            case bouy_ref:get(C, ?SYM(species)) of
                S when S =:= undefined; S =:= null -> Default;
                S ->
                    bouy_ref_array:is_constructor(S) orelse type_error(<<"object.constructor[Symbol.species] is not a constructor">>),
                    S
            end;
        _ -> type_error(<<"The .constructor property is not an object">>)
    end.

%% TypedArrayCreateFromConstructor.
create_from_constructor(C, Args, Name) ->
    New = bouy_ref:construct(C, Args),
    {_, Length} = validate(New, Name),
    case Args of
        [N] when is_integer(N) -> Length >= N orelse type_error(<<"The species constructor made a typed array that is too short">>);
        _ -> ok
    end,
    New.

%%% Statics

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"TypedArray">>, <<"of">>, C, Items) ->
    bouy_ref_array:is_constructor(C) orelse type_error(<<"TypedArray.of: this is not a constructor">>),
    New = create_from_constructor(C, [length(Items)], <<"of">>),
    [bouy_ref:set(New, I, V) || {I, V} <- lists:enumerate(0, Items)],
    New;
method(<<"TypedArray">>, <<"from">>, C, Args) ->
    bouy_ref_array:is_constructor(C) orelse type_error(<<"TypedArray.from: this is not a constructor">>),
    Source = arg(1, Args),
    Mapper = case arg(2, Args) of
        undefined -> none;
        F -> {callable(F), arg(3, Args)}
    end,
    Values = case iterator_method_of(Source) of
        undefined ->
            O = bouy_ref:to_object(Source),
            Length = bouy_ref_array:length_of(O),
            {array_like, O, Length};
        Method -> {list, iterator_to_list(Source, Method)}
    end,
    Length1 = case Values of
        {list, List} -> length(List);
        {array_like, _, L} -> L
    end,
    New = create_from_constructor(C, [Length1], <<"from">>),
    Mapped = fun(V, K) ->
                     case Mapper of
                         none -> V;
                         {F1, This} -> bouy_ref:call(F1, This, [V, K])
                     end
             end,
    case Values of
        {list, List1} -> [bouy_ref:set(New, K, Mapped(V, K)) || {K, V} <- lists:enumerate(0, List1)];
        {array_like, O1, L1} -> up(0, L1 - 1, fun(K) -> bouy_ref:set(New, K, Mapped(bouy_ref:get(O1, K), K)) end)
    end,
    New;
method(<<"TypedArray.prototype">>, <<"buffer">>, This, _) ->
    is_typed_array(This) orelse type_error(<<"this is not a typed array.">>),
    element(2, slots(This));
method(<<"TypedArray.prototype">>, <<"byteLength">>, This, _) ->
    is_typed_array(This) orelse type_error(<<"this is not a typed array.">>),
    {Kind, _, _, _} = Slots = slots(This),
    case length_of(Slots) of
        out_of_bounds -> 0;
        L -> L * bouy_ref_buffer:element_size(Kind)
    end;
method(<<"TypedArray.prototype">>, <<"byteOffset">>, This, _) ->
    is_typed_array(This) orelse type_error(<<"this is not a typed array.">>),
    {_, _, Offset, _} = Slots = slots(This),
    case length_of(Slots) of
        out_of_bounds -> 0;
        _ -> Offset
    end;
method(<<"TypedArray.prototype">>, <<"length">>, This, _) ->
    is_typed_array(This) orelse type_error(<<"this is not a typed array.">>),
    case length_of(slots(This)) of
        out_of_bounds -> 0;
        L -> L
    end;
method(<<"TypedArray.prototype">>, <<"[Symbol.toStringTag]">>, This, _) ->
    case is_typed_array(This) of
        true -> bouy_ref_buffer:kind_name(element(1, slots(This)));
        false -> undefined
    end;
method(<<"TypedArray.prototype">>, <<"set">>, This, Args) ->
    is_typed_array(This) orelse type_error(<<"this is not a typed array.">>),
    set(This, arg(1, Args), arg(2, Args));
method(<<"TypedArray.prototype">>, <<"subarray">>, This, Args) ->
    is_typed_array(This) orelse type_error(<<"this is not a typed array.">>),
    subarray(This, arg(1, Args), arg(2, Args));
method(<<"TypedArray.prototype">>, Name, This, Args) ->
    {Slots, Length} = validate(This, Name),
    proto(Name, This, Slots, Length, Args).

iterator_method_of(V) when ?IS_OBJECT(V) -> iterator_method(V);
iterator_method_of(V) when ?IS_STRING(V) -> bouy_ref:get(V, ?SYM(iterator));
iterator_method_of(_) -> undefined.

%%% TypedArray.prototype

integer(V) -> bouy_ref_number:to_integer_or_infinity(bouy_ref:to_number(V)).

relative(V, Len) ->
    case integer(V) of
        '-Infinity' -> 0;
        'Infinity' -> Len;
        I when I < 0 -> max(Len + I, 0);
        I -> min(I, Len)
    end.

relative_end(undefined, Len) -> Len;
relative_end(V, Len) -> relative(V, Len).

get(O, K) -> element_get(O, K).

proto(<<"at">>, O, _Slots, Len, Args) ->
    K = case integer(arg(1, Args)) of
        I when is_integer(I), I >= 0 -> I;
        I when is_integer(I) -> Len + I;
        _ -> -1
    end,
    case K >= 0 andalso K < Len of
        true -> get(O, K);
        false -> undefined
    end;
proto(<<"copyWithin">>, O, _Slots, Len, Args) ->
    To = relative(arg(1, Args), Len),
    From = relative(arg(2, Args), Len),
    Final = relative_end(arg(3, Args), Len),
    Count = min(Final - From, Len - To),
    case Count > 0 of
        false -> O;
        true ->
            {Kind, Buffer, Offset, _} = Slots1 = slots(O),
            NewLen = case length_of(Slots1) of
                out_of_bounds -> type_error(<<"Cannot perform %TypedArray%.prototype.copyWithin on a detached ArrayBuffer">>);
                L -> L
            end,
            Size = bouy_ref_buffer:element_size(Kind),
            ByteCount = max(0, min(Count, min(NewLen - From, NewLen - To))) * Size,
            ByteCount > 0 andalso bouy_ref_buffer:copy(Buffer, Offset + From * Size, Buffer, Offset + To * Size, ByteCount),
            O
    end;
proto(<<"entries">>, O, _, _, _) -> bouy_ref_array:iterator(O, entries);
proto(<<"keys">>, O, _, _, _) -> bouy_ref_array:iterator(O, keys);
proto(<<"values">>, O, _, _, _) -> bouy_ref_array:iterator(O, values);
proto(<<"every">>, O, _, Len, Args) ->
    F = callable(arg(1, Args)),
    This = arg(2, Args),
    not lists:any(fun(K) -> not bouy_ref:truthy(bouy_ref:call(F, This, [get(O, K), K, O])) end, seq(0, Len - 1));
proto(<<"some">>, O, _, Len, Args) ->
    F = callable(arg(1, Args)),
    This = arg(2, Args),
    lists:any(fun(K) -> bouy_ref:truthy(bouy_ref:call(F, This, [get(O, K), K, O])) end, seq(0, Len - 1));
proto(<<"forEach">>, O, _, Len, Args) ->
    F = callable(arg(1, Args)),
    This = arg(2, Args),
    up(0, Len - 1, fun(K) -> bouy_ref:call(F, This, [get(O, K), K, O]) end),
    undefined;
proto(<<"fill">>, O, {Kind, _, _, _}, Len, Args) ->
    Value = to_element(Kind, arg(1, Args)),
    K = relative(arg(2, Args), Len),
    Final = relative_end(arg(3, Args), Len),
    Slots1 = slots(O),
    case length_of(Slots1) of
        out_of_bounds -> type_error(<<"Cannot perform %TypedArray%.prototype.fill on a detached ArrayBuffer">>);
        NewLen -> up(K, min(Final, NewLen) - 1, fun(I) -> write_element(Slots1, I, Value) end)
    end,
    O;
proto(<<"filter">>, O, _, Len, Args) ->
    F = callable(arg(1, Args)),
    This = arg(2, Args),
    Kept = [V || K <- seq(0, Len - 1), V <- [get(O, K)], bouy_ref:truthy(bouy_ref:call(F, This, [V, K, O]))],
    A = species_create(O, [length(Kept)], <<"filter">>),
    [bouy_ref:set(A, I, V) || {I, V} <- lists:enumerate(0, Kept)],
    A;
proto(<<"find">>, O, _, Len, Args) -> find(O, Args, seq(0, Len - 1), value);
proto(<<"findIndex">>, O, _, Len, Args) -> find(O, Args, seq(0, Len - 1), index);
proto(<<"findLast">>, O, _, Len, Args) -> find(O, Args, lists:reverse(seq(0, Len - 1)), value);
proto(<<"findLastIndex">>, O, _, Len, Args) -> find(O, Args, lists:reverse(seq(0, Len - 1)), index);
proto(<<"includes">>, O, _, Len, Args) ->
    case Len of
        0 -> false;
        _ ->
            case integer(arg(2, Args)) of
                'Infinity' -> false;
                N ->
                    Search = arg(1, Args),
                    lists:any(fun(K) -> same_value_zero(get(O, K), Search) end, seq(start(N, Len), Len - 1))
            end
    end;
proto(<<"indexOf">>, O, _, Len, Args) ->
    case Len of
        0 -> -1;
        _ ->
            case integer(arg(2, Args)) of
                'Infinity' -> -1;
                N -> first_index(O, arg(1, Args), seq(start(N, Len), Len - 1))
            end
    end;
proto(<<"lastIndexOf">>, O, _, Len, Args) ->
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
            first_index(O, arg(1, Args), lists:reverse(seq(0, K)))
    end;
proto(<<"join">>, O, _, Len, Args) ->
    Sep = case arg(1, Args) of
        undefined -> <<",">>;
        S -> bouy_ref:to_string(S)
    end,
    bouy_ref_string:concat(lists:join(Sep, [case get(O, K) of undefined -> <<>>; V -> bouy_ref:to_string(V) end || K <- seq(0, Len - 1)]));
proto(<<"toLocaleString">>, O, _, Len, _Args) ->
    bouy_ref_string:concat(lists:join(<<",">>, [case get(O, K) of
                                                     V when V =:= undefined; V =:= null -> <<>>;
                                                     V -> bouy_ref:to_string(bouy_ref:call_method(V, <<"toLocaleString">>, []))
                                                 end || K <- seq(0, Len - 1)]));
proto(<<"map">>, O, _, Len, Args) ->
    F = callable(arg(1, Args)),
    This = arg(2, Args),
    A = species_create(O, [Len], <<"map">>),
    up(0, Len - 1, fun(K) -> bouy_ref:set(A, K, bouy_ref:call(F, This, [get(O, K), K, O])) end),
    A;
proto(<<"reduce">>, O, _, Len, Args) -> reduce(O, Args, seq(0, Len - 1));
proto(<<"reduceRight">>, O, _, Len, Args) -> reduce(O, Args, lists:reverse(seq(0, Len - 1)));
proto(<<"reverse">>, O, Slots, Len, _) ->
    Values = [read_element(Slots, K) || K <- seq(0, Len - 1)],
    [write_element(Slots, K, V) || {K, V} <- lists:enumerate(0, lists:reverse(Values))],
    O;
proto(<<"slice">>, O, {Kind, _, _, _}, Len, Args) ->
    Start = relative(arg(1, Args), Len),
    Final = relative_end(arg(2, Args), Len),
    Count = max(Final - Start, 0),
    A = species_create(O, [Count], <<"slice">>),
    case Count > 0 of
        false -> A;
        true ->
            Slots1 = slots(O),
            NewLen = case length_of(Slots1) of
                out_of_bounds -> type_error(<<"Cannot perform %TypedArray%.prototype.slice on a detached ArrayBuffer">>);
                L -> L
            end,
            End = min(Final, NewLen),
            {TargetKind, TargetBuffer, TargetOffset, _} = slots(A),
            case TargetKind =:= Kind of
                true ->
                    {_, Buffer, Offset, _} = Slots1,
                    Size = bouy_ref_buffer:element_size(Kind),
                    Bytes = max(0, End - Start) * Size,
                    %% The specification copies byte by byte, front to back, which
                    %% a species constructor on the same buffer can observe.
                    Bytes > 0 andalso bouy_ref_buffer:copy_forward(Buffer, Offset + Start * Size, TargetBuffer, TargetOffset, Bytes);
                false ->
                    [bouy_ref:set(A, N, get(O, K)) || {N, K} <- lists:enumerate(0, seq(Start, End - 1))]
            end,
            A
    end;
proto(<<"sort">>, O, Slots, Len, Args) ->
    Compare = comparator(arg(1, Args)),
    Sorted = sort_values([read_element(Slots, K) || K <- seq(0, Len - 1)], Compare),
    Slots1 = slots(O),
    [write_element(Slots1, K, V) || {K, V} <- lists:enumerate(0, Sorted), valid_index(Slots1, K) =/= invalid],
    O;
proto(<<"toSorted">>, _O, {Kind, _, _, _} = Slots, Len, Args) ->
    Compare = comparator(arg(1, Args)),
    A = create(Kind, Len),
    Sorted = sort_values([read_element(Slots, K) || K <- seq(0, Len - 1)], Compare),
    ASlots = slots(A),
    [write_element(ASlots, K, V) || {K, V} <- lists:enumerate(0, Sorted)],
    A;
proto(<<"toReversed">>, O, {Kind, _, _, _}, Len, _) ->
    A = create(Kind, Len),
    ASlots = slots(A),
    [write_element(ASlots, K, to_element(Kind, get(O, Len - K - 1))) || K <- seq(0, Len - 1)],
    A;
proto(<<"with">>, O, {Kind, _, _, _}, Len, Args) ->
    Relative = integer(arg(1, Args)),
    Index = case Relative of
        I when is_integer(I), I >= 0 -> I;
        I when is_integer(I) -> Len + I;
        _ -> -1
    end,
    Value = to_element(Kind, arg(2, Args)),
    valid_index(slots(O), Index) =/= invalid orelse bouy_heap:throw_error('RangeError', <<"Invalid typed array index">>),
    A = create(Kind, Len),
    ASlots = slots(A),
    [write_element(ASlots, K, case K of Index -> Value; _ -> to_element(Kind, get(O, K)) end) || K <- seq(0, Len - 1)],
    A.

start('-Infinity', _Len) -> 0;
start(N, _Len) when N >= 0 -> N;
start(N, Len) -> max(Len + N, 0).

same_value_zero(A, B) when is_number(A), is_number(B) -> A == B;
same_value_zero(A, B) -> A =:= B.

first_index(_O, _Search, []) -> -1;
first_index(O, Search, [K | Rest]) ->
    case element_has(O, K) andalso bouy_ref:strict_eq(get(O, K), Search) of
        true -> K;
        false -> first_index(O, Search, Rest)
    end.

find(O, Args, Indexes, What) ->
    F = callable(arg(1, Args)),
    This = arg(2, Args),
    find_in(Indexes, O, F, This, What).

find_in([], _O, _F, _This, value) -> undefined;
find_in([], _O, _F, _This, index) -> -1;
find_in([K | Rest], O, F, This, What) ->
    V = get(O, K),
    case bouy_ref:truthy(bouy_ref:call(F, This, [V, K, O])) of
        true when What =:= value -> V;
        true -> K;
        false -> find_in(Rest, O, F, This, What)
    end.

reduce(O, Args, Indexes) ->
    F = callable(arg(1, Args)),
    {Acc0, Rest} = case Args of
        [_, Init | _] -> {Init, Indexes};
        _ ->
            case Indexes of
                [] -> type_error(<<"Reduce of empty array with no initial value">>);
                [First | T] -> {get(O, First), T}
            end
    end,
    lists:foldl(fun(K, Acc) -> bouy_ref:call(F, undefined, [Acc, get(O, K), K, O]) end, Acc0, Rest).

comparator(undefined) -> undefined;
comparator(F) ->
    bouy_heap:is_callable(F) orelse type_error(<<"The comparison function must be either a function or undefined">>),
    F.

%% Numbers sort by value with -0 before +0 and NaN last; a comparator
%% sorts with V8's order of calls.
sort_values(Values, undefined) -> lists:sort(fun le/2, Values);
sort_values(Values, F) ->
    bouy_sort:sort(Values, fun(CallArgs) -> bouy_ref:to_number(bouy_ref:call(F, undefined, CallArgs)) end).

le({'$bigint', A}, {'$bigint', B}) -> A =< B;
le('NaN', _) -> false;
le(_, 'NaN') -> true;
le(A, B) ->
    case bouy_ref_number:compare(A, B) of
        lt -> true;
        gt -> false;
        eq -> not (A == 0 andalso B =:= -0.0 andalso A =/= -0.0)
    end.

%% %TypedArray%.prototype.set with an array-like or a typed array source.
set(O, Source, OffsetArg) ->
    Offset = case integer(OffsetArg) of
        I when is_integer(I), I >= 0 -> I;
        'Infinity' -> 'Infinity';
        _ -> bouy_heap:throw_error('RangeError', <<"offset is out of bounds">>)
    end,
    {Kind, Buffer, ByteOffset, _} = Slots = slots(O),
    TargetLength = case length_of(Slots) of
        out_of_bounds -> type_error(<<"Cannot perform %TypedArray%.prototype.set on a detached ArrayBuffer">>);
        L -> L
    end,
    case is_typed_array(Source) of
        true ->
            {SourceKind, SourceBuffer, SourceOffset, _} = SourceSlots = slots(Source),
            SourceLength = case length_of(SourceSlots) of
                out_of_bounds -> type_error(<<"Cannot perform %TypedArray%.prototype.set on a detached ArrayBuffer">>);
                SL -> SL
            end,
            (Offset =:= 'Infinity' orelse SourceLength + Offset > TargetLength) andalso
                bouy_heap:throw_error('RangeError', <<"offset is out of bounds">>),
            bouy_ref_buffer:is_big_int_kind(Kind) =:= bouy_ref_buffer:is_big_int_kind(SourceKind) orelse
                type_error(<<"Cannot mix BigInt and other types, use explicit conversions">>),
            Size = bouy_ref_buffer:element_size(Kind),
            case SourceKind =:= Kind of
                true ->
                    Bytes = SourceLength * Size,
                    Bytes > 0 andalso bouy_ref_buffer:copy(SourceBuffer, SourceOffset, Buffer, ByteOffset + Offset * Size, Bytes);
                false ->
                    Values = [read_element(SourceSlots, K) || K <- seq(0, SourceLength - 1)],
                    [write_element(Slots, Offset + K, V) || {K, V} <- lists:enumerate(0, Values)]
            end;
        false ->
            Src = bouy_ref:to_object(Source),
            SourceLength = bouy_ref_array:length_of(Src),
            (Offset =:= 'Infinity' orelse SourceLength + Offset > TargetLength) andalso
                bouy_heap:throw_error('RangeError', <<"offset is out of bounds">>),
            up(0, SourceLength - 1, fun(K) ->
                                            V = to_element(Kind, bouy_ref:get(Src, K)),
                                            Slots1 = slots(O),
                                            case valid_index(Slots1, Offset + K) of
                                                invalid -> ok;
                                                Index -> write_element(Slots1, Index, V)
                                            end
                                    end)
    end,
    undefined.

subarray(O, StartArg, EndArg) ->
    {Kind, Buffer, ByteOffset, ArrayLength} = Slots = slots(O),
    SourceLength = case length_of(Slots) of
        out_of_bounds -> 0;
        L -> L
    end,
    Start = relative(StartArg, SourceLength),
    Size = bouy_ref_buffer:element_size(Kind),
    BeginOffset = ByteOffset + Start * Size,
    Args = case {ArrayLength, EndArg} of
        {auto, undefined} -> [Buffer, BeginOffset];
        _ ->
            End = relative_end(EndArg, SourceLength),
            [Buffer, BeginOffset, max(End - Start, 0)]
    end,
    species_create(O, Args, <<"subarray">>).
