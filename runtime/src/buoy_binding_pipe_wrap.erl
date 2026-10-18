%% internalBinding('pipe_wrap') (src/pipe_wrap.cc): Pipe, the handle of the
%% stdio pipes of a child process. process_wrap binds each one to its
%% channel; the StreamBase methods are buoy_node_stream's. open(fd) reads and
%% writes a descriptor that the VM inherited: the standard descriptors through
%% buoy_node_stdio, and others, such as the IPC channel of a forked child
%% (NODE_CHANNEL_FD), through a port. A Pipe that connects or listens fails with
%% ENOTSUP until Buoy has local sockets.
-module(buoy_binding_pipe_wrap).

-export([binding/0]).

-define(UV_ENOTSUP, -45).

-spec binding() -> term().
binding() ->
    Pipe = buoy_node:constructor(<<"Pipe">>, 1, fun(_, _) -> undefined end),
    Proto = buoy_heap:get(Pipe, <<"prototype">>),
    buoy_node_stream:methods(Proto),
    buoy_node_stdio:methods(Proto),
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, fun(_, _) -> ?UV_ENOTSUP end),
                                      writable => true, enumerable => true, configurable => true})
     || Name <- [<<"bind">>, <<"listen">>, <<"connect">>, <<"fchmod">>, <<"setPendingInstances">>]],
    buoy_heap:define(Proto, <<"open">>, #{value => buoy_node:fn(<<"open">>, 0, fun(This, Args) -> open(This, buoy_node:arg(1, Args)) end),
                                          writable => true, enumerable => true, configurable => true}),
    buoy_node:object([
        {<<"Pipe">>, Pipe},
        {<<"PipeConnectWrap">>, buoy_node:constructor(<<"PipeConnectWrap">>, 0, fun(_, _) -> undefined end)},
        {<<"constants">>, buoy_node:object([{<<"SOCKET">>, 0}, {<<"SERVER">>, 1}, {<<"IPC">>, 2},
                                            {<<"UV_READABLE">>, 1}, {<<"UV_WRITABLE">>, 2}])}]).

%% open(fd): a channel process owns a port on the descriptor; the handle stays
%% a root of the heap until the channel ends.
open(This, Fd) when Fd =:= 0; Fd =:= 1; Fd =:= 2 ->
    buoy_node_stdio:open(This, Fd),
    0;
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
