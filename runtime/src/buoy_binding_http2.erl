%% internalBinding('http2') (src/node_http2.cc): Http2Session and Http2Stream
%% over buoy_h2, the session of nghttp2's semantics.
%%
%% A session consumes the handle of its socket, as Http2Session::Consume
%% pushes a stream listener: the handle's onread feeds mem_recv, and the
%% bytes of mem_send go out through the handle's writev. An Http2Stream is
%% a StreamBase (buoy_stream_base): its writes queue as the body of the
%% stream, and its reads are the DATA that the peer sends.
%%
%% Bun replaces lib/internal/http2 with its own node:http2 over a native
%% frame parser (src/js/node/http2.ts). Buoy keeps Node's JavaScript and
%% gives it the binding that it expects, so every callback, error code, and
%% shared typed array has Node's meaning. Writes go out from a later
%% macrotask, as Http2Scope schedules them with SetImmediate.
-module(buoy_binding_http2).

-export([binding/0]).

-define(SESSION, {'#', ?MODULE, <<"session">>}).
-define(STREAM, {'#', ?MODULE, <<"stream">>}).
-define(CALLBACKS, {?MODULE, callbacks}).
-define(STATE, {?MODULE, state}).

-define(UV_EOF, -4095).
-define(UV_ECANCELED, -89).
-define(STREAM_OPTION_EMPTY_PAYLOAD, 1).
-define(STREAM_OPTION_GET_TRAILERS, 2).
-define(K_BITFIELD, 0).
-define(K_PRIORITY_LISTENER_COUNT, 1).
-define(K_FRAME_ERROR_LISTENER_COUNT, 2).
-define(K_HAS_REMOTE_SETTINGS_LISTENERS, 0).
-define(K_REMOTE_SETTINGS_IS_UP_TO_DATE, 1).
-define(K_HAS_PING_LISTENERS, 2).
-define(K_HAS_ALTSVC_LISTENERS, 3).
-define(ERR_PROTO, -505).
-define(ERR_CALLBACK_FAILURE, -902).
-define(ENHANCE_YOUR_CALM, 11).
-define(SETTINGS_COUNT, 7).
%% The setting ids of the settings buffer by index, in the order of
%% Http2SettingsIndex (node_http2_state.h) that lib/internal/http2/util.js reads.
-define(SETTING_IDS, [1, 2, 4, 5, 3, 6, 8]).
-define(MAX_ADDITIONAL_SETTINGS, 10).

-spec binding() -> term().
binding() ->
    B = buoy_node_stubs:binding(<<"http2">>),
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    erlang:put(?STATE, #{settings => buoy_heap:get(B, <<"settingsBuffer">>),
                         options => buoy_heap:get(B, <<"optionsBuffer">>),
                         session_state => buoy_heap:get(B, <<"sessionState">>),
                         stream_state => buoy_heap:get(B, <<"streamState">>)}),
    Members = [{<<"nghttp2ErrorString">>, F(<<"nghttp2ErrorString">>, 1, fun(_, Args) ->
                   buoy_h2:strerror(trunc(buoy_ref:to_number(A(1, Args))))
               end)},
               {<<"refreshDefaultSettings">>, F(<<"refreshDefaultSettings">>, 0, fun(_, _) -> refresh_defaults() end)},
               {<<"packSettings">>, F(<<"packSettings">>, 0, fun(_, _) ->
                   buoy_node_encoding:new_buffer(buoy_h2:pack_settings(settings_entries()))
               end)},
               {<<"setCallbackFunctions">>, F(<<"setCallbackFunctions">>, 11, fun(_, Args) ->
                   Names = [error, priority, settings, ping, headers, frame_error, goaway_data, altsvc, origin,
                            stream_trailers, stream_close],
                   erlang:put(?CALLBACKS, maps:from_list(lists:zip(Names, [A(I, Args) || I <- lists:seq(1, 11)]))),
                   undefined
               end)},
               {<<"Http2Session">>, session_class()},
               {<<"Http2Stream">>, stream_class()}],
    [buoy_heap:set(B, K, V) || {K, V} <- Members],
    hidden_constants(buoy_heap:get(B, <<"constants">>)),
    B.

%% The constants that node_http2.cc defines with NODE_DEFINE_HIDDEN_CONSTANT:
%% not enumerable, so the recording of the binding's shape missed them.
hidden_constants(Constants) ->
    [buoy_heap:define(Constants, Name, #{value => V, writable => false, enumerable => false, configurable => false})
     || {Name, V} <- [{<<"NGHTTP2_HCAT_REQUEST">>, 0}, {<<"NGHTTP2_HCAT_RESPONSE">>, 1},
                      {<<"NGHTTP2_HCAT_PUSH_RESPONSE">>, 2}, {<<"NGHTTP2_HCAT_HEADERS">>, 3},
                      {<<"NGHTTP2_NV_FLAG_NONE">>, 0}, {<<"NGHTTP2_NV_FLAG_NO_INDEX">>, 1},
                      {<<"NGHTTP2_ERR_DEFERRED">>, -508}, {<<"NGHTTP2_ERR_STREAM_ID_NOT_AVAILABLE">>, -509},
                      {<<"NGHTTP2_ERR_INVALID_ARGUMENT">>, -501}, {<<"NGHTTP2_ERR_STREAM_CLOSED">>, -510},
                      {<<"NGHTTP2_ERR_NOMEM">>, -901},
                      {<<"STREAM_OPTION_EMPTY_PAYLOAD">>, ?STREAM_OPTION_EMPTY_PAYLOAD},
                      {<<"STREAM_OPTION_GET_TRAILERS">>, ?STREAM_OPTION_GET_TRAILERS}]],
    ok.

%%% Settings and options in the shared buffers

refresh_defaults() ->
    #{settings := Buf} = erlang:get(?STATE),
    Defaults = [4096, 1, 65535, 16384, 16#FFFFFFFF, 65535, 0],
    [buoy_heap:set(Buf, I, V) || {I, V} <- lists:enumerate(0, Defaults)],
    buoy_heap:set(Buf, ?SETTINGS_COUNT, (1 bsl ?SETTINGS_COUNT) - 1),
    buoy_heap:set(Buf, ?SETTINGS_COUNT + 1, 0),
    undefined.

%% Http2Settings::Init: the entries of the settings buffer that its flags
%% mark, then the custom ones.
settings_entries() ->
    #{settings := Buf} = erlang:get(?STATE),
    Get = fun(I) -> trunc(buoy_heap:get(Buf, I)) end,
    Flags = Get(?SETTINGS_COUNT),
    Standard = lists:keysort(1, [{Id, Get(I)} || {I, Id} <- lists:enumerate(0, ?SETTING_IDS), Flags band (1 bsl I) =/= 0]),
    Custom = [{Get(?SETTINGS_COUNT + 2 + N * 2), Get(?SETTINGS_COUNT + 3 + N * 2)}
              || N <- lists:seq(0, Get(?SETTINGS_COUNT + 1) - 1)],
    Standard ++ Custom.

%% The options of Http2Options, read when a session is made.
options() ->
    #{options := Buf} = erlang:get(?STATE),
    Get = fun(I) -> trunc(buoy_heap:get(Buf, I)) end,
    Flags = Get(13),
    Has = fun(I) -> Flags band (1 bsl I) =/= 0 end,
    Pick = fun(I, Key, Acc) ->
        case Has(I) of
            true -> Acc#{Key => Get(I)};
            false -> Acc
        end
    end,
    Pairs = [{0, max_deflate_dynamic_table_size}, {1, max_reserved_remote_streams},
             {2, max_send_header_block_length}, {3, peer_max_concurrent_streams}, {4, padding_strategy},
             {5, max_header_list_pairs}, {6, max_outstanding_pings}, {7, max_outstanding_settings},
             {8, max_session_memory}, {9, max_settings}],
    Opts = lists:foldl(fun({I, K}, Acc) -> Pick(I, K, Acc) end, #{}, Pairs),
    case Has(12) of
        true -> Opts#{strict_ws => Get(12) =:= 0};
        false -> Opts
    end.

%%% Http2Session

session_class() ->
    Class = buoy_node:constructor(<<"Http2Session">>, 1, fun(This, Args) -> new_session(This, buoy_node:arg(1, Args)) end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    A = fun buoy_node:arg/2,
    methods(Proto, ?SESSION, [
        {<<"origin">>, fun(This, Args) -> origin(This, A(1, Args), A(2, Args)) end},
        {<<"altsvc">>, fun(This, Args) -> altsvc(This, A(1, Args), A(2, Args), A(3, Args)) end},
        {<<"ping">>, fun(This, Args) -> ping(This, A(1, Args), A(2, Args)) end},
        {<<"consume">>, fun(This, Args) -> consume(This, A(1, Args)) end},
        {<<"receive">>, fun(This, Args) -> on_stream_read(This, buoy_node_encoding:view_bytes(A(1, Args))) end},
        {<<"destroy">>, fun(This, Args) -> close(This, to_uint(A(1, Args)), A(2, Args) =:= true) end},
        {<<"goaway">>, fun(This, Args) -> goaway(This, A(1, Args), A(2, Args), A(3, Args)) end},
        {<<"hasPendingData">>, fun(This, _) ->
            H = h2(This),
            buoy_h2:want_write(H) orelse buoy_h2:want_read(H)
        end},
        {<<"settings">>, fun(This, Args) -> settings(This, A(1, Args)) end},
        {<<"request">>, fun(This, Args) -> request(This, Args) end},
        {<<"setNextStreamID">>, fun(This, Args) ->
            {Ok, H} = buoy_h2:set_next_stream_id(h2(This), to_int(A(1, Args))),
            put_h2(This, H),
            Ok
        end},
        {<<"setLocalWindowSize">>, fun(This, Args) ->
            case buoy_h2:set_local_window_size(h2(This), to_int(A(1, Args))) of
                {0, H} -> scoped(This, fun() -> put_h2(This, H) end), 0;
                {Err, _} -> Err
            end
        end},
        {<<"updateChunksSent">>, fun(This, _) ->
            N = maps:get(chunks_sent, session(This), 0),
            buoy_heap:set(This, <<"chunksSentSinceLastWrite">>, N),
            N
        end},
        {<<"refreshState">>, fun(This, _) -> refresh_session_state(This) end},
        {<<"localSettings">>, fun(This, _) -> update_settings(This, local) end},
        {<<"remoteSettings">>, fun(This, _) -> update_settings(This, remote) end},
        {<<"setGracefulClose">>, fun(This, _) -> update(This, fun(S) -> S#{graceful => true} end), undefined end}]),
    async_methods(Proto, ?SESSION, <<"HTTP2SESSION">>),
    Class.

new_session(This, TypeArg) ->
    Type = case to_int(TypeArg) of 0 -> server; _ -> client end,
    Opts = options(),
    Fields = buoy_node:typed_array(<<"Uint8Array">>, 12),
    %% SessionJSFields: max_invalid_frames 1000 and max_rejected_streams 100,
    %% little-endian uint32s at offsets 4 and 8.
    [buoy_heap:set(Fields, I, V) || {I, V} <- [{4, 16#E8}, {5, 3}, {8, 100}]],
    buoy_heap:set(This, <<"fields">>, Fields),
    MaxPairs = maps:get(max_header_list_pairs, Opts, 128),
    Session = #{type => Type, fields => Fields, streams => #{}, socket => undefined,
                async_id => async_id(), padding => maps:get(padding_strategy, Opts, 0),
                max_header_pairs => case Type of server -> max(MaxPairs, 4); client -> max(MaxPairs, 1) end,
                max_pings => maps:get(max_outstanding_pings, Opts, 10),
                max_settings => maps:get(max_outstanding_settings, Opts, 10),
                pings => [], settings => [], outgoing => [], pending_rst => [],
                write_scheduled => false, in_scope => false, sending => false, write_in_progress => false,
                reading_stopped => false, destroyed => false, closing => false, graceful => false,
                invalid_frames => 0, rejected_streams => 0, chunks_sent => 0,
                remote_custom => remote_custom(), local_custom => []},
    buoy_heap:private_put(This, ?SESSION, Session),
    H = buoy_h2:new(Type, Opts, fun(Event, H0) -> event(This, Event, H0) end),
    put_h2(This, H),
    undefined.

%% The custom settings that the peer may send, from the settings buffer.
remote_custom() ->
    #{settings := Buf} = erlang:get(?STATE),
    Get = fun(I) -> trunc(buoy_heap:get(Buf, I)) end,
    [{Get(?SETTINGS_COUNT + 2 + N * 2) band 16#FFFF, unset} || N <- lists:seq(0, Get(?SETTINGS_COUNT + 1) - 1)].

session(This) ->
    case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, ?SESSION) of
        {ok, S} -> S;
        _ -> #{}
    end.

update(This, Fun) ->
    buoy_heap:private_put(This, ?SESSION, Fun(session(This))).

h2(This) -> erlang:get({?MODULE, h2, This}).

put_h2(This, H) -> erlang:put({?MODULE, h2, This}, H).

%% Runs Fun as a JavaScript call into the session: the session state
%% stays in the process dictionary, and the write it causes is scheduled
%% at the end, as Http2Scope does.
scoped(This, Fun) ->
    case maps:get(in_scope, session(This), false) orelse maps:get(write_scheduled, session(This), false) of
        true ->
            Fun();
        false ->
            update(This, fun(S) -> S#{in_scope => true} end),
            try Fun()
            after
                update(This, fun(S) -> S#{in_scope => false} end),
                maybe_schedule_write(This)
            end
    end.

maybe_schedule_write(This) ->
    S = session(This),
    case maps:get(write_scheduled, S) orelse maps:get(destroyed, S) of
        true ->
            ok;
        false ->
            case buoy_h2:want_write(h2(This)) of
                false -> ok;
                true ->
                    update(This, fun(St) -> St#{write_scheduled => true} end),
                    buoy_node_loop:set_immediate(fun() ->
                        case session(This) of
                            #{write_scheduled := true, destroyed := false} -> send_pending(This);
                            _ -> ok
                        end
                    end)
            end
    end.

%% consume(handle): the session reads and writes the socket's handle.
consume(This, Handle) ->
    Prev = buoy_heap:get(Handle, <<"onread">>),
    update(This, fun(S) -> S#{socket => Handle, prev_onread => Prev} end),
    Onread = buoy_node:fn(<<"onread">>, 1, fun(_, Args) -> on_socket_read(This, Handle, buoy_node:arg(1, Args)) end),
    buoy_heap:set(Handle, <<"onread">>, Onread),
    undefined.

on_socket_read(This, Handle, Buffer) ->
    State = buoy_heap:get(buoy_node:binding(<<"stream_wrap">>), <<"streamBaseState">>),
    case trunc(buoy_heap:get(State, 0)) of
        N when N < 0 ->
            %% PassReadErrorToPreviousListener: the socket hears its EOF.
            case maps:get(prev_onread, session(This), undefined) of
                Prev when Prev =/= undefined -> buoy_heap:call(Prev, Handle, [Buffer]);
                _ -> undefined
            end;
        0 ->
            undefined;
        N ->
            Offset = trunc(buoy_heap:get(State, 1)),
            <<_:Offset/binary, Bytes:N/binary, _/binary>> = buoy_ref_buffer:read(Buffer, 0, buoy_ref_buffer:byte_length(Buffer)),
            on_stream_read(This, Bytes)
    end.

%% Http2Session::OnStreamRead and ConsumeHTTP2Data.
on_stream_read(This, Bytes) ->
    case session(This) of
        #{destroyed := false} ->
            scoped(This, fun() ->
                {Ret, H} = buoy_h2:mem_recv(h2(This), Bytes),
                put_h2(This, H),
                case Ret of
                    ok ->
                        case session(This) of
                            #{destroyed := false} -> send_pending(This);
                            _ -> ok
                        end;
                    Code ->
                        Custom = maps:get(custom_error, session(This), null),
                        update(This, fun(S) -> maps:remove(custom_error, S) end),
                        call_session(This, error, [Code, Custom])
                end,
                maybe_stop_reading(This)
            end),
            undefined;
        _ ->
            undefined
    end.

maybe_stop_reading(This) ->
    S = session(This),
    case maps:get(reading_stopped, S) orelse maps:get(closing, S) orelse maps:get(socket, S) =:= undefined of
        true -> ok;
        false ->
            case not buoy_h2:want_read(h2(This)) orelse maps:get(write_in_progress, S) of
                true ->
                    update(This, fun(St) -> St#{reading_stopped => true} end),
                    socket_call(This, <<"readStop">>, []);
                false ->
                    ok
            end
    end.

socket_call(This, Name, Args) ->
    case maps:get(socket, session(This)) of
        undefined -> undefined;
        Handle ->
            F = buoy_heap:get(Handle, Name),
            case buoy_heap:is_callable(F) of
                true -> buoy_heap:call(F, Handle, Args);
                false -> undefined
            end
    end.

%% Http2Session::SendPendingData: every frame that is ready, in one writev
%% of one buffer for each piece that nghttp2 gave.
send_pending(This) ->
    case session(This) of
        #{destroyed := true} ->
            0;
        #{sending := true} ->
            update(This, fun(S) -> S#{write_scheduled => false} end),
            1;
        _ ->
            update(This, fun(S) -> S#{write_scheduled => false, sending => true} end),
            {Buffers, H} = buoy_h2:mem_send(h2(This)),
            put_h2(This, H),
            case {maps:get(socket, session(This)), Buffers} of
                {undefined, _} ->
                    clear_outgoing(This, ?UV_ECANCELED);
                {_, []} ->
                    clear_outgoing(This, 0);
                {Handle, _} ->
                    update(This, fun(S) -> S#{write_in_progress => true, chunks_sent => maps:get(chunks_sent, S) + 1} end),
                    Req = buoy_node:object([]),
                    buoy_heap:set(Req, <<"oncomplete">>, buoy_node:fn(<<"oncomplete">>, 3, fun(_, Args) ->
                        after_write(This, to_int(buoy_node:arg(1, Args)))
                    end)),
                    Write = buoy_heap:get(Handle, <<"writev">>),
                    Chunks = buoy_heap:new_array([buoy_node_encoding:new_buffer(iolist_to_binary(B)) || B <- Buffers]),
                    Status = buoy_heap:call(Write, Handle, [Req, Chunks, true]),
                    StreamState = buoy_heap:get(buoy_node:binding(<<"stream_wrap">>), <<"streamBaseState">>),
                    case {to_int(Status), trunc(buoy_heap:get(StreamState, 3))} of
                        {0, 1} -> ok;
                        {Err, _} ->
                            update(This, fun(S) -> S#{write_in_progress => false} end),
                            clear_outgoing(This, Err),
                            graceful_close_check(This)
                    end
            end,
            maybe_stop_reading(This),
            0
    end.

%% Http2Session::OnStreamAfterWrite.
after_write(This, Status) ->
    graceful_close_check(This),
    update(This, fun(S) -> S#{write_in_progress => false} end),
    clear_outgoing(This, Status),
    S = session(This),
    case maps:get(reading_stopped, S) andalso not maps:get(write_in_progress, S) andalso buoy_h2:want_read(h2(This)) of
        true ->
            update(This, fun(St) -> St#{reading_stopped => false} end),
            socket_call(This, <<"readStart">>, []);
        false ->
            ok
    end,
    case session(This) of
        #{destroyed := true} ->
            call_owner(This, <<"ondone">>, []),
            update(This, fun(St) -> St#{reading_stopped => false} end),
            socket_call(This, <<"readStart">>, []);
        #{write_scheduled := false} ->
            maybe_schedule_write(This);
        _ ->
            ok
    end,
    undefined.

%% ClearOutgoing: the writes of the streams that left in this write are
%% done, and the resets that waited for it go out.
clear_outgoing(This, _Status) ->
    #{outgoing := Done, pending_rst := Pending} = session(This),
    update(This, fun(S) -> S#{sending => false, outgoing => [], pending_rst => []} end),
    [buoy_stream_base:done(Req, 0, Stream) || {Req, Stream} <- lists:reverse(Done)],
    case Pending of
        [] -> ok;
        _ ->
            send_pending(This),
            [flush_rst(This, Id) || Id <- Pending]
    end,
    ok.

graceful_close_check(This) ->
    case maps:get(graceful, session(This), false) of
        true ->
            H = h2(This),
            case buoy_h2:want_write(H) orelse buoy_h2:want_read(H) of
                false -> call_owner(This, <<"ongracefulclosecomplete">>, []);
                true -> ok
            end;
        false ->
            ok
    end.

call_owner(This, Name, Args) ->
    F = buoy_heap:get(This, Name),
    case buoy_heap:is_callable(F) of
        true -> buoy_heap:call(F, This, Args);
        false -> undefined
    end.

%% Http2Session::Close.
close(This, Code, SocketClosed) ->
    case session(This) of
        #{closing := true} ->
            undefined;
        #{socket := Socket} ->
            update(This, fun(S) -> S#{closing => true} end),
            case Socket of
                undefined -> ok;
                _ ->
                    update(This, fun(S) -> S#{reading_stopped => true} end),
                    socket_call(This, <<"readStop">>, [])
            end,
            case SocketClosed of
                false ->
                    put_h2(This, buoy_h2:terminate_session(h2(This), Code)),
                    send_pending(This);
                true when Socket =/= undefined ->
                    buoy_heap:set(Socket, <<"onread">>, maps:get(prev_onread, session(This)));
                true ->
                    ok
            end,
            update(This, fun(S) -> S#{destroyed => true} end),
            case maps:get(write_in_progress, session(This)) andalso Socket =/= undefined of
                true -> ok;
                false ->
                    call_owner(This, <<"ondone">>, []),
                    case Socket of
                        undefined -> ok;
                        _ ->
                            update(This, fun(S) -> S#{reading_stopped => false} end),
                            socket_call(This, <<"readStart">>, [])
                    end
            end,
            Pings = maps:get(pings, session(This)),
            update(This, fun(S) -> S#{pings => []} end),
            [buoy_node_loop:set_immediate(fun() -> ping_done(Cb, Start, false, undefined) end) || {Cb, Start} <- Pings],
            undefined;
        _ ->
            undefined
    end.

goaway(This, Code, Last, Data) ->
    case session(This) of
        #{destroyed := false} ->
            Opaque = case buoy_heap:is_object(Data) of
                true -> buoy_node_encoding:view_bytes(Data);
                false -> <<>>
            end,
            scoped(This, fun() ->
                {_, H} = buoy_h2:submit_goaway(h2(This), to_int(Last), to_uint(Code), Opaque),
                put_h2(This, H)
            end),
            undefined;
        _ ->
            undefined
    end.

settings(This, Callback) ->
    S = session(This),
    case length(maps:get(settings, S)) >= maps:get(max_settings, S) of
        true ->
            settings_done(Callback, hrtime(), false),
            false;
        false ->
            Entries = settings_entries(),
            Custom = [{Id, V} || {Id, V} <- Entries, Id > 6, Id =/= 8],
            update(This, fun(St) -> St#{settings => maps:get(settings, St) ++ [{Callback, hrtime()}],
                                         local_custom => merge_custom(maps:get(local_custom, St), Custom)} end),
            scoped(This, fun() ->
                {_, H} = buoy_h2:submit_settings(h2(This), Entries),
                put_h2(This, H)
            end),
            true
    end.

merge_custom(Old, New) ->
    lists:foldl(fun({Id, V}, Acc) ->
        case lists:keymember(Id, 1, Acc) orelse length(Acc) < ?MAX_ADDITIONAL_SETTINGS of
            true -> lists:keystore(Id, 1, Acc, {Id, V});
            false -> Acc
        end
    end, Old, New).

settings_done(Callback, Start, Ack) ->
    buoy_heap:is_callable(Callback) andalso
        buoy_heap:call(Callback, undefined, [Ack, (hrtime() - Start) / 1.0e6]).

ping(This, Payload, Callback) ->
    S = session(This),
    Start = hrtime(),
    case length(maps:get(pings, S)) >= maps:get(max_pings, S) of
        true ->
            ping_done(Callback, Start, false, undefined),
            false;
        false ->
            Bytes = case buoy_heap:is_object(Payload) of
                true -> buoy_node_encoding:view_bytes(Payload);
                false -> <<Start:64/little>>
            end,
            update(This, fun(St) -> St#{pings => maps:get(pings, St) ++ [{Callback, Start}]} end),
            scoped(This, fun() -> put_h2(This, buoy_h2:submit_ping(h2(This), Bytes)) end),
            true
    end.

ping_done(Callback, Start, Ack, Payload) ->
    Buf = case Payload of
        undefined -> undefined;
        _ -> buoy_node_encoding:new_buffer(Payload)
    end,
    buoy_heap:is_callable(Callback) andalso
        buoy_heap:call(Callback, undefined, [Ack, (hrtime() - Start) / 1.0e6, Buf]).

origin(This, String, Count) ->
    Text = buoy_node_encoding:encode(latin1, String),
    Origins = [O || O <- binary:split(Text, <<0>>, [global]), O =/= <<>>],
    case to_int(Count) of
        0 -> ok;
        _ -> scoped(This, fun() -> put_h2(This, buoy_h2:submit_origin(h2(This), Origins)) end)
    end,
    undefined.

altsvc(This, Id, Origin, Value) ->
    O = buoy_node_encoding:encode(latin1, buoy_ref:to_string(Origin)),
    V = buoy_node_encoding:encode(latin1, buoy_ref:to_string(Value)),
    scoped(This, fun() -> put_h2(This, buoy_h2:submit_altsvc(h2(This), to_int(Id), O, V)) end),
    undefined.

%% request(headers, options, parent, weight, exclusive): the stream, or the
%% negative error of nghttp2_submit_request.
request(This, Args) ->
    A = fun(N) -> buoy_node:arg(N, Args) end,
    Fields = headers(A(1)),
    Options = to_int(A(2)),
    Pri = priority(A(3), A(4), A(5)),
    scoped(This, fun() ->
        {Ret, H} = buoy_h2:submit_request(h2(This), Pri, Fields, Options band ?STREAM_OPTION_EMPTY_PAYLOAD =:= 0),
        put_h2(This, H),
        case Ret > 0 of
            true -> new_stream(This, Ret, 3, Options);
            false -> Ret
        end
    end).

priority(Parent, Weight, Exclusive) ->
    case {to_int(Parent), to_int(Weight)} of
        {P, W} when is_integer(P), is_integer(W), W > 0 -> {P, min(W, 256), Exclusive =:= true};
        _ -> none
    end.

%% The fields of a header list from JavaScript: [string, count], with
%% "name\0value\0flags" for each field.
headers(List) ->
    case buoy_heap:is_object(List) of
        false -> [];
        true ->
            Text = buoy_node_encoding:encode(latin1, buoy_heap:get(List, 0)),
            fields(Text)
    end.

fields(<<>>) -> [];
fields(Text) ->
    case binary:split(Text, <<0>>) of
        [Name, Rest] ->
            case binary:split(Rest, <<0>>) of
                [Value, <<Flags, Rest2/binary>>] -> [{Name, Value, Flags band 1 =:= 1} | fields(Rest2)];
                _ -> []
            end;
        _ -> []
    end.

refresh_session_state(This) ->
    #{session_state := Buf} = erlang:get(?STATE),
    [buoy_heap:set(Buf, I, V) || {I, V} <- lists:enumerate(0, buoy_h2:session_state(h2(This)))],
    undefined.

%% Http2Settings::Update: the local or remote settings, into the buffer.
update_settings(This, Which) ->
    #{settings := Buf} = erlang:get(?STATE),
    H = h2(This),
    Settings = case Which of local -> buoy_h2:local_settings(H); remote -> buoy_h2:remote_settings(H) end,
    Keys = [header_table_size, enable_push, initial_window_size, max_frame_size, max_concurrent_streams,
            max_header_list_size, enable_connect_protocol],
    [buoy_heap:set(Buf, I, maps:get(K, Settings)) || {I, K} <- lists:enumerate(0, Keys)],
    Custom = case Which of
        local -> maps:get(local_custom, session(This));
        remote -> [{Id, V} || {Id, V} <- maps:get(remote_custom, session(This)), V =/= unset]
    end,
    Shown = lists:sublist(Custom, ?MAX_ADDITIONAL_SETTINGS),
    [begin
         buoy_heap:set(Buf, ?SETTINGS_COUNT + 2 + N * 2, Id),
         buoy_heap:set(Buf, ?SETTINGS_COUNT + 3 + N * 2, V)
     end || {N, {Id, V}} <- lists:enumerate(0, Shown)],
    buoy_heap:set(Buf, ?SETTINGS_COUNT + 1, length(Shown)),
    undefined.

%%% The events of the session (the callbacks of nghttp2)

%% Each event runs with the session in the process dictionary, where the
%% JavaScript that it calls finds it.
event(This, Event, H) ->
    put_h2(This, H),
    Reply = on(This, Event),
    {Reply, h2(This)}.

on(This, {begin_headers, #{id := Id, cat := Cat}}) ->
    case find_stream(This, Id) of
        undefined ->
            S = session(This),
            Local = buoy_h2:local_settings(h2(This)),
            case map_size(maps:get(streams, S)) < maps:get(max_concurrent_streams, Local) of
                true ->
                    update(This, fun(St) -> St#{rejected_streams => 0} end),
                    new_stream(This, Id, Cat, 0),
                    ok;
                false ->
                    N = maps:get(rejected_streams, S),
                    update(This, fun(St) -> St#{rejected_streams => N + 1} end),
                    case N > uint32(maps:get(fields, S), 8) of
                        true -> {fatal, ?ERR_CALLBACK_FAILURE};
                        false -> {rst, ?ENHANCE_YOUR_CALM}
                    end
            end;
        Stream ->
            case stream(Stream) of
                #{destroyed := false} -> update_stream(Stream, fun(St) -> St#{headers => [], headers_length => 0, cat => Cat} end);
                _ -> ok
            end,
            ok
    end;
on(This, {header, Id, Name, Value, NoIndex}) ->
    case find_stream(This, Id) of
        undefined ->
            temporal;
        Stream ->
            case stream(Stream) of
                #{destroyed := true} ->
                    ok;
                _ when Name =:= <<>> ->
                    ok;
                #{headers := Headers, headers_length := Length, max_header_length := MaxLength} ->
                    Size = byte_size(Name) + byte_size(Value) + 32,
                    case length(Headers) >= maps:get(max_header_pairs, session(This)) orelse Length + Size > MaxLength of
                        true -> {rst, ?ENHANCE_YOUR_CALM};
                        false ->
                            update_stream(Stream, fun(St) -> St#{headers => [{Name, Value, NoIndex} | Headers],
                                                                 headers_length => Length + Size} end),
                            ok
                    end
            end
    end;
on(_, {invalid_header, _, _, _}) ->
    ok;
on(This, {frame_recv, #{type := Type} = F}) ->
    case frame_received(This, Type, F) of
        fatal -> {fatal, ?ERR_CALLBACK_FAILURE};
        _ -> 0
    end;
on(This, {data_chunk, Id, Data, _Flags}) ->
    put_h2(This, buoy_h2:consume_connection(h2(This), byte_size(Data))),
    case find_stream(This, Id) of
        undefined -> ok;
        Stream ->
            case stream(Stream) of
                #{destroyed := true} -> ok;
                #{reading := Reading} ->
                    buoy_stream_base:emit_read(Stream, Data),
                    case Reading of
                        true -> put_h2(This, buoy_h2:consume_stream(h2(This), Id, byte_size(Data)));
                        false -> update_stream(Stream, fun(St) -> St#{paused_consumed => maps:get(paused_consumed, St) + byte_size(Data)} end)
                    end
            end
    end,
    ok;
on(This, {stream_close, Id, Code}) ->
    case find_stream(This, Id) of
        undefined -> ok;
        Stream ->
            case stream(Stream) of
                #{destroyed := true} -> ok;
                _ ->
                    update_stream(Stream, fun(St) -> St#{closed => true, code => Code} end),
                    Answer = call_stream_callback(Stream, stream_close, [Code]),
                    case Answer of
                        false -> destroy_stream(Stream);
                        _ -> ok
                    end
            end
    end,
    ok;
on(This, {invalid_frame, _F, Lib}) ->
    S = session(This),
    N = maps:get(invalid_frames, S),
    update(This, fun(St) -> St#{invalid_frames => N + 1} end),
    case N > uint32(maps:get(fields, S), 4) of
        true ->
            update(This, fun(St) -> St#{custom_error => <<"ERR_HTTP2_TOO_MANY_INVALID_FRAMES">>} end),
            {fatal, ?ERR_CALLBACK_FAILURE};
        false ->
            Fatal = Lib =< -900,
            case Fatal orelse lists:member(Lib, [-510, -524, -505]) of
                true -> call_session(This, error, [Lib]);
                false -> ok
            end,
            0
    end;
on(This, {frame_not_sent, #{type := Type, stream_id := Id}, Lib}) ->
    Ignored = lists:member(Lib, [-530, -510, -511]),
    case Ignored andalso Type =/= 7 of
        true -> ok;
        false -> call_session(This, frame_error, [Id, Type, translate_error(Lib)])
    end,
    0;
on(_, {frame_sent, _}) ->
    0;
on(This, {error, -536, _}) ->
    call_session(This, error, [?ERR_PROTO]),
    0;
on(_, {error, _, _}) ->
    0;
on(This, {read_data, Id, Max}) ->
    read_data(This, Id, Max);
on(This, {select_padding, Len, Max}) ->
    case maps:get(padding, session(This)) of
        2 -> Max;
        1 ->
            case (Len + 9) rem 8 of
                0 -> Len;
                R -> min(Max, Len + 8 - R)
            end;
        _ -> Len
    end.

uint32(Fields, Offset) ->
    lists:sum([trunc(buoy_heap:get(Fields, Offset + I)) bsl (8 * I) || I <- lists:seq(0, 3)]).

translate_error(-510) -> 5;
translate_error(-523) -> 9;
translate_error(-522) -> 6;
translate_error(-524) -> 3;
translate_error(-533) -> 7;
translate_error(L) when L =:= -505; L =:= -531; L =:= -532 -> 1;
translate_error(_) -> 2.

frame_received(This, 0, #{stream_id := Id, flags := Flags, length := Len}) ->
    case find_stream(This, Id) of
        Stream when Stream =/= undefined, Flags band 1 =/= 0 ->
            case stream(Stream) of
                #{destroyed := false} -> buoy_stream_base:emit_read(Stream, eof);
                _ -> ok
            end;
        _ when Len =:= 0 ->
            %% HandleDataFrame: a flood of empty frames without END_STREAM
            %% fails the session.
            S = session(This),
            N = maps:get(invalid_frames, S),
            update(This, fun(St) -> St#{invalid_frames => N + 1} end),
            case N > uint32(maps:get(fields, S), 4) of
                true ->
                    update(This, fun(St) -> St#{custom_error => <<"ERR_HTTP2_TOO_MANY_INVALID_FRAMES">>} end),
                    fatal;
                false ->
                    ok
            end;
        _ ->
            ok
    end;
frame_received(This, Type, #{flags := Flags} = F) when Type =:= 1; Type =:= 5 ->
    Id = maps:get(promised_stream_id, F, maps:get(stream_id, F)),
    case find_stream(This, Id) of
        undefined -> ok;
        Stream ->
            case stream(Stream) of
                #{destroyed := true} -> ok;
                #{headers := Headers, cat := Cat} ->
                    update_stream(Stream, fun(St) -> St#{headers => [], headers_length => 0} end),
                    List = lists:append([[N, V] || {N, V, _} <- lists:reverse(Headers)]),
                    Sensitive = [N || {N, _, true} <- lists:reverse(Headers)],
                    call_session(This, headers, [Stream, Id, Cat, Flags, buoy_heap:new_array(List),
                                                 buoy_heap:new_array(Sensitive)])
            end
    end;
frame_received(This, 2, #{stream_id := Id, pri := {Dep, Weight, E}}) ->
    case buoy_heap:get(maps:get(fields, session(This)), ?K_PRIORITY_LISTENER_COUNT) of
        0 -> ok;
        _ -> call_session(This, priority, [Id, Dep, Weight, E =:= 1])
    end;
frame_received(This, 4, #{flags := Flags} = F) ->
    Fields = maps:get(fields, session(This)),
    Bits = trunc(buoy_heap:get(Fields, ?K_BITFIELD)),
    case Flags band 1 of
        0 ->
            buoy_heap:set(Fields, ?K_BITFIELD, Bits band bnot (1 bsl ?K_REMOTE_SETTINGS_IS_UP_TO_DATE)),
            Entries = maps:get(settings, F, []),
            update(This, fun(S) ->
                S#{remote_custom => [case lists:keyfind(Id, 1, Entries) of
                                         {_, V} when Id > 8 -> {Id, V};
                                         _ -> {Id, Old}
                                     end || {Id, Old} <- maps:get(remote_custom, S)]}
            end),
            case Bits band (1 bsl ?K_HAS_REMOTE_SETTINGS_LISTENERS) of
                0 -> ok;
                _ -> call_session(This, settings, [])
            end;
        _ ->
            case maps:get(settings, session(This)) of
                [{Callback, Start} | Rest] ->
                    update(This, fun(S) -> S#{settings => Rest} end),
                    settings_done(Callback, Start, true);
                [] ->
                    call_session(This, error, [?ERR_PROTO])
            end
    end;
frame_received(This, 6, #{flags := Flags, opaque_data := Payload}) ->
    case Flags band 1 of
        1 ->
            case maps:get(pings, session(This)) of
                [{Callback, Start} | Rest] ->
                    update(This, fun(S) -> S#{pings => Rest} end),
                    ping_done(Callback, Start, true, Payload);
                [] ->
                    call_session(This, error, [?ERR_PROTO])
            end;
        0 ->
            Bits = trunc(buoy_heap:get(maps:get(fields, session(This)), ?K_BITFIELD)),
            case Bits band (1 bsl ?K_HAS_PING_LISTENERS) of
                0 -> ok;
                _ -> call_session(This, ping, [buoy_node_encoding:new_buffer(Payload)])
            end
    end;
frame_received(This, 7, #{error_code := Code, last_stream_id := Last, opaque_data := Data}) ->
    Buf = case Data of
        <<>> -> undefined;
        _ -> buoy_node_encoding:new_buffer(Data)
    end,
    call_session(This, goaway_data, [Code, Last, Buf]);
frame_received(This, 10, #{stream_id := Id, origin := Origin, field_value := Value}) ->
    Bits = trunc(buoy_heap:get(maps:get(fields, session(This)), ?K_BITFIELD)),
    case Bits band (1 bsl ?K_HAS_ALTSVC_LISTENERS) of
        0 -> ok;
        _ -> call_session(This, altsvc, [Id, Origin, Value])
    end;
frame_received(This, 12, #{origins := Origins}) ->
    call_session(This, origin, [buoy_heap:new_array(Origins)]);
frame_received(_, _, _) ->
    ok.

%% The JavaScript callback Name, with the session handle as this.
call_session(This, Name, Args) ->
    case maps:get(Name, erlang:get(?CALLBACKS), undefined) of
        undefined -> undefined;
        F -> buoy_heap:call(F, This, Args)
    end.

call_stream_callback(Stream, Name, Args) ->
    case maps:get(Name, erlang:get(?CALLBACKS), undefined) of
        undefined -> undefined;
        F -> buoy_heap:call(F, Stream, Args)
    end.

%% Provider::Stream::OnRead: the next bytes of the stream's body, with
%% the write requests that they finish.
read_data(This, Id, Max) ->
    case find_stream(This, Id) of
        undefined ->
            {<<>>, true, false};
        Stream ->
            St0 = stream(Stream),
            %% Empty writes finish at once.
            {Empty, Queue0} = lists:splitwith(fun({B, _}) -> B =:= <<>> end, maps:get(queue, St0)),
            update_stream(Stream, fun(St) -> St#{queue => Queue0} end),
            [buoy_stream_base:done(Req, 0, Stream) || {_, Req} <- Empty, Req =/= undefined],
            St = stream(Stream),
            Available = maps:get(available, St),
            Writable = maps:get(writable, St),
            case {Available, Writable} of
                {0, true} ->
                    deferred;
                {0, false} ->
                    case maps:get(has_trailers, St) of
                        true ->
                            update_stream(Stream, fun(S) -> S#{has_trailers => false} end),
                            call_stream_callback(Stream, stream_trailers, []),
                            {<<>>, true, true};
                        false ->
                            {<<>>, true, false}
                    end;
                _ ->
                    Amount = min(Available, Max),
                    {Bytes, Done, Rest} = take(maps:get(queue, St), Amount, [], []),
                    update_stream(Stream, fun(S) -> S#{queue => Rest, available => Available - Amount} end),
                    update(This, fun(S) -> S#{outgoing => [{Req, Stream} || Req <- Done] ++ maps:get(outgoing, S)} end),
                    St2 = stream(Stream),
                    case maps:get(available, St2) =:= 0 andalso not maps:get(writable, St2) of
                        true ->
                            case maps:get(has_trailers, St2) of
                                true ->
                                    update_stream(Stream, fun(S) -> S#{has_trailers => false} end),
                                    call_stream_callback(Stream, stream_trailers, []),
                                    {Bytes, true, true};
                                false ->
                                    {Bytes, true, false}
                            end;
                        false ->
                            {Bytes, false, false}
                    end
            end
    end.

%% Amount bytes off the front of the queue, and the requests that they end.
%% The bytes stay one part per write, as OnSendData hands each on.
take(Queue, 0, Acc, Done) ->
    {lists:reverse(Acc), lists:reverse(Done), Queue};
take([{B, Req} | Rest], N, Acc, Done) when byte_size(B) =< N ->
    Done1 = case Req of undefined -> Done; _ -> [Req | Done] end,
    take(Rest, N - byte_size(B), [B | Acc], Done1);
take([{B, Req} | Rest], N, Acc, Done) ->
    <<Part:N/binary, Left/binary>> = B,
    take([{Left, Req} | Rest], 0, [Part | Acc], Done);
take([], _, Acc, Done) ->
    {lists:reverse(Acc), lists:reverse(Done), []}.

%%% Http2Stream

stream_class() ->
    Class = buoy_node:constructor(<<"Http2Stream">>, 0, fun(_, _) -> undefined end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    A = fun buoy_node:arg/2,
    methods(Proto, ?STREAM, [
        {<<"id">>, fun(This, _) -> maps:get(id, stream(This)) end},
        {<<"destroy">>, fun(This, _) -> destroy_stream(This), undefined end},
        {<<"priority">>, fun(This, Args) -> stream_priority(This, A(1, Args), A(2, Args), A(3, Args), A(4, Args)) end},
        {<<"pushPromise">>, fun(This, Args) -> push_promise(This, A(1, Args), A(2, Args)) end},
        {<<"info">>, fun(This, Args) -> submit(This, fun(H, Id) -> buoy_h2:submit_headers(H, Id, headers(A(1, Args))) end) end},
        {<<"trailers">>, fun(This, Args) -> trailers(This, headers(A(1, Args))) end},
        {<<"respond">>, fun(This, Args) -> respond(This, headers(A(1, Args)), to_int(A(2, Args))) end},
        {<<"rstStream">>, fun(This, Args) -> rst_stream(This, to_uint(A(1, Args))), undefined end},
        {<<"refreshState">>, fun(This, _) ->
            #{stream_state := Buf} = erlang:get(?STATE),
            #{session := Session, id := Id} = stream(This),
            [buoy_heap:set(Buf, I, V) || {I, V} <- lists:enumerate(0, buoy_h2:stream_state(h2(Session), Id))],
            undefined
        end}]),
    async_methods(Proto, ?STREAM, <<"HTTP2STREAM">>),
    buoy_stream_base:methods(Proto, #{
        write => fun(This, Req, Chunks) -> stream_write(This, Req, Chunks) end,
        shutdown => fun(This, _Req) -> stream_shutdown(This) end,
        read_start => fun(This) -> stream_read_start(This) end,
        read_stop => fun(This) ->
            update_stream(This, fun(S) -> S#{reading => false} end),
            0
        end}),
    erlang:put({?MODULE, stream_class}, Class),
    Class.

%% Http2Stream::New: the JavaScript object of a new stream of the session.
new_stream(Session, Id, Cat, Options) ->
    Class = erlang:get({?MODULE, stream_class}),
    Stream = buoy_heap:construct(Class, [], Class),
    Local = buoy_h2:local_settings(h2(Session)),
    State = #{session => Session, id => Id, cat => Cat, destroyed => false, closed => false, code => 0,
              reading => false, writable => true, queue => [], available => 0,
              has_trailers => Options band ?STREAM_OPTION_GET_TRAILERS =/= 0,
              headers => [], headers_length => 0, paused_consumed => 0,
              max_header_length => min(maps:get(max_header_list_size, Local), 16777215),
              async_id => async_id()},
    buoy_heap:private_put(Stream, ?STREAM, State),
    update(Session, fun(S) -> S#{streams => (maps:get(streams, S))#{Id => Stream}} end),
    case Options band ?STREAM_OPTION_EMPTY_PAYLOAD of
        0 -> ok;
        _ -> update_stream(Stream, fun(S) -> S#{writable => false} end)
    end,
    Stream.

stream(This) ->
    case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, ?STREAM) of
        {ok, S} -> S;
        _ -> #{destroyed => true}
    end.

update_stream(This, Fun) ->
    buoy_heap:private_put(This, ?STREAM, Fun(stream(This))).

find_stream(Session, Id) ->
    maps:get(Id, maps:get(streams, session(Session), #{}), undefined).

%% Runs Fun(H, Id) on the stream's session, as a scoped submit.
submit(This, Fun) ->
    case stream(This) of
        #{destroyed := false, session := Session, id := Id} ->
            scoped(Session, fun() ->
                {Ret, H} = Fun(h2(Session), Id),
                put_h2(Session, H),
                Ret
            end);
        _ ->
            undefined
    end.

respond(This, Fields, Options) ->
    case Options band ?STREAM_OPTION_GET_TRAILERS of
        0 -> ok;
        _ -> update_stream(This, fun(S) -> S#{has_trailers => true} end)
    end,
    HasData = maps:get(writable, stream(This)) andalso Options band ?STREAM_OPTION_EMPTY_PAYLOAD =:= 0,
    submit(This, fun(H, Id) -> buoy_h2:submit_response(H, Id, Fields, HasData) end).

%% Http2Stream::SubmitTrailers: no fields end the stream with an empty DATA.
trailers(This, []) ->
    submit(This, fun(H, Id) -> buoy_h2:submit_data(H, Id, true) end);
trailers(This, Fields) ->
    submit(This, fun(H, Id) -> buoy_h2:submit_trailer(H, Id, Fields) end).

stream_priority(This, Parent, Weight, Exclusive, Silent) ->
    case priority(Parent, Weight, Exclusive) of
        none -> ok;
        Pri ->
            submit(This, fun(H, Id) ->
                case Silent of
                    true -> buoy_h2:change_stream_priority(H, Id, Pri);
                    _ -> buoy_h2:submit_priority(H, Id, Pri)
                end
            end)
    end,
    undefined.

push_promise(This, Headers, Options) ->
    #{session := Session} = stream(This),
    case submit(This, fun(H, Id) -> buoy_h2:submit_push_promise(H, Id, headers(Headers)) end) of
        Ret when is_integer(Ret), Ret > 0 -> new_stream(Session, Ret, 3, to_int(Options));
        Ret -> Ret
    end.

%% Http2Stream::SubmitRstStream: the data that is pending goes out first.
rst_stream(This, Code) ->
    case stream(This) of
        #{destroyed := false, session := Session, id := Id} ->
            update_stream(This, fun(S) -> S#{code => Code} end),
            case maps:get(in_scope, session(Session)) andalso Code =:= 8 of
                true ->
                    update(Session, fun(S) -> S#{pending_rst => maps:get(pending_rst, S) ++ [Id]} end);
                false ->
                    case send_pending(Session) of
                        0 -> flush_rst(Session, Id);
                        _ -> update(Session, fun(S) -> S#{pending_rst => maps:get(pending_rst, S) ++ [Id]} end)
                    end
            end;
        _ ->
            ok
    end.

flush_rst(Session, Id) ->
    case find_stream(Session, Id) of
        undefined -> ok;
        Stream ->
            case stream(Stream) of
                #{destroyed := false, code := Code} ->
                    scoped(Session, fun() ->
                        {_, H} = buoy_h2:submit_rst_stream(h2(Session), Id, Code),
                        put_h2(Session, H)
                    end);
                _ -> ok
            end
    end.

%% Http2Stream::Destroy: the stream leaves the session, and its pending
%% writes fail on the next turn of the loop.
destroy_stream(This) ->
    case stream(This) of
        #{destroyed := false, session := Session, id := Id} ->
            case lists:member(Id, maps:get(pending_rst, session(Session))) of
                true -> flush_rst(Session, Id);
                false -> ok
            end,
            update_stream(This, fun(S) -> S#{destroyed => true} end),
            update(Session, fun(S) -> S#{streams => maps:remove(Id, maps:get(streams, S))} end),
            buoy_node_loop:set_immediate(fun() ->
                Queue = maps:get(queue, stream(This)),
                update_stream(This, fun(S) -> S#{queue => [], available => 0} end),
                [buoy_stream_base:done(Req, ?UV_ECANCELED, This) || {_, Req} <- Queue, Req =/= undefined]
            end);
        _ ->
            ok
    end.

%% Http2Stream::DoWrite: the chunks queue as the stream's body.
stream_write(This, Req, Chunks) ->
    case stream(This) of
        #{destroyed := false, writable := true, session := Session, id := Id} ->
            Items = case [iolist_to_binary([C]) || C <- Chunks] of
                [] -> [{<<>>, Req}];
                Bins -> [{B, undefined} || B <- lists:droplast(Bins)] ++ [{lists:last(Bins), Req}]
            end,
            Size = lists:sum([byte_size(B) || {B, _} <- Items]),
            update_stream(This, fun(S) -> S#{queue => maps:get(queue, S) ++ Items, available => maps:get(available, S) + Size} end),
            scoped(Session, fun() -> put_h2(Session, buoy_h2:resume_data(h2(Session), Id)) end),
            0;
        _ ->
            ?UV_EOF
    end.

%% Http2Stream::DoShutdown: the end of the body, at once.
stream_shutdown(This) ->
    case stream(This) of
        #{destroyed := false, session := Session, id := Id} ->
            update_stream(This, fun(S) -> S#{writable => false} end),
            scoped(Session, fun() -> put_h2(Session, buoy_h2:resume_data(h2(Session), Id)) end),
            1;
        _ ->
            -32
    end.

stream_read_start(This) ->
    case stream(This) of
        #{destroyed := false, session := Session, id := Id, paused_consumed := N} ->
            update_stream(This, fun(S) -> S#{reading => true, paused_consumed => 0} end),
            scoped(Session, fun() -> put_h2(Session, buoy_h2:consume_stream(h2(Session), Id, N)) end),
            0;
        _ ->
            0
    end.

%%% Helpers

%% Methods of a FunctionTemplate with a signature.
methods(Proto, Slot, Methods) ->
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, fun(This, Args) ->
                                         case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, Slot) of
                                             {ok, _} -> Fun(This, Args);
                                             _ -> buoy_heap:throw_error('TypeError', <<"Illegal invocation">>)
                                         end
                                     end),
                                     writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    ok.

async_methods(Proto, Slot, Provider) ->
    methods(Proto, Slot, [
        {<<"getAsyncId">>, fun(This, _) ->
            case buoy_heap:private_find(This, Slot) of
                {ok, #{async_id := Id}} -> Id;
                _ -> -1
            end
        end},
        {<<"getProviderType">>, fun(_, _) ->
            buoy_heap:get(buoy_heap:get(buoy_node:binding(<<"async_wrap">>), <<"Providers">>), Provider)
        end},
        {<<"asyncReset">>, fun(_, _) -> undefined end},
        {<<"getAsyncContextFrameForDebuggingOnly">>, fun(_, _) -> undefined end}]).

async_id() ->
    Fields = buoy_heap:get(buoy_node:binding(<<"async_wrap">>), <<"async_id_fields">>),
    Id = buoy_heap:get(Fields, 2) + 1,
    buoy_heap:set(Fields, 2, Id),
    Id.

to_int(V) when is_integer(V) -> V;
to_int(V) when is_float(V), V == V -> trunc(V);
to_int(V) ->
    case buoy_ref:to_number(V) of
        N when is_integer(N) -> N;
        N when is_float(N), N == N, abs(N) < 1.0e18 -> trunc(N);
        _ -> 0
    end.

to_uint(V) -> to_int(V) band 16#FFFFFFFF.

hrtime() -> erlang:monotonic_time(nanosecond).
