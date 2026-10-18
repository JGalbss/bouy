%% internalBinding('task_queue') (src/node_task_queue.cc): the microtask
%% queue of the realm, the tick callback, and the promise rejection callback,
%% which buoy_node_loop calls.
-module(buoy_binding_task_queue).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    TickInfo = buoy_node:typed_array(<<"Uint8Array">>, 2),
    buoy_node_loop:set_callback(tick_info, TickInfo),
    F = fun buoy_node:fn/3,
    buoy_node:object([
        {<<"enqueueMicrotask">>, F(<<"enqueueMicrotask">>, 1, fun(_, A) ->
            Callback = buoy_node:arg(1, A),
            buoy_jobs:enqueue(fun() -> buoy_heap:call(Callback, undefined, []) end),
            undefined
        end)},
        {<<"setTickCallback">>, F(<<"setTickCallback">>, 1, fun(_, A) ->
            buoy_node_loop:set_callback(tick, buoy_node:arg(1, A)),
            undefined
        end)},
        {<<"runMicrotasks">>, F(<<"runMicrotasks">>, 0, fun(_, _) -> buoy_jobs:drain(), undefined end)},
        {<<"tickInfo">>, TickInfo},
        {<<"promiseRejectEvents">>, buoy_node:object([
            {<<"kPromiseRejectWithNoHandler">>, 0}, {<<"kPromiseHandlerAddedAfterReject">>, 1},
            {<<"kPromiseResolveAfterResolved">>, 3}, {<<"kPromiseRejectAfterResolved">>, 2}])},
        {<<"setPromiseRejectCallback">>, F(<<"setPromiseRejectCallback">>, 1, fun(_, A) ->
            buoy_node_loop:set_callback(promise_reject, buoy_node:arg(1, A)),
            undefined
        end)}]).
