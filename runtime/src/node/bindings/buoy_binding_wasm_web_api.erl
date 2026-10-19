%% internalBinding('wasm_web_api') (src/node_wasm_web_api.cc): the callback
%% that WebAssembly.compileStreaming and instantiateStreaming hand a source
%% and a stream state, which lib/internal/wasm_web_api.js fills from a
%% Response of fetch (buoy_ref_wasm:streaming/2).
-module(buoy_binding_wasm_web_api).

-export([binding/0, implementation/0]).

-define(KEY, '$buoy_wasm_streaming').

-spec binding() -> term().
binding() ->
    buoy_node:object([
        {<<"setImplementation">>, buoy_node:fn(<<"setImplementation">>, 1, fun(_, A) ->
            erlang:put(?KEY, buoy_node:arg(1, A)),
            undefined
        end)}]).

%% The callback of the realm. The bootstrap of Node sets it, so a program
%% that never used Node runs the bootstrap first.
-spec implementation() -> term().
implementation() ->
    case erlang:get(?KEY) of
        undefined ->
            buoy_node:ensure(),
            case erlang:get(?KEY) of
                undefined -> buoy_heap:throw_error('TypeError', <<"WebAssembly streaming is not available">>);
                F -> F
            end;
        F ->
            F
    end.
