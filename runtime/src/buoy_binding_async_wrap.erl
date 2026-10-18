%% internalBinding('async_wrap') (src/async_wrap.cc): the fields of
%% async_hooks that lib/internal/async_hooks shares with the native side, and
%% the native stack of async contexts past the 16 that the JavaScript side
%% keeps.
-module(buoy_binding_async_wrap).

-export([binding/0, emit_init/2]).

-define(STACK, '$buoy_node_async_stack').
-define(K_EXECUTION_ASYNC_ID, 0).
-define(K_TRIGGER_ASYNC_ID, 1).
-define(K_STACK_LENGTH, 7).

-spec binding() -> term().
binding() ->
    HookFields = buoy_node:typed_array(<<"Uint32Array">>, 9),
    IdFields = buoy_node:typed_array(<<"Float64Array">>, 4),
    %% The main script runs as async id 1, triggered by 0; the counter starts
    %% at 1, and no default trigger id is set.
    [buoy_heap:set(IdFields, I, V) || {I, V} <- [{0, 1}, {1, 0}, {2, 1}, {3, -1}]],
    IdsStack = buoy_node:typed_array(<<"Float64Array">>, 32),
    Resources = buoy_heap:new_array([]),
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    Noop = fun(Name, Length) -> {Name, F(Name, Length, fun(_, _) -> undefined end)} end,
    buoy_node:object([
        {<<"setupHooks">>, F(<<"setupHooks">>, 1, fun(_, Args) -> buoy_node_loop:set_callback(async_hooks, A(1, Args)), undefined end)},
        Noop(<<"setCallbackTrampoline">>, 1),
        {<<"pushAsyncContext">>, F(<<"pushAsyncContext">>, 3, fun(_, Args) ->
            push(HookFields, IdFields, A(1, Args), A(2, Args))
        end)},
        {<<"popAsyncContext">>, F(<<"popAsyncContext">>, 1, fun(_, _) -> pop(HookFields, IdFields) end)},
        {<<"executionAsyncResource">>, F(<<"executionAsyncResource">>, 1, fun(_, Args) -> buoy_heap:get(Resources, trunc(buoy_ref:to_number(A(1, Args)))) end)},
        {<<"clearAsyncIdStack">>, F(<<"clearAsyncIdStack">>, 0, fun(_, _) ->
            erlang:erase(?STACK),
            buoy_heap:set(HookFields, ?K_STACK_LENGTH, 0),
            buoy_heap:set(IdFields, ?K_EXECUTION_ASYNC_ID, 0),
            buoy_heap:set(IdFields, ?K_TRIGGER_ASYNC_ID, 0),
            undefined
        end)},
        Noop(<<"queueDestroyAsyncId">>, 1),
        Noop(<<"setPromiseHooks">>, 4),
        {<<"getPromiseHooks">>, F(<<"getPromiseHooks">>, 0, fun(_, _) -> buoy_heap:new_array([undefined, undefined, undefined, undefined]) end)},
        Noop(<<"registerDestroyHook">>, 3),
        {<<"async_hook_fields">>, HookFields},
        {<<"async_id_fields">>, IdFields},
        {<<"execution_async_resources">>, Resources},
        {<<"async_ids_stack">>, IdsStack},
        {<<"constants">>, buoy_node:object([
            {<<"kInit">>, 0}, {<<"kBefore">>, 1}, {<<"kAfter">>, 2}, {<<"kDestroy">>, 3}, {<<"kPromiseResolve">>, 4},
            {<<"kTotals">>, 5}, {<<"kCheck">>, 6}, {<<"kExecutionAsyncId">>, 0}, {<<"kTriggerAsyncId">>, 1},
            {<<"kAsyncIdCounter">>, 2}, {<<"kDefaultTriggerAsyncId">>, 3}, {<<"kUsesExecutionAsyncResource">>, 8},
            {<<"kStackLength">>, 7}])},
        {<<"Providers">>, buoy_node:object(
                                            [{P, I} || {I, P} <- lists:enumerate(0, providers())])}]).

%% AsyncWrap::AsyncReset for a native resource of the provider Type, such as
%% <<"MESSAGEPORT">>: a new async id, triggered by the default trigger id or
%% the current execution, and the init hooks when one is enabled
%% (EmitAsyncInit).
-spec emit_init(term(), binary()) -> number().
emit_init(Resource, Type) ->
    Binding = buoy_node:binding(<<"async_wrap">>),
    Ids = buoy_heap:get(Binding, <<"async_id_fields">>),
    Hooks = buoy_heap:get(Binding, <<"async_hook_fields">>),
    Id = buoy_heap:get(Ids, 2) + 1,
    buoy_heap:set(Ids, 2, Id),
    Trigger = case buoy_heap:get(Ids, 3) of
        D when D >= 0 -> D;
        _ -> buoy_heap:get(Ids, ?K_EXECUTION_ASYNC_ID)
    end,
    case buoy_heap:get(Hooks, 0) > 0 andalso buoy_node_loop:callback(async_hooks) of
        false -> ok;
        undefined -> ok;
        Native -> buoy_heap:call(buoy_heap:get(Native, <<"init">>), undefined, [Id, Type, Trigger, Resource])
    end,
    Id.

push(HookFields, IdFields, AsyncId, TriggerId) ->
    Old = {buoy_heap:get(IdFields, ?K_EXECUTION_ASYNC_ID), buoy_heap:get(IdFields, ?K_TRIGGER_ASYNC_ID)},
    erlang:put(?STACK, [Old | stack()]),
    buoy_heap:set(HookFields, ?K_STACK_LENGTH, buoy_heap:get(HookFields, ?K_STACK_LENGTH) + 1),
    buoy_heap:set(IdFields, ?K_EXECUTION_ASYNC_ID, AsyncId),
    buoy_heap:set(IdFields, ?K_TRIGGER_ASYNC_ID, TriggerId),
    undefined.

pop(HookFields, IdFields) ->
    case stack() of
        [] ->
            false;
        [{Execution, Trigger} | Rest] ->
            erlang:put(?STACK, Rest),
            Length = max(0, buoy_heap:get(HookFields, ?K_STACK_LENGTH) - 1),
            buoy_heap:set(HookFields, ?K_STACK_LENGTH, Length),
            buoy_heap:set(IdFields, ?K_EXECUTION_ASYNC_ID, Execution),
            buoy_heap:set(IdFields, ?K_TRIGGER_ASYNC_ID, Trigger),
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
