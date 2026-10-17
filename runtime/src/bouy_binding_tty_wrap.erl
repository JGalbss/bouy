%% internalBinding('tty_wrap') (src/tty_wrap.cc): isTTY(fd) for the standard
%% descriptors, through the terminal driver of OTP. The TTY handle class is
%% not implemented yet: guessHandleType reports a terminal only when the VM
%% has one.
-module(bouy_binding_tty_wrap).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    bouy_node:object([
        {<<"isTTY">>, bouy_node:fn(<<"isTTY">>, 0, fun(_, Args) -> is_tty(bouy_node:arg(1, Args)) end)},
        {<<"TTY">>, bouy_node:missing_constructor(<<"tty_wrap">>, <<"TTY">>, 2)}]).

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
