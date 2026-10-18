%% internalBinding('performance') (src/node_perf.cc): the clock and the
%% milestones of perf_hooks.
-module(buoy_binding_performance).

-export([binding/0, now_ns/0, has_observer/1, notify/5]).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    Milestones = buoy_node:typed_array(<<"Float64Array">>, 8),
    Origin = erlang:system_info(start_time),
    %% The time origin in nanoseconds of the monotonic clock, as hrtime counts.
    buoy_heap:set(Milestones, 1, 0),
    buoy_heap:set(Milestones, 0, erlang:system_time(microsecond) * 1.0 - (erlang:monotonic_time(microsecond) - erlang:convert_time_unit(Origin, native, microsecond))),
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
    ConstantsObject = buoy_node:object(Constants),
    [buoy_heap:define(ConstantsObject, K, #{value => V, writable => false, enumerable => false, configurable => false}) || {K, V} <- Hidden],
    Noop = fun(Name, Length) -> {Name, F(Name, Length, fun(_, _) -> undefined end)} end,
    buoy_node:object([
        {<<"setupObservers">>, F(<<"setupObservers">>, 1, fun(_, Args) ->
            buoy_node_loop:set_callback(performance_entry, buoy_node:arg(1, Args)),
            undefined
        end)},
        Noop(<<"installGarbageCollectionTracking">>, 0),
        Noop(<<"removeGarbageCollectionTracking">>, 0), Noop(<<"notify">>, 2),
        {<<"loopIdleTime">>, F(<<"loopIdleTime">>, 0, fun(_, _) -> 0 end)},
        {<<"markBootstrapComplete">>, F(<<"markBootstrapComplete">>, 0, fun(_, _) ->
            buoy_heap:set(Milestones, 7, now_ns()),
            undefined
        end)},
        {<<"uvMetricsInfo">>, F(<<"uvMetricsInfo">>, 0, fun(_, _) -> buoy_heap:new_array([0, 0, 0]) end)},
        {<<"now">>, F(<<"now">>, 0, fun(_, _) -> now_ns() / 1.0e6 end)},
        {<<"observerCounts">>, buoy_node:typed_array(<<"Uint32Array">>, 5)},
        {<<"milestones">>, Milestones},
        {<<"constants">>, ConstantsObject}]
        ++ buoy_node:stubs(<<"performance">>, [<<"createELDHistogram">>])
        ++ [{<<"Histogram">>, buoy_node:constructor(<<"Histogram">>, 0, fun(_, _) -> undefined end)}]).

%% PerformanceEntry::Notify: an entry of a native producer, such as an
%% Http2Session, to the callback of setupObservers while an observer of
%% its type, an index of observerCounts, exists. Start is in nanoseconds of
%% now_ns/0 and Duration in milliseconds.
-spec notify(non_neg_integer(), binary(), number(), number(), term()) -> ok.
notify(Type, Name, Start, Duration, Details) ->
    case has_observer(Type) of
        true ->
            Callback = buoy_node_loop:callback(performance_entry),
            TypeName = lists:nth(Type + 1, [<<"gc">>, <<"http">>, <<"http2">>, <<"net">>, <<"dns">>]),
            _ = buoy_heap:call(Callback, undefined, [Name, TypeName, Start / 1.0e6, Duration, Details]),
            ok;
        false ->
            ok
    end.

%% Whether an observer of the type, an index of observerCounts, exists.
-spec has_observer(non_neg_integer()) -> boolean().
has_observer(Type) ->
    Counts = buoy_heap:get(buoy_node:binding(<<"performance">>), <<"observerCounts">>),
    buoy_node_loop:callback(performance_entry) =/= undefined andalso buoy_heap:get(Counts, Type) > 0.

%% Nanoseconds since the VM started, the time origin of performance.now().
-spec now_ns() -> integer().
now_ns() -> erlang:monotonic_time(nanosecond) - erlang:convert_time_unit(erlang:system_info(start_time), native, nanosecond).
