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
%% The random of a HelloRetryRequest, SHA-256 of "HelloRetryRequest".
-define(HRR_RANDOM, 16#CF21AD74E59A6111BE1D8C021E65B891C2A211167ABB8C5E079E09E2C8A8339C).

-spec binding() -> term().
binding() ->
    Class = buoy_node:constructor(<<"TLSWrap">>, 0, fun(_, _) -> undefined end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    erlang:put({?MODULE, class}, Class),
    A = fun buoy_node:arg/2,
    Write = fun(Encode) -> fun(This, Args) -> write(This, A(1, Args), Encode(A(2, Args))) end end,
    Methods = [
        {<<"writeBuffer">>, Write(fun buoy_node_socket:buffer_bytes/1)},
        {<<"writeUtf8String">>, Write(fun(V) -> buoy_node_encoding:encode(utf8, V) end)},
        {<<"writeAsciiString">>, Write(fun(V) -> buoy_node_encoding:encode(latin1, V) end)},
        {<<"writeLatin1String">>, Write(fun(V) -> buoy_node_encoding:encode(latin1, V) end)},
        {<<"writeUcs2String">>, Write(fun(V) -> buoy_node_encoding:encode(ucs2, V) end)},
        {<<"writev">>, fun(This, Args) -> write(This, A(1, Args), writev_bytes(A(2, Args), buoy_ref:truthy(A(3, Args)))) end},
        {<<"readStart">>, fun(This, _) -> set_reading(This, true), 0 end},
        {<<"readStop">>, fun(This, _) -> set_reading(This, false), 0 end},
        {<<"shutdown">>, fun(This, Args) -> shutdown(This, A(1, Args)) end},
        {<<"useUserBuffer">>, fun(This, Args) -> put(This, user_buffer, A(1, Args)) end},
        {<<"getAsyncId">>, fun(This, _) -> maps:get(async_id, state(This)) end},
        {<<"getProviderType">>, fun(_, _) -> 0 end},
        {<<"start">>, fun(This, _) -> start(This), undefined end},
        {<<"setVerifyMode">>, fun(This, Args) -> put(This, verify, {buoy_ref:truthy(A(1, Args)), buoy_ref:truthy(A(2, Args))}) end},
        {<<"enableSessionCallbacks">>, fun(This, _) -> put(This, session_callbacks, true) end},
        {<<"enableKeylogCallback">>, fun(This, _) -> put(This, keylog, true) end},
        {<<"enableTrace">>, fun(_, _) -> undefined end},
        {<<"enableCertCb">>, fun(This, _) -> put(This, cert_cb, true) end},
        {<<"enableALPNCb">>, fun(This, _) -> put(This, alpn_cb, true) end},
        {<<"enablePskCallback">>, fun(_, _) -> undefined end},
        {<<"setPskIdentityHint">>, fun(This, Args) -> set_psk_identity_hint(This, A(1, Args)) end},
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
        {<<"getTLSTicket">>, fun(This, _) -> tls_ticket(This) end},
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
        {<<"renegotiate">>, fun(This, _) -> renegotiate(This) end},
        {<<"destroySSL">>, fun(This, _) -> destroy(This), undefined end},
        {<<"setOCSPResponse">>, fun(_, _) -> undefined end},
        {<<"requestOCSP">>, fun(_, _) -> undefined end},
        %% SSL_set_max_send_fragment takes 512 to 16384; ssl keeps its own
        %% record size.
        {<<"setMaxSendFragment">>, fun(_, Args) -> Size = buoy_ref:to_number(A(1, Args)), Size >= 512 andalso Size =< 16384 end},
        {<<"setKeyCert">>, fun(This, Args) -> put(This, key_cert, A(1, Args)) end},
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

%% SSL_use_psk_identity_hint refuses a hint past PSK_MAX_IDENTITY_LEN, and
%% TLSWrap reports it through onerror.
set_psk_identity_hint(This, Hint) ->
    case byte_size(text(Hint)) > 256 of
        true ->
            Message = <<"Failed to set PSK identity hint">>,
            E = buoy_heap:error_object('Error', Message, <<"Error: ", Message/binary>>),
            buoy_heap:set(E, <<"code">>, <<"ERR_TLS_PSK_SET_IDENTITY_HINT_FAILED">>),
            call_js(This, <<"onerror">>, [E]),
            undefined;
        false ->
            undefined
    end.

%%% State

state(This) ->
    case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, ?STATE) of
        {ok, S} -> S;
        _ -> buoy_ref:type_error(<<"Illegal invocation">>)
    end.

%% Saves the state. The wrap holds the loop from the end of the parent's
%% stream until ssl reports it, while JavaScript reads: libuv stops the
%% parent's read at EOF, as Node's TLSWrap decodes it in the same callback,
%% but ssl decodes it in the agent, after the loop could have ended.
save(This, S) ->
    Held = case buoy_heap:private_find(This, ?STATE) of
        {ok, Old} -> holds_eof(Old);
        error -> false
    end,
    case {Held, holds_eof(S)} of
        {false, true} -> buoy_node_loop:ref_handle();
        {true, false} -> buoy_node_loop:unref_handle();
        _ -> ok
    end,
    buoy_heap:private_put(This, ?STATE, S).

holds_eof(#{phase := open, peer_eof := true, reading := true}) -> true;
holds_eof(_) -> false.

put(This, Key, Value) ->
    save(This, (state(This))#{Key => Value}),
    undefined.

by_id(Id) -> erlang:get({?MODULE, Id}).

%% wrap(handle, context, isServer): the TLSWrap over the stream handle
%% handle, which hands its reads to it from now on.
wrap(Parent, Context, Server) ->
    buoy_crypto_context:is_context(Context) orelse
        buoy_node:throw_code('TypeError', <<"ERR_TLS_INVALID_CONTEXT">>, <<"context must be a SecureContext">>),
    %% A Pipe that has not connected yet becomes a local socket now.
    buoy_node_socket:find(Parent) =:= error
        andalso buoy_heap:get(Parent, <<"constructor">>) =:= erlang:get({buoy_node_socket, constructor, pipe})
        andalso buoy_node_socket:create(Parent, pipe),
    Class = erlang:get({?MODULE, class}),
    This = buoy_heap:construct(Class, [], Class),
    Id = make_ref(),
    erlang:put({?MODULE, Id}, This),
    save(This, #{id => Id, parent => Parent, context => Context, server => Server, phase => idle, agent => none,
                 verify => {not Server, false}, servername => none, alpn => none, session => none,
                 session_callbacks => false, keylog => false, cert_cb => false, sni_waiting => none,
                 reading => false, cleartext => [], eof => false, pending => [], writes => #{}, queued => 0,
                 shutdown => none, controller => none, active => false, inbox => [], inbox_size => 0,
                 peer_eof => false, info => #{}, read => 0, written => 0, delivered => 0, tls_eof => false,
                 flight => case Server of true -> off; false -> {sniff, <<>>} end, reneg => off,
                 kex => case Server of true -> off; false -> {scan, <<>>} end,
                 async_id => new_async_id()}),
    Reading = listen(Parent, Id),
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
    Options = ssl_options(S, Role, Agent),
    Agent ! {options, case Role of client -> Options; server -> server_options(Options) end},
    save(This, S#{phase := handshaking, agent := Agent}),
    hold(This, handshake),
    parent_read(Parent, true),
    Role =:= server andalso call_js(This, <<"onhandshakestart">>, [buoy_node_loop:now()]),
    ok.

%% The ssl application and its dependencies, started once per VM.
start_ssl() ->
    case persistent_term:get({?MODULE, ssl}, false) of
        true -> ok;
        false ->
            %% OpenSSL's server sends two TLS 1.3 tickets.
            application:set_env(ssl, server_session_tickets_amount, 2),
            {ok, _} = application:ensure_all_started(ssl),
            %% ssl loads a module on its first alert or close_notify; a load
            %% that waits on the disk then stalls a connection mid-stream.
            {ok, Modules} = application:get_key(ssl, modules),
            ok = code:ensure_modules_loaded(Modules),
            persistent_term:put({?MODULE, ssl}, true),
            ok
    end.

%% The ssl options of the connection; the verify_fun reports to Agent.
ssl_options(S, Role, Agent) ->
    #{context := Context, verify := {Request, Reject}, servername := Name, alpn := Alpn, session := Session} = S,
    Base = buoy_crypto_context:options(Context, Role),
    Cas = proplists:get_value(cacerts, Base, []),
    Verify = case {Role, Request} of
        {server, false} -> [{verify, verify_none}];
        %% SSL_VERIFY_FAIL_IF_NO_PEER_CERT comes with rejectUnauthorized.
        {server, true} -> [{verify, verify_peer}, {fail_if_no_peer_cert, Reject}, {verify_fun, verify_fun(Agent, Cas)}];
        {client, _} -> [{verify, verify_peer}, {verify_fun, verify_fun(Agent, Cas)}]
    end,
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
        %% Servers that share ticketKeys resume each other's tickets.
        {server, _} -> [{session_tickets, stateless}, {stateless_tickets_seed, buoy_crypto_context:ticket_keys(Context)}]
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
    Tickets = [O || O <- Resume, Tls13 orelse not lists:member(element(1, O), [session_tickets, use_ticket, stateless_tickets_seed]),
                    Older orelse not lists:member(element(1, O), [reuse_sessions, reuse_session])],
    [{cb_info, buoy_tls_transport:cb_info()}, {log_level, none}, {handshake, full}]
        ++ Verify ++ Sni ++ AlpnOption ++ Tickets ++ SniFun ++ Keylog
        ++ [{buoy_alpn_cb, true} || Role =:= server, maps:get(alpn_cb, S, false)] ++ Base.

self_realm() -> self().

%% A server connection comes from an ssl listener of the realm, so that ssl
%% runs its TLS 1.3 ticket tracker, which a socket that ssl upgrades lacks.
%% Connections with the same context options share one listener; the
%% options of one connection join at the handshake.
%% shortcut: a listener lives as long as its realm, so a server that
%% rotates many contexts keeps a UDP socket and three ssl processes for
%% each; close a listener with its last SecureContext if that matters.
server_options(Options) ->
    Own = [verify, fail_if_no_peer_cert, verify_fun, alpn_preferred_protocols, sni_fun, keep_secrets, buoy_alpn_cb],
    {Connection, Shared} = lists:partition(fun(O) -> lists:member(element(1, O), Own) end, Options),
    {listener(Shared), Connection}.

listener(Options) ->
    Key = {?MODULE, listener, erlang:phash2(Options)},
    case erlang:get(Key) of
        undefined ->
            %% The socket options that an upgraded socket takes from the
            %% transport: passive, binary.
            case ssl:listen(0, [{active, false}, {mode, binary} | Options]) of
                {ok, Listen} -> erlang:put(Key, Listen), Listen;
                {error, _} = Error -> Error
            end;
        Listen ->
            Listen
    end.

%% Records each verification error at the agent and lets the handshake go
%% on; the hostname is tls.js's to check (checkServerIdentity).
verify_fun(Agent, Cas) ->
    Fun = fun
        (_Cert, {bad_cert, hostname_check_failed}, State) -> {valid, State};
        (_Cert, {extension, _}, State) -> {unknown, State};
        (Cert, Event, State) ->
            Der = der(Cert),
            %% ssl verifies from the top of the chain down and never shows
            %% the anchor of the store; the peer's chain ends with it.
            State =:= [] andalso anchor(Cert, Cas, Agent),
            Agent ! {verify_chain, Der},
            case Event of
                %% A self-signed certificate that the store holds is
                %% trusted, as OpenSSL trusts it.
                {bad_cert, selfsigned_peer} ->
                    lists:member(Der, Cas) orelse (Agent ! {verify_error, selfsigned_peer, Der});
                %% OpenSSL takes an intermediate of the store as trusted and
                %% then misses its issuer (UNABLE_TO_GET_ISSUER_CERT).
                {bad_cert, unknown_ca} ->
                    Reason = case lists:member(Der, Cas) of true -> stored_issuer_missing; false -> unknown_ca end,
                    Agent ! {verify_error, Reason, Der};
                {bad_cert, Reason} ->
                    Agent ! {verify_error, Reason, Der};
                _ ->
                    ok
            end,
            {valid, started}
    end,
    {Fun, []}.

anchor(Cert, Cas, Agent) ->
    case public_key:pkix_is_self_signed(Cert) of
        true -> ok;
        false ->
            case [Ca || Ca <- Cas, is_issuer(Cert, Ca)] of
                [Ca | _] -> Agent ! {verify_chain, Ca};
                [] -> ok
            end
    end.

is_issuer(Cert, Ca) ->
    try public_key:pkix_is_issuer(Cert, Ca)
    catch _:_ -> false
    end.

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

%% A HelloRetryRequest makes ssl ask again for the second ClientHello;
%% OpenSSL calls the callback once per handshake, so the first answer stays.
cert_cb(Id, Name, Waiting) ->
    case by_id(Id) of
        undefined ->
            Waiting ! {'$buoy_tls_sni', []};
        This ->
            cert_cb(This, state(This), Name, Waiting)
    end.

cert_cb(_This, #{sni_answer := Answer}, _Name, Waiting) ->
    Waiting ! {'$buoy_tls_sni', Answer};
cert_cb(This, S, Name, Waiting) ->
    save(This, S#{sni_waiting := Waiting}),
    %% SelectSNIContextCallback names the server on the socket.
    Owner = buoy_heap:get(This, proplists:get_value(<<"owner_symbol">>, buoy_node:per_isolate_symbols())),
    buoy_heap:is_object(Owner) andalso buoy_heap:set(Owner, <<"servername">>, buoy_node:string(Name)),
    Info = buoy_node:object([{<<"servername">>, buoy_node:string(Name)}, {<<"OCSPRequest">>, false}]),
    call_js(This, <<"oncertcb">>, [Info]).

%% certCbDone(): the handshake goes on with the context that tls.js set as
%% sni_context, if it set one.
cert_cb_done(This) ->
    case state(This) of
        #{sni_waiting := Waiting} = S when is_pid(Waiting) ->
            save(This, S#{sni_waiting := none}),
            Context = buoy_heap:get(This, <<"sni_context">>),
            Answer = case buoy_crypto_context:is_context(Context) of
                true -> [O || {K, _} = O <- buoy_crypto_context:options(Context, server), lists:member(K, [certs_keys, cacerts])];
                false -> []
            end,
            put(This, sni_answer, Answer),
            Waiting ! {'$buoy_tls_sni', Answer},
            %% CertCbDone: an object that is no SecureContext fails.
            buoy_crypto_context:is_context(Context) orelse not buoy_heap:is_object(Context) orelse begin
                E = buoy_heap:error_object('TypeError', <<"Invalid SNI context">>, <<"TypeError: Invalid SNI context">>),
                call_js(This, <<"onerror">>, [E])
            end;
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

agent(Realm, Id, Role, Options0) ->
    erlang:monitor(process, Realm),
    Socket = buoy_tls_transport:socket(Realm, Id),
    {AlpnCallback, Options} = case Options0 of
        {Listen, Own} -> {proplists:get_bool(buoy_alpn_cb, Own), {Listen, proplists:delete(buoy_alpn_cb, Own)}};
        _ -> {false, Options0}
    end,
    Result = try
        case Role of
            client -> ssl:connect(Socket, Options, infinity);
            server -> server_handshake(Realm, Id, Socket, Options, AlpnCallback)
        end
    catch
        Class:Reason -> {error, {Class, Reason}}
    end,
    {Errors, Chain} = verification(),
    Report = fun(Event) -> buoy_node_stream:call(Realm, fun() -> event(Id, Event) end) end,
    case Result of
        {ok, Ssl} ->
            Report({handshake, {ok, connection_info(Ssl, Errors, Chain)}}),
            agent_loop(Ssl, Report, false);
        {error, Reason2} ->
            Report({handshake, {error, Reason2}})
    end.

%% A server stops after the ClientHello, where Node's ALPN callback picks a
%% protocol of the client's list, and goes on.
server_handshake(_Realm, _Id, _Socket, {{error, _} = Error, _}, _AlpnCallback) ->
    Error;
server_handshake(Realm, Id, Socket, {Listen, Options}, AlpnCallback) ->
    %% The transport's accept hands out the socket under this key.
    erlang:put(buoy_tls_accept, Socket),
    case ssl:transport_accept(Listen, infinity) of
        {ok, Accepted} -> server_handshake(Realm, Id, Accepted, Options, AlpnCallback);
        Error -> Error
    end;
server_handshake(Realm, Id, Socket, Options, true) ->
    case ssl:handshake(Socket, [{handshake, hello} | Options], infinity) of
        {ok, Hello, Ext} -> ssl:handshake_continue(Hello, alpn_select(Realm, Id, alpn_wire(Ext)), infinity);
        %% handshake/3 of an accepted socket replies with the bare map of
        %% the ClientHello's extension records.
        {ok, Ext} when is_map(Ext) -> ssl:handshake_continue(Socket, alpn_select(Realm, Id, alpn_wire(Ext)), infinity);
        Other -> Other
    end;
server_handshake(_Realm, _Id, Socket, Options, false) ->
    ssl:handshake(Socket, Options, infinity).

alpn_wire(Ext) ->
    case maps:get(alpn, Ext, undefined) of
        {alpn, Wire} -> Wire;
        Wire -> Wire
    end.

%% The protocol that the ALPN callback chose. None makes ssl refuse the
%% client's list with no_application_protocol, as SSL_TLSEXT_ERR_ALERT_FATAL
%% does; OpenSSL calls no callback when the client offers no ALPN.
alpn_select(Realm, Id, Wire) when is_binary(Wire) ->
    Self = self(),
    buoy_node_stream:call(Realm, fun() -> alpn_callback(Id, Wire, Self) end),
    receive
        {'$buoy_tls_alpn', Protocol, KeyCert} -> [{alpn_preferred_protocols, [Protocol]} | KeyCert]
    after 60000 ->
        []
    end;
alpn_select(_Realm, _Id, _None) ->
    [].

%% setKeyCert in the callback gives this connection the key and the
%% certificate of another context, as SSL_use_certificate does.
alpn_callback(Id, Wire, Agent) ->
    {Offset, KeyCert} = case by_id(Id) of
        undefined ->
            {none, []};
        This ->
            Chosen = call_js(This, <<"ALPNCallback">>, [buoy_node_encoding:new_buffer(Wire)]),
            Context = maps:get(key_cert, state(This), undefined),
            {Chosen, [O || buoy_crypto_context:is_context(Context),
                           {certs_keys, _} = O <- buoy_crypto_context:options(Context, server)]}
    end,
    Protocol = case is_number(Offset) andalso Wire of
        <<_:(trunc(Offset))/binary, Length, Chosen1:Length/binary, _/binary>> -> Chosen1;
        _ -> <<0>>
    end,
    Agent ! {'$buoy_tls_alpn', Protocol, KeyCert}.

%% The verification messages that ssl's process sent before the handshake
%% ended: they are in the mailbox before ssl's reply.
verification() -> verification([], []).

verification(Errors, Chain) ->
    receive
        {verify_error, Reason, Der} -> verification([{Reason, Der} | Errors], Chain);
        {verify_chain, Der} ->
            case lists:member(Der, Chain) of
                true -> verification(Errors, Chain);
                false -> verification(Errors, [Der | Chain])
            end
    after 0 ->
        {lists:reverse(Errors), Chain}
    end.

connection_info(Ssl, Errors, Chain) ->
    Items = case ssl:connection_information(Ssl, [protocol, selected_cipher_suite, sni_hostname, session_resumption,
                                                  selected_group, ecc, session_id, session_data]) of
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

%% The agent reads in passive mode and never leaves a receive waiting: ssl
%% stops a connection whose close_notify arrives during a receive, but
%% keeps one whose close_notify arrives between receives, and it can still
%% write then, as OpenSSL can after SSL_RECEIVED_SHUTDOWN. Each poll takes
%% what ssl decrypted: the realm polls after each delivery to ssl, so ssl
%% has handled it before the receive, and a receive with timeout 0 times
%% out before ssl takes another message.
agent_loop(Ssl, Report, Reading) ->
    receive
        {write, Ref, Bytes} ->
            Status = case ssl:send(Ssl, Bytes) of
                ok -> ok;
                {error, Reason} -> {error, Reason}
            end,
            Report({written, Ref, Status}),
            agent_loop(Ssl, Report, Reading);
        {reading, Flag, Count} ->
            agent_poll(Ssl, Report, Flag, Count);
        {poll, Count} ->
            agent_poll(Ssl, Report, Reading, Count);
        %% The agent owns one ssl socket, and ssl's messages may carry a
        %% copy of its record whose fields differ from the one connect gave.
        %% ssl sends a ticket as {Sni, Ticket} or, since OTP 27, as the
        %% ticket's map.
        {ssl, session_ticket, {_Sni, Ticket}} ->
            Report({ticket, Ticket}),
            agent_loop(Ssl, Report, Reading);
        {ssl, session_ticket, Ticket} when is_map(Ticket) ->
            Report({ticket, Ticket}),
            agent_loop(Ssl, Report, Reading);
        {shutdown, Ref} ->
            %% ssl sends close_notify only for read_write; ssl still reads
            %% after it, and the transport ends only the parent's write side.
            Status = case ssl:shutdown(Ssl, read_write) of
                ok -> ok;
                {error, Reason} -> {error, Reason}
            end,
            Report({shutdown, Ref, Status}),
            agent_loop(Ssl, Report, Reading);
        renegotiate ->
            case ssl:renegotiate(Ssl) of
                ok -> Report(renegotiated), agent_loop(Ssl, Report, Reading);
                {error, closed} -> Report(cleartext_eof);
                {error, Reason} -> Report({error, Reason}), agent_loop(Ssl, Report, Reading)
            end;
        {export, From, Ref, Label, Context, Length} ->
            %% The secret stays for the next export (ConsumeSecret false).
            From ! {Ref, try ssl:export_key_materials(Ssl, [Label], [Context], [Length], false) catch _:_ -> error end},
            agent_loop(Ssl, Report, Reading);
        close ->
            ssl:close(Ssl);
        {'DOWN', _, process, _, _} ->
            ssl:close(Ssl)
    end.

%% Takes the cleartext that ssl holds while the stream reads, then reports
%% that delivery Count is drained. A connection that ended is gone.
agent_poll(Ssl, Report, Reading, skip) ->
    agent_loop(Ssl, Report, Reading);
agent_poll(Ssl, Report, false, _Count) ->
    agent_loop(Ssl, Report, false);
agent_poll(Ssl, Report, true, Count) ->
    case ssl:recv(Ssl, 0, 0) of
        {ok, Data} ->
            Report({cleartext, Data}),
            agent_poll(Ssl, Report, true, Count);
        {error, timeout} ->
            Report({drained, Count}),
            agent_loop(Ssl, Report, true);
        %% A passive connection keeps the alert that ended it for recv.
        {error, {tls_alert, _} = Alert} ->
            Report({error, Alert}),
            Report(cleartext_eof);
        {error, _} ->
            Report(cleartext_eof)
    end.

%%% Events of the agent, in the realm

event(Id, Event) ->
    case by_id(Id) of
        undefined -> ok;
        This -> event(This, state(This), Event)
    end.

event(This, S, {handshake, {ok, Info}}) ->
    save(This, S#{phase := open, info := Info}),
    release(This, handshake),
    #{agent := Agent, pending := Pending, reading := Reading, server := Server, shutdown := Shutdown} = S,
    [Agent ! {write, Ref, Bytes} || {Ref, Bytes} <- Pending],
    save(This, (state(This))#{pending := []}),
    Reading andalso (Agent ! {reading, true, maps:get(delivered, S)}),
    Shutdown =/= none andalso begin hold(This, shutdown), Agent ! {shutdown, Shutdown} end,
    maps:get(protocol, maps:get(items, Info, #{}), 'tlsv1.3') =/= 'tlsv1.3'
        andalso put(This, reneg, #{in => {header, <<>>}, out => {header, <<>>}, phase => idle, notify => Server}),
    call_js(This, <<"onhandshakedone">>, []),
    release_flight(maps:get(id, S)),
    Server =:= false andalso maps:get(session_callbacks, S) andalso tls12_session(This, Info);
event(This, S, {handshake, {error, Reason}}) ->
    save(This, S#{phase := failed}),
    release_flight(maps:get(id, S)),
    release(This, handshake),
    case Reason of
        closed -> cleartext_end(This);
        _ -> call_js(This, <<"onerror">>, [handshake_error(Reason, maps:get(server, S))])
    end;
event(This, S, {cleartext, Data}) ->
    case S of
        #{reading := true, cleartext := []} -> deliver(This, Data);
        #{cleartext := Buffered} -> save(This, S#{cleartext := Buffered ++ [Data]})
    end;
%% The peer's stream ended and ssl holds no more cleartext: the end of the
%% TLS stream. ssl keeps the connection, which can still write, as a peer's
%% close_notify comes with the end of its stream.
event(This, S, {drained, Count}) ->
    case S of
        #{peer_eof := true, inbox := [], delivered := Count, tls_eof := false, phase := open} ->
            save(This, S#{tls_eof := true}),
            release(This, eof),
            cleartext_end(This);
        _ ->
            ok
    end;
%% The agent is gone with ssl's connection: the writes that it did not
%% take are canceled, as TLSWrap's InvokeQueued cancels them.
event(This, _S, cleartext_eof) ->
    #{writes := Writes, shutdown := Shutdown, phase := Phase} = S = state(This),
    save(This, S#{phase := closed, writes := #{}, queued := 0, shutdown := none}),
    Canceled = buoy_node_socket:errno(ecanceled),
    [buoy_node_socket:later(fun() -> complete(Req, Canceled, This) end) || {Req, _Size} <- maps:values(Writes)],
    %% A shutdown that the agent took and will not answer.
    Shutdown =/= none andalso Phase =:= open andalso
        buoy_node_socket:later(fun() -> complete(Shutdown, Canceled, This) end),
    release(This, shutdown),
    release(This, eof),
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
    release(This, shutdown),
    %% ssl that the peer's close_notify ended shuts nothing; the parent's
    %% write side still ends, as SSL_shutdown is followed by the stream's.
    Status =:= ok orelse parent_shutdown(maps:get(parent, S)),
    complete(Req, status(Status), This);
event(This, S, {ticket, Ticket}) ->
    save(This, S#{ticket => Ticket}),
    maps:get(session_callbacks, S) andalso
        call_js(This, <<"onnewsession">>, [buoy_node_encoding:new_buffer(<<>>),
                                          buoy_node_encoding:new_buffer(term_to_binary({tls13_ticket, Ticket}))]);
event(This, S, renegotiated) ->
    save(This, S#{renegotiating => false}),
    call_js(This, <<"onhandshakedone">>, []);
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

transport_event(This, #{flight := {hold, Held}} = S, {send, Data}) ->
    save(This, S#{flight := {hold, [Data | Held]}});
transport_event(This, S, {send, Data}) ->
    renegotiation(This, out, Data),
    parent_write(maps:get(parent, S), Data);
transport_event(This, S, {active, Caller, Mode}) ->
    save(This, S#{controller := Caller, active := Mode}),
    pump(This);
transport_event(This, S, {controller, Pid}) ->
    save(This, S#{controller := Pid}),
    pump(This);
transport_event(_This, S, {shutdown, How}) when How =:= write; How =:= read_write ->
    parent_shutdown(maps:get(parent, S));
transport_event(_This, _S, _) ->
    ok.

%%% The parent stream

%% Takes the reads of the parent; returns whether it reads. A socket handle
%% of buoy_node_socket hands them over in Erlang; another StreamBase, such
%% as the JSStream of a Duplex, through its onread, as TLSWrap becomes the
%% StreamListener of any StreamBase in Node.
listen(Parent, Id) ->
    case buoy_node_socket:find(Parent) of
        {ok, #{reading := Reading}} ->
            buoy_node_socket:set_listener(Parent, fun(Event) -> parent_event(Id, Event) end),
            Reading;
        error ->
            Onread = buoy_node:fn(<<"onread">>, 1, fun(_, Args) -> generic_read(Id, buoy_node:arg(1, Args)) end),
            buoy_heap:set(Parent, <<"onread">>, Onread),
            buoy_ref:truthy(buoy_heap:get(Parent, <<"reading">>))
    end.

generic_read(Id, ArrayBuffer) ->
    State = stream_state(),
    Event = case buoy_heap:get(State, ?K_READ_BYTES) of
        N when N > 0 ->
            Offset = buoy_heap:get(State, ?K_OFFSET),
            {data, buoy_node_encoding:view_bytes(ArrayBuffer, Offset, Offset + N)};
        0 -> none;
        ?UV_EOF -> eof;
        N -> {error, N}
    end,
    Event =/= none andalso parent_event(Id, Event),
    undefined.

parent_read(Parent, Reading) ->
    case {buoy_node_socket:find(Parent), Reading} of
        {{ok, _}, true} -> buoy_node_socket:read_start(Parent);
        {{ok, _}, false} -> buoy_node_socket:read_stop(Parent);
        {error, true} -> call_js(Parent, <<"readStart">>, []);
        {error, false} -> call_js(Parent, <<"readStop">>, [])
    end.

parent_write(Parent, Data) ->
    case buoy_node_socket:find(Parent) of
        {ok, _} -> buoy_node_socket:write_raw(Parent, Data);
        error -> call_js(Parent, <<"writeBuffer">>, [request(<<"WriteWrap">>, Parent), buoy_node_encoding:new_buffer(Data)])
    end.

parent_shutdown(Parent) ->
    case buoy_node_socket:find(Parent) of
        {ok, _} -> buoy_node_socket:shutdown_raw(Parent);
        error -> call_js(Parent, <<"shutdown">>, [request(<<"ShutdownWrap">>, Parent)])
    end.

%% A request of stream_wrap whose completion needs nothing.
request(Class, Parent) ->
    Constructor = buoy_heap:get(buoy_node:binding(<<"stream_wrap">>), Class),
    Req = buoy_heap:construct(Constructor, [], Constructor),
    buoy_heap:set(Req, <<"handle">>, Parent),
    buoy_heap:set(Req, <<"oncomplete">>, buoy_node:fn(<<"oncomplete">>, 1, fun(_, _) -> undefined end)),
    Req.

%% The parent read: encrypted bytes for ssl, the end, or an error.
parent_event(Id, Event) ->
    case by_id(Id) of
        undefined -> ok;
        This -> encrypted_in(This, Event)
    end.

encrypted_in(This, {data, Data}) ->
    sniff(This, Data),
    key_exchange(This, Data),
    renegotiation(This, in, Data),
    #{inbox := Inbox, inbox_size := Size, parent := Parent} = S = state(This),
    save(This, S#{inbox := [Data | Inbox], inbox_size := Size + byte_size(Data)}),
    Size + byte_size(Data) > ?INBOX_LIMIT andalso parent_read(Parent, false),
    pump(This);
encrypted_in(This, eof) ->
    S = state(This),
    save(This, S#{peer_eof := true}),
    maps:get(phase, S) =:= open andalso maps:get(reading, S) andalso hold(This, eof),
    case S of
        #{phase := open, renegotiating := true} -> pump(This);
        #{phase := open} -> poll(This);
        _ -> pump(This)
    end;
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

%%% Renegotiation

%% renegotiate(): TLS 1.3 has none, as SSL_renegotiate refuses it; ssl
%% renegotiates an older session, and onhandshakedone follows.
renegotiate(This) ->
    case state(This) of
        #{info := #{items := #{protocol := 'tlsv1.3'}}} ->
            erlang:error({'$throw', buoy_crypto_context:ssl_error_value(16#10A, <<"wrong ssl version">>, ssl)});
        #{phase := open, agent := Agent} = S ->
            save(This, S#{renegotiating => true}),
            Agent ! renegotiate,
            undefined;
        _ ->
            undefined
    end.

%% A TLS 1.2 connection sees a renegotiation in its records, whose content
%% type stays visible: a handshake record from the peer after the handshake
%% starts one, and the Finished that follows each side's change cipher spec
%% ends it. A server reports them as SSL_CB_HANDSHAKE_START and _DONE do.
%% The agent takes no cleartext meanwhile: a receive that times out during
%% ssl's renegotiation leaves an event that ssl later fails with
%% unexpected_message. The end of one polls.
renegotiation(This, Direction, Data) ->
    case state(This) of
        #{reneg := #{phase := Phase, notify := Notify} = R} = S ->
            {Types, Scan} = record_types(Data, maps:get(Direction, R)),
            Next = lists:foldl(fun(Type, P) -> reneg_step(Direction, Type, P) end, Phase, Types),
            save(This, S#{reneg := R#{Direction := Scan, phase := reneg_phase(Next)}}),
            Notify andalso Phase =:= idle andalso Next =/= idle andalso call_js(This, <<"onhandshakestart">>, [buoy_node_loop:now()]),
            Notify andalso Next =:= done andalso call_js(This, <<"onhandshakedone">>, []),
            Next =:= done andalso poll(This),
            ok;
        _ ->
            ok
    end.

renegotiating(#{reneg := #{phase := Phase}}) -> Phase =/= idle;
renegotiating(_) -> false.

%% Asks the agent of an open connection to take the cleartext of the
%% deliveries so far, unless ssl renegotiates.
poll(This) ->
    case state(This) of
        #{phase := open, agent := Agent, delivered := Count} = S when is_pid(Agent) ->
            renegotiating(S) orelse (Agent ! {poll, Count}),
            ok;
        _ ->
            ok
    end.

reneg_step(in, 22, idle) -> #{in_ccs => false, out_ccs => false, in_fin => false, out_fin => false};
reneg_step(_, _, idle) -> idle;
reneg_step(_, _, done) -> done;
reneg_step(in, 20, P) -> P#{in_ccs := true};
reneg_step(out, 20, P) -> P#{out_ccs := true};
reneg_step(in, 22, #{in_ccs := true} = P) -> finished(P#{in_fin := true});
reneg_step(out, 22, #{out_ccs := true} = P) -> finished(P#{out_fin := true});
reneg_step(_, _, P) -> P.

finished(#{in_fin := true, out_fin := true}) -> done;
finished(P) -> P.

reneg_phase(done) -> idle;
reneg_phase(P) -> P.

%% The content types of the records that Data starts, with the scan state
%% of a record header split across reads or a body left to skip.
record_types(Data, Scan) -> record_types(Data, Scan, []).

record_types(<<>>, Scan, Acc) -> {lists:reverse(Acc), Scan};
record_types(Data, {skip, N}, Acc) when byte_size(Data) =< N -> {lists:reverse(Acc), {skip, N - byte_size(Data)}};
record_types(Data, {skip, N}, Acc) ->
    <<_:N/binary, Rest/binary>> = Data,
    record_types(Rest, {header, <<>>}, Acc);
record_types(Data, {header, Seen}, Acc) ->
    case <<Seen/binary, Data/binary>> of
        <<Type, _:16, Length:16, Rest/binary>> -> record_types(Rest, {skip, Length}, [Type | Acc]);
        Short -> {lists:reverse(Acc), {header, Short}}
    end.

%%% The server's key exchange

%% A TLS 1.2 client sees the server's first flight in the clear. It keeps
%% the body of the ServerKeyExchange, whose DH prime gives the size that
%% getEphemeralKeyInfo reports and ssl does not. The scan ends at
%% ServerHelloDone, at a record that is no handshake, or past 64 KiB.
key_exchange(This, Data) ->
    case state(This) of
        #{kex := {scan, Seen}} = S ->
            All = <<Seen/binary, Data/binary>>,
            {Handshake, Rest} = handshake_bytes(All, <<>>),
            Messages = handshake_messages(Handshake),
            Kex = case lists:keyfind(12, 1, Messages) of
                {12, Body} -> {params, binary:copy(Body)};
                false ->
                    Ended = lists:keymember(14, 1, Messages) orelse not handshake_tail(Rest)
                        orelse byte_size(All) > 65536,
                    case Ended of true -> off; false -> {scan, All} end
            end,
            save(This, S#{kex := Kex});
        _ ->
            ok
    end.

handshake_bytes(<<22, _:16, Length:16, Record:Length/binary, Rest/binary>>, Acc) ->
    handshake_bytes(Rest, <<Acc/binary, Record/binary>>);
handshake_bytes(Rest, Acc) ->
    {Acc, Rest}.

handshake_messages(<<Type, Length:24, Body:Length/binary, Rest/binary>>) -> [{Type, Body} | handshake_messages(Rest)];
handshake_messages(_) -> [].

%% The rest of a read: nothing, or the start of a handshake record.
handshake_tail(<<>>) -> true;
handshake_tail(<<22, _/binary>>) -> true;
handshake_tail(_) -> false.

%%% The client's last flight

%% A TLS 1.3 client completes its handshake as it sends its Finished, and
%% Node's client runs onhandshakedone, where tls.js rejects an unverified
%% server, before TLSWrap writes that flight out: the server then never
%% completes. So a client holds what ssl sends after a TLS 1.3 ServerHello
%% until onhandshakedone has run, and drops it if tls.js destroyed the
%% socket. A TLS 1.2 client sends its Finished before the server's, so it
%% holds nothing.
sniff(This, Data) ->
    case state(This) of
        #{flight := {sniff, Seen}} = S ->
            Flight = case server_hello(<<Seen/binary, Data/binary>>) of
                more -> {sniff, <<Seen/binary, Data/binary>>};
                tls13 -> {hold, []};
                other -> off
            end,
            save(This, S#{flight := Flight});
        _ ->
            ok
    end.

%% The version of the server's first flight: tls13 for a ServerHello with
%% supported_versions 0x0304, more until its record is whole. A change
%% cipher spec record and a HelloRetryRequest come before the ServerHello.
server_hello(<<20, _:16, Length:16, _:Length/binary, Rest/binary>>) ->
    server_hello(Rest);
server_hello(<<22, _:16, Length:16, Record:Length/binary, Rest/binary>>) ->
    case Record of
        <<2, _:24, _:16, ?HRR_RANDOM:256, _/binary>> -> server_hello(Rest);
        <<2, _:24, _:16, _:32/binary, IdLength, _:IdLength/binary, _:16, _, ExtLength:16, Extensions:ExtLength/binary, _/binary>> ->
            case supports_tls13(Extensions) of
                true -> tls13;
                false -> other
            end;
        _ ->
            other
    end;
server_hello(<<22, _/binary>> = Partial) when byte_size(Partial) < 5 -> more;
server_hello(<<22, _:16, Length:16, Rest/binary>>) when byte_size(Rest) < Length -> more;
server_hello(<<20, _/binary>>) -> more;
server_hello(<<>>) -> more;
server_hello(_) -> other.

supports_tls13(<<43:16, 2:16, 16#0304:16, _/binary>>) -> true;
supports_tls13(<<_:16, Length:16, _:Length/binary, Rest/binary>>) -> supports_tls13(Rest);
supports_tls13(_) -> false.

%% After onhandshakedone: the held flight goes out unless tls.js destroyed
%% the socket.
release_flight(Id) ->
    case by_id(Id) of
        undefined ->
            ok;
        This ->
            S = state(This),
            case S of
                #{flight := {hold, Held}} -> [parent_write(maps:get(parent, S), D) || D <- lists:reverse(Held)];
                _ -> ok
            end,
            save(This, (state(This))#{flight := off})
    end.

%% Passes the waiting bytes to ssl while its active mode takes them.
%% A destroyed TLSWrap, or one whose socket closed, gives ssl nothing
%% more, as SSL is freed with it: a server that refuses a renegotiation in
%% onhandshakestart and destroys the socket never lets ssl answer it.
pump(This) ->
    S = state(This),
    Closed = maps:get(phase, S) =:= closed orelse case buoy_node_socket:find(maps:get(parent, S)) of
        {ok, #{closed := true}} -> true;
        _ -> false
    end,
    case Closed of
        true -> ok;
        false -> pump(This, S)
    end.

pump(This, S) ->
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
            Count = maps:get(delivered, S) + 1,
            save(This, S#{inbox := [], inbox_size := 0, active := Next, delivered := Count}),
            maps:get(inbox_size, S) > ?INBOX_LIMIT andalso parent_read(Parent, true),
            poll(This),
            ok;
        %% A closed transport tells each activation again, as gen_tcp's
        %% setopts fails on a closed socket: ssl defers a close that came
        %% while its owner did not read, until it activates the transport.
        %% An open connection keeps writing after the peer's end, so ssl
        %% hears of the transport's end only while this side renegotiates,
        %% which waits on the peer.
        #{controller := Pid, active := Active, inbox := [], peer_eof := true, phase := Phase} = S1
          when is_pid(Pid), Active =/= false, Phase =/= open orelse is_map_key(renegotiating, S1) andalso map_get(renegotiating, S1) ->
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
    case S of
        #{peer_eof := true, tls_eof := false, phase := open} when Reading -> hold(This, eof);
        _ when Reading -> ok;
        _ -> release(This, eof)
    end,
    case {S, Reading} of
        {#{phase := idle, server := true}, true} -> begin_handshake(This, server);
        {#{phase := open, agent := Agent, delivered := Count}, _} ->
            Agent ! {reading, Reading, case renegotiating(S) of true -> skip; false -> Count end};
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

%% Cleartext to onread, through the user's buffer when net set one; what
%% does not fit is the next read, and onread returns the next buffer of a
%% generator, as CustomBufferJSListener takes it.
deliver(This, Data) ->
    S = state(This),
    State = stream_state(),
    case maps:get(user_buffer, S, none) of
        none ->
            save(This, S#{read := maps:get(read, S) + byte_size(Data)}),
            buoy_heap:set(State, ?K_READ_BYTES, byte_size(Data)),
            buoy_heap:set(State, ?K_OFFSET, 0),
            Buffer = buoy_ref_buffer:allocate(byte_size(Data)),
            buoy_ref_buffer:write(Buffer, 0, Data),
            call_js(This, <<"onread">>, [Buffer]);
        User ->
            Size = min(byte_size(Data), buoy_node_encoding:view_length(User)),
            <<Chunk:Size/binary, Rest/binary>> = Data,
            buoy_node_encoding:view_write(User, 0, Chunk),
            Waiting = case Rest of <<>> -> maps:get(cleartext, S); _ -> [Rest | maps:get(cleartext, S)] end,
            save(This, S#{read := maps:get(read, S) + Size, cleartext := Waiting}),
            buoy_heap:set(State, ?K_READ_BYTES, Size),
            Next = call_js(This, <<"onread">>, [undefined]),
            buoy_heap:is_object(Next) andalso put(This, user_buffer, Next),
            Rest =/= <<>> andalso buoy_node_socket:later(fun() -> drain(This) end)
    end.

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

%% The loop stays alive while ssl owes the stream an answer: to a shutdown,
%% as the parent's uv_shutdown_t keeps Node's loop, and to the peer's end,
%% which Node's TLSWrap answers in the same callback.
%% A socket handle's ref and close govern the hold; another parent holds the
%% loop itself.
hold(This, Reason) -> hold(This, Reason, true).

release(This, Reason) -> hold(This, Reason, false).

hold(This, Reason, On) ->
    #{parent := Parent, held := Held} = S = maps:merge(#{held => []}, state(This)),
    case {buoy_node_socket:find(Parent), lists:member(Reason, Held)} of
        {{ok, _}, _} -> buoy_node_socket:hold(Parent, {?MODULE, Reason}, On);
        {error, false} when On -> buoy_node_loop:ref_handle(), save(This, S#{held := [Reason | Held]});
        {error, true} when not On -> buoy_node_loop:unref_handle(), save(This, S#{held := lists:delete(Reason, Held)});
        _ -> ok
    end.

%% shutdown(req): close_notify, then the parent's write side shuts.
shutdown(This, Req) ->
    case state(This) of
        #{phase := open, agent := Agent} = S -> save(This, S#{shutdown := Req}), hold(This, shutdown), Agent ! {shutdown, Req}, 0;
        #{phase := P} = S when P =:= idle; P =:= handshaking -> save(This, S#{shutdown := Req}), 0;
        %% The TLS session is over, and the parent's write side still ends,
        %% as TLSWrap::DoShutdown always shuts the underlying stream.
        #{parent := Parent} ->
            parent_shutdown(Parent),
            buoy_node_socket:later(fun() -> complete(Req, 0, This) end),
            0
    end.

destroy(This) ->
    [release(This, Reason) || Reason <- [handshake, shutdown, eof]],
    case state(This) of
        #{sni_waiting := Waiting} when is_pid(Waiting) -> Waiting ! {'$buoy_tls_sni', []};
        _ -> ok
    end,
    %% TLSWrap::Destroy cancels the writes that wait (InvokeQueued).
    #{writes := Writes} = state(This),
    save(This, (state(This))#{writes := #{}, pending := [], queued := 0}),
    Canceled = buoy_node_socket:errno(ecanceled),
    [buoy_node_socket:later(fun() -> complete(Req, Canceled, This) end) || {Req, _Size} <- maps:values(Writes)],
    case state(This) of
        #{agent := Agent, phase := Phase, id := Id} = S when is_pid(Agent) ->
            Agent ! close,
            %% An agent that waits in a handshake ends with it.
            Phase =:= handshaking andalso exit(Agent, kill),
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

%% getTLSTicket(): the opaque ticket of the session, as
%% SSL_SESSION_get0_ticket gives it: the last NewSessionTicket of a TLS 1.3
%% client, or the ticket that it resumed with. ssl has no TLS 1.2 tickets.
tls_ticket(This) ->
    Ticket = case state(This) of
        #{ticket := T} -> T;
        #{session := Bytes} when is_binary(Bytes) ->
            case try binary_to_term(Bytes, [safe]) catch error:_ -> none end of
                {tls13_ticket, T} -> T;
                _ -> none
            end;
        _ -> none
    end,
    case Ticket of
        #{ticket := NewSessionTicket} when tuple_size(NewSessionTicket) >= 5 ->
            buoy_node_encoding:new_buffer(element(5, NewSessionTicket));
        _ ->
            undefined
    end.

servername(This) ->
    case state(This) of
        #{server := false, servername := Name} when is_binary(Name) -> Name;
        #{info := #{items := #{sni_hostname := Name}}} when Name =/= undefined -> buoy_node:string(Name);
        _ -> false
    end.

session(This) ->
    case state(This) of
        #{ticket := Ticket} -> buoy_node_encoding:new_buffer(term_to_binary({tls13_ticket, Ticket}));
        %% Before its first ticket, a TLS 1.3 session cannot resume, and
        %% OpenSSL gives such a session.
        #{info := #{items := #{protocol := 'tlsv1.3'}}} -> buoy_node_encoding:new_buffer(term_to_binary(tls13_without_ticket));
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
cipher_version(#{mac := Mac, prf := Prf, key_exchange := Kex}) ->
    case lists:member(Mac, [aead, sha256, sha384]) orelse lists:member(Prf, [sha256, sha384]) of
        true -> <<"TLSv1.2">>;
        false ->
            case lists:member(Kex, [ecdhe_rsa, ecdhe_ecdsa, ecdh_rsa, ecdh_ecdsa, ecdh_anon, ecdhe_psk]) of
                true -> <<"TLSv1.0">>;
                false -> <<"SSLv3">>
            end
    end.

%% getEphemeralKeyInfo(): null on a server; on a client, the type, name,
%% and size of the key exchange's group, and {} for an RSA key exchange.
ephemeral_key(This) ->
    case state(This) of
        #{server := true} -> null;
        #{info := #{items := #{selected_cipher_suite := #{key_exchange := Kex}} = Items}} ->
            Group = case Items of
                #{selected_group := G} when G =/= undefined -> G;
                #{ecc := {named_curve, Curve}} -> curve_name(Curve);
                _ -> undefined
            end,
            case {Kex, group(Group), maps:get(kex, state(This), off)} of
                {rsa, _, _} -> buoy_node:object([]);
                {_, none, {params, <<Length:16, Prime:Length/binary, _/binary>>}}
                  when Kex =:= dhe_rsa; Kex =:= dhe_dss; Kex =:= dhe_psk; Kex =:= dh_anon ->
                    Size = length(integer_to_list(binary:decode_unsigned(Prime), 2)),
                    buoy_node:object([{<<"type">>, <<"DH">>}, {<<"size">>, Size}]);
                {_, {dh, Size}, _} -> buoy_node:object([{<<"type">>, <<"DH">>}, {<<"size">>, Size}]);
                {_, {ecdh, Name, Size}, _} -> buoy_node:object([{<<"type">>, <<"ECDH">>}, {<<"name">>, Name}, {<<"size">>, Size}]);
                _ -> buoy_node:object([])
            end;
        _ -> buoy_node:object([])
    end.

curve_name(Curve) when is_atom(Curve) -> Curve;
curve_name(Oid) ->
    try pubkey_cert_records:namedCurves(Oid)
    catch _:_ -> undefined
    end.

group(x25519) -> {ecdh, <<"X25519">>, 253};
group(x448) -> {ecdh, <<"X448">>, 448};
group(secp256r1) -> {ecdh, <<"prime256v1">>, 256};
group(secp384r1) -> {ecdh, <<"secp384r1">>, 384};
group(secp521r1) -> {ecdh, <<"secp521r1">>, 521};
group(secp256k1) -> {ecdh, <<"secp256k1">>, 256};
group(ffdhe2048) -> {dh, 2048};
group(ffdhe3072) -> {dh, 3072};
group(ffdhe4096) -> {dh, 4096};
group(ffdhe6144) -> {dh, 6144};
group(ffdhe8192) -> {dh, 8192};
group(Other) when is_atom(Other), Other =/= undefined -> {ecdh, atom_to_binary(Other), 0};
group(_) -> none.

%% getPeerCertificate(detailed): the legacy object of the peer's
%% certificate; a detailed one links each issuer up to the root.
peer_certificate(This, Detailed) ->
    case state(This) of
        #{info := #{peer := Der} = Info} when is_binary(Der) ->
            %% ssl verifies from the anchor down; the list holds the
            %% leaf's issuer first.
            Chain = [D || D <- maps:get(chain, Info, []), D =/= Der],
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

%% getPeerX509Certificate(): the peer's certificate, whose issuer is the
%% next one of the chain that the peer sent, as X509Certificate.from the
%% SSL session links one level.
peer_x509(This) ->
    case state(This) of
        #{info := #{peer := Der} = Info} when is_binary(Der) ->
            Leaf = buoy_crypto_x509:certificate(Der),
            case [D || D <- maps:get(chain, Info, []), D =/= Der] of
                [IssuerDer | _] ->
                    Issuer = buoy_crypto_x509:certificate(IssuerDer),
                    buoy_heap:define(Leaf, <<"getIssuerCert">>, #{value => buoy_node:fn(<<"getIssuerCert">>, 0, fun(_, _) -> Issuer end),
                                                                   writable => true, enumerable => false, configurable => true});
                [] ->
                    ok
            end,
            Leaf;
        _ ->
            undefined
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
x509_error(stored_issuer_missing, _, _) -> {<<"UNABLE_TO_GET_ISSUER_CERT">>, <<"unable to get issuer certificate">>};
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
    case {string:find(Description, "cipher"), string:find(Description, "client_certificate")} of
        {nomatch, nomatch} -> {1040, alert_text(handshake_failure)};
        {nomatch, _} -> {16#C7, <<"peer did not return a certificate">>};
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
        109 -> <<"tlsv13 alert missing extension">>;
        112 -> <<"tlsv1 unrecognized name">>;
        90 -> <<"tlsv1 alert user cancelled">>;
        Code when Code < 48 -> <<(sslv3_alert_prefix())/binary, " alert ", Words/binary>>;
        _ -> <<"tlsv1 alert ", Words/binary>>
    end.

%% The SSLv3 alert reasons read "sslv3 alert", "ssl/tls alert" from OpenSSL
%% 3.2, and "tls alert" from 4.0, the version that process.versions reports.
sslv3_alert_prefix() ->
    case crypto:info_lib() of
        [{_, Version, _} | _] when Version >= 16#40000000 -> <<"tls">>;
        [{_, Version, _} | _] when Version >= 16#30200000 -> <<"ssl/tls">>;
        _ -> <<"sslv3">>
    end.
