%% internalBinding('udp_wrap') (src/udp_wrap.cc): UDP, the handle of a
%% datagram socket, over an OTP socket that buoy_node_socket drives in
%% nowait mode. recvStart receives each datagram as its own callback of
%% onmessage(nread, handle, buffer, rinfo); a send goes to the kernel at
%% once, as uv_udp_try_send, and returns its size + 1 for a synchronous
%% finish, or waits in the queue of the handle until the socket is
%% writable. Bun's dgram sits on its own UDP layer; Buoy keeps Node's
%% lib/dgram.js on this handle.
-module(buoy_binding_udp_wrap).

-export([binding/0, receive_ready/1, send_ready/1]).

-define(UV_UDP_IPV6ONLY, 1).
-define(UV_UDP_REUSEADDR, 4).
-define(UV_UDP_REUSEPORT, 64).

-spec binding() -> term().
binding() ->
    UDP = buoy_node:constructor(<<"UDP">>, 0, fun(This, _) -> buoy_node_socket:create(This, udp), undefined end),
    Proto = buoy_heap:get(UDP, <<"prototype">>),
    buoy_node_socket:handle_methods(Proto),
    A = fun buoy_node:arg/2,
    Methods = [
        {<<"open">>, fun(This, Args) -> buoy_node_socket:open_fd(This, int(A(1, Args))) end},
        {<<"bind">>, fun(This, Args) -> bind(This, inet, A(1, Args), A(2, Args), A(3, Args)) end},
        {<<"bind6">>, fun(This, Args) -> bind(This, inet6, A(1, Args), A(2, Args), A(3, Args)) end},
        {<<"connect">>, fun(This, Args) -> connect(This, inet, A(1, Args), A(2, Args)) end},
        {<<"connect6">>, fun(This, Args) -> connect(This, inet6, A(1, Args), A(2, Args)) end},
        {<<"disconnect">>, fun(This, _) -> disconnect(This) end},
        {<<"send">>, fun(This, Args) -> send(This, inet, Args) end},
        {<<"send6">>, fun(This, Args) -> send(This, inet6, Args) end},
        {<<"recvStart">>, fun(This, _) -> recv_start(This) end},
        {<<"recvStop">>, fun(This, _) -> buoy_node_socket:save(This, (buoy_node_socket:state(This))#{reading := false}), 0 end},
        {<<"getsockname">>, fun(This, Args) -> buoy_node_socket:sockname(This, A(1, Args)) end},
        {<<"getpeername">>, fun(This, Args) -> buoy_node_socket:peername(This, A(1, Args)) end},
        {<<"addMembership">>, fun(This, Args) -> membership(This, add_membership, A(1, Args), A(2, Args)) end},
        {<<"dropMembership">>, fun(This, Args) -> membership(This, drop_membership, A(1, Args), A(2, Args)) end},
        {<<"addSourceSpecificMembership">>, fun(This, Args) -> source_membership(This, add_source_membership, Args) end},
        {<<"dropSourceSpecificMembership">>, fun(This, Args) -> source_membership(This, drop_source_membership, Args) end},
        {<<"setMulticastInterface">>, fun(This, Args) -> multicast_interface(This, A(1, Args)) end},
        {<<"setMulticastTTL">>, fun(This, Args) -> ttl(This, multicast_ttl, multicast_hops, A(1, Args)) end},
        {<<"setMulticastLoopback">>, fun(This, Args) -> option(This, {ip, multicast_loop}, {ipv6, multicast_loop}, buoy_ref:truthy(A(1, Args))) end},
        {<<"setBroadcast">>, fun(This, Args) -> setopt(This, {socket, broadcast}, buoy_ref:truthy(A(1, Args))) end},
        {<<"setTTL">>, fun(This, Args) -> ttl(This, ttl, unicast_hops, A(1, Args)) end},
        {<<"bufferSize">>, fun(This, Args) -> buffer_size(This, A(1, Args), buoy_ref:truthy(A(2, Args)), A(3, Args)) end},
        {<<"getSendQueueSize">>, fun(This, _) -> maps:get(queued, buoy_node_socket:state(This)) end},
        {<<"getSendQueueCount">>, fun(This, _) -> length(maps:get(queue, buoy_node_socket:state(This))) end}],
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    buoy_node:object([
        {<<"UDP">>, UDP},
        {<<"SendWrap">>, buoy_node:constructor(<<"SendWrap">>, 0, fun(_, _) -> undefined end)},
        {<<"constants">>, buoy_node:object([{<<"UV_UDP_IPV6ONLY">>, ?UV_UDP_IPV6ONLY}, {<<"UV_UDP_REUSEADDR">>, ?UV_UDP_REUSEADDR},
                                            {<<"UV_UDP_REUSEPORT">>, ?UV_UDP_REUSEPORT}])}]).

int(V) ->
    case buoy_ref:to_number(V) of
        N when is_integer(N) -> N;
        F when is_float(F), F == trunc(F) -> trunc(F);
        _ -> 0
    end.

text(V) -> unicode:characters_to_list(buoy_ref_string:to_utf8(buoy_ref:to_string(V))).

errno(Reason) -> buoy_node_socket:errno(Reason).

ip(Family, Address) ->
    Parse = case Family of
        inet -> fun inet:parse_ipv4strict_address/1;
        inet6 -> fun inet:parse_ipv6strict_address/1
    end,
    Parse(text(Address)).

sockaddr(Family, Address, Port) -> buoy_node_socket:sockaddr(Family, Address, Port).

family(Handle) ->
    case buoy_node_socket:state(Handle) of
        #{socket := none} -> inet;
        #{socket := Socket} ->
            case socket:info(Socket) of
                #{domain := inet6} -> inet6;
                _ -> inet
            end
    end.

%% bind(address, port, flags): the flags of UV_UDP_REUSEADDR, REUSEPORT, and
%% IPV6ONLY become socket options.
bind(Handle, Family, Address, Port, Flags) ->
    case sockaddr(Family, Address, Port) of
        {ok, Sockaddr} ->
            Bits = int(Flags),
            Options = [{{socket, reuseaddr}, true} || Bits band ?UV_UDP_REUSEADDR =/= 0]
                ++ [{{socket, reuseport}, true} || Bits band ?UV_UDP_REUSEPORT =/= 0]
                ++ [{{ipv6, v6only}, Bits band ?UV_UDP_IPV6ONLY =/= 0} || Family =:= inet6],
            buoy_node_socket:bind(Handle, Sockaddr, Options);
        error ->
            errno(einval)
    end.

%% A socket that sends or connects before it binds takes an ephemeral port
%% on the wildcard address, as libuv binds it.
ensure_bound(Handle, Family) ->
    case buoy_node_socket:state(Handle) of
        #{socket := none} ->
            Any = case Family of inet -> {0, 0, 0, 0}; inet6 -> {0, 0, 0, 0, 0, 0, 0, 0} end,
            buoy_node_socket:bind(Handle, #{family => Family, addr => Any, port => 0}, []);
        _ ->
            0
    end.

connect(Handle, Family, Address, Port) ->
    case sockaddr(Family, Address, Port) of
        {ok, Sockaddr} ->
            case ensure_bound(Handle, Family) of
                0 ->
                    #{socket := Socket} = buoy_node_socket:state(Handle),
                    case socket:connect(Socket, Sockaddr) of
                        ok -> 0;
                        {error, Reason} -> errno(Reason)
                    end;
                Errno ->
                    Errno
            end;
        error ->
            errno(einval)
    end.

%% disconnect(): connect to AF_UNSPEC dissolves the association.
disconnect(Handle) ->
    case buoy_node_socket:state(Handle) of
        #{socket := none} -> errno(enotconn);
        #{socket := Socket} ->
            case socket:connect(Socket, #{family => unspec, addr => <<0:112>>}) of
                ok -> 0;
                {error, eafnosupport} -> 0;
                {error, Reason} -> errno(Reason)
            end
    end.

%% send(req, list, count, port, address, hasCallback), or send(req, list,
%% count, hasCallback) on a connected socket: size + 1 when the kernel took
%% the datagram, 0 when it waits, or a negative errno.
send(Handle, Family, Args) ->
    A = fun(N) -> buoy_node:arg(N, Args) end,
    Req = A(1),
    Bytes = iolist_to_binary([buoy_node_encoding:view_bytes(B) || B <- buoy_heap:array_items(A(2))]),
    Target = case length(Args) >= 6 of
        true -> sockaddr(Family, A(5), A(4));
        false -> connected
    end,
    case {Target, ensure_bound(Handle, Family)} of
        {error, _} ->
            errno(einval);
        {_, 0} ->
            #{socket := Socket, queue := Queue} = S = buoy_node_socket:state(Handle),
            case Queue =:= [] andalso not no_try_send() of
                true ->
                    case transmit(Socket, Target, Bytes) of
                        ok ->
                            byte_size(Bytes) + 1;
                        {select, Ref} ->
                            buoy_node_socket:save(Handle, S#{queue := [{Req, {Target, Bytes}}], queued := byte_size(Bytes), wsel := Ref}),
                            0;
                        {error, Reason} ->
                            errno(Reason)
                    end;
                false ->
                    buoy_node_socket:save(Handle, S#{queue := Queue ++ [{Req, {Target, Bytes}}],
                                                     queued := maps:get(queued, S) + byte_size(Bytes)}),
                    Queue =:= [] andalso buoy_node_socket:write_kick(Handle),
                    0
            end;
        {_, Errno} ->
            Errno
    end.

%% --test-udp-no-try-send queues every send, as uv_udp_send does.
no_try_send() ->
    lists:member(<<"--test-udp-no-try-send">>, buoy_node_process:exec_argv()).

transmit(Socket, Target, Bytes) ->
    Result = case Target of
        connected -> socket:send(Socket, Bytes, [], nowait);
        {ok, Sockaddr} -> socket:sendto(Socket, Bytes, Sockaddr, [], nowait)
    end,
    case Result of
        ok -> ok;
        {ok, _} -> ok;
        {select, {{select_info, _, Ref}, _}} -> {select, Ref};
        {select, {select_info, _, Ref}} -> {select, Ref};
        {error, closed} -> {error, ebadf};
        {error, Reason} -> {error, Reason}
    end.

%% The socket can send again: the queued datagrams go out in order, and each
%% one's oncomplete(status, sent) runs as a job. It runs outside any job,
%% from buoy_node_socket:event/1.
-spec send_ready(term()) -> ok.
send_ready(Handle) ->
    case buoy_node_socket:state(Handle) of
        #{closed := false, queue := [{Req, {Target, Bytes}} | Rest], queued := Queued, socket := Socket} = S ->
            case transmit(Socket, Target, Bytes) of
                {select, Ref} ->
                    buoy_node_socket:save(Handle, S#{wsel := Ref});
                Result ->
                    buoy_node_socket:save(Handle, S#{queue := Rest, queued := Queued - byte_size(Bytes)}),
                    Status = case Result of ok -> 0; {error, Reason} -> errno(Reason) end,
                    buoy_node_socket:js(fun() -> complete(Req, Status, byte_size(Bytes)) end),
                    send_ready(Handle)
            end;
        _ ->
            ok
    end.

complete(Req, Status, Sent) ->
    F = buoy_heap:get(Req, <<"oncomplete">>),
    buoy_heap:is_callable(F) andalso buoy_heap:call(F, Req, [Status, Sent]).

recv_start(Handle) ->
    case buoy_node_socket:state(Handle) of
        #{socket := none} ->
            errno(ebadf);
        S ->
            buoy_node_socket:save(Handle, S#{reading := true}),
            buoy_node_socket:kick(Handle),
            0
    end.

%% The socket may hold datagrams: up to 32 go to onmessage, each as a job,
%% as uv__udp_recvmsg reads. It runs outside any job, from
%% buoy_node_socket:event/1.
-spec receive_ready(term()) -> ok.
receive_ready(Handle) -> receive_ready(Handle, 32).

receive_ready(Handle, 0) ->
    buoy_node_socket:kick(Handle);
receive_ready(Handle, N) ->
    case buoy_node_socket:state(Handle) of
        #{closed := false, reading := true, rsel := none, socket := Socket} = S ->
            case socket:recvfrom(Socket, 0, [], nowait) of
                {ok, {Source, Data}} ->
                    buoy_node_socket:js(fun() ->
                        onmessage(Handle, [byte_size(Data), Handle, buoy_node_encoding:new_buffer(Data), rinfo(Source)])
                    end),
                    receive_ready(Handle, N - 1);
                {select, {select_info, _, Ref}} ->
                    buoy_node_socket:save(Handle, S#{rsel := Ref});
                {error, closed} ->
                    ok;
                {error, Reason} ->
                    buoy_node_socket:js(fun() -> onmessage(Handle, [errno(Reason), Handle]) end),
                    receive_ready(Handle, N - 1)
            end;
        _ ->
            ok
    end,
    ok.

onmessage(Handle, Args) ->
    F = buoy_heap:get(Handle, <<"onmessage">>),
    buoy_heap:is_callable(F) andalso buoy_heap:call(F, Handle, Args).

rinfo(#{family := Family, port := Port} = Source) ->
    buoy_node:object([{<<"address">>, buoy_node_socket:address_text(Source)},
                      {<<"family">>, case Family of inet -> <<"IPv4">>; inet6 -> <<"IPv6">> end},
                      {<<"port">>, Port}]);
rinfo(_) ->
    buoy_node:object([]).

%% An option of a socket: EBADF before the handle has one, as libuv.
setopt(Handle, Option, Value) ->
    case buoy_node_socket:state(Handle) of
        #{socket := none} -> errno(ebadf);
        _ -> buoy_node_socket:setopt(Handle, Option, Value)
    end.

%% An option of the IPv4 or the IPv6 level, by the family of the socket.
option(Handle, V4, V6, Value) ->
    case family(Handle) of
        inet -> setopt(Handle, V4, Value);
        inet6 -> setopt(Handle, V6, Value)
    end.

%% setTTL and setMulticastTTL: 1 to 255, as uv_udp_set_ttl checks.
ttl(Handle, V4, V6, Value) ->
    case int(Value) of
        N when N >= 1, N =< 255 -> option(Handle, {ip, V4}, {ipv6, V6}, N);
        N when N =:= 0, V4 =:= multicast_ttl -> option(Handle, {ip, V4}, {ipv6, V6}, N);
        _ -> errno(einval)
    end.

interface(Family, undefined) -> {ok, any_interface(Family)};
interface(Family, V) ->
    case ip(Family, V) of
        {ok, Addr} -> {ok, Addr};
        {error, _} -> error
    end.

any_interface(inet) -> {0, 0, 0, 0};
any_interface(inet6) -> 0.

membership(Handle, Op, Group, Interface) ->
    Family = family(Handle),
    case {ip(Family, Group), interface(Family, Interface)} of
        {{ok, Multiaddr}, {ok, If}} when Family =:= inet ->
            setopt(Handle, {ip, Op}, #{multiaddr => Multiaddr, interface => If});
        {{ok, Multiaddr}, _} when Family =:= inet6 ->
            setopt(Handle, {ipv6, Op}, #{multiaddr => Multiaddr, interface => 0});
        _ ->
            errno(einval)
    end.

source_membership(Handle, Op, Args) ->
    [Source, Group, Interface] = [buoy_node:arg(N, Args) || N <- [1, 2, 3]],
    case {ip(inet, Source), ip(inet, Group), interface(inet, Interface)} of
        {{ok, S}, {ok, G}, {ok, If}} ->
            setopt(Handle, {ip, Op}, #{multiaddr => G, interface => If, sourceaddr => S});
        _ ->
            errno(einval)
    end.

%% setMulticastInterface(address): an IPv4 address sets IP_MULTICAST_IF, and
%% an IPv6 one, with a scope such as %lo0, sets IPV6_MULTICAST_IF to the
%% scope's interface, as uv_udp_set_multicast_interface parses it.
multicast_interface(Handle, Address) ->
    case {inet:parse_ipv4strict_address(text(Address)), sockaddr(inet6, Address, 0)} of
        {{ok, V4}, _} -> setopt(Handle, {ip, multicast_if}, V4);
        {_, {ok, #{scope_id := Index}}} -> setopt(Handle, {ipv6, multicast_if}, Index);
        _ -> errno(einval)
    end.

%% bufferSize(size, isRecv, ctx): the size of the kernel buffer, set first
%% when size is not 0, or undefined with the error in ctx.
buffer_size(Handle, Size, IsRecv, Ctx) ->
    {Option, Syscall} = case IsRecv of
        true -> {{socket, rcvbuf}, <<"uv_recv_buffer_size">>};
        false -> {{socket, sndbuf}, <<"uv_send_buffer_size">>}
    end,
    Result = case buoy_node_socket:state(Handle) of
        #{socket := none} -> {error, ebadf};
        #{socket := Socket} ->
            case int(Size) of
                0 -> socket:getopt(Socket, Option);
                N ->
                    case socket:setopt(Socket, Option, N) of
                        ok -> {ok, N};
                        Error -> Error
                    end
            end
    end,
    case Result of
        {ok, Value} ->
            Value;
        {error, Reason} ->
            Errno = errno(Reason),
            Code = buoy_binding_uv:name(Errno),
            [buoy_heap:set(Ctx, K, V) || {K, V} <- [{<<"errno">>, Errno}, {<<"code">>, Code},
                                                    {<<"message">>, message(Errno)}, {<<"syscall">>, Syscall}]],
            undefined
    end.

message(Errno) ->
    case lists:keyfind(Errno, 1, buoy_binding_uv:errors()) of
        {_, _, Message} -> Message;
        false -> <<"unknown error">>
    end.
