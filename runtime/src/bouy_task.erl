-module(bouy_task).

%% Promise.all, Promise.allSettled, Promise.race, and withTimeout run their
%% functions in parallel worker processes. A worker adopts the actor context of
%% its caller, so a call cycle through a worker still throws CallCycle. A
%% worker is linked to its caller, so it cannot outlive the caller. It catches
%% every exception and ends normally, so the link never ends the caller.
%%
%% Workers reply to an alias. After the caller stops listening, it removes the
%% alias, and the runtime drops any late reply.

-export([all/1, map/2, all_settled/1, map_settled/2, race/1, map_race/2, with_timeout/2]).
-export([resolve/1, reject/1]).

-type thunk() :: fun(() -> term()).
-type outcome() :: {ok, term()} | {raised, error | exit | throw, term(), list()}.

%% The values in input order. When a thunk throws, the first exception in input
%% order propagates after every thunk ends.
-spec all([thunk()]) -> list().
all(Thunks) ->
    [value(Outcome) || Outcome <- settle(Thunks)].

%% `Promise.all(items.map(f))`: f gets the argument list [Item, Index].
-spec map(list(), fun((list()) -> term())) -> list().
map(Items, Fun) ->
    all(thunks(Items, Fun)).

-spec all_settled([thunk()]) -> [#{binary() => term()}].
all_settled(Thunks) ->
    [settled(Outcome) || Outcome <- settle(Thunks)].

%% `Promise.allSettled(items.map(f))`.
-spec map_settled(list(), fun((list()) -> term())) -> [#{binary() => term()}].
map_settled(Items, Fun) ->
    all_settled(thunks(Items, Fun)).

%% `Promise.race(items.map(f))`.
-spec map_race(list(), fun((list()) -> term())) -> term().
map_race(Items, Fun) ->
    race(thunks(Items, Fun)).

thunks(Items, Fun) ->
    [fun() -> Fun([Item, Index]) end || {Index, Item} <- lists:enumerate(0, Items)].

%% The first thunk to end decides the result. The others keep running, as in
%% JavaScript, until they end or the caller ends.
-spec race([thunk()]) -> term().
race([]) ->
    %% An empty race never settles, as in JavaScript.
    receive
    after infinity -> ok
    end;
race(Thunks) ->
    Alias = alias(),
    _ = start_workers(Alias, Thunks),
    receive
        {Alias, _Index, Outcome} ->
            true = unalias(Alias),
            value(Outcome)
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
-spec with_timeout(timeout(), fun((list()) -> term())) -> term().
with_timeout(Ms, Fun) ->
    Alias = alias(),
    Worker = start_worker(Alias, 1, bouy_actor:context(), fun() -> Fun([]) end),
    receive
        {Alias, 1, Outcome} ->
            true = unalias(Alias),
            value(Outcome)
    after Ms ->
        true = unlink(Worker),
        true = exit(Worker, kill),
        true = unalias(Alias),
        late_outcome(Alias, Ms)
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

%% Runs every thunk in its own worker and returns the outcomes in input order.
-spec settle([thunk()]) -> [outcome()].
settle(Thunks) ->
    Alias = alias(),
    Count = start_workers(Alias, Thunks),
    Outcomes = collect(Alias, Count, #{}),
    true = unalias(Alias),
    [maps:get(Index, Outcomes) || Index <- lists:seq(1, Count)].

start_workers(Alias, Thunks) ->
    Context = bouy_actor:context(),
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
