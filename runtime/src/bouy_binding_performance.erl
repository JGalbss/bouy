%% internalBinding('performance') (src/node_perf.cc): the clock and the
%% milestones of perf_hooks.
-module(bouy_binding_performance).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    F = fun bouy_node:fn/3,
    Milestones = bouy_node:typed_array(<<"Float64Array">>, 8),
    Origin = erlang:system_info(start_time),
    %% The time origin in nanoseconds of the monotonic clock, as hrtime counts.
    bouy_heap:set(Milestones, 1, 0),
    bouy_heap:set(Milestones, 0, erlang:system_time(microsecond) * 1.0 - (erlang:monotonic_time(microsecond) - erlang:convert_time_unit(Origin, native, microsecond))),
    Constants = [{<<"NODE_PERFORMANCE_GC_MAJOR">>, 4}, {<<"NODE_PERFORMANCE_GC_MINOR">>, 1},
                 {<<"NODE_PERFORMANCE_GC_INCREMENTAL">>, 8}, {<<"NODE_PERFORMANCE_GC_WEAKCB">>, 16},
                 {<<"NODE_PERFORMANCE_GC_FLAGS_NO">>, 0}, {<<"NODE_PERFORMANCE_GC_FLAGS_CONSTRUCT_RETAINED">>, 2},
                 {<<"NODE_PERFORMANCE_GC_FLAGS_FORCED">>, 4}, {<<"NODE_PERFORMANCE_GC_FLAGS_SYNCHRONOUS_PHANTOM_PROCESSING">>, 8},
                 {<<"NODE_PERFORMANCE_GC_FLAGS_ALL_AVAILABLE_GARBAGE">>, 16},
                 {<<"NODE_PERFORMANCE_GC_FLAGS_ALL_EXTERNAL_MEMORY">>, 32}, {<<"NODE_PERFORMANCE_GC_FLAGS_SCHEDULE_IDLE">>, 64}],
    Hidden = [{<<"NODE_PERFORMANCE_ENTRY_TYPE_GC">>, 0}, {<<"NODE_PERFORMANCE_ENTRY_TYPE_HTTP">>, 1},
              {<<"NODE_PERFORMANCE_ENTRY_TYPE_HTTP2">>, 2}, {<<"NODE_PERFORMANCE_ENTRY_TYPE_NET">>, 3},
              {<<"NODE_PERFORMANCE_ENTRY_TYPE_DNS">>, 4}, {<<"NODE_PERFORMANCE_MILESTONE_TIME_ORIGIN_TIMESTAMP">>, 0},
              {<<"NODE_PERFORMANCE_MILESTONE_TIME_ORIGIN">>, 1}, {<<"NODE_PERFORMANCE_MILESTONE_ENVIRONMENT">>, 2},
              {<<"NODE_PERFORMANCE_MILESTONE_NODE_START">>, 3}, {<<"NODE_PERFORMANCE_MILESTONE_V8_START">>, 4},
              {<<"NODE_PERFORMANCE_MILESTONE_LOOP_START">>, 5}, {<<"NODE_PERFORMANCE_MILESTONE_LOOP_EXIT">>, 6},
              {<<"NODE_PERFORMANCE_MILESTONE_BOOTSTRAP_COMPLETE">>, 7}],
    ConstantsObject = bouy_node:object(Constants),
    [bouy_heap:define(ConstantsObject, K, #{value => V, writable => false, enumerable => false, configurable => false}) || {K, V} <- Hidden],
    Noop = fun(Name, Length) -> {Name, F(Name, Length, fun(_, _) -> undefined end)} end,
    bouy_node:object([
        Noop(<<"setupObservers">>, 1), Noop(<<"installGarbageCollectionTracking">>, 0),
        Noop(<<"removeGarbageCollectionTracking">>, 0), Noop(<<"notify">>, 2),
        {<<"loopIdleTime">>, F(<<"loopIdleTime">>, 0, fun(_, _) -> 0 end)},
        {<<"markBootstrapComplete">>, F(<<"markBootstrapComplete">>, 0, fun(_, _) ->
            bouy_heap:set(Milestones, 7, now_ns()),
            undefined
        end)},
        {<<"uvMetricsInfo">>, F(<<"uvMetricsInfo">>, 0, fun(_, _) -> bouy_heap:new_array([0, 0, 0]) end)},
        {<<"now">>, F(<<"now">>, 0, fun(_, _) -> now_ns() / 1.0e6 end)},
        {<<"observerCounts">>, bouy_node:typed_array(<<"Uint32Array">>, 5)},
        {<<"milestones">>, Milestones},
        {<<"constants">>, ConstantsObject}]
        ++ bouy_node:stubs(<<"performance">>, [<<"createELDHistogram">>])
        ++ [{<<"Histogram">>, bouy_node:constructor(<<"Histogram">>, 0, fun(_, _) -> undefined end)}]).

%% Nanoseconds since the VM started, the time origin of performance.now().
now_ns() -> erlang:monotonic_time(nanosecond) - erlang:convert_time_unit(erlang:system_info(start_time), native, nanosecond).
