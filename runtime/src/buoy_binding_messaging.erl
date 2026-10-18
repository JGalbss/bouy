%% internalBinding('messaging') (src/node_messaging.cc): MessagePort,
%% MessageChannel, the ports of BroadcastChannel, and structuredClone.
%%
%% A port is one side of a pipe, an Erlang process that holds an inbox for
%% each side, as Bun's MessagePortPipe does (src/jsc/bindings/webcore/
%% MessagePortPipe.h) and Node's SiblingGroup: a MessageChannel is a pipe of
%% two sides, and a BroadcastChannel is the pipe of every port with its name.
%% A send appends the message to the inbox of each other side and wakes the
%% realm that owns the side once per burst. That realm takes the inbox and
%% emits one message per macrotask, so its microtasks and ticks run between
%% messages, as MessagePort::OnMessage runs each in a callback scope. A port
%% that moves in a transfer list detaches from its realm and attaches to the
%% realm that receives it, and the inbox waits in the pipe meanwhile, so no
%% message is lost or reordered. A pipe monitors the realm of each side, so a
%% worker that ends closes its ports.
%%
%% A message is {message, Payload, Ports}: the clone of the value
%% (buoy_heap:clone_out/2), with a host tag for each port and JS transferable
%% in it, and the ports that it transfers, each as {Pipe, Side, Queue}.
-module(buoy_binding_messaging).

-export([binding/0, ready/2, poll/0, new_port/3, pipe/0, is_message_port/1, port_side/1, transfer_out/1, close_carried/1]).
-export([pipe_init/1, construct_invalid/2]).

-define(STATE, {'#', ?MODULE, <<"port">>}).
-define(PORTS(Pipe, Side), {?MODULE, port, Pipe, Side}).
-define(CREATE, {?MODULE, create_object}).
-define(PROTO, {?MODULE, port_prototype}).
-define(PENDING, {?MODULE, pending}).
-define(POLL, {?MODULE, poll}).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    DOMException = buoy_heap:get(buoy_node:context(), <<"DOMException">>),
    Port = buoy_node:constructor(<<"MessagePort">>, 0, fun ?MODULE:construct_invalid/2),
    Proto = buoy_heap:get(Port, <<"prototype">>),
    [buoy_heap:define(Proto, Name, #{value => F(Name, Length, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Length, Fun} <- [{<<"postMessage">>, 0, fun post_message/2},
                                {<<"start">>, 0, fun(This, _) -> start(This) end},
                                {<<"close">>, 0, fun(This, _) -> close(This), undefined end},
                                {<<"ref">>, 0, fun(This, _) -> set_ref(This, true) end},
                                {<<"unref">>, 0, fun(This, _) -> set_ref(This, false) end},
                                {<<"hasRef">>, 0, fun(This, _) -> has_ref(This) end}]],
    erlang:put(?PROTO, Proto),
    Channel = buoy_node:constructor(<<"MessageChannel">>, 0, fun new_channel/2),
    buoy_node:object([
        {<<"MessageChannel">>, Channel},
        {<<"MessagePort">>, Port},
        {<<"exposeLazyDOMExceptionProperty">>, F(<<"exposeLazyDOMExceptionProperty">>, 1, fun(_, Args) ->
            buoy_heap:define(A(1, Args), <<"DOMException">>, #{value => DOMException, writable => true, enumerable => false, configurable => true}),
            undefined
        end)},
        {<<"stopMessagePort">>, F(<<"stopMessagePort">>, 1, fun(_, Args) -> stop(A(1, Args)) end)},
        {<<"drainMessagePort">>, F(<<"drainMessagePort">>, 1, fun(_, Args) -> drain(A(1, Args)) end)},
        {<<"receiveMessageOnPort">>, F(<<"receiveMessageOnPort">>, 1, fun(_, Args) -> receive_message(A(1, Args)) end)},
        {<<"moveMessagePortToContext">>, F(<<"moveMessagePortToContext">>, 0, fun(_, Args) -> move_to_context(A(1, Args)) end)},
        {<<"setDeserializerCreateObjectFunction">>, F(<<"setDeserializerCreateObjectFunction">>, 1, fun(_, Args) ->
            erlang:put(?CREATE, A(1, Args)),
            undefined
        end)},
        {<<"broadcastChannel">>, F(<<"broadcastChannel">>, 1, fun(_, Args) -> broadcast_channel(A(1, Args)) end)},
        {<<"structuredClone">>, F(<<"structuredClone">>, 2, fun(_, Args) -> structured_clone(A(1, Args), A(2, Args)) end)},
        {<<"DOMException">>, DOMException}]).

%% new MessagePort(): ports come only from MessageChannel and transfers.
-spec construct_invalid(term(), list()) -> no_return().
construct_invalid(_, _) ->
    buoy_node:throw_code('TypeError', <<"ERR_CONSTRUCT_CALL_INVALID">>, <<"Constructor cannot be called">>).

%%% Ports in the realm

%% new MessageChannel(): this.port1 and this.port2, the two sides of a new pipe.
new_channel(This, _Args) ->
    buoy_heap:is_object(This) orelse
        buoy_node:throw_code('TypeError', <<"ERR_CONSTRUCT_CALL_REQUIRED">>,
                             <<"Class constructor MessageChannel cannot be invoked without 'new'">>),
    Pipe = pipe(),
    buoy_heap:set(This, <<"port1">>, new_port(Pipe, 1, [])),
    buoy_heap:set(This, <<"port2">>, new_port(Pipe, 2, [])),
    undefined.

%% A new pipe of two sides, which no realm owns yet.
-spec pipe() -> pid().
pipe() ->
    spawn(?MODULE, pipe_init, [channel]).

%% The port of this realm on the side Side of Pipe, with the messages Queue
%% that it carried from another realm. Like MessagePort::New, it calls the
%% oninit of the prototype, which unrefs it.
-spec new_port(pid(), term(), [term()]) -> term().
new_port(Pipe, Side, Queue) ->
    Port = buoy_node:object(erlang:get(?PROTO), []),
    buoy_heap:private_put(Port, ?STATE, #{pipe => Pipe, side => Side, queue => Queue, started => false,
                                          refed => false, state => open, seq => erlang:unique_integer([monotonic])}),
    %% The init hook sees the port before its handle refs and before oninit, as in HandleWrap.
    AsyncId = buoy_binding_async_wrap:emit_init(Port, <<"MESSAGEPORT">>),
    update(Port, fun(S) -> S#{async_id => AsyncId} end),
    erlang:put(?PORTS(Pipe, Side), Port),
    Pipe ! {attach, Side, self()},
    set_ref(Port, true),
    OnInit = buoy_heap:get(Port, symbol(<<"oninit">>)),
    buoy_heap:is_callable(OnInit) andalso buoy_heap:call(OnInit, Port, []),
    Queue =/= [] andalso schedule(Port),
    Port.

symbol(Description) ->
    {Description, Symbol} = lists:keyfind(Description, 1, buoy_node:per_isolate_symbols()),
    Symbol.

-spec is_message_port(term()) -> boolean().
is_message_port(V) ->
    buoy_heap:is_object(V) andalso buoy_heap:private_find(V, ?STATE) =/= error.

state(Port) ->
    {ok, S} = buoy_heap:private_find(Port, ?STATE),
    S.

save(Port, S) -> buoy_heap:private_put(Port, ?STATE, S).

update(Port, Fun) -> save(Port, Fun(state(Port))).

%% {Pipe, Side} of an open port, or closed.
-spec port_side(term()) -> {pid(), term()} | closed.
port_side(Port) ->
    case state(Port) of
        #{state := open, pipe := Pipe, side := Side} -> {Pipe, Side};
        _ -> closed
    end.

%% A method of MessagePort.prototype throws on another object, as the
%% signature of its FunctionTemplate makes V8 throw.
with_port(This, Fun) ->
    is_message_port(This) orelse illegal(),
    Fun(state(This)).

start(This) ->
    with_port(This, fun(#{state := open}) ->
                            update(This, fun(S) -> S#{started := true} end),
                            schedule(This),
                            undefined;
                       (_) -> undefined
                    end).

stop(Port) ->
    is_message_port(Port) andalso update(Port, fun(S) -> S#{started := false} end),
    undefined.

%% ref() and unref(): an open port that is ref'd keeps the loop alive, as its
%% uv_async_t does.
set_ref(This, Refed) ->
    with_port(This, fun(#{state := open, refed := Old} = S) ->
                            case {Old, Refed} of
                                {false, true} -> buoy_node_loop:ref_handle();
                                {true, false} -> buoy_node_loop:unref_handle();
                                _ -> ok
                            end,
                            save(This, S#{refed := Refed}),
                            undefined;
                       (_) -> undefined
                    end).

%% HandleWrap::HasRef: false while the port closes, and undefined once it
%% closed, when the handle is gone.
has_ref(This) ->
    with_port(This, fun(#{state := open, refed := Refed}) -> Refed;
                       (#{state := closing}) -> false;
                       (_) -> undefined
                    end).

%% close(): the port and, through the pipe, its sibling close. The 'close'
%% event follows in a later macrotask, as uv_close calls back.
-spec close(term()) -> ok.
close(This) ->
    case is_message_port(This) andalso state(This) of
        #{state := open, pipe := Pipe, side := Side} ->
            Pipe ! {close, Side},
            closed(This);
        _ ->
            ok
    end.

%% The port no longer takes part in its pipe: it unrefs, leaves the registry,
%% and emits 'close' later.
closed(Port) ->
    set_ref(Port, false),
    #{pipe := Pipe, side := Side} = state(Port),
    update(Port, fun(S) -> S#{state := closing} end),
    erlang:erase(?PORTS(Pipe, Side)),
    %% A dispatch that runs still emits the messages that its queue holds, as
    %% MessagePort::OnMessage goes on until OnClose detaches the data.
    buoy_node_loop:defer(fun() ->
        #{queue := Queue} = state(Port),
        close_carried(Queue),
        update(Port, fun(S) -> S#{state := closed, queue := []} end),
        OnClose = buoy_heap:get(Port, symbol(<<"handle_onclose">>)),
        buoy_heap:is_callable(OnClose) andalso buoy_heap:call(OnClose, Port, [])
    end),
    ok.

%% A message that no port will read closes the ports that it carries.
-spec close_carried([term()]) -> ok.
close_carried(Messages) ->
    [Pipe ! {close, Side} || {message, _, Ports} <- Messages, {Pipe, Side, _} <- Ports],
    ok.

%%% Receiving
%%
%% A pipe's wake-up only moves the inbox into the port's queue and marks the
%% port. One poll job then serves every marked port in the order the ports
%% were made, each with every message that waits, as libuv's poll phase runs
%% each uv_async_t of MessagePort::OnMessage in handle order. Microtasks and
%% ticks run between messages (MakeCallback).

%% The pipe has messages for the side Side of Pipe in this realm.
-spec ready(pid(), term()) -> ok.
ready(Pipe, Side) ->
    case erlang:get(?PORTS(Pipe, Side)) of
        undefined ->
            ok;
        Port ->
            take(Port),
            schedule(Port)
    end.

%% Moves the inbox of the port in its pipe to the queue of the port.
take(Port) ->
    #{pipe := Pipe, side := Side, queue := Queue} = state(Port),
    case call(Pipe, {take, Side}) of
        {ok, []} -> ok;
        {ok, Messages} -> update(Port, fun(S) -> S#{queue := Queue ++ Messages} end);
        closed -> ok
    end.

%% Marks a port whose queue holds messages, and makes sure a poll follows.
schedule(Port) ->
    case state(Port) of
        #{state := open, queue := [_ | _], pipe := Pipe, side := Side, seq := Seq} ->
            Pending = pending(),
            erlang:put(?PENDING, Pending#{Seq => {Pipe, Side}}),
            case erlang:get(?POLL) of
                true -> ok;
                _ -> erlang:put(?POLL, true), self() ! {'$buoy_node_call', fun ?MODULE:poll/0}
            end,
            ok;
        _ ->
            ok
    end.

pending() ->
    case erlang:get(?PENDING) of
        undefined -> #{};
        P -> P
    end.

%% The poll job: each marked port, in the order of creation.
-spec poll() -> ok.
poll() ->
    erlang:erase(?POLL),
    poll_next().

poll_next() ->
    case lists:sort(maps:to_list(pending())) of
        [] ->
            ok;
        [{Seq, {Pipe, Side}} | _] ->
            erlang:put(?PENDING, maps:remove(Seq, pending())),
            case erlang:get(?PORTS(Pipe, Side)) of
                undefined -> ok;
                Port -> dispatch(Port)
            end,
            poll_next()
    end.

%% MessagePort::OnMessage: the messages that wait, at least 1000 and at most
%% the ones there at the start, then the rest in a later poll. A close that
%% waits first closes the port even when it does not receive.
dispatch(Port) ->
    #{queue := Queue} = state(Port),
    dispatch(Port, max(length(Queue), 1000)).

dispatch(Port, 0) ->
    schedule(Port);
dispatch(Port, Limit) ->
    case state(Port) of
        #{state := open, queue := [close | _]} ->
            close(Port);
        #{state := closing, queue := [close | _]} ->
            ok;
        #{state := Open, started := true, queue := [Message | Rest]} = S when Open =:= open; Open =:= closing ->
            save(Port, S#{queue := Rest}),
            try emit(Port, Message)
            catch Class:Reason:Stack ->
                %% The uncaught error goes to the job; the rest of the queue waits for the next poll.
                schedule(Port),
                erlang:raise(Class, Reason, Stack)
            end,
            case Rest of
                [] -> ok;
                _ -> buoy_node_loop:after_callback(), dispatch(Port, Limit - 1)
            end;
        _ ->
            ok
    end.

emit(Port, Message) ->
    Emit = buoy_heap:get(buoy_node:context(), <<"emitMessage">>),
    case deserialize(Message) of
        {ok, Value, Ports} ->
            buoy_heap:call(Emit, Port, [Value, buoy_heap:new_array(Ports), <<"message">>]);
        {error, Error} ->
            buoy_heap:call(Emit, Port, [Error, buoy_heap:new_array([]), <<"messageerror">>])
    end,
    ok.

%% drainMessagePort(port): emits every message that waits, now.
drain(Port) ->
    case is_message_port(Port) andalso state(Port) of
        #{state := open} ->
            take(Port),
            drain_queue(Port);
        _ ->
            ok
    end,
    undefined.

drain_queue(Port) ->
    case state(Port) of
        #{state := open, queue := [close | _]} ->
            close(Port);
        #{state := open, queue := [Message | Rest]} = S ->
            save(Port, S#{queue := Rest}),
            emit(Port, Message),
            drain_queue(Port);
        _ ->
            ok
    end.

%% receiveMessageOnPort(port): the first message that waits, or the
%% no_message_symbol.
receive_message(Port) ->
    is_message_port(Port) orelse buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>,
                                              <<"The \"port\" argument must be a MessagePort instance">>),
    NoMessage = symbol(<<"no_message_symbol">>),
    case state(Port) of
        #{state := open} ->
            #{queue := Queue} = state(Port),
            Queue =:= [] andalso take(Port),
            case state(Port) of
                #{queue := [close | _]} ->
                    close(Port),
                    NoMessage;
                #{queue := [Message | Rest]} = S ->
                    save(Port, S#{queue := Rest}),
                    case deserialize(Message) of
                        {ok, Value, _} -> Value;
                        {error, Error} -> erlang:error({'$throw', Error})
                    end;
                _ ->
                    NoMessage
            end;
        _ ->
            NoMessage
    end.

%% moveMessagePortToContext(port, context): Buoy's contexts share the realm,
%% so the port stays itself.
move_to_context(Port) ->
    case is_message_port(Port) andalso port_side(Port) of
        false -> buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>, <<"The \"port\" argument must be a MessagePort instance">>);
        closed -> buoy_node:throw_code('Error', <<"ERR_CLOSED_MESSAGE_PORT">>, <<"Cannot send data on closed MessagePort">>);
        _ -> Port
    end.

%% broadcastChannel(name): a port of the pipe of the name, which every realm
%% of the VM shares.
broadcast_channel(Name) ->
    Key = buoy_ref_string:to_utf8(buoy_ref:to_string(Name)),
    {Pipe, Side} = join(Key),
    new_port(Pipe, Side, []).

%%% Sending

%% postMessage(value, transferList or { transfer }): serializes the message,
%% which throws on a bad transfer list even when the port is closed, then
%% sends it, or drops it on a closed port.
post_message(This, []) ->
    is_message_port(This) orelse illegal(),
    buoy_node:throw_code('TypeError', <<"ERR_MISSING_ARGS">>, <<"Not enough arguments to MessagePort.postMessage">>);
post_message(This, Args) ->
    is_message_port(This) orelse illegal(),
    Transfer = transfer_list(buoy_node:arg(2, Args)),
    Message = serialize(buoy_node:arg(1, Args), Transfer, This),
    case port_side(This) of
        closed ->
            close_carried([Message]),
            true;
        {Pipe, Side} ->
            case [P || {message, _, Ports} <- [Message], {P, _, _} <- Ports, P =:= Pipe] of
                [] ->
                    Pipe ! {send, Side, Message};
                _ ->
                    warn(<<"The target port was posted to itself, and the communication channel was lost">>),
                    close_carried([Message])
            end,
            true
    end.

-spec illegal() -> no_return().
illegal() -> buoy_ref:type_error(<<"Illegal invocation">>).

warn(Text) ->
    Process = buoy_node_loop:process(),
    buoy_heap:call(buoy_heap:get(Process, <<"emitWarning">>), Process, [Text]).

%% The items of the transfer list argument: an iterable, or the transfer
%% property of an options object.
transfer_list(V) when V =:= undefined; V =:= null -> [];
transfer_list(V) ->
    case buoy_heap:is_object(V) of
        true ->
            case is_iterable(V) of
                true -> iterate(V, <<"Optional transferList argument must be an iterable">>);
                false ->
                    case buoy_heap:get(V, <<"transfer">>) of
                        undefined -> [];
                        T -> iterate(T, <<"Optional options.transfer argument must be an iterable">>)
                    end
            end;
        false ->
            invalid_iterable(<<"Optional transferList argument must be an iterable">>)
    end.

is_iterable(V) ->
    buoy_heap:class_of(V) =:= array orelse buoy_heap:is_callable(buoy_heap:get(V, buoy_heap:well_known(iterator))).

iterate(V, Message) ->
    buoy_heap:is_object(V) orelse invalid_iterable(Message),
    case buoy_heap:class_of(V) of
        array ->
            buoy_heap:array_items(V);
        _ ->
            Method = buoy_heap:get(V, buoy_heap:well_known(iterator)),
            buoy_heap:is_callable(Method) orelse invalid_iterable(Message),
            Iterator = buoy_heap:call(Method, V, []),
            buoy_heap:is_object(Iterator) orelse invalid_iterable(Message),
            Next = buoy_heap:get(Iterator, <<"next">>),
            buoy_heap:is_callable(Next) orelse invalid_iterable(Message),
            step(Iterator, Next, Message, [])
    end.

step(Iterator, Next, Message, Acc) ->
    Result = buoy_heap:call(Next, Iterator, []),
    buoy_heap:is_object(Result) orelse invalid_iterable(Message),
    case buoy_ref:truthy(buoy_heap:get(Result, <<"done">>)) of
        true -> lists:reverse(Acc);
        false -> step(Iterator, Next, Message, [buoy_heap:get(Result, <<"value">>) | Acc])
    end.

-spec invalid_iterable(binary()) -> no_return().
invalid_iterable(Message) ->
    buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>, Message).

%% Message::Serialize: checks the transfer list as Node does, in its order,
%% before it detaches anything, clones the value, and then detaches each
%% transferred ArrayBuffer and port.
serialize(Value, Transfer, Source) ->
    Checked = check_transfer(Transfer, Source, [], []),
    Buffers = [B || {buffer, B} <- Checked],
    Ports0 = [P || {port, P} <- Checked],
    Js = [O || {js, O} <- Checked],
    %% A transferred JS object, such as a ReadableStream, may transfer ports of its own.
    Nested = lists:append([nested_transfers(O) || O <- Js]),
    Ports = Ports0 ++ [P || P <- Nested, is_message_port(P), not lists:member(P, Ports0)],
    Hook = fun(O) -> host_out(O, Ports, Js) end,
    Payload = try buoy_heap:clone_out(Value, Hook)
              catch error:{'$throw', E} -> erlang:error({'$throw', dom_clone_error(E)})
              end,
    [buoy_ref_buffer:detach(B) || B <- Buffers],
    {message, Payload, [transfer_out(P) || P <- Ports]}.

check_transfer([], _Source, Acc, _Seen) ->
    lists:reverse(Acc);
check_transfer([O | Rest], Source, Acc, Seen) ->
    buoy_heap:is_object(O) orelse
        buoy_node:throw_code('TypeError', <<"ERR_INVALID_TRANSFER_OBJECT">>, <<"Found invalid value in transferList.">>),
    own(O, buoy_node:private_symbol(<<"untransferable_object_private_symbol">>)) =/= undefined andalso
        clone_error(<<"Cannot transfer object of unsupported type.">>),
    lists:member(O, Seen) andalso
        clone_error(case buoy_heap:class_of(O) of
                        array_buffer -> <<"Transfer list contains duplicate ArrayBuffer">>;
                        _ -> buoy_ref_string:concat([<<"Transfer list contains duplicate ">>, constructor_name(O)])
                    end),
    Entry = case buoy_heap:class_of(O) of
        array_buffer ->
            buoy_ref_buffer:is_detached(O) andalso clone_error(<<"An ArrayBuffer is detached and could not be cloned.">>),
            {buffer, O};
        _ ->
            O =:= Source andalso clone_error(<<"Transfer list contains source port">>),
            case is_message_port(O) of
                true ->
                    port_side(O) =:= closed andalso clone_error(<<"MessagePort in transfer list is already detached">>),
                    {port, O};
                false ->
                    case transfer_mode(O) of
                        undefined ->
                            buoy_node:throw_code('TypeError', <<"ERR_INVALID_TRANSFER_OBJECT">>, <<"Found invalid value in transferList.">>);
                        Mode when Mode band 1 =:= 1 ->
                            {js, O};
                        _ ->
                            clone_error(<<"Cannot transfer object of unsupported type.">>)
                    end
            end
    end,
    check_transfer(Rest, Source, [Entry | Acc], [O | Seen]).

transfer_mode(O) ->
    case own(O, buoy_node:private_symbol(<<"transfer_mode_private_symbol">>)) of
        undefined -> undefined;
        Mode -> trunc(buoy_ref:to_number(Mode))
    end.

own(O, Key) ->
    case buoy_heap:get_own(O, Key) of
        {data, V, _} -> V;
        _ -> undefined
    end.

constructor_name(O) ->
    case buoy_heap:get(O, <<"constructor">>) of
        C when C =/= undefined ->
            case buoy_heap:get(C, <<"name">>) of
                Name when Name =/= undefined -> buoy_ref:to_string(Name);
                _ -> <<"Object">>
            end;
        _ ->
            <<"Object">>
    end.

nested_transfers(O) ->
    case buoy_heap:get(O, symbol(<<"messaging_transfer_list_symbol">>)) of
        F when F =/= undefined ->
            case buoy_heap:call(F, O, []) of
                List when List =/= undefined, List =/= null -> buoy_heap:array_items(List);
                _ -> []
            end;
        _ ->
            []
    end.

%% The host tag of an object that the clone meets: a port of the transfer
%% list, or a JS transferable, which its kTransfer or kClone method turns into
%% data and the id of the class that deserializes it.
host_out(O, Ports, Js) ->
    case index_of(O, Ports) of
        {ok, I} ->
            {host, {port, I}, undefined};
        error ->
            is_message_port(O) andalso
                clone_error(<<"Object that needs transfer was found in message but not listed in transferList">>),
            case transfer_mode(O) of
                undefined ->
                    none;
                Mode ->
                    Transferred = lists:member(O, Js),
                    Method = if
                        Transferred -> <<"messaging_transfer_symbol">>;
                        Mode band 2 =:= 2 -> <<"messaging_clone_symbol">>;
                        Mode band 1 =:= 1 ->
                            clone_error(<<"Object that needs transfer was found in message but not listed in transferList">>);
                        true ->
                            clone_error(<<"Cannot clone object of unsupported type.">>)
                    end,
                    Result = buoy_heap:call(buoy_heap:get(O, symbol(Method)), O, []),
                    Info = buoy_ref_string:to_utf8(buoy_ref:to_string(buoy_heap:get(Result, <<"deserializeInfo">>))),
                    {host, {js, Info}, buoy_heap:get(Result, <<"data">>)}
            end
    end.

index_of(X, List) -> index_of(X, List, 0).
index_of(_, [], _) -> error;
index_of(X, [X | _], I) -> {ok, I};
index_of(X, [_ | Rest], I) -> index_of(X, Rest, I + 1).

%% A transferred port leaves this realm: it detaches from its pipe, so the
%% pipe keeps what arrives until the receiving realm attaches, and it carries
%% the messages that waited in its queue. The port here closes.
-spec transfer_out(term()) -> {pid(), term(), [term()]}.
transfer_out(Port) ->
    #{pipe := Pipe, side := Side, queue := Queue} = state(Port),
    ok = detach(Pipe, Side),
    update(Port, fun(S) -> S#{queue := []} end),
    set_ref(Port, false),
    update(Port, fun(S) -> S#{state := closing} end),
    erlang:erase(?PORTS(Pipe, Side)),
    buoy_node_loop:defer(fun() ->
        update(Port, fun(S) -> S#{state := closed} end),
        OnClose = buoy_heap:get(Port, symbol(<<"handle_onclose">>)),
        buoy_heap:is_callable(OnClose) andalso buoy_heap:call(OnClose, Port, [])
    end),
    {Pipe, Side, Queue}.

detach(Pipe, Side) ->
    case call(Pipe, {detach, Side}) of
        {ok, ok} -> ok;
        closed -> ok
    end.

-spec clone_error(binary()) -> no_return().
clone_error(Message) ->
    erlang:error({'$throw', dom_exception(Message, <<"DataCloneError">>)}).

dom_exception(Message, Name) ->
    DOMException = buoy_heap:get(buoy_node:context(), <<"DOMException">>),
    buoy_heap:construct(DOMException, [Message, Name], DOMException).

%% The engine's DataCloneError becomes Node's DOMException.
dom_clone_error(E) ->
    case buoy_heap:is_object(E) andalso buoy_heap:class_of(E) =:= error andalso buoy_heap:get(E, <<"name">>) of
        <<"DataCloneError">> -> dom_exception(buoy_heap:get(E, <<"message">>), <<"DataCloneError">>);
        _ -> E
    end.

%% The value of a message in this realm, with a port for each that it
%% carries, or {error, Error} when a JS transferable cannot be made.
deserialize({message, Payload, Carried}) ->
    Ports = [new_port(Pipe, Side, Queue) || {Pipe, Side, Queue} <- Carried],
    Hook = fun({{port, I}, _}) -> lists:nth(I + 1, Ports);
              ({{js, Info}, Data}) -> js_object(Info, Data)
           end,
    try buoy_heap:clone_in(Payload, Hook) of
        Value -> {ok, Value, Ports}
    catch
        error:{'$throw', E} -> {error, E}
    end.

js_object(Info, Data) ->
    Create = erlang:get(?CREATE),
    O = buoy_heap:call(Create, undefined, [buoy_ref_string:from_utf8(Info)]),
    buoy_heap:call(buoy_heap:get(O, symbol(<<"messaging_deserialize_symbol">>)), O, [Data]),
    O.

%% structuredClone(value, { transfer }): the clone, with each transferred
%% ArrayBuffer detached and each transferred port moved to the clone.
structured_clone(Value, Options) ->
    Transfer = case buoy_heap:is_object(Options) andalso buoy_heap:get(Options, <<"transfer">>) of
        false -> [];
        undefined -> [];
        List -> buoy_heap:array_items(List)
    end,
    case deserialize(serialize(Value, Transfer, undefined)) of
        {ok, Clone, _} -> Clone;
        {error, Error} -> erlang:error({'$throw', Error})
    end.

%%% Calls to a pipe

call(Pipe, Request) ->
    Ref = erlang:monitor(process, Pipe),
    Pipe ! {Request, self(), Ref},
    receive
        {Ref, Reply} ->
            erlang:demonitor(Ref, [flush]),
            {ok, Reply};
        {'DOWN', Ref, process, Pipe, _} ->
            closed
    end.

%% The side of a new member of the broadcast pipe Name, which a registry
%% process starts once per name.
join(Name) ->
    Registry = registry(),
    Ref = erlang:monitor(process, Registry),
    Registry ! {join, Name, self(), Ref},
    receive
        {Ref, Pipe, Side} ->
            erlang:demonitor(Ref, [flush]),
            {Pipe, Side}
    end.

registry() ->
    case whereis(buoy_node_broadcast) of
        undefined ->
            Pid = spawn(fun() -> registry_loop(#{}) end),
            try register(buoy_node_broadcast, Pid) of
                true -> Pid
            catch error:badarg ->
                exit(Pid, kill),
                registry()
            end;
        Pid ->
            Pid
    end.

registry_loop(Pipes) ->
    receive
        {join, Name, Owner, Ref} ->
            Pipe = case Pipes of
                #{Name := P} -> P;
                _ -> spawn(?MODULE, pipe_init, [broadcast])
            end,
            Side = erlang:unique_integer([positive]),
            Pipe ! {join, Side},
            Owner ! {Ref, Pipe, Side},
            registry_loop(Pipes#{Name => Pipe})
    end.

%%% The pipe

%% A pipe: Kind is channel, whose sides 1 and 2 send to each other, or
%% broadcast, whose sides send to every other side. A side is
%% #{owner, inbox, notified}, its owner the realm that holds its port.
-spec pipe_init(channel | broadcast) -> no_return().
pipe_init(channel) ->
    pipe_loop(#{kind => channel, sides => #{1 => side(), 2 => side()}, owners => #{}});
pipe_init(broadcast) ->
    pipe_loop(#{kind => broadcast, sides => #{}, owners => #{}}).

side() -> #{owner => none, inbox => [], notified => false}.

pipe_loop(#{sides := Sides} = P) ->
    receive
        {send, From, Message} ->
            Targets = [S || S <- maps:keys(Sides), S =/= From],
            case Targets of
                [] -> close_carried([Message]);
                _ -> ok
            end,
            %% A broadcast message goes to each member; the ports it carries go once.
            pipe_loop(lists:foldl(fun(T, Acc) -> enqueue(T, Message, Acc) end, P, Targets));
        {attach, Side, Owner} ->
            case Sides of
                #{Side := S} ->
                    P1 = monitor_owner(Owner, P),
                    pipe_loop(notify(Side, (store(Side, S#{owner := Owner, notified := false}, P1))));
                _ ->
                    %% The side closed while its port moved: the new port closes.
                    Self = self(),
                    Owner ! {'$buoy_node_call', fun() -> ?MODULE:ready(Self, Side) end},
                    pipe_loop(P)
            end;
        {join, Side} ->
            pipe_loop(store(Side, side(), P));
        {{detach, Side}, From, Ref} ->
            From ! {Ref, ok},
            case Sides of
                #{Side := S} -> pipe_loop(store(Side, S#{owner := none, notified := false}, P));
                _ -> pipe_loop(P)
            end;
        {{take, Side}, From, Ref} ->
            case Sides of
                #{Side := #{inbox := Inbox} = S} ->
                    From ! {Ref, lists:reverse(Inbox)},
                    pipe_loop(store(Side, S#{inbox := [], notified := false}, P));
                _ ->
                    From ! {Ref, [close]},
                    pipe_loop(P)
            end;
        {close, Side} ->
            pipe_loop(remove(Side, P));
        {'DOWN', _, process, Owner, _} ->
            Owned = [S || S := #{owner := O} <- Sides, O =:= Owner],
            pipe_loop(lists:foldl(fun remove/2, P#{owners := maps:remove(Owner, maps:get(owners, P))}, Owned))
    end.

store(Side, S, #{sides := Sides} = P) -> P#{sides := Sides#{Side => S}}.

enqueue(Side, Message, #{sides := Sides} = P) ->
    #{inbox := Inbox} = S = maps:get(Side, Sides),
    notify(Side, store(Side, S#{inbox := [Message | Inbox]}, P)).

%% Wakes the owner of Side once while its inbox holds messages.
notify(Side, #{sides := Sides} = P) ->
    case maps:get(Side, Sides) of
        #{owner := Owner, notified := false, inbox := [_ | _]} = S when is_pid(Owner) ->
            Self = self(),
            Owner ! {'$buoy_node_call', fun() -> ?MODULE:ready(Self, Side) end},
            store(Side, S#{notified := true}, P);
        _ ->
            P
    end.

monitor_owner(Owner, #{owners := Owners} = P) ->
    case Owners of
        #{Owner := _} -> P;
        _ -> P#{owners := Owners#{Owner => erlang:monitor(process, Owner)}}
    end.

%% A side closes: what waited for it is dropped, and the sibling of a
%% channel gets a close after its messages. A pipe whose sides all closed
%% ends.
remove(Side, #{kind := Kind, sides := Sides} = P) ->
    case maps:take(Side, Sides) of
        error ->
            P;
        {#{inbox := Inbox}, Rest} ->
            close_carried(Inbox),
            P1 = P#{sides := Rest},
            P2 = case Kind of
                channel -> lists:foldl(fun(T, Acc) -> enqueue(T, close, Acc) end, P1, maps:keys(Rest));
                broadcast -> P1
            end,
            case {Kind, maps:size(Rest)} of
                {channel, 0} -> exit(normal);
                _ -> P2
            end
    end.
