%% internalBinding('async_wrap') (src/async_wrap.cc): the fields of
%% async_hooks that lib/internal/async_hooks shares with the native side, the
%% native stack of async contexts, and the AsyncWrap of a native handle or
%% request: its async id, its init and destroy hooks, and MakeCallback,
%% which calls back into JavaScript between the before and after hooks of
%% the resource, with the async context frame of its creation.
-module(buoy_binding_async_wrap).

-export([binding/0, wrap/2, make_callback/3, emit_destroy/1, destroy_queued/0]).

%% {HookFields, IdFields, Binding}: the fields of AsyncHooks, and the binding,
%% whose async_ids_stack grows past its 16 entries.
-define(FIELDS, '$buoy_node_async_fields').
%% The resources of the contexts that the native side pushed, by offset.
-define(RESOURCES, '$buoy_node_async_resources').
%% The async ids that wait for their destroy hooks, newest first.
-define(DESTROY, '$buoy_node_async_destroy').
-define(WRAP, '$buoy_async_wrap').
-define(K_INIT, 0).
-define(K_BEFORE, 1).
-define(K_AFTER, 2).
-define(K_DESTROY, 3).
-define(K_CHECK, 6).
-define(K_STACK_LENGTH, 7).
-define(K_USES_EXECUTION_ASYNC_RESOURCE, 8).
-define(K_EXECUTION_ASYNC_ID, 0).
-define(K_TRIGGER_ASYNC_ID, 1).
-define(K_ASYNC_ID_COUNTER, 2).
-define(K_DEFAULT_TRIGGER_ASYNC_ID, 3).
%% TRACING_CATEGORY_NODE1(async_hooks).
-define(TRACE, <<"node,node.async_hooks">>).

-spec binding() -> term().
binding() ->
    HookFields = buoy_node:typed_array(<<"Uint32Array">>, 9),
    IdFields = buoy_node:typed_array(<<"Float64Array">>, 4),
    %% The main script runs as async id 1, triggered by 0; the counter starts
    %% at 1, and no default trigger id is set.
    [buoy_heap:set(IdFields, I, V) || {I, V} <- [{0, 1}, {1, 0}, {2, 1}, {3, -1}]],
    Resources = buoy_heap:new_array([]),
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    Number = fun(I, Args) -> buoy_ref:to_number(A(I, Args)) end,
    Binding = buoy_node:object([
        {<<"setupHooks">>, F(<<"setupHooks">>, 1, fun(_, Args) -> buoy_node_loop:set_callback(async_hooks, A(1, Args)), undefined end)},
        {<<"setCallbackTrampoline">>, F(<<"setCallbackTrampoline">>, 1, fun(_, Args) ->
            buoy_node_loop:set_callback(async_trampoline, callable(A(1, Args))),
            undefined
        end)},
        {<<"pushAsyncContext">>, F(<<"pushAsyncContext">>, 3, fun(_, Args) ->
            push(Number(1, Args), Number(2, Args), undefined),
            undefined
        end)},
        {<<"popAsyncContext">>, F(<<"popAsyncContext">>, 1, fun(_, Args) -> pop(Number(1, Args)) end)},
        {<<"executionAsyncResource">>, F(<<"executionAsyncResource">>, 1, fun(_, Args) ->
            maps:get(trunc(Number(1, Args)), resources(), undefined)
        end)},
        {<<"clearAsyncIdStack">>, F(<<"clearAsyncIdStack">>, 0, fun(_, _) -> clear(Resources) end)},
        {<<"queueDestroyAsyncId">>, F(<<"queueDestroyAsyncId">>, 1, fun(_, Args) -> emit_destroy(Number(1, Args)), undefined end)},
        {<<"setPromiseHooks">>, F(<<"setPromiseHooks">>, 4, fun(_, Args) ->
            buoy_jobs:set_promise_hooks(list_to_tuple([callable(A(I, Args)) || I <- [1, 2, 3, 4]])),
            undefined
        end)},
        {<<"getPromiseHooks">>, F(<<"getPromiseHooks">>, 0, fun(_, _) ->
            Hooks = case buoy_jobs:promise_hooks() of
                undefined -> [undefined, undefined, undefined, undefined];
                H -> tuple_to_list(H)
            end,
            buoy_heap:new_array(Hooks)
        end)},
        %% shortcut: no destroy hook follows the collection of a promise or an
        %% AsyncResource, which only --expose-gc tests observe; add it with a
        %% finalization registry when a program needs it.
        {<<"registerDestroyHook">>, F(<<"registerDestroyHook">>, 3, fun(_, _) -> undefined end)},
        {<<"async_hook_fields">>, HookFields},
        {<<"async_id_fields">>, IdFields},
        {<<"execution_async_resources">>, Resources},
        {<<"async_ids_stack">>, buoy_node:typed_array(<<"Float64Array">>, 32)},
        {<<"constants">>, buoy_node:object([
            {<<"kInit">>, 0}, {<<"kBefore">>, 1}, {<<"kAfter">>, 2}, {<<"kDestroy">>, 3}, {<<"kPromiseResolve">>, 4},
            {<<"kTotals">>, 5}, {<<"kCheck">>, 6}, {<<"kExecutionAsyncId">>, 0}, {<<"kTriggerAsyncId">>, 1},
            {<<"kAsyncIdCounter">>, 2}, {<<"kDefaultTriggerAsyncId">>, 3}, {<<"kUsesExecutionAsyncResource">>, 8},
            {<<"kStackLength">>, 7}])},
        {<<"Providers">>, buoy_node:object(
                                            [{P, I} || {I, P} <- lists:enumerate(0, providers())])}]),
    erlang:put(?FIELDS, {HookFields, IdFields, Binding}),
    Binding.

callable(F) ->
    case buoy_heap:is_callable(F) of
        true -> F;
        false -> undefined
    end.

%%% The stack of async contexts (AsyncHooks::push_async_context)

%% The ids of the context that ends go to async_ids_stack, which doubles when
%% it is full, as lib reads it from the binding each time.
push(AsyncId, TriggerId, Resource) ->
    {HookFields, IdFields, Binding} = erlang:get(?FIELDS),
    Offset = field(HookFields, ?K_STACK_LENGTH),
    Stack = grown(Binding, Offset),
    buoy_heap:set(Stack, 2 * Offset, field(IdFields, ?K_EXECUTION_ASYNC_ID)),
    buoy_heap:set(Stack, 2 * Offset + 1, field(IdFields, ?K_TRIGGER_ASYNC_ID)),
    buoy_heap:set(HookFields, ?K_STACK_LENGTH, Offset + 1),
    buoy_heap:set(IdFields, ?K_EXECUTION_ASYNC_ID, AsyncId),
    buoy_heap:set(IdFields, ?K_TRIGGER_ASYNC_ID, TriggerId),
    erlang:put(?RESOURCES, (resources())#{Offset => Resource}),
    ok.

grown(Binding, Offset) ->
    Stack = buoy_heap:get(Binding, <<"async_ids_stack">>),
    Length = buoy_heap:get(Stack, <<"length">>),
    case 2 * Offset >= Length of
        false ->
            Stack;
        true ->
            Grown = buoy_node:typed_array(<<"Float64Array">>, 2 * Length),
            [buoy_heap:set(Grown, I, buoy_heap:get(Stack, I)) || I <- lists:seq(0, Length - 1)],
            buoy_heap:set(Binding, <<"async_ids_stack">>, Grown),
            Grown
    end.

%% AsyncHooks::pop_async_context: whether the stack holds more contexts. A
%% stack that does not end in AsyncId while hooks check it is corrupted.
pop(AsyncId) ->
    {HookFields, IdFields, Binding} = erlang:get(?FIELDS),
    case field(HookFields, ?K_STACK_LENGTH) of
        0 ->
            false;
        Length ->
            field(HookFields, ?K_CHECK) > 0 andalso field(IdFields, ?K_EXECUTION_ASYNC_ID) =/= AsyncId
                andalso corrupted(field(IdFields, ?K_EXECUTION_ASYNC_ID), AsyncId),
            Offset = Length - 1,
            Stack = buoy_heap:get(Binding, <<"async_ids_stack">>),
            buoy_heap:set(IdFields, ?K_EXECUTION_ASYNC_ID, buoy_heap:get(Stack, 2 * Offset)),
            buoy_heap:set(IdFields, ?K_TRIGGER_ASYNC_ID, buoy_heap:get(Stack, 2 * Offset + 1)),
            buoy_heap:set(HookFields, ?K_STACK_LENGTH, Offset),
            erlang:put(?RESOURCES, maps:filter(fun(K, _) -> K < Offset end, resources())),
            Resources = buoy_heap:get(Binding, <<"execution_async_resources">>),
            buoy_heap:get(Resources, <<"length">>) > Offset andalso buoy_heap:set(Resources, <<"length">>, Offset),
            Offset > 0
    end.

%% FailWithCorruptedAsyncStack
-spec corrupted(number(), number()) -> no_return().
corrupted(Actual, Expected) ->
    Text = io_lib:format("Error: async hook stack has become corrupted (actual: ~s, expected: ~s)~n",
                         [buoy_ref_string:to_utf8(buoy_ref:to_string(Actual)), buoy_ref_string:to_utf8(buoy_ref:to_string(Expected))]),
    io:put_chars(buoy_ref:stderr(), Text),
    buoy_node_loop:really_exit(1).

clear(Resources) ->
    {HookFields, IdFields, _} = erlang:get(?FIELDS),
    buoy_heap:set(Resources, <<"length">>, 0),
    erlang:erase(?RESOURCES),
    buoy_heap:set(IdFields, ?K_EXECUTION_ASYNC_ID, 0),
    buoy_heap:set(IdFields, ?K_TRIGGER_ASYNC_ID, 0),
    buoy_heap:set(HookFields, ?K_STACK_LENGTH, 0),
    undefined.

resources() ->
    case erlang:get(?RESOURCES) of
        undefined -> #{};
        R -> R
    end.

field(Array, I) -> trunc(buoy_heap:get(Array, I)).

%%% AsyncWrap

%% AsyncWrap::AsyncReset: Resource, a handle or a request of a binding, gets
%% a new async id, the default trigger id, and the async context frame, and
%% the init hooks run. Provider is its type, such as <<"FSREQCALLBACK">>.
-spec wrap(term(), binary()) -> ok.
wrap(Resource, Provider) ->
    case erlang:get(?FIELDS) of
        undefined ->
            ok;
        {HookFields, IdFields, _} ->
            AsyncId = buoy_heap:get(IdFields, ?K_ASYNC_ID_COUNTER) + 1,
            buoy_heap:set(IdFields, ?K_ASYNC_ID_COUNTER, AsyncId),
            TriggerId = case buoy_heap:get(IdFields, ?K_DEFAULT_TRIGGER_ASYNC_ID) of
                Default when Default < 0 -> buoy_heap:get(IdFields, ?K_EXECUTION_ASYNC_ID);
                Default -> Default
            end,
            buoy_heap:private_put(Resource, ?WRAP, {AsyncId, TriggerId, buoy_jobs:context(), Provider}),
            %% EmitTraceEventInit
            buoy_trace:event($b, ?TRACE, Provider, trunc(AsyncId), [{<<"data">>, #{
                <<"executionAsyncId">> => trunc(buoy_heap:get(IdFields, ?K_EXECUTION_ASYNC_ID)),
                <<"triggerAsyncId">> => trunc(TriggerId)}}]),
            case field(HookFields, ?K_INIT) of
                0 -> ok;
                _ -> hook(<<"init">>, Resource, [AsyncId, Provider, TriggerId, Resource])
            end
    end.

%% InternalMakeCallback: Callback(...Args) with Resource as this, inside the
%% async context of Resource and between its before and after hooks, which
%% the trampoline of lib emits while hooks need it. An exception goes to the
%% uncaught exception handler, and the call returns undefined.
-spec make_callback(term(), term(), list()) -> term().
make_callback(Resource, Callback, Args) ->
    {AsyncId, TriggerId, Frame, Provider} = case buoy_heap:private_find(Resource, ?WRAP) of
        {ok, Wrap} -> Wrap;
        error -> {0, 0, buoy_jobs:context(), none}
    end,
    %% EmitTraceEventBefore and EmitTraceEventAfter
    Traced = Provider =/= none andalso buoy_trace:enabled(?TRACE),
    Traced andalso buoy_trace:event($b, ?TRACE, <<Provider/binary, "_CALLBACK">>, trunc(AsyncId), []),
    Prior = buoy_jobs:context(),
    buoy_jobs:set_context(Frame),
    push(AsyncId, TriggerId, Resource),
    {HookFields, _, _} = erlang:get(?FIELDS),
    Trampoline = buoy_node_loop:callback(async_trampoline),
    Hooks = AsyncId =/= 0 andalso Trampoline =:= undefined,
    Hooks andalso hook_of(HookFields, ?K_BEFORE, <<"before">>, AsyncId),
    Outcome = try
        case Trampoline =/= undefined andalso field(HookFields, ?K_BEFORE) + field(HookFields, ?K_AFTER)
                 + field(HookFields, ?K_USES_EXECUTION_ASYNC_RESOURCE) > 0 of
            true -> {ok, buoy_heap:call(Trampoline, Resource, [AsyncId, Resource, Callback | Args])};
            false -> {ok, buoy_heap:call(Callback, Resource, Args)}
        end
    catch
        error:Reason:Stack -> {error, buoy_ref:caught(Reason, Stack)}
    end,
    Result = case Outcome of
        {ok, Value} ->
            Hooks andalso hook_of(HookFields, ?K_AFTER, <<"after">>, AsyncId),
            Value;
        {error, Error} ->
            _ = buoy_node_loop:uncaught(Error, false),
            undefined
    end,
    pop(AsyncId),
    buoy_jobs:set_context(Prior),
    Traced andalso buoy_trace:event($e, ?TRACE, <<Provider/binary, "_CALLBACK">>, trunc(AsyncId), []),
    Result.

hook_of(HookFields, Field, Name, AsyncId) ->
    case field(HookFields, Field) of
        0 -> ok;
        _ -> hook(Name, undefined, [AsyncId])
    end.

%% A native hook of setupHooks. Its exceptions are fatal, as the TryCatch of
%% kFatal makes them; lib's hooks catch their own.
hook(Name, This, Args) ->
    _ = buoy_heap:call(buoy_heap:get(buoy_node_loop:callback(async_hooks), Name), This, Args),
    ok.

%%% Destroy hooks

%% AsyncWrap::EmitDestroy: the destroy hooks of the async id of a resource,
%% or of an async id, run in the next check phase of the loop, or before
%% 'beforeExit'.
-spec emit_destroy(term()) -> ok.
emit_destroy(AsyncId) when is_number(AsyncId) ->
    case erlang:get(?FIELDS) of
        {HookFields, _, _} ->
            case field(HookFields, ?K_DESTROY) of
                0 -> ok;
                _ -> erlang:put(?DESTROY, [AsyncId | queued()]), ok
            end;
        undefined ->
            ok
    end;
emit_destroy(Resource) ->
    case buoy_heap:private_find(Resource, ?WRAP) of
        {ok, {AsyncId, _, _, Provider}} ->
            %% EmitTraceEventDestroy
            buoy_trace:event($e, ?TRACE, Provider, trunc(AsyncId), []),
            emit_destroy(AsyncId);
        error ->
            ok
    end.

%% DestroyAsyncIdsCallback, as a native immediate: the destroy hooks of the
%% queued async ids, also of those that the hooks queue, as one job.
-spec destroy_queued() -> boolean().
destroy_queued() ->
    erlang:get(?DESTROY) =/= undefined andalso begin buoy_jobs:run_job(fun destroy/0), true end.

destroy() ->
    case erlang:erase(?DESTROY) of
        undefined ->
            ok;
        Ids ->
            [hook(<<"destroy">>, undefined, [Id]) || Id <- lists:reverse(Ids)],
            destroy()
    end.

queued() ->
    case erlang:get(?DESTROY) of
        undefined -> [];
        Ids -> Ids
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
