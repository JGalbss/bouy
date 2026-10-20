%% internalBinding('os') (src/node_os.cc): the facts of the machine and the
%% user that the os module reports. Linux reads them from /proc, as libuv and
%% Bun do; darwin has no /proc, so it asks sysctl(8), which reads the same
%% sysctl names that Bun reads with sysctlbyname. A function that fails fills
%% its ctx argument as CollectUVExceptionInfo does and returns undefined, and
%% lib/os.js throws ERR_SYSTEM_ERROR from it.
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
        {<<"getLoadAvg">>, F(<<"getLoadAvg">>, 0, fun(_, A) ->
            Array = buoy_node:arg(1, A),
            [buoy_heap:set(Array, I, L) || {I, L} <- lists:enumerate(0, load_averages())],
            undefined
        end)},
        {<<"getUptime">>, F(<<"getUptime">>, 0, fun(_, _) -> uptime() end)},
        {<<"getTotalMem">>, F(<<"getTotalMem">>, 0, fun(_, _) -> total_memory() end)},
        {<<"getFreeMem">>, F(<<"getFreeMem">>, 0, fun(_, _) -> free_memory() end)},
        {<<"getCPUs">>, F(<<"getCPUs">>, 0, fun(_, _) -> buoy_heap:new_array(cpus()) end)},
        {<<"getInterfaceAddresses">>, F(<<"getInterfaceAddresses">>, 0, fun(_, _) -> interfaces() end)},
        {<<"getHomeDirectory">>, F(<<"getHomeDirectory">>, 0, fun(_, A) -> home_directory(buoy_node:arg(1, A)) end)},
        {<<"getUserInfo">>, F(<<"getUserInfo">>, 0, fun(_, A) -> user_info(buoy_node:arg(1, A), buoy_node:arg(2, A)) end)},
        {<<"setPriority">>, F(<<"setPriority">>, 0, fun(_, A) ->
            set_priority(os_pid(buoy_node:arg(1, A)), buoy_node:arg(2, A), buoy_node:arg(3, A))
        end)},
        {<<"getPriority">>, F(<<"getPriority">>, 0, fun(_, A) -> get_priority(os_pid(buoy_node:arg(1, A)), buoy_node:arg(2, A)) end)},
        {<<"getAvailableParallelism">>, F(<<"getAvailableParallelism">>, 0, fun(_, _) -> parallelism() end)},
        {<<"getOSInformation">>, F(<<"getOSInformation">>, 0, fun(_, _) -> os_information() end)},
        {<<"isBigEndian">>, false}]).

%%% Load, uptime, and memory

load_averages() ->
    Text = case file:read_file("/proc/loadavg") of
        {ok, Loadavg} -> binary_to_list(Loadavg);
        _ -> sysctl("vm.loadavg")
    end,
    case [to_number(W) || W <- string:lexemes(Text, " {}\n")] of
        [One, Five, Fifteen | _] -> [One, Five, Fifteen];
        _ -> [0, 0, 0]
    end.

uptime() ->
    case file:read_file("/proc/uptime") of
        {ok, Text} ->
            to_number(hd(string:lexemes(binary_to_list(Text), " ")));
        _ ->
            case re:run(sysctl("kern.boottime"), "sec = ([0-9]+)", [{capture, all_but_first, list}]) of
                {match, [Boot]} -> erlang:system_time(second) - list_to_integer(Boot);
                _ -> 0
            end
    end.

total_memory() ->
    case meminfo("MemTotal") of
        undefined -> to_number(string:trim(sysctl("hw.memsize")));
        Bytes -> Bytes
    end.

%% uv_get_free_memory: MemAvailable on Linux, and the free pages of the
%% virtual memory statistics on darwin.
free_memory() ->
    case meminfo("MemAvailable") of
        undefined ->
            case [to_number(W) || W <- string:lexemes(sysctl("vm.page_free_count hw.pagesize"), "\n")] of
                [Pages, PageSize] -> Pages * PageSize;
                _ -> 0
            end;
        Bytes ->
            Bytes
    end.

meminfo(Key) ->
    case file:read_file("/proc/meminfo") of
        {ok, Text} ->
            case re:run(Text, Key ++ ":\\s+([0-9]+)", [{capture, all_but_first, list}]) of
                {match, [Kb]} -> list_to_integer(Kb) * 1024;
                _ -> undefined
            end;
        _ ->
            undefined
    end.

parallelism() ->
    case erlang:system_info(logical_processors_available) of
        unknown -> erlang:system_info(logical_processors);
        Count -> Count
    end.

%%% CPUs

%% The flat list of getCPUs: model, speed, and the user, nice, sys, idle, and
%% irq times in milliseconds of each CPU.
cpus() ->
    case file:read_file("/proc/stat") of
        {ok, Stat} -> linux_cpus(Stat);
        _ -> darwin_cpus()
    end.

%% /proc/stat counts the ticks of each CPU, at the USER_HZ of 100 that the
%% kernel reports to user space, as uv_cpu_info reads them.
linux_cpus(Stat) ->
    Lines = [string:lexemes(Line, " ") || Line <- string:split(binary_to_list(Stat), "\n", all)],
    Times = [[list_to_integer(T) * 10 || T <- Ticks] || ["cpu" ++ [D | _] | Ticks] <- Lines, D >= $0, D =< $9],
    Models = linux_models(),
    lists:append([[model(Models, I), linux_speed(I), User, Nice, Sys, Idle, Irq]
                   || {I, [User, Nice, Sys, Idle, _IoWait, Irq | _]} <- lists:enumerate(0, Times)]).

linux_models() ->
    case file:read_file("/proc/cpuinfo") of
        {ok, Info} ->
            {match, Models} = re:run(Info, "^model name\\s*: ([^\\n]*)", [global, multiline, {capture, all_but_first, binary}]),
            [buoy_node:string(Model) || [Model] <- Models];
        _ ->
            []
    end.

model(Models, I) when I < length(Models) -> lists:nth(I + 1, Models);
model(_, _) -> <<"unknown">>.

linux_speed(I) ->
    case file:read_file(io_lib:format("/sys/devices/system/cpu/cpu~b/cpufreq/scaling_cur_freq", [I])) of
        {ok, Khz} -> to_number(string:trim(binary_to_list(Khz))) div 1000;
        _ -> 0
    end.

%% shortcut: darwin keeps the ticks of each CPU in host_processor_info,
%% which no command prints, so the times are 0; read them through a port
%% program when a user needs them on darwin.
darwin_cpus() ->
    [Count, Model | Hz] = cached("sysctl -n hw.logicalcpu machdep.cpu.brand_string; sysctl -n hw.cpufrequency 2>/dev/null"),
    %% arm64 has no hw.cpufrequency, and libuv reports 2400 MHz for it.
    Speed = case Hz of [H] -> to_number(H) div 1000000; [] -> 2400 end,
    lists:append(lists:duplicate(to_number(Count), [buoy_node:string(Model), Speed, 0, 0, 0, 0, 0])).

%%% Network interfaces

%% The flat list of getInterfaceAddresses: name, address, netmask, family,
%% mac, internal, and scope id for each address of an interface that is up
%% and running, as uv_interface_addresses lists them.
interfaces() ->
    case inet:getifaddrs() of
        {ok, Interfaces} ->
            buoy_heap:new_array(lists:append([interface(Name, Options) || {Name, Options} <- Interfaces, is_running(Options)]));
        _ ->
            undefined
    end.

is_running(Options) ->
    Flags = proplists:get_value(flags, Options, []),
    lists:member(up, Flags) andalso lists:member(running, Flags).

interface(Name, Options) ->
    Mac = case proplists:get_value(hwaddr, Options) of
        Bytes when is_list(Bytes), length(Bytes) =:= 6 -> iolist_to_binary(lists:join(":", [io_lib:format("~2.16.0b", [B]) || B <- Bytes]));
        _ -> <<"00:00:00:00:00:00">>
    end,
    Internal = lists:member(loopback, proplists:get_value(flags, Options, [])),
    [Field || {A, M} <- pairs(Options),
              Field <- [buoy_node:string(Name), address(A), address(M), family(A), Mac, Internal, scope_id(Name, A)]].

pairs([{addr, A}, {netmask, M} | Rest]) -> [{A, M} | pairs(Rest)];
pairs([_ | Rest]) -> pairs(Rest);
pairs([]) -> [].

address(A) -> buoy_node:string(inet:ntoa(A)).

family(A) when tuple_size(A) =:= 4 -> <<"IPv4">>;
family(_) -> <<"IPv6">>.

%% The sin6_scope_id of an IPv6 address: the index of its interface for a
%% link-local address, and 0 for the others.
scope_id(_, A) when tuple_size(A) =:= 4 -> -1;
scope_id(Name, {16#fe80, _, _, _, _, _, _, _}) ->
    case net:if_name2index(Name) of
        {ok, Index} -> Index;
        _ -> 0
    end;
scope_id(_, _) -> 0.

%%% The user

%% getHomeDirectory(ctx): uv_os_homedir, which reads HOME and then the
%% passwd entry of the user.
home_directory(Ctx) ->
    case os:getenv("HOME") of
        Home when Home =/= false, Home =/= "" -> buoy_node:string(Home);
        _ ->
            case passwd() of
                {ok, #{home := Home}} -> buoy_node:string(Home);
                error -> fail(Ctx, <<"ENOENT">>, <<"uv_os_homedir">>)
            end
    end.

%% getUserInfo(options, ctx): the passwd entry of the effective user, with
%% the strings in the encoding of options.encoding.
user_info(Options, Ctx) ->
    Encoding = case buoy_heap:is_object(Options) of
        true ->
            case buoy_node_encoding:parse(buoy_heap:get(Options, <<"encoding">>)) of
                {ok, E} -> E;
                error -> utf8
            end;
        false ->
            utf8
    end,
    case passwd() of
        {ok, #{uid := Uid, gid := Gid, name := Name, home := Home, shell := Shell}} ->
            Encode = fun(Text) -> encode(Encoding, unicode:characters_to_binary(Text)) end,
            buoy_node:object([{<<"uid">>, Uid}, {<<"gid">>, Gid}, {<<"username">>, Encode(Name)},
                              {<<"homedir">>, Encode(Home)}, {<<"shell">>, Encode(Shell)}]);
        error ->
            fail(Ctx, <<"ENOENT">>, <<"uv_os_get_passwd">>)
    end.

encode(buffer, Bytes) -> buoy_node_encoding:new_buffer(Bytes);
encode(Encoding, Bytes) -> buoy_node_encoding:decode(Encoding, Bytes).

%% The passwd entry of the effective user, as getpwuid_r(3) reads it: id -P
%% prints it on darwin, and getent passwd on Linux, which also asks NSS.
passwd() ->
    Line = hd(cached("id -P 2>/dev/null || getent passwd \"$(id -u)\" 2>/dev/null || grep \"^[^:]*:[^:]*:$(id -u):\" /etc/passwd")),
    case string:split(Line, ":", all) of
        [Name, _, Uid, Gid | Rest] when length(Rest) >= 3 ->
            [Home, Shell] = lists:nthtail(length(Rest) - 2, Rest),
            {ok, #{name => Name, uid => list_to_integer(Uid), gid => list_to_integer(Gid), home => Home, shell => Shell}};
        _ ->
            error
    end.

%%% Priority

%% A pid of 0 names the calling process: the OS process of the VM.
os_pid(Pid) ->
    case trunc(buoy_ref:to_number(Pid)) of
        0 -> list_to_integer(os:getpid());
        N -> N
    end.

%% getPriority(pid, ctx): the nice value of the process, which Linux keeps
%% in field 19 of /proc/<pid>/stat and ps(1) prints on darwin.
get_priority(Pid, Ctx) ->
    Nice = case file:read_file(io_lib:format("/proc/~b/stat", [Pid])) of
        {ok, Stat} ->
            [_, Fields] = string:split(Stat, ")", trailing),
            {ok, lists:nth(17, string:lexemes(Fields, " "))};
        _ when Pid > 0 ->
            case run("ps", ["-o", "nice=", "-p", integer_to_list(Pid)]) of
                {0, Out} -> {ok, string:trim(Out)};
                _ -> error
            end;
        _ ->
            error
    end,
    case Nice of
        {ok, Text} -> to_number(Text);
        error -> fail(Ctx, <<"ESRCH">>, <<"uv_os_getpriority">>)
    end.

%% setPriority(pid, priority, ctx): 0, or the error of renice(8), which
%% calls setpriority(2) as uv_os_setpriority does.
set_priority(Pid, Priority, Ctx) ->
    case run("renice", [integer_to_list(trunc(buoy_ref:to_number(Priority))), "-p", integer_to_list(Pid)]) of
        {0, _} ->
            0;
        {127, _} ->
            fail(Ctx, <<"ENOSYS">>, <<"uv_os_setpriority">>),
            -1;
        {_, Out} ->
            Code = case Out of
                _ when Pid < 0 -> <<"ESRCH">>;
                _ -> renice_error(string:lowercase(Out))
            end,
            fail(Ctx, Code, <<"uv_os_setpriority">>),
            -1
    end.

renice_error(Out) ->
    Codes = [{"permission denied", <<"EACCES">>}, {"not permitted", <<"EPERM">>}, {"no such process", <<"ESRCH">>}],
    case [Code || {Text, Code} <- Codes, string:find(Out, Text) =/= nomatch] of
        [Code | _] -> Code;
        [] -> <<"EPERM">>
    end.

%%% The OS

os_information() ->
    buoy_heap:new_array([buoy_node:string(Field) || Field <- cached("uname -s; uname -v; uname -r; uname -m")]).

%%% Helpers

%% Fills ctx as CollectUVExceptionInfo does for the libuv error Code of
%% Syscall, and returns undefined, the failure of a binding function.
fail(Ctx, Code, Syscall) ->
    [{Errno, Message} | _] = [{N, M} || {N, Name, M} <- buoy_binding_uv:errors(), Name =:= Code],
    [buoy_heap:set(Ctx, K, V) || buoy_heap:is_object(Ctx),
                                 {K, V} <- [{<<"errno">>, Errno}, {<<"code">>, Code}, {<<"message">>, Message}, {<<"syscall">>, Syscall}]],
    undefined.

%% The output of sysctl -n for Names, or "" where sysctl is missing.
sysctl(Names) ->
    os:cmd("sysctl -n " ++ Names ++ " 2>/dev/null").

%% The exit status and the output of Program, run without a shell.
run(Program, Args) ->
    case os:find_executable(Program) of
        false ->
            {127, ""};
        Path ->
            Port = open_port({spawn_executable, Path}, [{args, Args}, exit_status, stderr_to_stdout, hide]),
            collect(Port, [])
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Acc, Data]);
        {Port, {exit_status, Status}} -> {Status, lists:flatten(Acc)}
    end.

to_number(Text) when is_binary(Text) -> to_number(binary_to_list(Text));
to_number(Text) ->
    try list_to_float(Text)
    catch _:_ ->
        try list_to_integer(Text) catch _:_ -> 0 end
    end.

%% The lines that one shell command prints. A shell costs a process spawn,
%% and the answers never change while the VM runs, so each command runs once
%% per VM.
cached(Command) ->
    Key = {?MODULE, Command},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Lines = string:split(string:trim(os:cmd(Command)), "\n", all),
            persistent_term:put(Key, Lines),
            Lines;
        Lines ->
            Lines
    end.
