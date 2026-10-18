%% internalBinding('async_context_frame') (src/async_context_frame.cc): the
%% continuation-preserved embedder data of V8, which AsyncLocalStorage keeps
%% its frame in. buoy_jobs carries it into each promise job and microtask.
-module(buoy_binding_async_context_frame).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    buoy_node:object([
        {<<"getContinuationPreservedEmbedderData">>, F(<<"getContinuationPreservedEmbedderData">>, 0, fun(_, _) ->
            buoy_jobs:context()
        end)},
        {<<"setContinuationPreservedEmbedderData">>, F(<<"setContinuationPreservedEmbedderData">>, 1, fun(_, A) ->
            buoy_jobs:set_context(buoy_node:arg(1, A)),
            undefined
        end)}]).
