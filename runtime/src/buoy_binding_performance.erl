%% internalBinding('performance') (src/node_perf.cc and src/histogram.cc):
%% the clock and the milestones of perf_hooks, the metrics of the loop, and
%% the histograms of createHistogram and monitorEventLoopDelay.
-module(buoy_binding_performance).

-export([binding/0, mark/1]).

-define(MILESTONES, '$buoy_node_milestones').
-define(HISTOGRAM, '$buoy_histogram').
-define(INT64_MAX, 9223372036854775807).
%% The indices of the milestones array.
-define(TIME_ORIGIN_TIMESTAMP, 0).
-define(TIME_ORIGIN, 1).
-define(ENVIRONMENT, 2).
-define(NODE_START, 3).
-define(V8_START, 4).
-define(LOOP_START, 5).
-define(LOOP_EXIT, 6).
-define(BOOTSTRAP_COMPLETE, 7).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    Milestones = buoy_node:typed_array(<<"Float64Array">>, 8),
    %% The time origin is the start of the VM: 0 on the clock of hrtime, and
    %% the wall clock time then in microseconds. A milestone that has not
    %% happened is -1.
    Origin = erlang:system_time(microsecond) * 1.0 - now_ns() / 1000,
    Starts = [{?TIME_ORIGIN_TIMESTAMP, Origin}, {?TIME_ORIGIN, 0},
              {?NODE_START, persistent_term:get({buoy, node_start}, origin_ns()) - origin_ns()},
              {?V8_START, boot_ns()}, {?ENVIRONMENT, now_ns()}],
    [buoy_heap:set(Milestones, I, -1) || I <- lists:seq(0, 7)],
    [buoy_heap:set(Milestones, I, V) || {I, V} <- Starts ++ marked()],
    [trace_milestone(I, V) || {I, V} <- Starts ++ marked(), I >= ?ENVIRONMENT],
    erlang:put(?MILESTONES, Milestones),
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
        Noop(<<"setupObservers">>, 1), Noop(<<"installGarbageCollectionTracking">>, 0),
        Noop(<<"removeGarbageCollectionTracking">>, 0), Noop(<<"notify">>, 2),
        {<<"loopIdleTime">>, F(<<"loopIdleTime">>, 0, fun(_, _) -> number(buoy_node_loop:idle_time() / 1.0e6) end)},
        {<<"markBootstrapComplete">>, F(<<"markBootstrapComplete">>, 0, fun(_, _) -> mark(?BOOTSTRAP_COMPLETE), undefined end)},
        {<<"uvMetricsInfo">>, F(<<"uvMetricsInfo">>, 0, fun(_, _) ->
            {Loops, Events, Waiting} = buoy_node_loop:metrics(),
            buoy_heap:new_array([Loops, Events, Waiting])
        end)},
        {<<"now">>, F(<<"now">>, 0, fun(_, _) -> number(now_ns() / 1.0e6) end)},
        {<<"observerCounts">>, buoy_node:typed_array(<<"Uint32Array">>, 5)},
        {<<"milestones">>, Milestones},
        {<<"constants">>, ConstantsObject},
        {<<"Histogram">>, histogram_class()},
        {<<"createELDHistogram">>, F(<<"createELDHistogram">>, 1, fun(_, Args) ->
            eld_histogram(trunc(buoy_ref:to_number(buoy_node:arg(1, Args))))
        end)}]).

%% PerformanceState::Mark: the milestone Index happens now. The loop marks
%% its start and exit also before Node's bootstrap, so the binding takes
%% those when it is built.
-spec mark(non_neg_integer() | loop_start | loop_exit) -> ok.
mark(loop_start) -> mark_once(?LOOP_START);
mark(loop_exit) -> mark_once(?LOOP_EXIT);
mark(Index) ->
    Now = now_ns(),
    case erlang:get(?MILESTONES) of
        undefined -> erlang:put({?MODULE, Index}, Now);
        Milestones -> buoy_heap:set(Milestones, Index, Now), trace_milestone(Index, Now)
    end,
    ok.

%% The trace event of a mark, an instant at the time of the milestone.
trace_milestone(Index, Ns) ->
    Names = {<<"environment">>, <<"nodeStart">>, <<"v8Start">>, <<"loopStart">>, <<"loopExit">>, <<"bootstrapComplete">>},
    buoy_trace:instant(<<"node,node.bootstrap">>, element(Index - ?ENVIRONMENT + 1, Names),
                       round(Ns) div 1000).

mark_once(Index) ->
    Marked = case erlang:get(?MILESTONES) of
        undefined -> erlang:get({?MODULE, Index}) =/= undefined;
        Milestones -> buoy_heap:get(Milestones, Index) =/= -1
    end,
    Marked orelse mark(Index),
    ok.

marked() ->
    [{I, Ns} || I <- [?LOOP_START, ?LOOP_EXIT], Ns <- [erlang:get({?MODULE, I})], Ns =/= undefined].

boot_ns() ->
    case erlang:get('$buoy_node_boot_ns') of
        undefined -> now_ns();
        Ns -> Ns - origin_ns()
    end.

%% Nanoseconds since the VM started, the clock of hrtime and performance.now().
now_ns() -> erlang:monotonic_time(nanosecond) - origin_ns().

origin_ns() -> erlang:convert_time_unit(erlang:system_info(start_time), native, nanosecond).

%%% Histograms

%% new Histogram(lowest, highest, figures): a RecordableHistogram's handle.
histogram_class() ->
    Class = buoy_node:constructor(<<"Histogram">>, 3, fun(This, Args) ->
        [Lowest, Highest] = [int64(buoy_node:arg(I, Args)) || I <- [1, 2]],
        Figures = trunc(buoy_ref:to_number(buoy_node:arg(3, Args))),
        put_histogram(This, buoy_node_histogram:new(Lowest, Highest, Figures)),
        undefined
    end),
    install(buoy_heap:get(Class, <<"prototype">>), methods() ++ recordable()),
    Class.

%% createELDHistogram(interval): the histogram of the delays of a timer that
%% fires every interval ms while it is started, unref'd, as IntervalHistogram.
eld_histogram(Interval) ->
    Handle = buoy_node:object([]),
    put_histogram(Handle, buoy_node_histogram:new(1000, ?INT64_MAX, 3)),
    install(Handle, methods() ++ [
        {<<"start">>, 1, fun(This, _) -> start(This, Interval) end},
        {<<"stop">>, 0, fun(This, _) -> stop(This) end}]),
    Handle.

start(Handle, Interval) ->
    case erlang:get({?MODULE, interval, Handle}) of
        undefined ->
            Ref = make_ref(),
            %% The handle stays a root of the heap while its timer runs.
            erlang:put({?MODULE, interval, Handle}, Ref),
            tick(Handle, Ref, Interval);
        _ ->
            ok
    end,
    undefined.

stop(Handle) ->
    erlang:erase({?MODULE, interval, Handle}),
    undefined.

tick(Handle, Ref, Interval) ->
    _ = erlang:send_after(Interval, self(), {'$buoy_node_call', fun() ->
        case erlang:get({?MODULE, interval, Handle}) of
            Ref ->
                update(Handle, fun buoy_node_histogram:record_delta/1),
                tick(Handle, Ref, Interval);
            _ ->
                ok
        end
    end}),
    ok.

install(Object, Methods) ->
    [buoy_heap:define(Object, Name, #{value => buoy_node:fn(Name, Length, Fun), writable => true,
                                      enumerable => false, configurable => true})
     || {Name, Length, Fun} <- Methods],
    ok.

%% The methods of HistogramBase, in Number and BigInt forms.
methods() ->
    Read = fun(Name, Get) ->
        [{Name, 0, fun(This, _) -> number(Get(histogram(This))) end},
         {<<Name/binary, "BigInt">>, 0, fun(This, _) -> {'$bigint', Get(histogram(This))} end}]
    end,
    lists:append([Read(<<"count">>, fun buoy_node_histogram:count/1), Read(<<"min">>, fun buoy_node_histogram:min/1),
                  Read(<<"max">>, fun buoy_node_histogram:max/1), Read(<<"exceeds">>, fun buoy_node_histogram:exceeds/1)])
    ++ [{<<"mean">>, 0, fun(This, _) -> number(buoy_node_histogram:mean(histogram(This))) end},
        {<<"stddev">>, 0, fun(This, _) -> number(buoy_node_histogram:stddev(histogram(This))) end},
        {<<"percentile">>, 1, fun(This, Args) -> number(percentile(This, Args)) end},
        {<<"percentileBigInt">>, 1, fun(This, Args) -> {'$bigint', percentile(This, Args)} end},
        {<<"percentiles">>, 1, fun(This, Args) -> percentiles(This, buoy_node:arg(1, Args), fun number/1) end},
        {<<"percentilesBigInt">>, 1, fun(This, Args) -> percentiles(This, buoy_node:arg(1, Args), fun(V) -> {'$bigint', V} end) end},
        {<<"reset">>, 0, fun(This, _) -> update(This, fun buoy_node_histogram:reset/1) end}].

recordable() ->
    [{<<"record">>, 1, fun(This, Args) ->
        Value = int64(buoy_node:arg(1, Args)),
        Value < 1 andalso buoy_node:throw_code('RangeError', <<"ERR_OUT_OF_RANGE">>, <<"value is out of range">>),
        update(This, fun(H) -> buoy_node_histogram:record(H, Value) end)
     end},
     {<<"recordDelta">>, 0, fun(This, _) -> update(This, fun buoy_node_histogram:record_delta/1) end},
     {<<"add">>, 1, fun(This, Args) ->
        Other = histogram(buoy_node:arg(1, Args)),
        update(This, fun(H) -> buoy_node_histogram:add(H, Other) end)
     end}].

percentile(This, Args) ->
    buoy_node_histogram:percentile(histogram(This), float(buoy_ref:to_number(buoy_node:arg(1, Args)))).

percentiles(This, Map, Value) ->
    Set = buoy_heap:get(Map, <<"set">>),
    [buoy_heap:call(Set, Map, [number(Key), Value(V)]) || {Key, V} <- buoy_node_histogram:percentiles(histogram(This))],
    undefined.

histogram(Handle) ->
    case buoy_heap:is_object(Handle) andalso buoy_heap:private_find(Handle, ?HISTOGRAM) of
        {ok, H} -> H;
        _ -> buoy_node:throw_code('TypeError', <<"ERR_INVALID_THIS">>, <<"Value of \"this\" must be of type Histogram">>)
    end.

put_histogram(Handle, H) -> buoy_heap:private_put(Handle, ?HISTOGRAM, H).

update(Handle, Fun) ->
    put_histogram(Handle, Fun(histogram(Handle))),
    undefined.

%% A Number or a BigInt as int64_t, as the C++ side reads it.
int64({'$bigint', N}) when N >= -?INT64_MAX - 1, N =< ?INT64_MAX -> N;
int64({'$bigint', _}) -> buoy_node:throw_code('RangeError', <<"ERR_OUT_OF_RANGE">>, <<"value is out of range">>);
int64(V) ->
    case buoy_ref:to_number(V) of
        N when is_integer(N) -> N;
        N when is_float(N) -> trunc(N);
        _ -> 0
    end.

%% A double, as the C++ side returns it, in the canonical form of the engine.
number(N) -> buoy_ref_number:canonical(N).
