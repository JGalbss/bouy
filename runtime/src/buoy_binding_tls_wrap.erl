%% internalBinding('tls_wrap') (src/crypto/crypto_tls.cc): TLSWrap, the TLS
%% stream that tls.TLSSocket reads and writes, over the stream handle of a
%% net.Socket. OTP's ssl runs the protocol in place of OpenSSL:
%%
%% - The parent handle (buoy_node_socket) hands its reads to the TLSWrap
%%   (set_listener), and buoy_tls_transport is the transport of ssl over
%%   it: the realm passes the encrypted bytes to ssl under the active mode
%%   that ssl sets, and writes the bytes that ssl sends to the parent.
%% - An agent process per connection runs ssl:connect or ssl:handshake,
%%   which block until the handshake ends, then owns the ssl socket: it
%%   sends the cleartext writes and passes each read back to the realm.
%% - Certificate verification never fails the handshake: a verify_fun
%%   records the first error, and verifyError() reports it, as Node lets
%%   tls.js decide with rejectUnauthorized.
%%
%% Bun runs TLS inside its socket layer (uSockets with BoringSSL); here the
%% protocol runs in ssl's processes and the realm only moves bytes.
-module(buoy_binding_tls_wrap).

-export([binding/0, transport/2]).

-define(STATE, {'#', ?MODULE, <<"state">>}).
-define(K_READ_BYTES, 0).
-define(K_OFFSET, 1).
-define(K_BYTES_WRITTEN, 2).
-define(K_ASYNC, 3).
-define(UV_EOF, -4095).
-define(INBOX_LIMIT, 1048576).

-spec binding() -> term().
binding() ->
    Class = buoy_node:constructor(<<"TLSWrap">>, 0, fun(_, _) -> undefined end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    erlang:put({?MODULE, class}, Class),
    A = fun buoy_node:arg/2,
    Write = fun(Encode) -> fun(This, Args) -> write(This, A(1, Args), Encode(A(2, Args))) end end,
    Methods = [
        {<<"writeBuffer">>, Write(fun buoy_node_encoding:view_bytes/1)},
        {<<"writeUtf8String">>, Write(fun(V) -> buoy_node_encoding:encode(utf8, V) end)},
        {<<"writeAsciiString">>, Write(fun(V) -> buoy_node_encoding:encode(latin1, V) end)},
        {<<"writeLatin1String">>, Write(fun(V) -> buoy_node_encoding:encode(latin1, V) end)},
        {<<"writeUcs2String">>, Write(fun(V) -> buoy_node_encoding:encode(ucs2, V) end)},
        {<<"writev">>, fun(This, Args) -> write(This, A(1, Args), writev_bytes(A(2, Args), buoy_ref:truthy(A(3, Args)))) end},
        {<<"readStart">>, fun(This, _) -> set_reading(This, true), 0 end},
        {<<"readStop">>, fun(This, _) -> set_reading(This, false), 0 end},
        {<<"shutdown">>, fun(This, Args) -> shutdown(This, A(1, Args)) end},
        {<<"useUserBuffer">>, fun(_, _) -> undefined end},
        {<<"getAsyncId">>, fun(This, _) -> maps:get(async_id, state(This)) end},
        {<<"getProviderType">>, fun(_, _) -> 0 end},
        {<<"start">>, fun(This, _) -> start(This), undefined end},
        {<<"setVerifyMode">>, fun(This, Args) -> put(This, verify, {buoy_ref:truthy(A(1, Args)), buoy_ref:truthy(A(2, Args))}) end},
        {<<"enableSessionCallbacks">>, fun(This, _) -> put(This, session_callbacks, true) end},
        {<<"enableKeylogCallback">>, fun(This, _) -> put(This, keylog, true) end},
        {<<"enableTrace">>, fun(_, _) -> undefined end},
        {<<"enableCertCb">>, fun(This, _) -> put(This, cert_cb, true) end},
        {<<"enableALPNCb">>, fun(_, _) -> undefined end},
        {<<"enablePskCallback">>, fun(_, _) -> undefined end},
        {<<"setPskIdentityHint">>, fun(_, _) -> undefined end},
        {<<"setALPNProtocols">>, fun(This, Args) -> put(This, alpn, alpn_list(buoy_node_encoding:view_bytes(A(1, Args)))) end},
        {<<"getALPNNegotiatedProtocol">>, fun(This, _) -> info(This, alpn, false) end},
        {<<"setServername">>, fun(This, Args) -> put(This, servername, text(A(1, Args))) end},
        {<<"getServername">>, fun(This, _) -> servername(This) end},
        {<<"setSession">>, fun(This, Args) -> put(This, session, buoy_node_encoding:view_bytes(A(1, Args))) end},
        {<<"getSession">>, fun(This, _) -> session(This) end},
        {<<"isSessionReused">>, fun(This, _) -> info(This, reused, false) end},
        {<<"loadSession">>, fun(_, _) -> undefined end},
        {<<"endParser">>, fun(_, _) -> undefined end},
        {<<"newSessionDone">>, fun(_, _) -> undefined end},
        {<<"getTLSTicket">>, fun(_, _) -> undefined end},
        {<<"getPeerCertificate">>, fun(This, Args) -> peer_certificate(This, buoy_ref:truthy(A(1, Args))) end},
        {<<"getPeerX509Certificate">>, fun(This, _) -> peer_x509(This) end},
        {<<"getCertificate">>, fun(This, _) -> own_certificate(This, legacy) end},
        {<<"getX509Certificate">>, fun(This, _) -> own_certificate(This, x509) end},
        {<<"getFinished">>, fun(_, _) -> undefined end},
        {<<"getPeerFinished">>, fun(_, _) -> undefined end},
        {<<"getProtocol">>, fun(This, _) -> info(This, protocol, null) end},
        {<<"getCipher">>, fun(This, _) -> cipher(This) end},
        {<<"getSharedSigalgs">>, fun(_, _) -> buoy_heap:new_array([]) end},
        {<<"getEphemeralKeyInfo">>, fun(This, _) -> ephemeral_key(This) end},
        {<<"exportKeyingMaterial">>, fun(This, Args) -> export_keying_material(This, A(1, Args), A(2, Args), A(3, Args)) end},
        {<<"verifyError">>, fun(This, _) -> verify_error(This) end},
        {<<"renegotiate">>, fun(_, _) -> false end},
        {<<"destroySSL">>, fun(This, _) -> destroy(This), undefined end},
        {<<"setOCSPResponse">>, fun(_, _) -> undefined end},
        {<<"requestOCSP">>, fun(_, _) -> undefined end},
        {<<"setMaxSendFragment">>, fun(_, _) -> true end},
        {<<"setKeyCert">>, fun(_, _) -> undefined end},
        {<<"certCbDone">>, fun(This, _) -> cert_cb_done(This) end},
        {<<"receive">>, fun(This, Args) -> encrypted_in(This, {data, buoy_node_encoding:view_bytes(A(1, Args))}), undefined end},
        {<<"writesIssuedByPrevListenerDone">>, fun(_, _) -> undefined end}],
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    [buoy_heap:define(Proto, Name, #{get => buoy_node:fn(<<"get ", Name/binary>>, 0, Get), enumerable => true, configurable => true})
     || {Name, Get} <- [{<<"bytesRead">>, fun(This, _) -> maps:get(read, state(This)) end},
                        {<<"bytesWritten">>, fun(This, _) -> maps:get(written, state(This)) end},
                        {<<"writeQueueSize">>, fun(This, _) -> maps:get(queued, state(This)) end},
                        {<<"fd">>, fun(This, _) -> buoy_heap:get(maps:get(parent, state(This)), <<"fd">>) end}]],
    buoy_heap:define(Proto, <<"isStreamBase">>, #{value => true, writable => true, enumerable => true, configurable => true}),
    buoy_node:object([
        {<<"wrap">>, buoy_node:fn(<<"wrap">>, 4, fun(_, Args) -> wrap(A(1, Args), A(2, Args), buoy_ref:truthy(A(3, Args))) end)},
        {<<"HAVE_SSL_TRACE">>, 1},
        {<<"TLSWrap">>, Class}]).

text(V) -> buoy_ref_string:to_utf8(buoy_ref:to_string(V)).

%%% State

state(This) ->
    case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, ?STATE) of
        {ok, S} -> S;
        _ -> buoy_ref:type_error(<<"Illegal invocation">>)
    end.

save(This, S) -> buoy_heap:private_put(This, ?STATE, S).

put(This, Key, Value) ->
    save(This, (state(This))#{Key => Value}),
    undefined.

by_id(Id) -> erlang:get({?MODULE, Id}).

%% wrap(handle, context, isServer): the TLSWrap over the stream handle
%% handle, which hands its reads to it from now on.
wrap(Parent, Context, Server) ->
    buoy_crypto_context:is_context(Context) orelse
        buoy_node:throw_code('TypeError', <<"ERR_TLS_INVALID_CONTEXT">>, <<"context must be a SecureContext">>),
    buoy_node_socket:find(Parent) =/= error orelse
        buoy_node:throw_code('Error', <<"ERR_BUOY_NOT_IMPLEMENTED">>,
                             <<"TLS over a stream that is not a socket handle is not implemented on Buoy">>),
    Class = erlang:get({?MODULE, class}),
    This = buoy_heap:construct(Class, [], Class),
    Id = make_ref(),
    erlang:put({?MODULE, Id}, This),
    save(This, #{id => Id, parent => Parent, context => Context, server => Server, phase => idle, agent => none,
                 verify => {not Server, false}, servername => none, alpn => none, session => none,
                 session_callbacks => false, keylog => false, cert_cb => false, sni_waiting => none,
                 reading => false, cleartext => [], eof => false, pending => [], writes => #{}, queued => 0,
                 shutdown => none, controller => none, active => false, inbox => [], inbox_size => 0,
                 peer_eof => false, info => #{}, read => 0, written => 0,
                 async_id => new_async_id()}),
    buoy_node_socket:set_listener(Parent, fun(Event) -> parent_event(Id, Event) end),
    {ok, #{reading := Reading}} = buoy_node_socket:find(Parent),
    put(This, reading, Reading),
    %% A server's handshake begins once tls.js has set the options of the
    %% socket, which it does right after wrap, as OpenSSL waits for the
    %% ClientHello.
    Server andalso buoy_node_socket:later(fun() -> server_start(Id) end),
    This.

server_start(Id) ->
    case by_id(Id) of
        undefined -> ok;
        This ->
            case state(This) of
                #{phase := idle} -> begin_handshake(This, server);
                _ -> ok
            end
    end.

new_async_id() ->
    Fields = buoy_heap:get(buoy_node:binding(<<"async_wrap">>), <<"async_id_fields">>),
    Id = buoy_heap:get(Fields, 2) + 1,
    buoy_heap:set(Fields, 2, Id),
    Id.

%%% The handshake

%% start(): the client's handshake begins.
start(This) ->
    case state(This) of
        #{phase := idle, server := false} -> begin_handshake(This, client);
        _ -> ok
    end.

begin_handshake(This, Role) ->
    #{id := Id, parent := Parent} = S = state(This),
    ok = start_ssl(),
    Realm = self(),
    Agent = spawn(fun() -> receive {options, Options} -> agent(Realm, Id, Role, Options) end end),
    Agent ! {options, ssl_options(S, Role, Agent)},
    save(This, S#{phase := handshaking, agent := Agent}),
    buoy_node_loop:ref_handle(),
    buoy_node_socket:read_start(Parent),
    Role =:= server andalso call_js(This, <<"onhandshakestart">>, [buoy_node_loop:now()]),
    ok.

%% The ssl application and its dependencies, started once per VM.
start_ssl() ->
    case persistent_term:get({?MODULE, ssl}, false) of
        true -> ok;
        false ->
            {ok, _} = application:ensure_all_started(ssl),
            persistent_term:put({?MODULE, ssl}, true),
            ok
    end.

%% The ssl options of the connection; the verify_fun reports to Agent.
ssl_options(S, Role, Agent) ->
    #{context := Context, verify := {Request, _Reject}, servername := Name, alpn := Alpn, session := Session} = S,
    Verify = case {Role, Request} of
        {server, false} -> [{verify, verify_none}];
        {server, true} -> [{verify, verify_peer}, {fail_if_no_peer_cert, false}, {verify_fun, verify_fun(Agent)}];
        {client, _} -> [{verify, verify_peer}, {verify_fun, verify_fun(Agent)}]
    end,
    Base = buoy_crypto_context:options(Context, Role),
    Sni = case {Role, Name} of
        {client, none} -> [{server_name_indication, disable}];
        {client, _} -> [{server_name_indication, binary_to_list(Name)}];
        {server, _} -> []
    end,
    AlpnOption = case {Role, Alpn} of
        {_, none} -> [];
        {client, Protocols} -> [{alpn_advertised_protocols, Protocols}];
        {server, Protocols} -> [{alpn_preferred_protocols, Protocols}]
    end,
    Resume = case {Role, Session} of
        {client, none} -> [{session_tickets, manual}, {reuse_sessions, false}];
        {client, Bytes} ->
            case try binary_to_term(Bytes, [safe]) catch error:_ -> invalid end of
                {tls13_ticket, Ticket} -> [{session_tickets, manual}, {use_ticket, [Ticket]}];
                {tls12, SessionId, Data} -> [{session_tickets, manual}, {reuse_session, {SessionId, Data}}];
                _ -> [{session_tickets, manual}, {reuse_sessions, false}]
            end;
        {server, _} -> [{session_tickets, stateless}]
    end,
    SniFun = case {Role, maps:get(cert_cb, S)} of
        {server, true} -> [{sni_fun, sni_fun(self_realm(), maps:get(id, S))}];
        _ -> []
    end,
    Keylog = case maps:get(keylog, S) of
        true -> [{keep_secrets, {keylog, keylog_fun(self_realm(), maps:get(id, S))}}];
        false -> []
    end,
    %% Tickets are TLS 1.3's: ssl refuses the option without that version.
    %% and the sessions of TLS 1.2 and earlier refuse a TLS 1.3 only list.
    Versions = proplists:get_value(versions, Base, []),
    Tls13 = lists:member('tlsv1.3', Versions),
    Older = Versions -- ['tlsv1.3'] =/= [],
    Tickets = [O || O <- Resume, Tls13 orelse not lists:member(element(1, O), [session_tickets, use_ticket]),
                    Older orelse not lists:member(element(1, O), [reuse_sessions, reuse_session])],
    [{cb_info, buoy_tls_transport:cb_info()}, {log_level, none}, {handshake, full}]
        ++ Verify ++ Sni ++ AlpnOption ++ Tickets ++ SniFun ++ Keylog ++ Base.

self_realm() -> self().

%% Records each verification error at the agent and lets the handshake go
%% on; the hostname is tls.js's to check (checkServerIdentity).
verify_fun(Agent) ->
    Fun = fun
        (_Cert, {bad_cert, hostname_check_failed}, State) -> {valid, State};
        (Cert, {bad_cert, Reason}, State) ->
            Agent ! {verify_error, Reason, der(Cert)},
            {valid, State};
        (_Cert, {extension, _}, State) -> {unknown, State};
        (Cert, valid, State) -> Agent ! {verify_chain, der(Cert)}, {valid, State};
        (Cert, valid_peer, State) -> Agent ! {verify_chain, der(Cert)}, {valid, State}
    end,
    {Fun, []}.

der(Cert) ->
    try public_key:pkix_encode('OTPCertificate', Cert, otp)
    catch _:_ -> <<>>
    end.

%% The server's certificate callback (enableCertCb): oncertcb runs in the
%% realm, and the handshake waits in ssl's process for certCbDone.
sni_fun(Realm, Id) ->
    fun(ServerName) ->
        Self = self(),
        Name = unicode:characters_to_binary(ServerName),
        buoy_node_stream:call(Realm, fun() -> cert_cb(Id, Name, Self) end),
        receive
            {'$buoy_tls_sni', Options} -> Options
        after 60000 ->
            []
        end
    end.

keylog_fun(Realm, Id) ->
    fun(#{items := Items}) ->
        Lines = [unicode:characters_to_binary([Item, "\n"]) || Item <- Items],
        buoy_node_stream:call(Realm, fun() -> keylog(Id, Lines) end);
       (_) -> ok
    end.

cert_cb(Id, Name, Waiting) ->
    case by_id(Id) of
        undefined ->
            Waiting ! {'$buoy_tls_sni', []};
        This ->
            S = state(This),
            save(This, S#{sni_waiting := Waiting}),
            Info = buoy_node:object([{<<"servername">>, buoy_node:string(Name)}, {<<"OCSPRequest">>, false}]),
            call_js(This, <<"oncertcb">>, [Info])
    end.

%% certCbDone(): the handshake goes on with the context that tls.js set as
%% sni_context, if it set one.
cert_cb_done(This) ->
    case state(This) of
        #{sni_waiting := Waiting} = S when is_pid(Waiting) ->
            save(This, S#{sni_waiting := none}),
            Context = buoy_heap:get(This, <<"sni_context">>),
            Options = case buoy_crypto_context:is_context(Context) of
                true -> [O || {K, _} = O <- buoy_crypto_context:options(Context, server), lists:member(K, [certs_keys, cacerts])];
                false -> []
            end,
            Waiting ! {'$buoy_tls_sni', Options};
        _ ->
            ok
    end,
    undefined.

keylog(Id, Lines) ->
    case by_id(Id) of
        undefined -> ok;
        This -> [call_js(This, <<"onkeylog">>, [buoy_node_encoding:new_buffer(L)]) || L <- Lines]
    end.

%%% The agent

agent(Realm, Id, Role, Options) ->
    erlang:monitor(process, Realm),
    Socket = buoy_tls_transport:socket(Realm, Id),
    Result = try
        case Role of
            client -> ssl:connect(Socket, Options, infinity);
            server -> ssl:handshake(Socket, Options, infinity)
        end
    catch
        Class:Reason -> {error, {Class, Reason}}
    end,
    {Errors, Chain} = verification(),
    Report = fun(Event) -> buoy_node_stream:call(Realm, fun() -> event(Id, Event) end) end,
    case Result of
        {ok, Ssl} ->
            Report({handshake, {ok, connection_info(Ssl, Errors, Chain)}}),
            agent_loop(Ssl, Report, false, false);
        {error, Reason2} ->
            Report({handshake, {error, Reason2}})
    end.

%% The verification messages that ssl's process sent before the handshake
%% ended: they are in the mailbox before ssl's reply.
verification() -> verification([], []).

verification(Errors, Chain) ->
    receive
        {verify_error, Reason, Der} -> verification([{Reason, Der} | Errors], Chain);
        {verify_chain, Der} -> verification(Errors, [Der | Chain])
    after 0 ->
        {lists:reverse(Errors), Chain}
    end.

connection_info(Ssl, Errors, Chain) ->
    Items = case ssl:connection_information(Ssl, [protocol, selected_cipher_suite, sni_hostname, session_resumption,
                                                  selected_group, session_id, session_data]) of
        {ok, I} -> maps:from_list(I);
        _ -> #{}
    end,
    Peer = case ssl:peercert(Ssl) of
        {ok, Der} -> Der;
        _ -> none
    end,
    Alpn = case ssl:negotiated_protocol(Ssl) of
        {ok, P} -> P;
        _ -> false
    end,
    #{items => Items, peer => Peer, alpn => Alpn, errors => Errors, chain => Chain}.

agent_loop(Ssl, Report, Reading, Armed) ->
    receive
        {write, Ref, Bytes} ->
            Status = case ssl:send(Ssl, Bytes) of
                ok -> ok;
                {error, Reason} -> {error, Reason}
            end,
            Report({written, Ref, Status}),
            agent_loop(Ssl, Report, Reading, Armed);
        {reading, true} when not Armed ->
            arm(Ssl, Report, true);
        {reading, Flag} ->
            agent_loop(Ssl, Report, Flag, Armed);
        %% The agent owns one ssl socket, and ssl's messages may carry a
        %% copy of its record whose fields differ from the one connect gave.
        {ssl, session_ticket, {_Sni, Ticket}} ->
            Report({ticket, Ticket}),
            agent_loop(Ssl, Report, Reading, Armed);
        {ssl, _, Data} when is_binary(Data) ->
            Report({cleartext, Data}),
            case Reading of
                true -> arm(Ssl, Report, true);
                false -> agent_loop(Ssl, Report, false, false)
            end;
        {ssl_closed, _} ->
            Report(cleartext_eof);
        {ssl_error, _, Reason} ->
            Report({error, Reason}),
            agent_loop(Ssl, Report, Reading, Armed);
        {shutdown, Ref} ->
            Status = case ssl:shutdown(Ssl, write) of
                ok -> ok;
                {error, Reason} -> {error, Reason}
            end,
            Report({shutdown, Ref, Status}),
            agent_loop(Ssl, Report, Reading, Armed);
        {export, From, Ref, Label, Context, Length} ->
            %% The secret stays for the next export (ConsumeSecret false).
            From ! {Ref, try ssl:export_key_materials(Ssl, [Label], [Context], [Length], false) catch _:_ -> error end},
            agent_loop(Ssl, Report, Reading, Armed);
        close ->
            ssl:close(Ssl);
        {'DOWN', _, process, _, _} ->
            ssl:close(Ssl)
    end.

%% Asks ssl for the next read. A connection that ended while its owner
%% did not read is gone without an ssl_closed message, as ssl stops a
%% connection whose passive owner has no receive waiting.
arm(Ssl, Report, Reading) ->
    case ssl:setopts(Ssl, [{active, once}]) of
        ok -> agent_loop(Ssl, Report, Reading, true);
        {error, _} -> Report(cleartext_eof)
    end.

%%% Events of the agent, in the realm

event(Id, Event) ->
    case by_id(Id) of
        undefined -> ok;
        This -> event(This, state(This), Event)
    end.

event(This, S, {handshake, {ok, Info}}) ->
    buoy_node_loop:unref_handle(),
    save(This, S#{phase := open, info := Info}),
    #{agent := Agent, pending := Pending, reading := Reading, server := Server, shutdown := Shutdown} = S,
    [Agent ! {write, Ref, Bytes} || {Ref, Bytes} <- Pending],
    save(This, (state(This))#{pending := []}),
    Reading andalso (Agent ! {reading, true}),
    Shutdown =/= none andalso (Agent ! {shutdown, Shutdown}),
    call_js(This, <<"onhandshakedone">>, []),
    Server =:= false andalso maps:get(session_callbacks, S) andalso tls12_session(This, Info);
event(This, S, {handshake, {error, Reason}}) ->
    save(This, S#{phase := failed}),
    buoy_node_loop:unref_handle(),
    case Reason of
        closed -> cleartext_end(This);
        _ -> call_js(This, <<"onerror">>, [handshake_error(Reason, maps:get(server, S))])
    end;
event(This, S, {cleartext, Data}) ->
    case S of
        #{reading := true, cleartext := []} -> deliver(This, Data);
        #{cleartext := Buffered} -> save(This, S#{cleartext := Buffered ++ [Data]})
    end;
event(This, _S, cleartext_eof) ->
    save(This, (state(This))#{phase := closed}),
    cleartext_end(This);
event(This, S, {written, Ref, Status}) ->
    #{writes := Writes, queued := Queued} = S,
    case maps:take(Ref, Writes) of
        {{Req, Size}, Rest} ->
            save(This, S#{writes := Rest, queued := Queued - Size}),
            complete(Req, status(Status), This);
        error ->
            ok
    end;
event(This, S, {shutdown, Req, Status}) ->
    save(This, S#{shutdown := none}),
    complete(Req, status(Status), This);
event(This, S, {ticket, Ticket}) ->
    save(This, S#{ticket => Ticket}),
    maps:get(session_callbacks, S) andalso
        call_js(This, <<"onnewsession">>, [buoy_node_encoding:new_buffer(<<>>),
                                          buoy_node_encoding:new_buffer(term_to_binary({tls13_ticket, Ticket}))]);
event(This, _S, {error, Reason}) ->
    call_js(This, <<"onerror">>, [handshake_error(Reason, false)]).

tls12_session(This, #{items := #{protocol := Protocol, session_id := Id, session_data := Data}}) when Protocol =/= 'tlsv1.3' ->
    call_js(This, <<"onnewsession">>, [buoy_node_encoding:new_buffer(Id), buoy_node_encoding:new_buffer(term_to_binary({tls12, Id, Data}))]);
tls12_session(_, _) ->
    ok.

status(ok) -> 0;
status({error, closed}) -> buoy_node_socket:errno(epipe);
status({error, Reason}) -> buoy_node_socket:errno(Reason).

call_js(This, Name, Args) ->
    F = buoy_heap:get(This, Name),
    buoy_heap:is_callable(F) andalso buoy_heap:call(F, This, Args).

%%% The transport, in the realm

%% An event of buoy_tls_transport, sent from a process of ssl.
-spec transport(reference(), term()) -> ok.
transport(Id, Event) ->
    case by_id(Id) of
        undefined -> ok;
        This -> transport_event(This, state(This), Event)
    end,
    ok.

transport_event(_This, S, {send, Data}) ->
    buoy_node_socket:write_raw(maps:get(parent, S), Data);
transport_event(This, S, {active, Caller, Mode}) ->
    save(This, S#{controller := Caller, active := Mode}),
    pump(This);
transport_event(This, S, {controller, Pid}) ->
    save(This, S#{controller := Pid}),
    pump(This);
transport_event(_This, S, {shutdown, How}) when How =:= write; How =:= read_write ->
    buoy_node_socket:shutdown_raw(maps:get(parent, S));
transport_event(_This, _S, _) ->
    ok.

%% The parent read: encrypted bytes for ssl, the end, or an error.
parent_event(Id, Event) ->
    case by_id(Id) of
        undefined -> ok;
        This -> encrypted_in(This, Event)
    end.

encrypted_in(This, {data, Data}) ->
    #{inbox := Inbox, inbox_size := Size, parent := Parent} = S = state(This),
    save(This, S#{inbox := [Data | Inbox], inbox_size := Size + byte_size(Data)}),
    Size + byte_size(Data) > ?INBOX_LIMIT andalso buoy_node_socket:read_stop(Parent),
    pump(This);
encrypted_in(This, eof) ->
    save(This, (state(This))#{peer_eof := true}),
    pump(This);
encrypted_in(This, {error, Status}) ->
    S = state(This),
    case S of
        #{controller := Pid} when is_pid(Pid) ->
            Pid ! {buoy_tls_error, transport_socket(S), econnreset};
        _ ->
            ok
    end,
    buoy_heap:set(stream_state(), ?K_READ_BYTES, Status),
    call_js(This, <<"onread">>, [undefined]).

transport_socket(#{id := Id}) -> buoy_tls_transport:socket(self(), Id).

%% Passes the waiting bytes to ssl while its active mode takes them.
pump(This) ->
    S = state(This),
    case S of
        #{controller := Pid, active := Active, inbox := [_ | _] = Inbox, parent := Parent} when is_pid(Pid), Active =/= false ->
            Socket = transport_socket(S),
            Pid ! {buoy_tls, Socket, iolist_to_binary(lists:reverse(Inbox))},
            Next = case Active of
                once -> false;
                true -> true;
                N when is_integer(N), N > 1 -> N - 1;
                _ -> Pid ! {buoy_tls_passive, Socket}, false
            end,
            save(This, S#{inbox := [], inbox_size := 0, active := Next}),
            maps:get(inbox_size, S) > ?INBOX_LIMIT andalso buoy_node_socket:read_start(Parent),
            ok;
        %% A closed transport tells each activation again, as gen_tcp's
        %% setopts fails on a closed socket: ssl defers a close that came
        %% while its owner did not read, until it activates the transport.
        #{controller := Pid, active := Active, inbox := [], peer_eof := true} when is_pid(Pid), Active =/= false ->
            Pid ! {buoy_tls_closed, transport_socket(S)},
            save(This, S#{active := false});
        _ ->
            ok
    end.

%%% The stream

stream_state() ->
    buoy_heap:get(buoy_node:binding(<<"stream_wrap">>), <<"streamBaseState">>).

set_reading(This, Reading) ->
    S = state(This),
    save(This, S#{reading := Reading}),
    case {S, Reading} of
        {#{phase := idle, server := true}, true} -> begin_handshake(This, server);
        {#{phase := open, agent := Agent}, _} -> Agent ! {reading, Reading};
        _ -> ok
    end,
    case Reading of
        true -> drain(This);
        false -> ok
    end.

%% Cleartext that arrived while the stream did not read.
drain(This) ->
    case state(This) of
        #{reading := true, cleartext := [Data | Rest]} = S ->
            save(This, S#{cleartext := Rest}),
            deliver(This, Data),
            drain(This);
        #{reading := true, cleartext := [], eof := pending} = S ->
            save(This, S#{eof := done}),
            cleartext_end(This);
        _ ->
            ok
    end.

deliver(This, Data) ->
    S = state(This),
    save(This, S#{read := maps:get(read, S) + byte_size(Data)}),
    State = stream_state(),
    buoy_heap:set(State, ?K_READ_BYTES, byte_size(Data)),
    buoy_heap:set(State, ?K_OFFSET, 0),
    Buffer = buoy_ref_buffer:allocate(byte_size(Data)),
    buoy_ref_buffer:write(Buffer, 0, Data),
    call_js(This, <<"onread">>, [Buffer]).

cleartext_end(This) ->
    case state(This) of
        #{cleartext := [_ | _]} = S -> save(This, S#{eof := pending});
        #{reading := false} = S -> save(This, S#{eof := pending});
        _ ->
            buoy_heap:set(stream_state(), ?K_READ_BYTES, ?UV_EOF),
            call_js(This, <<"onread">>, [undefined])
    end.

%% A cleartext write: it waits for the handshake, then goes to the agent,
%% and completes when ssl took it (kLastWriteWasAsync is 1).
write(This, Req, Bytes) ->
    State = stream_state(),
    buoy_heap:set(State, ?K_BYTES_WRITTEN, byte_size(Bytes)),
    buoy_heap:set(State, ?K_ASYNC, 1),
    #{phase := Phase, agent := Agent, pending := Pending, writes := Writes, queued := Queued} = S = state(This),
    Ref = make_ref(),
    S1 = S#{writes := Writes#{Ref => {Req, byte_size(Bytes)}}, queued := Queued + byte_size(Bytes),
            written := maps:get(written, S) + byte_size(Bytes)},
    case Phase of
        open -> save(This, S1), Agent ! {write, Ref, Bytes}, 0;
        P when P =:= idle; P =:= handshaking -> save(This, S1#{pending := Pending ++ [{Ref, Bytes}]}), 0;
        _ -> buoy_heap:set(State, ?K_ASYNC, 0), buoy_node_socket:errno(epipe)
    end.

complete(Req, Status, This) ->
    F = buoy_heap:get(Req, <<"oncomplete">>),
    buoy_heap:is_callable(F) andalso buoy_heap:call(F, Req, [Status, This, undefined]).

writev_bytes(Chunks, true) ->
    iolist_to_binary([buoy_node_encoding:view_bytes(C) || C <- buoy_heap:array_items(Chunks)]);
writev_bytes(Chunks, false) ->
    iolist_to_binary(pairs(buoy_heap:array_items(Chunks))).

pairs([Chunk, Encoding | Rest]) ->
    Bytes = case buoy_heap:is_object(Chunk) of
        true -> buoy_node_encoding:view_bytes(Chunk);
        false ->
            Enc = case buoy_node_encoding:parse(Encoding) of
                {ok, E} -> E;
                error -> utf8
            end,
            buoy_node_encoding:encode(Enc, Chunk)
    end,
    [Bytes | pairs(Rest)];
pairs(_) -> [].

%% shutdown(req): close_notify, then the parent's write side shuts.
shutdown(This, Req) ->
    case state(This) of
        #{phase := open, agent := Agent} = S -> save(This, S#{shutdown := Req}), Agent ! {shutdown, Req}, 0;
        #{phase := P} = S when P =:= idle; P =:= handshaking -> save(This, S#{shutdown := Req}), 0;
        _ -> 1
    end.

destroy(This) ->
    case state(This) of
        #{agent := Agent, phase := Phase, id := Id} = S when is_pid(Agent) ->
            Agent ! close,
            Phase =:= handshaking andalso buoy_node_loop:unref_handle(),
            save(This, S#{agent := none, phase := closed}),
            erlang:erase({?MODULE, Id});
        #{id := Id} = S ->
            save(This, S#{phase := closed}),
            erlang:erase({?MODULE, Id})
    end.

%%% The connection's facts

info(This, Key, Default) ->
    case state(This) of
        #{info := #{alpn := Alpn}} when Key =:= alpn -> alpn_value(Alpn);
        #{info := #{items := #{protocol := P}}} when Key =:= protocol -> protocol_name(P);
        #{info := #{items := #{session_resumption := R}}} when Key =:= reused -> R;
        _ -> Default
    end.

alpn_value(false) -> false;
alpn_value(P) -> buoy_node:string(P).

protocol_name('tlsv1.3') -> <<"TLSv1.3">>;
protocol_name('tlsv1.2') -> <<"TLSv1.2">>;
protocol_name('tlsv1.1') -> <<"TLSv1.1">>;
protocol_name(tlsv1) -> <<"TLSv1">>;
protocol_name(_) -> null.

%% The wire format of ALPN, length-prefixed names, as a list.
alpn_list(<<Length, Name:Length/binary, Rest/binary>>) -> [Name | alpn_list(Rest)];
alpn_list(_) -> [].

servername(This) ->
    case state(This) of
        #{server := false, servername := Name} when is_binary(Name) -> Name;
        #{info := #{items := #{sni_hostname := Name}}} when Name =/= undefined -> buoy_node:string(Name);
        _ -> false
    end.

session(This) ->
    case state(This) of
        #{ticket := Ticket} -> buoy_node_encoding:new_buffer(term_to_binary({tls13_ticket, Ticket}));
        #{info := #{items := #{protocol := P, session_id := Id, session_data := Data}}} when P =/= 'tlsv1.3', Id =/= <<>> ->
            buoy_node_encoding:new_buffer(term_to_binary({tls12, Id, Data}));
        _ -> undefined
    end.

cipher(This) ->
    case state(This) of
        #{info := #{items := #{selected_cipher_suite := Suite, protocol := Protocol}}} ->
            Standard = list_to_binary(ssl:suite_to_str(Suite)),
            Name = try list_to_binary(ssl:suite_to_openssl_str(Suite)) catch _:_ -> Standard end,
            Version = case Protocol of
                'tlsv1.3' -> <<"TLSv1.3">>;
                _ -> cipher_version(Suite)
            end,
            buoy_node:object([{<<"name">>, Name}, {<<"standardName">>, Standard}, {<<"version">>, Version}]);
        _ ->
            null
    end.

%% SSL_CIPHER_get_version: the version that introduced the suite.
cipher_version(#{mac := aead}) -> <<"TLSv1.2">>;
cipher_version(#{prf := sha256}) -> <<"TLSv1.2">>;
cipher_version(#{prf := sha384}) -> <<"TLSv1.2">>;
cipher_version(_) -> <<"TLSv1">>.

ephemeral_key(This) ->
    case state(This) of
        #{server := false, info := #{items := #{selected_group := Group}}} ->
            {Name, Size} = case Group of
                x25519 -> {<<"X25519">>, 253};
                x448 -> {<<"X448">>, 448};
                secp256r1 -> {<<"prime256v1">>, 256};
                secp384r1 -> {<<"secp384r1">>, 384};
                secp521r1 -> {<<"secp521r1">>, 521};
                Other -> {atom_to_binary(Other), 0}
            end,
            buoy_node:object([{<<"type">>, <<"ECDH">>}, {<<"name">>, Name}, {<<"size">>, Size}]);
        _ ->
            buoy_node:object([])
    end.

%% getPeerCertificate(detailed): the legacy object of the peer's
%% certificate; a detailed one links each issuer up to the root.
peer_certificate(This, Detailed) ->
    case state(This) of
        #{info := #{peer := Der} = Info} when is_binary(Der) ->
            Chain = [D || D <- lists:reverse(maps:get(chain, Info, [])), D =/= Der],
            Leaf = legacy(Der),
            Detailed andalso link_issuers(Leaf, Chain),
            Leaf;
        _ ->
            undefined
    end.

link_issuers(Cert, []) ->
    buoy_heap:set(Cert, <<"issuerCertificate">>, Cert);
link_issuers(Cert, [Next | Rest]) ->
    Issuer = legacy(Next),
    buoy_heap:set(Cert, <<"issuerCertificate">>, Issuer),
    link_issuers(Issuer, Rest).

legacy(Der) ->
    Handle = buoy_crypto_x509:certificate(Der),
    buoy_heap:call(buoy_heap:get(Handle, <<"toLegacy">>), Handle, []).

peer_x509(This) ->
    case state(This) of
        #{info := #{peer := Der}} when is_binary(Der) -> buoy_crypto_x509:certificate(Der);
        _ -> undefined
    end.

own_certificate(This, Form) ->
    #{context := Context} = state(This),
    case buoy_heap:call(buoy_heap:get(Context, <<"getCertificate">>), Context, []) of
        null -> undefined;
        Buffer when Form =:= legacy -> legacy(buoy_node_encoding:view_bytes(Buffer));
        Buffer -> buoy_crypto_x509:certificate(buoy_node_encoding:view_bytes(Buffer))
    end.

export_keying_material(This, Length, Label, Context) ->
    case state(This) of
        #{phase := open, agent := Agent} ->
            Ref = make_ref(),
            Ctx = case Context of
                undefined -> no_context;
                _ -> buoy_node_encoding:view_bytes(Context)
            end,
            Agent ! {export, self(), Ref, text(Label), Ctx, trunc(buoy_ref:to_number(Length))},
            receive
                {Ref, {ok, [Bytes]}} -> buoy_node_encoding:new_buffer(Bytes);
                {Ref, _} -> buoy_node:throw_code('Error', <<"ERR_CRYPTO_OPERATION_FAILED">>, <<"Key export failed">>)
            after 5000 ->
                buoy_node:throw_code('Error', <<"ERR_CRYPTO_OPERATION_FAILED">>, <<"Key export failed">>)
            end;
        _ ->
            buoy_node:throw_code('Error', <<"ERR_TLS_INVALID_STATE">>, <<"TLS socket connection must be securely established">>)
    end.

%%% Errors

%% verifyError(): the first verification error, as an Error with the code
%% of X509_verify_cert_error_string, or null.
verify_error(This) ->
    case state(This) of
        #{info := #{errors := [{Reason, Der} | _]} = Info} ->
            {Code, Message} = x509_error(Reason, Der, Info),
            E = buoy_heap:error_object('Error', Message, <<"Error: ", Message/binary>>),
            buoy_heap:set(E, <<"code">>, Code),
            E;
        #{info := #{peer := none}, server := true} ->
            E = buoy_heap:error_object('Error', <<"unspecified certificate verification error">>,
                                       <<"Error: unspecified certificate verification error">>),
            buoy_heap:set(E, <<"code">>, <<"UNSPECIFIED">>),
            E;
        _ ->
            null
    end.

x509_error(selfsigned_peer, _, _) ->
    {<<"DEPTH_ZERO_SELF_SIGNED_CERT">>, <<"self-signed certificate">>};
x509_error(unknown_ca, Der, #{peer := Peer}) ->
    case {is_self_signed(Der), Der =:= Peer} of
        {true, _} -> {<<"SELF_SIGNED_CERT_IN_CHAIN">>, <<"self-signed certificate in certificate chain">>};
        {false, true} -> {<<"UNABLE_TO_VERIFY_LEAF_SIGNATURE">>, <<"unable to verify the first certificate">>};
        {false, false} -> {<<"UNABLE_TO_GET_ISSUER_CERT_LOCALLY">>, <<"unable to get local issuer certificate">>}
    end;
x509_error(cert_expired, Der, _) ->
    case not_yet_valid(Der) of
        true -> {<<"CERT_NOT_YET_VALID">>, <<"certificate is not yet valid">>};
        false -> {<<"CERT_HAS_EXPIRED">>, <<"certificate has expired">>}
    end;
x509_error(invalid_signature, _, _) -> {<<"CERT_SIGNATURE_FAILURE">>, <<"certificate signature failure">>};
x509_error(invalid_issuer, _, _) -> {<<"UNABLE_TO_GET_ISSUER_CERT">>, <<"unable to get issuer certificate">>};
x509_error(missing_basic_constraint, _, _) -> {<<"INVALID_CA">>, <<"invalid CA certificate">>};
x509_error(invalid_key_usage, _, _) -> {<<"INVALID_PURPOSE">>, <<"unsupported certificate purpose">>};
x509_error({revoked, _}, _, _) -> {<<"CERT_REVOKED">>, <<"certificate revoked">>};
x509_error(name_not_permitted, _, _) -> {<<"PERMITTED_VIOLATION">>, <<"permitted subtree violation">>};
x509_error(_, _, _) -> {<<"UNSPECIFIED">>, <<"unspecified certificate verification error">>}.

is_self_signed(<<>>) -> false;
is_self_signed(Der) -> public_key:pkix_is_self_signed(Der).

not_yet_valid(Der) ->
    case buoy_crypto_x509:decode(Der) of
        {ok, #{not_before := {Date, Time, _}}} ->
            calendar:datetime_to_gregorian_seconds({Date, Time}) > calendar:datetime_to_gregorian_seconds(calendar:universal_time());
        _ ->
            false
    end.

%% The error of a failed handshake, with OpenSSL's text and code: an alert
%% that the peer sent is "<version> alert <name>", and one that this side
%% raised is the reason that OpenSSL gives for it.
handshake_error({tls_alert, {Alert, Description}}, Server) ->
    Received = string:find(Description, "received") =/= nomatch,
    {Number, Text} = case Received of
        true -> {1000 + alert_code(Alert), alert_text(Alert)};
        false -> local_reason(Alert, Description, Server)
    end,
    buoy_crypto_context:ssl_error_value(Number, Text, ssl);
handshake_error({options, _} = Reason, _) ->
    message(io_lib:format("TLS options rejected: ~p", [Reason]));
handshake_error(Reason, _) ->
    message(io_lib:format("~p", [Reason])).

message(Text) ->
    Bin = unicode:characters_to_binary(Text),
    buoy_heap:error_object('Error', Bin, <<"Error: ", Bin/binary>>).

local_reason(insufficient_security, _, _) -> {16#C1, <<"no shared cipher">>};
local_reason(handshake_failure, Description, _) ->
    case string:find(Description, "cipher") of
        nomatch -> {16#410, <<"sslv3 alert handshake failure">>};
        _ -> {16#C1, <<"no shared cipher">>}
    end;
local_reason(protocol_version, _, _) -> {16#102, <<"unsupported protocol">>};
local_reason(certificate_required, _, _) -> {16#C7, <<"peer did not return a certificate">>};
local_reason(no_application_protocol, _, _) -> {16#EB, <<"no application protocol">>};
local_reason(unexpected_message, _, _) -> {16#10B, <<"wrong version number">>};
local_reason(decode_error, _, _) -> {16#10B, <<"wrong version number">>};
local_reason(record_overflow, _, _) -> {16#C6, <<"packet length too long">>};
local_reason(bad_certificate, _, _) -> {16#86, <<"certificate verify failed">>};
local_reason(unknown_ca, _, _) -> {16#86, <<"certificate verify failed">>};
local_reason(Alert, _, _) -> {1000 + alert_code(Alert), alert_text(Alert)}.

alert_code(close_notify) -> 0;
alert_code(unexpected_message) -> 10;
alert_code(bad_record_mac) -> 20;
alert_code(record_overflow) -> 22;
alert_code(handshake_failure) -> 40;
alert_code(bad_certificate) -> 42;
alert_code(unsupported_certificate) -> 43;
alert_code(certificate_revoked) -> 44;
alert_code(certificate_expired) -> 45;
alert_code(certificate_unknown) -> 46;
alert_code(illegal_parameter) -> 47;
alert_code(unknown_ca) -> 48;
alert_code(access_denied) -> 49;
alert_code(decode_error) -> 50;
alert_code(decrypt_error) -> 51;
alert_code(protocol_version) -> 70;
alert_code(insufficient_security) -> 71;
alert_code(internal_error) -> 80;
alert_code(inappropriate_fallback) -> 86;
alert_code(user_canceled) -> 90;
alert_code(no_renegotiation) -> 100;
alert_code(missing_extension) -> 109;
alert_code(unsupported_extension) -> 110;
alert_code(unrecognized_name) -> 112;
alert_code(bad_certificate_status_response) -> 113;
alert_code(unknown_psk_identity) -> 115;
alert_code(certificate_required) -> 116;
alert_code(no_application_protocol) -> 120;
alert_code(_) -> 80.

%% The text of SSL_R_SSLV3_ALERT_* and SSL_R_TLSV1_ALERT_* reasons.
alert_text(Alert) ->
    Words = binary:replace(atom_to_binary(Alert), <<"_">>, <<" ">>, [global]),
    case alert_code(Alert) of
        116 -> <<"tlsv13 alert certificate required">>;
        112 -> <<"tlsv1 unrecognized name">>;
        Code when Code < 48 -> <<"sslv3 alert ", Words/binary>>;
        _ -> <<"tlsv1 alert ", Words/binary>>
    end.
