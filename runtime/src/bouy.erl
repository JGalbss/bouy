-module(bouy).

%% The functions that TypeScript imports from "bouy". Each one takes the
%% argument list of the call and JavaScript values: an options object is a map
%% with binary keys, or `undefined`.

-compile({no_auto_import, [spawn/1]}).

-export([spawn/1, cast/1, stop/1, inspect/1, supervise/1, child/1]).
-export([schedule/1, cancelSchedule/1, sleep/1, withTimeout/1, self/1]).

-define(CAPACITY, 1024).
%% The longest timeout of one `receive ... after`.
-define(MAX_AFTER, 16#FFFFFFFF).

-type ref() :: {'$ref', pos_integer()}.
-type class() :: {'$class', module(), binary()}.
-type options() :: #{binary() => term()}.

%% A spawned actor is one process that bouy_keeper restarts. The actor that
%% a constructor starts belongs to the process of that constructor.
-spec spawn([term()]) -> ref().
spawn([Class | Rest]) ->
    Options = options(Rest),
    #{id := Id} = Spec = spec(Class, Options, name(option(<<"name">>, Options))),
    Owner =
        case bouy_actor:constructing() of
            true -> bouy_actor:owner();
            false -> none
        end,
    case bouy_actor:start(Spec#{supervisor => whereis(bouy_keeper), group => alone, owner => Owner}) of
        ok -> {'$ref', Id};
        {error, Failure} -> raise(Failure)
    end;
spawn([]) ->
    type_error(<<"spawn() needs an actor class">>).

-spec cast([term()]) -> {'$cast', pos_integer()}.
cast([{'$ref', Id} | _]) -> {'$cast', Id};
cast(_Arguments) -> type_error(<<"cast() needs an actor ref">>).

-spec stop([term()]) -> undefined.
stop([{'$ref', Id} | _]) ->
    ok = bouy_actor:stop(Id),
    undefined;
stop(_Arguments) ->
    type_error(<<"stop() needs an actor ref">>).

-spec inspect([term()]) -> [#{binary() => term()}].
inspect(_Arguments) ->
    [bouy_actor:snapshot(Actor) || Actor <- bouy_registry:all()].

%% Starts a group supervisor with one actor for each entry of `children`, in
%% key order, and returns an object of refs with the same keys.
-spec supervise([term()]) -> #{binary() => ref()}.
supervise(Arguments) ->
    Options = options(Arguments),
    Flags = #{
        strategy => strategy(option(<<"strategy">>, Options)),
        intensity => max_restarts(option(<<"maxRestarts">>, Options)),
        period => period(option(<<"withinMs">>, Options))
    },
    Children = lists:sort(maps:to_list(children(option(<<"children">>, Options)))),
    Specs = [{Key, child_spec(Key, Child)} || {Key, Child} <- Children],
    Group = new_group(Flags, [Id || {_, #{id := Id}} <- Specs]),
    start_children(Group, Specs, #{}).

start_children(_Group, [], Refs) ->
    Refs;
start_children(Group, [{Key, #{id := Id} = Spec} | Rest], Refs) ->
    case bouy_actor:start(Spec#{supervisor => Group, group => tree}) of
        ok ->
            start_children(Group, Rest, Refs#{Key => {'$ref', Id}});
        {error, Failure} ->
            ok = bouy_sup:stop_group(Group),
            lists:foreach(
                fun({'$ref', Started}) -> bouy_registry:mark_stopped(Started) end,
                maps:values(Refs)
            ),
            raise(Failure)
    end.

%% A group that a constructor starts belongs to the actor of the
%% constructor: it stops when that actor restarts or stops, so a restart
%% does not leave the actors of the previous start running.
new_group(Flags, Ids) ->
    Group = bouy_sup:new_group(Flags),
    ok = bouy_keeper:watch_group(Group, Ids),
    case bouy_actor:constructing() of
        true -> ok = bouy_keeper:own(bouy_actor:owner(), {group, Group, Ids});
        false -> ok
    end,
    Group.

-spec child([term()]) -> {'$child', class(), options()}.
child([{'$class', Module, Name} = Class | Rest]) when is_atom(Module), is_binary(Name) ->
    {'$child', Class, options(Rest)};
child(_Arguments) ->
    type_error(<<"child() needs an actor class">>).

%% Casts Method to the actor once after `after` ms, or every `every` ms, from a
%% timer process that ends with the caller: the actor whose turn or
%% constructor calls schedule(), or the top-level code.
-spec schedule([term()]) -> {'$schedule', pid()}.
schedule([Ref, Timing, Method | Args]) when is_binary(Method) ->
    Cast = cast([Ref]),
    {Repeat, Ms} = timing(Timing),
    Owner = bouy_actor:owner(),
    {'$schedule', erlang:spawn(fun() -> timer(monitor(process, Owner), Repeat, Ms, Cast, Method, Args) end)};
schedule(_Arguments) ->
    type_error(<<"schedule() needs a ref, { every } or { after }, and a method name">>).

%% Returns once the timer has stopped, so no cast of the schedule arrives
%% after a message that the caller sends next.
-spec cancelSchedule([term()]) -> undefined.
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

-spec sleep([term()]) -> undefined.
sleep([Ms | _]) when is_number(Ms) ->
    ok = bouy_task:wait(milliseconds(Ms)),
    undefined;
sleep(_Arguments) ->
    type_error(<<"sleep() needs a number of milliseconds">>).

-spec withTimeout([term()]) -> term().
withTimeout([Ms, Fun | _]) when is_number(Ms), is_function(Fun, 1) ->
    bouy_task:with_timeout(milliseconds(Ms), Fun);
withTimeout(_Arguments) ->
    type_error(<<"withTimeout() needs a number of milliseconds and a function">>).

-spec self([term()]) -> ref().
self(_Arguments) ->
    bouy_actor:current().

%% The spec of a new actor of Class, from the options of spawn() or child().
spec({'$class', Module, Class} = Value, Options, Name) when is_atom(Module), is_binary(Class) ->
    ok = actor_class(Value),
    #{
        id => bouy_registry:allocate(),
        module => Module,
        class => Class,
        args => args(option(<<"args">>, Options)),
        name => Name,
        mailbox => mailbox(option(<<"mailbox">>, Options)),
        restart => restart(option(<<"restart">>, Options)),
        chain => bouy_actor:chain()
    };
spec(_Class, _Options, _Name) ->
    type_error(<<"spawn() needs an actor class">>).

%% An actor class compiles to a module with `'C#dispatch'/3`; an error
%% class has none.
actor_class({'$class', Module, Class}) ->
    case bouy_actor:class_functions(Module, Class) of
        error -> type_error(<<"spawn() needs an actor class">>);
        _Functions -> ok
    end.

child_spec(Key, {'$child', Class, Options}) -> spec(Class, Options, Key);
child_spec(_Key, _Child) -> type_error(<<"each child of supervise() must come from child()">>).

options([]) -> #{};
options([undefined | _]) -> #{};
options([Options | _]) when is_map(Options) -> Options;
options([_Options | _]) -> type_error(<<"the options must be an object">>).

option(Key, Options) ->
    maps:get(Key, Options, undefined).

args(undefined) -> [];
args(Args) when is_list(Args) -> Args;
args(_Args) -> type_error(<<"args must be an array">>).

name(undefined) -> undefined;
name(Name) when is_binary(Name) -> Name;
name(_Name) -> type_error(<<"name must be a string">>).

mailbox(undefined) ->
    {?CAPACITY, backpressure};
mailbox(Mailbox) when is_map(Mailbox) ->
    {capacity(option(<<"capacity">>, Mailbox)), overflow(option(<<"overflow">>, Mailbox))};
mailbox(_Mailbox) ->
    type_error(<<"mailbox must be an object">>).

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

strategy(undefined) -> one_for_one;
strategy(<<"one-for-one">>) -> one_for_one;
strategy(<<"one-for-all">>) -> one_for_all;
strategy(<<"rest-for-one">>) -> rest_for_one;
strategy(_Strategy) ->
    type_error(<<"strategy must be \"one-for-one\", \"one-for-all\", or \"rest-for-one\"">>).

children(undefined) -> #{};
children(Children) when is_map(Children) -> Children;
children(_Children) -> type_error(<<"children must be an object">>).

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

timing(#{<<"every">> := Every}) when is_number(Every) -> {every, max(1, milliseconds(Every))};
timing(#{<<"after">> := After}) when is_number(After) -> {once, milliseconds(After)};
timing(_Timing) -> type_error(<<"schedule() needs { every: ms } or { after: ms }">>).

milliseconds(Ms) when is_integer(Ms) -> max(0, Ms);
milliseconds(Ms) -> max(0, trunc(Ms)).

%% The timer of one schedule() call. It ends when it is cancelled, after its
%% one `after` cast, when the actor has stopped, or when its owner ends. A
%% full mailbox skips a cast, whatever the overflow of the mailbox is.
timer(OwnerMonitor, Repeat, Ms, Cast, Method, Args) ->
    case due(OwnerMonitor, Ms) of
        {cancel, From, Monitor} ->
            From ! {Monitor, cancelled};
        ended ->
            ok;
        due ->
            case {Repeat, bouy_actor:offer(Cast, Method, Args)} of
                {every, Delivery} when Delivery =/= stopped -> timer(OwnerMonitor, Repeat, Ms, Cast, Method, Args);
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
    bouy_error:throw(<<"TypeError">>, Message).

-spec raise(term()) -> no_return().
raise(Failure) ->
    erlang:error({'$throw', Failure}).
