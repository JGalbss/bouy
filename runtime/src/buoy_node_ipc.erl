%% The IPC channel of child_process: the Pipe that getValidStdio marks ipc,
%% over a local stream socket, as libuv's uv_pipe in IPC mode
%% (src/unix/stream.c) runs it. The channel's bytes and the handles that
%% child.send() passes share the socket: a write may carry the descriptor
%% of a TCP, Pipe, or UDP handle in SCM_RIGHTS (uv_write2), and a read that
%% carries one gives the Pipe its pendingHandle before onread, as
%% LibuvStreamWrap::OnUvRead does.
%%
%% libuv gives the child its end of a socketpair. OTP has no socketpair, so
%% the parent listens at a path that only its user may open, and
%% `buoy --buoy-exec unix=<fd>:<path>` connects the child's end before it
%% execs the file. Bun passes handles the same way, over its own IPC
%% socket, but only for the cluster's server handles; Node's protocol of
%% NODE_HANDLE messages runs here unchanged.
%%
%% A channel is two processes: a writer, which the realm's StreamBase
%% methods send {write, Bytes, From, Ref}, {write, Bytes, From, Ref, Fds},
%% shutdown, and close (buoy_node_stream), and a reader that blocks in
%% recvmsg. A write that fills the socket's buffer waits in the writer, so
%% the reader keeps reading and two processes that send to each other at
%% once never deadlock (test-child-process-send-deadlock).
-module(buoy_node_ipc).

-export([listen/1, open/2, child_exited/1, abandon/1, send_fds/1]).

-define(ROOT(Channel), {?MODULE, root, Channel}).
%% Room for the SCM_RIGHTS of several descriptors in one read.
-define(CTRL_SIZE, 256).

%% The parent's end: a channel that waits for the child at Path.
-spec listen(term()) -> {ok, pid(), string()} | {error, term()}.
listen(Handle) ->
    Realm = self(),
    Path = lists:flatten(io_lib:format("/tmp/buoy-ipc-~s-~b.sock", [os:getpid(), erlang:unique_integer([positive])])),
    {Channel, Monitor} = spawn_monitor(fun() -> listening(Realm, Handle, Path) end),
    receive
        {Channel, listening} ->
            erlang:demonitor(Monitor, [flush]),
            root(Handle, Channel),
            {ok, Channel, Path};
        {'DOWN', Monitor, process, Channel, Reason} ->
            {error, Reason}
    end.

%% The child's end: the descriptor that the VM inherited (NODE_CHANNEL_FD),
%% or error when it is not a socket.
-spec open(term(), integer()) -> ok | error.
open(Handle, Fd) ->
    Realm = self(),
    {Channel, Monitor} = spawn_monitor(fun() ->
        case buoy_node_socket:open_inherited(Fd, #{dup => false}) of
            {ok, Socket} ->
                Realm ! {self(), opened},
                connected(Socket, Realm, Handle);
            {error, _} ->
                exit(normal)
        end
    end),
    receive
        {Channel, opened} ->
            erlang:demonitor(Monitor, [flush]),
            root(Handle, Channel),
            buoy_node_stream:set_fd(Handle, Fd),
            ok;
        {'DOWN', Monitor, process, Channel, _} ->
            error
    end.

%% The child of a channel that still waits has exited: the channel ends.
-spec child_exited(pid()) -> ok.
child_exited(Channel) ->
    Channel ! child_exited,
    ok.

%% The child never started: the channel ends without a read, since the
%% Pipe reads its end at once (process_wrap's unstarted/1).
-spec abandon(pid()) -> ok.
abandon(Channel) ->
    Channel ! abandon,
    erlang:erase(?ROOT(Channel)),
    ok.

%% The descriptor that a write of SendHandle passes: the socket of a TCP,
%% Pipe, or UDP handle of buoy_node_socket, or none.
-spec send_fds(term()) -> [integer()].
send_fds(SendHandle) ->
    case buoy_node_socket:find(SendHandle) of
        {ok, #{socket := Socket}} when Socket =/= none ->
            case socket:getopt(Socket, {otp, fd}) of
                {ok, Fd} when is_integer(Fd), Fd >= 0 -> [Fd];
                _ -> []
            end;
        _ ->
            []
    end.

%% The handle stays a root of the heap while its channel may call back.
root(Handle, Channel) ->
    erlang:put(?ROOT(Channel), Handle),
    buoy_node_stream:attach(Handle, Channel).

listening(Realm, Handle, Path) ->
    Monitor = monitor(process, Realm),
    _ = file:delete(Path),
    {ok, Listen} = socket:open(local, stream, default),
    ok = socket:bind(Listen, #{family => local, path => Path}),
    ok = file:change_mode(Path, 8#600),
    ok = socket:listen(Listen, 1),
    Realm ! {self(), listening},
    accept(Listen, Path, Monitor, Realm, Handle).

%% Writes wait in the mailbox until the child connects.
accept(Listen, Path, Monitor, Realm, Handle) ->
    case socket:accept(Listen, nowait) of
        {ok, Socket} ->
            stop_listening(Listen, Path),
            case socket:getopt(Socket, {otp, fd}) of
                {ok, Fd} -> call(Realm, fun() -> buoy_node_stream:set_fd(Handle, Fd) end);
                _ -> ok
            end,
            connected(Socket, Realm, Handle);
        {select, {select_info, _, Ref}} ->
            receive
                {'$socket', Listen, select, Ref} ->
                    accept(Listen, Path, Monitor, Realm, Handle);
                child_exited ->
                    stop_listening(Listen, Path),
                    ended(Realm, Handle, self());
                abandon ->
                    stop_listening(Listen, Path);
                close ->
                    stop_listening(Listen, Path),
                    unroot(Realm);
                {'DOWN', Monitor, process, _, _} ->
                    stop_listening(Listen, Path)
            end;
        {error, _} ->
            stop_listening(Listen, Path),
            ended(Realm, Handle, self())
    end.

stop_listening(Listen, Path) ->
    _ = socket:close(Listen),
    _ = file:delete(Path),
    ok.

connected(Socket, Realm, Handle) ->
    Writer = self(),
    spawn_link(fun() -> read(Socket, Realm, Handle, Writer, []) end),
    write(Socket, monitor(process, Realm)).

%% Each read holds at most one handle, as OnUvRead accepts one pending
%% handle for each read; more descriptors wait for the next reads.
read(Socket, Realm, Handle, Writer, Fds) ->
    case socket:recvmsg(Socket, 0, ?CTRL_SIZE, [], infinity) of
        {ok, #{iov := Iov} = Msg} ->
            Queue = Fds ++ [Fd || #{level := socket, type := rights, data := Data} <- maps:get(ctrl, Msg, []),
                                  <<Fd:32/native-signed>> <= Data],
            {Pending, Rest} = case Queue of
                [Fd | More] -> {Fd, More};
                [] -> {none, []}
            end,
            Bytes = iolist_to_binary(Iov),
            call(Realm, fun() -> received(Handle, Bytes, Pending) end),
            read(Socket, Realm, Handle, Writer, Rest);
        {error, _} ->
            [close_fd(Fd) || Fd <- Fds],
            ended(Realm, Handle, Writer)
    end.

received(Handle, Bytes, none) ->
    buoy_node_stream:deliver(Handle, Bytes);
received(Handle, Bytes, Fd) ->
    buoy_node_stream:deliver(Handle, {Bytes, pending_handle(Fd)}).

%% uv_pipe_pending_type: a local socket is a Pipe, a datagram socket a UDP,
%% and any other a TCP, each made as Instantiate makes it.
pending_handle(Fd) ->
    case buoy_node_socket:open_inherited(Fd, #{dup => false}) of
        {ok, Socket} ->
            {Binding, Class, Kind} = case socket:info(Socket) of
                #{domain := local} -> {<<"pipe_wrap">>, <<"Pipe">>, pipe};
                #{type := dgram} -> {<<"udp_wrap">>, <<"UDP">>, udp};
                _ -> {<<"tcp_wrap">>, <<"TCP">>, tcp}
            end,
            Constructor = buoy_heap:get(buoy_node:binding(Binding), Class),
            buoy_node_socket:adopt(Constructor, Kind, Socket);
        {error, _} ->
            undefined
    end.

close_fd(Fd) ->
    case buoy_node_socket:open_inherited(Fd, #{dup => false}) of
        {ok, Socket} -> socket:close(Socket);
        _ -> ok
    end.

write(Socket, Monitor) ->
    receive
        {write, Bytes, From, Ref} ->
            report(From, Ref, send(Socket, [Bytes], [])),
            write(Socket, Monitor);
        {write, Bytes, From, Ref, Fds} ->
            report(From, Ref, send(Socket, [Bytes], Fds)),
            write(Socket, Monitor);
        shutdown ->
            _ = socket:shutdown(Socket, write),
            write(Socket, Monitor);
        close ->
            socket:close(Socket);
        {'DOWN', Monitor, process, _, _} ->
            socket:close(Socket);
        _ ->
            write(Socket, Monitor)
    end.

%% The descriptors go with the first bytes, as uv_write2 sends them.
send(Socket, Iov, Fds) ->
    Ctrl = [#{level => socket, type => rights, data => << <<Fd:32/native>> || Fd <- Fds >>} || Fds =/= []],
    Msg = case Ctrl of
        [] -> #{iov => Iov};
        _ -> #{iov => Iov, ctrl => Ctrl}
    end,
    case socket:sendmsg(Socket, Msg, infinity) of
        ok -> ok;
        {ok, Rest} -> send(Socket, Rest, []);
        {error, _} = Error -> Error
    end.

report(From, Ref, Result) ->
    Status = case Result of
        ok -> 0;
        _ -> -32
    end,
    call(From, fun() -> buoy_node_stream:written(Ref, Status, ok) end).

ended(Realm, Handle, Channel) ->
    call(Realm, fun() ->
        buoy_node_stream:deliver(Handle, eof),
        erlang:erase(?ROOT(Channel))
    end).

unroot(Realm) ->
    Channel = self(),
    call(Realm, fun() -> erlang:erase(?ROOT(Channel)) end).

call(Realm, Fun) -> buoy_node_stream:call(Realm, Fun).
