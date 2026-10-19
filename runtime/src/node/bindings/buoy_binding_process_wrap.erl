%% internalBinding('process_wrap') (src/process_wrap.cc): Process, the handle
%% of a child process that child_process.spawn starts. A manager process
%% owns the child: bash connects a loopback socket for each piped stdin,
%% stdout, and stderr (/dev/tcp), wires the stdio, and execs the file through
%% `buoy --buoy-exec` (buoy_binding_spawn_sync:exec/4). The port only
%% reports the exit: OTP holds the exit status until the port's pipe ends,
%% and a grandchild that keeps a stdio pipe, as /bin/sh -c leaves one behind
%% on Linux, would hold the exit of the child. A socket never
%% blocks the child when the VM is gone, and it half-closes, so the end of
%% stdin reaches the child while its output still flows. Each stdio pipe is
%% a Pipe of pipe_wrap that buoy_node_stream drives; the IPC channel of fork
%% is buoy_node_ipc's local socket.
-module(buoy_binding_process_wrap).

-export([binding/0]).

-define(STATE, {'#', ?MODULE, <<"state">>}).

-spec binding() -> term().
binding() ->
    Process = buoy_node:constructor(<<"Process">>, 0, fun(_, _) -> undefined end),
    Proto = buoy_heap:get(Process, <<"prototype">>),
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    Methods = [{<<"spawn">>, fun(This, Args) -> spawn_child(This, A(1, Args)) end},
               {<<"kill">>, fun(This, Args) -> kill(This, A(1, Args)) end},
               {<<"close">>, fun(This, Args) -> close(This, A(1, Args)) end},
               {<<"ref">>, fun(This, _) -> set_ref(This, true) end},
               {<<"unref">>, fun(This, _) -> set_ref(This, false) end},
               {<<"hasRef">>, fun(This, _) -> maps:get(refed, state(This), false) end},
               {<<"getAsyncId">>, fun(_, _) -> erlang:unique_integer([positive]) end}],
    [buoy_heap:define(Proto, Name, #{value => F(Name, 0, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    buoy_node:object([{<<"Process">>, Process}]).

state(This) ->
    case buoy_heap:private_find(This, ?STATE) of
        {ok, S} -> S;
        error -> #{refed => false, exited => true}
    end.

save(This, S) -> buoy_heap:private_put(This, ?STATE, S).

get(O, Key) -> buoy_heap:get(O, Key).

text(V) -> unicode:characters_to_list(buoy_ref_string:to_utf8(buoy_ref:to_string(V))).

items(undefined) -> [];
items(null) -> [];
items(A) -> buoy_heap:array_items(A).

%% spawn(options): 0, or the negative errno of a spawn that fails.
spawn_child(This, Options) ->
    File = text(get(Options, <<"file">>)),
    Env = [buoy_binding_spawn_sync:split_pair(text(P)) || P <- items(get(Options, <<"envPairs">>))],
    Cwd = case get(Options, <<"cwd">>) of
        V when V =:= undefined; V =:= null; V =:= <<>> -> element(2, file:get_cwd());
        V -> text(V)
    end,
    Stdio = [stdio(S) || S <- items(get(Options, <<"stdio">>))] ++ lists:duplicate(3, ignore),
    case filelib:is_dir(Cwd) andalso buoy_binding_spawn_sync:exec(File, Cwd, Env, Options) of
        {ok, Exec} -> start(This, Exec, Cwd, Stdio);
        {error, -2} -> unstarted(Stdio);
        {error, Errno} -> Errno;
        false -> unstarted(Stdio)
    end.

%% uv_spawn opens the parent's end of each stdio pipe even when the child
%% fails to start, so each pipe reads its end at once and a write fails with
%% EPIPE: the streams close, and nothing keeps the loop alive.
unstarted(Stdio) ->
    Realm = self(),
    [begin
         buoy_node_stream:attach(Handle, spawn(fun() -> closed_pipe(monitor(process, Realm)) end)),
         buoy_node_loop:defer(fun() -> buoy_node_stream:deliver(Handle, eof) end)
     end || {Kind, Handle} <- Stdio, Kind =:= pipe orelse Kind =:= ipc],
    -2.

closed_pipe(Monitor) ->
    receive
        {write, _, From, Ref} -> report(From, Ref, {error, epipe}), closed_pipe(Monitor);
        close -> ok;
        {'DOWN', Monitor, _, _, _} -> ok;
        _ -> closed_pipe(Monitor)
    end.

stdio(S) ->
    case buoy_ref_string:to_utf8(buoy_ref:to_string(get(S, <<"type">>))) of
        <<"pipe">> -> pipe(S);
        <<"overlapped">> -> {pipe, get(S, <<"handle">>)};
        <<"wrap">> -> {wrap, get(S, <<"handle">>)};
        <<"inherit">> -> inherit;
        <<"fd">> ->
            case get(S, <<"fd">>) of
                Fd when Fd =:= 0; Fd =:= 1; Fd =:= 2 -> {fd, Fd};
                Fd -> buoy_binding_fs:inherited_file(Fd)
            end;
        _ -> ignore
    end.

%% The IPC channel of fork, a pipe that getValidStdio marks ipc, reads and
%% writes, at whatever index it has.
pipe(S) ->
    case get(S, <<"ipc">>) of
        true -> {ipc, get(S, <<"handle">>)};
        _ -> {pipe, get(S, <<"handle">>)}
    end.

start(This, {Program, ProgramArgs}, Cwd, [In, Out, Err | More]) ->
    ok = start_inet_db(),
    {ok, Listen} = gen_tcp:listen(0, [binary, {ip, loopback}, {active, false}, {reuseaddr, true}, {backlog, 8}]),
    {ok, ListenPort} = inet:port(Listen),
    %% A pipe past stderr is a socket at its index in the child that reads
    %% and writes; it connects at fd 10 + index first. The IPC channel of
    %% fork, at any index (NODE_CHANNEL_FD), is a local socket that the exec
    %% step connects (buoy_node_ipc), so handles can pass over it.
    Realm0 = self(),
    Stdio = lists:enumerate(0, [In, Out, Err | More]),
    Extras = [{Index, Handle, spawn(fun() -> ipc_channel(Realm0, Handle) end)}
              || {Index, {pipe, Handle}} <- Stdio, Index >= 3],
    Ipcs = [{Index, ipc_listen(Handle)} || {Index, {ipc, Handle}} <- Stdio],
    Piped = [Name || {Name, {Kind, _}} <- [{stdin, In}, {stdout, Out}, {stderr, Err}], Kind =:= pipe orelse Kind =:= wrap]
            ++ [{extra, I} || {I, _, _} <- Extras],
    Tcp = "<>/dev/tcp/127.0.0.1/" ++ integer_to_list(ListenPort) ++ " || exit 127; ",
    %% Each piped stream connects in this order, so the accepts know which is which.
    Connect = lists:append(["exec " ++ integer_to_list(fd_of(Name)) ++ Tcp || Name <- Piped]),
    Redirects = redirect(0, In) ++ redirect(1, Out) ++ redirect(2, Err),
    Moves = lists:append([" " ++ integer_to_list(I) ++ ">&" ++ integer_to_list(10 + I) ++ " " ++ integer_to_list(10 + I) ++ ">&-"
                          || {I, _, _} <- Extras])
            ++ lists:append([" " ++ integer_to_list(I) ++ "<&-" || {I, _} <- Ipcs]),
    ExecArgs = exec_options(ProgramArgs, ["unix=" ++ integer_to_list(I) ++ ":" ++ Path || {I, {_, Path}} <- Ipcs]),
    IpcChannels = [Channel || {_, {Channel, _}} <- Ipcs],
    Script = Connect ++ "exec \"$0\" \"$@\"" ++ Redirects ++ " 3<&- 4>&- 5<&- 6<&- 7<&-" ++ Moves,
    Realm = self(),
    Handles = #{stdin => pipe_handle(In), stdout => output_handle(Out), stderr => output_handle(Err)},
    {Manager, Monitor} = spawn_monitor(fun() ->
        Port = open_port({spawn_executable, "/bin/bash"},
                         [nouse_stdio, binary, exit_status, {cd, Cwd}, {args, ["-c", Script, Program | ExecArgs]}]),
        OsPid = case erlang:port_info(Port, os_pid) of {os_pid, P} -> P; _ -> 0 end,
        Realm ! {self(), started, OsPid},
        Sockets = accept(Listen, Piped, Port),
        gen_tcp:close(Listen),
        [give_socket(maps:get({extra, I}, Sockets, none), Channel) || {I, _, Channel} <- Extras],
        Writer = case maps:get(stdin, Sockets, none) of
            none -> none;
            Stdin -> spawn_link(fun() -> write_loop(Stdin) end)
        end,
        %% A piped stream whose child ended before it connected ends at once.
        [case maps:get(Name, Sockets, none) of
             none -> deliver(Realm, maps:get(Name, Handles), eof);
             Socket -> inet:setopts(Socket, [{active, true}])
         end || Name <- [stdout, stderr]],
        Waiting = [exit | [Name || Name <- [stdout, stderr], maps:is_key(Name, Sockets)]],
        manage(#{port => Port, realm => Realm, this => This, handles => Handles, writer => Writer,
                 stdout => maps:get(stdout, Sockets, none), stderr => maps:get(stderr, Sockets, none),
                 waiting => Waiting, ipc => IpcChannels})
    end),
    ok = gen_tcp:controlling_process(Listen, Manager),
    receive
        {Manager, started, OsPid} ->
            erlang:demonitor(Monitor, [flush]),
            started(This, Manager, OsPid, Handles, Extras, In);
        {'DOWN', Monitor, process, Manager, _} ->
            [exit(Channel, kill) || {_, _, Channel} <- Extras],
            [buoy_node_ipc:abandon(Channel) || Channel <- IpcChannels],
            unstarted([In, Out, Err | More])
    end.

%% The CLI boots the kernel with `-mode minimal`, which leaves out inet_db,
%% the configuration that gen_tcp reads; it joins the kernel supervisor here,
%% as buoy_ai_openai starts it for httpc.
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

%% The parent's end of an IPC channel, and the path that the child connects.
ipc_listen(Handle) ->
    {ok, Channel, Path} = buoy_node_ipc:listen(Handle),
    {Channel, Path}.

%% The options of `buoy --buoy-exec` with the local sockets to connect.
exec_options(Args, []) -> Args;
exec_options(["--buoy-exec", "-" | Rest], Unix) -> ["--buoy-exec", lists:flatten(lists:join(",", Unix)) | Rest];
exec_options(["--buoy-exec", Flags | Rest], Unix) -> ["--buoy-exec", lists:flatten(lists:join(",", [Flags | Unix])) | Rest].

fd_of(stdin) -> 5;
fd_of(stderr) -> 6;
fd_of(stdout) -> 7;
fd_of({extra, Index}) -> 10 + Index.

%% The channel of an extra pipe, such as fork's IPC channel: a process that
%% reads and writes the socket for the handle once the manager hands it over;
%% writes wait in its mailbox until then.
ipc_channel(Realm, Handle) ->
    receive
        {socket, none} ->
            deliver(Realm, Handle, eof);
        {socket, Socket} ->
            ok = inet:setopts(Socket, [{active, true}]),
            socket_loop(Socket, Realm, Handle)
    end.

give_socket(none, Channel) ->
    Channel ! {socket, none};
give_socket(Socket, Channel) ->
    ok = gen_tcp:controlling_process(Socket, Channel),
    Channel ! {socket, Socket}.

socket_loop(Socket, Realm, Handle) ->
    receive
        {tcp, Socket, Data} ->
            deliver(Realm, Handle, Data),
            socket_loop(Socket, Realm, Handle);
        {tcp_closed, Socket} ->
            deliver(Realm, Handle, eof),
            Self = self(),
            buoy_node_stream:call(Realm, fun() -> erlang:erase({?MODULE, root, Self}) end);
        {write, Bytes, From, Ref} ->
            report(From, Ref, gen_tcp:send(Socket, Bytes)),
            socket_loop(Socket, Realm, Handle);
        shutdown ->
            _ = gen_tcp:shutdown(Socket, write),
            socket_loop(Socket, Realm, Handle);
        close ->
            gen_tcp:close(Socket),
            Self = self(),
            buoy_node_stream:call(Realm, fun() -> erlang:erase({?MODULE, root, Self}) end)
    end.

%% The connections of the piped streams, in their order. A child that ends
%% before it connects leaves the rest out, once the queue holds no more.
accept(_Listen, [], _Port) -> #{};
accept(Listen, [Name | Rest], Port) ->
    Live = erlang:port_info(Port, os_pid) =/= undefined,
    case gen_tcp:accept(Listen, case Live of true -> 100; false -> 0 end) of
        {ok, Socket} -> (accept(Listen, Rest, Port))#{Name => Socket};
        {error, timeout} when Live -> accept(Listen, [Name | Rest], Port);
        _ -> #{}
    end.

started(This, Manager, OsPid, Handles, Extras, In) ->
    [begin
         erlang:put({?MODULE, root, Channel}, Handle),
         buoy_node_stream:attach(Handle, Channel)
     end || {_, Handle, Channel} <- Extras],
    %% The handles stay roots of the heap until the manager has sent its last
    %% callback, which may still name them.
    erlang:put({?MODULE, root, Manager}, {This, Handles}),
    [buoy_node_stream:attach(H, Manager) || H <- maps:values(Handles), H =/= none, element(1, H) =/= wrap],
    Source = case In of
        {wrap, Stream} -> buoy_node_stream:forward(Stream, Manager), Stream;
        _ -> none
    end,
    buoy_heap:set(This, <<"pid">>, OsPid),
    save(This, #{manager => Manager, pid => OsPid, refed => false, exited => false, source => Source}),
    set_ref(This, true),
    0.

pipe_handle({pipe, Handle}) -> Handle;
pipe_handle(_) -> none.

%% The output of the child goes to its pipe, or out through the handle of a
%% wrap entry, which the child shares.
output_handle({wrap, Handle}) -> {wrap, Handle};
output_handle(Stdio) -> pipe_handle(Stdio).

redirect(_, {ipc, _}) -> "";
redirect(I, {wrap, Handle}) -> redirect(I, {pipe, Handle});
redirect(0, {pipe, _}) -> " <&5";
redirect(0, {file, Path}) -> " <" ++ buoy_binding_spawn_sync:quote(Path);
redirect(0, inherit) -> "";
redirect(0, {fd, 0}) -> "";
redirect(0, _) -> " </dev/null";
redirect(1, {pipe, _}) -> " >&7";
redirect(1, {file, Path}) -> " >>" ++ buoy_binding_spawn_sync:quote(Path);
redirect(1, inherit) -> "";
redirect(1, {fd, 1}) -> "";
redirect(1, {fd, 2}) -> " >&2";
redirect(1, _) -> " >/dev/null";
redirect(2, {pipe, _}) -> " 2>&6";
redirect(2, {file, Path}) -> " 2>>" ++ buoy_binding_spawn_sync:quote(Path);
redirect(2, inherit) -> "";
redirect(2, {fd, 2}) -> "";
redirect(2, {fd, 1}) -> " 2>&1";
redirect(2, _) -> " 2>/dev/null".

%% The manager: the exit from the port, stdout and stderr from their sockets,
%% writes and the end of stdin to the writer, and every callback of the realm
%% in '$buoy_node_call', in order. It ends once the child exited and its
%% output ended, and its last callback drops the roots of the handles.
manage(#{waiting := []} = M) ->
    #{realm := Realm, writer := Writer} = M,
    Manager = self(),
    buoy_node_stream:call(Realm, fun() -> erlang:erase({?MODULE, root, Manager}) end),
    drain(Writer);
manage(#{port := Port, realm := Realm, handles := Handles, writer := Writer, stdout := Stdout, stderr := Stderr} = M) ->
    receive
        {tcp, Stdout, Data} ->
            deliver(Realm, maps:get(stdout, Handles), Data),
            manage(M);
        {tcp_closed, Stdout} ->
            deliver(Realm, maps:get(stdout, Handles), eof),
            manage(M#{waiting := lists:delete(stdout, maps:get(waiting, M))});
        {Port, {exit_status, Status}} ->
            {Code, Signal} = case Status of
                S when S > 128 -> {null, S - 128};
                S -> {S, 0}
            end,
            This = maps:get(this, M),
            [buoy_node_ipc:child_exited(Channel) || Channel <- maps:get(ipc, M)],
            buoy_node_stream:call(Realm, fun() -> exited(This, Code, Signal) end),
            manage(M#{waiting := lists:delete(exit, maps:get(waiting, M))});
        {tcp, Stderr, Data} ->
            deliver(Realm, maps:get(stderr, Handles), Data),
            manage(M);
        {tcp_closed, Stderr} ->
            deliver(Realm, maps:get(stderr, Handles), eof),
            manage(M#{waiting := lists:delete(stderr, maps:get(waiting, M))});
        {write, _, _, _} = Write when is_pid(Writer) ->
            Writer ! Write,
            manage(M);
        {write, _, From, Ref} ->
            report(From, Ref, {error, epipe}),
            manage(M);
        shutdown when is_pid(Writer) ->
            Writer ! shutdown,
            manage(M);
        {kill, Signal} ->
            case erlang:port_info(Port, os_pid) of
                {os_pid, OsPid} -> _ = buoy_native:os_kill(OsPid, Signal);
                _ -> ok
            end,
            manage(M);
        _ ->
            manage(M)
    end.

drain(Writer) when is_pid(Writer) -> Writer ! shutdown, ok;
drain(_) -> ok.

deliver(_Realm, none, _Item) -> ok;
deliver(_Realm, {wrap, _}, eof) -> ok;
deliver(Realm, {wrap, Handle}, Bytes) -> buoy_node_stream:call(Realm, fun() -> buoy_node_stream:pass(Handle, Bytes) end);
deliver(Realm, Handle, Item) -> buoy_node_stream:call(Realm, fun() -> buoy_node_stream:deliver(Handle, Item) end).

%% The writer of stdin: a send that fills the socket's buffer waits here, not
%% in the manager. Shutdown half-closes, so the child reads the end.
write_loop(Socket) ->
    receive
        {write, Bytes, From, Ref} ->
            case gen_tcp:send(Socket, Bytes) of
                ok -> report(From, Ref, ok), write_loop(Socket);
                Error -> report(From, Ref, Error), gen_tcp:close(Socket), write_closed(Socket)
            end;
        shutdown ->
            _ = gen_tcp:shutdown(Socket, write),
            write_loop_closed(Socket)
    end.

write_loop_closed(Socket) ->
    receive
        {write, _, From, Ref} -> report(From, Ref, {error, epipe}), write_loop_closed(Socket);
        _ -> write_loop_closed(Socket)
    after 60000 ->
        gen_tcp:close(Socket)
    end.

%% A writer whose socket failed answers each later write with EPIPE.
write_closed(Socket) ->
    write_loop_closed(Socket).

%% Reports a write of the realm's request Ref: 0, or EPIPE when it failed.
report(Realm, Ref, ok) ->
    buoy_node_stream:call(Realm, fun() -> buoy_node_stream:written(Ref, 0, ok) end);
report(Realm, Ref, _Error) ->
    buoy_node_stream:call(Realm, fun() -> buoy_node_stream:written(Ref, -32, ok) end).

%% ProcessWrap::OnExit: onexit(exitCode, signal name or '').
exited(This, Code, Signal) ->
    S = state(This),
    save(This, S#{exited => true}),
    %% The child's stdin no longer reads the stream that it shared.
    maps:get(source, S, none) =/= none andalso buoy_node_stream:forward(maps:get(source, S), none),
    set_ref(This, false),
    Name = case Signal of
        0 -> <<>>;
        N -> case buoy_binding_spawn_sync:signal_name(N) of null -> <<>>; Found -> Found end
    end,
    Onexit = buoy_heap:get(This, <<"onexit">>),
    ExitCode = case Code of null -> null; _ -> Code end,
    buoy_heap:is_callable(Onexit) andalso buoy_heap:call(Onexit, This, [ExitCode, Name]),
    undefined.

%% kill(signal): 0, or ESRCH once the child has exited.
kill(This, Signal) ->
    case state(This) of
        #{exited := false, manager := Manager} ->
            Manager ! {kill, trunc(buoy_ref:to_number(Signal))},
            0;
        _ ->
            -3
    end.

close(This, Callback) ->
    set_ref(This, false),
    save(This, (state(This))#{closed => true}),
    buoy_heap:is_callable(Callback) andalso
        buoy_node_loop:defer(fun() -> buoy_heap:call(Callback, This, []) end),
    undefined.

set_ref(This, Refed) ->
    S = state(This),
    Old = maps:get(refed, S, false),
    Live = not maps:get(exited, S, true),
    New = Refed andalso Live,
    case {Old, New} of
        {false, true} -> buoy_node_loop:ref_handle();
        {true, false} -> buoy_node_loop:unref_handle();
        _ -> ok
    end,
    save(This, S#{refed => New}),
    undefined.
