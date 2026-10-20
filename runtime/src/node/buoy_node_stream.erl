%% The StreamBase methods of Node's stream handles (src/stream_base.cc and
%% stream_wrap.cc) over an Erlang channel: a process that takes
%% {write, Bytes, Realm, Ref}, shutdown, and close, and sends the data that it
%% reads to the realm with deliver/2 inside a '$buoy_node_call' message. The
%% pipes of process_wrap use it.
%%
%% A write is asynchronous (kLastWriteWasAsync is 1): once the channel has
%% written the bytes, it calls written/3 in the realm, which runs the
%% request's oncomplete, so a stream waits for 'drain' as in Node. shutdown
%% returns 1, a synchronous finish, after which the channel closes its
%% writable side.
-module(buoy_node_stream).

-export([methods/1, attach/2, attach/3, set_fd/2, deliver/2, call/2, written/3, forward/2, pass/2]).

-define(STATE, {'#', ?MODULE, <<"state">>}).
-define(K_READ_BYTES, 0).
-define(K_OFFSET, 1).
-define(K_BYTES_WRITTEN, 2).
-define(K_ASYNC, 3).
-define(UV_EOF, -4095).

%% Defines the methods of a stream handle on the prototype of its class.
-spec methods(term()) -> ok.
methods(Proto) ->
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    Writes = [{<<"writeBuffer">>, fun(This, Args) -> write(This, A(1, Args), buoy_node_encoding:write_buffer_bytes(A(2, Args)), A(3, Args)) end},
              {<<"writeUtf8String">>, fun(This, Args) -> write(This, A(1, Args), buoy_node_encoding:encode(utf8, A(2, Args)), A(3, Args)) end},
              {<<"writeAsciiString">>, fun(This, Args) -> write(This, A(1, Args), buoy_node_encoding:encode(latin1, A(2, Args))) end},
              {<<"writeLatin1String">>, fun(This, Args) -> write(This, A(1, Args), buoy_node_encoding:encode(latin1, A(2, Args))) end},
              {<<"writeUcs2String">>, fun(This, Args) -> write(This, A(1, Args), buoy_node_encoding:encode(ucs2, A(2, Args))) end},
              {<<"writev">>, fun(This, Args) -> write(This, A(1, Args), writev_bytes(A(2, Args), buoy_ref:truthy(A(3, Args)))) end}],
    Methods = Writes ++ [
        {<<"readStart">>, fun(This, _) -> read_start(This) end},
        {<<"readStop">>, fun(This, _) -> read_stop(This) end},
        {<<"shutdown">>, fun(This, _) -> send(This, shutdown), 1 end},
        {<<"close">>, fun(This, Args) -> close(This, A(1, Args)) end},
        {<<"ref">>, fun(This, _) -> set_ref(This, true) end},
        {<<"unref">>, fun(This, _) -> set_ref(This, false) end},
        {<<"hasRef">>, fun(This, _) -> #{refed := R, closed := C} = state(This), R andalso not C end},
        {<<"getAsyncId">>, fun(This, _) -> maps:get(async_id, state(This), -1) end},
        {<<"useUserBuffer">>, fun(_, _) -> undefined end},
        {<<"setBlocking">>, fun(_, _) -> 0 end}],
    [buoy_heap:define(Proto, Name, #{value => F(Name, 0, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    [buoy_heap:define(Proto, Name, #{get => F(<<"get ", Name/binary>>, 0, Get), enumerable => true, configurable => true})
     || {Name, Get} <- [{<<"bytesRead">>, fun(This, _) -> maps:get(read, state(This), 0) end},
                        {<<"bytesWritten">>, fun(This, _) -> maps:get(written, state(This), 0) end},
                        {<<"fd">>, fun(This, _) -> maps:get(fd, state(This), -1) end},
                        {<<"writeQueueSize">>, fun(_, _) -> 0 end}]],
    ok.

%% Binds a handle to its channel. Until then the handle reads nothing.
-spec attach(term(), pid() | none) -> ok.
attach(Handle, Channel) ->
    Id = erlang:unique_integer([positive]),
    update(Handle, fun(S) -> S#{channel => Channel, reading => false, pending => [], eof => false,
                                read => 0, written => 0, async_id => Id, closed => false} end).

%% The descriptor that the handle's fd reports, as uv_fileno.
-spec set_fd(term(), integer()) -> ok.
set_fd(Handle, Fd) ->
    update(Handle, fun(S) -> S#{fd => Fd} end).

%% Binds a handle whose writes Writer makes at once, such as the writes of a
%% terminal, which libuv makes blocking for tty.WriteStream: each returns the
%% status of the write, and no oncomplete follows.
-spec attach(term(), pid() | none, fun((binary()) -> integer())) -> ok.
attach(Handle, Channel, Writer) ->
    attach(Handle, Channel),
    update(Handle, fun(S) -> S#{writer => Writer} end).

state(Handle) ->
    case buoy_heap:is_object(Handle) andalso buoy_heap:private_find(Handle, ?STATE) of
        {ok, S} -> S;
        _ -> #{channel => none, reading => false, pending => [], eof => false, refed => true, counted => false, closed => false}
    end.

%% uv_loop_alive: a handle keeps the loop alive while it is ref'd and
%% active, and a stream is active while it reads, before its end.
update(Handle, Fun) ->
    #{refed := Refed, reading := Reading, eof := Eof, closed := Closed, counted := Counted} = S = Fun(state(Handle)),
    Alive = Refed andalso Reading andalso not Eof andalso not Closed,
    case {Counted, Alive} of
        {false, true} -> buoy_node_loop:ref_handle();
        {true, false} -> buoy_node_loop:unref_handle();
        _ -> ok
    end,
    buoy_heap:private_put(Handle, ?STATE, S#{counted := Alive}).

send(Handle, Message) ->
    case state(Handle) of
        #{channel := Channel} when is_pid(Channel) -> Channel ! Message, ok;
        _ -> ok
    end.

%% Runs Fun in the realm Realm, as a callback of the loop of Node.
-spec call(pid(), fun(() -> term())) -> ok.
call(Realm, Fun) ->
    Realm ! {'$buoy_node_call', Fun},
    ok.

stream_state() ->
    buoy_heap:get(buoy_node:binding(<<"stream_wrap">>), <<"streamBaseState">>).

%% The request stays a root of the heap, and keeps the loop alive as libuv's
%% active request does, until the channel reports the write.
write(Handle, Req, Bytes) -> write(Handle, Req, Bytes, undefined).

%% A write of an IPC channel may pass SendHandle, as StreamBase::WriteString
%% passes it to uv_write2; the request keeps it alive until the write ends.
write(Handle, Req, Bytes, SendHandle) ->
    State = stream_state(),
    buoy_heap:set(State, ?K_BYTES_WRITTEN, byte_size(Bytes)),
    case state(Handle) of
        #{writer := Writer} ->
            buoy_heap:set(State, ?K_ASYNC, 0),
            update(Handle, fun(S) -> S#{written => maps:get(written, S, 0) + byte_size(Bytes)} end),
            Writer(Bytes);
        _ ->
            write_async(Handle, Req, Bytes, SendHandle, State)
    end.

write_async(Handle, Req, Bytes, SendHandle, State) ->
    buoy_node_loop:ref_handle(),
    buoy_heap:set(State, ?K_ASYNC, 1),
    Ref = make_ref(),
    erlang:put({?MODULE, request, Ref}, {Handle, Req}),
    Fds = case buoy_heap:is_object(SendHandle) of
        true -> buoy_heap:set(Req, <<"handle">>, SendHandle), buoy_node_ipc:send_fds(SendHandle);
        false -> []
    end,
    case state(Handle) of
        #{channel := Channel} when is_pid(Channel), Fds =/= [] -> Channel ! {write, Bytes, self(), Ref, Fds};
        #{channel := Channel} when is_pid(Channel) -> Channel ! {write, Bytes, self(), Ref};
        _ -> call(self(), fun() -> written(Ref, -32, ok) end)
    end,
    update(Handle, fun(S) -> S#{written => maps:get(written, S, 0) + byte_size(Bytes)} end),
    0.

%% The channel wrote the bytes of the request Ref, or failed with Status: the
%% request's oncomplete(status, handle) runs, as WriteWrap::OnDone calls it.
-spec written(reference(), integer(), term()) -> term().
written(Ref, Status, _) ->
    case erlang:erase({?MODULE, request, Ref}) of
        {Handle, Req} ->
            buoy_node_loop:unref_handle(),
            Oncomplete = buoy_heap:get(Req, <<"oncomplete">>),
            buoy_heap:is_callable(Oncomplete) andalso buoy_heap:call(Oncomplete, Req, [Status, Handle]);
        undefined ->
            ok
    end.

writev_bytes(Chunks, true) ->
    iolist_to_binary([buoy_node_encoding:view_bytes(C) || C <- buoy_heap:array_items(Chunks)]);
writev_bytes(Chunks, false) ->
    iolist_to_binary(pairs(buoy_heap:array_items(Chunks))).

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

%% A closed handle cannot read: uv_read_start fails with UV_EINVAL.
read_start(Handle) ->
    read_start(Handle, maps:get(closed, state(Handle), false)).

read_start(_Handle, true) ->
    -22;
read_start(Handle, false) ->
    update(Handle, fun(S) -> S#{reading := true} end),
    case state(Handle) of
        #{pending := [_ | _] = Pending} ->
            update(Handle, fun(S) -> S#{pending := []} end),
            Realm = self(),
            [call(Realm, fun() -> deliver(Handle, Item) end) || Item <- lists:reverse(Pending)];
        _ ->
            ok
    end,
    0.

%% A handle that stops reading is inactive, as after uv_read_stop, so it no
%% longer keeps the loop alive; it keeps its ref for the next readStart.
read_stop(Handle) ->
    update(Handle, fun(S) -> S#{reading := false} end),
    0.

set_ref(Handle, Refed) ->
    update(Handle, fun(S) -> S#{refed := Refed} end),
    undefined.

%% A child whose stdio entry is this handle (a 'wrap' of getValidStdio)
%% shares its descriptor: while Target, the manager of that child, is set,
%% what the handle reads goes to the child's stdin, as the reads of the
%% child take it from the shared pipe.
%% A socket of buoy_node_socket, such as a net.Socket, reads for the child
%% through a listener instead.
-spec forward(term(), pid() | none) -> ok.
forward(Handle, Target) ->
    case buoy_node_socket:find(Handle) of
        {ok, _} -> forward_socket(Handle, Target);
        error -> forward_channel(Handle, Target)
    end.

forward_socket(Handle, none) ->
    buoy_node_socket:set_listener(Handle, none),
    _ = buoy_node_socket:read_stop(Handle),
    ok;
forward_socket(Handle, Target) ->
    buoy_node_socket:set_listener(Handle, fun({data, Bytes}) -> pass_to(Target, Bytes);
                                             (eof) -> pass_to(Target, eof);
                                             (_) -> ok
                                          end),
    _ = buoy_node_socket:read_start(Handle),
    ok.

forward_channel(Handle, Target) ->
    #{pending := Pending} = state(Handle),
    update(Handle, fun(S) -> S#{forward => Target, pending := case Target of none -> Pending; _ -> [] end} end),
    is_pid(Target) andalso lists:foreach(fun(Item) -> pass_to(Target, Item) end, lists:reverse(Pending)),
    ok.

pass_to(Target, eof) -> Target ! shutdown;
pass_to(Target, {Bytes, _Pending}) -> pass_to(Target, Bytes);
pass_to(Target, Bytes) -> Target ! {write, Bytes, self(), make_ref()}.

%% A child's output whose stdio entry is this handle: the bytes go out
%% through the handle's channel, as the child writes to the shared pipe.
-spec pass(term(), binary()) -> ok.
pass(Handle, Bytes) ->
    case buoy_node_socket:find(Handle) of
        {ok, _} -> _ = buoy_node_socket:write_raw(Handle, Bytes), ok;
        error -> send(Handle, {write, Bytes, self(), make_ref()})
    end.

%% Data that the channel read, or eof: the handle's onread gets it while it
%% reads, and keeps it for readStart otherwise. Data that an IPC channel
%% read with a handle, {Bytes, Pending}, sets the handle's pendingHandle
%% first, as LibuvStreamWrap::OnUvRead does.
-spec deliver(term(), binary() | {binary(), term()} | eof) -> term().
deliver(Handle, Item) ->
    case state(Handle) of
        #{closed := true} ->
            ok;
        #{forward := Target} when is_pid(Target) ->
            pass_to(Target, Item);
        #{reading := false} = S ->
            update(Handle, fun(_) -> S#{pending := [Item | maps:get(pending, S)]} end);
        S ->
            State = stream_state(),
            Onread = buoy_heap:get(Handle, <<"onread">>),
            case Item of
                eof ->
                    update(Handle, fun(_) -> S#{eof := true} end),
                    buoy_heap:set(State, ?K_READ_BYTES, ?UV_EOF),
                    buoy_heap:is_callable(Onread) andalso buoy_heap:call(Onread, Handle, [undefined]);
                {Bytes, Pending} ->
                    buoy_heap:set(Handle, <<"pendingHandle">>, Pending),
                    deliver(Handle, Bytes);
                Bytes ->
                    update(Handle, fun(_) -> S#{read => maps:get(read, S, 0) + byte_size(Bytes)} end),
                    Buffer = buoy_ref_buffer:allocate(byte_size(Bytes)),
                    buoy_ref_buffer:write(Buffer, 0, Bytes),
                    buoy_heap:set(State, ?K_READ_BYTES, byte_size(Bytes)),
                    buoy_heap:set(State, ?K_OFFSET, 0),
                    buoy_heap:is_callable(Onread) andalso buoy_heap:call(Onread, Handle, [Buffer])
            end
    end.

close(Handle, Callback) ->
    update(Handle, fun(S) -> S#{closed => true, reading := false} end),
    send(Handle, close),
    buoy_heap:is_callable(Callback) andalso
        buoy_node_loop:defer(fun() -> buoy_heap:call(Callback, Handle, []) end),
    undefined.
