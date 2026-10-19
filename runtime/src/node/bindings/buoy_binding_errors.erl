%% internalBinding('errors') (src/node_errors.cc): the exit codes, and the
%% hooks that Node's lib registers for stack traces and fatal exceptions.
%% Buoy keeps each hook in the realm, and triggerUncaughtException hands the
%% error to process._fatalException (buoy_node_loop).
-module(buoy_binding_errors).

-export([binding/0, hook/1]).

-include("buoy_ref.hrl").

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
                no_side_effects_to_string(buoy_ref_realm:arg(1, Args))
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

%% Object::NoSideEffectsToString of V8: a primitive as ToString gives it, a
%% symbol as its descriptive string, a function as its source, an error as
%% "name: message", an object whose toString is Object.prototype's as
%% #<Constructor>, and anything else as [object Tag], reading only data
%% properties so that no getter or proxy trap runs.
no_side_effects_to_string(V) when ?IS_STRING(V) -> V;
no_side_effects_to_string({'$sym', _, _} = S) -> buoy_ref:describe(S);
no_side_effects_to_string(V) ->
    case buoy_heap:is_object(V) of
        false -> buoy_ref:to_string(V);
        true -> receiver_to_string(V)
    end.

receiver_to_string(O) ->
    case {buoy_heap:class_of(O), buoy_heap:is_callable(O)} of
        %% A proxy shows its target; a revoked one has none.
        {proxy, _} ->
            case buoy_heap:slots(O) of
                {revoked, _} -> <<"[object Object]">>;
                {Target, _} -> receiver_to_string(Target)
            end;
        {_, true} -> function_to_string(O);
        {_, false} -> object_to_string(O)
    end.

%% The source of a function, cut to 111 characters, "...<omitted>...", and
%% the last 2 when it is longer than 128.
function_to_string(F) ->
    Source = buoy_ref_string:to_utf8(buoy_ref_function:method(<<"Function.prototype">>, <<"toString">>, F, [])),
    Chars = unicode:characters_to_list(Source),
    case length(Chars) > 128 of
        true -> buoy_ref_string:from_utf8(unicode:characters_to_binary(
                    [lists:sublist(Chars, 111), "...<omitted>...", lists:nthtail(length(Chars) - 2, Chars)]));
        false -> buoy_ref_string:from_utf8(Source)
    end.

object_to_string(O) ->
    ToString = data_property(O, <<"toString">>),
    ErrorToString = buoy_heap:get(buoy_heap:intrinsic('Error.prototype'), <<"toString">>),
    ObjectToString = buoy_heap:get(buoy_heap:intrinsic('Object.prototype'), <<"toString">>),
    Class = buoy_heap:class_of(O),
    if
        Class =:= error; ToString =:= ErrorToString -> error_to_string(O);
        ToString =:= ObjectToString -> constructor_to_string(O);
        true -> tag(O)
    end.

%% NoSideEffectsErrorToString.
error_to_string(O) ->
    Text = fun(K) -> case data_property(O, K) of S when ?IS_STRING(S) -> S; _ -> <<>> end end,
    case {Text(<<"name">>), Text(<<"message">>)} of
        {<<>>, Message} -> Message;
        {Name, <<>>} -> Name;
        {Name, Message} -> buoy_ref_string:concat([Name, <<": ">>, Message])
    end.

constructor_to_string(O) ->
    Constructor = data_property(O, <<"constructor">>),
    Name = case buoy_heap:is_object(Constructor) andalso buoy_heap:is_callable(Constructor) of
        true -> data_property(Constructor, <<"name">>);
        false -> undefined
    end,
    case Name of
        N when ?IS_STRING(N), N =/= <<>> -> buoy_ref_string:concat([<<"#<">>, N, <<">">>]);
        _ -> tag(O)
    end.

%% "[object " + @@toStringTag or the class name + "]".
tag(O) ->
    Builtin = case {buoy_heap:is_callable(O), buoy_ref_array:is_array(O)} of
        {true, _} -> <<"Function">>;
        {_, true} -> <<"Array">>;
        _ -> <<"Object">>
    end,
    Tag = case data_property(O, ?SYM(toStringTag)) of
        T when ?IS_STRING(T) -> T;
        _ -> Builtin
    end,
    buoy_ref_string:concat([<<"[object ">>, Tag, <<"]">>]).

%% JSReceiver::GetDataProperty: the value of the data property Key on O or
%% its prototypes, and undefined for an accessor or at a proxy.
data_property(O, Key) ->
    case buoy_heap:class_of(O) of
        proxy ->
            undefined;
        _ ->
            case buoy_heap:get_own(O, Key) of
                {data, V, _} -> V;
                {accessor, _, _, _} -> undefined;
                none ->
                    case buoy_heap:prototype_of(O) of
                        null -> undefined;
                        Proto -> data_property(Proto, Key)
                    end
            end
    end.
