%% Node's libuv stream handles over OTP sockets (the socket module): the
%% HandleWrap and StreamBase methods of src/handle_wrap.cc, stream_wrap.cc,
%% and stream_base.cc, and the connect, bind, listen, and accept that
%% tcp_wrap.cc and pipe_wrap.cc share. The realm owns each socket and drives
%% it as libuv drives a descriptor: each call is nonblocking (nowait), and the
%% select message of the socket module, which buoy_node_loop routes to
%% event/1, says that the descriptor is ready.
%%
%% - Reads: readStart arms a recv. A ready socket reads up to 32 times,
%%   64 KiB each, as uv__read does, and each read goes to onread as its own
%%   job. readStop leaves the data in the kernel, so the peer's writes stop
%%   when its window fills: the backpressure of TCP.
%% - event/1 runs outside any job, as libuv's poll phase does, and runs
%%   each JavaScript callback as a job (js/1), which drains the microtasks
%%   and ticks after it. A kick is a select message that the handle sends
%%   itself, so a read or a write that JavaScript starts runs there too.
%% - Writes: a write sends at once, as uv_try_write, and completes
%%   synchronously (kLastWriteWasAsync 0) when the kernel takes every byte.
%%   Otherwise the rest waits in a queue that drains when the socket is
%%   writable, and writeQueueSize counts its bytes. Bun's sockets write the
%%   same way: try the kernel first, and buffer only the rest.
%% - shutdown waits for the queue, then shuts the write side, and reads go
%%   on: half-close.
%% - A handle keeps the loop alive while it is ref'd and active: reading,
%%   listening, connecting, writing, or shutting down.
-module(buoy_node_socket).

-export([methods/1, handle_methods/1, create/2, adopt/3, find/1, state/1, save/2, kick/1, write_kick/1, later/1, js/1, event/1]).
-export([ensure/2, bind/3, listen/2, connect/4, open_fd/2, sockname/2, peername/2, setopt/3, errno/1, reset/2]).
-export([sockaddr/3, address_text/1, scope/1, open_inherited/2]).
-export([set_listener/2, read_start/1, read_stop/1, write_raw/2, shutdown_raw/1, buffer_bytes/1]).
-export_type([kind/0]).

-define(STATE, {'#', ?MODULE, <<"state">>}).
-define(K_READ_BYTES, 0).
-define(K_OFFSET, 1).
-define(K_BYTES_WRITTEN, 2).
-define(K_ASYNC, 3).
-define(UV_EOF, -4095).

-type kind() :: tcp | pipe | udp.

%%% The handle

%% Gives a new handle of Kind its state. The handle has no socket until it
%% binds, connects, or opens a descriptor.
-spec create(term(), kind()) -> ok.
create(Handle, Kind) ->
    buoy_heap:private_put(Handle, ?STATE, #{
        kind => Kind, socket => none, refed => true, closed => false, reading => false,
        listening => false, rsel => none, wsel => none, queue => [], queued => 0,
        shutdown => none, connect => none, rbuf => <<>>, user_buffer => none, path => none, listener => none,
        read => 0, written => 0, async_id => new_async_id()}).

%% The handle of a socket that a listener accepted, made with the constructor
%% of its kind, as TCPWrap::Instantiate makes it.
-spec adopt(term(), kind(), socket:socket()) -> term().
adopt(Constructor, Kind, Socket) ->
    Handle = buoy_heap:construct(Constructor, [0], Constructor),
    find(Handle) =:= error andalso create(Handle, Kind),
    attach(Handle, Socket),
    Handle.

-spec find(term()) -> {ok, map()} | error.
find(Handle) ->
    case buoy_heap:is_object(Handle) of
        true -> buoy_heap:private_find(Handle, ?STATE);
        false -> error
    end.

-spec state(term()) -> map().
state(Handle) ->
    {ok, S} = find(Handle),
    S.

%% Saves the state and refs or unrefs the loop when the handle's hold on it
%% changed.
-spec save(term(), map()) -> ok.
save(Handle, New) ->
    Old = state(Handle),
    case {holds(Old), holds(New)} of
        {false, true} -> buoy_node_loop:ref_handle();
        {true, false} -> buoy_node_loop:unref_handle();
        _ -> ok
    end,
    buoy_heap:private_put(Handle, ?STATE, New).

holds(#{closed := true}) -> false;
holds(#{refed := false}) -> false;
holds(#{reading := Reading, listening := Listening, connect := Connect, queue := Queue, shutdown := Shutdown}) ->
    Reading orelse Listening orelse Connect =/= none orelse Queue =/= [] orelse Shutdown =/= none.

attach(Handle, Socket) ->
    %% A read takes up to 64 KiB, as libuv's buffers do; the socket module
    %% reads 8 KiB by default, and a datagram arrives whole.
    _ = socket:setopt(Socket, {otp, rcvbuf}, 65536),
    erlang:put({?MODULE, Socket}, Handle),
    save(Handle, (state(Handle))#{socket := Socket}).

new_async_id() ->
    Fields = buoy_heap:get(buoy_node:binding(<<"async_wrap">>), <<"async_id_fields">>),
    Id = buoy_heap:get(Fields, 2) + 1,
    buoy_heap:set(Fields, 2, Id),
    Id.

%% Runs Fun as a later callback of the loop.
-spec later(fun(() -> term())) -> ok.
later(Fun) -> buoy_node_stream:call(self(), Fun).

%% Runs a JavaScript callback as a job of its own, from event/1.
-spec js(fun(() -> term())) -> ok.
js(Fun) -> buoy_jobs:run_job(Fun).

%%% The methods

%% StreamBase::WriteBuffer takes a Uint8Array, such as a Buffer, only.
-spec buffer_bytes(term()) -> binary().
buffer_bytes(V) ->
    case buoy_heap:is_object(V) andalso buoy_heap:class_of(V) =:= typed_array andalso element(1, buoy_heap:slots(V)) of
        uint8 -> buoy_node_encoding:view_bytes(V);
        _ -> buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>, <<"Second argument must be a buffer">>)
    end.


%% Defines the methods of HandleWrap and StreamBase on Proto. A handle with
%% no state of this module, such as a Pipe that process_wrap binds to a
%% channel, takes the method that Proto had before.
-spec methods(term()) -> ok.
methods(Proto) ->
    A = fun buoy_node:arg/2,
    Write = fun(Encode) -> fun(This, Args) -> write(This, A(1, Args), Encode(A(2, Args))) end end,
    Methods = [
        {<<"writeBuffer">>, Write(fun ?MODULE:buffer_bytes/1)},
        {<<"writeUtf8String">>, Write(fun(V) -> buoy_node_encoding:encode(utf8, V) end)},
        {<<"writeAsciiString">>, Write(fun(V) -> buoy_node_encoding:encode(latin1, V) end)},
        {<<"writeLatin1String">>, Write(fun(V) -> buoy_node_encoding:encode(latin1, V) end)},
        {<<"writeUcs2String">>, Write(fun(V) -> buoy_node_encoding:encode(ucs2, V) end)},
        {<<"writev">>, fun(This, Args) -> write(This, A(1, Args), writev_bytes(A(2, Args), buoy_ref:truthy(A(3, Args)))) end},
        {<<"readStart">>, fun(This, _) -> read_start(This) end},
        {<<"readStop">>, fun(This, _) -> save(This, (state(This))#{reading := false}), 0 end},
        {<<"shutdown">>, fun(This, Args) -> shutdown(This, A(1, Args)) end},
        {<<"useUserBuffer">>, fun(This, Args) -> save(This, (state(This))#{user_buffer := A(1, Args)}), undefined end},
        {<<"setBlocking">>, fun(_, _) -> 0 end}],
    [define(Proto, Name, value, Fun) || {Name, Fun} <- Methods],
    Getters = [{<<"bytesRead">>, fun(This, _) -> maps:get(read, state(This)) end},
               {<<"bytesWritten">>, fun(This, _) -> maps:get(written, state(This)) end},
               {<<"writeQueueSize">>, fun(This, _) -> maps:get(queued, state(This)) end}],
    [define(Proto, Name, get, Fun) || {Name, Fun} <- Getters],
    %% LibuvStreamWrap's flag, which tls.TLSSocket asserts before it wraps.
    buoy_heap:define(Proto, <<"isStreamBase">>, #{value => true, writable => true, enumerable => true, configurable => true}),
    handle_methods(Proto).

%% Defines the methods of HandleWrap on Proto, and the fd getter.
-spec handle_methods(term()) -> ok.
handle_methods(Proto) ->
    A = fun buoy_node:arg/2,
    Methods = [
        {<<"close">>, fun(This, Args) -> close(This, A(1, Args)) end},
        {<<"ref">>, fun(This, _) -> save(This, (state(This))#{refed := true}), undefined end},
        {<<"unref">>, fun(This, _) -> save(This, (state(This))#{refed := false}), undefined end},
        {<<"hasRef">>, fun(This, _) -> #{refed := R, closed := C} = state(This), R andalso not C end},
        {<<"getAsyncId">>, fun(This, _) -> maps:get(async_id, state(This)) end}],
    [define(Proto, Name, value, Fun) || {Name, Fun} <- Methods],
    define(Proto, <<"fd">>, get, fun(This, _) -> fd(state(This)) end),
    ok.

define(Proto, Name, Kind, Fun) ->
    Old = buoy_heap:get_own(Proto, Name),
    Method = fun(This, Args) ->
        case find(This) of
            {ok, _} -> Fun(This, Args);
            error -> fallback(Old, This, Args)
        end
    end,
    case Kind of
        value ->
            buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, Method), writable => true, enumerable => true, configurable => true});
        get ->
            buoy_heap:define(Proto, Name, #{get => buoy_node:fn(<<"get ", Name/binary>>, 0, Method), enumerable => true, configurable => true})
    end.

fallback({data, F, _}, This, Args) -> buoy_heap:call(F, This, Args);
fallback({accessor, Get, _, _}, This, _) when Get =/= undefined -> buoy_heap:call(Get, This, []);
fallback(_, _, _) -> undefined.

fd(#{socket := none}) -> -1;
fd(#{socket := Socket}) ->
    case socket:getopt(Socket, {otp, fd}) of
        {ok, Fd} -> Fd;
        _ -> -1
    end.

%%% Reads

%% Reads soon, unless a read waits for the socket already: a select
%% message that the handle sends itself.
-spec kick(term()) -> ok.
kick(Handle) ->
    case state(Handle) of
        #{rsel := none, socket := Socket, closed := false} = S when Socket =/= none ->
            Ref = make_ref(),
            save(Handle, S#{rsel := Ref}),
            self() ! {'$socket', Socket, select, Ref},
            ok;
        _ ->
            ok
    end.

%% Flushes soon, unless a write waits for the socket already.
-spec write_kick(term()) -> ok.
write_kick(Handle) ->
    case state(Handle) of
        #{wsel := none, socket := Socket, closed := false} = S when Socket =/= none ->
            Ref = make_ref(),
            save(Handle, S#{wsel := Ref}),
            self() ! {'$socket', Socket, select, Ref},
            ok;
        _ ->
            ok
    end.

%% The socket may have data: a datagram socket receives, a listener
%% accepts, and a stream reads.
readable(Handle) ->
    case state(Handle) of
        #{kind := udp} -> buoy_binding_udp_wrap:receive_ready(Handle);
        #{listening := true} -> accept(Handle, 32);
        _ -> read(Handle, 32)
    end.

%% Up to N reads while the handle reads, each to onread as a job; with no
%% data the socket selects, and event/1 calls back.
read(Handle, 0) ->
    kick(Handle);
read(Handle, N) ->
    case state(Handle) of
        #{closed := true} -> ok;
        #{reading := false} -> ok;
        #{rsel := Ref} when Ref =/= none -> ok;
        #{rbuf := Buffered} = S when Buffered =/= <<>> ->
            save(Handle, S#{rbuf := <<>>}),
            js(fun() -> data(Handle, Buffered) end),
            read(Handle, N - 1);
        #{socket := Socket} = S ->
            case socket:recv(Socket, 0, [], nowait) of
                {ok, Data} ->
                    js(fun() -> data(Handle, Data) end),
                    read(Handle, N - 1);
                {select, {{select_info, _, Ref}, Data}} ->
                    save(Handle, S#{rsel := Ref}),
                    js(fun() -> data(Handle, Data) end);
                {select, {select_info, _, Ref}} ->
                    save(Handle, S#{rsel := Ref});
                {error, closed} ->
                    js(fun() -> ended(Handle, ?UV_EOF) end);
                {error, Reason} ->
                    js(fun() -> ended(Handle, errno(Reason)) end)
            end
    end.

%% Data to onread, through the user's buffer when net set one (useUserBuffer):
%% what does not fit waits for the next read. A listener, such as the
%% TLSWrap that wraps the handle, takes the data in place of onread.
data(Handle, Data) ->
    case state(Handle) of
        #{listener := none} = S -> data(Handle, S, Data);
        #{listener := Listener} = S ->
            save(Handle, S#{read := maps:get(read, S) + byte_size(Data)}),
            Listener({data, Data})
    end.

data(Handle, S, Data) ->
    {Chunk, Rest} = case S of
        #{user_buffer := none} -> {Data, <<>>};
        #{user_buffer := User} ->
            Size = min(byte_size(Data), buoy_node_encoding:view_length(User)),
            <<C:Size/binary, R/binary>> = Data,
            buoy_node_encoding:view_write(User, 0, C),
            {C, R}
    end,
    save(Handle, S#{read := maps:get(read, S) + byte_size(Chunk), rbuf := <<Rest/binary, (maps:get(rbuf, S))/binary>>}),
    State = stream_state(),
    buoy_heap:set(State, ?K_READ_BYTES, byte_size(Chunk)),
    buoy_heap:set(State, ?K_OFFSET, 0),
    case S of
        #{user_buffer := none} ->
            Fresh = buoy_ref_buffer:allocate(byte_size(Chunk)),
            buoy_ref_buffer:write(Fresh, 0, Chunk),
            onread(Handle, Fresh);
        _ ->
            %% onread returns the next buffer of a generator (CustomBufferJSListener).
            Next = onread(Handle, undefined),
            buoy_heap:is_object(Next) andalso save(Handle, (state(Handle))#{user_buffer := Next})
    end.

%% The end of the stream (UV_EOF) or a read error: reading stops, as
%% uv__stream_eof stops it.
ended(Handle, Status) ->
    S = state(Handle),
    save(Handle, S#{reading := false}),
    case S of
        #{listener := none} ->
            buoy_heap:set(stream_state(), ?K_READ_BYTES, Status),
            onread(Handle, undefined);
        #{listener := Listener} when Status =:= ?UV_EOF ->
            Listener(eof);
        #{listener := Listener} ->
            Listener({error, Status})
    end.

onread(Handle, Arg) ->
    Onread = buoy_heap:get(Handle, <<"onread">>),
    buoy_heap:is_callable(Onread) andalso buoy_heap:call(Onread, Handle, [Arg]).

stream_state() ->
    buoy_heap:get(buoy_node:binding(<<"stream_wrap">>), <<"streamBaseState">>).

%%% Writes

write(Handle, Req, Bytes) ->
    State = stream_state(),
    Size = byte_size(Bytes),
    buoy_heap:set(State, ?K_BYTES_WRITTEN, Size),
    S0 = state(Handle),
    S = S0#{written := maps:get(written, S0) + Size},
    case S of
        #{closed := true} ->
            buoy_heap:set(State, ?K_ASYNC, 0),
            errno(ebadf);
        #{socket := none} ->
            buoy_heap:set(State, ?K_ASYNC, 0),
            errno(ebadf);
        #{queue := [], connect := none, socket := Socket} ->
            case socket:send(Socket, Bytes, [], nowait) of
                ok ->
                    save(Handle, S),
                    buoy_heap:set(State, ?K_ASYNC, 0),
                    0;
                {select, {{select_info, _, Ref}, Rest}} ->
                    buoy_heap:set(State, ?K_ASYNC, 1),
                    save(Handle, S#{queue := [{Req, Rest}], queued := byte_size(Rest), wsel := Ref}),
                    0;
                {select, {select_info, _, Ref}} ->
                    buoy_heap:set(State, ?K_ASYNC, 1),
                    save(Handle, S#{queue := [{Req, Bytes}], queued := Size, wsel := Ref}),
                    0;
                {error, Reason} ->
                    buoy_heap:set(State, ?K_ASYNC, 0),
                    errno(write_reason(Reason))
            end;
        #{queue := Queue, queued := Queued} ->
            buoy_heap:set(State, ?K_ASYNC, 1),
            save(Handle, S#{queue := Queue ++ [{Req, Bytes}], queued := Queued + Size}),
            0
    end.

write_reason(closed) -> epipe;
write_reason({Reason, _}) -> Reason;
write_reason(Reason) -> Reason.

%% The socket can take more: the queue drains in order, and each write that
%% the kernel took completes, as uv__write_callbacks completes it.
flush(Handle) ->
    case state(Handle) of
        #{closed := true} ->
            ok;
        #{queue := [{Req, Bytes} | Rest], queued := Queued, socket := Socket} = S ->
            case socket:send(Socket, Bytes, [], nowait) of
                ok ->
                    save(Handle, S#{queue := Rest, queued := Queued - byte_size(Bytes)}),
                    js(fun() -> complete(Req, 0, Handle) end),
                    flush(Handle);
                {select, {{select_info, _, Ref}, Left}} ->
                    save(Handle, S#{queue := [{Req, Left} | Rest], queued := Queued - byte_size(Bytes) + byte_size(Left), wsel := Ref});
                {select, {select_info, _, Ref}} ->
                    save(Handle, S#{wsel := Ref});
                {error, Reason} ->
                    save(Handle, S#{queue := [], queued := 0}),
                    Status = errno(write_reason(Reason)),
                    js(fun() -> [complete(R, Status, Handle) || {R, _} <- [{Req, Bytes} | Rest]] end),
                    flush(Handle)
            end;
        #{queue := [], shutdown := Req} when Req =/= none ->
            js(fun() -> finish_shutdown(Handle) end);
        _ ->
            ok
    end.

%% A request's oncomplete(status, handle, error), as StreamReq::Done calls it.
%% A write of a listener, {raw, Done}, calls Done(status).
complete({raw, Done}, Status, _Handle) ->
    Done(Status);
complete(Req, Status, Handle) ->
    Oncomplete = buoy_heap:get(Req, <<"oncomplete">>),
    buoy_heap:is_callable(Oncomplete) andalso buoy_heap:call(Oncomplete, Req, [Status, Handle, undefined]).

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

%% shutdown(req): 0, and req.oncomplete(status) once the queue drained and
%% the write side shut.
shutdown(Handle, Req) ->
    case state(Handle) of
        #{socket := none} -> errno(enotconn);
        #{closed := true} -> errno(ebadf);
        #{queue := []} = S ->
            save(Handle, S#{shutdown := Req}),
            later(fun() -> finish_shutdown(Handle) end),
            0;
        S ->
            save(Handle, S#{shutdown := Req}),
            0
    end.

finish_shutdown(Handle) ->
    case state(Handle) of
        #{shutdown := Req, socket := Socket, closed := false} = S when Req =/= none ->
            Status = case socket:shutdown(Socket, write) of
                ok -> 0;
                {error, Reason} -> errno(Reason)
            end,
            save(Handle, S#{shutdown := none}),
            complete(Req, Status, Handle);
        _ ->
            ok
    end.

%%% The parent of a wrapping stream

%% Listener(Event) takes the reads of the handle in place of onread: {data,
%% Bytes}, eof, or {error, Status}; none gives them back to onread.
-spec set_listener(term(), none | fun((term()) -> term())) -> ok.
set_listener(Handle, Listener) ->
    save(Handle, (state(Handle))#{listener := Listener}).

-spec read_start(term()) -> integer().
read_start(Handle) ->
    S = state(Handle),
    save(Handle, S#{reading := true}),
    kick(Handle),
    0.

-spec read_stop(term()) -> integer().
read_stop(Handle) ->
    save(Handle, (state(Handle))#{reading := false}),
    0.

%% Writes bytes of a listener: 0, or a negative errno.
-spec write_raw(term(), iodata()) -> integer().
write_raw(Handle, Bytes) ->
    write(Handle, {raw, fun(_) -> ok end}, iolist_to_binary(Bytes)).

%% Shuts the write side after the queued writes: 0, or a negative errno.
-spec shutdown_raw(term()) -> integer().
shutdown_raw(Handle) ->
    shutdown(Handle, {raw, fun(_) -> ok end}).

%%% Close

%% close(callback): the socket closes now; in a later callback the requests
%% that wait complete with UV_ECANCELED and then the callback runs, as
%% uv__stream_destroy and uv_close do.
close(Handle, Callback) ->
    case state(Handle) of
        #{closed := true} ->
            undefined;
        #{socket := Socket, queue := Queue, shutdown := Shutdown, connect := Connect, path := Path} = S ->
            Socket =:= none orelse begin erlang:erase({?MODULE, Socket}), socket:close(Socket) end,
            Path =:= none orelse file:delete(Path),
            save(Handle, S#{closed := true, reading := false, listening := false, queue := [], queued := 0,
                            shutdown := none, connect := none}),
            Cancelled = [R || {R, _} <- Queue] ++ [R || R <- [Shutdown, Connect], R =/= none],
            buoy_node_loop:defer(fun() ->
                [cancel(R, Handle, Connect) || R <- Cancelled],
                buoy_heap:is_callable(Callback) andalso buoy_heap:call(Callback, Handle, [])
            end),
            undefined
    end.

cancel(Req, Handle, Req) -> connected(Handle, Req, errno(ecanceled));
cancel(Req, Handle, _) -> complete(Req, errno(ecanceled), Handle).

%% reset(callback): closes with RST, as uv_tcp_close_reset.
-spec reset(term(), term()) -> term().
reset(Handle, Callback) ->
    case state(Handle) of
        #{socket := Socket} when Socket =/= none -> _ = socket:setopt(Socket, {socket, linger}, #{onoff => true, linger => 0});
        _ -> ok
    end,
    close(Handle, Callback),
    0.

%%% Connect, bind, listen, and accept

%% The socket of the handle, opened in Domain when it has none yet.
-spec ensure(term(), socket:domain()) -> {ok, socket:socket()} | {error, integer()}.
ensure(Handle, Domain) ->
    case state(Handle) of
        #{socket := none, kind := Kind} ->
            {Type, Protocol} = case Kind of
                tcp -> {stream, tcp};
                pipe -> {stream, default};
                udp -> {dgram, udp}
            end,
            case socket:open(Domain, Type, Protocol) of
                {ok, Socket} ->
                    attach(Handle, Socket),
                    {ok, Socket};
                {error, Reason} ->
                    {error, errno(Reason)}
            end;
        #{socket := Socket} ->
            {ok, Socket}
    end.

%% bind(handle, address, options): 0 or a negative errno. Address is a
%% sockaddr map of the socket module.
-spec bind(term(), map(), [{socket:socket_option(), term()}]) -> integer().
bind(Handle, #{family := Domain} = Address, Options) ->
    case ensure(Handle, Domain) of
        {ok, Socket} ->
            [socket:setopt(Socket, Option, Value) || {Option, Value} <- Options],
            case socket:bind(Socket, Address) of
                ok ->
                    case Address of
                        #{family := local, path := Path} -> save(Handle, (state(Handle))#{path := Path});
                        _ -> ok
                    end,
                    0;
                {error, Reason} ->
                    errno(Reason)
            end;
        {error, Errno} ->
            Errno
    end.

%% listen(backlog): accepts in later callbacks, each one to onconnection.
-spec listen(term(), integer()) -> integer().
listen(Handle, Backlog) ->
    case state(Handle) of
        #{socket := none} ->
            errno(einval);
        #{socket := Socket} = S ->
            case socket:listen(Socket, max(Backlog, 1)) of
                ok ->
                    save(Handle, S#{listening := true}),
                    kick(Handle),
                    0;
                {error, Reason} ->
                    errno(Reason)
            end
    end.

%% Up to N accepts, each to onconnection as a job, as uv__server_io loops.
%% An error waits 100 ms before the next accept, as one such as EMFILE
%% repeats until a descriptor frees.
accept(Handle, 0) ->
    kick(Handle);
accept(Handle, N) ->
    case state(Handle) of
        #{listening := true, rsel := none, socket := Socket, kind := Kind} = S ->
            case socket:accept(Socket, nowait) of
                {ok, Client} ->
                    Constructor = erlang:get({?MODULE, constructor, Kind}),
                    js(fun() -> onconnection(Handle, 0, adopt(Constructor, Kind, Client)) end),
                    accept(Handle, N - 1);
                {select, {select_info, _, Ref}} ->
                    save(Handle, S#{rsel := Ref});
                {error, Reason} ->
                    js(fun() -> onconnection(Handle, errno(Reason), undefined) end),
                    Ref = make_ref(),
                    save(Handle, (state(Handle))#{rsel := Ref}),
                    erlang:send_after(100, self(), {'$socket', Socket, select, Ref}),
                    ok
            end;
        _ ->
            ok
    end.

onconnection(Handle, Status, Client) ->
    F = buoy_heap:get(Handle, <<"onconnection">>),
    buoy_heap:is_callable(F) andalso buoy_heap:call(F, Handle, [Status, Client]).

%% connect(handle, req, address, delayed): 0, and req.oncomplete(status,
%% handle, req, readable, writable) when the connection is up or failed.
%% An error that Delayed holds also reports through oncomplete, as libuv
%% delays ECONNREFUSED; another one returns at once.
-spec connect(term(), term(), map(), [atom()] | all) -> integer().
connect(Handle, Req, #{family := Domain} = Address, Delayed) ->
    case ensure(Handle, Domain) of
        {ok, Socket} ->
            S = state(Handle),
            case socket:connect(Socket, Address, nowait) of
                ok ->
                    save(Handle, S#{connect := Req}),
                    later(fun() -> connected(Handle, Req, 0) end),
                    0;
                {select, {select_info, _, Ref}} ->
                    save(Handle, S#{connect := Req, wsel := Ref}),
                    0;
                {error, Reason} ->
                    case Delayed =:= all orelse lists:member(Reason, Delayed) of
                        true ->
                            save(Handle, S#{connect := Req}),
                            later(fun() -> connected(Handle, Req, errno(Reason)) end),
                            0;
                        false ->
                            errno(Reason)
                    end
            end;
        {error, Errno} when Delayed =:= all ->
            buoy_node_loop:defer(fun() -> connected(Handle, Req, Errno) end),
            0;
        {error, Errno} ->
            Errno
    end.

connected(Handle, Req, Status) ->
    case state(Handle) of
        #{connect := Req} = S -> save(Handle, S#{connect := none});
        _ -> ok
    end,
    Oncomplete = buoy_heap:get(Req, <<"oncomplete">>),
    buoy_heap:is_callable(Oncomplete) andalso buoy_heap:call(Oncomplete, Req, [Status, Handle, Req, true, true]),
    case state(Handle) of
        #{queue := [_ | _]} -> write_kick(Handle);
        _ -> ok
    end.

%% open(fd): the handle takes a socket descriptor that the VM inherited.
-spec open_fd(term(), integer()) -> integer().
open_fd(Handle, Fd) ->
    case open_inherited(Fd, #{}) of
        {ok, Socket} -> attach(Handle, Socket), 0;
        {error, Reason} -> errno(Reason)
    end.

%% socket:open/2 of a descriptor that the VM did not open. macOS has no
%% SO_DOMAIN, so a duplicate opened as inet finds the family with
%% getsockname, as uv_guess_handle does.
-spec open_inherited(integer(), map()) -> {ok, socket:socket()} | {error, term()}.
open_inherited(Fd, Options) ->
    case socket:open(Fd, Options) of
        {error, {invalid, {options, domain, _}}} ->
            case socket:open(Fd, #{dup => true, domain => inet}) of
                {ok, Probe} ->
                    Name = socket:sockname(Probe),
                    socket:close(Probe),
                    case Name of
                        {ok, #{family := Family}} -> socket:open(Fd, Options#{domain => Family});
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        Result ->
            Result
    end.

%% The socket's own address or its peer's, or a negative errno.
-spec sockname(term(), term()) -> integer().
sockname(Handle, Out) -> address(Handle, Out, fun socket:sockname/1).

-spec peername(term(), term()) -> integer().
peername(Handle, Out) -> address(Handle, Out, fun socket:peername/1).

address(Handle, Out, Get) ->
    case state(Handle) of
        #{socket := none} ->
            errno(ebadf);
        #{socket := Socket} ->
            case Get(Socket) of
                {ok, #{family := Family, port := Port} = Sockaddr} when Family =:= inet; Family =:= inet6 ->
                    buoy_heap:set(Out, <<"address">>, address_text(Sockaddr)),
                    buoy_heap:set(Out, <<"family">>, case Family of inet -> <<"IPv4">>; inet6 -> <<"IPv6">> end),
                    buoy_heap:set(Out, <<"port">>, Port),
                    0;
                {ok, _} ->
                    errno(einval);
                {error, Reason} ->
                    errno(Reason)
            end
    end.

%% The sockaddr of an address text and a port: an IPv6 address may end in
%% %<interface> or %<index>, its scope, as uv_ip6_addr reads it.
-spec sockaddr(inet | inet6, term(), term()) -> {ok, map()} | error.
sockaddr(inet, Address, Port) ->
    case inet:parse_ipv4strict_address(text(Address)) of
        {ok, Addr} -> {ok, #{family => inet, addr => Addr, port => port(Port)}};
        {error, _} -> error
    end;
sockaddr(inet6, Address, Port) ->
    {Text, Scope} = case string:split(text(Address), "%") of
        [A, S] -> {A, S};
        [A] -> {A, ""}
    end,
    case inet:parse_ipv6strict_address(Text) of
        {ok, Addr} -> {ok, #{family => inet6, addr => Addr, port => port(Port), flowinfo => 0, scope_id => scope(Scope)}};
        {error, _} -> error
    end.

%% The index of an interface name or number, or 0.
-spec scope(string()) -> non_neg_integer().
scope("") -> 0;
scope(Scope) ->
    case {string:to_integer(Scope), net:if_name2index(Scope)} of
        {{N, ""}, _} when is_integer(N), N >= 0 -> N;
        {_, {ok, Index}} -> Index;
        _ -> 0
    end.

text(V) -> unicode:characters_to_list(buoy_ref_string:to_utf8(buoy_ref:to_string(V))).

port(V) ->
    case buoy_ref:to_number(V) of
        N when is_integer(N) -> N;
        F when is_float(F), F == trunc(F) -> trunc(F);
        _ -> 0
    end.

%% The text of a sockaddr's address, with the %<interface> of a scoped IPv6
%% address, as Node's AddressToJS writes it.
-spec address_text(map()) -> term().
address_text(#{family := inet6, addr := Addr, scope_id := Scope}) when Scope > 0 ->
    Name = case net:if_index2name(Scope) of
        {ok, N} -> N;
        _ -> integer_to_list(Scope)
    end,
    buoy_node:string([inet:ntoa(Addr), "%", Name]);
address_text(#{addr := Addr}) ->
    buoy_node:string(inet:ntoa(Addr)).

%% Sets an option of the handle's socket: 0 or a negative errno.
-spec setopt(term(), socket:socket_option(), term()) -> integer().
setopt(Handle, Option, Value) ->
    case state(Handle) of
        #{socket := none} -> 0;
        #{socket := Socket} ->
            case socket:setopt(Socket, Option, Value) of
                ok -> 0;
                {error, Reason} -> errno(Reason)
            end
    end.

%%% The loop

%% A select message of the socket module, or a kick: the socket of a
%% handle is ready for the read or the write that waited. It runs outside
%% any job (buoy_node_loop).
-spec event(term()) -> ok.
event({'$socket', Socket, select, Ref}) ->
    case erlang:get({?MODULE, Socket}) of
        undefined ->
            ok;
        Handle ->
            case state(Handle) of
                #{rsel := Ref} = S -> save(Handle, S#{rsel := none}), readable(Handle);
                #{wsel := Ref, connect := Req} = S when Req =/= none ->
                    save(Handle, S#{wsel := none}),
                    Status = case socket:connect(Socket) of
                        ok -> 0;
                        {error, Reason} -> errno(Reason)
                    end,
                    js(fun() -> connected(Handle, Req, Status) end);
                #{wsel := Ref, kind := udp} = S -> save(Handle, S#{wsel := none}), buoy_binding_udp_wrap:send_ready(Handle);
                #{wsel := Ref} = S -> save(Handle, S#{wsel := none}), flush(Handle);
                _ -> ok
            end
    end,
    ok;
event(_) ->
    ok.

%% The negative errno of libuv for an error of the socket module.
-spec errno(term()) -> integer().
errno({Reason, _}) ->
    errno(Reason);
errno(Reason) when is_atom(Reason) ->
    Name = string:uppercase(atom_to_binary(Reason)),
    case lists:keyfind(Name, 2, buoy_binding_uv:errors()) of
        {Code, _, _} -> Code;
        false when Reason =:= einval -> -22;
        false -> errno(einval)
    end;
errno(_) ->
    errno(einval).
