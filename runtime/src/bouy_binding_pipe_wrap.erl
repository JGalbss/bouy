%% internalBinding('pipe_wrap') (src/pipe_wrap.cc): Pipe, the handle of the
%% stdio pipes of a child process. process_wrap binds each one to its
%% channel; the StreamBase methods are bouy_node_stream's. A Pipe that
%% connects, listens, or opens a file descriptor fails with ENOTSUP until
%% Bouy has local sockets.
-module(bouy_binding_pipe_wrap).

-export([binding/0]).

-define(UV_ENOTSUP, -45).

-spec binding() -> term().
binding() ->
    Pipe = bouy_node:constructor(<<"Pipe">>, 1, fun(_, _) -> undefined end),
    Proto = bouy_heap:get(Pipe, <<"prototype">>),
    bouy_node_stream:methods(Proto),
    [bouy_heap:define(Proto, Name, #{value => bouy_node:fn(Name, 0, fun(_, _) -> ?UV_ENOTSUP end),
                                      writable => true, enumerable => true, configurable => true})
     || Name <- [<<"open">>, <<"bind">>, <<"listen">>, <<"connect">>, <<"fchmod">>, <<"setPendingInstances">>]],
    bouy_node:object([
        {<<"Pipe">>, Pipe},
        {<<"PipeConnectWrap">>, bouy_node:constructor(<<"PipeConnectWrap">>, 0, fun(_, _) -> undefined end)},
        {<<"constants">>, bouy_node:object([{<<"SOCKET">>, 0}, {<<"SERVER">>, 1}, {<<"IPC">>, 2},
                                            {<<"UV_READABLE">>, 1}, {<<"UV_WRITABLE">>, 2}])}]).
