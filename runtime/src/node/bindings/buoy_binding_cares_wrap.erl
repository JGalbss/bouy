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
    Channel = buoy_node:constructor(<<"ChannelWrap">>, 3, fun(This, Args) -> channel(This, A(1, Args), A(2, Args), A(3, Args)) end),
    Proto = buoy_heap:get(Channel, <<"prototype">>),
    Queries = [{<<"queryAny">>, any}, {<<"queryA">>, a}, {<<"queryAaaa">>, aaaa}, {<<"queryCaa">>, caa},
               {<<"queryCname">>, cname}, {<<"queryMx">>, mx}, {<<"queryNs">>, ns}, {<<"queryTlsa">>, tlsa},
               {<<"queryTxt">>, txt}, {<<"querySrv">>, srv}, {<<"queryPtr">>, ptr}, {<<"queryNaptr">>, naptr},
               {<<"querySoa">>, soa}, {<<"getHostByAddr">>, reverse}],
    Methods = [{Name, fun(This, Args) -> query(This, Type, A(1, Args), text(A(2, Args))) end} || {Name, Type} <- Queries]
        ++ [{<<"getServers">>, fun(This, _) -> get_servers(This) end},
            {<<"setServers">>, fun(This, Args) -> set_servers(This, A(1, Args)) end},
            {<<"setLocalAddress">>, fun(_, Args) -> set_local_address(A(1, Args), A(2, Args)) end},
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
                %% NI_NAMEREQD: an address with no name fails.
                case inet:gethostbyaddr(Address) of
                    {ok, {hostent, Name, _, _, _, _}} ->
                        Service = case inet:getservbyport(PortNumber, tcp) of
                            {ok, S} -> S;
                            {error, _} -> integer_to_list(PortNumber)
                        end,
                        {ok, Name, Service};
                    {error, Reason} ->
                        {error, Reason}
                end;
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

%% ChannelWrap(timeout, tries, maxTimeout): c-ares's defaults are a
%% 2000 ms timeout that doubles at each of 4 tries, up to maxTimeout. A
%% timeout of 0 is set (ARES_OPT_TIMEOUTMS), so a try waits the 250 ms floor.
channel(This, Timeout, Tries, MaxTimeout) ->
    Ms = case buoy_ref:to_number(Timeout) of
        T when is_number(T), T >= 0 -> trunc(T);
        _ -> 2000
    end,
    Retry = case buoy_ref:to_number(Tries) of
        N when is_number(N), N >= 1 -> trunc(N);
        _ -> 4
    end,
    Max = case buoy_ref:to_number(MaxTimeout) of
        M when is_number(M), M > 0 -> trunc(M);
        _ -> infinity
    end,
    buoy_heap:private_put(This, ?CHANNEL, #{servers => default_servers(), timeout => Ms, tries => Retry,
                                            max_timeout => Max, pending => []}),
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

%% setServers([[family, ip, port], ...]): 0, DNS_ESETSRVPENDING while a
%% query waits, or the c-ares error ARES_EBADSTR.
set_servers(This, List) ->
    case [R || {R, _} <- maps:get(pending, channel_state(This)), erlang:get({?MODULE, pending, R}) =/= undefined] of
        [] -> replace_servers(This, List);
        _ -> -1000
    end.

replace_servers(This, List) ->
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
     || {Ref, Req} <- lists:reverse(Pending), erlang:get({?MODULE, pending, Ref}) =/= undefined],
    undefined.

%% A query of the channel: 0, then req.oncomplete(0, result[, ttls]) or
%% req.oncomplete(code), with the code of c-ares, such as 'ENOTFOUND'.
query(This, Type, Req, Name) ->
    #{servers := Servers, timeout := Timeout, tries := Tries, max_timeout := Max, pending := Pending} = S = channel_state(This),
    Waits = [try_wait(Timeout, Max, I) || I <- lists:seq(0, Tries - 1)],
    {Question, Kind} = case Type of
        reverse -> {reverse_name(Name), ptr};
        tlsa -> {Name, 52};
        _ -> {Name, Type}
    end,
    Work = fun() -> resolve(Question, Kind, Servers, Waits) end,
    Ref = start(Req, Work, fun(Result) -> answer(This, Req, Type, Result) end),
    Live = [P || {R, _} = P <- Pending, erlang:get({?MODULE, pending, R}) =/= undefined],
    buoy_heap:private_put(This, ?CHANNEL, S#{pending := [{Ref, Req} | Live]}),
    0.

%% The wait of try Round, as ares_calc_query_timeout computes it: the
%% timeout, at least 250 ms and at most maxTimeout or 5000 ms, doubles
%% each round up to maxTimeout, and a retry waits a random 50% to 100% of
%% that, but never less than the timeout.
try_wait(Timeout, Max, Round) ->
    Cap = case Max of infinity -> 5000; _ -> Max end,
    Base = min(max(Timeout, 250), Cap),
    Doubled = min(Base bsl Round, Max),
    Jittered = case Round of
        0 -> Doubled;
        _ -> Doubled - trunc(Doubled * rand:uniform() / 2)
    end,
    max(Jittered, Timeout).

%% RFC 7686: c-ares answers a .onion name NXDOMAIN and sends no query.
resolve(Question, Kind, Servers, Waits) ->
    case lists:suffix(".onion", string:lowercase(string:trim(Question, trailing, "."))) of
        true -> {error, nxdomain};
        false -> resolve_servers(Question, Kind, Servers, Waits)
    end.

resolve_servers(_Question, _Kind, [], _Waits) ->
    {error, econnrefused};
resolve_servers(Question, Kind, Servers, [Wait | Rest]) ->
    case resolve_once(Question, Kind, [{nameservers, Servers}, {timeout, Wait}, {retry, 1}]) of
        {error, timeout} when Rest =/= [] -> resolve_servers(Question, Kind, Servers, Rest);
        Result -> Result
    end.

resolve_once(Question, Kind, Options) ->
    case inet_res:resolve(Question, in, Kind, Options) of
        {ok, Msg} -> {ok, [{inet_dns:rr(RR, type), inet_dns:rr(RR, ttl), inet_dns:rr(RR, data)} || RR <- inet_dns:msg(Msg, anlist)]};
        %% A reply that does not decode is formerr; a FORMERR rcode is qfmterror.
        {error, formerr} -> {error, badresp};
        {error, {qfmterror, _Msg}} -> {error, formerr};
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
code(badresp) -> "EBADRESP";
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
records(aaaa, Records) -> [{ntoa6(D), Ttl} || {aaaa, Ttl, D} <- Records];
records(reverse, Records) -> [str(D) || {ptr, _, D} <- Records];
records(Type, Records) ->
    Kind = case Type of tlsa -> 52; _ -> Type end,
    [record(Type, D) || {K, _, D} <- Records, K =:= Kind].

ntoa(Address) -> buoy_node:string(inet:ntoa(Address)).

%% An IPv6 address as ares_inet_ntop writes it: the longest run of zero
%% groups as ::, and the IPv4 form only for ::a.b.c.d with six zero groups
%% and for ::ffff:a.b.c.d. inet:ntoa writes ::0.0.0.66 for ::42.
ntoa6({0, 0, 0, 0, 0, W6, _, _} = A) when W6 =:= 0; W6 =:= 16#ffff ->
    case A of
        {0, 0, 0, 0, 0, 0, 0, _} -> buoy_node:string(compress(A));
        _ -> ntoa(A)
    end;
ntoa6(A) ->
    buoy_node:string(compress(A)).

compress(A) ->
    Words = tuple_to_list(A),
    {Start, Length} = longest_zeros(Words),
    Hex = [integer_to_list(W, 16) || W <- Words],
    Text = case Length >= 2 of
        true ->
            {Before, Rest} = lists:split(Start, Hex),
            After = lists:nthtail(Length, Rest),
            lists:join(":", Before) ++ "::" ++ lists:join(":", After);
        false ->
            lists:join(":", Hex)
    end,
    string:lowercase(lists:flatten(Text)).

%% The first longest run of zero groups: {start, length}.
longest_zeros(Words) ->
    {_, _, Best} = lists:foldl(fun
        (0, {I, Run, Best}) -> {I + 1, Run + 1, better({I - Run, Run + 1}, Best)};
        (_, {I, _, Best}) -> {I + 1, 0, Best}
    end, {0, 0, {0, 0}}, Words),
    Best.

better({_, L} = New, {_, B}) when L > B -> New;
better(_, Best) -> Best.

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
any_record(aaaa, Ttl, D) -> obj([{<<"address">>, ntoa6(D)}, {<<"ttl">>, Ttl}, {<<"type">>, str("AAAA")}]);
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

%% setLocalAddress(ip[, ip]): an IPv4 and an IPv6 address, in either order.
set_local_address(First, Second) ->
    Family = fun(V) ->
        case inet:parse_strict_address(text(V)) of
            {ok, {_, _, _, _}} -> 4;
            {ok, _} -> 6;
            {error, _} -> none
        end
    end,
    case {Family(First), Second =/= undefined andalso Family(Second)} of
        {none, _} -> invalid(<<"Invalid IP address.">>);
        {4, Other} when Other =/= false, Other =/= 6 -> invalid(<<"Invalid IPv6 address.">>);
        {6, Other} when Other =/= false, Other =/= 4 -> invalid(<<"Invalid IPv4 address.">>);
        _ -> undefined
    end.

invalid(Message) ->
    buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_VALUE">>, Message).

%% ares_strerror, and Node's DNS_ESETSRVPENDING.
strerror(-1000) ->
    buoy_node:string("There are pending queries.");
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
