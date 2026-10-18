%% internalBinding('tty_wrap') (src/tty_wrap.cc): isTTY(fd), and TTY, the
%% stream handle of tty.ReadStream and tty.WriteStream on the standard
%% descriptors of the VM.
%%
%% A TTY handle has the StreamBase methods of buoy_node_stream. A write goes
%% to the device of the descriptor at once, in order with console output and
%% with the writes of fs on the same descriptor, as WriteStream asks for a
%% blocking handle. The handle of fd 0 reads through buoy_node_stdin.
%% getWindowSize asks the terminal driver of OTP, and setRawMode sets the
%% termios flags of uv_tty_set_mode with stty(1); buoy_main resets the mode
%% before the VM halts, as Node's ResetStdio does.
-module(buoy_binding_tty_wrap).

-export([binding/0, is_tty/1, reset_mode/0]).

-define(FD, {'#', ?MODULE, <<"fd">>}).
-define(SAVED_MODE, {?MODULE, saved_mode}).
-define(UV_EINVAL, -22).
-define(UV_ENOTTY, -25).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    TTY = buoy_node:constructor(<<"TTY">>, 2, fun(This, Args) -> init(This, buoy_node:arg(1, Args), buoy_node:arg(2, Args)) end),
    Proto = buoy_heap:get(TTY, <<"prototype">>),
    buoy_node_stream:methods(Proto),
    Methods = [{<<"getWindowSize">>, fun(This, Args) -> window_size(fd(This), buoy_node:arg(1, Args)) end},
               {<<"setRawMode">>, fun(This, Args) -> set_raw_mode(fd(This), buoy_ref:truthy(buoy_node:arg(1, Args))) end}],
    [buoy_heap:define(Proto, Name, #{value => F(Name, 0, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    buoy_heap:define(Proto, <<"fd">>, #{get => F(<<"get fd">>, 0, fun(This, _) -> fd(This) end), enumerable => true, configurable => true}),
    buoy_node:object([
        {<<"isTTY">>, F(<<"isTTY">>, 0, fun(_, Args) -> is_tty(buoy_node:arg(1, Args)) end)},
        {<<"TTY">>, TTY}]).

%% Whether the descriptor Fd of the VM is a terminal.
-spec is_tty(term()) -> boolean().
is_tty(0) -> isatty(stdin);
is_tty(1) -> isatty(stdout);
is_tty(2) -> isatty(stderr);
is_tty(_) -> false.

isatty(Device) ->
    try prim_tty:isatty(Device) of
        true -> true;
        _ -> false
    catch _:_ -> false
    end.

%% new TTY(fd, ctx): ctx gets the error of uv_tty_init for a descriptor
%% that the VM cannot drive as a terminal.
init(This, Fd, _Ctx) when Fd =:= 0; Fd =:= 1; Fd =:= 2 ->
    buoy_heap:private_put(This, ?FD, Fd),
    case Fd of
        0 -> reader(This);
        _ -> buoy_node_stream:attach(This, none, writer(Fd))
    end,
    undefined;
init(_This, _Fd, Ctx) ->
    [buoy_heap:set(Ctx, K, V) || {K, V} <- [{<<"errno">>, ?UV_EINVAL}, {<<"code">>, <<"EINVAL">>},
                                            {<<"message">>, <<"invalid argument">>}, {<<"syscall">>, <<"uv_tty_init">>}]],
    undefined.

fd(This) ->
    case buoy_heap:private_find(This, ?FD) of
        {ok, Fd} -> Fd;
        error -> -1
    end.

writer(1) -> fun(Bytes) -> buoy_binding_fs:put_bytes(standard_io, Bytes), 0 end;
writer(2) -> fun(Bytes) -> buoy_binding_fs:put_bytes(buoy_ref:stderr(), Bytes), 0 end.

%% shortcut: the reader takes stdin from the start, where libuv reads only
%% while the handle reads; a child that inherits the terminal can lose the
%% bytes that the reader took. Start it on readStart when that matters.
reader(Handle) ->
    Realm = self(),
    Channel = spawn(fun() -> read_loop(Realm, Handle) end),
    erlang:put({?MODULE, root, Channel}, Handle),
    buoy_node_stream:attach(Handle, Channel).

read_loop(Realm, Handle) ->
    receive
        close -> ended(Realm, Handle)
    after 0 ->
        case buoy_node_stdin:read(65536) of
            <<>> -> ended(Realm, Handle);
            Bytes ->
                buoy_node_stream:call(Realm, fun() -> buoy_node_stream:deliver(Handle, Bytes) end),
                read_loop(Realm, Handle)
        end
    end.

ended(Realm, Handle) ->
    Self = self(),
    buoy_node_stream:call(Realm, fun() ->
        buoy_node_stream:deliver(Handle, eof),
        erlang:erase({?MODULE, root, Self})
    end).

%% getWindowSize([columns, rows]): 0, or the error of the ioctl.
window_size(Fd, Size) ->
    Device = case Fd of 2 -> standard_error; _ -> standard_io end,
    case {is_tty(Fd), io:columns(Device), io:rows(Device)} of
        {true, {ok, Columns}, {ok, Rows}} ->
            buoy_heap:set(Size, 0, Columns),
            buoy_heap:set(Size, 1, Rows),
            0;
        _ ->
            ?UV_ENOTTY
    end.

%% setRawMode(flag): the termios flags of UV_TTY_MODE_RAW, or the mode that
%% the terminal had before the first change.
set_raw_mode(Fd, Raw) ->
    case is_tty(Fd) of
        false ->
            ?UV_ENOTTY;
        true ->
            Device = terminal(),
            persistent_term:get(?SAVED_MODE, undefined) =:= undefined andalso
                persistent_term:put(?SAVED_MODE, {Device, string:trim(os:cmd("stty -g < " ++ Device ++ " 2>/dev/null"))}),
            Mode = case Raw of
                true -> "-brkint -icrnl -inpck -istrip -ixon opost onlcr cs8 -echo -icanon -iexten -isig min 1 time 0";
                false -> element(2, persistent_term:get(?SAVED_MODE))
            end,
            stty(Device, Mode)
    end.

%% The path of the terminal on stdin. A command that the VM starts runs in
%% its own session, where /dev/tty names no terminal, so stty opens the
%% device: /proc names it on Linux, and ps(1) names the controlling
%% terminal of the VM on darwin.
terminal() ->
    case file:read_link("/proc/self/fd/0") of
        {ok, Path} -> Path;
        _ -> "/dev/" ++ string:trim(os:cmd("ps -o tty= -p " ++ os:getpid()))
    end.

stty(Device, Mode) ->
    case os:cmd("stty " ++ Mode ++ " < " ++ Device ++ " 2>/dev/null; echo $?") of
        "0\n" -> 0;
        _ -> ?UV_ENOTTY
    end.

%% Restores the mode of the terminal that setRawMode changed, before the VM
%% halts.
-spec reset_mode() -> ok.
reset_mode() ->
    case persistent_term:get(?SAVED_MODE, undefined) of
        undefined -> ok;
        {Device, Mode} -> _ = stty(Device, Mode), ok
    end.
