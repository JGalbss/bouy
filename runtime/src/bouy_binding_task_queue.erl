%% internalBinding('task_queue') (src/node_task_queue.cc): the microtask
%% queue of the realm, the tick callback, and the promise rejection callback,
%% which bouy_node_loop calls.
-module(bouy_binding_task_queue).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    TickInfo = bouy_node:typed_array(<<"Uint8Array">>, 2),
    bouy_node_loop:set_callback(tick_info, TickInfo),
    F = fun bouy_node:fn/3,
    bouy_node:object([
        {<<"enqueueMicrotask">>, F(<<"enqueueMicrotask">>, 1, fun(_, A) ->
            Callback = bouy_node:arg(1, A),
            bouy_jobs:enqueue(fun() -> bouy_heap:call(Callback, undefined, []) end),
            undefined
        end)},
        {<<"setTickCallback">>, F(<<"setTickCallback">>, 1, fun(_, A) ->
            bouy_node_loop:set_callback(tick, bouy_node:arg(1, A)),
            undefined
        end)},
        {<<"runMicrotasks">>, F(<<"runMicrotasks">>, 0, fun(_, _) -> bouy_jobs:drain(), undefined end)},
        {<<"tickInfo">>, TickInfo},
        {<<"promiseRejectEvents">>, bouy_node:object([
            {<<"kPromiseRejectWithNoHandler">>, 0}, {<<"kPromiseHandlerAddedAfterReject">>, 1},
            {<<"kPromiseResolveAfterResolved">>, 3}, {<<"kPromiseRejectAfterResolved">>, 2}])},
        {<<"setPromiseRejectCallback">>, F(<<"setPromiseRejectCallback">>, 1, fun(_, A) ->
            bouy_node_loop:set_callback(promise_reject, bouy_node:arg(1, A)),
            undefined
        end)}]).
