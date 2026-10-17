%% internalBinding('contextify') (src/node_contextify.cc). The vm module is
%% not implemented yet; the binding has the names that Node's lib reads at
%% load time, and the check of ES module syntax that the loaders use.
-module(bouy_binding_contextify).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    Constants = bouy_node:object([{<<"measureMemory">>, bouy_node:object([
        {<<"mode">>, bouy_node:object([{<<"SUMMARY">>, 0}, {<<"DETAILED">>, 1}])},
        {<<"execution">>, bouy_node:object([{<<"DEFAULT">>, 0}, {<<"EAGER">>, 1}])}])}]),
    F = fun bouy_node:fn/3,
    bouy_node:object([
        {<<"ContextifyScript">>, bouy_node:missing_constructor(<<"contextify">>, <<"ContextifyScript">>, 8)},
        {<<"constants">>, Constants},
        {<<"startSigintWatchdog">>, F(<<"startSigintWatchdog">>, 0, fun(_, _) -> undefined end)},
        {<<"stopSigintWatchdog">>, F(<<"stopSigintWatchdog">>, 0, fun(_, _) -> false end)},
        {<<"watchdogHasPendingSigint">>, F(<<"watchdogHasPendingSigint">>, 0, fun(_, _) -> false end)},
        {<<"containsModuleSyntax">>, F(<<"containsModuleSyntax">>, 2, fun(_, _) -> false end)}]
        ++ bouy_node:stubs(<<"contextify">>, [<<"makeContext">>, <<"compileFunction">>, <<"measureMemory">>,
                                              <<"compileFunctionForCJSLoader">>])).
