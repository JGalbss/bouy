%% internalBinding('module_wrap') (src/module_wrap.cc). Bouy's compiler links
%% the ES modules of a program, so the loader of Node's lib does not run.
%% The binding has the names that the bootstrap reads at load time: the
%% ModuleWrap class, which throws when constructed, its status constants, and
%% the setters of the host callbacks.
-module(bouy_binding_module_wrap).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    ModuleWrap = bouy_node:missing_constructor(<<"module_wrap">>, <<"ModuleWrap">>, 0),
    Setters = [<<"setImportModuleDynamicallyCallback">>, <<"setInitializeImportMetaObjectCallback">>,
               <<"setImportMetaResolveInitializer">>],
    Constants = lists:enumerate(0, [<<"kUninstantiated">>, <<"kInstantiating">>, <<"kInstantiated">>,
                                    <<"kEvaluating">>, <<"kEvaluationPhase">>, <<"kEvaluated">>, <<"kErrored">>]),
    bouy_node:object(
        [{<<"ModuleWrap">>, ModuleWrap}]
        ++ [{Name, Value} || {Value, Name} <- Constants]
        ++ [{<<"kSourcePhase">>, 1}, {<<"kEvaluationPhase">>, 2}]
        ++ [{S, bouy_node:fn(S, 1, fun(_, _) -> undefined end)} || S <- Setters]
        ++ [{<<"throwIfPromiseRejected">>, bouy_node:fn(<<"throwIfPromiseRejected">>, 1, fun(_, _) -> undefined end)},
            {<<"createRequiredModuleFacade">>, bouy_node:not_implemented(<<"module_wrap">>, <<"createRequiredModuleFacade">>)}]).
