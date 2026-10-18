%% The standard descriptors of the VM as stream handles: the TTY handle of
%% tty_wrap and the Pipe handle of pipe_wrap that open fd 0, 1, or 2. Node
%% makes process.stdin and process.stdout such handles when they are a
%% terminal, a pipe, or a socket (internal/bootstrap/switches/is_main_thread).
%%
%% A write to fd 1 or 2 goes to the device at once, in order with console
%% output and with the fs writes on the same descriptor, as libuv makes the
%% writes of stdio blocking. fd 0 reads through buoy_node_stdin from the
%% first readStart, as libuv reads only while a handle reads, so a child that
%% inherits stdin before then still gets its bytes.
-module(buoy_node_stdio).

-export([methods/1, open/2, kind/1, close/1]).

-include_lib("kernel/include/file.hrl").

-define(FD, {'#', ?MODULE, <<"fd">>}).
-define(READER, {'#', ?MODULE, <<"reader">>}).
-define(UV_EPIPE, -32).

%% Wraps readStart of a prototype that buoy_node_stream:methods/1 set up, and
%% gives it the fd getter of a standard descriptor.
-spec methods(term()) -> ok.
methods(Proto) ->
    F = fun buoy_node:fn/3,
    ReadStart = buoy_heap:get(Proto, <<"readStart">>),
    buoy_heap:define(Proto, <<"readStart">>, #{value => F(<<"readStart">>, 0, fun(This, Args) ->
        case buoy_heap:call(ReadStart, This, Args) of
            0 -> start_reader(This), 0;
            Error -> Error
        end
    end), writable => true, enumerable => true, configurable => true}),
    buoy_heap:define(Proto, <<"fd">>, #{get => F(<<"get fd">>, 0, fun(This, _) -> fd(This) end),
                                        enumerable => true, configurable => true}),
    ok.

%% Binds Handle to the standard descriptor Fd.
-spec open(term(), 0..2) -> ok.
open(Handle, Fd) ->
    buoy_heap:private_put(Handle, ?FD, Fd),
    case Fd of
        0 ->
            Realm = self(),
            Reader = spawn(fun() -> receive start -> read_loop(Realm, Handle); close -> ok end end),
            buoy_heap:private_put(Handle, ?READER, Reader),
            buoy_node_stream:attach(Handle, Reader);
        1 ->
            buoy_node_stream:attach(Handle, none, fun(Bytes) -> write(standard_io, Bytes) end);
        2 ->
            buoy_node_stream:attach(Handle, none, fun(Bytes) -> write(buoy_ref:stderr(), Bytes) end)
    end.

%% A write to a pipe whose reader has gone ends the writer of OTP's device,
%% and each later write finds the device terminated: that is EPIPE, which
%% Node reports on the stream as libuv returns it, since Node ignores SIGPIPE.
write(Device, Bytes) ->
    try buoy_binding_fs:put_bytes(Device, Bytes) of
        _ -> 0
    catch
        error:terminated -> ?UV_EPIPE
    end.

%% What the standard descriptor Fd of the VM is, as uv_guess_handle reports
%% it: a terminal, a pipe or a socket, or a file, which a character device
%% such as /dev/null also is, or closed after fs.closeSync(Fd).
-spec kind(0..2) -> tty | pipe | file | closed.
kind(Fd) ->
    case persistent_term:get({?MODULE, closed, Fd}, false) of
        true -> closed;
        false -> open_kind(Fd)
    end.

open_kind(Fd) ->
    case buoy_binding_tty_wrap:is_tty(Fd) of
        true ->
            tty;
        false ->
            case file:read_file_info("/dev/fd/" ++ integer_to_list(Fd)) of
                {ok, #file_info{type = other}} -> pipe;
                _ -> file
            end
    end.

fd(This) ->
    case buoy_heap:private_find(This, ?FD) of
        {ok, Fd} -> Fd;
        error -> -1
    end.

%% The handle stays a root of the heap while its reader runs.
start_reader(Handle) ->
    case buoy_heap:private_find(Handle, ?READER) of
        {ok, Reader} when is_pid(Reader) ->
            buoy_heap:private_put(Handle, ?READER, started),
            erlang:put({?MODULE, root, Reader}, Handle),
            Reader ! start;
        _ ->
            ok
    end.

read_loop(Realm, Handle) ->
    case buoy_node_stdin:read(65536) of
        <<>> -> ended(Realm, Handle);
        Bytes ->
            buoy_node_stream:call(Realm, fun() -> buoy_node_stream:deliver(Handle, Bytes) end),
            receive
                close -> ended(Realm, Handle)
            after 0 ->
                read_loop(Realm, Handle)
            end
    end.

ended(Realm, Handle) ->
    Self = self(),
    buoy_node_stream:call(Realm, fun() ->
        buoy_node_stream:deliver(Handle, eof),
        erlang:erase({?MODULE, root, Self})
    end).

%% fs.closeSync(Fd) of a standard descriptor: OTP keeps the descriptor open,
%% so the VM records it as closed, and a stream that the program creates
%% after that gets no handle, as for a descriptor that libuv cannot guess.
%% It returns error when the descriptor was closed already, which is EBADF.
-spec close(0..2) -> ok | error.
close(Fd) ->
    case persistent_term:get({?MODULE, closed, Fd}, false) of
        true -> error;
        false -> persistent_term:put({?MODULE, closed, Fd}, true)
    end.
