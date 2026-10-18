%% internalBinding('serdes') (src/node_serdes.cc): Serializer and Deserializer,
%% the classes under v8.serialize, v8.deserialize, and node:test. They write
%% and read the wire format of V8's ValueSerializer (src/objects/value-serializer.cc),
%% version 15, so the bytes match Node's.
-module(buoy_binding_serdes).

-include("buoy_ref.hrl").

-export([binding/0]).

%% A function that only throws is a named fun, for dialyzer (node-builtins.md).
-dialyzer({no_return, [data_clone_error/2, invalid_data/0, failed/1, illegal/0, construct_call/1]}).

-define(VERSION, 15).
-define(STATE, {'#', ?MODULE, <<"state">>}).

-spec binding() -> term().
binding() ->
    Serializer = buoy_node:constructor(<<"Serializer">>, 0, fun(This, _) -> new_serializer(This) end),
    methods(Serializer, [
        {<<"writeHeader">>, fun(This, _) -> write(This, fun(S) -> append(S, <<16#FF, ?VERSION>>) end) end},
        {<<"writeValue">>, fun(This, A) -> write(This, fun(S) -> write_value(This, S, buoy_node:arg(1, A)) end), true end},
        {<<"releaseBuffer">>, fun release_buffer/2},
        {<<"transferArrayBuffer">>, fun transfer_out/2},
        {<<"writeUint32">>, fun(This, A) -> write(This, fun(S) -> append(S, varint(uint32(buoy_node:arg(1, A)))) end) end},
        {<<"writeUint64">>, fun(This, A) ->
            Value = (uint32(buoy_node:arg(1, A)) bsl 32) bor uint32(buoy_node:arg(2, A)),
            write(This, fun(S) -> append(S, varint(Value)) end)
        end},
        {<<"writeDouble">>, fun(This, A) -> write(This, fun(S) -> append(S, double(buoy_ref:to_number(buoy_node:arg(1, A)))) end) end},
        {<<"writeRawBytes">>, fun(This, A) ->
            Source = view_arg(buoy_node:arg(1, A), <<"source must be a TypedArray or a DataView">>),
            write(This, fun(S) -> append(S, buoy_node_encoding:view_bytes(Source)) end)
        end},
        {<<"_setTreatArrayBufferViewsAsHostObjects">>, fun(This, A) ->
            write(This, fun(S) -> S#{treat := buoy_ref:truthy(buoy_node:arg(1, A))} end)
        end}
    ]),
    Deserializer = buoy_node:constructor(<<"Deserializer">>, 1, fun(This, A) -> new_deserializer(This, buoy_node:arg(1, A)) end),
    methods(Deserializer, [
        {<<"readHeader">>, fun read_header/2},
        {<<"readValue">>, fun(This, _) -> read(This, fun(S) -> read_value(This, S) end) end},
        {<<"readUint32">>, fun(This, _) -> read(This, fun(S) -> read_varint(S, <<"ReadUint32() failed">>, 32) end) end},
        {<<"readUint64">>, fun(This, _) ->
            Value = read(This, fun(S) -> read_varint(S, <<"ReadUint64() failed">>, 64) end),
            buoy_heap:new_array([Value bsr 32, Value band 16#FFFFFFFF])
        end},
        {<<"readDouble">>, fun(This, _) -> read(This, fun(S) -> read_double(S, <<"ReadDouble() failed">>) end) end},
        {<<"_readRawBytes">>, fun(This, A) ->
            Length = trunc_length(buoy_node:arg(1, A)),
            read(This, fun(#{pos := Pos} = S) ->
                take(S, Length, <<"ReadRawBytes() failed">>),
                {Pos, S#{pos := Pos + Length}}
            end)
        end},
        {<<"getWireFormatVersion">>, fun(This, _) -> maps:get(version, state(This)) end},
        {<<"transferArrayBuffer">>, fun transfer_in/2}
    ]),
    buoy_node:object([{<<"Serializer">>, Serializer}, {<<"Deserializer">>, Deserializer}]).

methods(Class, Methods) ->
    Proto = buoy_heap:get(Class, <<"prototype">>),
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    ok.

%%% State

new_serializer(This) ->
    is_instance(This) orelse construct_call(<<"Serializer">>),
    buoy_heap:private_put(This, ?STATE, #{bytes => [], size => 0, treat => false, ids => #{}, next => 0, transfers => #{}}),
    undefined.

new_deserializer(This, Buffer) ->
    is_instance(This) orelse construct_call(<<"Deserializer">>),
    View = view_arg(Buffer, <<"buffer must be a TypedArray or a DataView">>),
    buoy_heap:define(This, <<"buffer">>, #{value => View, writable => true, enumerable => true, configurable => true}),
    buoy_heap:private_put(This, ?STATE, #{bin => buoy_node_encoding:view_bytes(View), pos => 0, version => 0,
                                          ids => #{}, next => 0, transfers => #{}}),
    undefined.

is_instance(This) -> buoy_heap:is_object(This).

state(This) ->
    case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, ?STATE) of
        {ok, S} -> S;
        _ -> illegal()
    end.

save(This, S) -> buoy_heap:private_put(This, ?STATE, S).

%% Runs Fun on the state of a Serializer and keeps what it returns.
write(This, Fun) ->
    save(This, Fun(state(This))),
    undefined.

%% Runs Fun on the state of a Deserializer: Fun returns {Value, State}.
read(This, Fun) ->
    {Value, S} = Fun(state(This)),
    save(This, S),
    Value.

-spec illegal() -> no_return().
illegal() -> buoy_ref:type_error(<<"Illegal invocation">>).

-spec construct_call(binary()) -> no_return().
construct_call(Name) ->
    buoy_node:throw_code('TypeError', <<"ERR_CONSTRUCT_CALL_REQUIRED">>,
                         <<"Class constructor ", Name/binary, " cannot be invoked without 'new'">>).

view_arg(V, Message) ->
    case buoy_heap:is_object(V) andalso lists:member(buoy_heap:class_of(V), [typed_array, data_view]) of
        true -> V;
        false -> buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>, Message)
    end.

uint32(V) -> buoy_ref_number:to_uint32(buoy_ref:to_number(V)).

trunc_length(V) ->
    case buoy_ref:to_number(V) of
        N when is_integer(N), N >= 0 -> N;
        N when is_float(N), N >= 0 -> trunc(N);
        _ -> 0
    end.

%%% Serializer

append(#{bytes := Bytes, size := Size} = S, Data) ->
    S#{bytes := [Bytes | Data], size := Size + iolist_size(Data)}.

release_buffer(This, _) ->
    #{bytes := Bytes} = S = state(This),
    save(This, S#{bytes := [], size := 0}),
    buoy_node_encoding:new_buffer(iolist_to_binary(Bytes)).

transfer_out(This, A) ->
    Id = uint32(buoy_node:arg(1, A)),
    Buffer = buoy_node:arg(2, A),
    buoy_heap:is_object(Buffer) andalso buoy_heap:class_of(Buffer) =:= array_buffer orelse
        buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>, <<"arrayBuffer must be an ArrayBuffer">>),
    write(This, fun(#{transfers := T} = S) -> S#{transfers := T#{key(Buffer) => Id}} end).

key(V) -> element(2, V).

write_value(_This, S, undefined) -> append(S, <<"_">>);
write_value(_This, S, null) -> append(S, <<"0">>);
write_value(_This, S, true) -> append(S, <<"T">>);
write_value(_This, S, false) -> append(S, <<"F">>);
write_value(_This, S, {'$bigint', N}) -> append(S, [<<"Z">>, bigint(N)]);
write_value(_This, S, V) when ?IS_NUMBER(V) -> append(S, number(V));
write_value(_This, S, V) when ?IS_STRING(V) -> write_string(S, V);
write_value(This, _S, {'$sym', _, _} = V) -> data_clone_error(This, buoy_ref:describe(V));
write_value(This, S, V) when ?IS_OBJECT(V) -> write_object(This, S, V).

number(I) when is_integer(I), I >= -16#80000000, I =< 16#7FFFFFFF -> [<<"I">>, varint(zigzag(I))];
number(N) -> [<<"N">>, double(N)].

zigzag(I) when I >= 0 -> I bsl 1;
zigzag(I) -> ((-I) bsl 1) - 1.

double('NaN') -> <<0, 0, 0, 0, 0, 0, 16#F8, 16#7F>>;
double('Infinity') -> <<0, 0, 0, 0, 0, 0, 16#F0, 16#7F>>;
double('-Infinity') -> <<0, 0, 0, 0, 0, 0, 16#F0, 16#FF>>;
double(N) -> <<(float(N)):64/float-little>>.

varint(N) when N < 128 -> <<N>>;
varint(N) -> <<(N band 127 bor 128), (varint(N bsr 7))/binary>>.

%% A BigInt: the bit field (byte length << 1 | sign), then 64-bit digits,
%% least significant first.
bigint(N) ->
    Digits = digits(abs(N), []),
    Sign = case N < 0 of true -> 1; false -> 0 end,
    [varint((length(Digits) * 8) bsl 1 bor Sign) | Digits].

digits(0, Acc) -> lists:reverse(Acc);
digits(N, Acc) -> digits(N bsr 64, [<<(N band 16#FFFFFFFFFFFFFFFF):64/little>> | Acc]).

%% A string of Latin-1 code units takes one byte each. A two-byte string is
%% aligned so that its UTF-16 data starts at an even offset.
write_string(S, V) when is_binary(V) ->
    append(S, [<<"\"">>, varint(byte_size(V)), V]);
write_string(#{size := Size} = S, {'$u16', Big}) ->
    Length = varint(byte_size(Big)),
    Padding = case (Size + 1 + byte_size(Length)) band 1 of
        1 -> <<0>>;
        0 -> <<>>
    end,
    append(S, [Padding, <<"c">>, Length, << <<U:16/little>> || <<U:16/big>> <= Big >>]).

%% A view writes its buffer first, before it takes an id of its own, unless
%% the views are host objects.
write_object(This, #{ids := Ids} = S, V) ->
    case maps:find(key(V), Ids) of
        {ok, Id} ->
            append(S, [<<"^">>, varint(Id)]);
        error ->
            S1 = case is_view(V) andalso not maps:get(treat, S) of
                true -> write_object(This, S, view_buffer(V));
                false -> S
            end,
            #{ids := Ids1, next := Next} = S1,
            case maps:find(key(V), Ids1) of
                {ok, Id} -> append(S1, [<<"^">>, varint(Id)]);
                error -> write_receiver(This, S1#{ids := Ids1#{key(V) => Next}, next := Next + 1}, V)
            end
    end.

is_view({'$o', _} = V) -> lists:member(buoy_heap:class_of(V), [typed_array, data_view]);
is_view(_) -> false.

view_buffer(V) -> element(2, view_slots(V)).

view_slots(V) ->
    case buoy_heap:slots(V) of
        {Kind, Buffer, Offset, Length} -> {Kind, Buffer, Offset, Length};
        {Buffer, Offset, Length} -> {data_view, Buffer, Offset, Length}
    end.

write_receiver(This, _S, {'$f', _, _} = F) ->
    data_clone_error(This, buoy_ref:to_string(F));
write_receiver(This, S, V) ->
    case buoy_heap:class_of(V) of
        object -> write_properties(This, append(S, <<"o">>), V, buoy_heap:enumerable_keys(V), <<"{">>, []);
        array -> write_array(This, S, V);
        date -> append(S, [<<"D">>, double(buoy_heap:slots(V))]);
        boolean -> append(S, case buoy_heap:slots(V) of true -> <<"y">>; false -> <<"x">> end);
        number -> append(S, [<<"n">>, double(buoy_heap:slots(V))]);
        bigint -> {'$bigint', N} = buoy_heap:slots(V), append(S, [<<"z">>, bigint(N)]);
        string -> write_string(append(S, <<"s">>), buoy_heap:slots(V));
        regexp -> write_regexp(S, V);
        map -> write_map(This, S, V);
        set -> write_set(This, S, V);
        array_buffer -> write_array_buffer(This, S, V);
        shared_array_buffer -> data_clone_error(This, <<"#<SharedArrayBuffer>">>);
        Class when Class =:= typed_array; Class =:= data_view -> write_view(This, S, V);
        error -> write_error(This, S, V);
        _ -> data_clone_error(This, <<"#<", (constructor_name(V))/binary, ">">>)
    end.

constructor_name(V) ->
    try buoy_heap:get(buoy_heap:get(V, <<"constructor">>), <<"name">>) of
        Name when is_binary(Name), Name =/= <<>> -> Name;
        _ -> <<"Object">>
    catch _:_ -> <<"Object">>
    end.

%% The own enumerable keys, an index as a number, then the end tag and the
%% count of the pairs written.
write_properties(This, S, V, Keys, End, Counts) ->
    {S1, Written} = lists:foldl(fun(K, {Acc, N}) ->
        case buoy_heap:get_own(V, K) of
            none -> {Acc, N};
            _ ->
                Value = buoy_heap:get(V, K),
                {write_value(This, write_value(This, Acc, K), Value), N + 1}
        end
    end, {S, 0}, Keys),
    append(S1, [End, varint(Written) | [varint(C) || C <- Counts]]).

write_array(This, S, V) ->
    Length = buoy_heap:get(V, <<"length">>),
    Keys = buoy_heap:enumerable_keys(V),
    Indexes = [K || K <- Keys, is_integer(K)],
    case length(Indexes) =:= Length of
        true ->
            S1 = lists:foldl(fun(I, Acc) -> write_value(This, Acc, buoy_heap:get(V, I)) end,
                             append(S, [<<"A">>, varint(Length)]), lists:seq(0, Length - 1)),
            write_properties(This, S1, V, [K || K <- Keys, not is_integer(K)], <<"$">>, [Length]);
        false ->
            write_properties(This, append(S, [<<"a">>, varint(Length)]), V, Keys, <<"@">>, [Length])
    end.

write_regexp(S, V) ->
    #{source := Source, flags := Flags} = buoy_heap:slots(V),
    Bits = lists:sum([Bit || {Char, Bit} <- [{$g, 1}, {$i, 2}, {$m, 4}, {$y, 8}, {$u, 16}, {$s, 32}, {$d, 128}, {$v, 256}],
                             binary:match(buoy_ref_string:to_utf8(Flags), <<Char>>) =/= nomatch]),
    append(write_string(append(S, <<"R">>), Source), varint(Bits)).

write_map(This, S, V) ->
    {Index, _} = buoy_heap:slots(V),
    Entries = [{K, Value} || {_, K, Value} <- lists:sort([{Seq, K, Value} || K := {Seq, Value} <- Index])],
    S1 = lists:foldl(fun({K, Value}, Acc) -> write_value(This, write_value(This, Acc, K), Value) end,
                     append(S, <<";">>), Entries),
    append(S1, [<<":">>, varint(2 * length(Entries))]).

write_set(This, S, V) ->
    {Index, _} = buoy_heap:slots(V),
    Members = [K || {_, K} <- lists:sort([{Seq, K} || K := Seq <- Index])],
    S1 = lists:foldl(fun(K, Acc) -> write_value(This, Acc, K) end, append(S, <<"'">>), Members),
    append(S1, [<<",">>, varint(length(Members))]).

write_array_buffer(This, #{transfers := Transfers} = S, V) ->
    case maps:find(key(V), Transfers) of
        {ok, Id} ->
            append(S, [<<"t">>, varint(Id)]);
        error ->
            buoy_ref_buffer:is_detached(V) andalso
                data_clone_error(This, <<"An ArrayBuffer is detached and could not be cloned.">>),
            {_, Length, Max} = buoy_heap:slots(V),
            Bytes = buoy_ref_buffer:read(V, 0, Length),
            case Max of
                none -> append(S, [<<"B">>, varint(Length), Bytes]);
                _ -> append(S, [<<"~">>, varint(Length), varint(Max), Bytes])
            end
    end.

write_view(This, #{treat := true} = S, V) ->
    write_host_object(This, append(S, <<"\\">>), V);
write_view(_This, S, V) ->
    {Kind, Buffer, Offset, Length} = view_slots(V),
    ByteLength = buoy_node_encoding:view_length(V),
    {_, _, Max} = buoy_heap:slots(Buffer),
    Flags = (case Length of auto -> 1; _ -> 0 end) bor (case Max of none -> 0; _ -> 2 end),
    append(S, [<<"V">>, subtag(Kind), varint(Offset), varint(ByteLength), varint(Flags)]).

subtag(int8) -> <<"b">>;
subtag(uint8) -> <<"B">>;
subtag(uint8c) -> <<"C">>;
subtag(int16) -> <<"w">>;
subtag(uint16) -> <<"W">>;
subtag(int32) -> <<"d">>;
subtag(uint32) -> <<"D">>;
subtag(float16) -> <<"h">>;
subtag(float32) -> <<"f">>;
subtag(float64) -> <<"F">>;
subtag(bigint64) -> <<"q">>;
subtag(biguint64) -> <<"Q">>;
subtag(data_view) -> <<"?">>.

%% this._writeHostObject(view) writes into this Serializer, so the state goes
%% back to it for the call.
write_host_object(This, S, V) ->
    save(This, S),
    Writer = buoy_heap:get(This, <<"_writeHostObject">>),
    buoy_heap:is_callable(Writer) orelse data_clone_error(This, <<"Unserializable host object">>),
    buoy_heap:call(Writer, This, [V]),
    state(This).

write_error(This, S, V) ->
    Name = buoy_ref:to_string(buoy_heap:get(V, <<"name">>)),
    Prototype = case Name of
        <<"EvalError">> -> <<"E">>;
        <<"RangeError">> -> <<"R">>;
        <<"ReferenceError">> -> <<"F">>;
        <<"SyntaxError">> -> <<"S">>;
        <<"TypeError">> -> <<"T">>;
        <<"URIError">> -> <<"U">>;
        _ -> <<>>
    end,
    S1 = append(S, [<<"r">>, Prototype]),
    S2 = case buoy_heap:get_own(V, <<"message">>) of
        {data, Message, _} -> write_string(append(S1, <<"m">>), buoy_ref:to_string(Message));
        _ -> S1
    end,
    S3 = case buoy_heap:get(V, <<"stack">>) of
        Stack when ?IS_STRING(Stack) -> write_string(append(S2, <<"s">>), Stack);
        _ -> S2
    end,
    S4 = case buoy_heap:get_own(V, <<"cause">>) of
        {data, Cause, _} -> write_value(This, append(S3, <<"c">>), Cause);
        _ -> S3
    end,
    append(S4, <<".">>).

%% Node's ThrowDataCloneError: the error that this._getDataCloneError(message)
%% returns.
-spec data_clone_error(term(), term()) -> no_return().
data_clone_error(This, What) ->
    Message = buoy_ref_string:concat([What, <<" could not be cloned.">>]),
    Maker = buoy_heap:get(This, <<"_getDataCloneError">>),
    case buoy_heap:is_callable(Maker) of
        true -> erlang:error({'$throw', buoy_heap:call(Maker, This, [Message])});
        false -> buoy_heap:throw_error('Error', buoy_ref_string:to_utf8(Message))
    end.

%%% Deserializer

read_header(This, _) ->
    read(This, fun
        (#{bin := Bin, pos := Pos} = S) when byte_size(Bin) > Pos, binary_part(Bin, Pos, 1) =:= <<16#FF>> ->
            {Version, S1} = read_varint(S#{pos := Pos + 1}, <<"Unable to deserialize cloned data due to invalid or unsupported version.">>, 32),
            Version > ?VERSION andalso
                buoy_heap:throw_error('Error', <<"Unable to deserialize cloned data due to invalid or unsupported version.">>),
            {true, S1#{version := Version}};
        (S) ->
            {true, S}
    end).

transfer_in(This, A) ->
    Id = uint32(buoy_node:arg(1, A)),
    Buffer = buoy_node:arg(2, A),
    buoy_heap:is_object(Buffer) andalso lists:member(buoy_heap:class_of(Buffer), [array_buffer, shared_array_buffer]) orelse
        buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>, <<"arrayBuffer must be an ArrayBuffer or SharedArrayBuffer">>),
    write(This, fun(#{transfers := T} = S) -> S#{transfers := T#{Id => Buffer}} end).

take(#{bin := Bin, pos := Pos}, Count, Failure) ->
    case byte_size(Bin) - Pos >= Count of
        true -> binary_part(Bin, Pos, Count);
        false -> failed(Failure)
    end.

-spec failed(binary()) -> no_return().
failed(Message) -> buoy_heap:throw_error('Error', Message).

-spec invalid_data() -> no_return().
invalid_data() -> buoy_heap:throw_error('Error', <<"Unable to deserialize cloned data.">>).

read_varint(S, Failure, Bits) -> read_varint(S, Failure, Bits, 0, 0).

read_varint(#{bin := Bin, pos := Pos} = S, Failure, Bits, Shift, Acc) ->
    case Bin of
        <<_:Pos/binary, Byte, _/binary>> ->
            Value = Acc bor ((Byte band 127) bsl Shift),
            case Byte band 128 of
                0 -> {Value band ((1 bsl Bits) - 1), S#{pos := Pos + 1}};
                _ -> read_varint(S#{pos := Pos + 1}, Failure, Bits, Shift + 7, Value)
            end;
        _ ->
            failed(Failure)
    end.

read_double(#{pos := Pos} = S, Failure) ->
    Bytes = take(S, 8, Failure),
    {from_double(Bytes), S#{pos := Pos + 8}}.

from_double(Bytes) ->
    <<Bits:64/little>> = Bytes,
    Exp = (Bits bsr 52) band 16#7FF,
    Frac = Bits band ((1 bsl 52) - 1),
    Sign = Bits bsr 63,
    case {Exp, Frac, Sign} of
        {16#7FF, 0, 0} -> 'Infinity';
        {16#7FF, 0, 1} -> '-Infinity';
        {16#7FF, _, _} -> 'NaN';
        _ -> <<F:64/float-little>> = Bytes, buoy_ref_number:canonical(F)
    end.

read_tag(#{bin := Bin, pos := Pos} = S) ->
    case Bin of
        <<_:Pos/binary, 0, _/binary>> -> read_tag(S#{pos := Pos + 1});
        <<_:Pos/binary, Tag, _/binary>> -> {Tag, S#{pos := Pos + 1}};
        _ -> invalid_data()
    end.

peek_tag(#{bin := Bin, pos := Pos} = S) ->
    case Bin of
        <<_:Pos/binary, 0, _/binary>> -> peek_tag(S#{pos := Pos + 1});
        <<_:Pos/binary, Tag, _/binary>> -> {Tag, S};
        _ -> invalid_data()
    end.

read_count(S) -> read_varint(S, <<"Unable to deserialize cloned data.">>, 64).

read_value(This, S) ->
    {Value, S1} = read_object(This, S),
    %% An ArrayBuffer followed by a view tag is the buffer of that view.
    case is_buffer(Value) andalso next_is(S1, $V) of
        true -> read_view(This, element(2, read_tag(S1)), Value);
        false -> {Value, S1}
    end.

is_buffer(V) -> buoy_heap:is_object(V) andalso lists:member(buoy_heap:class_of(V), [array_buffer, shared_array_buffer]).

next_is(#{bin := Bin, pos := Pos}, Tag) ->
    case Bin of
        <<_:Pos/binary, Tag, _/binary>> -> true;
        _ -> false
    end.

read_object(This, S0) ->
    {Tag, S} = read_tag(S0),
    case Tag of
        $? -> {_, S1} = read_count(S), read_object(This, S1);
        $_ -> {undefined, S};
        $0 -> {null, S};
        $T -> {true, S};
        $F -> {false, S};
        $I -> {Z, S1} = read_varint(S, <<"Unable to deserialize cloned data.">>, 32), {unzigzag(Z), S1};
        $U -> read_varint(S, <<"Unable to deserialize cloned data.">>, 32);
        $N -> read_double(S, <<"Unable to deserialize cloned data.">>);
        $Z -> read_bigint(S);
        $S -> read_bytes(S, fun(B) -> buoy_ref_string:from_utf8(B) end);
        $" -> read_bytes(S, fun(B) -> B end);
        $c -> read_bytes(S, fun two_byte/1);
        $^ ->
            {Id, S1} = read_count(S),
            case maps:get(ids, S1) of
                #{Id := V} -> {V, S1};
                _ -> invalid_data()
            end;
        $o -> read_js_object(This, S);
        $A -> read_dense_array(This, S);
        $a -> read_sparse_array(This, S);
        $D -> {Ms, S1} = read_double(S, <<"Unable to deserialize cloned data.">>), add(S1, buoy_heap:new_exotic(date, {'$o', 'Date.prototype'}, Ms));
        $y -> add(S, buoy_ref_boolean:wrap(true, {'$o', 'Boolean.prototype'}));
        $x -> add(S, buoy_ref_boolean:wrap(false, {'$o', 'Boolean.prototype'}));
        $n -> {N, S1} = read_double(S, <<"Unable to deserialize cloned data.">>), add(S1, buoy_ref_number:wrap(N, {'$o', 'Number.prototype'}));
        $z -> {B, S1} = read_bigint(S), add(S1, buoy_ref_bigint:wrap(B, {'$o', 'BigInt.prototype'}));
        $s ->
            {Str, S1} = read_string(This, S),
            add(S1, buoy_ref_string:wrap(Str, {'$o', 'String.prototype'}));
        $R -> read_regexp(This, S);
        $; -> read_map(This, S);
        $' -> read_set(This, S);
        $B -> read_array_buffer(S, none);
        $~ -> read_array_buffer(S, resizable);
        $t ->
            {Id, S1} = read_count(S),
            case maps:get(transfers, S1) of
                #{Id := Buffer} -> add(S1, Buffer);
                _ -> invalid_data()
            end;
        $r -> read_error(This, S);
        $\\ -> read_host_object(This, S);
        _ -> invalid_data()
    end.

unzigzag(Z) when Z band 1 =:= 0 -> Z bsr 1;
unzigzag(Z) -> -((Z + 1) bsr 1).

read_bigint(S) ->
    {Field, S1} = read_count(S),
    Length = Field bsr 1,
    Bytes = take(S1, Length, <<"Unable to deserialize cloned data.">>),
    Magnitude = binary:decode_unsigned(Bytes, little),
    Value = case Field band 1 of 1 -> -Magnitude; 0 -> Magnitude end,
    {{'$bigint', Value}, S1#{pos := maps:get(pos, S1) + Length}}.

read_bytes(S, Convert) ->
    {Length, #{pos := Pos} = S1} = read_count(S),
    Bytes = take(S1, Length, <<"Unable to deserialize cloned data.">>),
    {Convert(Bytes), S1#{pos := Pos + Length}}.

two_byte(Bytes) when byte_size(Bytes) rem 2 =:= 0 ->
    buoy_ref_string:from_units([U || <<U:16/little>> <= Bytes]);
two_byte(_) ->
    invalid_data().

read_string(This, S) ->
    case read_object(This, S) of
        {V, S1} when ?IS_STRING(V) -> {V, S1};
        _ -> invalid_data()
    end.

%% An object takes the next id before its contents are read, so a back
%% reference inside it finds it.
add(#{ids := Ids, next := Next} = S, V) ->
    {V, S#{ids := Ids#{Next => V}, next := Next + 1}}.

read_js_object(This, S) ->
    {O, S1} = add(S, buoy_heap:new_object(?OBJECT_PROTO)),
    {Count, S2} = read_properties(This, S1, O, ${),
    {Expected, S3} = read_count(S2),
    Count =:= Expected orelse invalid_data(),
    {O, S3}.

read_properties(This, S, O, End) -> read_properties(This, S, O, End, 0).

read_properties(This, S, O, End, Count) ->
    case peek_tag(S) of
        {End, S1} ->
            {_, S2} = read_tag(S1),
            {Count, S2};
        _ ->
            {Key, S1} = read_object(This, S),
            ?IS_STRING(Key) orelse ?IS_NUMBER(Key) orelse invalid_data(),
            {Value, S2} = read_value(This, S1),
            buoy_heap:define(O, buoy_heap:to_key(Key), #{value => Value, writable => true, enumerable => true, configurable => true}),
            read_properties(This, S2, O, End, Count + 1)
    end.

read_dense_array(This, S) ->
    {Length, S1} = read_count(S),
    {A, S2} = add(S1, buoy_heap:new_array([])),
    buoy_heap:set(A, <<"length">>, Length),
    S3 = lists:foldl(fun(I, Acc) ->
        case peek_tag(Acc) of
            {$-, Acc1} -> element(2, read_tag(Acc1));
            _ ->
                {Value, Acc1} = read_value(This, Acc),
                buoy_heap:define(A, I, #{value => Value, writable => true, enumerable => true, configurable => true}),
                Acc1
        end
    end, S2, lists:seq(0, Length - 1)),
    {Count, S4} = read_properties(This, S3, A, $$),
    {Expected, S5} = read_count(S4),
    {ExpectedLength, S6} = read_count(S5),
    Count =:= Expected andalso ExpectedLength =:= Length orelse invalid_data(),
    {A, S6}.

read_sparse_array(This, S) ->
    {Length, S1} = read_count(S),
    {A, S2} = add(S1, buoy_heap:new_array([])),
    buoy_heap:set(A, <<"length">>, Length),
    {Count, S3} = read_properties(This, S2, A, $@),
    {Expected, S4} = read_count(S3),
    {ExpectedLength, S5} = read_count(S4),
    Count =:= Expected andalso ExpectedLength =:= Length orelse invalid_data(),
    {A, S5}.

read_regexp(This, S) ->
    {Source, S1} = read_string(This, S),
    {Bits, S2} = read_count(S1),
    Flags = << <<Char>> || {Char, Bit} <- [{$d, 128}, {$g, 1}, {$i, 2}, {$m, 4}, {$s, 32}, {$u, 16}, {$v, 256}, {$y, 8}],
                           Bits band Bit =/= 0 >>,
    RegExp = buoy_ref_realm:global(<<"RegExp">>),
    add(S2, buoy_heap:construct(RegExp, [Source, Flags], RegExp)).

read_map(This, S) ->
    {M, S1} = add(S, buoy_heap:new_exotic(map, {'$o', 'Map.prototype'}, {#{}, 0})),
    {Entries, S2} = read_until(This, S1, $:, []),
    {Expected, S3} = read_count(S2),
    Expected =:= length(Entries) orelse invalid_data(),
    Pairs = pairs(Entries),
    Index = lists:foldl(fun({Seq, {K, V}}, Acc) ->
        case Acc of
            #{K := {Old, _}} -> Acc#{K := {Old, V}};
            _ -> Acc#{K => {Seq, V}}
        end
    end, #{}, lists:enumerate(0, [{map_key(K), V} || {K, V} <- Pairs])),
    buoy_heap:set_slots(M, {Index, length(Pairs)}),
    {M, S3}.

read_set(This, S) ->
    {Set, S1} = add(S, buoy_heap:new_exotic(set, {'$o', 'Set.prototype'}, {#{}, 0})),
    {Members, S2} = read_until(This, S1, $,, []),
    {Expected, S3} = read_count(S2),
    Expected =:= length(Members) orelse invalid_data(),
    Index = lists:foldl(fun({Seq, K}, Acc) ->
        case Acc of
            #{K := _} -> Acc;
            _ -> Acc#{K => Seq}
        end
    end, #{}, lists:enumerate(0, [map_key(K) || K <- Members])),
    buoy_heap:set_slots(Set, {Index, length(Members)}),
    {Set, S3}.

map_key(K) when K =:= -0.0 -> 0;
map_key(K) -> K.

pairs([K, V | Rest]) -> [{K, V} | pairs(Rest)];
pairs([]) -> [].

read_until(This, S, End, Acc) ->
    case peek_tag(S) of
        {End, S1} -> {lists:reverse(Acc), element(2, read_tag(S1))};
        _ ->
            {Value, S1} = read_value(This, S),
            read_until(This, S1, End, [Value | Acc])
    end.

read_array_buffer(S, Kind) ->
    {Length, S1} = read_count(S),
    {Max, S2} = case Kind of
        resizable -> read_count(S1);
        none -> {none, S1}
    end,
    Bytes = take(S2, Length, <<"Unable to deserialize cloned data.">>),
    is_integer(Max) andalso Max < Length andalso invalid_data(),
    Buffer = buoy_ref_buffer:allocate(Length, Max),
    buoy_ref_buffer:write(Buffer, 0, Bytes),
    add(S2#{pos := maps:get(pos, S2) + Length}, Buffer).

read_view(_This, S, Buffer) ->
    {SubTag, S1} = read_tag(S),
    {Offset, S2} = read_count(S1),
    {ByteLength, S3} = read_count(S2),
    {Flags, S4} = case maps:get(version, S3) >= 14 of
        true -> read_count(S3);
        false -> {0, S3}
    end,
    Offset + ByteLength =< buoy_ref_buffer:byte_length(Buffer) orelse invalid_data(),
    Tracking = Flags band 1 =:= 1,
    View = case SubTag of
        $? ->
            buoy_heap:new_exotic(data_view, {'$o', 'DataView.prototype'},
                                 {Buffer, Offset, case Tracking of true -> auto; false -> ByteLength end});
        _ ->
            Kind = kind(SubTag),
            Size = buoy_ref_buffer:element_size(Kind),
            Offset rem Size =:= 0 andalso ByteLength rem Size =:= 0 orelse invalid_data(),
            Proto = {'$o', binary_to_atom(<<(buoy_ref_buffer:kind_name(Kind))/binary, ".prototype">>)},
            buoy_heap:new_exotic(typed_array, Proto,
                                 {Kind, Buffer, Offset, case Tracking of true -> auto; false -> ByteLength div Size end})
    end,
    add(S4, View).

kind($b) -> int8;
kind($B) -> uint8;
kind($C) -> uint8c;
kind($w) -> int16;
kind($W) -> uint16;
kind($d) -> int32;
kind($D) -> uint32;
kind($h) -> float16;
kind($f) -> float32;
kind($F) -> float64;
kind($q) -> bigint64;
kind($Q) -> biguint64;
kind(_) -> invalid_data().

read_error(This, S) ->
    {E, S1} = add(S, buoy_heap:error_object('Error', <<>>, <<>>)),
    {Fields, S2} = read_error_fields(This, S1, #{}),
    Proto = {'$o', list_to_atom(atom_to_list(maps:get(prototype, Fields, 'Error')) ++ ".prototype")},
    buoy_heap:set_prototype_of(E, Proto),
    [buoy_heap:delete(E, K) || {K, F} <- [{<<"message">>, message}, {<<"stack">>, stack}], not is_map_key(F, Fields)],
    [buoy_heap:define(E, K, #{value => maps:get(F, Fields), writable => true, enumerable => false, configurable => true})
     || {K, F} <- [{<<"message">>, message}, {<<"stack">>, stack}, {<<"cause">>, cause}], is_map_key(F, Fields)],
    {E, S2}.

read_error_fields(This, S, Fields) ->
    {Tag, S1} = read_count(S),
    case Tag of
        $E -> read_error_fields(This, S1, Fields#{prototype => 'EvalError'});
        $R -> read_error_fields(This, S1, Fields#{prototype => 'RangeError'});
        $F -> read_error_fields(This, S1, Fields#{prototype => 'ReferenceError'});
        $S -> read_error_fields(This, S1, Fields#{prototype => 'SyntaxError'});
        $T -> read_error_fields(This, S1, Fields#{prototype => 'TypeError'});
        $U -> read_error_fields(This, S1, Fields#{prototype => 'URIError'});
        $m -> {M, S2} = read_string(This, S1), read_error_fields(This, S2, Fields#{message => M});
        $s -> {St, S2} = read_string(This, S1), read_error_fields(This, S2, Fields#{stack => St});
        $c -> {C, S2} = read_value(This, S1), read_error_fields(This, S2, Fields#{cause => C});
        $. -> {Fields, S1};
        _ -> invalid_data()
    end.

%% this._readHostObject() reads from this Deserializer, so the state goes back
%% to it for the call, and the host object takes the next id.
read_host_object(This, #{next := Next} = S) ->
    save(This, S#{next := Next + 1}),
    Reader = buoy_heap:get(This, <<"_readHostObject">>),
    buoy_heap:is_callable(Reader) orelse invalid_data(),
    Value = buoy_heap:call(Reader, This, []),
    buoy_heap:is_object(Value) orelse invalid_data(),
    #{ids := Ids} = S1 = state(This),
    {Value, S1#{ids := Ids#{Next => Value}}}.
