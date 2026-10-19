-module(buoy).

%% The functions that JavaScript imports from "buoy". Each one takes the
%% argument list of the call, JavaScript values of the reference engine, and
%% runs in the realm of the caller: the top-level code or an actor.

-compile({no_auto_import, [spawn/1]}).

-export([spawn/1, cast/1, stop/1, inspect/1, supervise/1, child/1]).
-export([schedule/1, cancelSchedule/1, sleep/1, withTimeout/1, self/1]).
-export([heapStats/1, vmMemory/1, function/1]).

-include("buoy_ref.hrl").

-define(CAPACITY, 1024).
%% The longest timeout of one `receive ... after`.
-define(MAX_AFTER, 16#FFFFFFFF).
%% The functions of "buoy", with the length of each.
-define(FUNCTIONS, [{<<"spawn">>, 2}, {<<"cast">>, 1}, {<<"stop">>, 1}, {<<"inspect">>, 0},
                    {<<"supervise">>, 1}, {<<"child">>, 2}, {<<"schedule">>, 4},
                    {<<"cancelSchedule">>, 1}, {<<"sleep">>, 1}, {<<"withTimeout">>, 2},
                    {<<"self">>, 1}, {<<"heapStats">>, 0}, {<<"vmMemory">>, 0}]).

-type value() :: buoy_heap:value().

%% The function Name of "buoy" as a JavaScript value, for an import that the
%% code does not call at once, such as `const f = spawn`.
-spec function(binary()) -> value().
function(Name) ->
    case lists:keyfind(Name, 1, ?FUNCTIONS) of
        {Name, Length} ->
            Function = binary_to_existing_atom(Name),
            buoy_heap:function(fun(_This, Args) -> ?MODULE:Function(Args) end, Name, Length, #{});
        false ->
            undefined
    end.

%% A spawned actor is one process that buoy_keeper restarts. The actor that
%% a constructor starts belongs to the process of that constructor.
-spec spawn([value()]) -> {'$actor', pos_integer()}.
spawn([Class | Rest]) ->
    Options = options(Rest),
    #{id := Id} = Spec = spec(Class, Options, name(option(<<"name">>, Options))),
    Owner =
        case buoy_actor:constructing() of
            true -> buoy_actor:owner();
            false -> none
        end,
    case buoy_actor:start(Spec#{supervisor => whereis(buoy_keeper), group => alone, owner => Owner}) of
        ok -> {'$actor', Id};
        {error, Failure} -> buoy_actor:raise(Failure)
    end;
spawn([]) ->
    type_error(<<"spawn() needs an actor class">>).

-spec cast([value()]) -> {'$cast', pos_integer()}.
cast([{'$actor', Id} | _]) -> {'$cast', Id};
cast(_Arguments) -> type_error(<<"cast() needs an actor ref">>).

-spec stop([value()]) -> undefined.
stop([{'$actor', Id} | _]) ->
    ok = buoy_actor:stop(Id),
    undefined;
stop(_Arguments) ->
    type_error(<<"stop() needs an actor ref">>).

-spec inspect([value()]) -> value().
inspect(_Arguments) ->
    buoy_heap:new_array([entry(buoy_actor:snapshot(Actor)) || Actor <- buoy_registry:all()]).

entry(#{id := Id, name := Name, class := Class, status := Status, restarts := Restarts, mailbox := Mailbox, memory := Memory}) ->
    buoy_heap:object(?OBJECT_PROTO, [
        {<<"id">>, Id},
        {<<"name">>, text(Name)},
        {<<"class">>, text(Class)},
        {<<"status">>, atom_to_binary(Status)},
        {<<"restarts">>, Restarts},
        {<<"mailbox">>, Mailbox},
        {<<"memory">>, Memory}
    ]).

text(undefined) -> undefined;
text(Utf8) -> buoy_ref_string:from_utf8(Utf8).

%% Starts a group supervisor with one actor for each entry of `children`, in
%% key order, and returns an object of refs with the same keys.
-spec supervise([value()]) -> value().
supervise(Arguments) ->
    Options = options(Arguments),
    Flags = #{
        strategy => strategy(option(<<"strategy">>, Options)),
        intensity => max_restarts(option(<<"maxRestarts">>, Options)),
        period => period(option(<<"withinMs">>, Options))
    },
    Children = lists:sort([{buoy_ref_string:to_utf8(Key), Key, Child} || {Key, Child} <- children(option(<<"children">>, Options))]),
    Specs = [{Key, child_spec(Name, Child)} || {Name, Key, Child} <- Children],
    Group = new_group(Flags, [Id || {_, #{id := Id}} <- Specs]),
    buoy_heap:object(?OBJECT_PROTO, start_children(Group, Specs, [])).

start_children(_Group, [], Refs) ->
    lists:reverse(Refs);
start_children(Group, [{Key, #{id := Id} = Spec} | Rest], Refs) ->
    case buoy_actor:start(Spec#{supervisor => Group, group => tree}) of
        ok ->
            start_children(Group, Rest, [{Key, {'$actor', Id}} | Refs]);
        {error, Failure} ->
            %% The mark comes first: an actor that dies unmarked counts as out of memory.
            lists:foreach(fun({_, {'$actor', Started}}) -> buoy_registry:mark_stopped(Started) end, Refs),
            ok = buoy_sup:stop_group(Group),
            buoy_actor:raise(Failure)
    end.

%% A group that a constructor starts belongs to the actor of the
%% constructor: it stops when that actor restarts or stops, so a restart
%% does not leave the actors of the previous start running.
new_group(Flags, Ids) ->
    Group = buoy_sup:new_group(Flags),
    ok = buoy_keeper:watch_group(Group, Ids),
    case buoy_actor:constructing() of
        true -> ok = buoy_keeper:own(buoy_actor:owner(), {group, Group, Ids});
        false -> ok
    end,
    Group.

%% A child specification for supervise(): an object whose internal slots
%% hold the class and the options.
-spec child([value()]) -> value().
child([Class | Rest]) ->
    _ = home(Class, <<"child() needs an actor class">>),
    buoy_heap:new_exotic(actor_child, ?OBJECT_PROTO, {Class, options(Rest)});
child([]) ->
    type_error(<<"child() needs an actor class">>).

%% Casts Method to the actor once after `after` ms, or every `every` ms, from a
%% timer process that ends with the caller: the actor whose turn or
%% constructor calls schedule(), or the top-level code.
-spec schedule([value()]) -> {'$schedule', pid()}.
schedule([{'$actor', Id}, Timing, Method | Args]) when ?IS_STRING(Method) ->
    {Repeat, Ms} = timing(Timing),
    Term = buoy_actor:clone_out(buoy_heap:new_array(Args)),
    {_Actor, Pid} = Owner = buoy_actor:timer_owner(),
    {'$schedule', erlang:spawn(fun() -> timer({Owner, monitor(process, Pid)}, Repeat, Ms, Id, Method, Term) end)};
schedule(_Arguments) ->
    type_error(<<"schedule() needs a ref, { every } or { after }, and a method name">>).

%% Returns once the timer has stopped, so no cast of the schedule arrives
%% after a message that the caller sends next.
-spec cancelSchedule([value()]) -> undefined.
cancelSchedule([{'$schedule', Timer} | _]) when is_pid(Timer) ->
    Monitor = monitor(process, Timer),
    Timer ! {cancel, self(), Monitor},
    receive
        {Monitor, cancelled} -> true = demonitor(Monitor, [flush]);
        {'DOWN', Monitor, process, Timer, _} -> ok
    end,
    undefined;
cancelSchedule(_Arguments) ->
    type_error(<<"cancelSchedule() needs the handle that schedule() returned">>).

%% Blocks the calling process: no job of its realm runs meanwhile.
-spec sleep([value()]) -> undefined.
sleep([Ms | _]) when is_number(Ms) ->
    ok = wait(milliseconds(Ms)),
    undefined;
sleep(_Arguments) ->
    type_error(<<"sleep() needs a number of milliseconds">>).

wait(Ms) when Ms > ?MAX_AFTER ->
    ok = timer:sleep(?MAX_AFTER),
    wait(Ms - ?MAX_AFTER);
wait(Ms) ->
    timer:sleep(Ms).

-spec withTimeout([value()]) -> value().
withTimeout([Ms, Fun | _]) when is_number(Ms) ->
    case buoy_heap:is_callable(Fun) of
        true -> buoy_actor:with_timeout(milliseconds(Ms), Fun);
        false -> type_error(<<"withTimeout() needs a number of milliseconds and a function">>)
    end;
withTimeout(_Arguments) ->
    type_error(<<"withTimeout() needs a number of milliseconds and a function">>).

-spec self([value()]) -> {'$actor', pos_integer()}.
self(_Arguments) ->
    buoy_actor:current().

%% heapStats(): the heap and the collector of this realm, for the benchmarks.
-spec heapStats([value()]) -> value().
heapStats(_Arguments) ->
    buoy_ref:heap_stats().

%% vmMemory(): erlang:memory(total) and the process count.
-spec vmMemory([value()]) -> value().
vmMemory(_Arguments) ->
    buoy_ref:vm_memory().

%% The spec of a new actor of Class, from the options of spawn() or child().
spec(Class, Options, Name) ->
    {Module, ClassName} = home(Class, <<"spawn() needs an actor class">>),
    #{
        id => buoy_registry:allocate(),
        module => Module,
        home => {Module, ClassName},
        class => ClassName,
        args => buoy_actor:clone_out(buoy_heap:new_array(args(option(<<"args">>, Options)))),
        name => Name,
        mailbox => mailbox(option(<<"mailbox">>, Options)),
        restart => restart(option(<<"restart">>, Options)),
        max_memory => max_memory(option(<<"maxMemory">>, Options)),
        turn_timeout => turn_timeout(option(<<"turnTimeout">>, Options)),
        chain => buoy_actor:chain()
    }.

%% The module and the name of a module-level class, which the realm of an
%% actor can make again. Any other value is no actor class.
home(Class, Message) ->
    case buoy_heap:is_object(Class) andalso erlang:get({'$buoy_class_home', Class}) of
        {Module, Name} when is_atom(Module) -> {Module, Name};
        _ -> type_error(Message)
    end.

child_spec(Key, Child) ->
    case buoy_heap:is_object(Child) andalso buoy_heap:class_of(Child) of
        actor_child ->
            {Class, Options} = buoy_heap:slots(Child),
            spec(Class, Options, Key);
        _ ->
            type_error(<<"each child of supervise() must come from child()">>)
    end.

options([]) -> undefined;
options([undefined | _]) -> undefined;
options([Options | _]) ->
    case buoy_heap:is_object(Options) of
        true -> Options;
        false -> type_error(<<"the options must be an object">>)
    end.

option(_Key, undefined) -> undefined;
option(Key, Options) -> buoy_heap:get(Options, Key).

args(undefined) ->
    [];
args(Args) ->
    case buoy_heap:is_object(Args) andalso buoy_heap:class_of(Args) =:= array of
        true -> buoy_heap:array_items(Args);
        false -> type_error(<<"args must be an array">>)
    end.

name(undefined) ->
    undefined;
name(Name) when ?IS_STRING(Name) ->
    buoy_ref_string:to_utf8(Name);
name(_Name) ->
    type_error(<<"name must be a string">>).

mailbox(undefined) ->
    {?CAPACITY, backpressure};
mailbox(Mailbox) ->
    case buoy_heap:is_object(Mailbox) of
        true -> {capacity(option(<<"capacity">>, Mailbox)), overflow(option(<<"overflow">>, Mailbox))};
        false -> type_error(<<"mailbox must be an object">>)
    end.

capacity(undefined) -> ?CAPACITY;
capacity(Capacity) ->
    case integer(Capacity) of
        N when is_integer(N), N > 0 -> N;
        _ -> type_error(<<"mailbox.capacity must be a positive integer">>)
    end.

%% A number with no fraction, such as 64.0 from JSON or 0.5 * 4, is an
%% integer, as Number.isInteger says.
integer(F) when is_float(F), F == trunc(F) -> trunc(F);
integer(N) -> N.

overflow(undefined) -> backpressure;
overflow(<<"backpressure">>) -> backpressure;
overflow(<<"reject">>) -> reject;
overflow(_Overflow) -> type_error(<<"mailbox.overflow must be \"backpressure\" or \"reject\"">>).

restart(undefined) -> transient;
restart(<<"permanent">>) -> permanent;
restart(<<"transient">>) -> transient;
restart(<<"temporary">>) -> temporary;
restart(_Restart) ->
    type_error(<<"restart must be \"permanent\", \"transient\", or \"temporary\"">>).

%% The longest turn of the actor in ms, or `infinity`.
turn_timeout(undefined) -> infinity;
turn_timeout(Ms) ->
    case integer(Ms) of
        N when is_integer(N), N > 0 -> N;
        _ -> type_error(<<"turnTimeout must be a positive integer number of milliseconds">>)
    end.

%% Bytes, or a string with a K, M, G, or T suffix, as BUOY_MAX_MEMORY takes. The limit
%% must leave room for the smallest heap of a process.
max_memory(undefined) ->
    infinity;
max_memory(Value) ->
    {min_heap_size, Words} = erlang:system_info(min_heap_size),
    Least = Words * erlang:system_info(wordsize),
    case bytes(Value) of
        {ok, Bytes} when Bytes >= Least -> Bytes;
        {ok, _Bytes} -> buoy_heap:throw_error('RangeError', <<"maxMemory must be at least ", (integer_to_binary(Least))/binary, " bytes">>);
        error -> type_error(<<"maxMemory must be a number of bytes or a string such as \"64M\"">>)
    end.

bytes(Text) when ?IS_STRING(Text) ->
    buoy_guard:bytes(unicode:characters_to_list(buoy_ref_string:to_utf8(Text)));
bytes(Number) when is_number(Number) ->
    case integer(Number) of
        N when is_integer(N), N > 0 -> {ok, N};
        _ -> error
    end;
bytes(_Value) ->
    error.

strategy(undefined) -> one_for_one;
strategy(<<"one-for-one">>) -> one_for_one;
strategy(<<"one-for-all">>) -> one_for_all;
strategy(<<"rest-for-one">>) -> rest_for_one;
strategy(_Strategy) ->
    type_error(<<"strategy must be \"one-for-one\", \"one-for-all\", or \"rest-for-one\"">>).

%% The own enumerable string keys of `children` and their values.
children(undefined) ->
    [];
children(Children) ->
    case buoy_heap:is_object(Children) of
        true -> [{Key, buoy_heap:get(Children, Key)} || Key <- buoy_heap:enumerable_keys(Children), ?IS_STRING(Key)];
        false -> type_error(<<"children must be an object">>)
    end.

max_restarts(undefined) -> 3;
max_restarts(Count) ->
    case integer(Count) of
        N when is_integer(N), N >= 0 -> N;
        _ -> type_error(<<"maxRestarts must be a non-negative integer">>)
    end.

%% OTP counts the restart period in whole seconds, so withinMs rounds up.
period(undefined) -> 5;
period(Ms) when is_number(Ms), Ms > 0 -> max(1, ceil(Ms / 1000));
period(_Ms) -> type_error(<<"withinMs must be a positive number">>).

timing(Timing) ->
    case buoy_heap:is_object(Timing) of
        true -> timing(buoy_heap:get(Timing, <<"every">>), buoy_heap:get(Timing, <<"after">>));
        false -> timing(undefined, undefined)
    end.

timing(Every, _After) when is_number(Every) -> {every, max(1, milliseconds(Every))};
timing(_Every, After) when is_number(After) -> {once, milliseconds(After)};
timing(_Every, _After) -> type_error(<<"schedule() needs { every: ms } or { after: ms }">>).

milliseconds(Ms) when is_integer(Ms) -> max(0, Ms);
milliseconds(Ms) -> max(0, trunc(Ms)).

%% The timer of one schedule() call. It ends when it is cancelled, after its
%% one `after` cast, when the actor has stopped, or when its owner ends. A
%% full mailbox skips a cast, whatever the overflow of the mailbox is.
timer({Owner, OwnerMonitor} = Owned, Repeat, Ms, Id, Method, Args) ->
    case due(OwnerMonitor, Ms) of
        {cancel, From, Monitor} ->
            From ! {Monitor, cancelled};
        ended ->
            ok;
        due ->
            case {Repeat, buoy_actor:offer(Id, Method, Args, Owner)} of
                {every, Delivery} when Delivery =/= stopped -> timer(Owned, Repeat, Ms, Id, Method, Args);
                _Done -> ok
            end
    end.

%% Waits Ms, which may exceed the longest timeout of one `receive`.
due(OwnerMonitor, Ms) ->
    Chunk = min(Ms, ?MAX_AFTER),
    receive
        {cancel, From, Monitor} -> {cancel, From, Monitor};
        {'DOWN', OwnerMonitor, process, _, _} -> ended
    after Chunk ->
        case Ms - Chunk of
            0 -> due;
            Rest -> due(OwnerMonitor, Rest)
        end
    end.

-spec type_error(binary()) -> no_return().
type_error(Message) ->
    buoy_heap:throw_error('TypeError', Message).
