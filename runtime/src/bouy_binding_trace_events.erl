%% internalBinding('trace_events') (src/node_trace_events.cc). Bouy records
%% no trace events: every category is off.
-module(bouy_binding_trace_events).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    F = fun bouy_node:fn/3,
    bouy_node:object([
        {<<"getEnabledCategories">>, F(<<"getEnabledCategories">>, 0, fun(_, _) -> undefined end)},
        {<<"setTraceCategoryStateUpdateHandler">>, F(<<"setTraceCategoryStateUpdateHandler">>, 1, fun(_, _) -> undefined end)},
        {<<"getCategoryEnabledBuffer">>, F(<<"getCategoryEnabledBuffer">>, 1, fun(_, _) -> bouy_node:typed_array(<<"Uint8Array">>, 1) end)},
        {<<"isTraceCategoryEnabled">>, F(<<"isTraceCategoryEnabled">>, 1, fun(_, _) -> false end)},
        {<<"trace">>, F(<<"trace">>, 5, fun(_, _) -> undefined end)},
        {<<"CategorySet">>, bouy_node:constructor(<<"CategorySet">>, 1, fun(_, _) -> undefined end)}]).
