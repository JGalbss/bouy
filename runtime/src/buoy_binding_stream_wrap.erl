%% internalBinding('stream_wrap') (src/stream_wrap.cc): the shared state of
%% StreamBase reads and writes, and the request classes of writes and
%% shutdowns. buoy_node_stream implements the methods of the stream handles.
-module(buoy_binding_stream_wrap).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    Request = fun(Name) -> buoy_node:constructor(Name, 0, fun(_, _) -> undefined end) end,
    Stream = buoy_node:constructor(<<"LibuvStreamWrap">>, 0, fun(_, _) -> undefined end),
    buoy_node_stream:methods(buoy_heap:get(Stream, <<"prototype">>)),
    buoy_node:object([
        {<<"kReadBytesOrError">>, 0}, {<<"kArrayBufferOffset">>, 1}, {<<"kBytesWritten">>, 2},
        {<<"kLastWriteWasAsync">>, 3},
        {<<"streamBaseState">>, buoy_node:typed_array(<<"Int32Array">>, 4)},
        {<<"WriteWrap">>, Request(<<"WriteWrap">>)},
        {<<"ShutdownWrap">>, Request(<<"ShutdownWrap">>)},
        {<<"LibuvStreamWrap">>, Stream}]).
