-module(richards_local).

%% Richards as a typed compilation after escape analysis. No object of a run escapes
%% runRichards, so the compiler can drop the heap: the scheduler, a singleton, becomes the
%% fields of one state record that every call threads through, and the task control
%% blocks, the tasks, and the packets become tuples indexed by a reference that is known
%% at compile time or carried in a field. A field write rebuilds one small tuple and the
%% tuple that holds it, and nothing touches the process dictionary.

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

%% A task control block is {Link, Id, Priority, Queue, State}, a packet is
%% {Link, Id, Kind, A1, A2}, and a task is {idle, V1, Count}, {device, V1},
%% {worker, V1, V2}, or {handler, V1, V2}. A link, a queue, and `current` hold the index
%% of a block or a packet, or null.
-record(st, {
    queue_count = 0 :: integer(),
    hold_count = 0 :: integer(),
    blocks :: tuple(),
    list = null :: pos_integer() | null,
    current = null :: pos_integer() | null,
    current_id = 0 :: integer(),
    tcbs :: tuple(),
    tasks :: tuple(),
    packets :: tuple()
}).

-spec main([string()]) -> no_return().
main(Args) ->
    speed_harness:bench(<<"richards">>, 100, fun iteration/1, Args).

iteration(Size) -> iteration(Size, 0).

iteration(0, Check) -> Check;
iteration(Size, Check) -> iteration(Size - 1, Check + run()).

-spec run() -> integer().
run() ->
    Data = {0, 0, 0, 0},
    Packets = {
        {null, ?ID_WORKER, ?KIND_WORK, 0, Data},
        {1, ?ID_WORKER, ?KIND_WORK, 0, Data},
        {null, ?ID_DEVICE_A, ?KIND_DEVICE, 0, Data},
        {3, ?ID_DEVICE_A, ?KIND_DEVICE, 0, Data},
        {4, ?ID_DEVICE_A, ?KIND_DEVICE, 0, Data},
        {null, ?ID_DEVICE_B, ?KIND_DEVICE, 0, Data},
        {6, ?ID_DEVICE_B, ?KIND_DEVICE, 0, Data},
        {7, ?ID_DEVICE_B, ?KIND_DEVICE, 0, Data}
    },
    Empty = erlang:make_tuple(6, null),
    St0 = #st{blocks = Empty, tcbs = Empty, tasks = Empty, packets = Packets},
    St1 = set_running(add_task(?ID_IDLE, 0, null, {idle, 1, ?COUNT}, St0)),
    St2 = add_task(?ID_WORKER, 1000, 2, {worker, ?ID_HANDLER_A, 0}, St1),
    St3 = add_task(?ID_HANDLER_A, 2000, 5, {handler, null, null}, St2),
    St4 = add_task(?ID_HANDLER_B, 3000, 8, {handler, null, null}, St3),
    St5 = add_task(?ID_DEVICE_A, 4000, null, {device, null}, St4),
    St6 = add_task(?ID_DEVICE_B, 5000, null, {device, null}, St5),
    #st{queue_count = QueueCount, hold_count = HoldCount} = schedule(St6),
    case {QueueCount, HoldCount} of
        {?EXPECTED_QUEUE_COUNT, ?EXPECTED_HOLD_COUNT} -> QueueCount + HoldCount;
        _ -> error({richards, QueueCount, HoldCount})
    end.

add_task(Id, Priority, Queue, Task, #st{list = List} = St) ->
    State =
        case Queue of
            null -> ?STATE_SUSPENDED;
            _ -> ?STATE_SUSPENDED_RUNNABLE
        end,
    Ref = Id + 1,
    St#st{
        tcbs = setelement(Ref, St#st.tcbs, {List, Id, Priority, Queue, State}),
        tasks = setelement(Ref, St#st.tasks, Task),
        blocks = setelement(Id + 1, St#st.blocks, Ref),
        list = Ref,
        current = Ref
    }.

set_running(#st{current = Current, tcbs = Tcbs} = St) ->
    {Link, Id, Priority, Queue, _} = element(Current, Tcbs),
    St#st{tcbs = setelement(Current, Tcbs, {Link, Id, Priority, Queue, ?STATE_RUNNING})}.

schedule(St) -> schedule_loop(St#st{current = St#st.list}).

schedule_loop(#st{current = null} = St) ->
    St;
schedule_loop(#st{current = Current, tcbs = Tcbs} = St) ->
    {Link, Id, _, _, State} = element(Current, Tcbs),
    case (State band ?STATE_HELD) =/= 0 orelse State =:= ?STATE_SUSPENDED of
        true ->
            schedule_loop(St#st{current = Link});
        false ->
            {Next, St1} = tcb_run(Current, St#st{current_id = Id}),
            schedule_loop(St1#st{current = Next})
    end.

tcb_run(Ref, #st{tcbs = Tcbs, packets = Packets} = St) ->
    case element(Ref, Tcbs) of
        {Link, Id, Priority, First, ?STATE_SUSPENDED_RUNNABLE} when First =/= null ->
            Next = element(1, element(First, Packets)),
            State =
                case Next of
                    null -> ?STATE_RUNNING;
                    _ -> ?STATE_RUNNABLE
                end,
            Tcbs1 = setelement(Ref, Tcbs, {Link, Id, Priority, Next, State}),
            task_run(Ref, First, St#st{tcbs = Tcbs1});
        _ ->
            task_run(Ref, null, St)
    end.

task_run(Ref, Packet, St) ->
    case element(Ref, St#st.tasks) of
        {idle, V1, Count} -> idle_run(Ref, V1, Count, St);
        {device, V1} -> device_run(Ref, V1, Packet, St);
        {worker, V1, V2} -> worker_run(Ref, V1, V2, Packet, St);
        {handler, V1, V2} -> handler_run(Ref, V1, V2, Packet, St)
    end.

set_task(Ref, Task, St) -> St#st{tasks = setelement(Ref, St#st.tasks, Task)}.

release(Id, #st{blocks = Blocks, tcbs = Tcbs, current = Current} = St) ->
    case element(Id + 1, Blocks) of
        null ->
            {null, St};
        Ref ->
            {Link, TcbId, Priority, Queue, State} = element(Ref, Tcbs),
            Tcbs1 = setelement(Ref, Tcbs, {Link, TcbId, Priority, Queue, State band ?STATE_NOT_HELD}),
            Next =
                case Priority > element(3, element(Current, Tcbs1)) of
                    true -> Ref;
                    false -> Current
                end,
            {Next, St#st{tcbs = Tcbs1}}
    end.

hold_current(#st{hold_count = HoldCount, current = Current, tcbs = Tcbs} = St) ->
    {Link, Id, Priority, Queue, State} = element(Current, Tcbs),
    Tcbs1 = setelement(Current, Tcbs, {Link, Id, Priority, Queue, State bor ?STATE_HELD}),
    {Link, St#st{hold_count = HoldCount + 1, tcbs = Tcbs1}}.

suspend_current(#st{current = Current, tcbs = Tcbs} = St) ->
    {Link, Id, Priority, Queue, State} = element(Current, Tcbs),
    Tcbs1 = setelement(Current, Tcbs, {Link, Id, Priority, Queue, State bor ?STATE_SUSPENDED}),
    {Current, St#st{tcbs = Tcbs1}}.

queue(Packet, #st{blocks = Blocks, packets = Packets, current_id = CurrentId} = St) ->
    {_, Id, Kind, A1, A2} = element(Packet, Packets),
    case element(Id + 1, Blocks) of
        null ->
            {null, St};
        Target ->
            Packets1 = setelement(Packet, Packets, {null, CurrentId, Kind, A1, A2}),
            St1 = St#st{queue_count = St#st.queue_count + 1, packets = Packets1},
            check_priority_add(Target, Packet, St1)
    end.

check_priority_add(Ref, Packet, #st{tcbs = Tcbs, current = Task} = St) ->
    case element(Ref, Tcbs) of
        {Link, Id, Priority, null, State} ->
            Tcbs1 = setelement(Ref, Tcbs, {Link, Id, Priority, Packet, State bor ?STATE_RUNNABLE}),
            Next =
                case Priority > element(3, element(Task, Tcbs1)) of
                    true -> Ref;
                    false -> Task
                end,
            {Next, St#st{tcbs = Tcbs1}};
        {Link, Id, Priority, Queue, State} ->
            {Queue1, St1} = add_to(Packet, Queue, St),
            Tcbs1 = setelement(Ref, St1#st.tcbs, {Link, Id, Priority, Queue1, State}),
            {Task, St1#st{tcbs = Tcbs1}}
    end.

add_to(Packet, Queue, #st{packets = Packets} = St) ->
    Packets1 = set_link(Packet, null, Packets),
    case Queue of
        null -> {Packet, St#st{packets = Packets1}};
        _ -> {Queue, St#st{packets = append(Queue, Packet, Packets1)}}
    end.

append(Next, Packet, Packets) ->
    case element(1, element(Next, Packets)) of
        null -> set_link(Next, Packet, Packets);
        Peek -> append(Peek, Packet, Packets)
    end.

set_link(Packet, Link, Packets) ->
    setelement(Packet, Packets, setelement(1, element(Packet, Packets), Link)).

idle_run(Ref, V1, Count, St) ->
    case Count - 1 of
        0 -> hold_current(set_task(Ref, {idle, V1, 0}, St));
        Left when V1 band 1 =:= 0 -> release(?ID_DEVICE_A, set_task(Ref, {idle, V1 bsr 1, Left}, St));
        Left -> release(?ID_DEVICE_B, set_task(Ref, {idle, (V1 bsr 1) bxor 16#D008, Left}, St))
    end.

device_run(_Ref, null, null, St) -> suspend_current(St);
device_run(Ref, Pending, null, St) -> queue(Pending, set_task(Ref, {device, null}, St));
device_run(Ref, _V1, Packet, St) -> hold_current(set_task(Ref, {device, Packet}, St)).

worker_run(_Ref, _V1, _V2, null, St) ->
    suspend_current(St);
worker_run(Ref, V1, V2, Packet, #st{packets = Packets} = St) ->
    Handler =
        case V1 of
            ?ID_HANDLER_A -> ?ID_HANDLER_B;
            _ -> ?ID_HANDLER_A
        end,
    {Link, _, Kind, _, Data} = element(Packet, Packets),
    {Next, Data1} = fill(V2, Data, 1),
    Packets1 = setelement(Packet, Packets, {Link, Handler, Kind, 0, Data1}),
    queue(Packet, set_task(Ref, {worker, Handler, Next}, St#st{packets = Packets1})).

fill(V2, Data, I) when I > 4 -> {V2, Data};
fill(V2, Data, I) ->
    Next =
        case V2 + 1 of
            Wrapped when Wrapped > 26 -> 1;
            Value -> Value
        end,
    fill(Next, setelement(I, Data, Next), I + 1).

handler_run(Ref, V1, V2, null, St) ->
    handler_step(Ref, V1, V2, St);
handler_run(Ref, V1, V2, Packet, St) ->
    case element(3, element(Packet, St#st.packets)) of
        ?KIND_WORK ->
            {Work, St1} = add_to(Packet, V1, St),
            handler_step(Ref, Work, V2, St1);
        _ ->
            {Device, St1} = add_to(Packet, V2, St),
            handler_step(Ref, V1, Device, St1)
    end.

handler_step(Ref, null, Device, St) ->
    suspend_current(set_task(Ref, {handler, null, Device}, St));
handler_step(Ref, Work, Device, #st{packets = Packets} = St) ->
    {WorkLink, WorkId, WorkKind, Count, WorkData} = element(Work, Packets),
    if
        Count < 4, Device =:= null ->
            suspend_current(set_task(Ref, {handler, Work, Device}, St));
        Count < 4 ->
            {DeviceLink, DeviceId, DeviceKind, _, DeviceData} = element(Device, Packets),
            Packets1 = setelement(
                Device, Packets, {DeviceLink, DeviceId, DeviceKind, element(Count + 1, WorkData), DeviceData}
            ),
            Packets2 = setelement(Work, Packets1, {WorkLink, WorkId, WorkKind, Count + 1, WorkData}),
            queue(Device, set_task(Ref, {handler, Work, DeviceLink}, St#st{packets = Packets2}));
        true ->
            queue(Work, set_task(Ref, {handler, WorkLink, Device}, St))
    end.
