-module(bouy_task).

%% Promise.all, Promise.allSettled, Promise.race, Promise.any, and
%% withTimeout run their functions in parallel worker processes. A worker
%% adopts the actor context of its caller, so a call cycle through a worker
%% still throws CallCycle. A worker is linked to its caller, so it cannot
%% outlive the caller. It catches every exception and ends normally, so the
%% link never ends the caller.
%%
%% Workers reply to an alias. After the caller stops listening, it removes the
%% alias, and the runtime drops any late reply.

-export([all/1, map/2, map/3, all_settled/1, map_settled/2, map_settled/3]).
-export([race/1, map_race/2, map_race/3, any/1, map_any/2, map_any/3, with_timeout/2]).
-export([resolve/1, reject/1, wait/1]).

-type thunk() :: fun(() -> term()).
-type outcome() :: {ok, term()} | {raised, error | exit | throw, term(), list()}.

%% The longest timeout of one `receive ... after`.
-define(MAX_AFTER, 16#FFFFFFFF).

%% The values in input order. When a thunk throws, the first exception in input
%% order propagates after every thunk ends.
-spec all([thunk()]) -> list().
all(Thunks) ->
    [value(Outcome) || Outcome <- settle(Thunks)].

%% `Promise.all(items.map(f))`: f gets the arguments that `map` passes.
%% Params is the parameter count of a function literal f, which the compiler
%% passes when f cannot read the array (section 7).
-spec map(term(), term()) -> list().
map(Items, Fun) ->
    map(Items, Fun, 3).

-spec map(term(), term(), non_neg_integer()) -> list().
map(Items, Fun, Params) when is_list(Items) ->
    all(thunks(Items, Fun, Params));
map(Items, Fun, _Params) ->
    mapped(Items, Fun).

-spec all_settled([thunk()]) -> [#{binary() => term()}].
all_settled(Thunks) ->
    [settled(Outcome) || Outcome <- settle(Thunks)].

%% `Promise.allSettled(items.map(f))`.
-spec map_settled(term(), term()) -> [#{binary() => term()}].
map_settled(Items, Fun) ->
    map_settled(Items, Fun, 3).

-spec map_settled(term(), term(), non_neg_integer()) -> [#{binary() => term()}].
map_settled(Items, Fun, Params) when is_list(Items) ->
    all_settled(thunks(Items, Fun, Params));
map_settled(Items, Fun, _Params) ->
    [settled({ok, Value}) || Value <- mapped(Items, Fun)].

%% `Promise.race(items.map(f))`.
-spec map_race(term(), term()) -> term().
map_race(Items, Fun) ->
    map_race(Items, Fun, 3).

-spec map_race(term(), term(), non_neg_integer()) -> term().
map_race(Items, Fun, Params) when is_list(Items) ->
    race(thunks(Items, Fun, Params));
map_race(Items, Fun, _Params) ->
    first(mapped(Items, Fun)).

%% `Promise.any(items.map(f))`.
-spec map_any(term(), term()) -> term().
map_any(Items, Fun) ->
    map_any(Items, Fun, 3).

-spec map_any(term(), term(), non_neg_integer()) -> term().
map_any(Items, Fun, Params) when is_list(Items) ->
    any(thunks(Items, Fun, Params));
map_any(Items, Fun, _Params) ->
    case mapped(Items, Fun) of
        [] -> aggregate([]);
        [Value | _] -> Value
    end.

%% Each item runs `Fun(item, index, items)`, as `map` calls it. A worker
%% copies what its thunk holds, so a function that cannot read the array
%% gets only its item and index: each worker then copies one item, not the
%% whole array.
thunks(Items, Fun, Params) when Params >= 3 ->
    [fun() -> bouy_rt:call(Fun, [Item, Index, Items]) end || {Index, Item} <- lists:enumerate(0, Items)];
thunks(Items, Fun, _Params) ->
    [fun() -> bouy_rt:call(Fun, [Item, Index]) end || {Index, Item} <- lists:enumerate(0, Items)].

%% `x.map(f)` of a value that is not an array runs its own `map`, whose
%% result holds values that are already settled.
mapped(Items, Fun) ->
    bouy_rt:to_list(bouy_rt:call_method(Items, <<"map">>, [Fun])).

first([]) -> never_settles();
first([Value | _]) -> Value.

%% The first thunk to end decides the result. The others keep running, as in
%% JavaScript, until they end or the caller ends, but they no longer act for
%% the turn of the caller, so their calls carry no call chain.
-spec race([thunk()]) -> term().
race([]) ->
    never_settles();
race(Thunks) ->
    Alias = alias(),
    Scope = atomics:new(1, []),
    _ = start_workers(Alias, bouy_actor:within(bouy_actor:context(), Scope), Thunks),
    receive
        {Alias, _Index, Outcome} ->
            ok = atomics:put(Scope, 1, 1),
            true = unalias(Alias),
            value(Outcome)
    end.

%% `Promise.any`: the first value. When every thunk throws, an
%% AggregateError with the errors in input order.
-spec any([thunk()]) -> term().
any([]) ->
    aggregate([]);
any(Thunks) ->
    Alias = alias(),
    Scope = atomics:new(1, []),
    Count = start_workers(Alias, bouy_actor:within(bouy_actor:context(), Scope), Thunks),
    first_value(Alias, Scope, Count, #{}).

first_value(Alias, Scope, 0, Errors) ->
    ok = atomics:put(Scope, 1, 1),
    true = unalias(Alias),
    aggregate([caught(maps:get(Index, Errors)) || Index <- lists:seq(1, map_size(Errors))]);
first_value(Alias, Scope, Remaining, Errors) ->
    receive
        {Alias, _Index, {ok, Value}} ->
            ok = atomics:put(Scope, 1, 1),
            true = unalias(Alias),
            Value;
        {Alias, Index, {raised, error, _, _} = Outcome} ->
            first_value(Alias, Scope, Remaining - 1, Errors#{Index => Outcome});
        {Alias, _Index, Outcome} ->
            %% An Effect failure or an exit is not a rejection, so it propagates.
            ok = atomics:put(Scope, 1, 1),
            true = unalias(Alias),
            value(Outcome)
    end.

caught({raised, error, Reason, Stack}) -> bouy_rt:caught(Reason, Stack).

-spec aggregate(list()) -> no_return().
aggregate(Errors) ->
    bouy_error:throw(<<"AggregateError">>, <<"All promises were rejected">>, #{<<"errors">> => Errors}).

%% An empty race never settles. Outside an actor, the top-level code waits
%% on it forever, so the program ends as Node ends it, with status 13.
-spec never_settles() -> no_return().
never_settles() ->
    case bouy_actor:current_id() of
        undefined ->
            io:put_chars(standard_error, "Warning: Detected unsettled top-level await\n"),
            erlang:halt(13);
        _Actor ->
            receive
            after infinity -> ok
            end
    end.

%% `Promise.resolve(value)`, through the namespace rule of `Promise`. A call
%% returns only when its result is ready, so every value is already settled.
-spec resolve(list()) -> term().
resolve(Args) ->
    bouy_rt:arg(1, Args).

%% `Promise.reject(reason)`.
-spec reject(list()) -> no_return().
reject(Args) ->
    erlang:error({'$throw', bouy_rt:arg(1, Args)}).

%% Runs Fun in a worker. When Ms passes first, it kills the worker and throws
%% CallTimedOut.
-spec with_timeout(non_neg_integer(), fun((list()) -> term())) -> term().
with_timeout(Ms, Fun) ->
    Alias = alias(),
    Worker = start_worker(Alias, 1, bouy_actor:context(), fun() -> Fun([]) end),
    case outcome(Alias, Ms) of
        {done, Outcome} ->
            true = unalias(Alias),
            value(Outcome);
        timeout ->
            true = unlink(Worker),
            true = exit(Worker, kill),
            true = unalias(Alias),
            late_outcome(Alias, Ms)
    end.

%% The outcome of worker 1, or timeout after Ms, which may exceed the
%% longest timeout of one `receive`.
outcome(Alias, Ms) ->
    Chunk = min(Ms, ?MAX_AFTER),
    receive
        {Alias, 1, Outcome} -> {done, Outcome}
    after Chunk ->
        case Ms - Chunk of
            0 -> timeout;
            Rest -> outcome(Alias, Rest)
        end
    end.

%% The worker can end after the deadline but before the kill.
late_outcome(Alias, Ms) ->
    receive
        {Alias, 1, Outcome} -> value(Outcome)
    after 0 ->
        Message = <<"the call did not finish within ", (integer_to_binary(Ms))/binary, " ms">>,
        Fields = #{<<"_tag">> => <<"CallTimedOut">>, <<"ms">> => Ms},
        bouy_error:throw(<<"CallTimedOut">>, Message, Fields)
    end.

%% Blocks the calling process for Ms, which may exceed the longest timeout
%% of one `receive`.
-spec wait(non_neg_integer()) -> ok.
wait(Ms) when Ms > ?MAX_AFTER ->
    ok = timer:sleep(?MAX_AFTER),
    wait(Ms - ?MAX_AFTER);
wait(Ms) ->
    timer:sleep(Ms).

%% Runs every thunk in its own worker and returns the outcomes in input order.
-spec settle([thunk()]) -> [outcome()].
settle(Thunks) ->
    Alias = alias(),
    Count = start_workers(Alias, bouy_actor:context(), Thunks),
    Outcomes = collect(Alias, Count, #{}),
    true = unalias(Alias),
    [maps:get(Index, Outcomes) || Index <- lists:seq(1, Count)].

start_workers(Alias, Context, Thunks) ->
    lists:foreach(
        fun({Index, Thunk}) -> start_worker(Alias, Index, Context, Thunk) end,
        lists:enumerate(Thunks)
    ),
    length(Thunks).

start_worker(Alias, Index, Context, Thunk) ->
    spawn_link(fun() ->
        ok = bouy_actor:adopt(Context),
        Alias ! {Alias, Index, run(Thunk)}
    end).

run(Thunk) ->
    try
        {ok, Thunk()}
    catch
        Kind:Reason:Stack -> {raised, Kind, Reason, Stack}
    end.

collect(_Alias, 0, Outcomes) ->
    Outcomes;
collect(Alias, Remaining, Outcomes) ->
    receive
        {Alias, Index, Outcome} -> collect(Alias, Remaining - 1, Outcomes#{Index => Outcome})
    end.

value({ok, Value}) ->
    Value;
value({raised, Kind, Reason, Stack}) ->
    erlang:raise(Kind, Reason, Stack).

settled({ok, Value}) ->
    #{<<"status">> => <<"fulfilled">>, <<"value">> => Value};
settled({raised, error, Reason, Stack}) ->
    #{<<"status">> => <<"rejected">>, <<"reason">> => bouy_rt:caught(Reason, Stack)};
settled({raised, Kind, Reason, Stack}) ->
    %% An Effect failure or an exit is not a JavaScript exception, so it
    %% propagates.
    erlang:raise(Kind, Reason, Stack).
