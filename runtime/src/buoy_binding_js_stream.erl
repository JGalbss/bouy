%% internalBinding('js_stream') (src/js_stream.cc): JSStream, a StreamBase
%% whose I/O is JavaScript. lib/internal/js_stream_socket wraps any Duplex
%% in one, so that http2, tls, and http's agent can treat it as a socket
%% handle: a write calls onwrite(req, buffers) and finishes with
%% finishWrite(req, status); readBuffer(chunk) and emitEOF() feed onread.
-module(buoy_binding_js_stream).

-export([binding/0]).

-define(STATE, {'#', ?MODULE, <<"stream">>}).

-spec binding() -> term().
binding() ->
    Class = buoy_node:constructor(<<"JSStream">>, 0, fun(This, _) ->
        buoy_heap:private_put(This, ?STATE, #{async_id => async_id()}),
        undefined
    end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    A = fun buoy_node:arg/2,
    buoy_stream_base:methods(Proto, #{
        write => fun(This, Req, Chunks) ->
            Buffers = buoy_heap:new_array([buoy_node_encoding:new_buffer(iolist_to_binary([C])) || C <- Chunks]),
            to_int(callback(This, <<"onwrite">>, [Req, Buffers]))
        end,
        shutdown => fun(This, Req) -> to_int(callback(This, <<"onshutdown">>, [Req])) end,
        read_start => fun(This) -> to_int(callback(This, <<"onreadstart">>, [])) end,
        read_stop => fun(This) -> to_int(callback(This, <<"onreadstop">>, [])) end}),
    Methods = [{<<"finishWrite">>, fun(This, Args) -> buoy_stream_base:done(A(1, Args), status(A(2, Args)), This) end},
               {<<"finishShutdown">>, fun(This, Args) -> buoy_stream_base:done(A(1, Args), status(A(2, Args)), This) end},
               {<<"readBuffer">>, fun(This, Args) ->
                   case buoy_node_encoding:view_bytes(A(1, Args)) of
                       <<>> -> undefined;
                       Bytes -> buoy_stream_base:emit_read(This, Bytes)
                   end,
                   undefined
               end},
               {<<"emitEOF">>, fun(This, _) -> buoy_stream_base:emit_read(This, eof), undefined end},
               {<<"getAsyncId">>, fun(This, _) ->
                   case buoy_heap:private_find(This, ?STATE) of
                       {ok, #{async_id := Id}} -> Id;
                       _ -> -1
                   end
               end},
               {<<"getProviderType">>, fun(_, _) ->
                   buoy_heap:get(buoy_heap:get(buoy_node:binding(<<"async_wrap">>), <<"Providers">>), <<"JSSTREAM">>)
               end},
               {<<"asyncReset">>, fun(_, _) -> undefined end}],
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    buoy_node:object([{<<"JSStream">>, Class}]).

%% MakeCallback(this[Name], ...): the JavaScript side's answer.
callback(This, Name, Args) ->
    F = buoy_heap:get(This, Name),
    case buoy_heap:is_callable(F) of
        true -> buoy_heap:call(F, This, Args);
        false -> -71
    end.

%% Int32Value of the answer, or UV_EPROTO when there is none.
to_int(V) when is_integer(V) -> V;
to_int(V) when is_float(V) -> trunc(V);
to_int(_) -> -71.

status(V) when is_integer(V) -> V;
status(V) when is_float(V) -> trunc(V);
status(_) -> 0.

async_id() ->
    Fields = buoy_heap:get(buoy_node:binding(<<"async_wrap">>), <<"async_id_fields">>),
    Id = buoy_heap:get(Fields, 2) + 1,
    buoy_heap:set(Fields, 2, Id),
    Id.
