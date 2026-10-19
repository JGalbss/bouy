-module(buoy_node_loop_tests).

%% The timer phase of Node's loop, in a realm without Node's lib: an Erlang
%% function stands in for processTimers of lib/internal/timers.

-include_lib("eunit/include/eunit.hrl").

%% libuv runs every due timer at the start of a turn, by the clock of the
%% loop (uv__run_timers). A turn that starts after the deadline but before
%% the BEAM message of the timer arrives runs processTimers all the same,
%% before it polls. The message is taken out of the mailbox here, as a busy
%% scheduler delays it; test-timers-immediate-queue.js failed on Linux when
%% the immediates of the next turn ran first.
a_due_timer_runs_at_the_start_of_a_turn_before_its_message_test() ->
    ?assertEqual([due], in_realm(fun() ->
        Fired = buoy_heap:function(fun(_This, _Args) -> erlang:put(fired, [due]), 0 end),
        buoy_node_loop:set_process(buoy_heap:object(null, [])),
        buoy_node_loop:set_callback(process_timers, Fired),
        buoy_node_loop:schedule_timer(1),
        receive {'$buoy_node_timer', _} -> ok end,
        _ = buoy_node_loop:poll(),
        erlang:get(fired)
    end)).

%% A timer that is not due yet waits for its message.
a_timer_that_is_not_due_waits_test() ->
    ?assertEqual(undefined, in_realm(fun() ->
        Fired = buoy_heap:function(fun(_This, _Args) -> erlang:put(fired, [due]), 0 end),
        buoy_node_loop:set_process(buoy_heap:object(null, [])),
        buoy_node_loop:set_callback(process_timers, Fired),
        buoy_node_loop:schedule_timer(60000),
        _ = buoy_node_loop:poll(),
        erlang:get(fired)
    end)).

in_realm(Body) ->
    Self = self(),
    Pid = spawn(fun() ->
        buoy_ref:init_realm(),
        Self ! {self(), Body()}
    end),
    receive
        {Pid, Result} -> Result
    after 5000 -> erlang:error(timeout)
    end.
