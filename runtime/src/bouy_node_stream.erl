%% The StreamBase methods of Node's stream handles (src/stream_base.cc and
%% stream_wrap.cc) over an Erlang channel: a process that takes
%% {write, Bytes, Realm, Ref}, shutdown, and close, and sends the data that it
%% reads to the realm with deliver/2 inside a '$bouy_node_call' message. The
%% pipes of process_wrap use it.
%%
%% A write is asynchronous (kLastWriteWasAsync is 1): once the channel has
%% written the bytes, it calls written/3 in the realm, which runs the
%% request's oncomplete, so a stream waits for 'drain' as in Node. shutdown
%% returns 1, a synchronous finish, after which the channel closes its
%% writable side.
-module(bouy_node_stream).

-export([methods/1, attach/2, deliver/2, call/2, written/3]).

-define(STATE, {'#', ?MODULE, <<"state">>}).
-define(K_READ_BYTES, 0).
-define(K_OFFSET, 1).
-define(K_BYTES_WRITTEN, 2).
-define(K_ASYNC, 3).
-define(UV_EOF, -4095).

%% Defines the methods of a stream handle on the prototype of its class.
-spec methods(term()) -> ok.
methods(Proto) ->
    F = fun bouy_node:fn/3,
    A = fun bouy_node:arg/2,
    Writes = [{<<"writeBuffer">>, fun(This, Args) -> write(This, A(1, Args), bouy_node_encoding:view_bytes(A(2, Args))) end},
              {<<"writeUtf8String">>, fun(This, Args) -> write(This, A(1, Args), bouy_node_encoding:encode(utf8, A(2, Args))) end},
              {<<"writeAsciiString">>, fun(This, Args) -> write(This, A(1, Args), bouy_node_encoding:encode(latin1, A(2, Args))) end},
              {<<"writeLatin1String">>, fun(This, Args) -> write(This, A(1, Args), bouy_node_encoding:encode(latin1, A(2, Args))) end},
              {<<"writeUcs2String">>, fun(This, Args) -> write(This, A(1, Args), bouy_node_encoding:encode(ucs2, A(2, Args))) end},
              {<<"writev">>, fun(This, Args) -> write(This, A(1, Args), writev_bytes(A(2, Args), bouy_ref:truthy(A(3, Args)))) end}],
    Methods = Writes ++ [
        {<<"readStart">>, fun(This, _) -> read_start(This) end},
        {<<"readStop">>, fun(This, _) -> update(This, fun(S) -> S#{reading := false} end), 0 end},
        {<<"shutdown">>, fun(This, _) -> send(This, shutdown), 1 end},
        {<<"close">>, fun(This, Args) -> close(This, A(1, Args)) end},
        {<<"ref">>, fun(This, _) -> set_ref(This, true) end},
        {<<"unref">>, fun(This, _) -> set_ref(This, false) end},
        {<<"hasRef">>, fun(This, _) -> maps:get(refed, state(This), false) end},
        {<<"getAsyncId">>, fun(This, _) -> maps:get(async_id, state(This), -1) end},
        {<<"useUserBuffer">>, fun(_, _) -> undefined end},
        {<<"setBlocking">>, fun(_, _) -> 0 end}],
    [bouy_heap:define(Proto, Name, #{value => F(Name, 0, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    [bouy_heap:define(Proto, Name, #{get => F(<<"get ", Name/binary>>, 0, Get), enumerable => true, configurable => true})
     || {Name, Get} <- [{<<"bytesRead">>, fun(This, _) -> maps:get(read, state(This), 0) end},
                        {<<"bytesWritten">>, fun(This, _) -> maps:get(written, state(This), 0) end},
                        {<<"fd">>, fun(_, _) -> -1 end},
                        {<<"writeQueueSize">>, fun(_, _) -> 0 end}]],
    ok.

%% Binds a handle to its channel. Until then the handle reads nothing.
-spec attach(term(), pid()) -> ok.
attach(Handle, Channel) ->
    Id = erlang:unique_integer([positive]),
    bouy_heap:private_put(Handle, ?STATE, #{channel => Channel, reading => false, pending => [], eof => false,
                                            refed => false, read => 0, written => 0, async_id => Id, closed => false}).

state(Handle) ->
    case bouy_heap:is_object(Handle) andalso bouy_heap:private_find(Handle, ?STATE) of
        {ok, S} -> S;
        _ -> #{channel => none, reading => false, pending => [], eof => false, refed => false, closed => false}
    end.

update(Handle, Fun) ->
    bouy_heap:private_put(Handle, ?STATE, Fun(state(Handle))).

send(Handle, Message) ->
    case state(Handle) of
        #{channel := Channel} when is_pid(Channel) -> Channel ! Message, ok;
        _ -> ok
    end.

%% Runs Fun in the realm Realm, as a callback of the loop of Node.
-spec call(pid(), fun(() -> term())) -> ok.
call(Realm, Fun) ->
    Realm ! {'$bouy_node_call', Fun},
    ok.

stream_state() ->
    bouy_heap:get(bouy_node:binding(<<"stream_wrap">>), <<"streamBaseState">>).

%% The request stays a root of the heap until the channel reports the write.
write(Handle, Req, Bytes) ->
    State = stream_state(),
    bouy_heap:set(State, ?K_BYTES_WRITTEN, byte_size(Bytes)),
    bouy_heap:set(State, ?K_ASYNC, 1),
    Ref = make_ref(),
    erlang:put({?MODULE, request, Ref}, {Handle, Req}),
    case state(Handle) of
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
            Oncomplete = bouy_heap:get(Req, <<"oncomplete">>),
            bouy_heap:is_callable(Oncomplete) andalso bouy_heap:call(Oncomplete, Req, [Status, Handle]);
        undefined ->
            ok
    end.

writev_bytes(Chunks, true) ->
    iolist_to_binary([bouy_node_encoding:view_bytes(C) || C <- bouy_heap:array_items(Chunks)]);
writev_bytes(Chunks, false) ->
    iolist_to_binary(pairs(bouy_heap:array_items(Chunks))).

pairs([Chunk, Encoding | Rest]) ->
    Bytes = case bouy_heap:is_object(Chunk) of
        true -> bouy_node_encoding:view_bytes(Chunk);
        false ->
            Enc = case bouy_node_encoding:parse(Encoding) of
                {ok, E} -> E;
                error -> utf8
            end,
            bouy_node_encoding:encode(Enc, Chunk)
    end,
    [Bytes | pairs(Rest)];
pairs(_) -> [].

read_start(Handle) ->
    update(Handle, fun(S) -> S#{reading := true} end),
    set_ref(Handle, true),
    case state(Handle) of
        #{pending := [_ | _] = Pending} ->
            update(Handle, fun(S) -> S#{pending := []} end),
            Realm = self(),
            [call(Realm, fun() -> deliver(Handle, Item) end) || Item <- lists:reverse(Pending)];
        _ ->
            ok
    end,
    0.

set_ref(Handle, Refed) ->
    #{refed := Old} = S = state(Handle),
    case {Old, Refed, maps:get(closed, S, false)} of
        {false, true, false} -> bouy_node_loop:ref_handle();
        {true, false, _} -> bouy_node_loop:unref_handle();
        _ -> ok
    end,
    update(Handle, fun(St) -> St#{refed := Refed andalso not maps:get(closed, St, false)} end),
    undefined.

%% Data that the channel read, or eof: the handle's onread gets it while it
%% reads, and keeps it for readStart otherwise.
-spec deliver(term(), binary() | eof) -> term().
deliver(Handle, Item) ->
    case state(Handle) of
        #{closed := true} ->
            ok;
        #{reading := false} = S ->
            update(Handle, fun(_) -> S#{pending := [Item | maps:get(pending, S)]} end);
        S ->
            State = stream_state(),
            Onread = bouy_heap:get(Handle, <<"onread">>),
            case Item of
                eof ->
                    update(Handle, fun(_) -> S#{eof := true} end),
                    set_ref(Handle, false),
                    bouy_heap:set(State, ?K_READ_BYTES, ?UV_EOF),
                    bouy_heap:is_callable(Onread) andalso bouy_heap:call(Onread, Handle, [undefined]);
                Bytes ->
                    update(Handle, fun(_) -> S#{read => maps:get(read, S, 0) + byte_size(Bytes)} end),
                    Buffer = bouy_ref_buffer:allocate(byte_size(Bytes)),
                    bouy_ref_buffer:write(Buffer, 0, Bytes),
                    bouy_heap:set(State, ?K_READ_BYTES, byte_size(Bytes)),
                    bouy_heap:set(State, ?K_OFFSET, 0),
                    bouy_heap:is_callable(Onread) andalso bouy_heap:call(Onread, Handle, [Buffer])
            end
    end.

close(Handle, Callback) ->
    set_ref(Handle, false),
    update(Handle, fun(S) -> S#{closed => true, reading := false} end),
    send(Handle, close),
    bouy_heap:is_callable(Callback) andalso
        bouy_node_loop:defer(fun() -> bouy_heap:call(Callback, Handle, []) end),
    undefined.
