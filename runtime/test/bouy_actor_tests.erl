-module(bouy_actor_tests).

-include_lib("eunit/include/eunit.hrl").

-import(bouy_test_runtime, [
    counter/0, slow/0, relay/0, broken/0, moody/0, quitter/0,
    thrown/1, tag/1, entry/1, pid/1, await/1, capture_stderr/1, capture_logs/1
]).

actor_test_() ->
    {setup, fun bouy_test_runtime:start/0, fun bouy_test_runtime:stop/1, [
        {"a call returns the method result", fun call_returns_result/0},
        {"casts from one sender run in send order", fun casts_run_in_send_order/0},
        {"calls and casts share one FIFO mailbox", fun calls_and_casts_are_fifo/0},
        {"two actors of one class keep separate state", fun state_is_per_actor/0},
        {"a crash fails the caller and spares other actors", fun crash_is_isolated/0},
        {"a crash restarts the actor with fresh state and the same id", fun crash_restarts/0},
        {"an actor process that dies of a runtime fault restarts", fun fault_restarts/0},
        {"a crash prints one line to stderr", fun crash_prints_one_line/0},
        {"bouy supervisors log no OTP reports", fun supervisors_are_quiet/0},
        {"a used-up restart budget stops the actor", fun budget_stops_actor/0},
        {"a temporary actor is not restarted", fun temporary_actor_stops/0},
        {"a constructor that fails on restart uses up the budget", fun failing_restart_stops_actor/0},
        {"an Effect success replies its value", fun effect_success_replies/0},
        {"an Effect failure is rethrown and keeps the state", fun effect_failure_keeps_state/0},
        {"an Effect defect crashes the actor", fun effect_defect_crashes/0},
        {"an unknown method crashes with a TypeError", fun unknown_method_crashes/0},
        {"a reject mailbox throws MailboxFull", fun reject_mailbox_throws/0},
        {"a backpressure mailbox stays bounded", fun backpressure_bounds_mailbox/0},
        {"a call cycle throws CallCycle", fun call_cycle_throws/0},
        {"an uncaught CallCycle fails each actor in the chain", fun uncaught_cycle_fails_chain/0},
        {"stop ends a running turn", fun stop_ends_running_turn/0},
        {"an actor can stop itself in a method", fun actor_stops_itself/0},
        {"a constructor can stop its own actor", fun constructor_stops_actor/0},
        {"inspect lists each actor", fun inspect_lists_actors/0},
        {"a throwing constructor fails spawn", fun throwing_constructor_fails_spawn/0},
        {"self returns the ref of the actor", fun self_returns_ref/0},
        {"a request count belongs to one start of the actor", fun request_count_per_start/0},
        {"an actor past maxMemory fails with ActorOutOfMemory and restarts", fun memory_limit_restarts/0},
        {"a child past maxMemory restarts in its group", fun child_memory_limit_restarts/0}
    ]}.

call_returns_result() ->
    Counter = bouy:spawn([counter(), #{<<"args">> => [5]}]),
    ?assertEqual(6, bouy_actor:call(Counter, <<"inc">>, [])),
    ?assertEqual(8, bouy_actor:call(Counter, <<"inc">>, [2])),
    ?assertEqual(8, bouy_actor:call(Counter, <<"get">>, [])).

casts_run_in_send_order() ->
    Counter = bouy:spawn([counter()]),
    Cast = bouy:cast([Counter]),
    Items = lists:seq(1, 500),
    [?assert(bouy_actor:cast(Cast, <<"record">>, [Item])) || Item <- Items],
    ?assertEqual(Items, bouy_actor:call(Counter, <<"log">>, [])).

calls_and_casts_are_fifo() ->
    Counter = bouy:spawn([counter()]),
    Cast = bouy:cast([Counter]),
    true = bouy_actor:cast(Cast, <<"record">>, [a]),
    ?assertEqual([a], bouy_actor:call(Counter, <<"log">>, [])),
    true = bouy_actor:cast(Cast, <<"record">>, [b]),
    ?assertEqual(3, bouy_actor:call(Counter, <<"record">>, [c])),
    true = bouy_actor:cast(Cast, <<"record">>, [d]),
    ?assertEqual([a, b, c, d], bouy_actor:call(Counter, <<"log">>, [])).

state_is_per_actor() ->
    First = bouy:spawn([counter()]),
    Second = bouy:spawn([counter()]),
    ?assertEqual(3, bouy_actor:call(First, <<"inc">>, [3])),
    ?assertEqual(0, bouy_actor:call(Second, <<"get">>, [])).

crash_is_isolated() ->
    {'$ref', Id} = Failing = bouy:spawn([counter()]),
    Healthy = bouy:spawn([counter()]),
    3 = bouy_actor:call(Healthy, <<"inc">>, [3]),
    Failed = thrown(fun() -> bouy_actor:call(Failing, <<"fail">>, [<<"boom">>]) end),
    Label = <<"Counter #", (integer_to_binary(Id))/binary>>,
    ?assertMatch(
        #{
            '$error' := [],
            <<"name">> := <<"ActorFailed">>,
            <<"_tag">> := <<"ActorFailed">>,
            <<"actor">> := Label,
            <<"method">> := <<"fail">>,
            <<"cause">> := #{<<"name">> := <<"Error">>, <<"message">> := <<"boom">>}
        },
        Failed
    ),
    ?assertEqual(<<Label/binary, " failed in fail: Error: boom">>, maps:get(<<"message">>, Failed)),
    ?assertEqual(3, bouy_actor:call(Healthy, <<"get">>, [])),
    ?assertMatch(#{<<"restarts">> := 0}, entry(Healthy)).

crash_restarts() ->
    Counter = bouy:spawn([counter(), #{<<"args">> => [10]}]),
    11 = bouy_actor:call(Counter, <<"inc">>, []),
    OldPid = pid(Counter),
    <<"ActorFailed">> = tag(fun() -> bouy_actor:call(Counter, <<"fail">>, [<<"x">>]) end),
    %% The next call waits for the restart and reaches the new process.
    ?assertEqual(10, bouy_actor:call(Counter, <<"get">>, [])),
    ?assertNotEqual(OldPid, pid(Counter)),
    ?assertMatch(#{<<"restarts">> := 1, <<"status">> := <<"running">>}, entry(Counter)).

%% Not a JavaScript exception: an exit signal ends the process, and the
%% keeper restarts it as after a crash. The next call waits for the restart.
fault_restarts() ->
    Counter = bouy:spawn([counter()]),
    1 = bouy_actor:call(Counter, <<"inc">>, []),
    OldPid = pid(Counter),
    true = exit(OldPid, fault),
    ?assertEqual(1, bouy_actor:call(Counter, <<"inc">>, [])),
    ?assertNotEqual(OldPid, pid(Counter)),
    ?assertMatch(#{<<"restarts">> := 1, <<"status">> := <<"running">>}, entry(Counter)).

crash_prints_one_line() ->
    Named = bouy:spawn([counter(), #{<<"name">> => <<"alice">>}]),
    {'$ref', Id} = Unnamed = bouy:spawn([counter()]),
    {_, NamedText} = capture_stderr(fun() ->
        thrown(fun() -> bouy_actor:call(Named, <<"fail">>, [<<"boom">>]) end)
    end),
    ?assertEqual(<<"bouy: Counter alice crashed: Error: boom\n">>, NamedText),
    {_, UnnamedText} = capture_stderr(fun() ->
        thrown(fun() -> bouy_actor:call(Unnamed, <<"fail">>, [<<"bad">>]) end)
    end),
    ?assertEqual(<<"bouy: Counter #", (integer_to_binary(Id))/binary, " crashed: Error: bad\n">>, UnnamedText).

supervisors_are_quiet() ->
    {_, Events} = capture_logs(fun() ->
        Counter = bouy:spawn([counter()]),
        lists:foreach(
            fun(_) -> thrown(fun() -> bouy_actor:call(Counter, <<"fail">>, [<<"x">>]) end) end,
            lists:seq(1, 4)
        ),
        await(fun() -> maps:get(<<"status">>, entry(Counter)) =:= <<"stopped">> end)
    end),
    ?assertEqual([], Events).

budget_stops_actor() ->
    Counter = bouy:spawn([counter()]),
    %% The default budget is 3 restarts in 5 seconds, so the fourth crash stops it.
    [
        ?assertEqual(<<"ActorFailed">>, tag(fun() -> bouy_actor:call(Counter, <<"fail">>, [<<"x">>]) end))
     || _ <- lists:seq(1, 4)
    ],
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> bouy_actor:call(Counter, <<"get">>, []) end)),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> bouy_actor:cast(bouy:cast([Counter]), <<"inc">>, []) end)),
    ?assertMatch(#{<<"status">> := <<"stopped">>, <<"restarts">> := 3}, entry(Counter)).

temporary_actor_stops() ->
    Counter = bouy:spawn([counter(), #{<<"restart">> => <<"temporary">>}]),
    <<"ActorFailed">> = tag(fun() -> bouy_actor:call(Counter, <<"fail">>, [<<"x">>]) end),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> bouy_actor:call(Counter, <<"get">>, []) end)),
    ?assertMatch(#{<<"status">> := <<"stopped">>, <<"restarts">> := 0}, entry(Counter)).

failing_restart_stops_actor() ->
    Moody = bouy:spawn([moody()]),
    true = os:putenv("BOUY_MOODY", "fail"),
    try
        <<"ActorFailed">> = tag(fun() -> bouy_actor:call(Moody, <<"fail">>, []) end),
        ?assertEqual(<<"ActorStopped">>, tag(fun() -> bouy_actor:call(Moody, <<"fail">>, []) end)),
        ?assertMatch(#{<<"status">> := <<"stopped">>}, entry(Moody))
    after
        true = os:unsetenv("BOUY_MOODY")
    end.

effect_success_replies() ->
    Counter = bouy:spawn([counter()]),
    ?assertEqual(42, bouy_actor:call(Counter, <<"succeed">>, [42])).

effect_failure_keeps_state() ->
    Counter = bouy:spawn([counter()]),
    ?assertMatch(
        #{<<"_tag">> := <<"NotFound">>, <<"name">> := <<"NotFound">>},
        thrown(fun() -> bouy_actor:call(Counter, <<"missing">>, []) end)
    ),
    ?assertEqual(100, bouy_actor:call(Counter, <<"get">>, [])),
    ?assertMatch(#{<<"restarts">> := 0}, entry(Counter)).

effect_defect_crashes() ->
    Counter = bouy:spawn([counter()]),
    ?assertMatch(
        #{<<"_tag">> := <<"ActorFailed">>, <<"cause">> := #{<<"message">> := <<"defect">>}},
        thrown(fun() -> bouy_actor:call(Counter, <<"die">>, []) end)
    ),
    ?assertEqual(0, bouy_actor:call(Counter, <<"get">>, [])),
    ?assertMatch(#{<<"restarts">> := 1}, entry(Counter)).

unknown_method_crashes() ->
    Counter = bouy:spawn([counter()]),
    ?assertMatch(
        #{
            <<"_tag">> := <<"ActorFailed">>,
            <<"cause">> := #{<<"name">> := <<"TypeError">>, <<"message">> := <<"Counter.nope is not a function">>}
        },
        thrown(fun() -> bouy_actor:call(Counter, <<"nope">>, []) end)
    ).

reject_mailbox_throws() ->
    Mailbox = #{<<"capacity">> => 2, <<"overflow">> => <<"reject">>},
    Slow = bouy:spawn([slow(), #{<<"mailbox">> => Mailbox}]),
    Cast = bouy:cast([Slow]),
    true = bouy_actor:cast(Cast, <<"work">>, [500]),
    await(fun() -> maps:get(<<"mailbox">>, entry(Slow)) =:= 0 end),
    true = bouy_actor:cast(Cast, <<"ping">>, []),
    true = bouy_actor:cast(Cast, <<"ping">>, []),
    ?assertEqual(<<"MailboxFull">>, tag(fun() -> bouy_actor:cast(Cast, <<"ping">>, []) end)),
    ?assertEqual(<<"MailboxFull">>, tag(fun() -> bouy_actor:call(Slow, <<"ping">>, []) end)),
    await(fun() -> maps:get(<<"mailbox">>, entry(Slow)) =:= 0 end),
    ?assertEqual(<<"pong">>, bouy_actor:call(Slow, <<"ping">>, [])).

backpressure_bounds_mailbox() ->
    Capacity = 5,
    Slow = bouy:spawn([slow(), #{<<"mailbox">> => #{<<"capacity">> => Capacity}}]),
    Sampler = start_sampler(pid(Slow)),
    Cast = bouy:cast([Slow]),
    Started = erlang:monotonic_time(millisecond),
    [true = bouy_actor:cast(Cast, <<"work">>, [2]) || _ <- lists:seq(1, 100)],
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    ?assertEqual(100, bouy_actor:call(Slow, <<"done">>, [])),
    Sampler ! {stop, self()},
    Longest = receive {longest, Length} -> Length end,
    %% One sender waits at a time, so the queue holds at most one more message.
    ?assert(Longest =< Capacity + 1),
    %% Without backpressure the sender would finish in well under a millisecond.
    ?assert(Elapsed >= 2 * (100 - Capacity - 1)).

start_sampler(Pid) ->
    spawn_link(fun() -> sample(Pid, 0) end).

sample(Pid, Longest) ->
    receive
        {stop, From} -> From ! {longest, Longest}
    after 0 ->
        {message_queue_len, Length} = erlang:process_info(Pid, message_queue_len),
        sample(Pid, max(Length, Longest))
    end.

call_cycle_throws() ->
    First = bouy:spawn([relay()]),
    Second = bouy:spawn([relay()]),
    %% First asks Second, and Second calls First back while First waits.
    ?assertEqual(
        <<"CallCycle">>,
        bouy_actor:call(First, <<"ask">>, [Second, <<"ask">>, First, <<"ping">>])
    ),
    ?assertEqual(<<"pong">>, bouy_actor:call(First, <<"ask">>, [Second, <<"ping">>])),
    Counter = bouy:spawn([counter()]),
    ?assertEqual(<<"CallCycle">>, bouy_actor:call(Counter, <<"selfGet">>, [])),
    ?assertMatch(#{<<"restarts">> := 0}, entry(Counter)).

uncaught_cycle_fails_chain() ->
    {'$ref', FirstId} = First = bouy:spawn([relay()]),
    Second = bouy:spawn([relay()]),
    Failed = thrown(fun() ->
        bouy_actor:call(First, <<"tell">>, [Second, <<"tell">>, First, <<"ping">>])
    end),
    ?assertMatch(
        #{
            <<"_tag">> := <<"ActorFailed">>,
            <<"cause">> := #{
                <<"_tag">> := <<"ActorFailed">>,
                <<"cause">> := #{<<"_tag">> := <<"CallCycle">>}
            }
        },
        Failed
    ),
    #{<<"cause">> := #{<<"cause">> := Cycle}} = Failed,
    ?assertEqual(<<"Relay #", (integer_to_binary(FirstId))/binary>>, maps:get(<<"actor">>, Cycle)).

stop_ends_running_turn() ->
    Slow = bouy:spawn([slow()]),
    Test = self(),
    Waiters = [
        spawn_link(fun() ->
            Test ! {waited, tag(fun() -> bouy_actor:call(Slow, <<"work">>, [10000]) end)}
        end)
     || _ <- lists:seq(1, 2)
    ],
    await(fun() -> maps:get(<<"mailbox">>, entry(Slow)) =:= 1 end),
    Started = erlang:monotonic_time(millisecond),
    ?assertEqual(undefined, bouy:stop([Slow])),
    [
        receive
            {waited, Tag} -> ?assertEqual(<<"ActorStopped">>, Tag)
        after 5000 -> erlang:error(waiter_still_blocked)
        end
     || _ <- Waiters
    ],
    ?assert(erlang:monotonic_time(millisecond) - Started < 5000),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> bouy_actor:call(Slow, <<"ping">>, []) end)),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> bouy_actor:cast(bouy:cast([Slow]), <<"ping">>, []) end)),
    ?assertMatch(#{<<"status">> := <<"stopped">>}, entry(Slow)),
    ?assertEqual(undefined, bouy:stop([Slow])).

actor_stops_itself() ->
    Quitter = bouy:spawn([quitter()]),
    <<"pong">> = bouy_actor:call(Quitter, <<"ping">>, []),
    %% The turn may reply before the stop ends the process; later calls fail.
    Reply =
        try
            bouy_actor:call(Quitter, <<"quit">>, [])
        catch
            error:{'$throw', #{<<"_tag">> := <<"ActorStopped">>}} -> stopped
        end,
    ?assert(lists:member(Reply, [<<"bye">>, stopped])),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> bouy_actor:call(Quitter, <<"ping">>, []) end)),
    await(fun() -> pid_is_dead(Quitter) end),
    ?assertMatch(#{<<"status">> := <<"stopped">>, <<"restarts">> := 0}, entry(Quitter)).

constructor_stops_actor() ->
    Quitter = bouy:spawn([quitter(), #{<<"args">> => [true]}]),
    ?assertEqual(<<"ActorStopped">>, tag(fun() -> bouy_actor:call(Quitter, <<"ping">>, []) end)),
    await(fun() -> pid_is_dead(Quitter) end),
    ?assertMatch(#{<<"status">> := <<"stopped">>}, entry(Quitter)).

pid_is_dead(Ref) ->
    not is_process_alive(pid(Ref)).

inspect_lists_actors() ->
    Named = bouy:spawn([counter(), #{<<"name">> => <<"inspected">>}]),
    Unnamed = bouy:spawn([slow()]),
    Entry = entry(Named),
    ?assertEqual(
        [<<"class">>, <<"id">>, <<"mailbox">>, <<"memory">>, <<"name">>, <<"restarts">>, <<"status">>],
        lists:sort(maps:keys(Entry))
    ),
    {'$ref', Id} = Named,
    ?assertMatch(
        #{
            <<"id">> := Id,
            <<"name">> := <<"inspected">>,
            <<"class">> := <<"Counter">>,
            <<"status">> := <<"running">>,
            <<"restarts">> := 0,
            <<"mailbox">> := 0
        },
        Entry
    ),
    ?assert(maps:get(<<"memory">>, Entry) > 0),
    ?assertMatch(#{<<"name">> := undefined, <<"class">> := <<"Slow">>}, entry(Unnamed)),
    Ids = [EntryId || #{<<"id">> := EntryId} <- bouy:inspect([])],
    ?assertEqual(lists:sort(Ids), Ids).

%% The actor stays listed as stopped, so a ref that escaped its constructor
%% keeps its label.
throwing_constructor_fails_spawn() ->
    Before = length(bouy:inspect([])),
    ?assertMatch(
        #{
            <<"_tag">> := <<"ActorFailed">>,
            <<"method">> := <<"constructor">>,
            <<"cause">> := #{<<"message">> := <<"cannot start">>}
        },
        thrown(fun() -> bouy:spawn([broken()]) end)
    ),
    ?assertMatch([#{<<"class">> := <<"Broken">>, <<"status">> := <<"stopped">>}], lists:nthtail(Before, bouy:inspect([]))).

self_returns_ref() ->
    Counter = bouy:spawn([counter()]),
    ?assertEqual(Counter, bouy_actor:call(Counter, <<"me">>, [])),
    ?assertMatch(#{<<"name">> := <<"Error">>}, thrown(fun() -> bouy:self([#{}]) end)).

%% A sender counts its request before it sends it in the counter of the
%% current start: a restart starts a new count of zero, since the mailbox of
%% the dead process is gone.
request_count_per_start() ->
    {'$ref', Id} = Counter = bouy:spawn([counter()]),
    {running, _, First, _} = bouy_registry:mode(Id),
    ?assertEqual(1, atomics:add_get(First, 1, 1)),
    <<"ActorFailed">> = tag(fun() -> bouy_actor:call(Counter, <<"fail">>, [<<"x">>]) end),
    0 = bouy_actor:call(Counter, <<"get">>, []),
    {running, _, Second, _} = bouy_registry:mode(Id),
    ?assertNotEqual(First, Second),
    ?assertEqual(0, atomics:get(Second, 1)),
    ?assertEqual(forgotten, bouy_registry:mode(999999999)).

%% Each recorded chunk is a 1 MiB binary outside the heap, which the limit
%% counts, so the actor dies at the collection after the eighth.
memory_limit_restarts() ->
    {'$ref', Id} = Leaky = bouy:spawn([counter(), #{<<"maxMemory">> => <<"8M">>, <<"args">> => [5]}]),
    Healthy = bouy:spawn([counter()]),
    {Failure, Text} = capture_stderr(fun() ->
        Failed = thrown(fun() -> record_chunks(Leaky, 64) end),
        %% The next call waits for the restart, which the keeper starts after the crash line.
        ?assertEqual(5, bouy_actor:call(Leaky, <<"get">>, [])),
        Failed
    end),
    Label = <<"Counter #", (integer_to_binary(Id))/binary>>,
    Message = <<Label/binary, " used more than its memory limit of 8388608 bytes">>,
    ?assertMatch(
        #{<<"_tag">> := <<"ActorOutOfMemory">>, <<"actor">> := Label, <<"limit">> := 8388608, <<"message">> := Message},
        Failure
    ),
    ?assertEqual(<<"bouy: ", Label/binary, " crashed: ActorOutOfMemory: ", Message/binary, "\n">>, Text),
    ?assertMatch(#{<<"restarts">> := 1, <<"status">> := <<"running">>}, entry(Leaky)),
    ?assertEqual(1, bouy_actor:call(Healthy, <<"inc">>, [])),
    ?assertMatch(#{<<"name">> := <<"TypeError">>}, thrown(fun() -> bouy:spawn([counter(), #{<<"maxMemory">> => <<"lots">>}]) end)),
    ?assertMatch(#{<<"name">> := <<"RangeError">>}, thrown(fun() -> bouy:spawn([counter(), #{<<"maxMemory">> => 16}]) end)).

child_memory_limit_restarts() ->
    #{<<"leaky">> := Leaky, <<"steady">> := Steady} = bouy:supervise([
        #{<<"children">> => #{
            <<"leaky">> => bouy:child([counter(), #{<<"maxMemory">> => 8 * 1024 * 1024}]),
            <<"steady">> => bouy:child([counter()])
        }}
    ]),
    3 = bouy_actor:call(Steady, <<"inc">>, [3]),
    {Tag, Text} = capture_stderr(fun() ->
        Thrown = tag(fun() -> record_chunks(Leaky, 64) end),
        await(fun() -> maps:get(<<"restarts">>, entry(Leaky)) =:= 1 end),
        ?assertEqual(0, bouy_actor:call(Leaky, <<"get">>, [])),
        Thrown
    end),
    ?assertEqual(<<"ActorOutOfMemory">>, Tag),
    ?assertMatch(<<"bouy: Counter leaky crashed: ActorOutOfMemory: ", _/binary>>, Text),
    ?assertEqual(3, bouy_actor:call(Steady, <<"get">>, [])).

record_chunks(Ref, Count) ->
    [bouy_actor:call(Ref, <<"record">>, [binary:copy(<<"x">>, 1024 * 1024)]) || _ <- lists:seq(1, Count)].
