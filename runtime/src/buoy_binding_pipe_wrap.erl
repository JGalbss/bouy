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

-spec binding() -> term().
binding() ->
    Pipe = buoy_node:constructor(<<"Pipe">>, 1, fun(_, _) -> undefined end),
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
    buoy_node_socket:bind(This, #{family => local, path => path(Name)}, []).

listen(This, Backlog) ->
    case buoy_node_socket:find(This) of
        {ok, _} -> buoy_node_socket:listen(This, trunc(buoy_ref:to_number(Backlog)));
        error -> ?UV_EINVAL
    end.

%% connect(req, name): libuv reports every error of a pipe's connect
%% through the request.
connect(This, Req, Name) ->
    local(This),
    buoy_node_socket:connect(This, Req, #{family => local, path => path(Name)}, all).

fchmod(This, Mode) ->
    case buoy_node_socket:find(This) of
        {ok, #{path := Path}} when Path =/= none ->
            case file:change_mode(Path, trunc(buoy_ref:to_number(Mode))) of
                ok -> 0;
                {error, Reason} -> buoy_node_socket:errno(Reason)
            end;
        _ ->
            ?UV_EBADF
    end.

%% open(fd): a channel process owns a port on the descriptor; the handle stays
%% a root of the heap until the channel ends.
open(This, Fd) when is_integer(Fd), Fd >= 0 ->
    Realm = self(),
    Channel = spawn(fun() ->
        Port = open_port({fd, Fd, Fd}, [binary, stream, eof]),
        fd_loop(Port, Realm, This)
    end),
    erlang:put({?MODULE, root, Channel}, This),
    buoy_node_stream:attach(This, Channel),
    0;
open(_This, _Fd) ->
    -22.

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
