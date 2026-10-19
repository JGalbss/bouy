%% internalBinding('worker') (src/node_worker.cc): the program runs on the
%% main thread. Worker threads are not implemented yet.
-module(buoy_binding_worker).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    Worker = buoy_node:missing_constructor(<<"worker">>, <<"Worker">>, 0),
    buoy_node:object([
        {<<"Worker">>, Worker},
        {<<"getEnvMessagePort">>, buoy_node:fn(<<"getEnvMessagePort">>, 0, fun(_, _) -> undefined end)},
        {<<"threadId">>, 0}, {<<"threadName">>, <<"main">>}, {<<"isMainThread">>, true},
        {<<"isInternalThread">>, false}, {<<"ownsProcessState">>, true},
        {<<"kMaxYoungGenerationSizeMb">>, 0}, {<<"kMaxOldGenerationSizeMb">>, 1}, {<<"kCodeRangeSizeMb">>, 2},
        {<<"kStackSizeMb">>, 3}, {<<"kTotalResourceLimitCount">>, 4},
        {<<"resourceLimits">>, buoy_node:typed_array(<<"Float64Array">>, 4)}]).
