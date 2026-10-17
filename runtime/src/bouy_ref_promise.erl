%% The Promise family: the Promise constructor, its statics, and
%% Promise.prototype. bouy_jobs holds the promise states and the job queue.
-module(bouy_ref_promise).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, constructor/0]).

-import(bouy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Promise.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"Promise.prototype">>, [<<"then">>, <<"catch">>, <<"finally">>]) ++ [{<<"constructor">>, constructor()}, {?SYM(toStringTag), <<"Promise">>}], none)},
     {{builtin, <<"Promise">>}, ctor_record(<<"Promise">>, 1, {'$o', 'Promise.prototype'}, ?METHODS(<<"Promise">>, [<<"resolve">>, <<"reject">>, <<"all">>, <<"allSettled">>, <<"race">>, <<"any">>, <<"withResolvers">>]), fun promise_construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Promise">>, constructor()}].

-spec constructor() -> term().
constructor() -> bouy_ref_realm:constructor(?MODULE, <<"Promise">>).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(Name, _This, _Args) -> type_error(<<"Constructor ", Name/binary, " requires 'new'">>).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Promise.prototype">>, Name, This, Args) -> promise_proto(Name, This, Args);
method(<<"Promise">>, Name, _This, Args) -> promise_static(Name, Args).

promise_construct(_NewTarget, Args) ->
    Executor = arg(1, Args),
    bouy_heap:is_callable(Executor) orelse
        type_error(<<"Promise resolver ", (bouy_ref:describe(Executor))/binary, " is not a function">>),
    P = bouy_jobs:new_promise(),
    {Resolve, Reject} = bouy_jobs:resolving_functions(P),
    try bouy_ref:call(Executor, undefined, [js(Resolve), js(Reject)]) of
        _ -> ok
    catch
        error:Reason:Stack -> Reject(bouy_ref:caught(Reason, Stack))
    end,
    P.

js(Fun) -> bouy_heap:function(fun(_This, Args) -> Fun(arg(1, Args)) end).

promise_proto(<<"then">>, P, Args) ->
    bouy_jobs:is_promise(P) orelse type_error(<<"Method Promise.prototype.then called on incompatible receiver">>),
    bouy_jobs:then(P, arg(1, Args), arg(2, Args));
promise_proto(<<"catch">>, P, Args) ->
    bouy_ref:call_method(P, <<"then">>, [undefined, arg(1, Args)]);
promise_proto(<<"finally">>, P, Args) ->
    case arg(1, Args) of
        {'$f', _, _} = OnFinally ->
            ThenFinally = bouy_heap:function(fun(_, [Value | _]) ->
                Result = bouy_ref:call(OnFinally, undefined, []),
                Promise = bouy_jobs:promise_resolve(Result),
                bouy_ref:call_method(Promise, <<"then">>, [bouy_heap:function(fun(_, _) -> Value end)])
            end),
            CatchFinally = bouy_heap:function(fun(_, [Reason | _]) ->
                Result = bouy_ref:call(OnFinally, undefined, []),
                Promise = bouy_jobs:promise_resolve(Result),
                bouy_ref:call_method(Promise, <<"then">>, [bouy_heap:function(fun(_, _) -> erlang:error({'$throw', Reason}) end)])
            end),
            bouy_ref:call_method(P, <<"then">>, [ThenFinally, CatchFinally]);
        Other ->
            bouy_ref:call_method(P, <<"then">>, [Other, Other])
    end.

promise_static(<<"resolve">>, Args) -> bouy_jobs:promise_resolve(arg(1, Args));
promise_static(<<"reject">>, Args) -> bouy_jobs:rejected(arg(1, Args));
promise_static(<<"all">>, Args) -> settle_list(fun(L) -> bouy_jobs:all(L, true) end, Args);
promise_static(<<"allSettled">>, Args) -> settle_list(fun bouy_jobs:all_settled/1, Args);
promise_static(<<"race">>, Args) -> settle_list(fun bouy_jobs:race/1, Args);
promise_static(<<"any">>, Args) -> settle_list(fun bouy_jobs:any/1, Args);
promise_static(<<"withResolvers">>, _Args) ->
    {P, Resolve, Reject} = bouy_jobs:capability(),
    bouy_heap:object(?OBJECT_PROTO, [{<<"promise">>, P}, {<<"resolve">>, js(Resolve)}, {<<"reject">>, js(Reject)}]).

%% An iterable that throws rejects the result instead of throwing.
settle_list(Combinator, Args) ->
    try bouy_ref_iterator:to_list(arg(1, Args)) of
        L -> Combinator(L)
    catch
        error:Reason:Stack -> bouy_jobs:rejected(bouy_ref:caught(Reason, Stack))
    end.
