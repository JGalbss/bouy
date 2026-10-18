%% internalBinding('block_list') (src/node_sockaddr.cc): SocketAddress, an
%% IP address with a port and an IPv6 flow label, and BlockList, the rules
%% of net.BlockList: addresses, ranges, and subnets, newest first. An IPv4
%% address matches its IPv4-mapped IPv6 form, as SocketAddress::is_match
%% compares them.
-module(buoy_binding_block_list).

-export([binding/0]).

-define(ADDRESS, {'#', ?MODULE, <<"address">>}).
-define(RULES, {'#', ?MODULE, <<"rules">>}).
-define(AF_INET, 2).
-define(AF_INET6, 30).

-spec binding() -> term().
binding() ->
    A = fun buoy_node:arg/2,
    Address = buoy_node:constructor(<<"SocketAddress">>, 4, fun(This, Args) ->
        new_address(This, A(1, Args), A(2, Args), A(3, Args), A(4, Args))
    end),
    define(buoy_heap:get(Address, <<"prototype">>), [
        {<<"detail">>, fun(This, Args) -> detail(This, A(1, Args)) end},
        {<<"flowlabel">>, fun(This, _) -> element(4, address(This)) end}]),
    List = buoy_node:constructor(<<"BlockList">>, 0, fun(This, _) -> buoy_heap:private_put(This, ?RULES, []), undefined end),
    define(buoy_heap:get(List, <<"prototype">>), [
        {<<"addAddress">>, fun(This, Args) -> add(This, {address, value(A(1, Args))}), undefined end},
        {<<"addRange">>, fun(This, Args) -> add_range(This, value(A(1, Args)), value(A(2, Args))) end},
        {<<"addSubnet">>, fun(This, Args) -> add(This, {subnet, value(A(1, Args)), trunc(buoy_ref:to_number(A(2, Args)))}), undefined end},
        {<<"check">>, fun(This, Args) -> check(This, value(A(1, Args))) end},
        {<<"getRules">>, fun(This, _) -> buoy_heap:new_array([buoy_node:string(text(R)) || R <- rules(This)]) end}]),
    buoy_node:object([{<<"BlockList">>, List}, {<<"SocketAddress">>, Address},
                      {<<"AF_INET">>, ?AF_INET}, {<<"AF_INET6">>, ?AF_INET6}]).

define(Proto, Methods) ->
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    ok.

%%% SocketAddress

new_address(This, Text, Port, Family, Flowlabel) ->
    Parse = case buoy_ref:to_number(Family) of
        ?AF_INET -> fun inet:parse_ipv4strict_address/1;
        _ -> fun inet:parse_ipv6strict_address/1
    end,
    case Parse(unicode:characters_to_list(buoy_ref_string:to_utf8(buoy_ref:to_string(Text)))) of
        {ok, Ip} ->
            buoy_heap:private_put(This, ?ADDRESS, {Ip, int(Port), int(Flowlabel), int(Flowlabel)}),
            undefined;
        {error, _} ->
            buoy_node:throw_code('Error', <<"ERR_INVALID_ADDRESS">>, <<"Invalid socket address">>)
    end.

int(V) ->
    case buoy_ref:to_number(V) of
        N when is_integer(N) -> N;
        _ -> 0
    end.

address(This) ->
    {ok, {Ip, Port, _, Flowlabel}} = buoy_heap:private_find(This, ?ADDRESS),
    {Ip, Port, family(Ip), Flowlabel}.

family(Ip) when tuple_size(Ip) =:= 4 -> ?AF_INET;
family(_) -> ?AF_INET6.

detail(This, Out) ->
    {Ip, Port, Family, Flowlabel} = address(This),
    [buoy_heap:set(Out, K, V) || {K, V} <- [{<<"address">>, buoy_node:string(inet:ntoa(Ip))}, {<<"port">>, Port},
                                            {<<"family">>, Family}, {<<"flowlabel">>, Flowlabel}]],
    Out.

%% The IP of a SocketAddress handle.
value(Handle) -> element(1, address(Handle)).

%%% BlockList

rules(This) ->
    {ok, Rules} = buoy_heap:private_find(This, ?RULES),
    Rules.

add(This, Rule) ->
    buoy_heap:private_put(This, ?RULES, [Rule | rules(This)]).

add_range(This, Start, End) ->
    case compare(Start, End) of
        greater -> false;
        _ -> add(This, {range, Start, End}), true
    end.

check(This, Ip) ->
    lists:any(fun(Rule) -> applies(Rule, Ip) end, rules(This)).

applies({address, Rule}, Ip) -> compare(Rule, Ip) =:= equal;
applies({range, Start, End}, Ip) ->
    lists:member(compare(Start, Ip), [less, equal]) andalso lists:member(compare(End, Ip), [greater, equal]);
applies({subnet, Network, Prefix}, Ip) ->
    case {Network, as(family(Network), Ip)} of
        {_, none} -> false;
        {Net, Value} ->
            Bits = bits(family(Net)),
            Shift = Bits - Prefix,
            (integer(Net) bsr Shift) =:= (Value bsr Shift)
    end.

bits(?AF_INET) -> 32;
bits(?AF_INET6) -> 128.

%% equal, less, or greater, with an IPv4 address and its IPv4-mapped IPv6
%% form the same; addresses of the two families that cannot meet are
%% unordered.
compare(A, B) ->
    case as(family(A), B) of
        none -> unordered;
        Value ->
            Own = integer(A),
            if
                Own =:= Value -> equal;
                Own < Value -> less;
                true -> greater
            end
    end.

%% The integer of Ip in the family Family, or none.
as(?AF_INET, {_, _, _, _} = Ip) -> integer(Ip);
as(?AF_INET, {0, 0, 0, 0, 0, 16#ffff, Hi, Lo}) -> (Hi bsl 16) bor Lo;
as(?AF_INET, _) -> none;
as(?AF_INET6, {_, _, _, _} = Ip) -> (16#ffff bsl 32) bor integer(Ip);
as(?AF_INET6, Ip) -> integer(Ip).

integer({A, B, C, D}) -> (A bsl 24) bor (B bsl 16) bor (C bsl 8) bor D;
integer(Ip) -> lists:foldl(fun(W, Acc) -> (Acc bsl 16) bor W end, 0, tuple_to_list(Ip)).

text({address, Ip}) -> ["Address: ", name(Ip), " ", inet:ntoa(Ip)];
text({range, Start, End}) -> ["Range: ", name(Start), " ", inet:ntoa(Start), "-", inet:ntoa(End)];
text({subnet, Ip, Prefix}) -> ["Subnet: ", name(Ip), " ", inet:ntoa(Ip), "/", integer_to_list(Prefix)].

name(Ip) when tuple_size(Ip) =:= 4 -> "IPv4";
name(_) -> "IPv6".
