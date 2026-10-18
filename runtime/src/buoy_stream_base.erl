%% The JavaScript side of a StreamBase of src/stream_base.cc for a handle
%% whose reads and writes Erlang code produces: the write and read methods,
%% the streamBaseState protocol of lib/internal/stream_base_commons.js, and
%% the oncomplete of a request. The js_stream and http2 bindings use it.
%%
%% Impl holds the operations of the stream, as the virtual methods of
%% StreamBase: write(This, Req, [Bytes]) returns 0 for a write that
%% completes later through done/3, a negative errno, or {sync, Status};
%% shutdown(This, Req), read_start(This), and read_stop(This) return an
%% integer.
-module(buoy_stream_base).

-export([methods/2, emit_read/2, done/3, push_listener/2]).

-define(BYTES, {'#', ?MODULE, <<"bytes">>}).
-define(K_READ_BYTES, 0).
-define(K_OFFSET, 1).
-define(K_BYTES_WRITTEN, 2).
-define(K_ASYNC, 3).
-define(UV_EOF, -4095).

-spec methods(term(), map()) -> ok.
methods(Proto, Impl) ->
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    Write = fun(This, Req, Chunks) -> write(Impl, This, Req, Chunks) end,
    Methods = [
        {<<"writeBuffer">>, fun(This, Args) -> Write(This, A(1, Args), [buoy_node_encoding:view_bytes(A(2, Args))]) end},
        {<<"writev">>, fun(This, Args) -> Write(This, A(1, Args), chunks(A(2, Args), buoy_ref:truthy(A(3, Args)))) end},
        {<<"writeUtf8String">>, fun(This, Args) -> Write(This, A(1, Args), [buoy_node_encoding:encode(utf8, A(2, Args))]) end},
        {<<"writeAsciiString">>, fun(This, Args) -> Write(This, A(1, Args), [buoy_node_encoding:encode(latin1, A(2, Args))]) end},
        {<<"writeLatin1String">>, fun(This, Args) -> Write(This, A(1, Args), [buoy_node_encoding:encode(latin1, A(2, Args))]) end},
        {<<"writeUcs2String">>, fun(This, Args) -> Write(This, A(1, Args), [buoy_node_encoding:encode(ucs2, A(2, Args))]) end},
        {<<"readStart">>, fun(This, _) -> (maps:get(read_start, Impl))(This) end},
        {<<"readStop">>, fun(This, _) -> (maps:get(read_stop, Impl))(This) end},
        {<<"shutdown">>, fun(This, Args) -> (maps:get(shutdown, Impl))(This, A(1, Args)) end},
        {<<"useUserBuffer">>, fun(_, _) -> undefined end}],
    [buoy_heap:define(Proto, Name, #{value => F(Name, 0, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    Getters = [{<<"bytesRead">>, fun(This, _) -> element(1, counts(This)) end},
               {<<"bytesWritten">>, fun(This, _) -> element(2, counts(This)) end},
               {<<"fd">>, fun(_, _) -> -1 end},
               {<<"_externalStream">>, fun(_, _) -> undefined end}],
    [buoy_heap:define(Proto, Name, #{get => F(<<"get ", Name/binary>>, 0, Get), enumerable => false, configurable => false})
     || {Name, Get} <- Getters],
    buoy_heap:define(Proto, <<"isStreamBase">>, #{value => true, writable => true, enumerable => true, configurable => true}),
    ok.

chunks(Chunks, true) ->
    [buoy_node_encoding:view_bytes(C) || C <- buoy_heap:array_items(Chunks)];
chunks(Chunks, false) ->
    pairs(buoy_heap:array_items(Chunks)).

pairs([Chunk, Encoding | Rest]) ->
    Bytes = case buoy_heap:is_object(Chunk) of
        true -> buoy_node_encoding:view_bytes(Chunk);
        false ->
            Enc = case buoy_node_encoding:parse(Encoding) of
                {ok, E} -> E;
                error -> utf8
            end,
            buoy_node_encoding:encode(Enc, Chunk)
    end,
    [Bytes | pairs(Rest)];
pairs(_) -> [].

%% StreamBase::Write: kBytesWritten, then kLastWriteWasAsync as the stream
%% answers.
write(Impl, This, Req, Chunks) ->
    State = state(),
    Size = iolist_size(Chunks),
    buoy_heap:set(State, ?K_BYTES_WRITTEN, Size),
    {Read, Written} = counts(This),
    buoy_heap:private_put(This, ?BYTES, {Read, Written + Size}),
    case (maps:get(write, Impl))(This, Req, Chunks) of
        {sync, Status} ->
            buoy_heap:set(State, ?K_ASYNC, 0),
            Status;
        0 ->
            buoy_heap:set(State, ?K_ASYNC, 1),
            0;
        Err ->
            buoy_heap:set(State, ?K_ASYNC, 0),
            Err
    end.

counts(This) ->
    case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, ?BYTES) of
        {ok, Counts} -> Counts;
        _ -> {0, 0}
    end.

state() ->
    buoy_heap:get(buoy_node:binding(<<"stream_wrap">>), <<"streamBaseState">>).

%% CallJSOnreadMethod: the bytes, or eof, to the handle's onread.
-spec emit_read(term(), binary() | eof) -> term().
emit_read(Handle, eof) ->
    State = state(),
    buoy_heap:set(State, ?K_READ_BYTES, ?UV_EOF),
    buoy_heap:set(State, ?K_OFFSET, 0),
    onread(Handle, undefined);
emit_read(Handle, Bytes) ->
    {Read, Written} = counts(Handle),
    buoy_heap:private_put(Handle, ?BYTES, {Read + byte_size(Bytes), Written}),
    Buffer = buoy_ref_buffer:allocate(byte_size(Bytes)),
    buoy_ref_buffer:write(Buffer, 0, Bytes),
    State = state(),
    buoy_heap:set(State, ?K_READ_BYTES, byte_size(Bytes)),
    buoy_heap:set(State, ?K_OFFSET, 0),
    onread(Handle, Buffer).

onread(Handle, Arg) ->
    Onread = buoy_heap:get(Handle, <<"onread">>),
    case buoy_heap:is_callable(Onread) of
        true -> buoy_heap:call(Onread, Handle, [Arg]);
        false -> undefined
    end.

%% StreamBase::PushStreamListener for a binding that reads a handle, such
%% as a consumed socket: OnRead gets the bytes of each read, and a read
%% error or EOF goes to the onread of before (PassReadErrorToPreviousListener).
%% Returns that onread, for the binding to put back.
-spec push_listener(term(), fun((binary()) -> term())) -> term().
push_listener(Handle, OnRead) ->
    Prev = buoy_heap:get(Handle, <<"onread">>),
    buoy_heap:set(Handle, <<"onread">>, buoy_node:fn(<<"onread">>, 1, fun(_, Args) ->
        Buffer = buoy_node:arg(1, Args),
        State = state(),
        case trunc(buoy_heap:get(State, ?K_READ_BYTES)) of
            N when N < 0 ->
                case buoy_heap:is_callable(Prev) of
                    true -> buoy_heap:call(Prev, Handle, [Buffer]);
                    false -> undefined
                end;
            0 ->
                undefined;
            N ->
                Offset = trunc(buoy_heap:get(State, ?K_OFFSET)),
                <<_:Offset/binary, Bytes:N/binary, _/binary>> = buoy_ref_buffer:read(Buffer, 0, buoy_ref_buffer:byte_length(Buffer)),
                OnRead(Bytes)
        end
    end)),
    Prev.

%% StreamReq::Done: req.oncomplete(status, handle, undefined).
-spec done(term(), integer(), term()) -> term().
done(Req, Status, Handle) ->
    case buoy_heap:is_object(Req) of
        false ->
            undefined;
        true ->
            Oncomplete = buoy_heap:get(Req, <<"oncomplete">>),
            case buoy_heap:is_callable(Oncomplete) of
                true -> buoy_heap:call(Oncomplete, Req, [Status, Handle, undefined]);
                false -> undefined
            end
    end.
