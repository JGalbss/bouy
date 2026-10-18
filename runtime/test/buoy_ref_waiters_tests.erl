-module(buoy_ref_waiters_tests).

-include_lib("eunit/include/eunit.hrl").

%% Processes that share an atomics array share its waiter lists: a notify wakes the
%% waiters of one element oldest first, up to its count, and returns how many it woke.
notify_wakes_in_order_test() ->
    Ref = atomics:new(2, [{signed, false}]),
    Cell = {Ref, 4, 4},
    Parent = self(),
    Waiters = [spawn_waiter(Parent, Cell, N) || N <- [1, 2, 3]],
    ?assertEqual(2, buoy_ref_waiters:notify(Cell, 2)),
    ?assertEqual([1, 2], [receive {woken, N} -> N end || _ <- [1, 2]]),
    ?assertEqual(0, buoy_ref_waiters:notify({Ref, 0, 4}, infinity)),
    ?assertEqual(1, buoy_ref_waiters:notify(Cell, infinity)),
    ?assertEqual(3, receive {woken, N} -> N end),
    ?assertEqual(0, buoy_ref_waiters:notify(Cell, infinity)),
    [exit(W, kill) || W <- Waiters].

%% A waiter is added only when the element holds the expected bytes.
wait_compares_the_element_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    atomics:put(Ref, 1, 7 bsl 32),
    ?assertEqual(not_equal, buoy_ref_waiters:wait({Ref, 4, 4}, <<0, 0, 0, 0>>, make_ref())),
    ?assert(buoy_ref_waiters:holds({Ref, 4, 4}, <<7, 0, 0, 0>>)),
    ?assert(buoy_ref_waiters:holds({Ref, 0, 4}, <<0, 0, 0, 0>>)).

%% A waiter whose timeout ends removes itself, unless a notify woke it first.
cancel_test() ->
    Cell = {atomics:new(1, [{signed, false}]), 0, 4},
    Tag = make_ref(),
    ?assertEqual(waiting, buoy_ref_waiters:wait(Cell, <<0, 0, 0, 0>>, Tag)),
    ?assertEqual(removed, buoy_ref_waiters:cancel(Cell, Tag)),
    ?assertEqual(0, buoy_ref_waiters:notify(Cell, infinity)),
    Woken = make_ref(),
    ?assertEqual(waiting, buoy_ref_waiters:wait(Cell, <<0, 0, 0, 0>>, Woken)),
    ?assertEqual(1, buoy_ref_waiters:notify(Cell, 1)),
    ?assertEqual(gone, buoy_ref_waiters:cancel(Cell, Woken)),
    receive {'$buoy_atomics_wake', Woken} -> ok end.

%% A waiter that exits leaves its list, so a notify does not count it.
exited_waiter_leaves_test() ->
    {Ref, Byte, _} = Cell = {atomics:new(1, [{signed, false}]), 0, 4},
    Waiter = spawn_waiter(self(), Cell, 1),
    ?assert(maps:is_key({Ref, Byte}, sys:get_state(buoy_ref_waiters))),
    exit(Waiter, kill),
    ok = until_gone({Ref, Byte}),
    ?assertEqual(0, buoy_ref_waiters:notify(Cell, infinity)).

%% Returns once the list process has taken the DOWN of the last waiter of Key.
until_gone(Key) ->
    case maps:is_key(Key, sys:get_state(buoy_ref_waiters)) of
        true -> timer:sleep(1), until_gone(Key);
        false -> ok
    end.

%% A process that waits on Cell and reports N when it wakes. It returns once the
%% process is in the list.
spawn_waiter(Parent, Cell, N) ->
    Pid = spawn(fun() ->
                        Tag = make_ref(),
                        waiting = buoy_ref_waiters:wait(Cell, <<0, 0, 0, 0>>, Tag),
                        Parent ! {waiting, self()},
                        receive {'$buoy_atomics_wake', Tag} -> Parent ! {woken, N} end
                end),
    receive {waiting, Pid} -> Pid end.
