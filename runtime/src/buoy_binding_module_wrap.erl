%% internalBinding('module_wrap') (src/module_wrap.cc). Buoy's compiler links
%% the ES modules of a program, so the loader of Node's lib does not run.
%% The binding has the names that the bootstrap reads at load time: the
%% ModuleWrap class, which throws when constructed, its status constants, and
%% the setters of the host callbacks.
-module(buoy_binding_module_wrap).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    ModuleWrap = buoy_node:missing_constructor(<<"module_wrap">>, <<"ModuleWrap">>, 0),
    Setters = [<<"setImportModuleDynamicallyCallback">>, <<"setInitializeImportMetaObjectCallback">>,
               <<"setImportMetaResolveInitializer">>],
    Constants = lists:enumerate(0, [<<"kUninstantiated">>, <<"kInstantiating">>, <<"kInstantiated">>,
                                    <<"kEvaluating">>, <<"kEvaluationPhase">>, <<"kEvaluated">>, <<"kErrored">>]),
    buoy_node:object(
        [{<<"ModuleWrap">>, ModuleWrap}]
        ++ [{Name, Value} || {Value, Name} <- Constants]
        ++ [{<<"kSourcePhase">>, 1}, {<<"kEvaluationPhase">>, 2}]
        ++ [{S, buoy_node:fn(S, 1, fun(_, _) -> undefined end)} || S <- Setters]
        ++ [{<<"throwIfPromiseRejected">>, buoy_node:fn(<<"throwIfPromiseRejected">>, 1, fun(_, _) -> undefined end)},
            {<<"createRequiredModuleFacade">>, buoy_node:not_implemented(<<"module_wrap">>, <<"createRequiredModuleFacade">>)}]).
