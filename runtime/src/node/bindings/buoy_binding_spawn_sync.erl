%% internalBinding('spawn_sync') (src/spawn_sync.cc): spawn(options) runs a
%% child process to its end and returns {pid, status, signal, output, error},
%% as SyncProcessRunner does. The child starts through /bin/sh, which wires
%% its stdio and then execs `buoy --buoy-exec` (crates/buoy-cli/src/spawn.rs),
%% which sets the environment, argv[0], the ids, and the session exactly and
%% execs the file: Erlang's port reads the child's stdout from fd 4
%% (nouse_stdio), stderr goes to a temporary file, and the input of stdin
%% comes from one.
-module(buoy_binding_spawn_sync).

-export([binding/0, signal_name/1, executable/3, split_pair/1, temp_base/0, quote/1, exec/4]).

-spec binding() -> term().
binding() ->
    buoy_node:object([{<<"spawn">>, buoy_node:fn(<<"spawn">>, 0, fun(_, Args) -> spawn_sync(buoy_node:arg(1, Args)) end)}]).

get(O, Key) -> buoy_heap:get(O, Key).

text(V) -> unicode:characters_to_list(buoy_ref_string:to_utf8(buoy_ref:to_string(V))).

spawn_sync(Options) ->
    File = text(get(Options, <<"file">>)),
    Env = [split_pair(text(P)) || P <- items(get(Options, <<"envPairs">>))],
    Cwd = case get(Options, <<"cwd">>) of
        V when V =:= undefined; V =:= null; V =:= <<>> -> element(2, file:get_cwd());
        V -> text(V)
    end,
    Stdio = [stdio(S) || S <- items(get(Options, <<"stdio">>))],
    case filelib:is_dir(Cwd) andalso exec(File, Cwd, Env, Options) of
        {ok, Exec} -> run(Exec, Cwd, Stdio, Options);
        {error, Errno} -> result(#{error => Errno, pid => 0, status => null, signal => null, output => null});
        false -> result(#{error => -2, pid => 0, status => null, signal => null, output => null})
    end.

%% The program and the arguments that start File as uv_spawn would, in the
%% order of its child: the ids (setgid and setuid, which only root may change
%% to another id, else EPERM), then the search of execvp (ENOENT). The
%% `buoy --buoy-exec` step gives the child the exact envPairs and argv[0].
-spec exec(string(), string(), [{string(), string()}], term()) -> {ok, {string(), [string()]}} | {error, integer()}.
exec(File, Cwd, Env, Options) ->
    Ids = [{Name, trunc(buoy_ref:to_number(get(Options, Key)))}
           || {Name, Key} <- [{"gid", <<"gid">>}, {"uid", <<"uid">>}], is_number(get(Options, Key))],
    Denied = [Name || {Name, Id} <- Ids, not may_take(Name, Id)],
    case {Denied, executable(File, Cwd, Env)} of
        {[_ | _], _} ->
            {error, -1};
        {[], error} ->
            {error, -2};
        {[], {ok, Path}} ->
            [Argv0 | Args] = case [text(A) || A <- items(get(Options, <<"args">>))] of
                [] -> [File];
                Given -> Given
            end,
            Pairs = [text(P) || P <- items(get(Options, <<"envPairs">>))],
            Flags = case [<<"detached">> || get(Options, <<"detached">>) =:= true]
                         ++ [iolist_to_binary([Name, $=, integer_to_list(Id)]) || {Name, Id} <- Ids] of
                [] -> "-";
                Set -> binary_to_list(iolist_to_binary(lists:join(",", Set)))
            end,
            Buoy = unicode:characters_to_list(buoy_ref_string:to_utf8(buoy_node_process:exec_path())),
            {ok, {Buoy, ["--buoy-exec", Flags, Argv0, Path, integer_to_list(length(Pairs)) | Pairs ++ Args]}}
    end.

%% Whether setuid or setgid to Id succeeds: root takes any id, another user
%% only its own.
may_take(Name, Id) ->
    Own = fun(Flag) -> list_to_integer(string:trim(os:cmd("id " ++ Flag))) end,
    Own("-u") =:= 0 orelse Id =:= Own(case Name of "uid" -> "-u"; "gid" -> "-g" end).

items(undefined) -> [];
items(null) -> [];
items(A) -> buoy_heap:array_items(A).

split_pair(Pair) ->
    case string:split(Pair, "=") of
        [K, V] -> {K, V};
        [K] -> {K, ""}
    end.

%% One stdio entry: pipe (with its input), ignore, inherit, or fd.
stdio(S) ->
    case buoy_ref_string:to_utf8(buoy_ref:to_string(get(S, <<"type">>))) of
        <<"pipe">> ->
            case get(S, <<"input">>) of
                Input when Input =:= undefined; Input =:= null -> pipe;
                Input -> {pipe, buoy_node_encoding:view_bytes(Input)}
            end;
        <<"overlapped">> -> pipe;
        <<"inherit">> -> inherit;
        <<"fd">> ->
            case get(S, <<"fd">>) of
                Fd when Fd =:= 0; Fd =:= 1; Fd =:= 2 -> {fd, Fd};
                Fd -> buoy_binding_fs:inherited_file(Fd)
            end;
        _ -> ignore
    end.

%% execvp's search: a file with a slash names itself, else the first
%% executable file of that name on the PATH of the child.
executable(File, Cwd, Env) ->
    case lists:member($/, File) of
        true ->
            Path = filename:absname(File, Cwd),
            case is_executable(Path) of true -> {ok, Path}; false -> error end;
        false ->
            Dirs = string:split(proplists:get_value("PATH", Env, os:getenv("PATH", "/usr/bin:/bin")), ":", all),
            case [P || D <- Dirs, P <- [filename:join(filename:absname(D, Cwd), File)], is_executable(P)] of
                [Path | _] -> {ok, Path};
                [] -> error
            end
    end.

is_executable(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> element(3, Info) =:= regular andalso element(8, Info) band 8#111 =/= 0;
        _ -> false
    end.

run({Program, ProgramArgs}, Cwd, Stdio0, Options) ->
    Stdio = lists:sublist(Stdio0 ++ [ignore, ignore, ignore], 3),
    Temp = temp_base(),
    InFile = Temp ++ ".in",
    ErrFile = Temp ++ ".err",
    Redirects = redirects(Stdio, InFile, ErrFile),
    Script = "exec \"$0\" \"$@\"" ++ Redirects ++ " 3<&- 4>&-",
    Port = open_port({spawn_executable, "/bin/sh"},
                     [nouse_stdio, binary, exit_status, {cd, Cwd}, {args, ["-c", Script, Program | ProgramArgs]}]),
    OsPid = case erlang:port_info(Port, os_pid) of {os_pid, P} -> P; _ -> 0 end,
    Timeout = case buoy_ref:to_number(get(Options, <<"timeout">>)) of
        T when is_integer(T), T > 0 -> T;
        T when is_float(T), T > 0 -> trunc(T);
        _ -> infinity
    end,
    MaxBuffer = case buoy_ref:to_number(get(Options, <<"maxBuffer">>)) of
        M when is_number(M), M >= 0 -> M;
        _ -> infinity
    end,
    KillSignal = case get(Options, <<"killSignal">>) of
        K when is_integer(K) -> K;
        _ -> 15
    end,
    Deadline = case Timeout of infinity -> infinity; _ -> erlang:monotonic_time(millisecond) + Timeout end,
    {Status, Stdout, Error} = collect(Port, OsPid, Deadline, MaxBuffer, KillSignal, [], 0, none),
    Stderr = case file:read_file(ErrFile) of {ok, B} -> B; _ -> <<>> end,
    _ = file:delete(InFile),
    _ = file:delete(ErrFile),
    {ExitStatus, Signal} = case Status of
        S when S > 128 -> {null, signal_name(S - 128)};
        S -> {S, null}
    end,
    Output = buoy_heap:new_array([output(I, Stdio, Stdout, Stderr) || I <- lists:seq(0, max(3, length(Stdio0)) - 1)]),
    result(maps:merge(#{pid => OsPid, status => ExitStatus, signal => Signal, output => Output},
                      case Error of none -> #{}; _ -> #{error => Error} end)).

redirects([In, Out, Err], InFile, ErrFile) ->
    InRedirect = case In of
        {pipe, Bytes} -> ok = file:write_file(InFile, Bytes), " <" ++ quote(InFile);
        inherit -> "";
        {fd, 0} -> "";
        {file, InPath} -> " <" ++ quote(InPath);
        _ -> " </dev/null"
    end,
    OutRedirect = case Out of
        pipe -> " >&4";
        {pipe, _} -> " >&4";
        inherit -> "";
        {fd, 1} -> "";
        {fd, 2} -> " >&2";
        {file, OutPath} -> " >>" ++ quote(OutPath);
        _ -> " >/dev/null"
    end,
    ErrRedirect = case Err of
        pipe -> " 2>" ++ quote(ErrFile);
        {pipe, _} -> " 2>" ++ quote(ErrFile);
        inherit -> "";
        {fd, 2} -> "";
        {fd, 1} when Out =:= pipe -> " 2>&4";
        {fd, 1} -> " 2>&1";
        {file, ErrPath} -> " 2>>" ++ quote(ErrPath);
        _ -> " 2>/dev/null"
    end,
    InRedirect ++ OutRedirect ++ ErrRedirect.

quote(Path) -> "'" ++ lists:flatten(string:replace(Path, "'", "'\\''", all)) ++ "'".

temp_base() ->
    Dir = case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        D -> D
    end,
    filename:join(Dir, "buoy-spawn-" ++ os:getpid() ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))).

collect(Port, OsPid, Deadline, MaxBuffer, KillSignal, Acc, Size, Error) ->
    Wait = case Deadline of
        infinity -> infinity;
        _ -> max(0, Deadline - erlang:monotonic_time(millisecond))
    end,
    receive
        {Port, {data, Data}} ->
            NewSize = Size + byte_size(Data),
            case MaxBuffer =/= infinity andalso NewSize > MaxBuffer andalso Error =:= none of
                true ->
                    kill(OsPid, KillSignal),
                    collect(Port, OsPid, infinity, MaxBuffer, KillSignal, [Acc, Data], NewSize, uv(<<"ENOBUFS">>));
                false ->
                    collect(Port, OsPid, Deadline, MaxBuffer, KillSignal, [Acc, Data], NewSize, Error)
            end;
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(Acc), Error}
    after Wait ->
        kill(OsPid, KillSignal),
        collect(Port, OsPid, infinity, MaxBuffer, KillSignal, Acc, Size, uv(<<"ETIMEDOUT">>))
    end.

%% The code of a libuv error of this OS, such as -60 for ETIMEDOUT on darwin.
uv(Name) ->
    hd([Code || {Code, N, _} <- buoy_binding_uv:errors(), N =:= Name]).

kill(0, _Signal) -> ok;
kill(OsPid, Signal) ->
    _ = os:cmd("kill -" ++ integer_to_list(Signal) ++ " " ++ integer_to_list(OsPid)),
    ok.

output(0, _Stdio, _Stdout, _Stderr) -> null;
output(1, [_, Out, _], Stdout, _Stderr) when Out =:= pipe -> buoy_node_encoding:new_buffer(Stdout);
output(2, [_, _, Err], _Stdout, Stderr) when Err =:= pipe -> buoy_node_encoding:new_buffer(Stderr);
output(_, _, _, _) -> null.

result(Fields) ->
    buoy_node:object([{atom_to_binary(K), V} || {K, V} <- maps:to_list(Fields)]).

%% The name of signal N, from os.constants.signals.
-spec signal_name(integer()) -> term().
signal_name(N) ->
    Signals = buoy_heap:get(buoy_heap:get(buoy_node:binding(<<"constants">>), <<"os">>), <<"signals">>),
    case [K || K <- buoy_heap:enumerable_keys(Signals), buoy_heap:get(Signals, K) =:= N] of
        [Name | _] -> Name;
        [] -> null
    end.
