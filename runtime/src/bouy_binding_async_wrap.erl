%% internalBinding('async_wrap') (src/async_wrap.cc): the fields of
%% async_hooks that lib/internal/async_hooks shares with the native side, and
%% the native stack of async contexts past the 16 that the JavaScript side
%% keeps.
-module(bouy_binding_async_wrap).

-export([binding/0]).

-define(STACK, '$bouy_node_async_stack').
-define(K_EXECUTION_ASYNC_ID, 0).
-define(K_TRIGGER_ASYNC_ID, 1).
-define(K_STACK_LENGTH, 7).

-spec binding() -> term().
binding() ->
    HookFields = bouy_node:typed_array(<<"Uint32Array">>, 9),
    IdFields = bouy_node:typed_array(<<"Float64Array">>, 4),
    %% The main script runs as async id 1, triggered by 0; the counter starts
    %% at 1, and no default trigger id is set.
    [bouy_heap:set(IdFields, I, V) || {I, V} <- [{0, 1}, {1, 0}, {2, 1}, {3, -1}]],
    IdsStack = bouy_node:typed_array(<<"Float64Array">>, 32),
    Resources = bouy_heap:new_array([]),
    F = fun bouy_node:fn/3,
    A = fun bouy_node:arg/2,
    Noop = fun(Name, Length) -> {Name, F(Name, Length, fun(_, _) -> undefined end)} end,
    bouy_node:object([
        {<<"setupHooks">>, F(<<"setupHooks">>, 1, fun(_, Args) -> bouy_node_loop:set_callback(async_hooks, A(1, Args)), undefined end)},
        Noop(<<"setCallbackTrampoline">>, 1),
        {<<"pushAsyncContext">>, F(<<"pushAsyncContext">>, 3, fun(_, Args) ->
            push(HookFields, IdFields, A(1, Args), A(2, Args))
        end)},
        {<<"popAsyncContext">>, F(<<"popAsyncContext">>, 1, fun(_, _) -> pop(HookFields, IdFields) end)},
        {<<"executionAsyncResource">>, F(<<"executionAsyncResource">>, 1, fun(_, Args) -> bouy_heap:get(Resources, trunc(bouy_ref:to_number(A(1, Args)))) end)},
        {<<"clearAsyncIdStack">>, F(<<"clearAsyncIdStack">>, 0, fun(_, _) ->
            erlang:erase(?STACK),
            bouy_heap:set(HookFields, ?K_STACK_LENGTH, 0),
            bouy_heap:set(IdFields, ?K_EXECUTION_ASYNC_ID, 0),
            bouy_heap:set(IdFields, ?K_TRIGGER_ASYNC_ID, 0),
            undefined
        end)},
        Noop(<<"queueDestroyAsyncId">>, 1),
        Noop(<<"setPromiseHooks">>, 4),
        {<<"getPromiseHooks">>, F(<<"getPromiseHooks">>, 0, fun(_, _) -> bouy_heap:new_array([undefined, undefined, undefined, undefined]) end)},
        Noop(<<"registerDestroyHook">>, 3),
        {<<"async_hook_fields">>, HookFields},
        {<<"async_id_fields">>, IdFields},
        {<<"execution_async_resources">>, Resources},
        {<<"async_ids_stack">>, IdsStack},
        {<<"constants">>, bouy_node:object([
            {<<"kInit">>, 0}, {<<"kBefore">>, 1}, {<<"kAfter">>, 2}, {<<"kDestroy">>, 3}, {<<"kPromiseResolve">>, 4},
            {<<"kTotals">>, 5}, {<<"kCheck">>, 6}, {<<"kExecutionAsyncId">>, 0}, {<<"kTriggerAsyncId">>, 1},
            {<<"kAsyncIdCounter">>, 2}, {<<"kDefaultTriggerAsyncId">>, 3}, {<<"kUsesExecutionAsyncResource">>, 8},
            {<<"kStackLength">>, 7}])},
        {<<"Providers">>, bouy_node:object(
                                            [{P, I} || {I, P} <- lists:enumerate(0, providers())])}]).

push(HookFields, IdFields, AsyncId, TriggerId) ->
    Old = {bouy_heap:get(IdFields, ?K_EXECUTION_ASYNC_ID), bouy_heap:get(IdFields, ?K_TRIGGER_ASYNC_ID)},
    erlang:put(?STACK, [Old | stack()]),
    bouy_heap:set(HookFields, ?K_STACK_LENGTH, bouy_heap:get(HookFields, ?K_STACK_LENGTH) + 1),
    bouy_heap:set(IdFields, ?K_EXECUTION_ASYNC_ID, AsyncId),
    bouy_heap:set(IdFields, ?K_TRIGGER_ASYNC_ID, TriggerId),
    undefined.

pop(HookFields, IdFields) ->
    case stack() of
        [] ->
            false;
        [{Execution, Trigger} | Rest] ->
            erlang:put(?STACK, Rest),
            Length = max(0, bouy_heap:get(HookFields, ?K_STACK_LENGTH) - 1),
            bouy_heap:set(HookFields, ?K_STACK_LENGTH, Length),
            bouy_heap:set(IdFields, ?K_EXECUTION_ASYNC_ID, Execution),
            bouy_heap:set(IdFields, ?K_TRIGGER_ASYNC_ID, Trigger),
            Length > 0
    end.

stack() ->
    case erlang:get(?STACK) of
        undefined -> [];
        S -> S
    end.

providers() ->
    [<<"NONE">>, <<"DIRHANDLE">>, <<"DNSCHANNEL">>, <<"ELDHISTOGRAM">>, <<"FILEHANDLE">>, <<"FILEHANDLECLOSEREQ">>,
     <<"BLOBREADER">>, <<"FSEVENTWRAP">>, <<"FSREQCALLBACK">>, <<"FSREQPROMISE">>, <<"GETADDRINFOREQWRAP">>,
     <<"GETNAMEINFOREQWRAP">>, <<"HEAPSNAPSHOT">>, <<"HTTP2SESSION">>, <<"HTTP2STREAM">>, <<"HTTP2PING">>,
     <<"HTTP2SETTINGS">>, <<"HTTPINCOMINGMESSAGE">>, <<"HTTPCLIENTREQUEST">>, <<"LOCKS">>, <<"JSSTREAM">>,
     <<"JSUDPWRAP">>, <<"MESSAGEPORT">>, <<"PIPECONNECTWRAP">>, <<"PIPESERVERWRAP">>, <<"PIPEWRAP">>,
     <<"PROCESSWRAP">>, <<"PROMISE">>, <<"QUERYWRAP">>, <<"QUIC_ENDPOINT">>, <<"QUIC_LOGSTREAM">>,
     <<"QUIC_PACKET">>, <<"QUIC_SESSION">>, <<"QUIC_STREAM">>, <<"QUIC_UDP">>, <<"SHUTDOWNWRAP">>,
     <<"SIGNALWRAP">>, <<"STATWATCHER">>, <<"STREAMPIPE">>, <<"TCPCONNECTWRAP">>, <<"TCPSERVERWRAP">>,
     <<"TCPWRAP">>, <<"TTYWRAP">>, <<"UDPSENDWRAP">>, <<"UDPWRAP">>, <<"SIGINTWATCHDOG">>, <<"WORKER">>,
     <<"WORKERCPUPROFILE">>, <<"WORKERCPUUSAGE">>, <<"WORKERHEAPPROFILE">>, <<"WORKERHEAPSNAPSHOT">>,
     <<"WORKERHEAPSTATISTICS">>, <<"WRITEWRAP">>, <<"ZLIB">>, <<"CHECKPRIMEREQUEST">>, <<"PBKDF2REQUEST">>,
     <<"KEYPAIRGENREQUEST">>, <<"KEYGENREQUEST">>, <<"KEYEXPORTREQUEST">>, <<"ARGON2REQUEST">>,
     <<"CIPHERREQUEST">>, <<"DERIVEBITSREQUEST">>, <<"HASHREQUEST">>, <<"RANDOMBYTESREQUEST">>,
     <<"RANDOMPRIMEREQUEST">>, <<"SCRYPTREQUEST">>, <<"SIGNREQUEST">>, <<"TLSWRAP">>, <<"VERIFYREQUEST">>].
