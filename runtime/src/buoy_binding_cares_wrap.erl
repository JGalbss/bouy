%% internalBinding('cares_wrap') (src/cares_wrap.cc): getaddrinfo and
%% getnameinfo, which libuv runs on its thread pool, and ChannelWrap, the
%% c-ares channel of dns.Resolver. A worker process runs each request with
%% the resolvers of OTP: inet:getaddrs and inet:gethostbyaddr (the native
%% resolver, the getaddrinfo of the OS) and inet_res for DNS queries, which
%% parses the answers as c-ares does. The result comes back to the realm as
%% a callback of the loop, and the request keeps the loop alive until then.
%% Bun resolves on a thread pool too, with its own cache in front; Buoy's
%% workers are BEAM processes.
-module(buoy_binding_cares_wrap).

-export([binding/0]).

-define(CHANNEL, {'#', ?MODULE, <<"channel">>}).
-define(AF_INET, 2).
-define(AF_INET6, 30).
-define(ORDER_VERBATIM, 0).
-define(ORDER_IPV4_FIRST, 1).
-define(ORDER_IPV6_FIRST, 2).
-define(DNS_PORT, 53).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    Request = fun(Name) -> buoy_node:constructor(Name, 0, fun(_, _) -> undefined end) end,
    Channel = buoy_node:constructor(<<"ChannelWrap">>, 3, fun(This, Args) -> channel(This, A(1, Args), A(2, Args)) end),
    Proto = buoy_heap:get(Channel, <<"prototype">>),
    Queries = [{<<"queryAny">>, any}, {<<"queryA">>, a}, {<<"queryAaaa">>, aaaa}, {<<"queryCaa">>, caa},
               {<<"queryCname">>, cname}, {<<"queryMx">>, mx}, {<<"queryNs">>, ns}, {<<"queryTlsa">>, tlsa},
               {<<"queryTxt">>, txt}, {<<"querySrv">>, srv}, {<<"queryPtr">>, ptr}, {<<"queryNaptr">>, naptr},
               {<<"querySoa">>, soa}, {<<"getHostByAddr">>, reverse}],
    Methods = [{Name, fun(This, Args) -> query(This, Type, A(1, Args), text(A(2, Args))) end} || {Name, Type} <- Queries]
        ++ [{<<"getServers">>, fun(This, _) -> get_servers(This) end},
            {<<"setServers">>, fun(This, Args) -> set_servers(This, A(1, Args)) end},
            {<<"setLocalAddress">>, fun(_, _) -> undefined end},
            {<<"cancel">>, fun(This, _) -> cancel(This) end}],
    [buoy_heap:define(Proto, Name, #{value => F(Name, 2, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    buoy_node:object([
        {<<"getaddrinfo">>, F(<<"getaddrinfo">>, 5, fun(_, Args) -> getaddrinfo(A(1, Args), text(A(2, Args)), A(3, Args), A(5, Args)) end)},
        {<<"getnameinfo">>, F(<<"getnameinfo">>, 3, fun(_, Args) -> getnameinfo(A(1, Args), text(A(2, Args)), A(3, Args)) end)},
        {<<"canonicalizeIP">>, F(<<"canonicalizeIP">>, 1, fun(_, Args) -> canonicalize(A(1, Args)) end)},
        {<<"convertIpv6StringToBuffer">>, F(<<"convertIpv6StringToBuffer">>, 1, fun(_, Args) -> ipv6_buffer(A(1, Args)) end)},
        {<<"strerror">>, F(<<"strerror">>, 1, fun(_, Args) -> strerror(buoy_ref:to_number(A(1, Args))) end)},
        {<<"AF_INET">>, ?AF_INET}, {<<"AF_INET6">>, ?AF_INET6}, {<<"AF_UNSPEC">>, 0},
        {<<"AI_ADDRCONFIG">>, 1024}, {<<"AI_ALL">>, 256}, {<<"AI_V4MAPPED">>, 2048},
        {<<"DNS_ORDER_VERBATIM">>, ?ORDER_VERBATIM}, {<<"DNS_ORDER_IPV4_FIRST">>, ?ORDER_IPV4_FIRST},
        {<<"DNS_ORDER_IPV6_FIRST">>, ?ORDER_IPV6_FIRST},
        {<<"GetAddrInfoReqWrap">>, Request(<<"GetAddrInfoReqWrap">>)},
        {<<"GetNameInfoReqWrap">>, Request(<<"GetNameInfoReqWrap">>)},
        {<<"QueryReqWrap">>, Request(<<"QueryReqWrap">>)},
        {<<"ChannelWrap">>, Channel}]).

text(V) when is_binary(V) -> unicode:characters_to_list(V);
text(V) -> unicode:characters_to_list(buoy_ref_string:to_utf8(buoy_ref:to_string(V))).

%%% Requests

%% Runs Work in a worker process; Done(Result) runs in the realm as a later
%% callback. The request stays a root of the heap and keeps the loop alive
%% until then. Returns the worker.
start(Req, Work, Done) ->
    ok = start_inet_db(),
    Realm = self(),
    Ref = make_ref(),
    erlang:put({?MODULE, pending, Ref}, Req),
    buoy_node_loop:ref_handle(),
    spawn(fun() ->
        Result = try Work() catch _:Reason -> {error, Reason} end,
        buoy_node_stream:call(Realm, fun() -> finish(Ref, Done, Result) end)
    end),
    Ref.

%% The resolvers of OTP need inet_db, which the VM of a program does not
%% start until a binding asks for it.
start_inet_db() ->
    case whereis(inet_db) of
        undefined ->
            Spec = #{id => inet_db, start => {inet_db, start_link, []}, restart => permanent, shutdown => 2000},
            case supervisor:start_child(kernel_sup, Spec) of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok
            end;
        _ ->
            ok
    end.

finish(Ref, Done, Result) ->
    case erlang:erase({?MODULE, pending, Ref}) of
        undefined -> ok;
        _Req -> buoy_node_loop:unref_handle(), Done(Result)
    end.

oncomplete(Req, Args) ->
    F = buoy_heap:get(Req, <<"oncomplete">>),
    buoy_heap:is_callable(F) andalso buoy_heap:call(F, Req, Args).

%%% getaddrinfo and getnameinfo

%% getaddrinfo(req, hostname, family, hints, order): 0, then
%% req.oncomplete(err, addresses) with the addresses as strings.
getaddrinfo(Req, Host, Family, Order) ->
    Families = case {buoy_ref:to_number(Family), buoy_ref:to_number(Order)} of
        {4, _} -> [inet];
        {6, _} -> [inet6];
        {_, ?ORDER_IPV4_FIRST} -> [inet, inet6];
        _ -> [inet6, inet]
    end,
    Work = fun() ->
        Results = [inet:getaddrs(Host, F) || F <- Families],
        case lists:append([Addrs || {ok, Addrs} <- Results]) of
            [] -> hd([E || {error, _} = E <- Results]);
            Addrs -> {ok, Addrs}
        end
    end,
    start(Req, Work, fun
        ({ok, Addrs}) ->
            oncomplete(Req, [0, buoy_heap:new_array([buoy_node:string(inet:ntoa(A)) || A <- Addrs])]);
        ({error, Reason}) ->
            oncomplete(Req, [eai(Reason), buoy_heap:new_array([])])
    end),
    0.

eai(nxdomain) -> -3008;
eai(timeout) -> -3001;
eai(einval) -> -3008;
eai(_) -> -3004.

%% getnameinfo(req, host, port): 0, then req.oncomplete(err, hostname, service).
getnameinfo(Req, Host, Port) ->
    PortNumber = trunc(buoy_ref:to_number(Port)),
    Work = fun() ->
        case inet:parse_address(Host) of
            {ok, Address} ->
                Name = case inet:gethostbyaddr(Address) of
                    {ok, {hostent, N, _, _, _, _}} -> N;
                    {error, _} -> inet:ntoa(Address)
                end,
                Service = case inet:getservbyport(PortNumber, tcp) of
                    {ok, S} -> S;
                    {error, _} -> integer_to_list(PortNumber)
                end,
                {ok, Name, Service};
            {error, Reason} ->
                {error, Reason}
        end
    end,
    start(Req, Work, fun
        ({ok, Name, Service}) -> oncomplete(Req, [0, buoy_node:string(Name), buoy_node:string(Service)]);
        ({error, Reason}) -> oncomplete(Req, [eai(Reason)])
    end),
    0.

%% canonicalizeIP(ip): the canonical text of an IP address, or undefined.
canonicalize(V) ->
    case inet:parse_strict_address(text(V)) of
        {ok, Address} -> buoy_node:string(inet:ntoa(Address));
        {error, _} -> undefined
    end.

ipv6_buffer(V) ->
    case inet:parse_ipv6strict_address(text(V)) of
        {ok, Address} ->
            Bytes = << <<W:16>> || W <- tuple_to_list(Address) >>,
            buoy_node_encoding:new_buffer(Bytes);
        {error, _} ->
            null
    end.

%%% ChannelWrap

channel(This, Timeout, Tries) ->
    Ms = case buoy_ref:to_number(Timeout) of
        T when is_number(T), T > 0 -> trunc(T);
        _ -> 5000
    end,
    Retry = case buoy_ref:to_number(Tries) of
        N when is_number(N), N >= 1 -> trunc(N);
        _ -> 4
    end,
    buoy_heap:private_put(This, ?CHANNEL, #{servers => default_servers(), timeout => Ms, tries => Retry, pending => []}),
    undefined.

channel_state(This) ->
    {ok, S} = buoy_heap:private_find(This, ?CHANNEL),
    S.

%% The name servers of /etc/resolv.conf, as c-ares reads them.
default_servers() ->
    case inet_parse:resolv("/etc/resolv.conf") of
        {ok, Lines} -> [{IP, ?DNS_PORT} || {nameserver, IP} <- Lines];
        _ -> [{{127, 0, 0, 1}, ?DNS_PORT}]
    end.

get_servers(This) ->
    #{servers := Servers} = channel_state(This),
    buoy_heap:new_array([buoy_heap:new_array([buoy_node:string(inet:ntoa(IP)), Port]) || {IP, Port} <- Servers]).

%% setServers([[family, ip, port], ...]): 0, or the c-ares error ARES_EBADSTR.
set_servers(This, List) ->
    Parsed = [begin
                  [_Family, IP, Port] = buoy_heap:array_items(Item),
                  {inet:parse_strict_address(text(IP)), trunc(buoy_ref:to_number(Port))}
              end || Item <- buoy_heap:array_items(List)],
    case [{IP, Port} || {{ok, IP}, Port} <- Parsed] of
        Servers when length(Servers) =:= length(Parsed) ->
            buoy_heap:private_put(This, ?CHANNEL, (channel_state(This))#{servers := Servers}),
            0;
        _ ->
            17
    end.

%% cancel(): each pending query fails with ECANCELLED.
cancel(This) ->
    #{pending := Pending} = S = channel_state(This),
    buoy_heap:private_put(This, ?CHANNEL, S#{pending := []}),
    [finish(Ref, fun(_) -> oncomplete(Req, [buoy_node:string("ECANCELLED")]) end, cancelled)
     || {Ref, Req} <- Pending, erlang:get({?MODULE, pending, Ref}) =/= undefined],
    undefined.

%% A query of the channel: 0, then req.oncomplete(0, result[, ttls]) or
%% req.oncomplete(code), with the code of c-ares, such as 'ENOTFOUND'.
query(This, Type, Req, Name) ->
    #{servers := Servers, timeout := Timeout, tries := Tries, pending := Pending} = S = channel_state(This),
    Options = [{nameservers, Servers}, {timeout, Timeout}, {retry, Tries}],
    {Question, Kind} = case Type of
        reverse -> {reverse_name(Name), ptr};
        tlsa -> {Name, 52};
        _ -> {Name, Type}
    end,
    Work = fun() -> resolve(Question, Kind, Options) end,
    Ref = start(Req, Work, fun(Result) -> answer(This, Req, Type, Result) end),
    Live = [P || {R, _} = P <- Pending, erlang:get({?MODULE, pending, R}) =/= undefined],
    buoy_heap:private_put(This, ?CHANNEL, S#{pending := [{Ref, Req} | Live]}),
    0.

resolve(_Question, _Kind, []) ->
    {error, econnrefused};
resolve(Question, Kind, Options) ->
    case inet_res:resolve(Question, in, Kind, Options) of
        {ok, Msg} -> {ok, [{inet_dns:rr(RR, type), inet_dns:rr(RR, ttl), inet_dns:rr(RR, data)} || RR <- inet_dns:msg(Msg, anlist)]};
        {error, {Reason, _Msg}} -> {error, Reason};
        {error, Reason} -> {error, Reason}
    end.

reverse_name(Name) ->
    case inet:parse_strict_address(Name) of
        {ok, {A, B, C, D}} ->
            lists:flatten(io_lib:format("~b.~b.~b.~b.in-addr.arpa", [D, C, B, A]));
        {ok, Address} ->
            Nibbles = lists:reverse([N || W <- tuple_to_list(Address), <<N:4>> <= <<W:16>>]),
            string:lowercase(string:join([integer_to_list(N, 16) || N <- Nibbles], ".")) ++ ".ip6.arpa";
        {error, _} ->
            Name
    end.

answer(_This, Req, Type, {ok, Records}) ->
    case records(Type, Records) of
        [] when Type =/= soa ->
            oncomplete(Req, [buoy_node:string("ENODATA")]);
        Result when Type =:= a; Type =:= aaaa ->
            oncomplete(Req, [0, buoy_heap:new_array([V || {V, _} <- Result]), buoy_heap:new_array([T || {_, T} <- Result])]);
        [Soa | _] when Type =:= soa ->
            oncomplete(Req, [0, Soa]);
        [] ->
            oncomplete(Req, [buoy_node:string("ENODATA")]);
        Result ->
            oncomplete(Req, [0, buoy_heap:new_array(Result)])
    end;
answer(_This, Req, _Type, {error, Reason}) ->
    oncomplete(Req, [buoy_node:string(code(Reason))]).

code(nxdomain) -> "ENOTFOUND";
code(timeout) -> "ETIMEOUT";
code(servfail) -> "ESERVFAIL";
code(formerr) -> "EFORMERR";
code(qfmterror) -> "EBADQUERY";
code(notimp) -> "ENOTIMP";
code(refused) -> "EREFUSED";
code(econnrefused) -> "ECONNREFUSED";
code(einval) -> "EBADNAME";
code(nodata) -> "ENODATA";
code(_) -> "EBADRESP".

%% The answers of the queried type, in Node's shape.
records(any, Records) ->
    [Value || {Type, Ttl, Data} <- Records, Value <- [any_record(Type, Ttl, Data)], Value =/= skip];
records(a, Records) -> [{ntoa(D), Ttl} || {a, Ttl, D} <- Records];
records(aaaa, Records) -> [{ntoa(D), Ttl} || {aaaa, Ttl, D} <- Records];
records(reverse, Records) -> [str(D) || {ptr, _, D} <- Records];
records(Type, Records) ->
    Kind = case Type of tlsa -> 52; _ -> Type end,
    [record(Type, D) || {K, _, D} <- Records, K =:= Kind].

ntoa(Address) -> buoy_node:string(inet:ntoa(Address)).

str(S) -> buoy_node:string(S).

obj(Pairs) -> buoy_node:object(Pairs).

record(cname, D) -> str(D);
record(ns, D) -> str(D);
record(ptr, D) -> str(D);
record(mx, {Priority, Exchange}) -> obj([{<<"exchange">>, str(Exchange)}, {<<"priority">>, Priority}]);
record(txt, Chunks) -> buoy_heap:new_array([str(C) || C <- Chunks]);
record(srv, {Priority, Weight, Port, Name}) ->
    obj([{<<"name">>, str(Name)}, {<<"port">>, Port}, {<<"priority">>, Priority}, {<<"weight">>, Weight}]);
record(naptr, {Order, Preference, Flags, Service, Regexp, Replacement}) ->
    obj([{<<"flags">>, str(Flags)}, {<<"service">>, str(Service)}, {<<"regexp">>, str(Regexp)},
         {<<"replacement">>, str(Replacement)}, {<<"order">>, Order}, {<<"preference">>, Preference}]);
record(soa, {Ns, Host, Serial, Refresh, Retry, Expire, Min}) ->
    obj([{<<"nsname">>, str(Ns)}, {<<"hostmaster">>, str(Host)}, {<<"serial">>, Serial}, {<<"refresh">>, Refresh},
         {<<"retry">>, Retry}, {<<"expire">>, Expire}, {<<"minttl">>, Min}]);
record(caa, {Flags, Tag, Value}) ->
    obj([{<<"critical">>, Flags}, {list_to_binary(Tag), str(Value)}]);
record(tlsa, <<Usage, Selector, Match, Data/binary>>) ->
    Buffer = buoy_ref_buffer:allocate(byte_size(Data)),
    buoy_ref_buffer:write(Buffer, 0, Data),
    obj([{<<"certUsage">>, Usage}, {<<"selector">>, Selector}, {<<"match">>, Match}, {<<"data">>, Buffer}]);
record(_, D) when is_list(D) -> str(D);
record(_, _) -> undefined.

with_type(Object, Type) ->
    buoy_heap:set(Object, <<"type">>, buoy_node:string(Type)),
    Object.

any_record(a, Ttl, D) -> obj([{<<"address">>, ntoa(D)}, {<<"ttl">>, Ttl}, {<<"type">>, str("A")}]);
any_record(aaaa, Ttl, D) -> obj([{<<"address">>, ntoa(D)}, {<<"ttl">>, Ttl}, {<<"type">>, str("AAAA")}]);
any_record(cname, _, D) -> obj([{<<"value">>, str(D)}, {<<"type">>, str("CNAME")}]);
any_record(ns, _, D) -> obj([{<<"value">>, str(D)}, {<<"type">>, str("NS")}]);
any_record(ptr, _, D) -> obj([{<<"value">>, str(D)}, {<<"type">>, str("PTR")}]);
any_record(txt, _, D) -> obj([{<<"entries">>, record(txt, D)}, {<<"type">>, str("TXT")}]);
any_record(mx, _, D) -> with_type(record(mx, D), "MX");
any_record(srv, _, D) -> with_type(record(srv, D), "SRV");
any_record(naptr, _, D) -> with_type(record(naptr, D), "NAPTR");
any_record(soa, _, D) -> with_type(record(soa, D), "SOA");
any_record(caa, _, D) -> with_type(record(caa, D), "CAA");
any_record(52, _, D) -> with_type(record(tlsa, D), "TLSA");
any_record(_, _, _) -> skip.

%% ares_strerror.
strerror(Code) ->
    Messages = ["Successful completion", "DNS server returned answer with no data", "DNS server claims query was misformatted",
                "DNS server returned general failure", "Domain name not found", "DNS server does not implement requested operation",
                "DNS server refused query", "Misformatted DNS query", "Misformatted domain name", "Unsupported address family",
                "Misformatted DNS reply", "Could not contact DNS servers", "Timeout while contacting DNS servers",
                "End of file", "Error reading file", "Out of memory", "Channel is being destroyed", "Misformatted string",
                "Illegal flags specified", "Given hostname is not numeric", "Illegal hints flags specified",
                "c-ares library initialization not yet performed", "Error loading iphlpapi.dll",
                "Could not find GetNetworkParams function", "DNS query cancelled"],
    case is_integer(Code) andalso Code >= 0 andalso Code < length(Messages) of
        true -> buoy_node:string(lists:nth(Code + 1, Messages));
        false -> buoy_node:string("unknown")
    end.
