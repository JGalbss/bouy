%% internalBinding('process_methods') (src/node_process_methods.cc): the
%% methods of the process object that need the OS or the VM.
-module(buoy_binding_process_methods).

-include("buoy_ref.hrl").

-export([binding/0, really_exit/2, abort/2, segfault/2, dlopen/2]).

-define(UMASK, '$buoy_node_umask').

-spec binding() -> term().
binding() ->
    Hr = buoy_node:typed_array(<<"Uint32Array">>, 3),
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    buoy_node:object([
        {<<"hrtime">>, F(<<"hrtime">>, 0, fun(_, _) ->
            Ns = erlang:monotonic_time(nanosecond) - erlang:system_info(start_time),
            Sec = Ns div 1000000000,
            buoy_heap:set(Hr, 0, Sec bsr 32),
            buoy_heap:set(Hr, 1, Sec band 16#FFFFFFFF),
            buoy_heap:set(Hr, 2, Ns rem 1000000000),
            undefined
        end)},
        {<<"hrtimeBigInt">>, F(<<"hrtimeBigInt">>, 0, fun(_, _) ->
            Ns = erlang:monotonic_time(nanosecond) - erlang:system_info(start_time),
            buoy_heap:set(Hr, 0, Ns band 16#FFFFFFFF),
            buoy_heap:set(Hr, 1, (Ns bsr 32) band 16#FFFFFFFF),
            undefined
        end)},
        {<<"hrtimeBuffer">>, Hr},
        {<<"cwd">>, F(<<"cwd">>, 0, fun(_, _) -> cwd() end)},
        {<<"chdir">>, F(<<"chdir">>, 0, fun(_, Args) -> chdir(A(1, Args)) end)},
        {<<"umask">>, F(<<"umask">>, 0, fun(_, Args) -> umask(A(1, Args)) end)},
        {<<"memoryUsage">>, F(<<"memoryUsage">>, 0, fun(_, Args) -> memory_usage(A(1, Args)) end)},
        {<<"rss">>, F(<<"rss">>, 0, fun(_, _) -> erlang:memory(total) end)},
        {<<"constrainedMemory">>, F(<<"constrainedMemory">>, 0, fun(_, _) -> 0 end)},
        {<<"availableMemory">>, F(<<"availableMemory">>, 0, fun(_, _) -> buoy_guard:limit(os:getenv("BUOY_MAX_MEMORY", "")) end)},
        {<<"cpuUsage">>, F(<<"cpuUsage">>, 0, fun(_, Args) -> cpu_usage(A(1, Args)) end)},
        {<<"threadCpuUsage">>, F(<<"threadCpuUsage">>, 0, fun(_, Args) -> cpu_usage(A(1, Args)) end)},
        {<<"resourceUsage">>, F(<<"resourceUsage">>, 0, fun(_, Args) -> resource_usage(A(1, Args)) end)},
        {<<"_getActiveRequests">>, F(<<"_getActiveRequests">>, 0, fun(_, _) -> buoy_heap:new_array([]) end)},
        {<<"_getActiveHandles">>, F(<<"_getActiveHandles">>, 0, fun(_, _) -> active_handles() end)},
        {<<"getActiveResourcesInfo">>, F(<<"getActiveResourcesInfo">>, 0, fun(_, _) -> active_resources() end)},
        {<<"_kill">>, F(<<"_kill">>, 0, fun(_, Args) -> kill(A(1, Args), A(2, Args)) end)},
        {<<"_rawDebug">>, F(<<"_rawDebug">>, 0, fun(_, Args) ->
            io:put_chars(buoy_ref:stderr(), [lists:join(" ", [buoy_ref_string:to_utf8(buoy_ref:to_string(X)) || X <- Args]), "\n"]),
            undefined
        end)},
        {<<"reallyExit">>, F(<<"reallyExit">>, 0, fun ?MODULE:really_exit/2)},
        %% Uptime of src/node_process_methods.cc counts from node_start_time,
        %% the nodeStart milestone of perf_hooks, not from the start of the VM.
        {<<"uptime">>, F(<<"uptime">>, 0, fun(_, _) ->
            Now = erlang:monotonic_time(nanosecond),
            (Now - persistent_term:get({buoy, node_start}, Now)) / 1.0e9
        end)},
        {<<"patchProcessObject">>, F(<<"patchProcessObject">>, 0, fun(_, Args) -> buoy_node_process:patch(A(1, Args)) end)},
        {<<"dlopen">>, F(<<"dlopen">>, 0, fun ?MODULE:dlopen/2)},
        {<<"setEmitWarningSync">>, F(<<"setEmitWarningSync">>, 0, fun(_, Args) ->
            buoy_node_loop:set_callback(emit_warning_sync, A(1, Args)),
            undefined
        end)},
        {<<"loadEnvFile">>, F(<<"loadEnvFile">>, 0, fun(_, Args) -> load_env_file(A(1, Args)) end)},
        {<<"resetStdioForTesting">>, F(<<"resetStdioForTesting">>, 0, fun(_, _) -> undefined end)},
        {<<"abort">>, F(<<"abort">>, 0, fun ?MODULE:abort/2)},
        {<<"causeSegfault">>, F(<<"causeSegfault">>, 0, fun ?MODULE:segfault/2)}
    ] ++ buoy_node:stubs(<<"process_methods">>, [<<"_debugProcess">>, <<"_debugEnd">>, <<"execve">>])).

%% Cwd of src/node_process_methods.cc, with its hint for a removed working
%% directory.
cwd() ->
    case file:get_cwd() of
        {ok, Dir} ->
            buoy_node:string(Dir);
        {error, Reason} ->
            Hint = case Reason of
                enoent -> <<", the current working directory was likely removed without changing the working directory">>;
                _ -> <<>>
            end,
            buoy_binding_fs:uv_error(Reason, <<"uv_cwd">>, undefined, undefined,
                                     fun(Message) -> [<<"process.cwd failed with error ">>, Message, Hint] end)
    end.

chdir(Dir) ->
    Path = buoy_ref_string:to_utf8(buoy_ref:to_string(Dir)),
    case file:set_cwd(Path) of
        ok ->
            undefined;
        {error, Reason} ->
            {ok, Cwd} = file:get_cwd(),
            buoy_binding_fs:uv_error(Reason, <<"chdir">>, unicode:characters_to_binary(Cwd), Path)
    end.

%% umask(mask): the VM cannot set the umask of its OS process, so the realm
%% keeps the value that the program set and returns the previous one.
umask(Mask) ->
    Old = case erlang:get(?UMASK) of
        undefined -> 8#022;
        M -> M
    end,
    case Mask of
        undefined -> ok;
        _ -> erlang:put(?UMASK, trunc(buoy_ref:to_number(Mask)) band 8#777)
    end,
    Old.

memory_usage(Array) ->
    Total = erlang:memory(total),
    Processes = erlang:memory(processes),
    Binary = erlang:memory(binary),
    [buoy_heap:set(Array, I, V) || {I, V} <- lists:enumerate(0, [Total, Processes, erlang:memory(processes_used), Binary, Binary])],
    undefined.

cpu_usage(Array) ->
    {Ms, _} = erlang:statistics(runtime),
    buoy_heap:set(Array, 0, Ms * 1000),
    buoy_heap:set(Array, 1, 0),
    undefined.

resource_usage(Array) ->
    {Ms, _} = erlang:statistics(runtime),
    buoy_heap:set(Array, 0, Ms * 1000),
    buoy_heap:set(Array, 2, erlang:memory(total) div 1024),
    undefined.

%% _kill(pid, signal): 0, EINVAL for a signal that the OS lacks, else ESRCH.
kill(Pid, Signal) ->
    case trunc(buoy_ref:to_number(Signal)) of
        Number when Number < 0; Number > 31 -> -22;
        Number ->
            Target = trunc(buoy_ref:to_number(Pid)),
            case Target =:= list_to_integer(os:getpid()) andalso buoy_binding_signal_wrap:emulate(Number) of
                true -> 0;
                false -> kill_os(Target, Number)
            end
    end.

kill_os(Target, Number) ->
    Command = io_lib:format("kill -~w ~w 2>/dev/null; echo $?", [Number, Target]),
    case string:trim(os:cmd(lists:flatten(Command))) of
        "0" -> 0;
        _ -> -3
    end.

load_env_file(Path) ->
    File = case Path of
        undefined -> <<".env">>;
        _ -> buoy_ref_string:to_utf8(buoy_ref:to_string(Path))
    end,
    case file:read_file(File) of
        {ok, Text} ->
            Parse = buoy_heap:get(buoy_node:binding(<<"util">>), <<"parseEnv">>),
            Vars = buoy_heap:call(Parse, undefined, [buoy_ref_string:from_utf8(Text)]),
            lists:foreach(fun(Key) ->
                Name = unicode:characters_to_list(buoy_ref_string:to_utf8(Key)),
                case os:getenv(Name) of
                    false -> os:putenv(Name, unicode:characters_to_list(buoy_ref_string:to_utf8(buoy_heap:get(Vars, Key))));
                    _ -> ok
                end
            end, buoy_heap:enumerable_keys(Vars)),
            undefined;
        {error, Reason} ->
            buoy_binding_fs:uv_error(Reason, <<"open">>, File)
    end.

%% reallyExit(code): ends the program after process.exit ran its handlers.
-spec really_exit(term(), list()) -> no_return().
really_exit(_This, Args) -> buoy_node_loop:really_exit(buoy_ref:to_number(buoy_node:arg(1, Args))).

-spec abort(term(), list()) -> no_return().
abort(_This, _Args) -> erlang:halt(134).

-spec segfault(term(), list()) -> no_return().
segfault(_This, _Args) -> erlang:halt(139).

%% process.dlopen: Buoy loads no native addon (goal.md, requirement 2).
-spec dlopen(term(), list()) -> no_return().
dlopen(_This, _Args) ->
    buoy_node:throw_code('Error', <<"ERR_DLOPEN_FAILED">>,
                         <<"Buoy cannot load native addons (.node files); use the WebAssembly or pure-JavaScript build of the package">>).

%% GetActiveHandles: the owner of each ref'd handle wrap (GetOwner), or the
%% handle itself.
active_handles() ->
    Owner = buoy_heap:get(buoy_node:binding(<<"symbols">>), <<"owner_symbol">>),
    buoy_heap:new_array([case buoy_heap:get(Handle, Owner) of
                             undefined -> Handle;
                             Object -> Object
                         end || {Handle, _} <- buoy_node_loop:handle_wraps()]).

%% GetActiveResourcesInfo: the name of each ref'd handle wrap, a Timeout for
%% each active timer (timeoutInfo[0] of lib/internal/timers), and an
%% Immediate for each ref'd immediate (immediateInfo[kRefCount]).
%% shortcut: the requests of the bindings are not named yet.
active_resources() ->
    Timers = buoy_node:binding(<<"timers">>),
    Timeouts = buoy_heap:get(buoy_heap:get(Timers, <<"timeoutInfo">>), 0),
    Immediates = buoy_heap:get(buoy_heap:get(Timers, <<"immediateInfo">>), 1),
    buoy_heap:new_array([Name || {_, Name} <- buoy_node_loop:handle_wraps()] ++
                        lists:duplicate(max(0, Timeouts), <<"Timeout">>) ++ lists:duplicate(max(0, Immediates), <<"Immediate">>)).
