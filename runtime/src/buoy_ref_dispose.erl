%% Explicit resource management: the resources of `using` and `await using`
%% declarations, DisposeResources at the end of their block, and the
%% DisposableStack and AsyncDisposableStack built-ins.
%%
%% The resources of a block are a cell that holds {Value, Hint, Method}
%% entries, newest first, so that disposal runs in reverse order. Hint is
%% sync or async. Method is the dispose method, {sync_as_async, M} for an
%% `await using` of a value that has only Symbol.dispose, or undefined for
%% an `await using` of null or undefined.
%%
%% A DisposableStack or an AsyncDisposableStack is an object of the class
%% disposable_stack or async_disposable_stack whose slots are {State,
%% Resources}: State is pending or disposed, and Resources is such a cell.
%% The SuppressedError constructor is in buoy_ref_error.
-module(buoy_ref_dispose).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).
-export([new/0, add/3, dispose/2, dispose_async/3]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5, callable/1]).

-define(NAMES, [<<"DisposableStack">>, <<"AsyncDisposableStack">>]).

%%% DisposableStack and AsyncDisposableStack

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Sync = ?METHODS(<<"DisposableStack.prototype">>, [{<<"adopt">>, 2}, {<<"defer">>, 1}, {<<"dispose">>, 0}, {<<"move">>, 0}, {<<"use">>, 1}]),
    Async = ?METHODS(<<"AsyncDisposableStack.prototype">>, [{<<"adopt">>, 2}, {<<"defer">>, 1}, {<<"disposeAsync">>, 0}, {<<"move">>, 0}, {<<"use">>, 1}]),
    {_, Dispose} = lists:keyfind(<<"dispose">>, 1, Sync),
    {_, DisposeAsync} = lists:keyfind(<<"disposeAsync">>, 1, Async),
    [prototype(<<"DisposableStack">>, Sync ++ [{?SYM(dispose), Dispose}]),
     prototype(<<"AsyncDisposableStack">>, Async ++ [{?SYM(asyncDispose), DisposeAsync}])]
    ++ [{{builtin, N}, ctor_record(N, 0, {'$o', prototype_id(N)}, [], fun(NT, _) -> construct(N, NT) end)} || N <- ?NAMES].

prototype(Name, Methods) ->
    Owner = <<Name/binary, ".prototype">>,
    Disposed = buoy_ref_realm:builtin(<<"get ", Owner/binary, ".disposed">>, <<"get disposed">>, 0,
                                      fun(This, _) -> ?MODULE:method(Owner, <<"disposed">>, This, []) end),
    {prototype_id(Name), record(object, ?OBJECT_PROTO, Methods
         ++ [{<<"disposed">>, {'$accessor', Disposed, undefined}, 4}, {<<"constructor">>, constructor(Name)}, {?SYM(toStringTag), Name, 4}], none)}.

prototype_id(Name) -> binary_to_atom(<<Name/binary, ".prototype">>).

class(<<"DisposableStack">>) -> disposable_stack;
class(<<"AsyncDisposableStack">>) -> async_disposable_stack.

-spec globals() -> [{binary(), term()}].
globals() -> [{N, constructor(N)} || N <- ?NAMES].

constructor(Name) -> buoy_ref_realm:constructor(?MODULE, Name).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(Name, _This, _Args) -> buoy_ref:type_error(<<"Constructor ", Name/binary, " requires 'new'">>).

construct(Name, NewTarget) ->
    buoy_heap:new_exotic(class(Name), buoy_ref_realm:proto_for(NewTarget, prototype_id(Name)), {pending, new()}).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"AsyncDisposableStack.prototype">>, <<"disposeAsync">>, This, _) ->
    {P, Resolve, Reject} = buoy_jobs:capability(),
    case attempt(fun() -> slots(This, <<"AsyncDisposableStack">>, <<"disposeAsync">>) end) of
        {error, E} -> Reject(E);
        {ok, {disposed, _}} -> Resolve(undefined);
        {ok, {pending, Resources}} ->
            buoy_heap:set_slots(This, {disposed, Resources}),
            dispose_async(Resources, normal, fun({throw, E}) -> Reject(E); (_) -> Resolve(undefined) end)
    end,
    P;
method(<<"DisposableStack.prototype">>, <<"dispose">>, This, _) ->
    case slots(This, <<"DisposableStack">>, <<"dispose">>) of
        {disposed, _} -> undefined;
        {pending, Resources} ->
            buoy_heap:set_slots(This, {disposed, Resources}),
            case dispose(Resources, normal) of
                {throw, E} -> erlang:error({'$throw', E});
                _ -> undefined
            end
    end;
method(Owner, <<"disposed">>, This, _) ->
    element(1, slots(This, stack_name(Owner), <<"disposed">>)) =:= disposed;
method(Owner, Name, This, Args) ->
    Stack = stack_name(Owner),
    case slots(This, Stack, Name) of
        {disposed, _} -> buoy_heap:throw_error('ReferenceError', <<"Cannot call ", Owner/binary, ".", Name/binary, " on an already-disposed ", Stack/binary>>);
        {pending, Resources} -> pending(Name, Stack, This, Resources, Args)
    end.

stack_name(<<"DisposableStack.prototype">>) -> <<"DisposableStack">>;
stack_name(<<"AsyncDisposableStack.prototype">>) -> <<"AsyncDisposableStack">>.

hint(<<"DisposableStack">>) -> sync;
hint(<<"AsyncDisposableStack">>) -> async.

%% The methods that need a pending stack.
pending(<<"use">>, Stack, _This, Resources, Args) ->
    add(Resources, arg(1, Args), hint(Stack));
pending(<<"defer">>, Stack, _This, Resources, Args) ->
    push(Resources, {undefined, hint(Stack), callable(arg(1, Args))}),
    undefined;
pending(<<"adopt">>, Stack, _This, Resources, Args) ->
    V = arg(1, Args),
    OnDispose = callable(arg(2, Args)),
    push(Resources, {undefined, hint(Stack), buoy_heap:function(fun(_, _) -> buoy_ref:call(OnDispose, undefined, [V]) end)}),
    V;
pending(<<"move">>, Stack, This, Resources, _Args) ->
    buoy_heap:set_slots(This, {disposed, new()}),
    buoy_heap:new_exotic(class(Stack), {'$o', prototype_id(Stack)}, {pending, Resources}).

%% RequireInternalSlot: the slots of a stack of the class of Stack.
slots({'$o', _} = O, Stack, Name) ->
    Class = class(Stack),
    case buoy_heap:class_of(O) of
        Class -> buoy_heap:slots(O);
        _ -> incompatible(Stack, Name)
    end;
slots(_, Stack, Name) -> incompatible(Stack, Name).

-spec incompatible(binary(), binary()) -> no_return().
incompatible(Stack, Name) ->
    buoy_ref:type_error(<<"Method ", Stack/binary, ".prototype.", Name/binary, " called on incompatible receiver">>).

%%% Resources

-spec new() -> {'$c', pos_integer()}.
new() -> buoy_heap:cell([]).

%% AddDisposableResource for the value of a `using` (sync) or an `await
%% using` (async) declaration.
-spec add({'$c', pos_integer()}, term(), sync | async) -> term().
add(_Stack, V, sync) when V =:= undefined; V =:= null -> V;
add(Stack, V, async) when V =:= undefined; V =:= null ->
    push(Stack, {undefined, async, undefined}),
    V;
add(Stack, V, Hint) ->
    ?IS_OBJECT(V) orelse buoy_ref:type_error(<<"The value of a using declaration must be an object, null, or undefined">>),
    push(Stack, {V, Hint, dispose_method(V, Hint)}),
    V.

push(Stack, Resource) -> buoy_heap:cell_set(Stack, [Resource | buoy_heap:cell_get(Stack)]).

dispose_method(V, sync) ->
    case get_method(V, ?SYM(dispose)) of
        undefined -> buoy_ref:type_error(<<"The value of a using declaration has no Symbol.dispose method">>);
        M -> M
    end;
dispose_method(V, async) ->
    case get_method(V, ?SYM(asyncDispose)) of
        undefined ->
            case get_method(V, ?SYM(dispose)) of
                undefined -> buoy_ref:type_error(<<"The value of an await using declaration has no Symbol.asyncDispose or Symbol.dispose method">>);
                M -> {sync_as_async, M}
            end;
        M -> M
    end.

get_method(O, K) ->
    case buoy_ref:get(O, K) of
        M when M =:= undefined; M =:= null -> undefined;
        {'$f', _, _} = M -> M;
        M -> buoy_ref:type_error(buoy_ref_string:concat([buoy_ref:describe(M), <<" is not a function">>]))
    end.

%% DisposeResources of a block of `using` declarations: the completion of the
%% block after its resources are disposed, newest first. An error of a
%% dispose method replaces the completion, and suppresses a throw.
-spec dispose({'$c', pos_integer()}, term()) -> term().
dispose(Stack, Completion) ->
    Resources = buoy_heap:cell_get(Stack),
    buoy_heap:cell_set(Stack, []),
    lists:foldl(fun({V, _Hint, Method}, C) ->
                        case attempt(fun() -> buoy_ref:call(Method, V, []) end) of
                            {ok, _} -> C;
                            {error, E} -> suppress(E, C)
                        end
                end, Completion, Resources).

%% DisposeResources of a block with `await using` declarations: Then(C) goes
%% on with the completion once each async dispose settled.
-spec dispose_async({'$c', pos_integer()}, term(), fun((term()) -> term())) -> term().
dispose_async(Stack, Completion, Then) ->
    Resources = buoy_heap:cell_get(Stack),
    buoy_heap:cell_set(Stack, []),
    dispose_each(Resources, Completion, false, false, Then).

dispose_each([], C, NeedsAwait, HasAwaited, Then) ->
    case NeedsAwait andalso not HasAwaited of
        true -> buoy_jobs:await(undefined, fun(_) -> Then(C) end, fun(_) -> Then(C) end);
        false -> Then(C)
    end;
dispose_each([{_, sync, _} | _] = Resources, C, true, false, Then) ->
    buoy_jobs:await(undefined, fun(_) -> dispose_each(Resources, C, false, false, Then) end, fun(_) -> Then(C) end);
dispose_each([{_, _, undefined} | Rest], C, _NeedsAwait, HasAwaited, Then) ->
    dispose_each(Rest, C, true, HasAwaited, Then);
dispose_each([{V, sync, Method} | Rest], C, NeedsAwait, HasAwaited, Then) ->
    case attempt(fun() -> buoy_ref:call(Method, V, []) end) of
        {ok, _} -> dispose_each(Rest, C, NeedsAwait, HasAwaited, Then);
        {error, E} -> dispose_each(Rest, suppress(E, C), NeedsAwait, HasAwaited, Then)
    end;
dispose_each([{V, async, Method} | Rest], C, NeedsAwait, HasAwaited, Then) ->
    Result = case Method of
        {sync_as_async, M} ->
            case attempt(fun() -> buoy_ref:call(M, V, []) end) of
                {ok, _} -> {ok, undefined};
                {error, E} -> {ok, buoy_jobs:rejected(E)}
            end;
        _ -> attempt(fun() -> buoy_ref:call(Method, V, []) end)
    end,
    Next = fun(C1) -> dispose_each(Rest, C1, NeedsAwait, true, Then) end,
    case Result of
        {ok, R} -> buoy_jobs:await(R, fun(_) -> Next(C) end, fun(E2) -> Next(suppress(E2, C)) end);
        {error, E3} -> dispose_each(Rest, suppress(E3, C), NeedsAwait, HasAwaited, Then)
    end.

suppress(E, {throw, Suppressed}) ->
    {throw, buoy_ref_error:call_constructor(<<"SuppressedError">>, undefined, [E, Suppressed])};
suppress(E, _Completion) ->
    {throw, E}.

attempt(F) ->
    try F() of
        V -> {ok, V}
    catch
        error:Reason:Stack -> {error, buoy_ref:caught(Reason, Stack)}
    end.
