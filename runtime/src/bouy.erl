-module(bouy).

%% The functions that TypeScript imports from "bouy". Each one takes the
%% argument list of the call and JavaScript values: an options object is a map
%% with binary keys, or `undefined`.

-compile({no_auto_import, [spawn/1]}).

-export([spawn/1, cast/1, stop/1, inspect/1, supervise/1, child/1]).
-export([schedule/1, cancelSchedule/1, sleep/1, withTimeout/1, self/1]).

%% A top-level actor gets a group supervisor of its own with this budget.
-define(ALONE, #{strategy => one_for_one, intensity => 3, period => 5}).
-define(CAPACITY, 1024).

-type ref() :: {'$ref', pos_integer()}.
-type class() :: {'$class', module(), binary()}.
-type options() :: #{binary() => term()}.

-spec spawn([term()]) -> ref().
spawn([Class | Rest]) ->
    Options = options(Rest),
    #{id := Id} = Spec = spec(Class, Options, name(option(<<"name">>, Options))),
    Group = bouy_sup:new_group(?ALONE),
    case bouy_actor:start(Spec#{supervisor => Group, group => alone}) of
        ok ->
            {'$ref', Id};
        {error, Failure} ->
            ok = bouy_sup:stop_group(Group),
            raise(Failure)
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
    start_children(bouy_sup:new_group(Flags), Specs, #{}).

start_children(_Group, [], Refs) ->
    Refs;
start_children(Group, [{Key, #{id := Id} = Spec} | Rest], Refs) ->
    case bouy_actor:start(Spec#{supervisor => Group, group => tree}) of
        ok ->
            start_children(Group, Rest, Refs#{Key => {'$ref', Id}});
        {error, Failure} ->
            ok = bouy_sup:stop_group(Group),
            lists:foreach(
                fun({'$ref', Started}) -> bouy_registry:delete(Started) end,
                maps:values(Refs)
            ),
            raise(Failure)
    end.

-spec child([term()]) -> {'$child', class(), options()}.
child([{'$class', Module, Name} = Class | Rest]) when is_atom(Module), is_binary(Name) ->
    {'$child', Class, options(Rest)};
child(_Arguments) ->
    type_error(<<"child() needs an actor class">>).

%% Casts Method to the actor once after `after` ms, or every `every` ms, from a
%% timer process linked to the caller.
-spec schedule([term()]) -> {'$schedule', pid()}.
schedule([Ref, Timing, Method | Args]) when is_binary(Method) ->
    Cast = cast([Ref]),
    {Repeat, Ms} = timing(Timing),
    {'$schedule', spawn_link(fun() -> tick(Repeat, Ms, Cast, Method, Args) end)};
schedule(_Arguments) ->
    type_error(<<"schedule() needs a ref, { every } or { after }, and a method name">>).

-spec cancelSchedule([term()]) -> undefined.
cancelSchedule([{'$schedule', Timer} | _]) when is_pid(Timer) ->
    Timer ! cancel,
    undefined;
cancelSchedule(_Arguments) ->
    type_error(<<"cancelSchedule() needs the handle that schedule() returned">>).

-spec sleep([term()]) -> undefined.
sleep([Ms | _]) when is_number(Ms) ->
    ok = timer:sleep(milliseconds(Ms)),
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
spec({'$class', Module, Class}, Options, Name) when is_atom(Module), is_binary(Class) ->
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
capacity(Capacity) when is_integer(Capacity), Capacity > 0 -> Capacity;
capacity(_Capacity) -> type_error(<<"mailbox.capacity must be a positive integer">>).

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
max_restarts(Count) when is_integer(Count), Count >= 0 -> Count;
max_restarts(_Count) -> type_error(<<"maxRestarts must be a non-negative integer">>).

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
%% one `after` cast, or when the actor has stopped. A full mailbox skips a cast.
tick(Repeat, Ms, Cast, Method, Args) ->
    receive
        cancel -> ok
    after Ms ->
        case {Repeat, deliver(Cast, Method, Args)} of
            {every, Delivery} when Delivery =/= stopped -> tick(Repeat, Ms, Cast, Method, Args);
            _Done -> ok
        end
    end.

deliver(Cast, Method, Args) ->
    try bouy_actor:cast(Cast, Method, Args) of
        true -> sent
    catch
        error:{'$throw', #{<<"_tag">> := <<"MailboxFull">>}} -> skipped;
        error:{'$throw', #{<<"_tag">> := <<"ActorStopped">>}} -> stopped
    end.

-spec type_error(binary()) -> no_return().
type_error(Message) ->
    bouy_error:throw(<<"TypeError">>, Message).

-spec raise(term()) -> no_return().
raise(Failure) ->
    erlang:error({'$throw', Failure}).
