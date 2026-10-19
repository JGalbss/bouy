%% An HTTP/2 session with the semantics of nghttp2 1.68.1, the library that
%% Node 25.9.0 bundles: lib/nghttp2_session.c, nghttp2_frame.c, and the
%% messaging rules of nghttp2_http.c, with the options that
%% node_http2.cc sets (no closed streams kept, no automatic WINDOW_UPDATE,
%% ALTSVC and ORIGIN received by clients).
%%
%% The session is a value. mem_recv/3 takes bytes from the peer and
%% mem_send/2 returns the bytes to write, and both call the callback fun of
%% the session for each event that nghttp2 reports to node_http2.cc. A
%% callback runs JavaScript, which may submit more frames on the same
%% session, so the fun takes the session and returns it: {Reply, Session}.
%%
%% Bun implements HTTP/2 itself in src/runtime/api/bun/h2_frame_parser.rs
%% under its own node:http2. Buoy runs Node's lib/internal/http2, so this
%% keeps nghttp2's frame handling, error codes, and flow control instead.
-module(buoy_h2).

-export([new/3, mem_recv/2, mem_send/1, want_read/1, want_write/1]).
-export([submit_settings/2, submit_ping/2, submit_goaway/4, terminate_session/2, submit_request/4,
         submit_response/4, submit_headers/3, submit_trailer/3, submit_data/3, submit_rst_stream/3,
         submit_priority/3, submit_push_promise/3, submit_altsvc/4, submit_origin/2, resume_data/2,
         consume_connection/2, consume_stream/3, set_next_stream_id/2, set_local_window_size/2,
         change_stream_priority/3, set_callback/2]).
-export([session_state/1, stream_state/2, local_settings/1, remote_settings/1, find_stream/2,
         is_server/1, last_proc_stream_id/1, strerror/1, pack_settings/1]).

-export_type([session/0]).

-define(DATA, 0).
-define(HEADERS, 1).
-define(PRIORITY, 2).
-define(RST_STREAM, 3).
-define(SETTINGS, 4).
-define(PUSH_PROMISE, 5).
-define(PING, 6).
-define(GOAWAY, 7).
-define(WINDOW_UPDATE, 8).
-define(CONTINUATION, 9).
-define(ALTSVC, 10).
-define(ORIGIN, 12).

-define(FLAG_END_STREAM, 16#1).
-define(FLAG_ACK, 16#1).
-define(FLAG_END_HEADERS, 16#4).
-define(FLAG_PADDED, 16#8).
-define(FLAG_PRIORITY, 16#20).

-define(NO_ERROR, 0).
-define(PROTOCOL_ERROR, 1).
-define(INTERNAL_ERROR, 2).
-define(FLOW_CONTROL_ERROR, 3).
-define(STREAM_CLOSED, 5).
-define(FRAME_SIZE_ERROR, 6).
-define(REFUSED_STREAM, 7).
-define(CANCEL, 8).
-define(COMPRESSION_ERROR, 9).

-define(ERR_INVALID_ARGUMENT, -501).
-define(ERR_PROTO, -505).
-define(ERR_DEFERRED, -508).
-define(ERR_STREAM_ID_NOT_AVAILABLE, -509).
-define(ERR_STREAM_CLOSED, -510).
-define(ERR_STREAM_CLOSING, -511).
-define(ERR_STREAM_SHUT_WR, -512).
-define(ERR_INVALID_STREAM_ID, -513).
-define(ERR_INVALID_STREAM_STATE, -514).
-define(ERR_START_STREAM_NOT_ALLOWED, -516).
-define(ERR_INVALID_STATE, -519).
-define(ERR_FRAME_SIZE_ERROR, -522).
-define(ERR_HEADER_COMP, -523).
-define(ERR_FLOW_CONTROL, -524).
-define(ERR_PUSH_DISABLED, -528).
-define(ERR_DATA_EXIST, -529).
-define(ERR_SESSION_CLOSING, -530).
-define(ERR_HTTP_HEADER, -531).
-define(ERR_HTTP_MESSAGING, -532).
-define(ERR_REFUSED_STREAM, -533).
-define(ERR_SETTINGS_EXPECTED, -536).
-define(ERR_TOO_MANY_SETTINGS, -537).
-define(ERR_BAD_CLIENT_MAGIC, -903).
-define(ERR_FLOODED, -904).
%% NGHTTP2_DEFAULT_MAX_OBQ_FLOOD_ITEM, which Node does not change.
-define(MAX_OUTBOUND_ACK, 1000).

-define(MAGIC, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>).
-define(MAX_WINDOW, 16#7FFFFFFF).
-define(INITIAL_WINDOW, 65535).
-define(MAX_STREAM_ID, 16#7FFFFFFF).
-define(UNLIMITED, 16#FFFFFFFF).

-define(DEFAULT_WEIGHT, 16).
-define(MAX_PADLEN, 256).
-define(MAX_PAYLOADLEN, 16384).

%% Headers categories of nghttp2_headers_category.
-define(HCAT_REQUEST, 0).
-define(HCAT_RESPONSE, 1).
-define(HCAT_PUSH_RESPONSE, 2).
-define(HCAT_HEADERS, 3).

-record(stream, {id :: pos_integer(),
                 %% idle | initial | opening | opened | reserved | closing
                 state = initial :: atom(),
                 shut_rd = false :: boolean(),
                 shut_wr = false :: boolean(),
                 %% The window that the peer may send into, and what it sent.
                 local_window :: integer(),
                 recv_window = 0 :: integer(),
                 consumed = 0 :: integer(),
                 window_update_queued = false :: boolean(),
                 %% The window that we may send into.
                 remote_window :: integer(),
                 %% none | active | deferred: the provider of DATA frames.
                 data = none :: none | active | deferred,
                 data_end_stream = true :: boolean(),
                 weight = 16 :: pos_integer(),
                 dep = 0 :: non_neg_integer(),
                 sum_dep_weight = 0 :: non_neg_integer(),
                 %% The messaging state of nghttp2_http.c.
                 http = #{} :: map(),
                 incoming :: boolean(),
                 %% Whether the stream counts against the concurrent streams.
                 counted = false :: boolean()}).

-record(h2, {server :: boolean(),
             cb :: fun((term(), term()) -> {term(), term()}),
             inbound = head :: magic | first_settings | head | ign_all,
             magic_left = <<>> :: binary(),
             buf = <<>> :: binary(),
             %% The DATA frame whose end waits, after a data_chunk callback
             %% paused the receive (NGHTTP2_ERR_PAUSE).
             paused = none :: none | map(),
             %% A header block that CONTINUATION frames continue:
             %% {Frame, StreamId, BlockSoFar}.
             cont = none :: none | {map(), non_neg_integer(), iodata()},
             local = #{} :: map(),
             remote = #{} :: map(),
             remote_settings_received = false :: boolean(),
             inflight = [] :: [[{non_neg_integer(), non_neg_integer()}]],
             pending_max_concurrent = ?UNLIMITED :: non_neg_integer(),
             pending_enable_push = 1 :: 0 | 1,
             enc :: term(),
             dec :: term(),
             streams = #{} :: #{pos_integer() => #stream{}},
             next_stream_id :: pos_integer(),
             last_recv_stream_id = 0 :: non_neg_integer(),
             last_proc_stream_id = 0 :: non_neg_integer(),
             %% Connection flow control.
             remote_window = ?INITIAL_WINDOW :: integer(),
             local_window = ?INITIAL_WINDOW :: integer(),
             recv_window = 0 :: integer(),
             %% How far set_local_window_size shrank the window (recv_reduction).
             recv_reduction = 0 :: integer(),
             consumed = 0 :: integer(),
             window_update_queued = false :: boolean(),
             goaway_sent = false :: boolean(),
             goaway_recv = false :: boolean(),
             goaway_term = none :: none | queued | sent,
             local_last_stream_id = ?MAX_STREAM_ID :: non_neg_integer(),
             remote_last_stream_id = ?MAX_STREAM_ID :: non_neg_integer(),
             ob_urgent = [] :: list(),
             ob_reg = [] :: list(),
             ob_syn = [] :: list(),
             %% The streams with DATA to send, in round-robin order.
             active = [] :: [pos_integer()],
             num_outgoing = 0 :: non_neg_integer(),
             num_incoming = 0 :: non_neg_integer(),
             opts = #{} :: map(),
             preface_sent = false :: boolean(),
             %% The PING and SETTINGS ACKs in the queue (obq_flood_counter_).
             obq_flood = 0 :: non_neg_integer()}).

-opaque session() :: #h2{}.

%%% Creating a session

%% A session of Type, server or client, with nghttp2's options: Opts may
%% hold max_deflate_dynamic_table_size, max_reserved_remote_streams,
%% max_send_header_block_length, peer_max_concurrent_streams, max_settings,
%% and strict_ws (RFC 9113 whitespace checks).
-spec new(server | client, map(), fun((term(), term()) -> {term(), term()})) -> session().
new(Type, Opts, Cb) ->
    Server = Type =:= server,
    Defaults = #{header_table_size => 4096, enable_push => 1, max_concurrent_streams => ?UNLIMITED,
                 initial_window_size => ?INITIAL_WINDOW, max_frame_size => 16384,
                 max_header_list_size => ?UNLIMITED, enable_connect_protocol => 0},
    Remote = Defaults#{max_concurrent_streams => maps:get(peer_max_concurrent_streams, Opts, 100)},
    #h2{server = Server, cb = Cb,
        inbound = case Server of true -> magic; false -> first_settings end,
        magic_left = ?MAGIC,
        local = Defaults, remote = Remote,
        enc = buoy_hpack:new(min(4096, maps:get(max_deflate_dynamic_table_size, Opts, 4096))),
        dec = buoy_hpack:new(4096),
        next_stream_id = case Server of true -> 2; false -> 1 end,
        opts = Opts}.

-spec set_callback(session(), fun((term(), term()) -> {term(), term()})) -> session().
set_callback(H, Cb) -> H#h2{cb = Cb}.

-spec is_server(session()) -> boolean().
is_server(#h2{server = S}) -> S.

%%% Receiving

%% nghttp2_session_mem_recv2: {ok, Session}, or {Error, Session} with the
%% negative error code of nghttp2 when the session must end.
%% A data_chunk callback that answers pause stops the receive after that
%% chunk, as NGHTTP2_ERR_PAUSE does: mem_recv returns paused and keeps the
%% rest, and the next mem_recv, with more bytes or none, goes on with the
%% end of that frame.
-spec mem_recv(session(), binary()) -> {ok | paused | integer(), session()}.
mem_recv(H, Data) ->
    case want_read(H) of
        false -> {ok, H};
        true ->
            try
                recv(resume(H#h2{buf = <<(H#h2.buf)/binary, Data/binary>>}))
            catch
                throw:{?MODULE, fatal, Code, H1} -> {Code, H1#h2{inbound = ign_all, buf = <<>>}}
            end
    end.

recv(#h2{inbound = ign_all} = H) ->
    {ok, H#h2{buf = <<>>}};
recv(#h2{inbound = magic, magic_left = Left, buf = Buf} = H) ->
    N = min(byte_size(Left), byte_size(Buf)),
    <<Want:N/binary, LeftRest/binary>> = Left,
    case Buf of
        <<Want:N/binary, Rest/binary>> when LeftRest =:= <<>> -> recv(H#h2{inbound = first_settings, buf = Rest, magic_left = <<>>});
        <<Want:N/binary, Rest/binary>> -> {ok, H#h2{magic_left = LeftRest, buf = Rest}};
        _ -> {?ERR_BAD_CLIENT_MAGIC, H#h2{buf = <<>>}}
    end;
recv(#h2{inbound = first_settings, buf = <<_:24, Type:8, Flags:8, _/binary>>} = H)
  when Type =/= ?SETTINGS; Flags band ?FLAG_ACK =/= 0 ->
    {_, H1} = cb({error, ?ERR_SETTINGS_EXPECTED,
                  <<"Remote peer returned unexpected data while we expected SETTINGS frame.  Perhaps, peer does not "
                    "support HTTP/2 properly.">>}, H),
    {ok, terminate(H1#h2{buf = <<>>}, ?PROTOCOL_ERROR, <<"SETTINGS expected">>)};
recv(#h2{inbound = first_settings, buf = <<_:9/binary, _/binary>>} = H) ->
    recv(H#h2{inbound = head});
recv(#h2{inbound = first_settings} = H) ->
    {ok, H};
recv(#h2{buf = <<Len:24, _:8, _:8, _:1, _:31, _/binary>>, local = #{max_frame_size := Max}} = H) when Len > Max ->
    {ok, terminate(H#h2{buf = <<>>}, ?FRAME_SIZE_ERROR, <<"too large frame size">>)};
recv(#h2{buf = <<Len:24, Type:8, Flags:8, _:1, Id:31, Payload:Len/binary, Rest/binary>>} = H) ->
    Frame = #{type => Type, flags => Flags, stream_id => Id, length => Len},
    case frame(Frame, Payload, H#h2{buf = Rest}) of
        #h2{paused = none} = H1 -> recv(H1);
        H1 -> {paused, H1}
    end;
recv(H) ->
    {ok, H}.

resume(#h2{paused = none} = H) -> H;
resume(#h2{paused = F} = H) -> on_data_received(F, H#h2{paused = none}).

%% A complete frame. A header block in progress takes only its CONTINUATION.
frame(#{type := ?CONTINUATION, stream_id := Id} = F, Payload, #h2{cont = {First, Id, Block}} = H) ->
    Block1 = [Block, Payload],
    case maps:get(flags, F) band ?FLAG_END_HEADERS of
        0 -> H#h2{cont = {First, Id, Block1}};
        _ -> header_block(First, iolist_to_binary(Block1), H#h2{cont = none})
    end;
frame(F, _, #h2{cont = {_, _, _}} = H) ->
    invalid_connection(F, ?ERR_PROTO, <<"unexpected non-CONTINUATION frame or stream_id is invalid">>, H#h2{cont = none});
frame(#{type := ?DATA} = F, Payload, H) -> recv_data(F, Payload, H);
frame(#{type := ?HEADERS} = F, Payload, H) -> recv_headers(F, Payload, H);
frame(#{type := ?PRIORITY} = F, Payload, H) -> recv_priority(F, Payload, H);
frame(#{type := ?RST_STREAM} = F, Payload, H) -> recv_rst_stream(F, Payload, H);
frame(#{type := ?SETTINGS} = F, Payload, H) -> recv_settings(F, Payload, H);
frame(#{type := ?PUSH_PROMISE} = F, Payload, H) -> recv_push_promise(F, Payload, H);
frame(#{type := ?PING} = F, Payload, H) -> recv_ping(F, Payload, H);
frame(#{type := ?GOAWAY} = F, Payload, H) -> recv_goaway(F, Payload, H);
frame(#{type := ?WINDOW_UPDATE} = F, Payload, H) -> recv_window_update(F, Payload, H);
frame(#{type := ?CONTINUATION} = F, _, H) ->
    invalid_connection(F, ?ERR_PROTO, <<"CONTINUATION: unexpected">>, H);
frame(#{type := ?ALTSVC} = F, Payload, #h2{server = false} = H) -> recv_altsvc(F, Payload, H);
frame(#{type := ?ORIGIN} = F, Payload, #h2{server = false} = H) -> recv_origin(F, Payload, H);
frame(_, _, H) -> H.

%%% DATA

recv_data(#{stream_id := 0} = F, _, H) ->
    invalid_connection(F, ?ERR_PROTO, <<"DATA: stream_id == 0">>, H);
recv_data(#{stream_id := Id, length := Len, flags := Flags} = F, Payload, H) ->
    case data_fail_fast(Id, H) of
        {fail, Code, Reason} ->
            terminate(H, Code, Reason);
        ignore ->
            %% The payload counts against the connection window, and
            %% nghttp2 consumes it for the application.
            case conn_window(Len, H) of
                {ok, H1} -> consume_connection(H1, Len);
                Terminated -> Terminated
            end;
        ok ->
            case unpad(Flags, Payload) of
                error ->
                    terminate(H, ?PROTOCOL_ERROR, <<"DATA: insufficient padding space">>);
                {ok, Data} ->
                    case conn_window(Len, H) of
                        {ok, H1} -> recv_data_flow(F, Data, Len - byte_size(Data), H1);
                        Terminated -> Terminated
                    end
            end
    end.

%% nghttp2_session_update_recv_stream_window_size: a stream past its window
%% is reset with FLOW_CONTROL_ERROR, and only a connection past its window
%% ends the session. The frame's data still reaches the application.
recv_data_flow(#{stream_id := Id} = F, Data, Padding, H) ->
    S = stream(Id, H),
    {S1, H1} = case S#stream.recv_window + byte_size(Data) + Padding > S#stream.local_window of
        true ->
            {S, add_rst_stream(Id, ?FLOW_CONTROL_ERROR, H)};
        false ->
            Counted = S#stream{recv_window = S#stream.recv_window + byte_size(Data) + Padding},
            {Counted, put_stream(Counted, H)}
    end,
    %% Padding is consumed at once, as nghttp2 does without automatic
    %% WINDOW_UPDATE.
    H2 = case Padding of
        0 -> H1;
        _ -> consume_stream(consume_connection(H1, Padding), Id, Padding)
    end,
    case http_on_data(S1, byte_size(Data)) of
        error ->
            invalid_stream(F, ?ERR_PROTO, H2);
        {ok, Http} ->
            H3 = update_stream(Id, fun(St) -> St#stream{http = Http} end, H2),
            case Data of
                <<>> -> on_data_received(F, H3);
                _ ->
                    case cb({data_chunk, Id, Data, maps:get(flags, F)}, H3) of
                        {pause, H4} -> H4#h2{paused = F};
                        {_, H4} -> on_data_received(F, H4)
                    end
            end
    end.

on_data_received(#{stream_id := Id, flags := Flags} = F, H) ->
    case find(Id, H) of
        #stream{state = closing} -> H;
        #stream{} = S when Flags band ?FLAG_END_STREAM =/= 0 ->
            case http_on_remote_end_stream(S) of
                error ->
                    H1 = add_rst_stream(Id, ?PROTOCOL_ERROR, H),
                    update_stream(Id, fun(St) -> St#stream{shut_rd = true} end, H1);
                ok ->
                    {_, H1} = cb({frame_recv, F}, H),
                    H2 = update_stream(Id, fun(St) -> St#stream{shut_rd = true} end, H1),
                    close_if_shut(Id, H2)
            end;
        #stream{} ->
            element(2, cb({frame_recv, F}, H));
        none ->
            H
    end.

data_fail_fast(Id, H) ->
    case find(Id, H) of
        none ->
            case is_idle(Id, H) of
                true -> {fail, ?PROTOCOL_ERROR, <<"DATA: stream in idle">>};
                false -> ignore
            end;
        #stream{shut_rd = true} ->
            {fail, ?STREAM_CLOSED, <<"DATA: stream in half-closed(remote)">>};
        #stream{state = closing} ->
            ignore;
        #stream{incoming = false, state = State} when State =/= opened ->
            {fail, ?PROTOCOL_ERROR, <<"DATA: stream not opened">>};
        #stream{state = reserved} ->
            {fail, ?PROTOCOL_ERROR, <<"DATA: stream in reserved">>};
        #stream{} ->
            ok
    end.

conn_window(Len, #h2{recv_window = R, local_window = L} = H) ->
    case R + Len > L of
        true -> terminate(H, ?FLOW_CONTROL_ERROR, <<>>);
        false -> {ok, H#h2{recv_window = R + Len}}
    end.

unpad(Flags, Payload) when Flags band ?FLAG_PADDED =:= 0 -> {ok, Payload};
unpad(_, <<Pad, Rest/binary>>) when Pad =< byte_size(Rest) -> {ok, binary:part(Rest, 0, byte_size(Rest) - Pad)};
unpad(_, _) -> error.

%%% HEADERS and PUSH_PROMISE

recv_headers(#{stream_id := 0} = F, _, H) ->
    invalid_connection(F, ?ERR_PROTO, <<"HEADERS: stream_id == 0">>, H);
recv_headers(#{flags := Flags, stream_id := Id} = F, Payload, H) ->
    case unpad(Flags, Payload) of
        error ->
            terminate(H, ?PROTOCOL_ERROR, <<"HEADERS: insufficient padding space">>);
        {ok, Body} ->
            case Flags band ?FLAG_PRIORITY of
                0 ->
                    headers_block(F#{pri => none}, Body, H);
                _ ->
                    case Body of
                        <<E:1, Dep:31, Weight, Block/binary>> when Dep =/= Id ->
                            headers_block(F#{pri => {Dep, Weight + 1, E}}, Block, H);
                        <<_:1, Id:31, _, _/binary>> ->
                            invalid_connection(F, ?ERR_PROTO, <<"HEADERS: stream_id == pri_spec.stream_id">>, H);
                        _ ->
                            terminate(H, ?FRAME_SIZE_ERROR, <<"HEADERS: too short">>)
                    end
            end
    end.

headers_block(#{flags := Flags} = F, Block, H) ->
    case Flags band ?FLAG_END_HEADERS of
        0 -> H#h2{cont = {F, maps:get(stream_id, F), Block}};
        _ -> header_block(F, Block, H)
    end.

recv_push_promise(F, _, #h2{server = true} = H) ->
    invalid_connection(F, ?ERR_PROTO, <<"PUSH_PROMISE: server received">>, H);
recv_push_promise(#{stream_id := 0} = F, _, H) ->
    invalid_connection(F, ?ERR_PROTO, <<"PUSH_PROMISE: stream_id == 0">>, H);
recv_push_promise(F, _, #h2{local = #{enable_push := 0}} = H) ->
    invalid_connection(F, ?ERR_PROTO, <<"PUSH_PROMISE: push disabled">>, H);
recv_push_promise(#{flags := Flags} = F, Payload, H) ->
    case unpad(Flags, Payload) of
        {ok, <<_:1, Promised:31, Block/binary>>} ->
            headers_block(F#{promised_stream_id => Promised}, Block, H);
        _ ->
            terminate(H, ?PROTOCOL_ERROR, <<"PUSH_PROMISE: insufficient padding space">>)
    end.

%% A complete header block of a HEADERS or PUSH_PROMISE frame: classify it,
%% decode it, check it with the rules of HTTP, and report it.
header_block(#{type := ?PUSH_PROMISE} = F, Block, H) ->
    push_promise_block(F, Block, H);
header_block(#{stream_id := Id} = F, Block, H) ->
    case classify_headers(F, H) of
        {connection_error, Lib, Reason} ->
            invalid_connection(F, Lib, Reason, decode_only(Block, H));
        {stream_error, Lib} ->
            case decode(Block, H) of
                {ok, _, H1} -> invalid_stream(F, Lib, H1);
                {error, H1} -> H1
            end;
        {stream_error, Lib, H1} ->
            case decode(Block, H1) of
                {ok, _, H2} -> invalid_stream(F, Lib, H2);
                {error, H2} -> H2
            end;
        ignore ->
            decode_only(Block, H);
        {Cat, H1} ->
            case decode(Block, H1) of
                {error, H2} -> H2;
                {ok, Fields, H2} -> deliver_headers(F#{cat => Cat}, Id, Fields, H2)
            end
    end.

decode_only(Block, H) ->
    case decode(Block, H) of
        {ok, _, H1} -> H1;
        {error, H1} -> H1
    end.

decode(Block, #h2{dec = Dec} = H) ->
    case buoy_hpack:decode(Block, Dec) of
        {ok, Fields, Dec1} -> {ok, Fields, H#h2{dec = Dec1}};
        {error, _} -> {error, terminate(H, ?COMPRESSION_ERROR, <<>>)}
    end.

%% The kind of a received HEADERS frame, as session_on_*_headers_received.
classify_headers(#{stream_id := Id}, #h2{server = Server} = H) ->
    case find(Id, H) of
        none when Server ->
            if
                Id rem 2 =:= 0; Id =< H#h2.last_recv_stream_id ->
                    {connection_error, ?ERR_PROTO, <<"request HEADERS: invalid stream_id">>};
                H#h2.goaway_sent, Id > H#h2.local_last_stream_id ->
                    ignore;
                true ->
                    open_incoming(Id, H)
            end;
        none ->
            case is_idle(Id, H) of
                true -> {connection_error, ?ERR_PROTO, <<"HEADERS: stream in idle">>};
                false -> ignore
            end;
        #stream{shut_rd = true} ->
            {stream_error, ?ERR_STREAM_CLOSED};
        #stream{state = closing} ->
            ignore;
        #stream{incoming = false, state = opening} = S when not Server ->
            {?HCAT_RESPONSE, put_stream(S#stream{state = opened}, H)};
        #stream{state = reserved} = S when not Server ->
            {?HCAT_PUSH_RESPONSE, put_stream(S#stream{state = opened, counted = true}, H#h2{num_incoming = H#h2.num_incoming + 1})};
        #stream{} ->
            {?HCAT_HEADERS, H}
    end.

open_incoming(Id, #h2{local = #{max_concurrent_streams := Max}, num_incoming = N} = H) ->
    H1 = H#h2{last_recv_stream_id = Id},
    case N >= min(Max, H#h2.pending_max_concurrent) of
        true ->
            %% The stream exists only to be refused.
            Code = case N >= Max of true -> ?ERR_PROTO; false -> ?ERR_REFUSED_STREAM end,
            {stream_error, Code, H1};
        false ->
            S = (new_stream(Id, opened, true, H1))#stream{counted = true},
            {?HCAT_REQUEST, put_stream(S, H1#h2{num_incoming = N + 1, last_proc_stream_id = Id})}
    end.

push_promise_block(#{stream_id := Id, promised_stream_id := P} = F, Block, H) ->
    case find(Id, H) of
        _ when P rem 2 =/= 0; P =< H#h2.last_recv_stream_id ->
            invalid_connection(F, ?ERR_PROTO, <<"PUSH_PROMISE: invalid promised_stream_id">>, decode_only(Block, H));
        none ->
            case is_idle(Id, H) of
                true -> invalid_connection(F, ?ERR_PROTO, <<"PUSH_PROMISE: stream in idle">>, decode_only(Block, H));
                false -> decode_only(Block, H#h2{last_recv_stream_id = P})
            end;
        #stream{shut_rd = true} ->
            invalid_connection(F, ?ERR_STREAM_CLOSED, <<"PUSH_PROMISE: stream closed">>,
                               decode_only(Block, H#h2{last_recv_stream_id = P}));
        #stream{} when H#h2.goaway_sent ->
            decode_only(Block, H#h2{last_recv_stream_id = P});
        #stream{} ->
            H1 = H#h2{last_recv_stream_id = P},
            S = (new_stream(P, reserved, true, H1))#stream{shut_wr = true},
            H2 = put_stream(S, H1),
            case decode(Block, H2) of
                {error, H3} -> H3;
                {ok, Fields, H3} -> deliver_headers(F#{cat => ?HCAT_REQUEST}, P, Fields, H3)
            end
    end.

%% on_begin_headers, then on_header for each field that passes the rules,
%% then on_frame_recv; a stream error stops the block.
deliver_headers(F, Id, Fields, H) ->
    case cb({begin_headers, F#{id => Id}}, H) of
        {ok, H1} ->
            header_fields(F, Id, Fields, H1);
        {{rst, Code}, H1} ->
            add_rst_stream(Id, Code, H1);
        {_, H1} ->
            H1
    end.

header_fields(F, Id, [], H) ->
    case find(Id, H) of
        none ->
            H;
        S ->
            %% session_after_header_block_received: a block that breaks the
            %% messaging rules, or ends a stream short of its content-length,
            %% resets the stream before on_frame_recv.
            Ends = maps:get(type, F) =/= ?PUSH_PROMISE andalso maps:get(flags, F) band ?FLAG_END_STREAM =/= 0,
            case http_on_headers_end(F, S) of
                {ok, Http} ->
                    S1 = S#stream{http = Http},
                    case Ends andalso http_on_remote_end_stream(S1) =:= error of
                        false ->
                            end_headers(F, Id, put_stream(S1, H));
                        true ->
                            H1 = invalid_stream(F#{stream_id => Id}, ?ERR_HTTP_MESSAGING, put_stream(S1, H)),
                            update_stream(Id, fun(St) -> St#stream{shut_rd = true} end, H1)
                    end;
                error ->
                    invalid_stream(F#{stream_id => Id}, ?ERR_HTTP_MESSAGING, H)
            end
    end;
header_fields(F, Id, [{Name, Value, NoIndex} | Rest], H) ->
    case find(Id, H) of
        none ->
            H;
        S ->
            case http_on_header(F, S, Name, Value, H) of
                {ok, Http} ->
                    H1 = put_stream(S#stream{http = Http}, H),
                    case cb({header, Id, Name, Value, NoIndex}, H1) of
                        {ok, H2} -> header_fields(F, Id, Rest, H2);
                        {{rst, Code}, H2} -> add_rst_stream(Id, Code, H2);
                        {_, H2} -> H2
                    end;
                ignore ->
                    {_, H1} = cb({invalid_header, Id, Name, Value}, H),
                    header_fields(F, Id, Rest, H1);
                error ->
                    invalid_stream(F#{stream_id => Id}, ?ERR_HTTP_HEADER, H)
            end
    end.

end_headers(#{type := ?PUSH_PROMISE} = F, _Id, H) ->
    element(2, cb({frame_recv, F}, H));
end_headers(#{flags := Flags, stream_id := Id} = F, Id, H) ->
    {_, H1} = cb({frame_recv, F}, H),
    case Flags band ?FLAG_END_STREAM of
        0 -> H1;
        _ ->
            case find(Id, H1) of
                none -> H1;
                S -> close_if_shut(Id, put_stream(S#stream{shut_rd = true}, H1))
            end
    end.

%%% Other frames

recv_priority(#{length := Len} = F, _, H) when Len =/= 5 ->
    invalid_connection(F, ?ERR_FRAME_SIZE_ERROR, <<"PRIORITY: invalid payload length">>, H);
recv_priority(#{stream_id := 0} = F, _, H) ->
    invalid_connection(F, ?ERR_PROTO, <<"PRIORITY: stream_id == 0">>, H);
recv_priority(#{stream_id := Id} = F, <<E:1, Dep:31, W>>, H) ->
    case Dep =:= Id of
        true ->
            invalid_connection(F, ?ERR_PROTO, <<"depend on itself">>, H);
        false ->
            H1 = update_stream(Id, fun(S) -> S#stream{weight = W + 1, dep = Dep} end, H),
            element(2, cb({frame_recv, F#{pri => {Dep, W + 1, E}}}, H1))
    end.

recv_rst_stream(#{length := Len} = F, _, H) when Len =/= 4 ->
    invalid_connection(F, ?ERR_FRAME_SIZE_ERROR, <<"RST_STREAM: invalid payload length">>, H);
recv_rst_stream(#{stream_id := 0} = F, _, H) ->
    invalid_connection(F, ?ERR_PROTO, <<"RST_STREAM: stream_id == 0">>, H);
recv_rst_stream(#{stream_id := Id} = F, <<Code:32>>, H) ->
    case is_idle(Id, H) of
        true ->
            invalid_connection(F, ?ERR_PROTO, <<"RST_STREAM: stream in idle">>, H);
        false ->
            {_, H1} = cb({frame_recv, F#{error_code => Code}}, H),
            close_stream(Id, Code, H1)
    end.

recv_settings(#{length := Len} = F, _, H) when Len rem 6 =/= 0 ->
    invalid_connection(F, ?ERR_FRAME_SIZE_ERROR, <<"SETTINGS: invalid payload length">>, H);
recv_settings(#{stream_id := Id} = F, _, H) when Id =/= 0 ->
    invalid_connection(F, ?ERR_PROTO, <<"SETTINGS: stream_id != 0">>, H);
recv_settings(#{flags := Flags, length := Len} = F, _, H) when Flags band ?FLAG_ACK =/= 0 ->
    case {Len, H#h2.inflight} of
        {0, [Entries | Rest]} ->
            case apply_local_settings(Entries, H#h2{inflight = Rest}) of
                {ok, H1} -> element(2, cb({frame_recv, F}, H1));
                {error, Lib} -> invalid_connection(F, Lib, <<>>, H)
            end;
        {0, []} -> invalid_connection(F, ?ERR_PROTO, <<"SETTINGS: unexpected ACK">>, H);
        _ -> invalid_connection(F, ?ERR_FRAME_SIZE_ERROR, <<"SETTINGS: ACK and payload != 0">>, H)
    end;
recv_settings(_, _, #h2{obq_flood = N} = H) when N >= ?MAX_OUTBOUND_ACK ->
    throw({?MODULE, fatal, ?ERR_FLOODED, H});
recv_settings(F, Payload, H) ->
    Entries = [{Key, Value} || <<Key:16, Value:32>> <= Payload],
    case length(Entries) > maps:get(max_settings, H#h2.opts, 32) of
        true ->
            invalid_connection(F, ?ERR_TOO_MANY_SETTINGS, <<"SETTINGS: too many setting entries">>, H);
        false ->
            H0 = case H#h2.remote_settings_received of
                false -> H#h2{remote = (H#h2.remote)#{max_concurrent_streams => ?UNLIMITED}, remote_settings_received = true};
                true -> H
            end,
            case apply_remote_settings(Entries, H0) of
                {error, Lib, Reason} ->
                    invalid_connection(F, Lib, Reason, H0);
                {ok, H1} ->
                    H2 = case session_closing(H1) of
                        true -> H1;
                        false -> queue(urgent, {settings_ack}, H1#h2{obq_flood = H1#h2.obq_flood + 1})
                    end,
                    element(2, cb({frame_recv, F#{settings => Entries}}, H2))
            end
    end.

apply_remote_settings([], H) ->
    {ok, H};
apply_remote_settings([{Key, Value} | Rest], #h2{remote = R} = H) ->
    case setting_name(Key) of
        header_table_size ->
            apply_remote_settings(Rest, H#h2{remote = R#{header_table_size => Value},
                                             enc = buoy_hpack:set_max(H#h2.enc, min(Value, deflate_max(H)))});
        enable_push when Value > 1 ->
            {error, ?ERR_PROTO, <<"SETTINGS: invalid SETTINGS_ENBLE_PUSH">>};
        enable_push when not H#h2.server, Value =/= 0 ->
            {error, ?ERR_PROTO, <<"SETTINGS: server attempted to enable push">>};
        initial_window_size when Value > ?MAX_WINDOW ->
            {error, ?ERR_FLOW_CONTROL, <<"SETTINGS: too large SETTINGS_INITIAL_WINDOW_SIZE">>};
        initial_window_size ->
            Delta = Value - maps:get(initial_window_size, R),
            Streams = maps:map(fun(_, S) -> S#stream{remote_window = S#stream.remote_window + Delta} end, H#h2.streams),
            case lists:any(fun(S) -> S#stream.remote_window > ?MAX_WINDOW end, maps:values(Streams)) of
                true -> {error, ?ERR_FLOW_CONTROL, <<>>};
                false -> apply_remote_settings(Rest, H#h2{remote = R#{initial_window_size => Value}, streams = Streams})
            end;
        max_frame_size when Value < 16384; Value > 16777215 ->
            {error, ?ERR_PROTO, <<"SETTINGS: invalid SETTINGS_MAX_FRAME_SIZE">>};
        enable_connect_protocol when Value > 1 ->
            {error, ?ERR_PROTO, <<"SETTINGS: invalid SETTINGS_ENABLE_CONNECT_PROTOCOL">>};
        enable_connect_protocol when not H#h2.server, Value =:= 0 ->
            case maps:get(enable_connect_protocol, R) of
                1 -> {error, ?ERR_PROTO, <<"SETTINGS: server attempted to disable SETTINGS_ENABLE_CONNECT_PROTOCOL">>};
                _ -> apply_remote_settings(Rest, H)
            end;
        unknown ->
            apply_remote_settings(Rest, H);
        Name ->
            apply_remote_settings(Rest, H#h2{remote = R#{Name => Value}})
    end.

deflate_max(H) -> maps:get(max_deflate_dynamic_table_size, H#h2.opts, 4096).

apply_local_settings(Entries, #h2{local = L} = H) ->
    lists:foldl(fun
        (_, {error, _} = E) -> E;
        ({Key, Value}, {ok, Acc}) ->
            Local = Acc#h2.local,
            case setting_name(Key) of
                header_table_size ->
                    {ok, Acc#h2{local = Local#{header_table_size => Value}, dec = buoy_hpack:set_decoder_max(Acc#h2.dec, Value)}};
                initial_window_size ->
                    Delta = Value - maps:get(initial_window_size, Local),
                    Streams = maps:map(fun(_, S) -> S#stream{local_window = S#stream.local_window + Delta} end, Acc#h2.streams),
                    {ok, Acc#h2{local = Local#{initial_window_size => Value}, streams = Streams}};
                max_concurrent_streams ->
                    {ok, Acc#h2{local = Local#{max_concurrent_streams => Value}, pending_max_concurrent = ?UNLIMITED}};
                unknown ->
                    {ok, Acc};
                Name ->
                    {ok, Acc#h2{local = Local#{Name => Value}}}
            end
    end, {ok, H#h2{local = L}}, Entries).

setting_name(1) -> header_table_size;
setting_name(2) -> enable_push;
setting_name(3) -> max_concurrent_streams;
setting_name(4) -> initial_window_size;
setting_name(5) -> max_frame_size;
setting_name(6) -> max_header_list_size;
setting_name(8) -> enable_connect_protocol;
setting_name(_) -> unknown.

recv_ping(#{length := Len} = F, _, H) when Len =/= 8 ->
    invalid_connection(F, ?ERR_FRAME_SIZE_ERROR, <<"PING: invalid payload length">>, H);
recv_ping(#{stream_id := Id} = F, _, H) when Id =/= 0 ->
    invalid_connection(F, ?ERR_PROTO, <<"PING: stream_id != 0">>, H);
recv_ping(#{flags := Flags} = F, Payload, H) ->
    H1 = case Flags band ?FLAG_ACK =:= 0 andalso not session_closing(H) of
        true when H#h2.obq_flood >= ?MAX_OUTBOUND_ACK -> throw({?MODULE, fatal, ?ERR_FLOODED, H});
        true -> queue(urgent, {ping, ?FLAG_ACK, Payload}, H#h2{obq_flood = H#h2.obq_flood + 1});
        false -> H
    end,
    element(2, cb({frame_recv, F#{opaque_data => Payload}}, H1)).

recv_goaway(#{stream_id := Id} = F, _, H) when Id =/= 0 ->
    invalid_connection(F, ?ERR_PROTO, <<"GOAWAY: stream_id != 0">>, H);
recv_goaway(#{length := Len} = F, _, H) when Len < 8 ->
    invalid_connection(F, ?ERR_FRAME_SIZE_ERROR, <<"GOAWAY: invalid payload length">>, H);
recv_goaway(F, <<_:1, Last:31, Code:32, Debug/binary>>, H) ->
    Mine = case H#h2.server of true -> 0; false -> 1 end,
    case (Last > 0 andalso Last rem 2 =/= Mine) orelse Last > H#h2.remote_last_stream_id of
        true ->
            invalid_connection(F, ?ERR_PROTO, <<"GOAWAY: invalid last_stream_id">>, H);
        false ->
            H1 = H#h2{goaway_recv = true, remote_last_stream_id = Last},
            {_, H2} = cb({frame_recv, F#{last_stream_id => Last, error_code => Code, opaque_data => Debug}}, H1),
            close_streams_on_goaway(Last, false, H2)
    end.

recv_window_update(#{length := Len} = F, _, H) when Len =/= 4 ->
    invalid_connection(F, ?ERR_FRAME_SIZE_ERROR, <<"WINDOW_UPDATE: invalid payload length">>, H);
recv_window_update(#{stream_id := 0} = F, <<_:1, 0:31>>, H) ->
    invalid_connection(F, ?ERR_PROTO, <<"WINDOW_UPDATE: window_size_increment == 0">>, H);
recv_window_update(#{stream_id := 0} = F, <<_:1, Inc:31>>, #h2{remote_window = W} = H) ->
    case W + Inc > ?MAX_WINDOW of
        true -> invalid_connection(F, ?ERR_FLOW_CONTROL, <<>>, H);
        false -> element(2, cb({frame_recv, F#{increment => Inc}}, H#h2{remote_window = W + Inc}))
    end;
recv_window_update(#{stream_id := Id} = F, <<_:1, Inc:31>>, H) ->
    case find(Id, H) of
        none ->
            case is_idle(Id, H) of
                true -> invalid_connection(F, ?ERR_PROTO, <<"WINDOW_UPDATE to idle stream">>, H);
                false -> H
            end;
        #stream{state = reserved, incoming = true} ->
            invalid_connection(F, ?ERR_PROTO, <<"WINDOW_UPADATE to reserved stream">>, H);
        #stream{} when Inc =:= 0 ->
            invalid_stream(F, ?ERR_PROTO, H);
        #stream{remote_window = W} when W + Inc > ?MAX_WINDOW ->
            invalid_stream(F, ?ERR_FLOW_CONTROL, H);
        #stream{remote_window = W} = S ->
            H1 = put_stream(S#stream{remote_window = W + Inc}, H),
            element(2, cb({frame_recv, F#{increment => Inc}}, H1))
    end.

%% nghttp2_session_on_altsvc_received: a stream's ALTSVC names no origin and
%% a live stream, and the connection's names an origin; both need a value.
recv_altsvc(F, <<OriginLen:16, Origin:OriginLen/binary, Value/binary>>, H) ->
    Id = maps:get(stream_id, F),
    Stream = case Id of 0 -> none; _ -> find(Id, H) end,
    case {Id, Origin, Stream, Value} of
        {0, <<>>, _, _} -> invalid_frame(F, ?ERR_PROTO, H);
        {0, _, _, <<>>} -> invalid_frame(F, ?ERR_PROTO, H);
        {0, _, _, _} -> element(2, cb({frame_recv, F#{origin => Origin, field_value => Value}}, H));
        {_, <<_, _/binary>>, _, _} -> invalid_frame(F, ?ERR_PROTO, H);
        {_, _, none, _} -> H;
        {_, _, #stream{state = closing}, _} -> H;
        {_, _, _, <<>>} -> invalid_frame(F, ?ERR_PROTO, H);
        _ -> element(2, cb({frame_recv, F#{origin => Origin, field_value => Value}}, H))
    end;
recv_altsvc(_, _, H) ->
    H.

invalid_frame(F, Lib, H) -> element(2, cb({invalid_frame, F, Lib}, H)).

recv_origin(#{stream_id := 0, flags := 0} = F, Payload, H) ->
    case origins(Payload, []) of
        error -> H;
        List -> element(2, cb({frame_recv, F#{origins => List}}, H))
    end;
recv_origin(_, _, H) ->
    H.

origins(<<>>, Acc) -> lists:reverse(Acc);
origins(<<Len:16, Origin:Len/binary, Rest/binary>>, Acc) -> origins(Rest, [Origin | Acc]);
origins(_, _) -> error.

%%% Errors

%% session_handle_invalid_connection: the application hears of the frame,
%% and the session ends with a GOAWAY.
invalid_connection(F, Lib, Reason, H) ->
    {_, H1} = cb({invalid_frame, F, Lib}, H),
    terminate(H1, error_code(Lib), Reason).

%% session_handle_invalid_stream2: RST_STREAM for the frame's stream.
invalid_stream(#{stream_id := Id} = F, Lib, H) ->
    {_, H1} = cb({invalid_frame, F, Lib}, H),
    add_rst_stream(Id, error_code(Lib), H1).

error_code(?ERR_STREAM_CLOSED) -> ?STREAM_CLOSED;
error_code(?ERR_HEADER_COMP) -> ?COMPRESSION_ERROR;
error_code(?ERR_FRAME_SIZE_ERROR) -> ?FRAME_SIZE_ERROR;
error_code(?ERR_FLOW_CONTROL) -> ?FLOW_CONTROL_ERROR;
error_code(?ERR_REFUSED_STREAM) -> ?REFUSED_STREAM;
error_code(?ERR_PROTO) -> ?PROTOCOL_ERROR;
error_code(?ERR_HTTP_HEADER) -> ?PROTOCOL_ERROR;
error_code(?ERR_HTTP_MESSAGING) -> ?PROTOCOL_ERROR;
error_code(_) -> ?INTERNAL_ERROR.

%% nghttp2_session_terminate_session_with_reason: a last GOAWAY, after which
%% the session reads nothing.
terminate(#h2{goaway_term = T} = H, _, _) when T =/= none ->
    H#h2{inbound = ign_all, buf = <<>>};
terminate(H, Code, Reason) ->
    H1 = queue(urgent, {goaway, H#h2.last_proc_stream_id, Code, Reason, term}, H),
    H1#h2{inbound = ign_all, buf = <<>>, goaway_term = queued}.

-spec terminate_session(session(), non_neg_integer()) -> session().
terminate_session(H, Code) -> terminate(H, Code, <<>>).

session_closing(#h2{goaway_term = T}) -> T =/= none.

%%% Streams

new_stream(Id, State, Incoming, #h2{local = L, remote = R}) ->
    #stream{id = Id, state = State, incoming = Incoming,
            local_window = maps:get(initial_window_size, L), remote_window = maps:get(initial_window_size, R)}.

find(Id, #h2{streams = Streams}) -> maps:get(Id, Streams, none).

stream(Id, H) -> maps:get(Id, H#h2.streams).

put_stream(#stream{id = Id} = S, H) -> H#h2{streams = (H#h2.streams)#{Id => S}}.

update_stream(Id, Fun, H) ->
    case find(Id, H) of
        none -> H;
        S -> put_stream(Fun(S), H)
    end.

%% An idle stream: one with an id past every stream that either side opened.
is_idle(Id, #h2{server = Server, next_stream_id = Next, last_recv_stream_id = Last}) ->
    Mine = (Id rem 2 =:= 0) =:= Server,
    case Mine of
        true -> Id >= Next;
        false -> Id > Last
    end.

close_if_shut(Id, H) ->
    case find(Id, H) of
        #stream{shut_rd = true, shut_wr = true} -> close_stream(Id, ?NO_ERROR, H);
        _ -> H
    end.

%% nghttp2_session_close_stream: on_stream_close, then the stream is gone.
close_stream(Id, Code, H) ->
    case find(Id, H) of
        none ->
            H;
        S ->
            H1 = H#h2{streams = maps:remove(Id, H#h2.streams), active = lists:delete(Id, H#h2.active),
                      ob_syn = [I || I <- H#h2.ob_syn, element(2, I) =/= Id]},
            H2 = case {S#stream.counted, S#stream.incoming} of
                {false, _} -> H1;
                {true, true} -> H1#h2{num_incoming = max(0, H1#h2.num_incoming - 1)};
                {true, false} -> H1#h2{num_outgoing = max(0, H1#h2.num_outgoing - 1)}
            end,
            element(2, cb({stream_close, Id, Code}, H2))
    end.

close_streams_on_goaway(Last, Incoming, H) ->
    Ids = [Id || {Id, #stream{incoming = In}} <- maps:to_list(H#h2.streams), In =:= Incoming, Id > Last],
    lists:foldl(fun(Id, Acc) -> close_stream(Id, ?REFUSED_STREAM, Acc) end, H, lists:sort(Ids)).

%%% Flow control of received data

%% nghttp2_session_consume_connection.
-spec consume_connection(session(), non_neg_integer()) -> session().
consume_connection(#h2{consumed = C, recv_window = R, local_window = L} = H, N) ->
    C1 = C + N,
    Size = min(C1, R),
    case should_update(L, Size) andalso not H#h2.window_update_queued of
        true -> queue_window_update(0, Size, H#h2{consumed = C1 - Size, recv_window = R - Size});
        false -> H#h2{consumed = C1}
    end.

%% nghttp2_session_consume_stream.
-spec consume_stream(session(), pos_integer(), non_neg_integer()) -> session().
consume_stream(H, Id, N) ->
    case find(Id, H) of
        none ->
            H;
        #stream{consumed = C, recv_window = R, local_window = L} = S ->
            C1 = C + N,
            Size = min(C1, R),
            case should_update(L, Size) andalso not S#stream.window_update_queued andalso not S#stream.shut_rd of
                true -> queue_window_update(Id, Size, put_stream(S#stream{consumed = C1 - Size, recv_window = R - Size}, H));
                false -> put_stream(S#stream{consumed = C1}, H)
            end
    end.

should_update(Local, Size) -> Size > 0 andalso Size >= Local div 2.

%% nghttp2_session_add_window_update: until the frame leaves, the stream or
%% the connection queues no other, so data that the peer sends meanwhile
%% counts against the window that the peer knows.
queue_window_update(0, Inc, H) ->
    queue(reg, {window_update, 0, Inc}, H#h2{window_update_queued = true});
queue_window_update(Id, Inc, H) ->
    queue(reg, {window_update, Id, Inc}, update_stream(Id, fun(S) -> S#stream{window_update_queued = true} end, H)).

%% session_after_frame_sent1 of a WINDOW_UPDATE: another may go now for
%% what was consumed meanwhile.
window_update_sent(0, H) ->
    consume_connection(H#h2{window_update_queued = false}, 0);
window_update_sent(Id, H) ->
    case find(Id, H) of
        none -> H;
        #stream{shut_rd = true} = S -> put_stream(S#stream{window_update_queued = false}, H);
        #stream{} = S -> consume_stream(put_stream(S#stream{window_update_queued = false}, H), Id, 0)
    end.

%% nghttp2_session_set_local_window_size for the connection.
-spec set_local_window_size(session(), integer()) -> {integer(), session()}.
set_local_window_size(_, Size) when Size < 0 ->
    {?ERR_INVALID_ARGUMENT, undefined};
set_local_window_size(#h2{local_window = L, recv_window = R, recv_reduction = Reduction} = H, Size) ->
    case Size - L of
        0 ->
            {0, H};
        D when D > 0, L > ?MAX_WINDOW - D ->
            {?ERR_FLOW_CONTROL, H};
        D when D > 0 ->
            %% nghttp2_increase_local_window_size: the room taken back from
            %% an earlier shrink needs no WINDOW_UPDATE.
            Back = min(Reduction, D),
            H1 = H#h2{local_window = Size, recv_reduction = Reduction - Back, recv_window = R + Back},
            case D - Back of
                0 -> {0, H1};
                Inc -> {0, queue_window_update(0, Inc, H1)}
            end;
        D ->
            %% nghttp2_adjust_local_window_size shrinks without telling the peer.
            {0, H#h2{local_window = Size, recv_window = R + D, recv_reduction = Reduction - D}}
    end.

%%% Submitting

-spec submit_settings(session(), [{non_neg_integer(), non_neg_integer()}]) -> {integer(), session()}.
submit_settings(H, Entries) ->
    case validate_settings(Entries) of
        false ->
            {?ERR_INVALID_ARGUMENT, H};
        true ->
            H1 = lists:foldl(fun
                ({3, V}, Acc) -> Acc#h2{pending_max_concurrent = V};
                ({2, V}, Acc) -> Acc#h2{pending_enable_push = V};
                (_, Acc) -> Acc
            end, H, Entries),
            %% nghttp2_session_add_settings: the settings are in flight from
            %% their submission, so an ACK that comes before they go out
            %% still applies them.
            {0, queue(urgent, {settings, Entries}, H1#h2{inflight = H1#h2.inflight ++ [Entries]})}
    end.

validate_settings(Entries) ->
    lists:all(fun
        ({2, V}) -> V =< 1;
        ({4, V}) -> V =< ?MAX_WINDOW;
        ({5, V}) -> V >= 16384 andalso V =< 16777215;
        ({8, V}) -> V =< 1;
        (_) -> true
    end, Entries).

-spec submit_ping(session(), binary()) -> session().
submit_ping(H, Payload) -> queue(urgent, {ping, 0, Payload}, H).

%% nghttp2_submit_goaway: last stream Last, or the last that we processed.
-spec submit_goaway(session(), integer(), non_neg_integer(), binary()) -> {integer(), session()}.
submit_goaway(#h2{goaway_term = T} = H, _, _, _) when T =/= none ->
    {0, H};
submit_goaway(H, Last, Code, Data) ->
    Last1 = case Last =< 0 of
        true -> H#h2.last_proc_stream_id;
        false -> Last
    end,
    {0, queue(reg, {goaway, Last1, Code, Data, normal}, H)}.

%% nghttp2_submit_request: the id of the new stream, or a negative error.
%% HasData: whether the body follows as DATA frames.
-spec submit_request(session(), term(), [{binary(), binary(), boolean()}], boolean()) -> {integer(), session()}.
submit_request(#h2{server = true} = H, _, _, _) ->
    {?ERR_PROTO, H};
submit_request(#h2{next_stream_id = Id} = H, _, _, _) when Id > ?MAX_STREAM_ID ->
    {?ERR_STREAM_ID_NOT_AVAILABLE, H};
submit_request(H, {0, ?DEFAULT_WEIGHT, false}, Fields, HasData) ->
    %% nghttp2_priority_spec_check_default: the default spec sends no PRIORITY flag.
    submit_request(H, none, Fields, HasData);
submit_request(#h2{next_stream_id = Id} = H, Pri, Fields, HasData) ->
    S0 = new_stream(Id, initial, false, H),
    {Weight, Dep} = case Pri of
        {D, W, _} when W > 0 -> {W, D};
        _ -> {16, 0}
    end,
    S = S0#stream{weight = Weight, dep = Dep, data = data_state(HasData), data_end_stream = true},
    H1 = put_stream(S, H#h2{next_stream_id = Id + 2}),
    {Id, queue(syn, {headers, Id, request, Fields, not HasData, Pri}, H1)}.

data_state(true) -> active;
data_state(false) -> none.

-spec submit_response(session(), pos_integer(), [{binary(), binary(), boolean()}], boolean()) -> {integer(), session()}.
submit_response(H, Id, Fields, HasData) ->
    case find(Id, H) of
        none -> {?ERR_INVALID_ARGUMENT, H};
        #stream{shut_wr = true} -> {?ERR_STREAM_SHUT_WR, H};
        #stream{data = D} when D =/= none -> {?ERR_DATA_EXIST, H};
        S ->
            H1 = put_stream(S#stream{data = case HasData of true -> pending; false -> none end, data_end_stream = true}, H),
            {0, queue(reg, {headers, Id, response, Fields, not HasData, none}, H1)}
    end.

%% nghttp2_submit_headers without END_STREAM: informational headers.
-spec submit_headers(session(), pos_integer(), [{binary(), binary(), boolean()}]) -> {integer(), session()}.
submit_headers(H, Id, Fields) ->
    case find(Id, H) of
        none -> {?ERR_INVALID_ARGUMENT, H};
        #stream{shut_wr = true} -> {?ERR_STREAM_SHUT_WR, H};
        _ -> {0, queue(reg, {headers, Id, info, Fields, false, none}, H)}
    end.

-spec submit_trailer(session(), pos_integer(), [{binary(), binary(), boolean()}]) -> {integer(), session()}.
submit_trailer(H, Id, Fields) ->
    case find(Id, H) of
        none -> {?ERR_INVALID_ARGUMENT, H};
        #stream{shut_wr = true} -> {?ERR_STREAM_SHUT_WR, H};
        _ -> {0, queue(reg, {headers, Id, trailers, Fields, true, none}, H)}
    end.

%% nghttp2_submit_data with END_STREAM: the provider of the stream's body.
-spec submit_data(session(), pos_integer(), boolean()) -> {integer(), session()}.
submit_data(H, Id, EndStream) ->
    case find(Id, H) of
        none -> {?ERR_INVALID_ARGUMENT, H};
        #stream{shut_wr = true} -> {?ERR_STREAM_SHUT_WR, H};
        #stream{data = D} when D =:= active; D =:= deferred -> {?ERR_DATA_EXIST, H};
        S -> {0, activate(Id, put_stream(S#stream{data = active, data_end_stream = EndStream}, H))}
    end.

-spec submit_rst_stream(session(), pos_integer(), non_neg_integer()) -> {integer(), session()}.
submit_rst_stream(H, Id, Code) ->
    case Id of
        0 -> {?ERR_INVALID_ARGUMENT, H};
        _ -> {0, add_rst_stream(Id, Code, H)}
    end.

add_rst_stream(Id, Code, H) ->
    %% A request that never left becomes nothing at all.
    case [I || I <- H#h2.ob_syn, element(2, I) =:= Id] of
        [_ | _] ->
            H1 = H#h2{ob_syn = [I || I <- H#h2.ob_syn, element(2, I) =/= Id]},
            close_stream(Id, Code, H1);
        [] ->
            H1 = update_stream(Id, fun(S) -> S#stream{state = closing_state(S)} end, H),
            queue(reg, {rst_stream, Id, Code}, H1)
    end.

closing_state(#stream{state = initial}) -> initial;
closing_state(#stream{}) -> closing.

-spec submit_priority(session(), pos_integer(), term()) -> {integer(), session()}.
submit_priority(H, Id, {Dep, _, _}) when Dep =:= Id -> {?ERR_INVALID_ARGUMENT, H};
submit_priority(H, Id, {Dep, W, _} = Pri) ->
    H1 = update_stream(Id, fun(S) -> S#stream{weight = W, dep = Dep} end, H),
    {0, queue(reg, {priority, Id, Pri}, H1)}.

-spec change_stream_priority(session(), pos_integer(), term()) -> {integer(), session()}.
change_stream_priority(H, Id, {Dep, W, _}) ->
    {0, update_stream(Id, fun(S) -> S#stream{weight = W, dep = Dep} end, H)}.

-spec submit_push_promise(session(), pos_integer(), [{binary(), binary(), boolean()}]) -> {integer(), session()}.
submit_push_promise(#h2{server = false} = H, _, _) ->
    {?ERR_PROTO, H};
submit_push_promise(#h2{remote = #{enable_push := 0}} = H, _, _) ->
    {?ERR_PUSH_DISABLED, H};
submit_push_promise(#h2{next_stream_id = P} = H, _, _) when P > ?MAX_STREAM_ID ->
    {?ERR_STREAM_ID_NOT_AVAILABLE, H};
submit_push_promise(#h2{next_stream_id = P} = H, Id, Fields) ->
    case find(Id, H) of
        none ->
            {?ERR_STREAM_CLOSED, H};
        #stream{incoming = false} ->
            {?ERR_PROTO, H};
        _ ->
            S = (new_stream(P, reserved, false, H))#stream{shut_rd = true},
            H1 = put_stream(S, H#h2{next_stream_id = P + 2}),
            {P, queue(reg, {push_promise, Id, P, Fields}, H1)}
    end.

-spec submit_altsvc(session(), non_neg_integer(), binary(), binary()) -> session().
submit_altsvc(H, Id, Origin, Value) -> queue(reg, {altsvc, Id, Origin, Value}, H).

-spec submit_origin(session(), [binary()]) -> session().
submit_origin(H, Origins) -> queue(reg, {origin, Origins}, H).

%% nghttp2_session_resume_data: a deferred provider has data again.
-spec resume_data(session(), pos_integer()) -> session().
resume_data(H, Id) ->
    case find(Id, H) of
        #stream{data = deferred} = S -> activate(Id, put_stream(S#stream{data = active}, H));
        #stream{data = active} -> activate(Id, H);
        _ -> H
    end.

activate(Id, #h2{active = Active} = H) ->
    case lists:member(Id, Active) of
        true -> H;
        false -> H#h2{active = Active ++ [Id]}
    end.

-spec set_next_stream_id(session(), integer()) -> {boolean(), session()}.
set_next_stream_id(#h2{server = Server, next_stream_id = Next} = H, Id) ->
    Mine = (Id rem 2 =:= 0) =:= Server,
    case Id =< 0 orelse Id > ?MAX_STREAM_ID orelse not Mine orelse Id < Next of
        true -> {false, H};
        false -> {true, H#h2{next_stream_id = Id}}
    end.

queue(urgent, Item, H) -> H#h2{ob_urgent = H#h2.ob_urgent ++ [Item]};
queue(reg, Item, H) -> H#h2{ob_reg = H#h2.ob_reg ++ [Item]};
queue(syn, Item, H) -> H#h2{ob_syn = H#h2.ob_syn ++ [Item]}.

%%% Sending

%% nghttp2_session_want_read.
-spec want_read(session()) -> boolean().
want_read(#h2{goaway_term = sent}) -> false;
want_read(#h2{streams = Streams} = H) ->
    map_size(Streams) > 0 orelse not (H#h2.goaway_sent orelse H#h2.goaway_recv).

%% nghttp2_session_want_write.
-spec want_write(session()) -> boolean().
want_write(#h2{goaway_term = sent}) -> false;
want_write(H) ->
    (not H#h2.server andalso not H#h2.preface_sent)
        orelse H#h2.ob_urgent =/= [] orelse H#h2.ob_reg =/= []
        orelse (H#h2.ob_syn =/= [] andalso H#h2.num_outgoing < maps:get(max_concurrent_streams, H#h2.remote))
        orelse (H#h2.remote_window > 0 andalso sendable(H) =/= []).

sendable(H) ->
    [Id || Id <- H#h2.active,
           case find(Id, H) of
               #stream{data = active, remote_window = W, state = St} -> W > 0 andalso St =/= initial andalso St =/= reserved;
               _ -> false
           end].

%% nghttp2_session_mem_send2, until nothing is left: the bytes to write.
-spec mem_send(session()) -> {iodata(), session()}.
mem_send(H) ->
    send_loop(H, []).

%% Each frame is one buffer, as each call of nghttp2_session_mem_send2
%% gives one; a DATA frame is its header, its pad length, the parts of
%% its body, and its padding, as Node's OnSendData copies them.
send_loop(#h2{server = false, preface_sent = false} = H, Acc) ->
    send_loop(H#h2{preface_sent = true}, [?MAGIC | Acc]);
send_loop(#h2{goaway_term = sent} = H, Acc) ->
    {lists:reverse(Acc), H};
send_loop(H, Acc) ->
    case next_item(H) of
        none ->
            {lists:reverse(Acc), H};
        {Item, H1} ->
            case send_item(Item, H1) of
                {[], H2} -> send_loop(H2, Acc);
                {{buffers, Buffers}, H2} -> send_loop(H2, lists:reverse([B || B <- Buffers, B =/= <<>>], Acc));
                {Bytes, H2} -> send_loop(H2, [Bytes | Acc])
            end
    end.

next_item(#h2{ob_urgent = [I | Rest]} = H) -> {I, H#h2{ob_urgent = Rest}};
next_item(#h2{ob_reg = [I | Rest]} = H) -> {I, H#h2{ob_reg = Rest}};
next_item(#h2{ob_syn = [I | Rest], num_outgoing = N, remote = #{max_concurrent_streams := Max}} = H) when N < Max ->
    {I, H#h2{ob_syn = Rest}};
next_item(#h2{goaway_term = queued}) ->
    none;
next_item(H) ->
    next_data(H#h2.active, H).

%% The next stream in turn with a window and a body to send.
next_data([], _) ->
    none;
next_data([Id | Rest], H) ->
    case find(Id, H) of
        #stream{data = active, state = State, remote_window = W} when State =/= initial, State =/= reserved ->
            case min(W, H#h2.remote_window) > 0 of
                true -> {{data, Id}, H#h2{active = lists:delete(Id, H#h2.active) ++ [Id]}};
                false -> next_data(Rest, H)
            end;
        #stream{data = active} ->
            next_data(Rest, H);
        _ ->
            next_data(Rest, H#h2{active = lists:delete(Id, H#h2.active)})
    end.

frame_bytes(Type, Flags, Id, Payload) ->
    Len = iolist_size(Payload),
    [<<Len:24, Type:8, Flags:8, 0:1, Id:31>>, Payload].

send_item({settings_ack}, H0) ->
    H = H0#h2{obq_flood = H0#h2.obq_flood - 1},
    {frame_bytes(?SETTINGS, ?FLAG_ACK, 0, []), sent(#{type => ?SETTINGS, flags => ?FLAG_ACK, stream_id => 0}, H)};
send_item({settings, Entries}, H) ->
    Payload = [<<K:16, V:32>> || {K, V} <- Entries],
    {frame_bytes(?SETTINGS, 0, 0, Payload), sent(#{type => ?SETTINGS, flags => 0, stream_id => 0}, H)};
send_item({ping, Flags, Payload}, H0) ->
    H = case Flags of ?FLAG_ACK -> H0#h2{obq_flood = H0#h2.obq_flood - 1}; _ -> H0 end,
    {frame_bytes(?PING, Flags, 0, Payload), sent(#{type => ?PING, flags => Flags, stream_id => 0}, H)};
send_item({goaway, Last, Code, Data, Kind}, H) ->
    H1 = H#h2{goaway_sent = true, local_last_stream_id = min(Last, H#h2.local_last_stream_id),
              goaway_term = case Kind of term -> sent; normal -> H#h2.goaway_term end},
    H2 = close_streams_on_goaway(Last, true, H1),
    {frame_bytes(?GOAWAY, 0, 0, [<<0:1, Last:31, Code:32>>, Data]),
     sent(#{type => ?GOAWAY, flags => 0, stream_id => 0, last_stream_id => Last, error_code => Code}, H2)};
send_item({window_update, Id, Inc}, H) ->
    {frame_bytes(?WINDOW_UPDATE, 0, Id, <<0:1, Inc:31>>),
     window_update_sent(Id, sent(#{type => ?WINDOW_UPDATE, flags => 0, stream_id => Id}, H))};
send_item({rst_stream, Id, Code}, H) ->
    Bytes = frame_bytes(?RST_STREAM, 0, Id, <<Code:32>>),
    {Bytes, close_stream(Id, Code, sent(#{type => ?RST_STREAM, flags => 0, stream_id => Id}, H))};
send_item({priority, Id, Pri}, H) ->
    {Dep, W, E} = case Pri of {_, _, _} -> Pri; _ -> {0, 16, 0} end,
    {frame_bytes(?PRIORITY, 0, Id, <<(bool(E)):1, Dep:31, (W - 1)>>), sent(#{type => ?PRIORITY, flags => 0, stream_id => Id}, H)};
send_item({altsvc, Id, Origin, Value}, H) ->
    {frame_bytes(?ALTSVC, 0, Id, [<<(byte_size(Origin)):16>>, Origin, Value]), H};
send_item({origin, Origins}, H) ->
    {frame_bytes(?ORIGIN, 0, 0, [[<<(byte_size(O)):16>>, O] || O <- Origins]), H};
send_item({push_promise, Id, P, Fields}, H) ->
    case find(Id, H) of
        #stream{shut_wr = false} ->
            {Block, H1} = encode(Fields, H),
            {header_frames(?PUSH_PROMISE, 0, Id, [<<0:1, P:31>>, Block], H1),
             sent(#{type => ?PUSH_PROMISE, flags => 0, stream_id => Id, promised_stream_id => P}, H1)};
        _ ->
            not_sent(#{type => ?PUSH_PROMISE, flags => 0, stream_id => Id}, ?ERR_STREAM_CLOSED,
                     close_stream(P, ?CANCEL, H))
    end;
send_item({headers, Id, Kind, Fields, EndStream, Pri}, H) ->
    send_headers(Id, Kind, Fields, EndStream, Pri, H);
send_item({data, Id}, H) ->
    send_data(Id, H).

bool(true) -> 1;
bool(1) -> 1;
bool(_) -> 0.

send_headers(Id, request, _, _, _, #h2{goaway_recv = true} = H) ->
    headers_not_sent(Id, request, 0, ?ERR_START_STREAM_NOT_ALLOWED, H);
send_headers(Id, Kind, Fields, EndStream, Pri, H) ->
    case find(Id, H) of
        none ->
            headers_not_sent(Id, Kind, 0, ?ERR_STREAM_CLOSED, H);
        #stream{shut_wr = true} ->
            headers_not_sent(Id, Kind, 0, ?ERR_STREAM_CLOSED, H);
        S ->
            {Block, H1} = encode(Fields, H),
            Flags0 = case EndStream of true -> ?FLAG_END_STREAM; false -> 0 end,
            {PriBytes, Flags} = case Pri of
                {Dep, W, E} when Kind =:= request -> {<<(bool(E)):1, Dep:31, (W - 1)>>, Flags0 bor ?FLAG_PRIORITY};
                _ -> {<<>>, Flags0}
            end,
            Max = maps:get(max_send_header_block_length, H#h2.opts, 65536),
            case iolist_size(Block) > Max of
                true ->
                    headers_not_sent(Id, Kind, Flags, ?ERR_FRAME_SIZE_ERROR, H);
                false ->
                    Bytes = header_frames(?HEADERS, Flags, Id, [PriBytes, Block], H1),
                    S1 = case Kind of
                        request -> S#stream{state = opening};
                        response -> S#stream{state = opened};
                        _ -> S
                    end,
                    {S1b, H2} = case Kind of
                        request -> {S1#stream{counted = true}, H1#h2{num_outgoing = H1#h2.num_outgoing + 1}};
                        _ -> {S1, H1}
                    end,
                    S2 = case S1b#stream.data of
                        pending -> S1b#stream{data = active};
                        _ -> S1b
                    end,
                    H3 = put_stream(S2#stream{shut_wr = S2#stream.shut_wr orelse EndStream}, H2),
                    H4 = case S2#stream.data of
                        active -> activate(Id, H3);
                        _ -> H3
                    end,
                    H5 = sent(#{type => ?HEADERS, flags => Flags, stream_id => Id}, H4),
                    {Bytes, close_if_shut(Id, H5)}
            end
    end.

%% A request whose HEADERS cannot go out closes with REFUSED_STREAM, so the
%% application may send it again (nghttp2_session_send's prep failure).
headers_not_sent(Id, Kind, Flags, Lib, H) ->
    {Bytes, H1} = not_sent(#{type => ?HEADERS, flags => Flags, stream_id => Id}, Lib, H),
    case Kind of
        request -> {Bytes, close_stream(Id, ?REFUSED_STREAM, H1)};
        _ -> {Bytes, H1}
    end.

%% A header block, split into HEADERS (or PUSH_PROMISE) and CONTINUATION
%% frames of the peer's maximum frame size.
%% A HEADERS frame takes the padding of session_headers_add_pad in its
%% first frame; PUSH_PROMISE takes none, as in nghttp2.
header_frames(Type, Flags, Id, Payload, #h2{remote = #{max_frame_size := Max}} = H) ->
    Bin = iolist_to_binary(Payload),
    Len = byte_size(Bin),
    {Pre, Post, PadFlag} = case Type =:= ?HEADERS andalso padding(Len, ?MAX_PAYLOADLEN, H) of
        P when is_integer(P), P > Len -> {<<(P - Len - 1)>>, binary:copy(<<0>>, P - Len - 1), ?FLAG_PADDED};
        _ -> {<<>>, <<>>, 0}
    end,
    FirstMax = max(1, Max - byte_size(Pre) - byte_size(Post)),
    case Len =< FirstMax of
        true ->
            frame_bytes(Type, Flags bor PadFlag bor ?FLAG_END_HEADERS, Id, [Pre, Bin, Post]);
        false ->
            <<First:FirstMax/binary, Rest/binary>> = Bin,
            [frame_bytes(Type, Flags bor PadFlag, Id, [Pre, First, Post]) | continuations(Rest, Id, Max)]
    end.

%% session_call_select_padding: the padded payload length that the
%% callback picks, from Len up to Len plus NGHTTP2_MAX_PADLEN.
padding(Len, Max, H) ->
    Limit = min(Max, Len + ?MAX_PADLEN),
    case Len >= Limit of
        true ->
            Len;
        false ->
            case cb({select_padding, Len, Limit}, H) of
                {P, _} when is_integer(P), P >= Len, P =< Limit -> P;
                _ -> Len
            end
    end.

continuations(Bin, Id, Max) when byte_size(Bin) =< Max ->
    [frame_bytes(?CONTINUATION, ?FLAG_END_HEADERS, Id, Bin)];
continuations(Bin, Id, Max) ->
    <<Chunk:Max/binary, Rest/binary>> = Bin,
    [frame_bytes(?CONTINUATION, 0, Id, Chunk) | continuations(Rest, Id, Max)].

encode(Fields, #h2{enc = Enc} = H) ->
    {Block, Enc1} = buoy_hpack:encode(Fields, Enc),
    {Block, H#h2{enc = Enc1}}.

%% One DATA frame of a stream: the provider gives up to the window.
send_data(Id, H) ->
    case find(Id, H) of
        #stream{data = active, remote_window = W, data_end_stream = EndStream} ->
            Max = lists:min([W, H#h2.remote_window, maps:get(max_frame_size, H#h2.remote)]),
            case Max =< 0 of
                true ->
                    {[], H};
                false ->
                    case cb({read_data, Id, Max}, H) of
                        {deferred, H1} ->
                            {[], update_stream(Id, fun(St) -> St#stream{data = deferred} end,
                                               H1#h2{active = lists:delete(Id, H1#h2.active)})};
                        {{Bytes, Eof, NoEndStream}, H1} ->
                            data_frame(Max, Id, Bytes, Eof, NoEndStream orelse not EndStream, H1)
                    end
            end;
        _ ->
            {[], H#h2{active = lists:delete(Id, H#h2.active)}}
    end.

data_frame(Max, Id, Bytes, Eof, NoEndStream, H) ->
    case find(Id, H) of
        none ->
            {[], H};
        S ->
            Len = iolist_size(Bytes),
            EndStream = Eof andalso not NoEndStream,
            Flags = case EndStream of true -> ?FLAG_END_STREAM; false -> 0 end,
            Parts = case Bytes of
                B when is_binary(B) -> [B];
                L -> L
            end,
            {Padded, PadFlags, FrameLen} = case padding(Len, Max, H) of
                P when P > Len -> {[<<(P - Len - 1)>> | Parts] ++ [binary:copy(<<0>>, P - Len - 1)], ?FLAG_PADDED, P};
                _ -> {Parts, 0, Len}
            end,
            S1 = S#stream{remote_window = S#stream.remote_window - FrameLen,
                          shut_wr = S#stream.shut_wr orelse EndStream,
                          data = case Eof of true -> none; false -> active end},
            H1 = put_stream(S1, H#h2{remote_window = H#h2.remote_window - FrameLen}),
            H2 = case Eof of
                true -> H1#h2{active = lists:delete(Id, H1#h2.active)};
                false -> H1
            end,
            H3 = sent(#{type => ?DATA, flags => Flags, stream_id => Id, length => Len}, H2),
            {{buffers, [<<FrameLen:24, ?DATA:8, (Flags bor PadFlags):8, 0:1, Id:31>> | Padded]}, close_if_shut(Id, H3)}
    end.

sent(F, H) -> element(2, cb({frame_sent, F}, H)).

not_sent(F, Lib, H) -> {[], element(2, cb({frame_not_sent, F, Lib}, H))}.

%%% The messaging rules of nghttp2_http.c

%% A received field: {ok, Http}, ignore for a field that is only invalid
%% (on_invalid_header), or error for a violation that resets the stream.
http_on_header(F, #stream{http = Http}, Name, Value, H) ->
    Strict = maps:get(strict_ws, H#h2.opts, true),
    case valid_name(Name) andalso valid_field_value(Name, Value, Strict, F, H) of
        false when Name =:= <<>> -> error;
        false ->
            case Name of
                <<$:, _/binary>> -> error;
                _ -> ignore
            end;
        true ->
            Cat = maps:get(cat, F),
            pseudo_or_field(Cat, Name, Value, Http)
    end.

pseudo_or_field(Cat, <<$:, _/binary>> = Name, Value, Http) ->
    case maps:get(regular_seen, Http, false) orelse maps:is_key({pseudo, Name}, Http) of
        true -> error;
        false ->
            Allowed = case Cat of
                ?HCAT_REQUEST -> [<<":method">>, <<":path">>, <<":scheme">>, <<":authority">>, <<":protocol">>];
                ?HCAT_HEADERS ->
                    case is_trailer(Http) of
                        true -> [];
                        false -> [<<":status">>]
                    end;
                _ -> [<<":status">>]
            end,
            case lists:member(Name, Allowed) of
                false -> error;
                true -> pseudo(Name, Value, Http#{{pseudo, Name} => Value})
            end
    end;
pseudo_or_field(Cat, Name, Value, Http) ->
    Http1 = Http#{regular_seen => true},
    case Name of
        <<"content-length">> ->
            case parse_length(Value) of
                error -> error;
                N when Cat =:= ?HCAT_HEADERS -> {ok, Http1#{trailer_content_length => N}};
                N ->
                    case maps:get(content_length, Http1, none) of
                        none -> {ok, Http1#{content_length => N}};
                        N -> {ok, Http1};
                        _ -> error
                    end
            end;
        _ when Name =:= <<"connection">>; Name =:= <<"keep-alive">>; Name =:= <<"proxy-connection">>;
               Name =:= <<"transfer-encoding">>; Name =:= <<"upgrade">> ->
            error;
        <<"te">> ->
            case string:lowercase(Value) of
                <<"trailers">> -> {ok, Http1};
                _ -> error
            end;
        <<"host">> -> {ok, Http1#{host => true}};
        _ -> {ok, Http1}
    end.

pseudo(<<":status">>, Value, Http) ->
    case Value of
        <<A, B, C>> when A >= $1, A =< $9, B >= $0, B =< $9, C >= $0, C =< $9 ->
            {ok, Http#{status => (A - $0) * 100 + (B - $0) * 10 + (C - $0)}};
        _ -> error
    end;
pseudo(<<":method">>, <<>>, _) -> error;
pseudo(<<":path">>, <<>>, _) -> error;
pseudo(_, _, Http) -> {ok, Http}.

parse_length(<<>>) -> error;
parse_length(V) ->
    case lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(V)) of
        true -> binary_to_integer(V);
        false -> error
    end.

valid_name(<<>>) -> false;
valid_name(<<$:, Rest/binary>>) -> Rest =/= <<>> andalso valid_token(Rest);
valid_name(Name) -> valid_token(Name).

valid_token(Name) -> valid_token(Name, lower).

%% A tchar of RFC 9110; a header name must be lowercase.
valid_token(Name, Case) ->
    lists:all(fun(C) -> (C >= $a andalso C =< $z) orelse (C >= $0 andalso C =< $9)
                        orelse (Case =:= upper andalso C >= $A andalso C =< $Z)
                        orelse lists:member(C, "!#$%&'*+-.^_`|~") end, binary_to_list(Name)).

%% nghttp2_http_on_header: each pseudo-header has its own character set.
valid_field_value(<<":method">>, Value, _, _, _) ->
    Value =/= <<>> andalso valid_token(Value, upper);
valid_field_value(<<":path">>, Value, _, _, _) ->
    lists:all(fun(C) -> C > 16#20 andalso C =/= 16#7f end, binary_to_list(Value));
valid_field_value(Name, Value, Strict, F, H) when Name =:= <<":authority">>; Name =:= <<"host">> ->
    case H#h2.server orelse maps:get(type, F) =:= ?PUSH_PROMISE of
        true -> lists:all(fun authority_char/1, binary_to_list(Value));
        false -> valid_value(Value, Strict)
    end;
valid_field_value(<<":protocol">>, Value, _, _, _) ->
    valid_value(Value, false);
valid_field_value(_, Value, Strict, _, _) ->
    valid_value(Value, Strict).

%% VALID_AUTHORITY_CHARS: unreserved, sub-delims, ":", "@", "[", "]", and "%".
authority_char(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse (C >= $0 andalso C =< $9)
        orelse lists:member(C, "-._~!$&'()*+,;=:@[]%").

valid_value(Value, Strict) ->
    Ok = lists:all(fun(C) -> C =:= $\t orelse (C >= 16#20 andalso C =/= 16#7f) end, binary_to_list(Value)),
    Ok andalso (not Strict orelse not edge_ws(Value)).

edge_ws(<<>>) -> false;
edge_ws(V) ->
    First = binary:first(V),
    Last = binary:last(V),
    First =:= $\s orelse First =:= $\t orelse Last =:= $\s orelse Last =:= $\t.

%% The end of a header block: the pseudo-headers that it must hold.
http_on_headers_end(#{cat := ?HCAT_REQUEST}, #stream{http = Http}) ->
    Method = maps:get({pseudo, <<":method">>}, Http, undefined),
    HasPath = maps:is_key({pseudo, <<":path">>}, Http),
    HasScheme = maps:is_key({pseudo, <<":scheme">>}, Http),
    HasAuthority = maps:is_key({pseudo, <<":authority">>}, Http) orelse maps:get(host, Http, false),
    HasProtocol = maps:is_key({pseudo, <<":protocol">>}, Http),
    Ok = case Method of
        undefined -> false;
        <<"CONNECT">> when not HasProtocol -> HasAuthority andalso not HasPath andalso not HasScheme;
        _ -> HasPath andalso HasScheme
    end,
    case Ok of
        true -> {ok, clear_pseudo(Http#{request => true, method => Method})};
        false -> error
    end;
http_on_headers_end(#{cat := Cat}, #stream{http = Http}) when Cat =:= ?HCAT_RESPONSE; Cat =:= ?HCAT_PUSH_RESPONSE ->
    case maps:get(status, Http, undefined) of
        undefined -> error;
        Status when Status >= 100, Status < 200 -> {ok, clear_pseudo(maps:without([status, content_length], Http))};
        Status ->
            Http1 = Http#{final => true, status_code => Status},
            Http2 = case Status of
                S when S =:= 204; S =:= 304 -> maps:remove(content_length, Http1);
                _ -> Http1
            end,
            {ok, clear_pseudo(Http2)}
    end;
http_on_headers_end(#{cat := ?HCAT_HEADERS, flags := Flags} = F, #stream{http = Http} = S) ->
    case {is_trailer(Http), Flags band ?FLAG_END_STREAM} of
        {true, 0} -> error;
        {true, _} -> {ok, clear_pseudo(Http)};
        {false, _} -> http_on_headers_end(F#{cat := ?HCAT_RESPONSE}, S)
    end.

%% A HEADERS block after the request, or after the final response.
is_trailer(Http) -> maps:get(final, Http, false) orelse maps:get(request, Http, false).

clear_pseudo(Http) ->
    maps:filter(fun({pseudo, _}, _) -> false; (_, _) -> true end, Http#{regular_seen => false}).

http_on_data(#stream{http = Http}, Len) ->
    Recv = maps:get(recv_length, Http, 0) + Len,
    case maps:get(content_length, Http, none) of
        N when is_integer(N), Recv > N -> error;
        _ -> {ok, Http#{recv_length => Recv}}
    end.

http_on_remote_end_stream(#stream{http = Http}) ->
    case maps:get(content_length, Http, none) of
        N when is_integer(N) ->
            case {maps:get(recv_length, Http, 0), maps:get(method, Http, undefined)} of
                {N, _} -> ok;
                {_, <<"HEAD">>} -> ok;
                _ -> error
            end;
        none ->
            ok
    end.

%%% State for the binding

-spec find_stream(session(), pos_integer()) -> boolean().
find_stream(H, Id) -> find(Id, H) =/= none.

-spec last_proc_stream_id(session()) -> non_neg_integer().
last_proc_stream_id(#h2{last_proc_stream_id = L}) -> L.

%% The values of Http2Session::RefreshState, in the order of the session
%% state buffer.
-spec session_state(session()) -> [number()].
session_state(H) ->
    Queue = length(H#h2.ob_urgent) + length(H#h2.ob_reg) + length(H#h2.ob_syn),
    [H#h2.local_window,                      % effective local window size
     max(0, H#h2.recv_window),               % effective recv data length
     H#h2.next_stream_id,
     max(0, H#h2.local_window - H#h2.recv_window),
     H#h2.last_proc_stream_id,
     H#h2.remote_window,
     Queue,
     buoy_hpack:table_size(H#h2.enc),
     buoy_hpack:table_size(H#h2.dec)].

%% The values of Http2Stream::RefreshState: state, weight, the sum of the
%% weights that depend on it, local close, remote close, local window.
-spec stream_state(session(), pos_integer()) -> [number()].
stream_state(H, Id) ->
    case find(Id, H) of
        none ->
            [1, 0, 0, 0, 0, 0];
        S ->
            State = case {S#stream.state, S#stream.shut_rd, S#stream.shut_wr} of
                {initial, _, _} -> 1;
                {reserved, _, _} when S#stream.incoming -> 4;
                {reserved, _, _} -> 3;
                {_, true, true} -> 7;
                {_, false, true} -> 5;
                {_, true, false} -> 6;
                _ -> 2
            end,
            [State, S#stream.weight, S#stream.sum_dep_weight, bool(S#stream.shut_wr), bool(S#stream.shut_rd),
             max(0, S#stream.local_window - S#stream.recv_window)]
    end.

-spec local_settings(session()) -> map().
local_settings(#h2{local = L}) -> L.

-spec remote_settings(session()) -> map().
remote_settings(#h2{remote = R}) -> R.

%% nghttp2_pack_settings_payload.
-spec pack_settings([{non_neg_integer(), non_neg_integer()}]) -> binary().
pack_settings(Entries) -> << <<K:16, V:32>> || {K, V} <- Entries >>.

%% A callback that answers {fatal, Code} ends mem_recv with that error, as
%% NGHTTP2_ERR_CALLBACK_FAILURE does.
cb(Event, #h2{cb = Cb} = H) ->
    case Cb(Event, H) of
        {{fatal, Code}, H1} -> throw({?MODULE, fatal, Code, H1});
        Reply -> Reply
    end.

-spec strerror(integer()) -> binary().
strerror(0) -> <<"Success">>;
strerror(-501) -> <<"Invalid argument">>;
strerror(-502) -> <<"Out of buffer space">>;
strerror(-503) -> <<"Unsupported SPDY version">>;
strerror(-504) -> <<"Operation would block">>;
strerror(-505) -> <<"Protocol error">>;
strerror(-506) -> <<"Invalid frame octets">>;
strerror(-507) -> <<"EOF">>;
strerror(-508) -> <<"Data transfer deferred">>;
strerror(-509) -> <<"No more Stream ID available">>;
strerror(-510) -> <<"Stream was already closed or invalid">>;
strerror(-511) -> <<"Stream is closing">>;
strerror(-512) -> <<"The transmission is not allowed for this stream">>;
strerror(-513) -> <<"Stream ID is invalid">>;
strerror(-514) -> <<"Invalid stream state">>;
strerror(-515) -> <<"Another DATA frame has already been deferred">>;
strerror(-516) -> <<"request HEADERS is not allowed">>;
strerror(-517) -> <<"GOAWAY has already been sent">>;
strerror(-518) -> <<"Invalid header block">>;
strerror(-519) -> <<"Invalid state">>;
strerror(-521) -> <<"The user callback function failed due to the temporal error">>;
strerror(-522) -> <<"The length of the frame is invalid">>;
strerror(-523) -> <<"Header compression/decompression error">>;
strerror(-524) -> <<"Flow control error">>;
strerror(-525) -> <<"Insufficient buffer size given to function">>;
strerror(-526) -> <<"Callback was paused by the application">>;
strerror(-527) -> <<"Too many inflight SETTINGS">>;
strerror(-528) -> <<"Server push is disabled by peer">>;
strerror(-529) -> <<"DATA or HEADERS frame has already been submitted for the stream">>;
strerror(-530) -> <<"The current session is closing">>;
strerror(-531) -> <<"Invalid HTTP header field was received">>;
strerror(-532) -> <<"Violation in HTTP messaging rule">>;
strerror(-533) -> <<"Stream was refused">>;
strerror(-534) -> <<"Internal error">>;
strerror(-535) -> <<"Cancel">>;
strerror(-536) -> <<"When a local endpoint expects to receive SETTINGS frame, it receives an other type of frame">>;
strerror(-537) -> <<"SETTINGS frame contained more than the maximum allowed entries">>;
strerror(-901) -> <<"Out of memory">>;
strerror(-902) -> <<"The user callback function failed">>;
strerror(-903) -> <<"Received bad client magic byte string">>;
strerror(-904) -> <<"Flooding was detected in this HTTP/2 session, and it must be closed">>;
strerror(-905) -> <<"Too many CONTINUATION frames following a HEADER frame">>;
strerror(_) -> <<"Unknown error code">>.
