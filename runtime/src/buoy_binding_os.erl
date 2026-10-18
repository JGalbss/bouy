%% internalBinding('os') (src/node_os.cc): the facts of the machine and the
%% user that the os module reports.
-module(buoy_binding_os).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    buoy_node:object([
        {<<"getHostname">>, F(<<"getHostname">>, 0, fun(_, _) ->
            {ok, Host} = inet:gethostname(),
            buoy_node:string(Host)
        end)},
        {<<"getLoadAvg">>, F(<<"getLoadAvg">>, 1, fun(_, A) ->
            Array = buoy_node:arg(1, A),
            Loads = load_averages(),
            [buoy_heap:set(Array, I, L) || {I, L} <- lists:enumerate(0, Loads)],
            undefined
        end)},
        {<<"getUptime">>, F(<<"getUptime">>, 0, fun(_, _) -> uptime() end)},
        {<<"getTotalMem">>, F(<<"getTotalMem">>, 0, fun(_, _) -> total_memory() end)},
        {<<"getFreeMem">>, F(<<"getFreeMem">>, 0, fun(_, _) -> free_memory() end)},
        {<<"getCPUs">>, F(<<"getCPUs">>, 0, fun(_, _) ->
            Count = erlang:system_info(logical_processors_available),
            N = case Count of unknown -> erlang:system_info(schedulers); _ -> Count end,
            Model = cpu_model(),
            buoy_heap:new_array(lists:append([[Model, 0, 0, 0, 0, 0, 0] || _ <- lists:seq(1, N)]))
        end)},
        {<<"getInterfaceAddresses">>, F(<<"getInterfaceAddresses">>, 1, fun(_, _) -> interfaces() end)},
        {<<"getHomeDirectory">>, F(<<"getHomeDirectory">>, 0, fun(_, _) ->
            case os:getenv("HOME") of
                false -> <<"/">>;
                Home -> buoy_node:string(Home)
            end
        end)},
        {<<"getUserInfo">>, F(<<"getUserInfo">>, 2, fun(_, _) -> user_info() end)},
        {<<"setPriority">>, F(<<"setPriority">>, 3, fun(_, _) -> 0 end)},
        {<<"getPriority">>, F(<<"getPriority">>, 2, fun(_, _) -> 0 end)},
        {<<"getAvailableParallelism">>, F(<<"getAvailableParallelism">>, 0, fun(_, _) -> erlang:system_info(schedulers_online) end)},
        {<<"getOSInformation">>, F(<<"getOSInformation">>, 1, fun(_, _) -> os_information() end)},
        {<<"isBigEndian">>, false}]).

load_averages() ->
    case string:lexemes(os:cmd("uptime"), " ,\n") of
        Words when length(Words) >= 3 ->
            [to_float(W) || W <- lists:nthtail(length(Words) - 3, Words)];
        _ ->
            [0, 0, 0]
    end.

to_float(Text) ->
    try list_to_float(Text)
    catch _:_ ->
        try list_to_integer(Text) catch _:_ -> 0 end
    end.

uptime() ->
    case os:type() of
        {unix, darwin} ->
            case re:run(os:cmd("sysctl -n kern.boottime"), "sec = ([0-9]+)", [{capture, all_but_first, list}]) of
                {match, [Boot]} -> erlang:system_time(second) - list_to_integer(Boot);
                _ -> 0
            end;
        _ ->
            case file:read_file("/proc/uptime") of
                {ok, Text} -> trunc(to_float(hd(string:lexemes(binary_to_list(Text), " "))));
                _ -> 0
            end
    end.

total_memory() ->
    case os:type() of
        {unix, darwin} -> trunc(to_float(string:trim(os:cmd("sysctl -n hw.memsize"))));
        _ -> meminfo("MemTotal")
    end.

free_memory() ->
    case os:type() of
        {unix, darwin} ->
            Pages = trunc(to_float(string:trim(os:cmd("sysctl -n vm.page_free_count")))),
            Pages * 16384;
        _ ->
            meminfo("MemAvailable")
    end.

meminfo(Key) ->
    case file:read_file("/proc/meminfo") of
        {ok, Text} ->
            case re:run(Text, Key ++ ":\\s+([0-9]+)", [{capture, all_but_first, list}]) of
                {match, [Kb]} -> list_to_integer(Kb) * 1024;
                _ -> 0
            end;
        _ ->
            0
    end.

cpu_model() ->
    case os:type() of
        {unix, darwin} -> buoy_node:string(string:trim(os:cmd("sysctl -n machdep.cpu.brand_string")));
        _ -> <<"unknown">>
    end.

%% The flat list of getInterfaceAddresses: name, address, netmask, family,
%% mac, internal, scope id for each address.
interfaces() ->
    case inet:getifaddrs() of
        {ok, Interfaces} ->
            buoy_heap:new_array(lists:append([interface(Name, Options) || {Name, Options} <- Interfaces]));
        _ ->
            undefined
    end.

interface(Name, Options) ->
    Mac = case proplists:get_value(hwaddr, Options) of
        Bytes when is_list(Bytes), length(Bytes) =:= 6 -> iolist_to_binary(lists:join(":", [io_lib:format("~2.16.0b", [B]) || B <- Bytes]));
        _ -> <<"00:00:00:00:00:00">>
    end,
    Internal = lists:member(loopback, proplists:get_value(flags, Options, [])),
    Pairs = pairs(Options),
    lists:append([[buoy_node:string(Name), address(A), address(M), family(A), Mac, Internal, -1] || {A, M} <- Pairs]).

pairs([{addr, A}, {netmask, M} | Rest]) -> [{A, M} | pairs(Rest)];
pairs([_ | Rest]) -> pairs(Rest);
pairs([]) -> [].

address(A) -> buoy_node:string(inet:ntoa(A)).

family(A) when tuple_size(A) =:= 4 -> <<"IPv4">>;
family(_) -> <<"IPv6">>.

user_info() ->
    [UidText, GidText, User] = lines("id -u; id -g; id -un"),
    Uid = list_to_integer(UidText),
    Gid = list_to_integer(GidText),
    Home = case os:getenv("HOME") of false -> "/"; H -> H end,
    Shell = case os:getenv("SHELL") of false -> null; S -> buoy_node:string(S) end,
    buoy_node:object([{<<"uid">>, Uid}, {<<"gid">>, Gid}, {<<"username">>, buoy_node:string(User)},
                      {<<"homedir">>, buoy_node:string(Home)}, {<<"shell">>, Shell}]).

os_information() ->
    buoy_heap:new_array([buoy_node:string(Field) || Field <- lines("uname -s; uname -v; uname -r; uname -m")]).

%% The lines that one shell prints: a shell costs a process spawn, and
%% lib/os.js reads the OS information when it loads, so each command runs
%% once per VM.
lines(Command) ->
    Key = {?MODULE, Command},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Lines = string:split(string:trim(os:cmd(Command)), "\n", all),
            persistent_term:put(Key, Lines),
            Lines;
        Lines ->
            Lines
    end.
