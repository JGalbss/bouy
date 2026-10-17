%% internalBinding('async_context_frame') (src/async_context_frame.cc): the
%% continuation-preserved embedder data of V8, which AsyncLocalStorage keeps
%% its frame in.
%% shortcut: the value is one slot of the realm and does not follow promise
%% jobs; carry it through bouy_jobs reactions when async context needs it.
-module(bouy_binding_async_context_frame).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    F = fun bouy_node:fn/3,
    bouy_node:object([
        {<<"getContinuationPreservedEmbedderData">>, F(<<"getContinuationPreservedEmbedderData">>, 0, fun(_, _) ->
            case erlang:get('$bouy_node_cped') of undefined -> undefined; V -> V end
        end)},
        {<<"setContinuationPreservedEmbedderData">>, F(<<"setContinuationPreservedEmbedderData">>, 1, fun(_, A) ->
            erlang:put('$bouy_node_cped', bouy_node:arg(1, A)),
            undefined
        end)}]).
