%% internalBinding('pipe_wrap') (src/pipe_wrap.cc): Pipe, the handle of a
%% local socket and of the stdio pipes of a child process. A Pipe that
%% binds, listens, or connects becomes a local (Unix domain) socket that
%% buoy_node_socket drives, as TCP's handle; process_wrap binds each stdio
%% pipe to its channel instead, and those keep the methods of
%% buoy_node_stream. open(fd) reads and writes a descriptor that the VM
%% inherited, such as the IPC channel of a forked child (NODE_CHANNEL_FD).
-module(buoy_binding_pipe_wrap).

-export([binding/0]).

-define(UV_EINVAL, -22).
-define(UV_EBADF, -9).
-define(TYPE, {'#', ?MODULE, <<"type">>}).
-define(IPC, 2).

-spec binding() -> term().
binding() ->
    Pipe = buoy_node:constructor(<<"Pipe">>, 1, fun(This, Args) -> buoy_heap:private_put(This, ?TYPE, buoy_node:arg(1, Args)), undefined end),
    erlang:put({buoy_node_socket, constructor, pipe}, Pipe),
    Proto = buoy_heap:get(Pipe, <<"prototype">>),
    buoy_node_stream:methods(Proto),
    buoy_node_socket:methods(Proto),
    A = fun buoy_node:arg/2,
    Methods = [{<<"bind">>, fun(This, Args) -> bind(This, A(1, Args)) end},
               {<<"listen">>, fun(This, Args) -> listen(This, A(1, Args)) end},
               {<<"connect">>, fun(This, Args) -> connect(This, A(1, Args), A(2, Args)) end},
               {<<"fchmod">>, fun(This, Args) -> fchmod(This, A(1, Args)) end},
               {<<"setPendingInstances">>, fun(_, _) -> undefined end},
               {<<"open">>, fun(This, Args) -> open(This, A(1, Args)) end}],
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    buoy_node:object([
        {<<"Pipe">>, Pipe},
        {<<"PipeConnectWrap">>, buoy_node:constructor(<<"PipeConnectWrap">>, 0, fun(_, _) -> undefined end)},
        {<<"constants">>, buoy_node:object([{<<"SOCKET">>, 0}, {<<"SERVER">>, 1}, {<<"IPC">>, 2},
                                            {<<"UV_READABLE">>, 1}, {<<"UV_WRITABLE">>, 2}])}]).

path(V) -> buoy_ref_string:to_utf8(buoy_ref:to_string(V)).

%% The handle as a local socket: its state of buoy_node_socket.
local(Handle) ->
    buoy_node_socket:find(Handle) =:= error andalso buoy_node_socket:create(Handle, pipe),
    ok.

bind(This, Name) ->
    local(This),
    case local_path(Name) of
        {ok, Path} ->
            Status = on_path(Path, fun(P) -> buoy_node_socket:bind(This, #{family => local, path => P}, []) end),
            Status =:= 0 andalso buoy_node_socket:save(This, (buoy_node_socket:state(This))#{path := Path}),
            Status;
        error ->
            ?UV_EINVAL
    end.

listen(This, Backlog) ->
    case buoy_node_socket:find(This) of
        {ok, _} -> buoy_node_socket:listen(This, trunc(buoy_ref:to_number(Backlog)));
        error -> ?UV_EINVAL
    end.

%% connect(req, name): libuv reports every error of a pipe's connect
%% through the request.
connect(This, Req, Name) ->
    local(This),
    case local_path(Name) of
        {ok, Path} -> on_path(Path, fun(P) -> buoy_node_socket:connect(This, Req, #{family => local, path => P}, all) end);
        error -> ?UV_EINVAL
    end.

%% fchmod(flags): uv_pipe_chmod gives everyone read (UV_READABLE) and
%% write (UV_WRITABLE) on top of the socket file's mode.
fchmod(This, Flags) ->
    Bits = trunc(buoy_ref:to_number(Flags)),
    Add = (case Bits band 1 of 0 -> 0; _ -> 8#444 end) bor (case Bits band 2 of 0 -> 0; _ -> 8#222 end),
    case buoy_node_socket:find(This) of
        {ok, #{path := Path}} when Path =/= none, Add =/= 0 ->
            case file:read_file_info(Path) of
                {ok, Info} ->
                    case file:change_mode(Path, (element(8, Info) band 8#7777) bor Add) of
                        ok -> 0;
                        {error, Reason} -> buoy_node_socket:errno(Reason)
                    end;
                {error, Reason} ->
                    buoy_node_socket:errno(Reason)
            end;
        {ok, _} ->
            ?UV_EINVAL;
        _ ->
            ?UV_EBADF
    end.

%% A socket path longer than sun_path is EINVAL, as pipe_wrap passes
%% UV_PIPE_NO_TRUNCATE.
local_path(V) ->
    Path = path(V),
    case byte_size(Path) > sun_path() of
        true -> error;
        false -> {ok, Path}
    end.

sun_path() ->
    case os:type() of {unix, darwin} -> 104; _ -> 108 end.

%% Fun(Path) for bind or connect. libuv takes a path that fills sun_path
%% with no NUL, where the socket module needs room for one, so such a path
%% goes through a short symlink to its directory, which the kernel resolves
%% during the call.
on_path(Path, Fun) ->
    case byte_size(Path) < sun_path() of
        true -> Fun(Path);
        false -> on_link(Path, Fun)
    end.

on_link(Path, Fun) ->
    Link = iolist_to_binary(["/tmp/buoy-", os:getpid(), $-, integer_to_list(erlang:unique_integer([positive]))]),
    case file:make_symlink(filename:absname(filename:dirname(Path)), Link) of
        ok ->
            try Fun(filename:join(Link, filename:basename(Path))) after file:delete(Link) end;
        {error, Reason} ->
            buoy_node_socket:errno(Reason)
    end.

%% open(fd): an IPC Pipe on a socket is the channel of buoy_node_ipc, which
%% passes handles. Otherwise a channel process owns a port on the
%% descriptor; the handle stays a root of the heap until the channel ends.
open(This, Fd) when is_integer(Fd), Fd >= 0 ->
    case is_ipc(This) andalso buoy_node_ipc:open(This, Fd) of
        ok -> 0;
        _ -> open_port_channel(This, Fd)
    end;
open(_This, _Fd) ->
    -22.

is_ipc(This) ->
    case buoy_heap:private_find(This, ?TYPE) of
        {ok, Type} -> Type == ?IPC;
        error -> false
    end.

open_port_channel(This, Fd) ->
    Realm = self(),
    Channel = spawn(fun() ->
        Port = open_port({fd, Fd, Fd}, [binary, stream, eof]),
        fd_loop(Port, Realm, This)
    end),
    erlang:put({?MODULE, root, Channel}, This),
    buoy_node_stream:attach(This, Channel),
    0.

fd_loop(Port, Realm, Handle) ->
    receive
        {Port, {data, Data}} ->
            call(Realm, fun() -> buoy_node_stream:deliver(Handle, Data) end),
            fd_loop(Port, Realm, Handle);
        {Port, eof} ->
            ended(Realm, Handle);
        {write, Bytes, From, Ref} ->
            Status = try port_command(Port, Bytes) of true -> 0 catch error:badarg -> -32 end,
            call(From, fun() -> buoy_node_stream:written(Ref, Status, ok) end),
            fd_loop(Port, Realm, Handle);
        shutdown ->
            fd_loop(Port, Realm, Handle);
        close ->
            try port_close(Port) catch error:badarg -> ok end,
            ended(Realm, Handle)
    end.

ended(Realm, Handle) ->
    Self = self(),
    call(Realm, fun() ->
        buoy_node_stream:deliver(Handle, eof),
        erlang:erase({?MODULE, root, Self})
    end).

call(Realm, Fun) -> buoy_node_stream:call(Realm, Fun).
