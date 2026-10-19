%% internalBinding('tty_wrap') (src/tty_wrap.cc): isTTY(fd) for the standard
%% descriptors, through the terminal driver of OTP. The TTY handle class is
%% not implemented yet: guessHandleType reports a terminal only when the VM
%% has one.
-module(buoy_binding_tty_wrap).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    buoy_node:object([
        {<<"isTTY">>, buoy_node:fn(<<"isTTY">>, 0, fun(_, Args) -> is_tty(buoy_node:arg(1, Args)) end)},
        {<<"TTY">>, buoy_node:missing_constructor(<<"tty_wrap">>, <<"TTY">>, 2)}]).

is_tty(Fd) ->
    case Fd of
        0 -> isatty(stdin);
        1 -> isatty(stdout);
        2 -> isatty(stderr);
        _ -> false
    end.

isatty(Device) ->
    try prim_tty:isatty(Device) of
        true -> true;
        _ -> false
    catch _:_ -> false
    end.
