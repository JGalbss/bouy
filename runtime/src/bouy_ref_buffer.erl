%% The binary data family: ArrayBuffer, SharedArrayBuffer, DataView, and the
%% byte storage and element encodings that typed arrays share.
%%
%% BEAM has no mutable byte array, so the bytes of a buffer live in an
%% atomics array of unsigned 64-bit words: byte I is byte I rem 8 of word
%% I div 8, little-endian, as on the machines Node runs on. A read or write
%% of an element takes one or two word operations. The atomics array is off
%% the process heap; a SharedArrayBuffer shares it with every realm that
%% receives the buffer.
%%
%% The slots of an ArrayBuffer are {Data, ByteLength, MaxByteLength}: Data
%% is the atomics array or detached, and MaxByteLength is none for a fixed
%% length. A SharedArrayBuffer has the class shared_array_buffer and the
%% same slots.
-module(bouy_ref_buffer).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).
-export([allocate/1, allocate/2, byte_length/1, is_detached/1, is_buffer/1, read/3, write/3, copy/5, copy_forward/5, detach/1]).
-export([element_size/1, decode/2, encode/2, is_big_int_kind/1, kinds/0, kind_name/1, to_index/1, species_constructor/2]).

-import(bouy_ref_realm, [arg/2, record/4, ctor_record/5]).

%% shortcut: a buffer holds at most 1 GiB, so a test that allocates a huge
%% buffer gets a RangeError instead of the memory of the machine; raise it
%% when a program needs larger buffers.
-define(MAX_BYTES, 1073741824).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'ArrayBuffer.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"ArrayBuffer.prototype">>, [{<<"slice">>, 2}, {<<"resize">>, 1}, {<<"transfer">>, 0}, {<<"transferToFixedLength">>, 0}])
         ++ [getter(<<"ArrayBuffer.prototype">>, G) || G <- [<<"byteLength">>, <<"maxByteLength">>, <<"resizable">>, <<"detached">>]]
         ++ [{<<"constructor">>, constructor(<<"ArrayBuffer">>)}, {?SYM(toStringTag), <<"ArrayBuffer">>, 4}], none)},
     {'SharedArrayBuffer.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"SharedArrayBuffer.prototype">>, [{<<"slice">>, 2}, {<<"grow">>, 1}])
         ++ [getter(<<"SharedArrayBuffer.prototype">>, G) || G <- [<<"byteLength">>, <<"maxByteLength">>, <<"growable">>]]
         ++ [{<<"constructor">>, constructor(<<"SharedArrayBuffer">>)}, {?SYM(toStringTag), <<"SharedArrayBuffer">>, 4}], none)},
     {'DataView.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"DataView.prototype">>, [{<<"get", N/binary>>, 1} || N <- view_types()] ++ [{<<"set", N/binary>>, 2} || N <- view_types()])
         ++ [getter(<<"DataView.prototype">>, G) || G <- [<<"buffer">>, <<"byteLength">>, <<"byteOffset">>]]
         ++ [{<<"constructor">>, constructor(<<"DataView">>)}, {?SYM(toStringTag), <<"DataView">>, 4}], none)},
     {{builtin, <<"ArrayBuffer">>}, ctor_record(<<"ArrayBuffer">>, 1, {'$o', 'ArrayBuffer.prototype'}, ?METHODS(<<"ArrayBuffer">>, [{<<"isView">>, 1}]) ++ [species(<<"ArrayBuffer">>)], fun(NT, Args) -> construct(array_buffer, NT, Args) end)},
     {{builtin, <<"SharedArrayBuffer">>}, ctor_record(<<"SharedArrayBuffer">>, 1, {'$o', 'SharedArrayBuffer.prototype'}, [species(<<"SharedArrayBuffer">>)], fun(NT, Args) -> construct(shared_array_buffer, NT, Args) end)},
     {{builtin, <<"DataView">>}, ctor_record(<<"DataView">>, 1, {'$o', 'DataView.prototype'}, [], fun construct_view/2)}].

view_types() ->
    [<<"Int8">>, <<"Uint8">>, <<"Int16">>, <<"Uint16">>, <<"Int32">>, <<"Uint32">>, <<"Float16">>, <<"Float32">>, <<"Float64">>,
     <<"BigInt64">>, <<"BigUint64">>].

getter(Owner, Name) ->
    {Name, {'$accessor', bouy_ref_realm:builtin(<<"get ", Owner/binary, ".", Name/binary>>, <<"get ", Name/binary>>, 0,
                                                fun(This, _) -> ?MODULE:method(Owner, Name, This, []) end), undefined}, 4}.

species(Name) ->
    {?SYM(species), {'$accessor', bouy_ref_realm:builtin(<<"get ", Name/binary, "[Symbol.species]">>, <<"get [Symbol.species]">>, 0, fun(This, _) -> This end), undefined}, 4}.

-spec globals() -> [{binary(), term()}].
globals() -> [{N, constructor(N)} || N <- [<<"ArrayBuffer">>, <<"SharedArrayBuffer">>, <<"DataView">>]].

constructor(Name) -> bouy_ref_realm:constructor(?MODULE, Name).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(Name, _This, _Args) -> bouy_ref:type_error(<<"Constructor ", Name/binary, " requires 'new'">>).

%%% Storage

%% A new buffer of ByteLength zero bytes.
-spec allocate(non_neg_integer()) -> term().
allocate(ByteLength) -> allocate(ByteLength, none).

-spec allocate(non_neg_integer(), non_neg_integer() | none) -> term().
allocate(ByteLength, Max) -> create(array_buffer, {'$o', 'ArrayBuffer.prototype'}, ByteLength, Max).

create(Class, Proto, ByteLength, Max) ->
    Capacity = case Max of
        none -> ByteLength;
        _ -> Max
    end,
    Capacity > ?MAX_BYTES andalso bouy_heap:throw_error('RangeError', <<"Array buffer allocation failed">>),
    bouy_heap:new_exotic(Class, Proto, {data(Capacity), ByteLength, Max}).

data(Bytes) -> atomics:new(max(1, (Bytes + 7) div 8), [{signed, false}]).

-spec is_buffer(term()) -> boolean().
is_buffer({'$o', _} = O) ->
    case bouy_heap:class_of(O) of
        array_buffer -> true;
        shared_array_buffer -> true;
        _ -> false
    end;
is_buffer(_) -> false.

-spec byte_length(term()) -> non_neg_integer().
byte_length(Buffer) ->
    case bouy_heap:slots(Buffer) of
        {detached, _, _} -> 0;
        {_, Length, _} -> Length
    end.

-spec is_detached(term()) -> boolean().
is_detached(Buffer) -> element(1, bouy_heap:slots(Buffer)) =:= detached.

-spec detach(term()) -> ok.
detach(Buffer) ->
    {_, _, Max} = bouy_heap:slots(Buffer),
    bouy_heap:set_slots(Buffer, {detached, 0, Max}).

%% Count bytes from Offset, as a binary.
-spec read(term(), non_neg_integer(), non_neg_integer()) -> binary().
read(Buffer, Offset, Count) ->
    {Ref, _, _} = bouy_heap:slots(Buffer),
    read_bytes(Ref, Offset, Count).

read_bytes(_Ref, _Offset, 0) -> <<>>;
read_bytes(Ref, Offset, Count) ->
    First = Offset div 8,
    Last = (Offset + Count - 1) div 8,
    Words = << <<(atomics:get(Ref, W + 1)):64/little>> || W <- lists:seq(First, Last) >>,
    binary:part(Words, Offset - First * 8, Count).

%% Writes Bytes at Offset.
-spec write(term(), non_neg_integer(), binary()) -> ok.
write(Buffer, Offset, Bytes) ->
    {Ref, _, _} = bouy_heap:slots(Buffer),
    write_bytes(Ref, Offset, Bytes).

write_bytes(_Ref, _Offset, <<>>) -> ok;
write_bytes(Ref, Offset, Bytes) ->
    Word = Offset div 8,
    Start = Offset rem 8,
    Take = min(8 - Start, byte_size(Bytes)),
    <<Part:Take/binary, Rest/binary>> = Bytes,
    write_word(Ref, Word + 1, Start, Part),
    write_bytes(Ref, Offset + Take, Rest).

%% Replaces the bytes of a word from Start with Part, through a
%% compare-and-swap, so that a write does not undo the write of another
%% agent to the other bytes of the word.
write_word(Ref, Index, Start, Part) ->
    Old = atomics:get(Ref, Index),
    Take = byte_size(Part),
    <<Before:Start/binary, _:Take/binary, After/binary>> = <<Old:64/little>>,
    <<New:64/little>> = <<Before/binary, Part/binary, After/binary>>,
    case atomics:compare_exchange(Ref, Index, Old, New) of
        ok -> ok;
        _ -> write_word(Ref, Index, Start, Part)
    end.

%% Copies Count bytes from one buffer to another, as a read then a write,
%% so overlapping ranges copy correctly.
-spec copy(term(), non_neg_integer(), term(), non_neg_integer(), non_neg_integer()) -> ok.
copy(From, FromOffset, To, ToOffset, Count) -> write(To, ToOffset, read(From, FromOffset, Count)).

%% Copies Count bytes front to back, one at a time when the ranges overlap
%% with the target after the source, as the byte loop of the specification.
-spec copy_forward(term(), non_neg_integer(), term(), non_neg_integer(), non_neg_integer()) -> ok.
copy_forward(From, FromOffset, To, ToOffset, Count) when From =:= To, ToOffset > FromOffset, ToOffset < FromOffset + Count ->
    Step = ToOffset - FromOffset,
    copy_steps(From, FromOffset, ToOffset, Count, Step);
copy_forward(From, FromOffset, To, ToOffset, Count) -> copy(From, FromOffset, To, ToOffset, Count).

%% Copies in chunks of Step bytes, each read after the previous write.
copy_steps(_Buffer, _From, _To, 0, _Step) -> ok;
copy_steps(Buffer, From, To, Count, Step) ->
    Chunk = min(Step, Count),
    copy(Buffer, From, Buffer, To, Chunk),
    copy_steps(Buffer, From + Chunk, To + Chunk, Count - Chunk, Step).

%%% Element types

-spec kinds() -> [atom()].
kinds() -> [int8, uint8, uint8c, int16, uint16, int32, uint32, float16, float32, float64, bigint64, biguint64].

-spec kind_name(atom()) -> binary().
kind_name(int8) -> <<"Int8Array">>;
kind_name(uint8) -> <<"Uint8Array">>;
kind_name(uint8c) -> <<"Uint8ClampedArray">>;
kind_name(int16) -> <<"Int16Array">>;
kind_name(uint16) -> <<"Uint16Array">>;
kind_name(int32) -> <<"Int32Array">>;
kind_name(uint32) -> <<"Uint32Array">>;
kind_name(float16) -> <<"Float16Array">>;
kind_name(float32) -> <<"Float32Array">>;
kind_name(float64) -> <<"Float64Array">>;
kind_name(bigint64) -> <<"BigInt64Array">>;
kind_name(biguint64) -> <<"BigUint64Array">>.

-spec element_size(atom()) -> 1 | 2 | 4 | 8.
element_size(K) when K =:= int8; K =:= uint8; K =:= uint8c -> 1;
element_size(K) when K =:= int16; K =:= uint16; K =:= float16 -> 2;
element_size(K) when K =:= int32; K =:= uint32; K =:= float32 -> 4;
element_size(_) -> 8.

-spec is_big_int_kind(atom()) -> boolean().
is_big_int_kind(K) -> K =:= bigint64 orelse K =:= biguint64.

%% RawBytesToNumeric: the value of the little-endian bytes of an element.
-spec decode(atom(), binary()) -> term().
decode(int8, <<V:8/signed>>) -> V;
decode(uint8, <<V:8>>) -> V;
decode(uint8c, <<V:8>>) -> V;
decode(int16, <<V:16/signed-little>>) -> V;
decode(uint16, <<V:16/little>>) -> V;
decode(int32, <<V:32/signed-little>>) -> V;
decode(uint32, <<V:32/little>>) -> V;
decode(float16, <<Bits:16/little>>) -> half_value(Bits);
decode(float32, <<Bits:32/little>>) ->
    case Bits band 16#7F800000 of
        16#7F800000 -> special(Bits band 16#7FFFFF, Bits bsr 31);
        _ ->
            <<F:32/float>> = <<Bits:32>>,
            bouy_ref_number:canonical(F)
    end;
decode(float64, <<Bits:64/little>>) ->
    case Bits band 16#7FF0000000000000 of
        16#7FF0000000000000 -> special(Bits band 16#FFFFFFFFFFFFF, Bits bsr 63);
        _ ->
            <<F:64/float>> = <<Bits:64>>,
            bouy_ref_number:canonical(F)
    end;
decode(bigint64, <<V:64/signed-little>>) -> {'$bigint', V};
decode(biguint64, <<V:64/little>>) -> {'$bigint', V}.

special(0, 0) -> 'Infinity';
special(0, 1) -> '-Infinity';
special(_, _) -> 'NaN'.

half_value(Bits) ->
    Sign = case Bits bsr 15 of
        0 -> 1;
        1 -> -1
    end,
    Exp = (Bits bsr 10) band 16#1F,
    Frac = Bits band 16#3FF,
    case Exp of
        31 when Frac =:= 0 -> case Sign of 1 -> 'Infinity'; -1 -> '-Infinity' end;
        31 -> 'NaN';
        0 when Frac =:= 0, Sign =:= -1 -> -0.0;
        0 -> bouy_ref_number:canonical(Sign * Frac / 16777216);
        _ -> bouy_ref_number:canonical(Sign * (1024 + Frac) * math:pow(2, Exp - 25))
    end.

%% NumericToRawBytes: the bytes of a value that is already a number of the
%% type, or a BigInt for the 64-bit integer types.
-spec encode(atom(), term()) -> binary().
encode(int8, N) -> <<(int_bits(N, 8)):8>>;
encode(uint8, N) -> <<(int_bits(N, 8)):8>>;
encode(uint8c, N) -> <<(clamp(N)):8>>;
encode(int16, N) -> <<(int_bits(N, 16)):16/little>>;
encode(uint16, N) -> <<(int_bits(N, 16)):16/little>>;
encode(int32, N) -> <<(int_bits(N, 32)):32/little>>;
encode(uint32, N) -> <<(int_bits(N, 32)):32/little>>;
encode(float16, N) -> <<(half_bits(N)):16/little>>;
encode(float32, 'NaN') -> <<16#7FC00000:32/little>>;
encode(float32, 'Infinity') -> <<16#7F800000:32/little>>;
encode(float32, '-Infinity') -> <<16#FF800000:32/little>>;
encode(float32, N) -> <<(float(N)):32/float-little>>;
encode(float64, 'NaN') -> <<16#7FF8000000000000:64/little>>;
encode(float64, 'Infinity') -> <<16#7FF0000000000000:64/little>>;
encode(float64, '-Infinity') -> <<16#FFF0000000000000:64/little>>;
encode(float64, N) -> <<(float(N)):64/float-little>>;
encode(bigint64, {'$bigint', I}) -> <<I:64/little>>;
encode(biguint64, {'$bigint', I}) -> <<I:64/little>>.

%% The low Bits of ToIntegerOrInfinity of N, as ToInt8 through ToUint32 take
%% them; NaN and the infinities are 0.
int_bits(N, Bits) when is_integer(N) -> N band ((1 bsl Bits) - 1);
int_bits(N, Bits) when is_float(N) -> trunc(N) band ((1 bsl Bits) - 1);
int_bits(_, _) -> 0.

%% ToUint8Clamp: round half to even into 0..255.
clamp('NaN') -> 0;
clamp('Infinity') -> 255;
clamp('-Infinity') -> 0;
clamp(N) when N =< 0 -> 0;
clamp(N) when N >= 255 -> 255;
clamp(N) when is_integer(N) -> N;
clamp(F) ->
    Floor = trunc(math:floor(F)),
    case F - Floor of
        Half when Half < 0.5 -> Floor;
        Half when Half > 0.5 -> Floor + 1;
        _ when Floor rem 2 =:= 0 -> Floor;
        _ -> Floor + 1
    end.

half_bits('NaN') -> 16#7E00;
half_bits('Infinity') -> 16#7C00;
half_bits('-Infinity') -> 16#FC00;
half_bits(N) ->
    Rounded = bouy_ref_math:f16round(N),
    Sign = case Rounded =:= -0.0 orelse (is_number(Rounded) andalso Rounded < 0) orelse Rounded =:= '-Infinity' of
        true -> 16#8000;
        false -> 0
    end,
    case Rounded of
        'Infinity' -> 16#7C00;
        '-Infinity' -> 16#FC00;
        Z when Z == 0 -> Sign;
        V -> Sign bor magnitude_bits(abs(V))
    end.

%% The exponent and fraction bits of a positive binary16 value.
magnitude_bits(V) when V < 6.103515625e-5 -> round(V * 16777216);
magnitude_bits(V) ->
    E = floor(math:log2(V)),
    Low = pow2(E),
    Exp = if
        V >= 2 * Low -> E + 1;
        V < Low -> E - 1;
        true -> E
    end,
    Frac = round((V / pow2(Exp) - 1) * 1024),
    ((Exp + 15) bsl 10) bor Frac.

pow2(E) -> math:pow(2, E).

%% ToIndex.
-spec to_index(term()) -> non_neg_integer().
to_index(undefined) -> 0;
to_index(V) ->
    case bouy_ref_number:to_integer_or_infinity(bouy_ref:to_number(V)) of
        I when is_integer(I), I >= 0, I =< 9007199254740991 -> I;
        _ -> bouy_heap:throw_error('RangeError', <<"Invalid index: must be a safe integer">>)
    end.

%%% ArrayBuffer and SharedArrayBuffer

construct(Class, NewTarget, Args) ->
    Default = case Class of
        array_buffer -> 'ArrayBuffer.prototype';
        shared_array_buffer -> 'SharedArrayBuffer.prototype'
    end,
    ByteLength = to_index(arg(1, Args)),
    Max = max_byte_length(arg(2, Args)),
    Max =/= none andalso ByteLength > Max andalso
        bouy_heap:throw_error('RangeError', <<"Invalid array buffer length: larger than maxByteLength">>),
    Proto = bouy_ref_realm:proto_for(NewTarget, Default),
    create(Class, Proto, ByteLength, Max).

max_byte_length(Options) when ?IS_OBJECT(Options) ->
    case bouy_ref:get(Options, <<"maxByteLength">>) of
        undefined -> none;
        V -> to_index(V)
    end;
max_byte_length(_) -> none.

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"ArrayBuffer">>, <<"isView">>, _This, Args) ->
    V = arg(1, Args),
    ?IS_OBJECT(V) andalso lists:member(bouy_heap:class_of(V), [typed_array, data_view]);
method(<<"ArrayBuffer.prototype">>, Name, This, Args) -> buffer_proto(Name, this_buffer(This, array_buffer, Name), Args);
method(<<"SharedArrayBuffer.prototype">>, Name, This, Args) -> shared_proto(Name, this_buffer(This, shared_array_buffer, Name), Args);
method(<<"DataView.prototype">>, Name, This, Args) -> view_proto(Name, this_view(This, Name), Args).

this_buffer({'$o', _} = O, Class, Name) ->
    case bouy_heap:class_of(O) of
        Class -> O;
        _ -> incompatible(Class, Name)
    end;
this_buffer(_, Class, Name) -> incompatible(Class, Name).

-spec incompatible(atom(), binary()) -> no_return().
incompatible(array_buffer, Name) -> bouy_ref:type_error(<<"Method ArrayBuffer.prototype.", Name/binary, " called on incompatible receiver">>);
incompatible(shared_array_buffer, Name) -> bouy_ref:type_error(<<"Method SharedArrayBuffer.prototype.", Name/binary, " called on incompatible receiver">>).

-spec detached_error() -> no_return().
detached_error() -> bouy_ref:type_error(<<"Cannot perform this operation on a detached ArrayBuffer">>).

buffer_proto(<<"byteLength">>, B, _) -> byte_length(B);
buffer_proto(<<"maxByteLength">>, B, _) ->
    case bouy_heap:slots(B) of
        {detached, _, _} -> 0;
        {_, Length, none} -> Length;
        {_, _, Max} -> Max
    end;
buffer_proto(<<"resizable">>, B, _) -> element(3, bouy_heap:slots(B)) =/= none;
buffer_proto(<<"detached">>, B, _) -> is_detached(B);
buffer_proto(<<"resize">>, B, Args) ->
    {_, _, Max} = bouy_heap:slots(B),
    Max =:= none andalso bouy_ref:type_error(<<"Method ArrayBuffer.prototype.resize called on incompatible receiver">>),
    NewLength = to_index(arg(1, Args)),
    is_detached(B) andalso detached_error(),
    NewLength > Max andalso bouy_heap:throw_error('RangeError', <<"ArrayBuffer.prototype.resize: Invalid length parameter">>),
    {Ref, Old, _} = bouy_heap:slots(B),
    NewLength < Old andalso write_bytes(Ref, NewLength, binary:copy(<<0>>, Old - NewLength)),
    bouy_heap:set_slots(B, {Ref, NewLength, Max}),
    undefined;
buffer_proto(<<"slice">>, B, Args) ->
    is_detached(B) andalso detached_error(),
    Len = byte_length(B),
    First = relative(arg(1, Args), Len, 0),
    Final = relative(arg(2, Args), Len, Len),
    NewLength = max(Final - First, 0),
    C = species_constructor(B, constructor(<<"ArrayBuffer">>)),
    New = bouy_ref:construct(C, [NewLength]),
    (?IS_OBJECT(New) andalso bouy_heap:class_of(New) =:= array_buffer) orelse bouy_ref:type_error(<<"The species constructor did not make an ArrayBuffer">>),
    is_detached(New) andalso detached_error(),
    New =:= B andalso bouy_ref:type_error(<<"The species constructor returned the same ArrayBuffer">>),
    byte_length(New) < NewLength andalso bouy_ref:type_error(<<"The species constructor made a buffer that is too small">>),
    is_detached(B) andalso detached_error(),
    CurrentLength = byte_length(B),
    Count = max(0, min(NewLength, CurrentLength - First)),
    Count > 0 andalso copy(B, First, New, 0, Count),
    New;
buffer_proto(<<"transfer">>, B, Args) -> transfer(B, arg(1, Args), preserve);
buffer_proto(<<"transferToFixedLength">>, B, Args) -> transfer(B, arg(1, Args), fixed).

%% ArrayBufferCopyAndDetach.
transfer(B, LengthArg, Mode) ->
    NewLength = case LengthArg of
        undefined -> byte_length(B);
        _ -> to_index(LengthArg)
    end,
    is_detached(B) andalso detached_error(),
    {Ref, Old, Max} = bouy_heap:slots(B),
    NewMax = case Mode of
        preserve -> Max;
        fixed -> none
    end,
    NewMax =/= none andalso NewLength > NewMax andalso bouy_heap:throw_error('RangeError', <<"Invalid array buffer length">>),
    New = allocate(NewLength, NewMax),
    Count = min(NewLength, Old),
    Count > 0 andalso write(New, 0, read_bytes(Ref, 0, Count)),
    detach(B),
    New.

shared_proto(<<"byteLength">>, B, _) -> byte_length(B);
shared_proto(<<"maxByteLength">>, B, _) ->
    case bouy_heap:slots(B) of
        {_, Length, none} -> Length;
        {_, _, Max} -> Max
    end;
shared_proto(<<"growable">>, B, _) -> element(3, bouy_heap:slots(B)) =/= none;
shared_proto(<<"grow">>, B, Args) ->
    {Ref, Old, Max} = bouy_heap:slots(B),
    Max =:= none andalso bouy_ref:type_error(<<"Method SharedArrayBuffer.prototype.grow called on incompatible receiver">>),
    NewLength = to_index(arg(1, Args)),
    (NewLength > Max orelse NewLength < Old) andalso bouy_heap:throw_error('RangeError', <<"SharedArrayBuffer.prototype.grow: Invalid length parameter">>),
    bouy_heap:set_slots(B, {Ref, NewLength, Max}),
    undefined;
shared_proto(<<"slice">>, B, Args) ->
    Len = byte_length(B),
    First = relative(arg(1, Args), Len, 0),
    Final = relative(arg(2, Args), Len, Len),
    NewLength = max(Final - First, 0),
    C = species_constructor(B, constructor(<<"SharedArrayBuffer">>)),
    New = bouy_ref:construct(C, [NewLength]),
    (?IS_OBJECT(New) andalso bouy_heap:class_of(New) =:= shared_array_buffer) orelse bouy_ref:type_error(<<"The species constructor did not make a SharedArrayBuffer">>),
    New =:= B andalso bouy_ref:type_error(<<"The species constructor returned the same SharedArrayBuffer">>),
    byte_length(New) < NewLength andalso bouy_ref:type_error(<<"The species constructor made a buffer that is too small">>),
    NewLength > 0 andalso copy(B, First, New, 0, NewLength),
    New.

relative(undefined, _Len, Default) -> Default;
relative(V, Len, _Default) ->
    case bouy_ref_number:to_integer_or_infinity(bouy_ref:to_number(V)) of
        '-Infinity' -> 0;
        'Infinity' -> Len;
        I when I < 0 -> max(Len + I, 0);
        I -> min(I, Len)
    end.

%% SpeciesConstructor(O, Default).
-spec species_constructor(term(), term()) -> term().
species_constructor(O, Default) ->
    case bouy_ref:get(O, <<"constructor">>) of
        undefined -> Default;
        C when ?IS_OBJECT(C) ->
            case bouy_ref:get(C, ?SYM(species)) of
                S when S =:= undefined; S =:= null -> Default;
                S ->
                    bouy_ref_array:is_constructor(S) orelse bouy_ref:type_error(<<"object.constructor[Symbol.species] is not a constructor">>),
                    S
            end;
        _ -> bouy_ref:type_error(<<"The .constructor property is not an object">>)
    end.

%%% DataView

%% The slots of a DataView: {Buffer, ByteOffset, ByteLength}, where
%% ByteLength is auto for a view that tracks a resizable buffer.
construct_view(NewTarget, Args) ->
    Buffer = arg(1, Args),
    is_buffer(Buffer) orelse bouy_ref:type_error(<<"First argument to DataView constructor must be an ArrayBuffer">>),
    Offset = to_index(arg(2, Args)),
    is_detached(Buffer) andalso detached_error(),
    BufferLength = byte_length(Buffer),
    Offset > BufferLength andalso bouy_heap:throw_error('RangeError', <<"Start offset is outside the bounds of the buffer">>),
    Tracking = element(3, bouy_heap:slots(Buffer)) =/= none andalso arg(3, Args) =:= undefined,
    ViewLength = case arg(3, Args) of
        undefined when Tracking -> auto;
        undefined -> BufferLength - Offset;
        L ->
            Length = to_index(L),
            Offset + Length > BufferLength andalso bouy_heap:throw_error('RangeError', <<"Invalid DataView length">>),
            Length
    end,
    Proto = bouy_ref_realm:proto_for(NewTarget, 'DataView.prototype'),
    is_detached(Buffer) andalso detached_error(),
    NewBufferLength = byte_length(Buffer),
    Offset > NewBufferLength andalso bouy_heap:throw_error('RangeError', <<"Start offset is outside the bounds of the buffer">>),
    is_integer(ViewLength) andalso Offset + ViewLength > NewBufferLength andalso bouy_heap:throw_error('RangeError', <<"Invalid DataView length">>),
    bouy_heap:new_exotic(data_view, Proto, {Buffer, Offset, ViewLength}).

this_view({'$o', _} = O, Name) ->
    case bouy_heap:class_of(O) of
        data_view -> O;
        _ -> bouy_ref:type_error(<<"Method DataView.prototype.", Name/binary, " called on incompatible receiver">>)
    end;
this_view(_, Name) -> bouy_ref:type_error(<<"Method DataView.prototype.", Name/binary, " called on incompatible receiver">>).

%% The byte length of a view, or out_of_bounds.
view_length(View) ->
    {Buffer, Offset, Length} = bouy_heap:slots(View),
    case is_detached(Buffer) of
        true -> out_of_bounds;
        false ->
            BufferLength = byte_length(Buffer),
            case Length of
                auto when Offset =< BufferLength -> BufferLength - Offset;
                auto -> out_of_bounds;
                _ when Offset + Length =< BufferLength -> Length;
                _ -> out_of_bounds
            end
    end.

view_proto(<<"buffer">>, V, _) -> element(1, bouy_heap:slots(V));
view_proto(<<"byteLength">>, V, _) ->
    case view_length(V) of
        out_of_bounds -> bouy_ref:type_error(<<"Cannot perform DataView.prototype.byteLength on a detached or out of bounds view">>);
        L -> L
    end;
view_proto(<<"byteOffset">>, V, _) ->
    case view_length(V) of
        out_of_bounds -> bouy_ref:type_error(<<"Cannot perform DataView.prototype.byteOffset on a detached or out of bounds view">>);
        _ -> element(2, bouy_heap:slots(V))
    end;
view_proto(<<"get", Type/binary>>, V, Args) ->
    Kind = view_kind(Type),
    Index = to_index(arg(1, Args)),
    Little = bouy_ref:truthy(arg(2, Args)),
    {Buffer, Offset, Size} = view_access(V, Index, Kind),
    Bytes = read(Buffer, Offset + Index, Size),
    decode(Kind, order(Bytes, Little));
view_proto(<<"set", Type/binary>>, V, Args) ->
    Kind = view_kind(Type),
    Index = to_index(arg(1, Args)),
    Value = case is_big_int_kind(Kind) of
        true -> bouy_ref_bigint:to_big_int(arg(2, Args));
        false -> bouy_ref:to_number(arg(2, Args))
    end,
    Little = bouy_ref:truthy(arg(3, Args)),
    {Buffer, Offset, _} = view_access(V, Index, Kind),
    write(Buffer, Offset + Index, order(encode(Kind, Value), Little)),
    undefined.

%% The buffer, offset, and element size of an access, after the checks of
%% GetViewValue and SetViewValue.
view_access(V, Index, Kind) ->
    case view_length(V) of
        out_of_bounds -> bouy_ref:type_error(<<"Cannot perform DataView access on a detached or out of bounds view">>);
        Length ->
            Size = element_size(Kind),
            Index + Size > Length andalso bouy_heap:throw_error('RangeError', <<"Offset is outside the bounds of the DataView">>),
            {Buffer, Offset, _} = bouy_heap:slots(V),
            {Buffer, Offset, Size}
    end.

%% The little-endian bytes of an element in the order of the access.
order(Bytes, true) -> Bytes;
order(Bytes, false) -> list_to_binary(lists:reverse(binary_to_list(Bytes))).

view_kind(<<"Int8">>) -> int8;
view_kind(<<"Uint8">>) -> uint8;
view_kind(<<"Int16">>) -> int16;
view_kind(<<"Uint16">>) -> uint16;
view_kind(<<"Int32">>) -> int32;
view_kind(<<"Uint32">>) -> uint32;
view_kind(<<"Float16">>) -> float16;
view_kind(<<"Float32">>) -> float32;
view_kind(<<"Float64">>) -> float64;
view_kind(<<"BigInt64">>) -> bigint64;
view_kind(<<"BigUint64">>) -> biguint64.
