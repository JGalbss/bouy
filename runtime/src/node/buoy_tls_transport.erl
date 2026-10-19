%% The transport of an OTP ssl connection that runs over a Node stream
%% handle: the cb_info module that ssl calls in place of gen_tcp. A socket
%% is {buoy_tls_transport, Realm, Id}; each call runs in a process of ssl
%% and sends it to the realm, where buoy_binding_tls_wrap holds the
%% TLSWrap of Id and its parent handle. The realm sends the bytes that the
%% parent reads to the controlling process as {buoy_tls, Socket, Data},
%% under the active mode that ssl sets, as gen_tcp does.
-module(buoy_tls_transport).

-export([socket/2, cb_info/0]).
-export([send/2, setopts/2, getopts/2, getstat/2, peername/1, sockname/1, port/1, controlling_process/2]).
-export([close/1, shutdown/2, recv/2, recv/3]).

-type socket() :: {buoy_tls_transport, pid(), reference()}.
-export_type([socket/0]).

-spec socket(pid(), reference()) -> socket().
socket(Realm, Id) -> {buoy_tls_transport, Realm, Id}.

%% The cb_info option of ssl: the module and the tags of its messages.
-spec cb_info() -> {module(), atom(), atom(), atom(), atom()}.
cb_info() -> {?MODULE, buoy_tls, buoy_tls_closed, buoy_tls_error, buoy_tls_passive}.

tell({buoy_tls_transport, Realm, Id}, Event) ->
    buoy_node_stream:call(Realm, fun() -> buoy_binding_tls_wrap:transport(Id, Event) end).

-spec send(socket(), iodata()) -> ok.
send(Socket, Data) ->
    tell(Socket, {send, iolist_to_binary(Data)}),
    ok.

-spec setopts(socket(), list()) -> ok.
setopts(Socket, Options) ->
    Caller = self(),
    [tell(Socket, {active, Caller, Mode}) || {active, Mode} <- Options],
    ok.

-spec getopts(socket(), list()) -> {ok, list()}.
getopts(_Socket, Options) ->
    {ok, [{O, default(O)} || O <- Options, default(O) =/= undefined]}.

default(active) -> false;
default(mode) -> binary;
default(packet) -> 0;
default(packet_size) -> 0;
default(header) -> 0;
default(_) -> undefined.

-spec getstat(socket(), list()) -> {ok, list()}.
getstat(_Socket, _Options) -> {ok, []}.

-spec peername(socket()) -> {ok, {inet:ip_address(), inet:port_number()}}.
peername(_Socket) -> {ok, {{127, 0, 0, 1}, 0}}.

-spec sockname(socket()) -> {ok, {inet:ip_address(), inet:port_number()}}.
sockname(_Socket) -> {ok, {{127, 0, 0, 1}, 0}}.

-spec port(socket()) -> {ok, inet:port_number()}.
port(_Socket) -> {ok, 0}.

-spec controlling_process(socket(), pid()) -> ok.
controlling_process(Socket, Pid) ->
    tell(Socket, {controller, Pid}),
    ok.

-spec close(socket()) -> ok.
close(Socket) ->
    tell(Socket, close),
    ok.

-spec shutdown(socket(), read | write | read_write) -> ok.
shutdown(Socket, How) ->
    tell(Socket, {shutdown, How}),
    ok.

-spec recv(socket(), non_neg_integer()) -> {error, closed}.
recv(_Socket, _Length) -> {error, closed}.

-spec recv(socket(), non_neg_integer(), timeout()) -> {error, closed}.
recv(_Socket, _Length, _Timeout) -> {error, closed}.
