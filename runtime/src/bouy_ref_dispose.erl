%% Explicit resource management: the resources of `using` and `await using`
%% declarations, DisposeResources at the end of their block, and
%% SuppressedError.
%%
%% The resources of a block are a cell that holds {Value, Hint, Method}
%% entries, newest first, so that disposal runs in reverse order. Hint is
%% sync or async. Method is the dispose method, {sync_as_async, M} for an
%% `await using` of a value that has only Symbol.dispose, or undefined for
%% an `await using` of null or undefined.
-module(bouy_ref_dispose).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).
-export([new/0, add/3, dispose/2, dispose_async/3]).

-import(bouy_ref_realm, [arg/2, record/4, ctor_record/5]).

%%% SuppressedError

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'SuppressedError.prototype', record(object, {'$o', 'Error.prototype'},
        [{<<"name">>, <<"SuppressedError">>}, {<<"message">>, <<>>}, {<<"constructor">>, constructor()}], none)},
     {{builtin, <<"SuppressedError">>}, ctor_record(<<"SuppressedError">>, 3, {'$o', 'SuppressedError.prototype'}, [], fun construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"SuppressedError">>, constructor()}].

constructor() -> bouy_ref_realm:constructor(?MODULE, <<"SuppressedError">>).

-spec method(binary(), binary(), term(), list()) -> no_return().
method(Owner, Name, _This, _Args) -> erlang:error({no_method, Owner, Name}).

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(_Name, _This, Args) -> construct(constructor(), Args).

%% new SuppressedError(error, suppressed, message).
construct(NewTarget, Args) ->
    Proto = case NewTarget of
        {'$f', {builtin, _}, _} -> {'$o', 'SuppressedError.prototype'};
        _ ->
            case bouy_ref:get(NewTarget, <<"prototype">>) of
                P when ?IS_OBJECT(P) -> P;
                _ -> {'$o', 'SuppressedError.prototype'}
            end
    end,
    suppressed_error(Proto, arg(1, Args), arg(2, Args), arg(3, Args)).

suppressed_error(Proto, Error, Suppressed, MessageArg) ->
    E = bouy_heap:error_object(Proto, <<>>, <<"SuppressedError\n    at <anonymous>">>),
    case MessageArg of
        undefined -> bouy_heap:delete(E, <<"message">>);
        M -> bouy_heap:define(E, <<"message">>, #{value => bouy_ref:to_string(M), writable => true, enumerable => false, configurable => true})
    end,
    bouy_heap:define(E, <<"error">>, #{value => Error, writable => true, enumerable => false, configurable => true}),
    bouy_heap:define(E, <<"suppressed">>, #{value => Suppressed, writable => true, enumerable => false, configurable => true}),
    E.

%%% Resources

-spec new() -> {'$c', pos_integer()}.
new() -> bouy_heap:cell([]).

%% AddDisposableResource for the value of a `using` (sync) or an `await
%% using` (async) declaration.
-spec add({'$c', pos_integer()}, term(), sync | async) -> term().
add(_Stack, V, sync) when V =:= undefined; V =:= null -> V;
add(Stack, V, async) when V =:= undefined; V =:= null ->
    push(Stack, {undefined, async, undefined}),
    V;
add(Stack, V, Hint) ->
    ?IS_OBJECT(V) orelse bouy_ref:type_error(<<"The value of a using declaration must be an object, null, or undefined">>),
    push(Stack, {V, Hint, dispose_method(V, Hint)}),
    V.

push(Stack, Resource) -> bouy_heap:cell_set(Stack, [Resource | bouy_heap:cell_get(Stack)]).

dispose_method(V, sync) ->
    case get_method(V, ?SYM(dispose)) of
        undefined -> bouy_ref:type_error(<<"The value of a using declaration has no Symbol.dispose method">>);
        M -> M
    end;
dispose_method(V, async) ->
    case get_method(V, ?SYM(asyncDispose)) of
        undefined ->
            case get_method(V, ?SYM(dispose)) of
                undefined -> bouy_ref:type_error(<<"The value of an await using declaration has no Symbol.asyncDispose or Symbol.dispose method">>);
                M -> {sync_as_async, M}
            end;
        M -> M
    end.

get_method(O, K) ->
    case bouy_ref:get(O, K) of
        M when M =:= undefined; M =:= null -> undefined;
        {'$f', _, _} = M -> M;
        M -> bouy_ref:type_error(bouy_ref_string:concat([bouy_ref:describe(M), <<" is not a function">>]))
    end.

%% DisposeResources of a block of `using` declarations: the completion of the
%% block after its resources are disposed, newest first. An error of a
%% dispose method replaces the completion, and suppresses a throw.
-spec dispose({'$c', pos_integer()}, term()) -> term().
dispose(Stack, Completion) ->
    Resources = bouy_heap:cell_get(Stack),
    bouy_heap:cell_set(Stack, []),
    lists:foldl(fun({V, _Hint, Method}, C) ->
                        case attempt(fun() -> bouy_ref:call(Method, V, []) end) of
                            {ok, _} -> C;
                            {error, E} -> suppress(E, C)
                        end
                end, Completion, Resources).

%% DisposeResources of a block with `await using` declarations: Then(C) goes
%% on with the completion once each async dispose settled.
-spec dispose_async({'$c', pos_integer()}, term(), fun((term()) -> term())) -> term().
dispose_async(Stack, Completion, Then) ->
    Resources = bouy_heap:cell_get(Stack),
    bouy_heap:cell_set(Stack, []),
    dispose_each(Resources, Completion, false, false, Then).

dispose_each([], C, NeedsAwait, HasAwaited, Then) ->
    case NeedsAwait andalso not HasAwaited of
        true -> bouy_jobs:await(undefined, fun(_) -> Then(C) end, fun(_) -> Then(C) end);
        false -> Then(C)
    end;
dispose_each([{_, sync, _} | _] = Resources, C, true, false, Then) ->
    bouy_jobs:await(undefined, fun(_) -> dispose_each(Resources, C, false, false, Then) end, fun(_) -> Then(C) end);
dispose_each([{_, _, undefined} | Rest], C, _NeedsAwait, HasAwaited, Then) ->
    dispose_each(Rest, C, true, HasAwaited, Then);
dispose_each([{V, sync, Method} | Rest], C, NeedsAwait, HasAwaited, Then) ->
    case attempt(fun() -> bouy_ref:call(Method, V, []) end) of
        {ok, _} -> dispose_each(Rest, C, NeedsAwait, HasAwaited, Then);
        {error, E} -> dispose_each(Rest, suppress(E, C), NeedsAwait, HasAwaited, Then)
    end;
dispose_each([{V, async, Method} | Rest], C, NeedsAwait, HasAwaited, Then) ->
    Result = case Method of
        {sync_as_async, M} ->
            case attempt(fun() -> bouy_ref:call(M, V, []) end) of
                {ok, _} -> {ok, undefined};
                {error, E} -> {ok, bouy_jobs:rejected(E)}
            end;
        _ -> attempt(fun() -> bouy_ref:call(Method, V, []) end)
    end,
    Next = fun(C1) -> dispose_each(Rest, C1, NeedsAwait, true, Then) end,
    case Result of
        {ok, R} -> bouy_jobs:await(R, fun(_) -> Next(C) end, fun(E2) -> Next(suppress(E2, C)) end);
        {error, E3} -> dispose_each(Rest, suppress(E3, C), NeedsAwait, HasAwaited, Then)
    end.

suppress(E, {throw, Suppressed}) ->
    {throw, suppressed_error({'$o', 'SuppressedError.prototype'}, E, Suppressed, undefined)};
suppress(E, _Completion) ->
    {throw, E}.

attempt(F) ->
    try F() of
        V -> {ok, V}
    catch
        error:Reason:Stack -> {error, bouy_ref:caught(Reason, Stack)}
    end.
