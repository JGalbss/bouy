%% internalBinding('report') (src/node_report_module.cc): the settings of
%% process.report, kept in the realm. Bouy writes no diagnostic report yet.
-module(bouy_binding_report).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    Settings = [{<<"Compact">>, false}, {<<"ExcludeNetwork">>, false}, {<<"ExcludeEnv">>, false},
                {<<"Directory">>, <<>>}, {<<"Filename">>, <<>>}, {<<"Signal">>, <<"SIGUSR2">>}],
    Flags = [{<<"ReportOnFatalError">>, false}, {<<"ReportOnSignal">>, false}, {<<"ReportOnUncaughtException">>, false}],
    bouy_node:object(
        lists:append([accessors(<<"get">>, <<"set">>, Name, Default) || {Name, Default} <- Settings])
        ++ lists:append([accessors(<<"should">>, <<"set">>, Name, Default) || {Name, Default} <- Flags])
        ++ bouy_node:stubs(<<"report">>, [<<"writeReport">>, <<"getReport">>])).

%% The getter and the setter of one setting, such as getCompact and setCompact.
accessors(Get, Set, Name, Default) ->
    Key = {?MODULE, Name},
    [{<<Get/binary, Name/binary>>, bouy_node:fn(<<Get/binary, Name/binary>>, 0, fun(_, _) ->
         case erlang:get(Key) of
             undefined -> Default;
             Value -> Value
         end
     end)},
     {<<Set/binary, Name/binary>>, bouy_node:fn(<<Set/binary, Name/binary>>, 1, fun(_, A) ->
         erlang:put(Key, bouy_node:arg(1, A)),
         undefined
     end)}].
