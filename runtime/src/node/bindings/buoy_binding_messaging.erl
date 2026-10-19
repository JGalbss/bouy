%% internalBinding('messaging') (src/node_messaging.cc): structuredClone and
%% DOMException. MessagePort and MessageChannel are not implemented yet.
-module(buoy_binding_messaging).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    DOMException = buoy_heap:get(buoy_node:context(), <<"DOMException">>),
    buoy_node:object([
        {<<"MessageChannel">>, buoy_node:missing_constructor(<<"messaging">>, <<"MessageChannel">>, 0)},
        {<<"MessagePort">>, buoy_node:missing_constructor(<<"messaging">>, <<"MessagePort">>, 0)},
        {<<"exposeLazyDOMExceptionProperty">>, F(<<"exposeLazyDOMExceptionProperty">>, 1, fun(_, Args) ->
            buoy_heap:define(A(1, Args), <<"DOMException">>, #{value => DOMException, writable => true, enumerable => false, configurable => true}),
            undefined
        end)},
        {<<"stopMessagePort">>, F(<<"stopMessagePort">>, 1, fun(_, _) -> undefined end)},
        {<<"drainMessagePort">>, F(<<"drainMessagePort">>, 1, fun(_, _) -> undefined end)},
        {<<"receiveMessageOnPort">>, buoy_node:not_implemented(<<"messaging">>, <<"receiveMessageOnPort">>)},
        {<<"moveMessagePortToContext">>, buoy_node:not_implemented(<<"messaging">>, <<"moveMessagePortToContext">>)},
        {<<"setDeserializerCreateObjectFunction">>, F(<<"setDeserializerCreateObjectFunction">>, 1, fun(_, _) -> undefined end)},
        {<<"broadcastChannel">>, buoy_node:not_implemented(<<"messaging">>, <<"broadcastChannel">>)},
        {<<"structuredClone">>, F(<<"structuredClone">>, 2, fun(_, Args) -> structured_clone(A(1, Args), A(2, Args)) end)},
        {<<"DOMException">>, DOMException}]).

%% structuredClone(value, { transfer }): the clone, with each ArrayBuffer of
%% transfer detached afterwards, as a transfer moves its bytes to the clone.
structured_clone(Value, Options) ->
    Transfer = case buoy_heap:is_object(Options) andalso buoy_heap:get(Options, <<"transfer">>) of
        false -> [];
        undefined -> [];
        List -> buoy_heap:array_items(List)
    end,
    Buffers = [B || B <- Transfer, buoy_heap:is_object(B), buoy_heap:class_of(B) =:= array_buffer],
    [buoy_heap:throw_error('DataCloneError', <<"An ArrayBuffer is detached and could not be cloned.">>)
     || B <- Buffers, buoy_ref_buffer:is_detached(B)],
    Clone = buoy_heap:clone_in(buoy_heap:clone_out(Value)),
    [buoy_ref_buffer:detach(B) || B <- Buffers],
    Clone.
