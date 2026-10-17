%% internalBinding('process_methods') (src/node_process_methods.cc): the
%% methods of the process object that need the OS or the VM.
-module(bouy_binding_process_methods).

-include("bouy_ref.hrl").

-export([binding/0, really_exit/2, abort/2, segfault/2, dlopen/2]).

-define(UMASK, '$bouy_node_umask').

-spec binding() -> term().
binding() ->
    Hr = bouy_node:typed_array(<<"Uint32Array">>, 3),
    F = fun bouy_node:fn/3,
    A = fun bouy_node:arg/2,
    bouy_node:object([
        {<<"hrtime">>, F(<<"hrtime">>, 0, fun(_, _) ->
            Ns = erlang:monotonic_time(nanosecond) - erlang:system_info(start_time),
            Sec = Ns div 1000000000,
            bouy_heap:set(Hr, 0, Sec bsr 32),
            bouy_heap:set(Hr, 1, Sec band 16#FFFFFFFF),
            bouy_heap:set(Hr, 2, Ns rem 1000000000),
            undefined
        end)},
        {<<"hrtimeBigInt">>, F(<<"hrtimeBigInt">>, 0, fun(_, _) ->
            Ns = erlang:monotonic_time(nanosecond) - erlang:system_info(start_time),
            bouy_heap:set(Hr, 0, Ns band 16#FFFFFFFF),
            bouy_heap:set(Hr, 1, (Ns bsr 32) band 16#FFFFFFFF),
            undefined
        end)},
        {<<"hrtimeBuffer">>, Hr},
        {<<"cwd">>, F(<<"cwd">>, 0, fun(_, _) ->
            {ok, Dir} = file:get_cwd(),
            bouy_node:string(Dir)
        end)},
        {<<"chdir">>, F(<<"chdir">>, 1, fun(_, Args) -> chdir(A(1, Args)) end)},
        {<<"umask">>, F(<<"umask">>, 1, fun(_, Args) -> umask(A(1, Args)) end)},
        {<<"memoryUsage">>, F(<<"memoryUsage">>, 1, fun(_, Args) -> memory_usage(A(1, Args)) end)},
        {<<"rss">>, F(<<"rss">>, 0, fun(_, _) -> erlang:memory(total) end)},
        {<<"constrainedMemory">>, F(<<"constrainedMemory">>, 0, fun(_, _) -> 0 end)},
        {<<"availableMemory">>, F(<<"availableMemory">>, 0, fun(_, _) -> bouy_guard:limit(os:getenv("BOUY_MAX_MEMORY", "")) end)},
        {<<"cpuUsage">>, F(<<"cpuUsage">>, 1, fun(_, Args) -> cpu_usage(A(1, Args)) end)},
        {<<"threadCpuUsage">>, F(<<"threadCpuUsage">>, 1, fun(_, Args) -> cpu_usage(A(1, Args)) end)},
        {<<"resourceUsage">>, F(<<"resourceUsage">>, 1, fun(_, Args) -> resource_usage(A(1, Args)) end)},
        {<<"_getActiveRequests">>, F(<<"_getActiveRequests">>, 0, fun(_, _) -> bouy_heap:new_array([]) end)},
        {<<"_getActiveHandles">>, F(<<"_getActiveHandles">>, 0, fun(_, _) -> bouy_heap:new_array([]) end)},
        {<<"getActiveResourcesInfo">>, F(<<"getActiveResourcesInfo">>, 0, fun(_, _) -> bouy_heap:new_array([]) end)},
        {<<"_kill">>, F(<<"_kill">>, 2, fun(_, Args) -> kill(A(1, Args), A(2, Args)) end)},
        {<<"_rawDebug">>, F(<<"_rawDebug">>, 0, fun(_, Args) ->
            io:put_chars(bouy_ref:stderr(), [lists:join(" ", [bouy_ref_string:to_utf8(bouy_ref:to_string(X)) || X <- Args]), "\n"]),
            undefined
        end)},
        {<<"reallyExit">>, F(<<"reallyExit">>, 1, fun ?MODULE:really_exit/2)},
        {<<"uptime">>, F(<<"uptime">>, 0, fun(_, _) ->
            {Ms, _} = erlang:statistics(wall_clock),
            Ms / 1000
        end)},
        {<<"patchProcessObject">>, F(<<"patchProcessObject">>, 1, fun(_, Args) -> bouy_node_process:patch(A(1, Args)) end)},
        {<<"dlopen">>, F(<<"dlopen">>, 2, fun ?MODULE:dlopen/2)},
        {<<"setEmitWarningSync">>, F(<<"setEmitWarningSync">>, 1, fun(_, Args) ->
            bouy_node_loop:set_callback(emit_warning_sync, A(1, Args)),
            undefined
        end)},
        {<<"loadEnvFile">>, F(<<"loadEnvFile">>, 1, fun(_, Args) -> load_env_file(A(1, Args)) end)},
        {<<"resetStdioForTesting">>, F(<<"resetStdioForTesting">>, 0, fun(_, _) -> undefined end)},
        {<<"abort">>, F(<<"abort">>, 0, fun ?MODULE:abort/2)},
        {<<"causeSegfault">>, F(<<"causeSegfault">>, 0, fun ?MODULE:segfault/2)}
    ] ++ bouy_node:stubs(<<"process_methods">>, [<<"_debugProcess">>, <<"_debugEnd">>, <<"execve">>])).

chdir(Dir) ->
    Path = bouy_ref_string:to_utf8(bouy_ref:to_string(Dir)),
    case file:set_cwd(Path) of
        ok ->
            undefined;
        {error, Reason} ->
            {Code, Text} = case Reason of
                enoent -> {<<"ENOENT">>, <<"no such file or directory">>};
                enotdir -> {<<"ENOTDIR">>, <<"not a directory">>};
                eacces -> {<<"EACCES">>, <<"permission denied">>};
                _ -> {string:uppercase(atom_to_binary(Reason)), atom_to_binary(Reason)}
            end,
            {ok, Cwd} = file:get_cwd(),
            Message = iolist_to_binary([Code, <<": process.chdir failed, ">>, Text, <<", chdir '">>, Cwd, <<"' -> '">>, Path, <<"'">>]),
            E = bouy_heap:error_object('Error', bouy_ref_string:from_utf8(Message), bouy_ref_string:from_utf8(<<"Error: ", Message/binary>>)),
            [bouy_heap:set(E, K, V) || {K, V} <- [{<<"errno">>, -2}, {<<"code">>, Code}, {<<"syscall">>, <<"chdir">>},
                                                   {<<"path">>, bouy_ref_string:from_utf8(unicode:characters_to_binary(Cwd))},
                                                   {<<"dest">>, bouy_ref_string:from_utf8(Path)}]],
            erlang:error({'$throw', E})
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
        _ -> erlang:put(?UMASK, trunc(bouy_ref:to_number(Mask)) band 8#777)
    end,
    Old.

memory_usage(Array) ->
    Total = erlang:memory(total),
    Processes = erlang:memory(processes),
    Binary = erlang:memory(binary),
    [bouy_heap:set(Array, I, V) || {I, V} <- lists:enumerate(0, [Total, Processes, erlang:memory(processes_used), Binary, Binary])],
    undefined.

cpu_usage(Array) ->
    {Ms, _} = erlang:statistics(runtime),
    bouy_heap:set(Array, 0, Ms * 1000),
    bouy_heap:set(Array, 1, 0),
    undefined.

resource_usage(Array) ->
    {Ms, _} = erlang:statistics(runtime),
    bouy_heap:set(Array, 0, Ms * 1000),
    bouy_heap:set(Array, 2, erlang:memory(total) div 1024),
    undefined.

kill(Pid, Signal) ->
    Command = io_lib:format("kill -~w ~w 2>/dev/null; echo $?", [trunc(bouy_ref:to_number(Signal)), trunc(bouy_ref:to_number(Pid))]),
    case string:trim(os:cmd(lists:flatten(Command))) of
        "0" -> 0;
        _ -> -3
    end.

load_env_file(Path) ->
    File = case Path of
        undefined -> <<".env">>;
        _ -> bouy_ref_string:to_utf8(bouy_ref:to_string(Path))
    end,
    case file:read_file(File) of
        {ok, Text} ->
            Parse = bouy_heap:get(bouy_node:binding(<<"util">>), <<"parseEnv">>),
            Vars = bouy_heap:call(Parse, undefined, [bouy_ref_string:from_utf8(Text)]),
            lists:foreach(fun(Key) ->
                Name = unicode:characters_to_list(bouy_ref_string:to_utf8(Key)),
                case os:getenv(Name) of
                    false -> os:putenv(Name, unicode:characters_to_list(bouy_ref_string:to_utf8(bouy_heap:get(Vars, Key))));
                    _ -> ok
                end
            end, bouy_heap:enumerable_keys(Vars)),
            undefined;
        {error, _} ->
            bouy_node:throw_code('Error', <<"ENOENT">>, bouy_ref_string:from_utf8(<<"ENOENT: no such file or directory, open '", File/binary, "'">>))
    end.

%% reallyExit(code): ends the program after process.exit ran its handlers.
-spec really_exit(term(), list()) -> no_return().
really_exit(_This, Args) -> bouy_node_loop:really_exit(bouy_ref:to_number(bouy_node:arg(1, Args))).

-spec abort(term(), list()) -> no_return().
abort(_This, _Args) -> erlang:halt(134).

-spec segfault(term(), list()) -> no_return().
segfault(_This, _Args) -> erlang:halt(139).

%% process.dlopen: Bouy loads no native addon (goal.md, requirement 2).
-spec dlopen(term(), list()) -> no_return().
dlopen(_This, _Args) ->
    bouy_node:throw_code('Error', <<"ERR_DLOPEN_FAILED">>,
                         <<"Bouy cannot load native addons (.node files); use the WebAssembly or pure-JavaScript build of the package">>).
