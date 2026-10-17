%% internalBinding('timers') (src/timers.cc): the one native timer of
%% lib/internal/timers and the counts of immediates, which bouy_node_loop
%% serves.
-module(bouy_binding_timers).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    ImmediateInfo = bouy_node:typed_array(<<"Uint32Array">>, 3),
    bouy_node_loop:set_callback(immediate_info, ImmediateInfo),
    F = fun bouy_node:fn/3,
    bouy_node:object([
        {<<"setupTimers">>, F(<<"setupTimers">>, 2, fun(_, A) ->
            bouy_node_loop:set_callback(process_immediate, bouy_node:arg(1, A)),
            bouy_node_loop:set_callback(process_timers, bouy_node:arg(2, A)),
            undefined
        end)},
        {<<"getLibuvNow">>, F(<<"getLibuvNow">>, 0, fun(_, _) -> bouy_node_loop:now() end)},
        {<<"scheduleTimer">>, F(<<"scheduleTimer">>, 1, fun(_, A) -> bouy_node_loop:schedule_timer(bouy_node:arg(1, A)) end)},
        {<<"toggleTimerRef">>, F(<<"toggleTimerRef">>, 1, fun(_, A) -> bouy_node_loop:toggle_timer_ref(bouy_ref:truthy(bouy_node:arg(1, A))) end)},
        {<<"toggleImmediateRef">>, F(<<"toggleImmediateRef">>, 1, fun(_, A) ->
            bouy_node_loop:toggle_immediate_ref(bouy_ref:truthy(bouy_node:arg(1, A)))
        end)},
        {<<"immediateInfo">>, ImmediateInfo},
        {<<"timeoutInfo">>, bouy_node:typed_array(<<"Int32Array">>, 1)}]).
