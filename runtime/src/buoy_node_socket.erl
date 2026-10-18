%% Node's libuv stream handles over OTP sockets (the socket module): the
%% HandleWrap and StreamBase methods of src/handle_wrap.cc, stream_wrap.cc,
%% and stream_base.cc, and the connect, bind, listen, and accept that
%% tcp_wrap.cc and pipe_wrap.cc share. The realm owns each socket and drives
%% it as libuv drives a descriptor: each call is nonblocking (nowait), and the
%% select message of the socket module, which buoy_node_loop routes to
%% event/1, says that the descriptor is ready.
%%
%% - Reads: readStart arms a recv, and each read goes to onread as its own
%%   callback. readStop leaves the data in the kernel, so the peer's writes
%%   stop when its window fills: the backpressure of TCP.
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

-export([methods/1, handle_methods/1, create/2, adopt/3, find/1, state/1, save/2, kick/1, later/1, event/1]).
-export([ensure/2, bind/3, listen/2, connect/4, open_fd/2, open_descriptor/2, sockname/2, peername/2, setopt/3, errno/1, reset/2]).
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
        listening => false, rsel => none, wsel => none, kicked => false, queue => [], queued => 0,
        shutdown => none, connect => none, rbuf => <<>>, user_buffer => none, path => none,
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

%%% The methods

%% Defines the methods of HandleWrap and StreamBase on Proto. A handle with
%% no state of this module, such as a Pipe that process_wrap binds to a
%% channel, takes the method that Proto had before.
-spec methods(term()) -> ok.
methods(Proto) ->
    A = fun buoy_node:arg/2,
    Write = fun(Encode) -> fun(This, Args) -> write(This, A(1, Args), Encode(A(2, Args))) end end,
    Methods = [
        {<<"writeBuffer">>, Write(fun buoy_node_encoding:write_buffer_bytes/1)},
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

read_start(Handle) ->
    S = state(Handle),
    save(Handle, S#{reading := true}),
    kick(Handle),
    0.

%% Reads in a later callback, unless a read waits for the socket already.
-spec kick(term()) -> ok.
kick(Handle) ->
    case state(Handle) of
        #{rsel := none, kicked := false, socket := Socket} = S when Socket =/= none ->
            save(Handle, S#{kicked := true}),
            later(fun() -> save(Handle, (state(Handle))#{kicked := false}), readable(Handle) end);
        _ ->
            ok
    end.

%% The socket may have data: a datagram socket receives, a listener
%% accepts, and a stream reads.
readable(Handle) ->
    case state(Handle) of
        #{kind := udp} -> buoy_binding_udp_wrap:receive_ready(Handle);
        #{listening := true} -> accept(Handle);
        _ -> read(Handle)
    end.

%% One read while the handle reads: data, the end, or an error goes to
%% onread, and the next read is a later callback. With no data the socket
%% selects, and event/1 calls back.
read(Handle) ->
    case state(Handle) of
        #{closed := true} -> ok;
        #{reading := false} -> ok;
        #{rsel := Ref} when Ref =/= none -> ok;
        #{rbuf := Buffered} = S when Buffered =/= <<>> ->
            save(Handle, S#{rbuf := <<>>}),
            data(Handle, Buffered),
            kick(Handle);
        #{socket := Socket} = S ->
            case socket:recv(Socket, 0, [], nowait) of
                {ok, Data} ->
                    data(Handle, Data),
                    kick(Handle);
                {select, {{select_info, _, Ref}, Data}} ->
                    save(Handle, S#{rsel := Ref}),
                    data(Handle, Data);
                {select, {select_info, _, Ref}} ->
                    save(Handle, S#{rsel := Ref});
                {error, closed} ->
                    ended(Handle, ?UV_EOF);
                {error, Reason} ->
                    ended(Handle, errno(Reason))
            end
    end.

%% Data to onread, through the user's buffer when net set one (useUserBuffer):
%% what does not fit waits for the next read.
data(Handle, Data) ->
    S = state(Handle),
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
    save(Handle, (state(Handle))#{reading := false}),
    buoy_heap:set(stream_state(), ?K_READ_BYTES, Status),
    onread(Handle, undefined).

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
                    complete(Req, 0, Handle),
                    flush(Handle);
                {select, {{select_info, _, Ref}, Left}} ->
                    save(Handle, S#{queue := [{Req, Left} | Rest], queued := Queued - byte_size(Bytes) + byte_size(Left), wsel := Ref});
                {select, {select_info, _, Ref}} ->
                    save(Handle, S#{wsel := Ref});
                {error, Reason} ->
                    save(Handle, S#{queue := [], queued := 0}),
                    Status = errno(write_reason(Reason)),
                    [complete(R, Status, Handle) || {R, _} <- [{Req, Bytes} | Rest]],
                    flush(Handle)
            end;
        #{queue := [], shutdown := Req} when Req =/= none ->
            finish_shutdown(Handle);
        _ ->
            ok
    end.

%% A request's oncomplete(status, handle, error), as StreamReq::Done calls it.
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
                    %% A datagram arrives whole: room for the largest one.
                    Kind =:= udp andalso socket:setopt(Socket, {otp, rcvbuf}, 65536),
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
                    later(fun() -> accept(Handle) end),
                    0;
                {error, Reason} ->
                    errno(Reason)
            end
    end.

accept(Handle) ->
    case state(Handle) of
        #{listening := true, rsel := none, socket := Socket, kind := Kind} = S ->
            case socket:accept(Socket, nowait) of
                {ok, Client} ->
                    Constructor = erlang:get({?MODULE, constructor, Kind}),
                    onconnection(Handle, 0, adopt(Constructor, Kind, Client)),
                    later(fun() -> accept(Handle) end);
                {select, {select_info, _, Ref}} ->
                    save(Handle, S#{rsel := Ref});
                {error, Reason} ->
                    onconnection(Handle, errno(Reason), undefined),
                    later(fun() -> accept(Handle) end)
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
    flush(Handle).

%% open(fd): the handle takes a socket descriptor that the VM inherited.
-spec open_fd(term(), integer()) -> integer().
open_fd(Handle, Fd) ->
    case open_descriptor(Fd, #{}) of
        {ok, Socket} -> attach(Handle, Socket), 0;
        {error, Reason} -> errno(Reason)
    end.

%% A socket on the descriptor Fd. OTP reads its domain with SO_DOMAIN, which
%% macOS lacks: there a duplicate opens as inet, and its sockname gives the
%% family, which sockaddr carries whatever the domain.
-spec open_descriptor(integer(), map()) -> {ok, socket:socket()} | {error, term()}.
open_descriptor(Fd, Options) ->
    case socket:open(Fd, Options) of
        {error, {invalid, {options, domain, _}}} ->
            case socket:open(Fd, #{domain => inet, dup => true}) of
                {ok, Probe} ->
                    Name = socket:sockname(Probe),
                    socket:close(Probe),
                    case Name of
                        {ok, #{family := Family}} -> socket:open(Fd, Options#{domain => Family});
                        {error, _} = Error -> Error
                    end;
                Error ->
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
                {ok, #{family := Family, addr := Addr, port := Port}} when Family =:= inet; Family =:= inet6 ->
                    buoy_heap:set(Out, <<"address">>, buoy_node:string(inet:ntoa(Addr))),
                    buoy_heap:set(Out, <<"family">>, case Family of inet -> <<"IPv4">>; inet6 -> <<"IPv6">> end),
                    buoy_heap:set(Out, <<"port">>, Port),
                    0;
                {ok, _} ->
                    errno(einval);
                {error, Reason} ->
                    errno(Reason)
            end
    end.

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

%% A select message of the socket module: the socket of a handle is ready
%% for the read or the write that waited.
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
                    connected(Handle, Req, Status);
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
