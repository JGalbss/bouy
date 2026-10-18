%% internalBinding('errors') (src/node_errors.cc): the exit codes, and the
%% hooks that Node's lib registers for stack traces and fatal exceptions.
%% Buoy keeps each hook in the realm, and triggerUncaughtException hands the
%% error to process._fatalException (buoy_node_loop).
-module(buoy_binding_errors).

-export([binding/0, hook/1]).

-spec binding() -> term().
binding() ->
    Hooks = [<<"setPrepareStackTraceCallback">>, <<"setGetSourceMapErrorSource">>, <<"setSourceMapsEnabled">>,
             <<"setMaybeCacheGeneratedSourceMap">>],
    ExitCodes = buoy_node:object([{<<"k", Name/binary>>, Code} || {Name, Code} <- exit_codes()]),
    buoy_node:object(
        [{H, buoy_node:fn(H, 1, fun(_, Args) -> erlang:put({?MODULE, H}, buoy_ref_realm:arg(1, Args)), undefined end)} || H <- Hooks]
        ++ [{<<"setEnhanceStackForFatalException">>, buoy_node:fn(<<"setEnhanceStackForFatalException">>, 2, fun(_, Args) ->
                erlang:put({?MODULE, enhance}, {buoy_ref_realm:arg(1, Args), buoy_ref_realm:arg(2, Args)}),
                undefined
            end)},
            {<<"noSideEffectsToString">>, buoy_node:fn(<<"noSideEffectsToString">>, 1, fun(_, Args) ->
                buoy_node:string(buoy_ref_console:inspect(buoy_ref_realm:arg(1, Args)))
            end)},
            {<<"triggerUncaughtException">>, buoy_node:fn(<<"triggerUncaughtException">>, 2, fun(_, Args) ->
                buoy_node_loop:uncaught(buoy_ref_realm:arg(1, Args), buoy_ref:truthy(buoy_ref_realm:arg(2, Args)))
            end)},
            {<<"getErrorSourcePositions">>, buoy_node:fn(<<"getErrorSourcePositions">>, 1, fun(_, _) ->
                buoy_node:object([{<<"sourceLine">>, <<>>}, {<<"scriptResourceName">>, <<>>}, {<<"lineNumber">>, 0}, {<<"startColumn">>, 0}])
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
