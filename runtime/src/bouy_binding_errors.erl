%% internalBinding('errors') (src/node_errors.cc): the exit codes, and the
%% hooks that Node's lib registers for stack traces and fatal exceptions.
%% Bouy keeps each hook in the realm, and triggerUncaughtException hands the
%% error to process._fatalException (bouy_node_loop).
-module(bouy_binding_errors).

-export([binding/0, hook/1]).

-spec binding() -> term().
binding() ->
    Hooks = [<<"setPrepareStackTraceCallback">>, <<"setGetSourceMapErrorSource">>, <<"setSourceMapsEnabled">>,
             <<"setMaybeCacheGeneratedSourceMap">>],
    ExitCodes = bouy_node:object([{<<"k", Name/binary>>, Code} || {Name, Code} <- exit_codes()]),
    bouy_node:object(
        [{H, bouy_node:fn(H, 1, fun(_, Args) -> erlang:put({?MODULE, H}, bouy_ref_realm:arg(1, Args)), undefined end)} || H <- Hooks]
        ++ [{<<"setEnhanceStackForFatalException">>, bouy_node:fn(<<"setEnhanceStackForFatalException">>, 2, fun(_, Args) ->
                erlang:put({?MODULE, enhance}, {bouy_ref_realm:arg(1, Args), bouy_ref_realm:arg(2, Args)}),
                undefined
            end)},
            {<<"noSideEffectsToString">>, bouy_node:fn(<<"noSideEffectsToString">>, 1, fun(_, Args) ->
                bouy_node:string(bouy_ref_console:inspect(bouy_ref_realm:arg(1, Args)))
            end)},
            {<<"triggerUncaughtException">>, bouy_node:fn(<<"triggerUncaughtException">>, 2, fun(_, Args) ->
                bouy_node_loop:uncaught(bouy_ref_realm:arg(1, Args), bouy_ref:truthy(bouy_ref_realm:arg(2, Args)))
            end)},
            {<<"getErrorSourcePositions">>, bouy_node:fn(<<"getErrorSourcePositions">>, 1, fun(_, _) ->
                bouy_node:object([{<<"sourceLine">>, <<>>}, {<<"scriptResourceName">>, <<>>}, {<<"lineNumber">>, 0}, {<<"startColumn">>, 0}])
            end)},
            {<<"exitCodes">>, ExitCodes}]).

%% The hook that the code registered with the setter Name, or undefined.
-spec hook(binary()) -> term().
hook(Name) ->
    case erlang:get({?MODULE, Name}) of
        undefined -> undefined;
        F -> F
    end.

exit_codes() ->
    [{<<"NoFailure">>, 0}, {<<"GenericUserError">>, 1}, {<<"InternalJSParseError">>, 3},
     {<<"InternalJSEvaluationFailure">>, 4}, {<<"V8FatalError">>, 5}, {<<"InvalidFatalExceptionMonkeyPatching">>, 6},
     {<<"ExceptionInFatalExceptionHandler">>, 7}, {<<"InvalidCommandLineArgument">>, 9}, {<<"BootstrapFailure">>, 10},
     {<<"InvalidCommandLineArgument2">>, 12}, {<<"UnsettledTopLevelAwait">>, 13}, {<<"StartupSnapshotFailure">>, 14},
     {<<"Abort">>, 134}].
