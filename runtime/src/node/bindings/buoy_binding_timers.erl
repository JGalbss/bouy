%% internalBinding('timers') (src/timers.cc): the one native timer of
%% lib/internal/timers and the counts of immediates, which buoy_node_loop
%% serves.
-module(buoy_binding_timers).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    ImmediateInfo = buoy_node:typed_array(<<"Uint32Array">>, 3),
    buoy_node_loop:set_callback(immediate_info, ImmediateInfo),
    F = fun buoy_node:fn/3,
    buoy_node:object([
        {<<"setupTimers">>, F(<<"setupTimers">>, 2, fun(_, A) ->
            buoy_node_loop:set_callback(process_immediate, buoy_node:arg(1, A)),
            buoy_node_loop:set_callback(process_timers, buoy_node:arg(2, A)),
            undefined
        end)},
        {<<"getLibuvNow">>, F(<<"getLibuvNow">>, 0, fun(_, _) -> buoy_node_loop:now() end)},
        {<<"scheduleTimer">>, F(<<"scheduleTimer">>, 1, fun(_, A) -> buoy_node_loop:schedule_timer(buoy_node:arg(1, A)) end)},
        {<<"toggleTimerRef">>, F(<<"toggleTimerRef">>, 1, fun(_, A) -> buoy_node_loop:toggle_timer_ref(buoy_ref:truthy(buoy_node:arg(1, A))) end)},
        {<<"toggleImmediateRef">>, F(<<"toggleImmediateRef">>, 1, fun(_, A) ->
            buoy_node_loop:toggle_immediate_ref(buoy_ref:truthy(buoy_node:arg(1, A)))
        end)},
        {<<"immediateInfo">>, ImmediateInfo},
        {<<"timeoutInfo">>, buoy_node:typed_array(<<"Int32Array">>, 1)}]).
