%% `Effect` and `pipe` from "effect" (contract section 13).
%%
%% An Effect is `{'$effect', Thunk}`. Running it calls `Thunk()`, which
%% returns `{ok, Value}` or `{error, Failure}`. A defect is a JavaScript
%% exception, so it crosses every combinator that does not handle it. An
%% error value is an Effect that fails with itself, which is how
%% `yield* new NotFound(...)` fails a generator.
%%
%% The concurrent forms run each Effect in a worker process that adopts the
%% actor context of its caller and is linked to it. A worker that loses a
%% race, runs past a timeout, or runs beside a failure is killed, so the
%% `ensuring` finalizers inside it do not run.
-module(buoy_effect).

-export(['$member'/1, call/3, pipe/1]).
-export([succeed/1, fail/1, sync/1, 'try'/1, promise/1, tryPromise/1, die/1, gen/1, fn/1, fnUntraced/1]).
-export([map/1, flatMap/1, andThen/1, tap/1, 'catch'/1, catchTag/1, catchTags/1, mapError/1, orElseSucceed/1]).
-export([result/1, match/1, ensuring/1, as/1, asVoid/1, zip/1, all/1, forEach/1]).
-export([sleep/1, timeout/1, retry/1, race/1, runPromise/1, runSync/1]).
-export([bind/1, generator/1, run/1]).

-define(FUNCTIONS, [
    <<"succeed">>, <<"fail">>, <<"sync">>, <<"try">>, <<"promise">>, <<"tryPromise">>, <<"die">>,
    <<"gen">>, <<"fn">>, <<"fnUntraced">>, <<"map">>, <<"flatMap">>, <<"andThen">>, <<"tap">>,
    <<"catch">>, <<"catchTag">>, <<"catchTags">>, <<"mapError">>, <<"orElseSucceed">>, <<"result">>,
    <<"match">>, <<"ensuring">>, <<"as">>, <<"asVoid">>, <<"zip">>, <<"all">>, <<"forEach">>, <<"sleep">>,
    <<"timeout">>, <<"retry">>, <<"race">>, <<"runPromise">>, <<"runSync">>
]).
%% The longest timeout of one `receive ... after`.
-define(MAX_AFTER, 16#FFFFFFFF).

-type exit() :: {ok, term()} | {error, term()}.
-type effect() :: {'$effect', fun(() -> exit())}.
-type outcome() :: exit() | {raised, error | exit | throw, term(), list()}.
-export_type([effect/0, exit/0]).

-spec '$member'(binary()) -> term().
'$member'(<<"void">>) -> done({ok, undefined});
'$member'(Name) -> buoy_rt:member_function(?MODULE, Name, ?FUNCTIONS).

%% `effect.pipe(f, g)`, the method of every Effect.
-spec call(binary(), effect(), list()) -> term().
call(<<"pipe">>, Effect, Functions) -> pipe([Effect | Functions]);
call(Name, Effect, Args) -> buoy_rt:prototype_call(Effect, Name, Args).

%% `pipe(value, f, g)` is `g(f(value))`.
-spec pipe(list()) -> term().
pipe([Value | Functions]) -> lists:foldl(fun(F, Acc) -> buoy_rt:call(F, [Acc]) end, Value, Functions);
pipe([]) -> undefined.

%%% Constructors

-spec succeed(list()) -> effect().
succeed(Args) -> done({ok, buoy_rt:arg(1, Args)}).

-spec fail(list()) -> effect().
fail(Args) -> done({error, buoy_rt:arg(1, Args)}).

-spec sync(list()) -> effect().
sync(Args) ->
    Thunk = buoy_rt:arg(1, Args),
    effect(fun() -> {ok, buoy_rt:call(Thunk, [])} end).

%% A call returns when its result is ready, so the function of
%% `Effect.promise` gets no AbortSignal and its value is the result.
-spec promise(list()) -> effect().
promise(Args) -> sync(Args).

-spec die(list()) -> effect().
die(Args) ->
    Defect = buoy_rt:arg(1, Args),
    effect(fun() -> erlang:error({'$throw', Defect}) end).

%% `Effect.try(thunk)` and `Effect.try({ try, catch })`: an exception is a
%% failure, the UnknownError of Effect or the result of `catch`.
-spec 'try'(list()) -> effect().
'try'(Args) -> attempt(buoy_rt:arg(1, Args), <<"Effect.try">>).

-spec tryPromise(list()) -> effect().
tryPromise(Args) -> attempt(buoy_rt:arg(1, Args), <<"Effect.tryPromise">>).

attempt(#{<<"try">> := Try} = Options, _Name) -> guarded(Try, {catches, maps:get(<<"catch">>, Options, undefined)});
attempt(Try, Name) -> guarded(Try, {unknown, Name}).

guarded(Try, Recovery) ->
    effect(fun() ->
        try
            {ok, buoy_rt:call(Try, [])}
        catch
            error:Reason:Stack -> {error, recovered(Recovery, buoy_rt:caught(Reason, Stack))}
        end
    end).

recovered({catches, Catch}, Cause) ->
    buoy_rt:call(Catch, [Cause]);
recovered({unknown, Name}, Cause) ->
    Fields = #{<<"_tag">> => <<"UnknownError">>, <<"cause">> => Cause},
    buoy_error:new(<<"UnknownError">>, <<"An error occurred in ", Name/binary>>, Fields).

%% `Effect.gen(body)` and `Effect.gen(options, body)`. A generator function
%% returns its Effect when it is called (generator/1), and the body runs
%% each time the Effect runs.
-spec gen(list()) -> effect().
gen([_Options, Body | _]) -> lazy(Body, []);
gen(Args) -> lazy(buoy_rt:arg(1, Args), []).

%% `Effect.fn("name")(body, ...pipeables)` and `Effect.fn(body, ...pipeables)`.
-spec fn(list()) -> fun((list()) -> term()).
fn([Name | _]) when is_binary(Name) -> fun traced/1;
fn(Args) -> traced(Args).

-spec fnUntraced(list()) -> fun((list()) -> term()).
fnUntraced(Args) -> traced(Args).

%% A function whose call is the Effect of `body` with the arguments, passed
%% with the arguments through each pipeable.
-spec traced(list()) -> fun((list()) -> term()).
traced(Args) ->
    Body = buoy_rt:arg(1, Args),
    Pipeables = buoy_rt:rest(2, Args),
    fun(CallArgs) ->
        Pipe = fun(Pipeable, Effect) -> buoy_rt:call(Pipeable, [Effect | CallArgs]) end,
        lists:foldl(Pipe, lazy(Body, CallArgs), Pipeables)
    end.

lazy(Body, Args) ->
    effect(fun() -> run(buoy_rt:call(Body, Args)) end).

%%% Sequencing and recovery, each in its data-first and data-last form

-spec map(list()) -> term().
map(Args) ->
    dual(length(Args) >= 2, Args, fun([Self, F | _]) ->
        then(Self, fun(Value) -> {ok, buoy_rt:call(F, [Value])} end)
    end).

-spec flatMap(list()) -> term().
flatMap(Args) ->
    dual(length(Args) >= 2, Args, fun([Self, F | _]) ->
        then(Self, fun(Value) -> run(buoy_rt:call(F, [Value])) end)
    end).

%% `next` is an Effect, or a function of the value that returns one.
-spec andThen(list()) -> term().
andThen(Args) ->
    dual(length(Args) >= 2, Args, fun([Self, Next | _]) ->
        then(Self, fun(Value) -> run(next(Next, Value)) end)
    end).

-spec tap(list()) -> term().
tap(Args) ->
    dual(length(Args) >= 2, Args, fun([Self, Next | _]) ->
        then(Self, fun(Value) ->
            case run(next(Next, Value)) of
                {ok, _} -> {ok, Value};
                Failure -> Failure
            end
        end)
    end).

-spec as(list()) -> term().
as(Args) ->
    dual(length(Args) >= 2, Args, fun([Self, Value | _]) -> then(Self, fun(_) -> {ok, Value} end) end).

-spec asVoid(list()) -> effect().
asVoid(Args) -> then(buoy_rt:arg(1, Args), fun(_) -> {ok, undefined} end).

-spec 'catch'(list()) -> term().
'catch'(Args) ->
    dual(length(Args) >= 2, Args, fun([Self, F | _]) ->
        recover(Self, fun(Failure) -> run(buoy_rt:call(F, [Failure])) end)
    end).

%% `catchTag(self, tag | [tags], f, orElse?)`.
-spec catchTag(list()) -> term().
catchTag(Args) ->
    dual(is_effect(buoy_rt:arg(1, Args)), Args, fun([Self, Tags, F | Rest]) ->
        recover(Self, fun(Failure) ->
            case lists:member(tag(Failure), tags(Tags)) of
                true -> run(buoy_rt:call(F, [Failure]));
                false -> otherwise(buoy_rt:arg(1, Rest), Failure)
            end
        end)
    end).

%% `catchTags(self, { Tag: f }, orElse?)`.
-spec catchTags(list()) -> term().
catchTags(Args) ->
    dual(is_effect(buoy_rt:arg(1, Args)), Args, fun([Self, Cases | Rest]) ->
        recover(Self, fun(Failure) ->
            Tag = tag(Failure),
            case Cases of
                #{Tag := F} -> run(buoy_rt:call(F, [Failure]));
                _ -> otherwise(buoy_rt:arg(1, Rest), Failure)
            end
        end)
    end).

-spec mapError(list()) -> term().
mapError(Args) ->
    dual(length(Args) >= 2, Args, fun([Self, F | _]) ->
        recover(Self, fun(Failure) -> {error, buoy_rt:call(F, [Failure])} end)
    end).

-spec orElseSucceed(list()) -> term().
orElseSucceed(Args) ->
    dual(length(Args) >= 2, Args, fun([Self, F | _]) ->
        recover(Self, fun(Failure) -> {ok, buoy_rt:call(F, [Failure])} end)
    end).

%% The outcome as a Result, `{ _tag: "Success", success }` or
%% `{ _tag: "Failure", failure }`, the fields of a Result of Effect.
-spec result(list()) -> effect().
result(Args) ->
    Self = buoy_rt:arg(1, Args),
    effect(fun() ->
        case run(Self) of
            {ok, Value} -> {ok, #{<<"_tag">> => <<"Success">>, <<"success">> => Value}};
            {error, Failure} -> {ok, #{<<"_tag">> => <<"Failure">>, <<"failure">> => Failure}}
        end
    end).

%% `match(self, { onFailure, onSuccess })`.
-spec match(list()) -> term().
match(Args) ->
    dual(length(Args) >= 2, Args, fun([Self, Options | _]) ->
        effect(fun() ->
            case run(Self) of
                {ok, Value} -> {ok, buoy_rt:call(buoy_rt:get(Options, <<"onSuccess">>), [Value])};
                {error, Failure} -> {ok, buoy_rt:call(buoy_rt:get(Options, <<"onFailure">>), [Failure])}
            end
        end)
    end).

%% The finalizer runs after a success, a failure, and a defect.
-spec ensuring(list()) -> term().
ensuring(Args) ->
    dual(length(Args) >= 2, Args, fun([Self, Finalizer | _]) ->
        effect(fun() ->
            try
                run(Self)
            after
                run(Finalizer)
            end
        end)
    end).

%% `zip(self, that, { concurrent? })`: `[a, b]`.
-spec zip(list()) -> term().
zip(Args) ->
    dual(is_effect(buoy_rt:arg(2, Args)), Args, fun([Self, That | Rest]) ->
        Limit =
            case buoy_rt:truthy(option(<<"concurrent">>, buoy_rt:arg(1, Rest))) of
                true -> 2;
                false -> 1
            end,
        effect(fun() -> each([fun() -> Self end, fun() -> That end], Limit) end)
    end).

%%% Collections

%% `all(effects, { concurrency?, discard? })` over an array or a record.
-spec all(list()) -> effect().
all(Args) ->
    Effects = buoy_rt:arg(1, Args),
    Options = buoy_rt:arg(2, Args),
    Limit = concurrency(Options),
    effect(fun() -> discarded(Options, all_of(Effects, Limit)) end).

all_of(Record, Limit) when is_map(Record) ->
    Entries = buoy_object:own_entries(Record),
    case each([fun() -> Effect end || {_Key, Effect} <- Entries], Limit) of
        {ok, Values} -> {ok, maps:from_list(lists:zip([Key || {Key, _} <- Entries], Values))};
        Failure -> Failure
    end;
all_of(Effects, Limit) ->
    each([fun() -> Effect end || Effect <- buoy_rt:to_list(Effects)], Limit).

%% `forEach(items, (item, index) => effect, { concurrency?, discard? })`.
-spec forEach(list()) -> term().
forEach(Args) ->
    dual(buoy_rt:type_of(buoy_rt:arg(2, Args)) =:= <<"function">>, Args, fun([Items, F | Rest]) ->
        Options = buoy_rt:arg(1, Rest),
        Limit = concurrency(Options),
        effect(fun() ->
            Indexed = lists:enumerate(0, buoy_rt:to_list(Items)),
            discarded(Options, each([fun() -> buoy_rt:call(F, [Item, Index]) end || {Index, Item} <- Indexed], Limit))
        end)
    end).

discarded(Options, {ok, Values}) ->
    case buoy_rt:truthy(option(<<"discard">>, Options)) of
        true -> {ok, undefined};
        false -> {ok, Values}
    end;
discarded(_Options, Failure) ->
    Failure.

concurrency(Options) ->
    case option(<<"concurrency">>, Options) of
        undefined -> 1;
        <<"unbounded">> -> infinity;
        Value ->
            case buoy_rt:to_number(Value) of
                'Infinity' -> infinity;
                N when is_number(N), N > 1 -> ceil(N);
                _ -> 1
            end
    end.

option(Key, #{} = Options) -> maps:get(Key, Options, undefined);
option(_Key, _Options) -> undefined.

%% Runs the Effect that each start returns, at most Limit at a time, and
%% returns the values in input order or the first failure. A start runs in
%% the caller, in input order, when its Effect is about to begin.
each(Starts, 1) ->
    sequence(Starts, []);
each([], _Limit) ->
    {ok, []};
each(Starts, Limit) ->
    Alias = alias(),
    Context = buoy_actor:context(),
    {First, Waiting} = lists:split(min(Limit, length(Starts)), lists:enumerate(Starts)),
    Workers = lists:foldl(fun(Start, Started) -> start(Alias, Context, Start, Started) end, #{}, First),
    gather(Alias, Context, Workers, Waiting, #{}).

sequence([], Values) ->
    {ok, lists:reverse(Values)};
sequence([Start | Rest], Values) ->
    case run(Start()) of
        {ok, Value} -> sequence(Rest, [Value | Values]);
        Failure -> Failure
    end.

start(Alias, Context, {Index, Start}, Workers) ->
    Effect =
        try
            Start()
        catch
            Class:Reason:Stack ->
                stop(Alias, Workers),
                erlang:raise(Class, Reason, Stack)
        end,
    Workers#{Index => worker(Alias, Index, Context, Effect)}.

gather(Alias, _Context, Workers, [], Values) when map_size(Workers) =:= 0 ->
    true = unalias(Alias),
    {ok, [Value || {_Index, Value} <- lists:sort(maps:to_list(Values))]};
gather(Alias, Context, Workers, Waiting, Values) ->
    receive
        {Alias, Index, {ok, Value}} ->
            Running = maps:remove(Index, Workers),
            case Waiting of
                [] -> gather(Alias, Context, Running, [], Values#{Index => Value});
                [Next | Later] -> gather(Alias, Context, start(Alias, Context, Next, Running), Later, Values#{Index => Value})
            end;
        {Alias, Index, Outcome} ->
            stop(Alias, maps:remove(Index, Workers)),
            settle(Outcome)
    end.

%%% Time and concurrency

-spec sleep(list()) -> effect().
sleep(Args) ->
    Duration = buoy_rt:arg(1, Args),
    effect(fun() ->
        ok = pause(buoy_duration:to_millis(Duration)),
        {ok, undefined}
    end).

%% A failure with TimeoutError when `duration` passes first. The worker
%% that runs `self` is killed then.
-spec timeout(list()) -> term().
timeout(Args) ->
    dual(length(Args) >= 2, Args, fun([Self, Duration | _]) ->
        effect(fun() ->
            case buoy_duration:to_millis(Duration) of
                'Infinity' -> run(Self);
                Millis -> deadline(Self, Millis)
            end
        end)
    end).

deadline(Self, Millis) ->
    Alias = alias(),
    Worker = worker(Alias, 1, buoy_actor:context(), Self),
    case await(Alias, milliseconds(Millis)) of
        {done, Outcome} ->
            true = unalias(Alias),
            settle(Outcome);
        timeout ->
            stop(Alias, #{1 => Worker}),
            Message = <<"Operation timed out after '", (buoy_duration:text(Millis))/binary, "'">>,
            {error, buoy_error:new(<<"TimeoutError">>, Message, #{<<"_tag">> => <<"TimeoutError">>})}
    end.

await(Alias, Millis) ->
    Chunk = min(Millis, ?MAX_AFTER),
    receive
        {Alias, 1, Outcome} -> {done, Outcome}
    after Chunk ->
        case Millis - Chunk of
            0 -> timeout;
            Rest -> await(Alias, Rest)
        end
    end.

%% `retry(self, schedule | { schedule?, times?, while?, until? })`: runs
%% `self` again after each failure that the policy allows.
-spec retry(list()) -> term().
retry(Args) ->
    dual(length(Args) >= 2, Args, fun([Self, Policy | _]) ->
        Decide = buoy_schedule:policy(Policy),
        effect(fun() -> retrying(Self, Decide, 1) end)
    end).

retrying(Self, Decide, Attempt) ->
    case run(Self) of
        {error, Failure} = Exit ->
            case Decide(Attempt, Failure) of
                {delay, Millis} ->
                    ok = pause(Millis),
                    retrying(Self, Decide, Attempt + 1);
                done ->
                    Exit
            end;
        Success ->
            Success
    end.

%% `race(self, that)`: the first success. When both fail, the first typed
%% failure, else the first defect.
-spec race(list()) -> term().
race(Args) ->
    dual(is_effect(buoy_rt:arg(2, Args)), Args, fun([Self, That | _]) ->
        effect(fun() ->
            Alias = alias(),
            Context = buoy_actor:context(),
            Workers = #{1 => worker(Alias, 1, Context, Self), 2 => worker(Alias, 2, Context, That)},
            first_success(Alias, Workers, [])
        end)
    end).

%% The failures arrive in the order the workers end.
first_success(Alias, Workers, Failures) when length(Failures) =:= map_size(Workers) ->
    true = unalias(Alias),
    Ordered = lists:reverse(Failures),
    settle(hd([Failure || {error, _} = Failure <- Ordered] ++ Ordered));
first_success(Alias, Workers, Failures) ->
    receive
        {Alias, Index, {ok, _} = Success} ->
            stop(Alias, maps:remove(Index, Workers)),
            Success;
        {Alias, _Index, Failure} ->
            first_success(Alias, Workers, [Failure | Failures])
    end.

worker(Alias, Index, Context, Effect) ->
    spawn_link(fun() ->
        ok = buoy_actor:adopt(Context),
        Alias ! {Alias, Index, outcome(Effect)}
    end).

-spec outcome(term()) -> outcome().
outcome(Effect) ->
    try
        run(Effect)
    catch
        Class:Reason:Stack -> {raised, Class, Reason, Stack}
    end.

-spec settle(outcome()) -> exit().
settle({raised, Class, Reason, Stack}) -> erlang:raise(Class, Reason, Stack);
settle(Exit) -> Exit.

%% Kills the workers and drops the outcomes that they already sent.
stop(Alias, Workers) ->
    maps:foreach(
        fun(_Index, Worker) ->
            true = unlink(Worker),
            true = exit(Worker, kill)
        end,
        Workers
    ),
    true = unalias(Alias),
    flush(Alias).

flush(Alias) ->
    receive
        {Alias, _Index, _Outcome} -> flush(Alias)
    after 0 -> ok
    end.

pause('Infinity') ->
    receive
    after infinity -> ok
    end;
pause(Millis) ->
    buoy_task:wait(milliseconds(Millis)).

milliseconds(Millis) when is_integer(Millis) -> max(Millis, 0);
milliseconds(Millis) when is_float(Millis) -> max(ceil(Millis), 0);
milliseconds(_NegativeOrNaN) -> 0.

%%% Running

-spec runSync(list()) -> term().
runSync(Args) ->
    case run(buoy_rt:arg(1, Args)) of
        {ok, Value} -> Value;
        {error, Failure} -> erlang:error({'$throw', Failure})
    end.

%% A call returns when its result is ready, so `runPromise` runs the Effect
%% to the end as `runSync` does.
-spec runPromise(list()) -> term().
runPromise(Args) -> runSync(Args).

%% Runs an Effect: its value or its failure. A defect raises.
-spec run(term()) -> exit().
run({'$effect', Thunk}) -> Thunk();
run(#{'$error' := _} = Error) -> {error, Error};
run(Other) -> not_an_effect(Other).

%%% Generators (contract section 13)

%% The Effect of a call of a generator function. `Body` runs when the Effect
%% runs, and its return value is the success value.
-spec generator(fun(() -> term())) -> effect().
generator(Body) ->
    effect(fun() ->
        try
            {ok, Body()}
        catch
            throw:{'$fail', Failure} -> {error, Failure};
            throw:{'$die', Defect} -> erlang:error({'$throw', Defect})
        end
    end).

%% `yield* effect`: the value of the Effect. A failure or a defect ends the
%% generator body with an Erlang throw, which no `catch` or `finally` of the
%% body sees, as Effect abandons the generator.
-spec bind(term()) -> term().
bind({'$effect', _} = Effect) ->
    try run(Effect) of
        {ok, Value} -> Value;
        {error, Failure} -> throw({'$fail', Failure})
    catch
        error:Reason:Stack -> throw({'$die', buoy_rt:caught(Reason, Stack)})
    end;
bind(#{'$error' := _} = Error) ->
    throw({'$fail', Error});
bind(Other) ->
    not_an_effect(Other).

%%% Helpers

effect(Thunk) -> {'$effect', Thunk}.

done(Exit) -> effect(fun() -> Exit end).

is_effect({'$effect', _}) -> true;
is_effect(#{'$error' := _}) -> true;
is_effect(_) -> false.

%% Effect's dual APIs: the data-first form when DataFirst holds, else a
%% function that takes the subject, as `pipe` passes it.
dual(true, Args, Apply) -> Apply(Args);
dual(false, Args, Apply) -> fun(Subject) -> Apply([buoy_rt:arg(1, Subject) | Args]) end.

then(Self, Next) ->
    effect(fun() ->
        case run(Self) of
            {ok, Value} -> Next(Value);
            Failure -> Failure
        end
    end).

recover(Self, Recover) ->
    effect(fun() ->
        case run(Self) of
            {error, Failure} -> Recover(Failure);
            Success -> Success
        end
    end).

next(Next, Value) ->
    case is_effect(Next) of
        true -> Next;
        false -> buoy_rt:call(Next, [Value])
    end.

otherwise(undefined, Failure) -> {error, Failure};
otherwise(OrElse, Failure) -> run(buoy_rt:call(OrElse, [Failure])).

tag(#{<<"_tag">> := Tag}) when is_binary(Tag) -> Tag;
tag(_) -> undefined.

tags(Tags) when is_list(Tags) -> Tags;
tags(Tag) -> [Tag].

-spec not_an_effect(term()) -> no_return().
not_an_effect(Value) ->
    buoy_error:throw(<<"TypeError">>, <<(buoy_rt:describe(Value))/binary, " is not an Effect">>).
