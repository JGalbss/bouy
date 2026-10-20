%% internalBinding('tcp_wrap') (src/tcp_wrap.cc): TCP, the handle of a TCP
%% socket or server, over an OTP socket that buoy_node_socket drives as
%% libuv drives a descriptor. Bun's net sits on its own socket layer
%% (uSockets) and rewrites lib/net in TypeScript; Buoy keeps Node's
%% lib/net.js and gives it the handle that it expects.
-module(buoy_binding_tcp_wrap).

-export([binding/0]).

-define(SOCKET, 0).
-define(SERVER, 1).
-define(UV_TCP_IPV6ONLY, 1).
-define(UV_TCP_REUSEPORT, 2).

-spec binding() -> term().
binding() ->
    TCP = buoy_node:constructor(<<"TCP">>, 1, fun(This, Args) -> buoy_node_socket:create(This, tcp, wrap_name(buoy_node:arg(1, Args))), undefined end),
    erlang:put({buoy_node_socket, constructor, tcp}, TCP),
    Proto = buoy_heap:get(TCP, <<"prototype">>),
    buoy_node_socket:methods(Proto),
    A = fun buoy_node:arg/2,
    Methods = [
        {<<"open">>, fun(This, Args) -> buoy_node_socket:open_fd(This, int(A(1, Args))) end},
        {<<"bind">>, fun(This, Args) -> bind(This, inet, A(1, Args), A(2, Args), A(3, Args)) end},
        {<<"bind6">>, fun(This, Args) -> bind(This, inet6, A(1, Args), A(2, Args), A(3, Args)) end},
        {<<"listen">>, fun(This, Args) -> buoy_node_socket:listen(This, int(A(1, Args))) end},
        {<<"connect">>, fun(This, Args) -> connect(This, A(1, Args), inet, A(2, Args), A(3, Args)) end},
        {<<"connect6">>, fun(This, Args) -> connect(This, A(1, Args), inet6, A(2, Args), A(3, Args)) end},
        {<<"getsockname">>, fun(This, Args) -> buoy_node_socket:sockname(This, A(1, Args)) end},
        {<<"getpeername">>, fun(This, Args) -> buoy_node_socket:peername(This, A(1, Args)) end},
        {<<"setNoDelay">>, fun(This, Args) -> buoy_node_socket:setopt(This, {tcp, nodelay}, buoy_ref:truthy(A(1, Args))) end},
        {<<"setKeepAlive">>, fun(This, Args) -> buoy_node_socket:setopt(This, {socket, keepalive}, buoy_ref:truthy(A(1, Args))) end},
        {<<"setTypeOfService">>, fun(This, Args) -> set_type_of_service(This, int(A(1, Args))) end},
        {<<"getTypeOfService">>, fun(This, _) -> type_of_service(This) end},
        {<<"reset">>, fun(This, Args) -> buoy_node_socket:reset(This, A(1, Args)) end},
        {<<"setSimultaneousAccepts">>, fun(_, _) -> undefined end}],
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    buoy_node:object([
        {<<"TCP">>, TCP},
        {<<"TCPConnectWrap">>, buoy_node:constructor(<<"TCPConnectWrap">>, 0, fun(_, _) -> undefined end)},
        {<<"constants">>, buoy_node:object([{<<"SOCKET">>, ?SOCKET}, {<<"SERVER">>, ?SERVER},
                                            {<<"UV_TCP_IPV6ONLY">>, ?UV_TCP_IPV6ONLY}, {<<"UV_TCP_REUSEPORT">>, ?UV_TCP_REUSEPORT}])}]).

wrap_name(?SERVER) -> <<"TCPServerWrap">>;
wrap_name(_) -> <<"TCPSocketWrap">>.

int(V) ->
    case buoy_ref:to_number(V) of
        N when is_integer(N) -> N;
        F when is_float(F), F == trunc(F) -> trunc(F);
        _ -> 0
    end.

sockaddr(Family, Address, Port) -> buoy_node_socket:sockaddr(Family, Address, Port).

%% bind and bind6: libuv sets SO_REUSEADDR on each TCP socket that binds,
%% and an IPv6 socket takes IPv4 too unless UV_TCP_IPV6ONLY.
bind(Handle, Family, Address, Port, Flags) ->
    case sockaddr(Family, Address, Port) of
        {ok, Sockaddr} ->
            Bits = int(Flags),
            Options = [{{socket, reuseaddr}, true}]
                ++ [{{socket, reuseport}, true} || Bits band ?UV_TCP_REUSEPORT =/= 0]
                ++ [{{ipv6, v6only}, Bits band ?UV_TCP_IPV6ONLY =/= 0} || Family =:= inet6],
            buoy_node_socket:bind(Handle, Sockaddr, Options);
        error ->
            buoy_node_socket:errno(einval)
    end.

%% connect and connect6: ECONNREFUSED reaches oncomplete, as libuv delays it.
connect(Handle, Req, Family, Address, Port) ->
    case sockaddr(Family, Address, Port) of
        {ok, Sockaddr} -> buoy_node_socket:connect(Handle, Req, Sockaddr, [econnrefused]);
        error -> buoy_node_socket:errno(einval)
    end.

%% setTypeOfService(tos): IP_TOS, or IPV6_TCLASS on a socket that refuses
%% it, as TCPWrap::SetTypeOfService tries both.
set_type_of_service(Handle, Tos) ->
    case buoy_node_socket:setopt(Handle, {ip, tos}, Tos) of
        0 -> 0;
        Errno ->
            case buoy_node_socket:setopt(Handle, {ipv6, tclass}, Tos) of
                0 -> 0;
                _ -> Errno
            end
    end.

type_of_service(Handle) ->
    case buoy_node_socket:find(Handle) of
        {ok, #{socket := Socket}} when Socket =/= none ->
            case {socket:getopt(Socket, {ip, tos}), socket:getopt(Socket, {ipv6, tclass})} of
                {{ok, Tos}, _} when is_integer(Tos) -> Tos;
                {_, {ok, Class}} when is_integer(Class) -> Class;
                {{error, Reason}, _} -> buoy_node_socket:errno(Reason);
                _ -> 0
            end;
        _ ->
            0
    end.
