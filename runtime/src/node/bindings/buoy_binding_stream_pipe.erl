%% internalBinding('stream_pipe') (src/stream_pipe.cc): StreamPipe moves the
%% reads of a source StreamBase into writes of a sink StreamBase, as http2's
%% respondWithFD pipes a FileHandle into an Http2Stream.
%%
%% Bun's http2.ts pipes the file through fs.createReadStream instead; Buoy
%% runs Node's lib/internal/http2/core.js, which needs this binding. The
%% pipe drives both handles through their StreamBase methods, so any
%% handle of Buoy can be either end. No handle of Buoy signals
%% OnStreamWantsWrite, so the pipe reads again when a write completes, as
%% Node does for a sink without HasWantsWrite.
-module(buoy_binding_stream_pipe).

-export([binding/0]).

-define(STATE, {'#', ?MODULE, <<"pipe">>}).
-define(K_ASYNC, 3).

-spec binding() -> term().
binding() ->
    Class = buoy_node:constructor(<<"StreamPipe">>, 2, fun(This, Args) ->
        new(This, buoy_node:arg(1, Args), buoy_node:arg(2, Args))
    end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    Methods = [{<<"unpipe">>, fun(This, _) -> unpipe(This), undefined end},
               {<<"start">>, fun(This, _) -> update(This, fun(S) -> S#{closed => false} end), wants_write(This), undefined end},
               {<<"isClosed">>, fun(This, _) -> maps:get(closed, state(This)) end},
               {<<"pendingWrites">>, fun(This, _) -> maps:get(pending, state(This)) end}],
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, fun(This, Args) ->
                                         case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, ?STATE) of
                                             {ok, _} -> Fun(This, Args);
                                             _ -> buoy_heap:throw_error('TypeError', <<"Illegal invocation">>)
                                         end
                                     end), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    buoy_node:object([{<<"StreamPipe">>, Class}]).

%% The constructor links the pipe and its handles both ways, as the
%% source, sink, pipeTarget, and pipeSource properties.
new(This, Source, Sink) ->
    buoy_binding_async_wrap:wrap(This, <<"STREAMPIPE">>),
    Prev = buoy_stream_base:push_listener(Source, fun(Bytes) -> write(This, Bytes) end, fun(_) -> read_end(This) end),
    buoy_heap:private_put(This, ?STATE, #{source => Source, sink => Sink, prev => Prev, reading => false,
                                          closed => true, eof => false, pending => 0}),
    buoy_heap:set(This, <<"source">>, Source),
    buoy_heap:set(Source, <<"pipeTarget">>, This),
    buoy_heap:set(This, <<"sink">>, Sink),
    buoy_heap:set(Sink, <<"pipeSource">>, This),
    undefined.

%% WritableListener::OnStreamWantsWrite: the source reads again.
wants_write(This) ->
    case state(This) of
        #{reading := false, closed := false, source := Source} ->
            update(This, fun(S) -> S#{reading => true} end),
            call(Source, <<"readStart">>, []);
        _ ->
            ok
    end.

%% StreamPipe::ProcessData: the bytes go to the sink, and an async write
%% stops the source until it completes.
write(This, Bytes) ->
    #{sink := Sink, source := Source} = state(This),
    Req = buoy_node:object([{<<"oncomplete">>, buoy_node:fn(<<"oncomplete">>, 1, fun(_, Args) ->
        after_write(This, status(buoy_node:arg(1, Args)))
    end)}]),
    Status = call(Sink, <<"writeBuffer">>, [Req, buoy_node_encoding:new_buffer(Bytes)]),
    update(This, fun(S) -> S#{pending => maps:get(pending, S) + 1} end),
    StreamState = buoy_heap:get(buoy_node:binding(<<"stream_wrap">>), <<"streamBaseState">>),
    case buoy_heap:get(StreamState, ?K_ASYNC) == 1 andalso status(Status) == 0 of
        true ->
            update(This, fun(S) -> S#{reading => false} end),
            call(Source, <<"readStop">>, []);
        false ->
            after_write(This, status(Status))
    end.

%% ReadableListener::OnStreamRead of EOF or an error, after the previous
%% listener had it: the sink ends once no write is pending.
read_end(This) ->
    #{source := Source} = update(This, fun(S) -> S#{eof => true} end),
    call(Source, <<"readStop">>, []),
    case state(This) of
        #{pending := 0, sink := Sink} ->
            shutdown(Sink),
            unpipe(This);
        _ ->
            ok
    end.

%% WritableListener::OnStreamAfterWrite.
after_write(This, Status) ->
    case update(This, fun(S) -> S#{pending => maps:get(pending, S) - 1} end) of
        #{closed := true, pending := 0} ->
            Oncomplete = buoy_heap:get(This, <<"oncomplete">>),
            buoy_heap:is_callable(Oncomplete) andalso buoy_binding_async_wrap:make_callback(This, Oncomplete, []),
            ok;
        #{closed := true} ->
            ok;
        #{eof := true, sink := Sink} ->
            shutdown(Sink),
            unpipe(This);
        _ when Status =/= 0 ->
            unpipe(This);
        _ ->
            wants_write(This)
    end.

%% StreamPipe::Unpipe: the source stops and gets its listener back, and on
%% the next check phase onunpipe runs and the links become null.
unpipe(This) ->
    case update(This, fun(S) -> S#{reading => false} end) of
        #{closed := true} ->
            ok;
        #{source := Source, prev := Prev, sink := Sink} ->
            update(This, fun(S) -> S#{closed => true} end),
            call(Source, <<"readStop">>, []),
            buoy_heap:set(Source, <<"onread">>, Prev),
            buoy_node_loop:set_immediate(fun() ->
                Onunpipe = buoy_heap:get(This, <<"onunpipe">>),
                buoy_heap:is_callable(Onunpipe) andalso buoy_binding_async_wrap:make_callback(This, Onunpipe, []),
                buoy_heap:set(This, <<"source">>, null),
                buoy_heap:set(This, <<"sink">>, null),
                buoy_heap:set(Source, <<"pipeTarget">>, null),
                buoy_heap:set(Sink, <<"pipeSource">>, null)
            end)
    end.

%% StreamBase::Shutdown with no request of JavaScript.
shutdown(Sink) ->
    call(Sink, <<"shutdown">>, [buoy_node:object([{<<"oncomplete">>, buoy_node:fn(<<"oncomplete">>, 1, fun(_, _) -> undefined end)}])]).

call(Handle, Method, Args) ->
    buoy_heap:call(buoy_heap:get(Handle, Method), Handle, Args).

status(N) when is_number(N) -> trunc(N);
status(_) -> 0.

state(This) ->
    {ok, S} = buoy_heap:private_find(This, ?STATE),
    S.

update(This, Fun) ->
    S = Fun(state(This)),
    buoy_heap:private_put(This, ?STATE, S),
    S.
