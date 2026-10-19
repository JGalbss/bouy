%% The Promise family: the Promise constructor, its statics, and
%% Promise.prototype, as ECMA-262 §27.2 specifies them. buoy_jobs holds the
%% promise states and the job queue.
%%
%% A promise capability is {Promise, Resolve, Reject}. For the intrinsic
%% Promise, Resolve and Reject are Erlang funs of buoy_jobs, which nothing
%% can observe, and they become builtin functions only when user code can
%% see them. For another constructor they are the functions that its
%% executor received.
-module(buoy_ref_promise).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, constructor/0]).

-import(buoy_ref_realm, [arg/2, rest/2, record/4, ctor_record/5]).
-import(buoy_ref, [type_error/1]).
-import(buoy_jobs, [invoke/2]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Promise.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"Promise.prototype">>, [{<<"then">>, 2}, {<<"catch">>, 1}, {<<"finally">>, 1}]) ++ [{<<"constructor">>, constructor()}, {?SYM(toStringTag), <<"Promise">>, 4}], none)},
     {{builtin, <<"Promise">>}, ctor_record(<<"Promise">>, 1, {'$o', 'Promise.prototype'}, ?METHODS(<<"Promise">>, [{<<"resolve">>, 1}, {<<"reject">>, 1}, {<<"all">>, 1}, {<<"allSettled">>, 1}, {<<"race">>, 1}, {<<"any">>, 1}, {<<"withResolvers">>, 0}, {<<"try">>, 1}, {<<"allKeyed">>, 1}, {<<"allSettledKeyed">>, 1}]) ++ [{?SYM(species), species_getter(), 4}], fun construct/2)}].

%% get Promise[Symbol.species]: this.
species_getter() ->
    {'$accessor', buoy_ref_realm:builtin(<<"get Promise[Symbol.species]">>, <<"get [Symbol.species]">>, 0, fun(This, _) -> This end), undefined}.

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Promise">>, constructor()}].

-spec constructor() -> term().
constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Promise">>).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(Name, _This, _Args) -> type_error(<<"Constructor ", Name/binary, " requires 'new'">>).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Promise.prototype">>, Name, This, Args) -> promise_proto(Name, This, Args);
method(<<"Promise">>, Name, This, Args) -> promise_static(Name, This, Args).

%% new Promise(executor): the prototype comes from NewTarget, so a subclass
%% gets its own.
construct(NewTarget, Args) ->
    Executor = arg(1, Args),
    buoy_heap:is_callable(Executor) orelse
        type_error(buoy_ref_string:concat([<<"Promise resolver ">>, buoy_ref:describe(Executor), <<" is not a function">>])),
    P = buoy_jobs:new_promise(buoy_ref_realm:proto_for(NewTarget, 'Promise.prototype')),
    {Resolve, Reject} = buoy_jobs:resolving_functions(P),
    try buoy_ref:call(Executor, undefined, [buoy_jobs:js_function(Resolve), buoy_jobs:js_function(Reject)]) of
        _ -> ok
    catch
        error:Reason:Stack -> Reject(buoy_ref:caught(Reason, Stack))
    end,
    P.

%% NewPromiseCapability(C). The intrinsic Promise needs no executor, because
%% its construction is not observable.
new_capability(C) -> new_capability(C, undefined).

%% Parent is the promise whose `then` derives the capability, for the init
%% promise hook.
new_capability(C, Parent) ->
    case C =:= constructor() of
        true -> buoy_jobs:capability(Parent);
        false -> capability_of(C)
    end.

%% Construct(C, [executor]) with a GetCapabilitiesExecutor: a builtin of
%% length 2 that keeps the first resolve and reject that are not undefined.
capability_of(C) ->
    buoy_heap:is_constructor(C) orelse type_error(buoy_ref_string:concat(buoy_ref:describe(C), <<" is not a constructor">>)),
    Functions = buoy_heap:cell({undefined, undefined}),
    Executor = buoy_heap:function(fun(_This, Args) ->
                                          case buoy_heap:cell_get(Functions) of
                                              {undefined, undefined} -> buoy_heap:cell_set(Functions, {arg(1, Args), arg(2, Args)}), undefined;
                                              _ -> type_error(<<"Promise executor has already been invoked with non-undefined arguments">>)
                                          end
                                  end, <<>>, 2, #{}),
    P = buoy_heap:construct(C, [Executor], C),
    {Resolve, Reject} = buoy_heap:cell_get(Functions),
    buoy_heap:is_callable(Resolve) andalso buoy_heap:is_callable(Reject) orelse
        type_error(<<"Promise resolve or reject function is not callable">>),
    {P, Resolve, Reject}.

%% PromiseResolve(C, X): X itself when it is a promise of C.
promise_resolve(C, X) ->
    case buoy_jobs:is_promise(X) andalso buoy_heap:get(X, <<"constructor">>) =:= C of
        true ->
            X;
        false ->
            {P, Resolve, _} = new_capability(C),
            _ = invoke(Resolve, X),
            P
    end.

%% SpeciesConstructor(P, %Promise%).
species_constructor(P) -> buoy_ref_buffer:species_constructor(P, constructor()).

%% A capability function as user code sees it.
as_js(F) when is_function(F, 1) -> buoy_jobs:js_function(F);
as_js(F) -> F.

promise_proto(<<"then">>, P, Args) ->
    buoy_jobs:is_promise(P) orelse type_error(<<"Method Promise.prototype.then called on incompatible receiver">>),
    {Promise, _, _} = Capability = new_capability(species_constructor(P), P),
    buoy_jobs:perform_then(P, arg(1, Args), arg(2, Args), Capability),
    Promise;
promise_proto(<<"catch">>, P, Args) ->
    buoy_ref:call_method(P, <<"then">>, [undefined, arg(1, Args)]);
promise_proto(<<"finally">>, P, Args) ->
    ?IS_OBJECT(P) orelse type_error(<<"Method Promise.prototype.finally called on a non-object">>),
    C = species_constructor(P),
    OnFinally = arg(1, Args),
    case buoy_heap:is_callable(OnFinally) of
        true ->
            ThenFinally = after_finally(C, OnFinally, fun(Value) -> Value end),
            CatchFinally = after_finally(C, OnFinally, fun(Reason) -> erlang:error({'$throw', Reason}) end),
            buoy_ref:call_method(P, <<"then">>, [ThenFinally, CatchFinally]);
        false ->
            buoy_ref:call_method(P, <<"then">>, [OnFinally, OnFinally])
    end.

%% thenFinally or catchFinally: calls onFinally, waits for its result, and
%% then passes on the value or the reason through Settle.
after_finally(C, OnFinally, Settle) ->
    buoy_jobs:js_function(fun(Argument) ->
                                  Promise = promise_resolve(C, buoy_ref:call(OnFinally, undefined, [])),
                                  Thunk = buoy_heap:function(fun(_, _) -> Settle(Argument) end, <<>>, 0, #{}),
                                  buoy_ref:call_method(Promise, <<"then">>, [Thunk])
                          end).

promise_static(<<"resolve">>, C, Args) ->
    ?IS_OBJECT(C) orelse type_error(<<"PromiseResolve called on non-object">>),
    promise_resolve(C, arg(1, Args));
promise_static(<<"reject">>, C, Args) ->
    {P, _, Reject} = new_capability(C),
    _ = invoke(Reject, arg(1, Args)),
    P;
promise_static(<<"withResolvers">>, C, _Args) ->
    {P, Resolve, Reject} = new_capability(C),
    buoy_heap:object(?OBJECT_PROTO, [{<<"promise">>, P}, {<<"resolve">>, as_js(Resolve)}, {<<"reject">>, as_js(Reject)}]);
%% Promise.try with ecma262 PR 3883: a promise of C that the callback
%% returns comes back unwrapped.
promise_static(<<"try">>, C, Args) ->
    ?IS_OBJECT(C) orelse type_error(<<"Promise.try called on non-object">>),
    try buoy_ref:call(arg(1, Args), undefined, rest(2, Args)) of
        V -> promise_resolve(C, V)
    catch
        error:Reason:Stack -> promise_static(<<"reject">>, C, [buoy_ref:caught(Reason, Stack)])
    end;
promise_static(<<"all">>, C, Args) -> combinator(C, arg(1, Args), fun all/2);
promise_static(<<"allSettled">>, C, Args) -> combinator(C, arg(1, Args), fun all_settled/2);
promise_static(<<"any">>, C, Args) -> combinator(C, arg(1, Args), fun any/2);
promise_static(<<"race">>, C, Args) -> combinator(C, arg(1, Args), fun race/2);
promise_static(<<"allKeyed">>, C, Args) -> keyed(C, arg(1, Args), fun all/2);
promise_static(<<"allSettledKeyed">>, C, Args) -> keyed(C, arg(1, Args), fun all_settled/2).

%% Promise.allKeyed and Promise.allSettledKeyed (the await-dictionary
%% proposal): the combinator of all or allSettled over the own enumerable
%% properties of an object, whose result is an object with the same keys and
%% a null prototype. Perform finishes with the values in key order, so the
%% capability that it gets resolves with the object of the keys instead.
keyed(C, Promises, Perform) ->
    {P, Resolve, Reject} = new_capability(C),
    try
        ResolveMethod = buoy_ref:get(C, <<"resolve">>),
        buoy_heap:is_callable(ResolveMethod) orelse type_error(<<"Promise resolve is not a function">>),
        ?IS_OBJECT(Promises) orelse type_error(<<"Promise keyed combinators take an object">>),
        Keys = buoy_heap:cell([]),
        Each = fun(Element) ->
                       keyed_each(Promises, buoy_heap:own_keys(Promises), fun(V) -> buoy_ref:call(ResolveMethod, C, [V]) end,
                                  fun(Index, Key, Next) ->
                                          buoy_heap:cell_set(Keys, [Key | buoy_heap:cell_get(Keys)]),
                                          Element(Index, Next)
                                  end, 0)
               end,
        ResolveObject = fun(Array) ->
                                Result = buoy_heap:new_object(null),
                                Values = buoy_heap:array_items(Array),
                                [buoy_heap:define(Result, K, #{value => V, writable => true, enumerable => true, configurable => true})
                                 || {K, V} <- lists:zip(lists:reverse(buoy_heap:cell_get(Keys)), Values)],
                                invoke(Resolve, Result)
                        end,
        Perform(Each, {P, ResolveObject, Reject})
    catch
        error:Reason:Stack -> invoke(Reject, buoy_ref:caught(Reason, Stack))
    end,
    P.

%% The loop of the keyed combinators over the own keys of O: a key whose own
%% property is enumerable gets the next index. Returns the count.
keyed_each(_O, [], _Resolve, _Element, Index) ->
    Index;
keyed_each(O, [K | Rest], Resolve, Element, Index) ->
    case buoy_heap:is_enumerable(buoy_heap:get_own(O, K)) of
        true ->
            Element(Index, K, Resolve(buoy_ref:get(O, K))),
            keyed_each(O, Rest, Resolve, Element, Index + 1);
        false ->
            keyed_each(O, Rest, Resolve, Element, Index)
    end.

%%% all, allSettled, any, and race

%% The frame of the combinators: an error of GetPromiseResolve, of
%% GetIterator, or of the loop rejects the promise instead of throwing.
%% Perform gets Each, which runs the loop, and the capability.
combinator(C, Iterable, Perform) ->
    {P, _, Reject} = Capability = new_capability(C),
    try
        Resolve = buoy_ref:get(C, <<"resolve">>),
        buoy_heap:is_callable(Resolve) orelse type_error(<<"Promise resolve is not a function">>),
        State = buoy_ref_iterator:iterate(Iterable),
        Perform(fun(Element) -> each(State, fun(V) -> buoy_ref:call(Resolve, C, [V]) end, Element, 0) end, Capability)
    catch
        error:Reason:Stack -> invoke(Reject, buoy_ref:caught(Reason, Stack))
    end,
    P.

%% Steps the iterator one value at a time and calls Element(Index, Next)
%% with the promise of each value from C.resolve. Returns the count at the
%% end. An error after a step closes the iterator; an error of the step
%% itself does not, because the iterator is then done.
each(State, Resolve, Element, Index) ->
    case buoy_ref_iterator:step(State) of
        done ->
            Index;
        {value, V, State1} ->
            try
                Element(Index, Resolve(V))
            catch
                Class:Reason:Stack ->
                    buoy_ref_iterator:close_quietly(State1),
                    erlang:raise(Class, Reason, Stack)
            end,
            each(State1, Resolve, Element, Index + 1)
    end.

%% Promise.race: the first value or reason.
race(Each, {_, Resolve, Reject}) ->
    {OnFulfilled, OnRejected} = {as_js(Resolve), as_js(Reject)},
    Each(fun(_Index, Next) -> buoy_ref:call_method(Next, <<"then">>, [OnFulfilled, OnRejected]) end).

%% Promise.all: an array of the values, or the first reason.
all(Each, {_, Resolve, Reject}) ->
    Finish = fun(Values) -> invoke(Resolve, buoy_heap:new_array(Values)) end,
    OnRejected = as_js(Reject),
    gather(Each, Finish, Finish, fun(Element) -> {Element(fun(V) -> V end), OnRejected} end).

%% Promise.allSettled: an array of the outcomes as objects.
all_settled(Each, {_, Resolve, _}) ->
    Finish = fun(Values) -> invoke(Resolve, buoy_heap:new_array(Values)) end,
    gather(Each, Finish, Finish,
           fun(Element) -> {Element(fun(V) -> outcome(<<"fulfilled">>, <<"value">>, V) end),
                            Element(fun(E) -> outcome(<<"rejected">>, <<"reason">>, E) end)} end).

outcome(Status, Key, V) -> buoy_heap:object(?OBJECT_PROTO, [{<<"status">>, Status}, {Key, V}]).

%% Promise.any: the first value, or an AggregateError of the reasons. When
%% the iterator ends with nothing left, the error is an abrupt completion
%% of the loop, so the frame rejects with it.
any(Each, {_, Resolve, Reject}) ->
    OnFulfilled = as_js(Resolve),
    gather(Each, fun(Errors) -> invoke(Reject, aggregate(Errors)) end,
           fun(Errors) -> erlang:error({'$throw', aggregate(Errors)}) end,
           fun(Element) -> {OnFulfilled, Element(fun(E) -> E end)} end).

aggregate(Errors) ->
    E = buoy_heap:error_object({'$o', 'AggregateError.prototype'}, <<"All promises were rejected">>, <<>>),
    buoy_heap:define(E, <<"errors">>, #{value => buoy_heap:new_array(Errors), writable => true, enumerable => false, configurable => true}),
    E.

%% The loop of all, allSettled, and any. Each value gets an index in the
%% list of results and stays in the remaining count, which starts at 1 for
%% the loop itself, until one of its element functions runs. Handlers gets
%% Element and returns the two functions for then; Element(Wrap) makes an
%% element function, a builtin of length 1 that stores Wrap(X), and the
%% element functions of one index share one alreadyCalled flag. The list
%% goes to Finish when an element function settles the last index, or to
%% Last when the loop ends with nothing remaining.
gather(Each, Finish, Last, Handlers) ->
    Values = buoy_heap:cell(#{}),
    Remaining = buoy_heap:cell(1),
    CountDown = fun(Then) ->
                        case buoy_heap:cell_set(Remaining, buoy_heap:cell_get(Remaining) - 1) of
                            0 -> Then(ordered(buoy_heap:cell_get(Values)));
                            _ -> undefined
                        end
                end,
    _ = Each(fun(Index, Next) ->
                     buoy_heap:cell_set(Values, (buoy_heap:cell_get(Values))#{Index => undefined}),
                     AlreadyCalled = buoy_heap:cell(false),
                     Element = fun(Wrap) ->
                                       buoy_jobs:js_function(fun(X) ->
                                                                     case buoy_heap:cell_get(AlreadyCalled) of
                                                                         true ->
                                                                             undefined;
                                                                         false ->
                                                                             buoy_heap:cell_set(AlreadyCalled, true),
                                                                             buoy_heap:cell_set(Values, (buoy_heap:cell_get(Values))#{Index => Wrap(X)}),
                                                                             CountDown(Finish)
                                                                     end
                                                             end)
                               end,
                     {OnFulfilled, OnRejected} = Handlers(Element),
                     buoy_heap:cell_set(Remaining, buoy_heap:cell_get(Remaining) + 1),
                     buoy_ref:call_method(Next, <<"then">>, [OnFulfilled, OnRejected])
             end),
    CountDown(Last).

ordered(Values) -> [maps:get(I, Values) || I <- lists:seq(0, map_size(Values) - 1)].
