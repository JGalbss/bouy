%% internalBinding('symbols') (src/node_symbols.cc): the per-isolate symbols,
%% keyed by their descriptions.
-module(buoy_binding_symbols).

-export([binding/0]).

-spec binding() -> term().
binding() -> buoy_node:object(buoy_node:per_isolate_symbols()).
