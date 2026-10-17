-module(richards_heap).

%% Richards as a typed compilation with a heap: every object is a tuple of its known shape,
%% stored under an integer reference in the process dictionary. A field read is one
%% `get` and one `element` with an index that the compiler knows. A field write is a
%% `put` of the tuple with `setelement`. A monomorphic method call is a direct local call,
%% and `task.run` dispatches on the class tag of the record. Each run resets the
%% allocator, which stands in for the collector, because no object outlives a run.

-export([main/1, run/0]).

-define(COUNT, 1000).
-define(EXPECTED_QUEUE_COUNT, 2322).
-define(EXPECTED_HOLD_COUNT, 928).

-define(ID_IDLE, 0).
-define(ID_WORKER, 1).
-define(ID_HANDLER_A, 2).
-define(ID_HANDLER_B, 3).
-define(ID_DEVICE_A, 4).
-define(ID_DEVICE_B, 5).

-define(KIND_DEVICE, 0).
-define(KIND_WORK, 1).

-define(STATE_RUNNING, 0).
-define(STATE_RUNNABLE, 1).
-define(STATE_SUSPENDED, 2).
-define(STATE_HELD, 4).
-define(STATE_SUSPENDED_RUNNABLE, 3).
-define(STATE_NOT_HELD, -5).

%% Scheduler: {scheduler, QueueCount, HoldCount, Blocks, List, CurrentTcb, CurrentId}
-define(S_QUEUE_COUNT, 2).
-define(S_HOLD_COUNT, 3).
-define(S_BLOCKS, 4).
-define(S_LIST, 5).
-define(S_CURRENT, 6).
-define(S_CURRENT_ID, 7).
%% TaskControlBlock: {tcb, Link, Id, Priority, Queue, Task, State}
-define(T_LINK, 2).
-define(T_ID, 3).
-define(T_PRIORITY, 4).
-define(T_QUEUE, 5).
-define(T_TASK, 6).
-define(T_STATE, 7).
%% Packet: {packet, Link, Id, Kind, A1, A2}
-define(P_LINK, 2).
-define(P_ID, 3).
-define(P_KIND, 4).
-define(P_A1, 5).
-define(P_A2, 6).

-define(GET(Ref, Field), element(Field, get(Ref))).
%% A function, not a macro: the new value must be computed before the record is read.
-define(SET(Ref, Field, Value), set(Ref, Field, Value)).
-compile({inline, [set/3]}).

-spec main([string()]) -> no_return().
main(Args) ->
    speed_harness:bench(<<"richards">>, 100, fun iteration/1, Args).

iteration(Size) -> iteration(Size, 0).

iteration(0, Check) -> Check;
iteration(Size, Check) -> iteration(Size - 1, Check + run()).

set(Ref, Field, Value) -> put(Ref, setelement(Field, get(Ref), Value)).

new(Record) ->
    Ref = get(next),
    put(next, Ref + 1),
    put(Ref, Record),
    Ref.

new_packet(Link, Id, Kind) -> new({packet, Link, Id, Kind, 0, {0, 0, 0, 0}}).

-spec run() -> integer().
run() ->
    put(next, 1),
    S = new({scheduler, 0, 0, {null, null, null, null, null, null}, null, null, 0}),
    add_task(S, ?ID_IDLE, 0, null, new({idle, S, 1, ?COUNT})),
    tcb_set_running(?GET(S, ?S_CURRENT)),
    W1 = new_packet(null, ?ID_WORKER, ?KIND_WORK),
    W2 = new_packet(W1, ?ID_WORKER, ?KIND_WORK),
    add_task(S, ?ID_WORKER, 1000, W2, new({worker, S, ?ID_HANDLER_A, 0})),
    A1 = new_packet(null, ?ID_DEVICE_A, ?KIND_DEVICE),
    A2 = new_packet(A1, ?ID_DEVICE_A, ?KIND_DEVICE),
    A3 = new_packet(A2, ?ID_DEVICE_A, ?KIND_DEVICE),
    add_task(S, ?ID_HANDLER_A, 2000, A3, new({handler, S, null, null})),
    B1 = new_packet(null, ?ID_DEVICE_B, ?KIND_DEVICE),
    B2 = new_packet(B1, ?ID_DEVICE_B, ?KIND_DEVICE),
    B3 = new_packet(B2, ?ID_DEVICE_B, ?KIND_DEVICE),
    add_task(S, ?ID_HANDLER_B, 3000, B3, new({handler, S, null, null})),
    add_task(S, ?ID_DEVICE_A, 4000, null, new({device, S, null})),
    add_task(S, ?ID_DEVICE_B, 5000, null, new({device, S, null})),
    schedule(S),
    {scheduler, QueueCount, HoldCount, _, _, _, _} = get(S),
    case {QueueCount, HoldCount} of
        {?EXPECTED_QUEUE_COUNT, ?EXPECTED_HOLD_COUNT} -> QueueCount + HoldCount;
        _ -> error({richards, QueueCount, HoldCount})
    end.

add_task(S, Id, Priority, Queue, Task) ->
    State =
        case Queue of
            null -> ?STATE_SUSPENDED;
            _ -> ?STATE_SUSPENDED_RUNNABLE
        end,
    Tcb = new({tcb, ?GET(S, ?S_LIST), Id, Priority, Queue, Task, State}),
    ?SET(S, ?S_CURRENT, Tcb),
    ?SET(S, ?S_LIST, Tcb),
    ?SET(S, ?S_BLOCKS, setelement(Id + 1, ?GET(S, ?S_BLOCKS), Tcb)).

schedule(S) ->
    ?SET(S, ?S_CURRENT, ?GET(S, ?S_LIST)),
    schedule_loop(S).

schedule_loop(S) ->
    case ?GET(S, ?S_CURRENT) of
        null ->
            ok;
        Tcb ->
            case tcb_is_held_or_suspended(Tcb) of
                true ->
                    ?SET(S, ?S_CURRENT, ?GET(Tcb, ?T_LINK));
                false ->
                    ?SET(S, ?S_CURRENT_ID, ?GET(Tcb, ?T_ID)),
                    ?SET(S, ?S_CURRENT, tcb_run(Tcb))
            end,
            schedule_loop(S)
    end.

release(S, Id) ->
    case element(Id + 1, ?GET(S, ?S_BLOCKS)) of
        null ->
            null;
        Tcb ->
            ?SET(Tcb, ?T_STATE, ?GET(Tcb, ?T_STATE) band ?STATE_NOT_HELD),
            Current = ?GET(S, ?S_CURRENT),
            case ?GET(Tcb, ?T_PRIORITY) > ?GET(Current, ?T_PRIORITY) of
                true -> Tcb;
                false -> Current
            end
    end.

hold_current(S) ->
    ?SET(S, ?S_HOLD_COUNT, ?GET(S, ?S_HOLD_COUNT) + 1),
    Current = ?GET(S, ?S_CURRENT),
    ?SET(Current, ?T_STATE, ?GET(Current, ?T_STATE) bor ?STATE_HELD),
    ?GET(Current, ?T_LINK).

suspend_current(S) ->
    Current = ?GET(S, ?S_CURRENT),
    ?SET(Current, ?T_STATE, ?GET(Current, ?T_STATE) bor ?STATE_SUSPENDED),
    Current.

queue(S, Packet) ->
    case element(?GET(Packet, ?P_ID) + 1, ?GET(S, ?S_BLOCKS)) of
        null ->
            null;
        Target ->
            ?SET(S, ?S_QUEUE_COUNT, ?GET(S, ?S_QUEUE_COUNT) + 1),
            ?SET(Packet, ?P_LINK, null),
            ?SET(Packet, ?P_ID, ?GET(S, ?S_CURRENT_ID)),
            tcb_check_priority_add(Target, ?GET(S, ?S_CURRENT), Packet)
    end.

tcb_set_running(Tcb) -> ?SET(Tcb, ?T_STATE, ?STATE_RUNNING).

tcb_is_held_or_suspended(Tcb) ->
    State = ?GET(Tcb, ?T_STATE),
    (State band ?STATE_HELD) =/= 0 orelse State =:= ?STATE_SUSPENDED.

tcb_run(Tcb) ->
    Packet =
        case ?GET(Tcb, ?T_STATE) =:= ?STATE_SUSPENDED_RUNNABLE andalso ?GET(Tcb, ?T_QUEUE) of
            false ->
                null;
            null ->
                null;
            First ->
                Next = ?GET(First, ?P_LINK),
                ?SET(Tcb, ?T_QUEUE, Next),
                State =
                    case Next of
                        null -> ?STATE_RUNNING;
                        _ -> ?STATE_RUNNABLE
                    end,
                ?SET(Tcb, ?T_STATE, State),
                First
        end,
    task_run(?GET(Tcb, ?T_TASK), Packet).

tcb_check_priority_add(Tcb, Task, Packet) ->
    case ?GET(Tcb, ?T_QUEUE) of
        null ->
            ?SET(Tcb, ?T_QUEUE, Packet),
            ?SET(Tcb, ?T_STATE, ?GET(Tcb, ?T_STATE) bor ?STATE_RUNNABLE),
            case ?GET(Tcb, ?T_PRIORITY) > ?GET(Task, ?T_PRIORITY) of
                true -> Tcb;
                false -> Task
            end;
        Queue ->
            ?SET(Tcb, ?T_QUEUE, packet_add_to(Packet, Queue)),
            Task
    end.

packet_add_to(Packet, Queue) ->
    ?SET(Packet, ?P_LINK, null),
    case Queue of
        null ->
            Packet;
        _ ->
            append(Queue, Packet),
            Queue
    end.

append(Next, Packet) ->
    case ?GET(Next, ?P_LINK) of
        null -> ?SET(Next, ?P_LINK, Packet);
        Peek -> append(Peek, Packet)
    end.

task_run(Task, Packet) ->
    case get(Task) of
        {idle, S, V1, Count} -> idle_run(Task, S, V1, Count);
        {device, S, V1} -> device_run(Task, S, V1, Packet);
        {worker, S, V1, V2} -> worker_run(Task, S, V1, V2, Packet);
        {handler, S, V1, V2} -> handler_run(Task, S, V1, V2, Packet)
    end.

idle_run(Task, S, V1, Count) ->
    case Count - 1 of
        0 ->
            put(Task, {idle, S, V1, 0}),
            hold_current(S);
        Left when V1 band 1 =:= 0 ->
            put(Task, {idle, S, V1 bsr 1, Left}),
            release(S, ?ID_DEVICE_A);
        Left ->
            put(Task, {idle, S, (V1 bsr 1) bxor 16#D008, Left}),
            release(S, ?ID_DEVICE_B)
    end.

device_run(Task, S, null, null) ->
    _ = Task,
    suspend_current(S);
device_run(Task, S, Pending, null) ->
    put(Task, {device, S, null}),
    queue(S, Pending);
device_run(Task, S, _V1, Packet) ->
    put(Task, {device, S, Packet}),
    hold_current(S).

worker_run(_Task, S, _V1, _V2, null) ->
    suspend_current(S);
worker_run(Task, S, V1, V2, Packet) ->
    Handler =
        case V1 of
            ?ID_HANDLER_A -> ?ID_HANDLER_B;
            _ -> ?ID_HANDLER_A
        end,
    ?SET(Packet, ?P_ID, Handler),
    ?SET(Packet, ?P_A1, 0),
    {Next, Data} = fill(V2, ?GET(Packet, ?P_A2), 1),
    ?SET(Packet, ?P_A2, Data),
    put(Task, {worker, S, Handler, Next}),
    queue(S, Packet).

fill(V2, Data, I) when I > 4 -> {V2, Data};
fill(V2, Data, I) ->
    Next =
        case V2 + 1 of
            Wrapped when Wrapped > 26 -> 1;
            Value -> Value
        end,
    fill(Next, setelement(I, Data, Next), I + 1).

handler_run(Task, S, V1, V2, Packet) ->
    {Work, Device} =
        case Packet of
            null ->
                {V1, V2};
            _ ->
                case ?GET(Packet, ?P_KIND) of
                    ?KIND_WORK -> {packet_add_to(Packet, V1), V2};
                    _ -> {V1, packet_add_to(Packet, V2)}
                end
        end,
    handler_step(Task, S, Work, Device).

handler_step(Task, S, null, Device) ->
    put(Task, {handler, S, null, Device}),
    suspend_current(S);
handler_step(Task, S, Work, Device) ->
    Count = ?GET(Work, ?P_A1),
    case Count < 4 of
        true when Device =:= null ->
            put(Task, {handler, S, Work, Device}),
            suspend_current(S);
        true ->
            put(Task, {handler, S, Work, ?GET(Device, ?P_LINK)}),
            ?SET(Device, ?P_A1, element(Count + 1, ?GET(Work, ?P_A2))),
            ?SET(Work, ?P_A1, Count + 1),
            queue(S, Device);
        false ->
            put(Task, {handler, S, ?GET(Work, ?P_LINK), Device}),
            queue(S, Work)
    end.
