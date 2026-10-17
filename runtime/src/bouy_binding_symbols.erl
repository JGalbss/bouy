%% internalBinding('symbols') (src/node_symbols.cc): the per-isolate symbols,
%% keyed by their descriptions.
-module(bouy_binding_symbols).

-export([binding/0]).

-spec binding() -> term().
binding() -> bouy_node:object(bouy_node:per_isolate_symbols()).
