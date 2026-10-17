%% internalBinding('messaging') (src/node_messaging.cc): structuredClone and
%% DOMException. MessagePort and MessageChannel are not implemented yet.
-module(bouy_binding_messaging).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    F = fun bouy_node:fn/3,
    A = fun bouy_node:arg/2,
    DOMException = bouy_heap:get(bouy_node:context(), <<"DOMException">>),
    bouy_node:object([
        {<<"MessageChannel">>, bouy_node:missing_constructor(<<"messaging">>, <<"MessageChannel">>, 0)},
        {<<"MessagePort">>, bouy_node:missing_constructor(<<"messaging">>, <<"MessagePort">>, 0)},
        {<<"exposeLazyDOMExceptionProperty">>, F(<<"exposeLazyDOMExceptionProperty">>, 1, fun(_, Args) ->
            bouy_heap:define(A(1, Args), <<"DOMException">>, #{value => DOMException, writable => true, enumerable => false, configurable => true}),
            undefined
        end)},
        {<<"stopMessagePort">>, F(<<"stopMessagePort">>, 1, fun(_, _) -> undefined end)},
        {<<"drainMessagePort">>, F(<<"drainMessagePort">>, 1, fun(_, _) -> undefined end)},
        {<<"receiveMessageOnPort">>, bouy_node:not_implemented(<<"messaging">>, <<"receiveMessageOnPort">>)},
        {<<"moveMessagePortToContext">>, bouy_node:not_implemented(<<"messaging">>, <<"moveMessagePortToContext">>)},
        {<<"setDeserializerCreateObjectFunction">>, F(<<"setDeserializerCreateObjectFunction">>, 1, fun(_, _) -> undefined end)},
        {<<"broadcastChannel">>, bouy_node:not_implemented(<<"messaging">>, <<"broadcastChannel">>)},
        {<<"structuredClone">>, F(<<"structuredClone">>, 2, fun(_, Args) -> structured_clone(A(1, Args), A(2, Args)) end)},
        {<<"DOMException">>, DOMException}]).

%% structuredClone(value, { transfer }): the clone, with each ArrayBuffer of
%% transfer detached afterwards, as a transfer moves its bytes to the clone.
structured_clone(Value, Options) ->
    Transfer = case bouy_heap:is_object(Options) andalso bouy_heap:get(Options, <<"transfer">>) of
        false -> [];
        undefined -> [];
        List -> bouy_heap:array_items(List)
    end,
    Buffers = [B || B <- Transfer, bouy_heap:is_object(B), bouy_heap:class_of(B) =:= array_buffer],
    [bouy_heap:throw_error('DataCloneError', <<"An ArrayBuffer is detached and could not be cloned.">>)
     || B <- Buffers, bouy_ref_buffer:is_detached(B)],
    Clone = bouy_heap:clone_in(bouy_heap:clone_out(Value)),
    [bouy_ref_buffer:detach(B) || B <- Buffers],
    Clone.
