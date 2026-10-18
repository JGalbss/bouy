%% The Generator family: generator and async generator objects, the
%% prototypes of generator, async generator, and async functions, yield*,
%% and the async-from-sync iterator of for await.
%%
%% A generator body is a fun that returns {yield, V, Continuation},
%% {yield_raw, Result, Continuation} for a step of yield* whose result object
%% next() returns as it is, or {done, V}. A Continuation takes the
%% resumption: {next, V}, {throw, E}, or {return, V}.
%%
%% An async generator body is fun(Resolve, Reject, Yield): Resolve and Reject
%% end the body, and Yield(V, Continuation) completes the oldest request with
%% V. The slots of an async generator are {State, Queue}: the queue holds
%% {Completion, Capability} pairs, oldest first, as AsyncGeneratorQueue.
-module(buoy_ref_generator).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4]).
-export([function/4, static_record/5, start/2, start_async/2, resume/2]).
-export([yield_star/4, yield_star_async/5, async_iterator/1, from_sync/1, async_close/4]).

-import(buoy_ref_realm, [arg/2, builtin/2, record/4, ctor_record/5]).

-define(GENERATOR_PROTO, buoy_heap:intrinsic('Generator.prototype')).
-define(ASYNC_GENERATOR_PROTO, buoy_heap:intrinsic('AsyncGenerator.prototype')).

%%% Intrinsics

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Tag = fun(Name) -> {?SYM(toStringTag), Name} end,
    %% The links between a function prototype, its constructor, and the prototype
    %% of its instances are not writable.
    Fixed = [<<"constructor">>, <<"prototype">>, ?SYM(toStringTag)],
    Methods = [<<"next">>, <<"return">>, <<"throw">>],
    [{'Generator.prototype', fixed(record(object, ?ITERATOR_PROTO,
        ?METHODS(<<"Generator.prototype">>, Methods)
        ++ [{<<"constructor">>, {'$o', 'GeneratorFunction.prototype'}}, Tag(<<"Generator">>)], none), Fixed)},
     {'GeneratorFunction.prototype', fixed(record(object, ?FUNCTION_PROTO,
        [{<<"constructor">>, constructor(<<"GeneratorFunction">>)}, {<<"prototype">>, ?GENERATOR_PROTO},
         Tag(<<"GeneratorFunction">>)], none), Fixed)},
     {'AsyncIterator.prototype', record(object, ?OBJECT_PROTO,
        [{?SYM(asyncIterator), builtin(<<"AsyncIterator.prototype.[Symbol.asyncIterator]">>, fun(This, _) -> This end)},
         {?SYM(asyncDispose), builtin(<<"AsyncIterator.prototype.[Symbol.asyncDispose]">>, fun(This, _) -> async_dispose(This) end)}], none)},
     {'AsyncGenerator.prototype', fixed(record(object, {'$o', 'AsyncIterator.prototype'},
        ?METHODS(<<"AsyncGenerator.prototype">>, Methods)
        ++ [{<<"constructor">>, {'$o', 'AsyncGeneratorFunction.prototype'}}, Tag(<<"AsyncGenerator">>)], none), Fixed)},
     {'AsyncGeneratorFunction.prototype', fixed(record(object, ?FUNCTION_PROTO,
        [{<<"constructor">>, constructor(<<"AsyncGeneratorFunction">>)}, {<<"prototype">>, ?ASYNC_GENERATOR_PROTO},
         Tag(<<"AsyncGeneratorFunction">>)], none), Fixed)},
     {'AsyncFunction.prototype', fixed(record(object, ?FUNCTION_PROTO,
        [{<<"constructor">>, constructor(<<"AsyncFunction">>)}, Tag(<<"AsyncFunction">>)], none), Fixed)},
     {'AsyncFromSyncIterator.prototype', record(object, {'$o', 'AsyncIterator.prototype'},
        ?METHODS(<<"AsyncFromSyncIterator.prototype">>, Methods), none)}]
    ++ [{{builtin, <<"AsyncIterator.prototype.[Symbol.asyncIterator]">>}, function_record(<<"[Symbol.asyncIterator]">>, 0)},
        {{builtin, <<"AsyncIterator.prototype.[Symbol.asyncDispose]">>}, function_record(<<"[Symbol.asyncDispose]">>, 0)}]
    ++ [{{builtin, <<Owner/binary, ".", Name/binary>>}, function_record(Name, 1)}
        || Owner <- [<<"Generator.prototype">>, <<"AsyncGenerator.prototype">>, <<"AsyncFromSyncIterator.prototype">>],
           Name <- Methods]
    ++ [{{builtin, Name}, kind_constructor(Name, Kind, Proto)}
        || {Name, Kind, Proto} <- [{<<"GeneratorFunction">>, generator, 'GeneratorFunction.prototype'},
                                   {<<"AsyncGeneratorFunction">>, async_generator, 'AsyncGeneratorFunction.prototype'},
                                   {<<"AsyncFunction">>, async, 'AsyncFunction.prototype'}]].

%% %GeneratorFunction%, %AsyncGeneratorFunction%, and %AsyncFunction% build a
%% function of their kind from source text (CreateDynamicFunction), and
%% inherit from %Function%. They are not globals.
constructor(Name) ->
    {'$f', {builtin, Name}, fun(This, Args) -> buoy_ref_function:call_constructor(Name, This, Args) end}.

kind_constructor(Name, Kind, Proto) ->
    {Class, _, Props, Keys, Attrs, Slots} =
        ctor_record(Name, 1, {'$o', Proto}, [], fun(NewTarget, Args) -> buoy_ref_eval:create_function(Kind, Args, NewTarget) end),
    {Class, buoy_ref_realm:constructor(buoy_ref_function, <<"Function">>), Props, Keys, Attrs, Slots}.

%% A record whose Keys are configurable but not writable.
fixed({Class, Proto, Props, Keys, Attrs, Slots}, Fixed) ->
    {Class, Proto, Props, Keys, maps:merge(Attrs, maps:from_list([{K, 4} || K <- Fixed, is_map_key(K, Props)])), Slots}.

function_record(Name, Length) ->
    {function, ?FUNCTION_PROTO, #{<<"name">> => Name, <<"length">> => Length}, [<<"name">>, <<"length">>],
     #{<<"name">> => 4, <<"length">> => 4}, #{}}.

-spec globals() -> [{binary(), term()}].
globals() -> [].

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Generator.prototype">>, Name, This, Args) ->
    is_generator(This) orelse
        buoy_ref:type_error(<<"Generator.prototype.", Name/binary, " called on an object that is not a generator">>),
    case resume(This, resumption(Name, Args)) of
        {yield, V} -> buoy_ref_iterator:result(V, false);
        {yield_raw, Result} -> Result;
        {done, V} -> buoy_ref_iterator:result(V, true)
    end;
method(<<"AsyncGenerator.prototype">>, Name, This, Args) ->
    async_request(This, resumption(Name, Args));
method(<<"AsyncFromSyncIterator.prototype">>, Name, This, Args) ->
    from_sync_method(Name, This, Args).

resumption(<<"next">>, Args) -> {next, arg(1, Args)};
resumption(<<"return">>, Args) -> {return, arg(1, Args)};
resumption(<<"throw">>, Args) -> {throw, arg(1, Args)}.

%%% Function objects

%% A function object of Kind with a name and a length. A generator or an
%% async generator takes a maker, fun((SelfId) -> Fun), and gets its own
%% prototype object, from which its generators inherit.
-spec function(term(), term(), non_neg_integer(), atom()) -> term().
function(Maker, Name, Length, Kind) when Kind =:= generator; Kind =:= async_generator ->
    {'$f', Id, _} = buoy_heap:function(fun buoy_ref:class_call/2, Name, Length, #{kind => Kind}),
    F = {'$f', Id, in_realm(Maker(Id))},
    {Parent, FunctionProto} = case Kind of
        generator -> {?GENERATOR_PROTO, buoy_heap:intrinsic('GeneratorFunction.prototype')};
        async_generator -> {?ASYNC_GENERATOR_PROTO, buoy_heap:intrinsic('AsyncGeneratorFunction.prototype')}
    end,
    buoy_heap:define(F, <<"prototype">>, #{value => buoy_heap:new_object(Parent), writable => true, enumerable => false, configurable => false}),
    buoy_heap:set_prototype_of(F, FunctionProto),
    F;
function(Fun, Name, Length, normal) ->
    buoy_ref:named_fn(Fun, Name, Length);
function(Fun, Name, Length, sloppy) ->
    buoy_ref:named_fn(Fun, Name, Length, sloppy);
function(Fun3, Name, Length, normal_nt) ->
    F = buoy_ref:named_fn(fun(This, Args) -> Fun3(This, Args, undefined) end, Name, Length),
    Construct = in_realm(fun(NewTarget, Args) -> buoy_ref_class:new_target_construct(Fun3, NewTarget, Args) end),
    buoy_heap:set_slots(F, (buoy_heap:slots(F))#{kind => normal, construct => Construct}),
    F;
function(Fun, Name, Length, async) ->
    F = buoy_heap:function(Fun, Name, Length, #{kind => async}),
    buoy_heap:set_prototype_of(F, buoy_heap:intrinsic('AsyncFunction.prototype')),
    F;
function(Fun, Name, Length, Kind) ->
    buoy_heap:function(Fun, Name, Length, #{kind => Kind}).

%% Fun as a function of the current realm, as buoy_heap:function/4 makes it.
in_realm(Fun) ->
    case buoy_heap:realm() of
        0 -> Fun;
        N -> buoy_ref_realm:realm_fun(N, Fun)
    end.

%% The record of the static value of a module-level function of Form, which
%% each realm makes on first use (buoy_heap).
-spec static_record(atom(), module(), binary(), non_neg_integer(), term()) -> tuple().
static_record(Form, Module, Name, Length, F) ->
    Props = #{<<"length">> => Length, <<"name">> => Name},
    Attrs = #{<<"length">> => 4, <<"name">> => 4},
    Keys = [<<"name">>, <<"length">>],
    case Form of
        fn_nt ->
            Proto = buoy_heap:new_object(?OBJECT_PROTO),
            buoy_heap:define(Proto, <<"constructor">>, #{value => F, writable => true, enumerable => false, configurable => true}),
            Fun3 = erlang:make_fun(Module, binary_to_atom(buoy_ref_string:to_utf8(Name), utf8), 3),
            Construct = fun(NewTarget, Args) -> buoy_ref_class:new_target_construct(Fun3, NewTarget, Args) end,
            {function, ?FUNCTION_PROTO, Props#{<<"prototype">> => Proto}, [<<"prototype">> | Keys],
             Attrs#{<<"prototype">> => 1}, #{kind => normal, construct => Construct}};
        async ->
            {function, buoy_heap:intrinsic('AsyncFunction.prototype'), Props, Keys, Attrs, #{kind => async}};
        generator ->
            Proto = buoy_heap:new_object(?GENERATOR_PROTO),
            {function, buoy_heap:intrinsic('GeneratorFunction.prototype'), Props#{<<"prototype">> => Proto}, [<<"prototype">> | Keys],
             Attrs#{<<"prototype">> => 1}, #{kind => generator}};
        async_generator ->
            Proto = buoy_heap:new_object(?ASYNC_GENERATOR_PROTO),
            {function, buoy_heap:intrinsic('AsyncGeneratorFunction.prototype'), Props#{<<"prototype">> => Proto}, [<<"prototype">> | Keys],
             Attrs#{<<"prototype">> => 1}, #{kind => async_generator}}
    end.

%% The prototype of the generators of the function Self: its prototype
%% property when that is an object. Self is the function, or the id of its
%% record.
own_prototype(Id, Default) when is_integer(Id) -> own_prototype({'$f', Id, undefined}, Default);
own_prototype(Self, Default) ->
    case buoy_ref:get(Self, <<"prototype">>) of
        P when ?IS_OBJECT(P) -> P;
        _ -> Default
    end.

%%% Generators

-spec start(term(), fun(() -> term())) -> term().
start(Self, Body) ->
    buoy_heap:new_exotic(generator, own_prototype(Self, ?GENERATOR_PROTO), {suspended_start, Body}).

is_generator({'$o', _} = O) -> buoy_heap:class_of(O) =:= generator;
is_generator(_) -> false.

%% GeneratorResume and GeneratorResumeAbrupt.
-spec resume(term(), {next | throw | return, term()}) -> {yield | yield_raw | done, term()}.
resume(G, Resumption) ->
    case buoy_heap:slots(G) of
        {suspended_start, Start} ->
            case Resumption of
                {next, _} -> run(G, Start);
                {return, V} -> buoy_heap:set_slots(G, completed), {done, V};
                {throw, E} -> buoy_heap:set_slots(G, completed), erlang:error({'$throw', E})
            end;
        {suspended_yield, Continuation} ->
            run(G, fun() -> Continuation(Resumption) end);
        executing ->
            buoy_ref:type_error(<<"Generator is already running">>);
        completed ->
            case Resumption of
                {next, _} -> {done, undefined};
                {return, V} -> {done, V};
                {throw, E} -> erlang:error({'$throw', E})
            end
    end.

run(G, Body) ->
    buoy_heap:set_slots(G, executing),
    try Body() of
        {yield, V, Continuation} ->
            buoy_heap:set_slots(G, {suspended_yield, Continuation}),
            {yield, V};
        {yield_raw, Result, Continuation} ->
            buoy_heap:set_slots(G, {suspended_yield, Continuation}),
            {yield_raw, Result};
        {done, V} ->
            buoy_heap:set_slots(G, completed),
            {done, V}
    catch
        Class:Reason:Stack ->
            buoy_heap:set_slots(G, completed),
            erlang:raise(Class, Reason, Stack)
    end.

%% yield* in a generator: Done(V) goes on after the yield* with the value of
%% the inner iterator's last result, Throw(E) throws at the yield*, and
%% Return(V) returns from the generator there.
-spec yield_star(term(), fun((term()) -> term()), fun((term()) -> term()), fun((term()) -> term())) -> term().
yield_star(Iterable, Done, Throw, Return) ->
    case attempt(fun() -> buoy_ref_iterator:get_iterator(Iterable) end) of
        {ok, {Iterator, Next}} -> delegate(Iterator, Next, {next, undefined}, Done, Throw, Return);
        {error, E} -> Throw(E)
    end.

delegate(Iterator, Next, Received, Done, Throw, Return) ->
    Again = fun(Resumption) -> delegate(Iterator, Next, Resumption, Done, Throw, Return) end,
    Step = fun(Result) ->
        case attempt(fun() -> {object(Result), buoy_ref:truthy(buoy_ref:get(Result, <<"done">>))} end) of
            {ok, {_, true}} -> {done, Result};
            {ok, {_, false}} -> {yield_raw, Result, Again};
            {error, E} -> {error, E}
        end
    end,
    Outcome = case Received of
        {next, V} ->
            case attempt(fun() -> buoy_ref:call(Next, Iterator, [V]) end) of
                {ok, Result} -> Step(Result);
                Error -> Error
            end;
        {throw, E} ->
            case attempt(fun() -> get_method(Iterator, <<"throw">>) end) of
                {ok, undefined} ->
                    case attempt(fun() -> buoy_ref_iterator:close(Iterator) end) of
                        {ok, _} -> {error, type_error_object(<<"The iterator does not provide a 'throw' method">>)};
                        CloseError -> CloseError
                    end;
                {ok, Method} ->
                    case attempt(fun() -> buoy_ref:call(Method, Iterator, [E]) end) of
                        {ok, Result} -> Step(Result);
                        Error -> Error
                    end;
                Error -> Error
            end;
        {return, V} ->
            case attempt(fun() -> get_method(Iterator, <<"return">>) end) of
                {ok, undefined} -> {return, V};
                {ok, Method} ->
                    case attempt(fun() -> buoy_ref:call(Method, Iterator, [V]) end) of
                        {ok, Result} ->
                            case Step(Result) of
                                {done, R} -> returned(R);
                                Other -> Other
                            end;
                        Error -> Error
                    end;
                Error -> Error
            end
    end,
    case Outcome of
        {done, Final} ->
            case attempt(fun() -> buoy_ref:get(Final, <<"value">>) end) of
                {ok, Value} -> Done(Value);
                {error, E2} -> Throw(E2)
            end;
        {returned, Value} -> Return(Value);
        {return, Value} -> Return(Value);
        {yield_raw, _, _} = Yield -> Yield;
        {error, E3} -> Throw(E3)
    end.

returned(Result) ->
    case attempt(fun() -> buoy_ref:get(Result, <<"value">>) end) of
        {ok, Value} -> {returned, Value};
        Error -> Error
    end.

object(V) when ?IS_OBJECT(V) -> V;
object(V) -> buoy_ref:type_error(buoy_ref_string:concat([<<"Iterator result ">>, buoy_ref:describe(V), <<" is not an object">>])).

get_method(O, K) ->
    case buoy_ref:get(O, K) of
        M when M =:= undefined; M =:= null -> undefined;
        {'$f', _, _} = M -> M;
        M -> buoy_ref:type_error(buoy_ref_string:concat([buoy_ref:describe(M), <<" is not a function">>]))
    end.

%% Runs F and returns {ok, Value}, or {error, JsValue} for a throw.
attempt(F) ->
    try F() of
        V -> {ok, V}
    catch
        error:Reason:Stack -> {error, buoy_ref:caught(Reason, Stack)}
    end.

type_error_object(Message) ->
    buoy_heap:error_object('TypeError', Message, buoy_ref_string:concat(<<"TypeError: ">>, Message)).

%%% Async generators

-spec start_async(term(), fun((fun(), fun(), fun()) -> term())) -> term().
start_async(Self, Body) ->
    buoy_heap:new_exotic(async_generator, own_prototype(Self, ?ASYNC_GENERATOR_PROTO), {{suspended_start, Body}, []}).

is_async_generator({'$o', _} = O) -> buoy_heap:class_of(O) =:= async_generator;
is_async_generator(_) -> false.

%% next, return, and throw of %AsyncGeneratorPrototype%.
async_request(G, Completion) ->
    {P, Resolve, Reject} = buoy_jobs:capability(),
    case is_async_generator(G) of
        false ->
            Reject(type_error_object(<<"AsyncGenerator method called on an object that is not an async generator">>));
        true ->
            {State, Queue} = buoy_heap:slots(G),
            request(G, State, Queue, Completion, {P, Resolve, Reject})
    end,
    P.

request(_G, completed, _Queue, {next, _}, {_, Resolve, _}) ->
    Resolve(buoy_ref_iterator:result(undefined, true));
request(_G, completed, _Queue, {throw, E}, {_, _, Reject}) ->
    Reject(E);
request(G, {suspended_start, _}, _Queue, {throw, E}, {_, _, Reject}) ->
    buoy_heap:set_slots(G, {completed, []}),
    Reject(E);
request(G, State, Queue, {return, _} = Completion, Capability) when State =:= completed; element(1, State) =:= suspended_start ->
    buoy_heap:set_slots(G, {draining, Queue ++ [{Completion, Capability}]}),
    await_return(G);
request(G, State, Queue, Completion, Capability) ->
    buoy_heap:set_slots(G, {State, Queue ++ [{Completion, Capability}]}),
    case State of
        {suspended_start, _} -> resume_async(G, Completion);
        {suspended_yield, _} -> resume_async(G, Completion);
        _ -> ok
    end.

%% AsyncGeneratorResume.
resume_async(G, Completion) ->
    {State, Queue} = buoy_heap:slots(G),
    buoy_heap:set_slots(G, {executing, Queue}),
    case State of
        {suspended_start, Body} ->
            Body(fun(V) -> finish(G, {normal, V}) end,
                 fun(E) -> finish(G, {throw, E}) end,
                 fun(V, Continuation) -> async_yield(G, V, Continuation) end);
        {suspended_yield, Continuation} ->
            Continuation(Completion)
    end,
    ok.

%% AsyncGeneratorYield, with V awaited already.
async_yield(G, V, Continuation) ->
    complete_step(G, {normal, V}, false),
    case buoy_heap:slots(G) of
        {_, [{Completion, _} | _]} -> Continuation(Completion);
        {_, []} -> buoy_heap:set_slots(G, {{suspended_yield, Continuation}, []})
    end,
    ok.

%% The body ended with a return value or a throw.
finish(G, Completion) ->
    {_, Queue} = buoy_heap:slots(G),
    buoy_heap:set_slots(G, {draining, Queue}),
    complete_step(G, Completion, true),
    drain(G),
    undefined.

%% AsyncGeneratorCompleteStep: settles the oldest request.
complete_step(G, Completion, Done) ->
    {State, [{_, {_, Resolve, Reject}} | Rest]} = buoy_heap:slots(G),
    buoy_heap:set_slots(G, {State, Rest}),
    case Completion of
        {throw, E} -> Reject(E);
        {normal, V} -> Resolve(buoy_ref_iterator:result(V, Done))
    end.

%% AsyncGeneratorDrainQueue.
drain(G) ->
    case buoy_heap:slots(G) of
        {_, []} -> buoy_heap:set_slots(G, {completed, []});
        {_, [{{return, _}, _} | _]} -> await_return(G);
        {_, [{{throw, E}, _} | _]} -> complete_step(G, {throw, E}, true), drain(G);
        {_, [{{next, _}, _} | _]} -> complete_step(G, {normal, undefined}, true), drain(G)
    end.

%% AsyncGeneratorAwaitReturn.
await_return(G) ->
    {_, [{{return, V}, _} | _]} = buoy_heap:slots(G),
    case attempt(fun() -> buoy_jobs:promise_resolve(V) end) of
        {ok, Promise} ->
            Settle = fun(Completion) -> complete_step(G, Completion, true), drain(G) end,
            buoy_jobs:perform_then(Promise, fun(R) -> Settle({normal, R}) end, fun(E) -> Settle({throw, E}) end, undefined);
        {error, E} ->
            complete_step(G, {throw, E}, true),
            drain(G)
    end.

%% yield* in an async generator. Yield(V, Continuation) is the yield of the
%% generator, and Done, Throw, and Return are as for yield_star/4.
-spec yield_star_async(term(), fun(), fun((term()) -> term()), fun((term()) -> term()), fun((term()) -> term())) -> term().
yield_star_async(Iterable, Yield, Done, Throw, Return) ->
    case attempt(fun() -> async_iterator(Iterable) end) of
        {ok, {Iterator, Next}} -> delegate_async(Iterator, Next, {next, undefined}, Yield, Done, Throw, Return);
        {error, E} -> Throw(E)
    end.

delegate_async(Iterator, Next, Received, Yield, Done, Throw, Return) ->
    Again = fun(Resumption) -> resumed_async(Iterator, Next, Resumption, Yield, Done, Throw, Return) end,
    %% An awaited inner result: its value goes on with OnDone when done is
    %% true, else the generator yields it.
    Awaited = fun(Result, OnDone) ->
        buoy_jobs:await(Result,
            fun(R) ->
                case attempt(fun() -> {buoy_ref:truthy(buoy_ref:get(object(R), <<"done">>)), R} end) of
                    {ok, {true, _}} ->
                        case attempt(fun() -> buoy_ref:get(R, <<"value">>) end) of
                            {ok, Value} -> OnDone(Value);
                            {error, E} -> Throw(E)
                        end;
                    {ok, {false, _}} ->
                        case attempt(fun() -> buoy_ref:get(R, <<"value">>) end) of
                            {ok, Value} -> Yield(Value, Again);
                            {error, E} -> Throw(E)
                        end;
                    {error, E} -> Throw(E)
                end
            end,
            Throw)
    end,
    Call = fun(Method, Args, OnDone) ->
        case attempt(fun() -> buoy_ref:call(Method, Iterator, Args) end) of
            {ok, Result} -> Awaited(Result, OnDone);
            {error, E} -> Throw(E)
        end
    end,
    case Received of
        {next, V} ->
            Call(Next, [V], Done);
        {throw, E} ->
            case attempt(fun() -> get_method(Iterator, <<"throw">>) end) of
                {ok, undefined} ->
                    Fail = fun() -> Throw(type_error_object(<<"The iterator does not provide a 'throw' method">>)) end,
                    async_close(Iterator, false, Fail, Throw);
                {ok, Method} -> Call(Method, [E], Done);
                {error, E2} -> Throw(E2)
            end;
        {return, V} ->
            case attempt(fun() -> get_method(Iterator, <<"return">>) end) of
                {ok, undefined} -> buoy_jobs:await(V, Return, Throw);
                {ok, Method} -> Call(Method, [V], Return);
                {error, E2} -> Throw(E2)
            end
    end.

%% The resumption of a yield inside yield*: a return awaits its value first,
%% as AsyncGeneratorUnwrapYieldResumption does.
resumed_async(Iterator, Next, {return, V}, Yield, Done, Throw, Return) ->
    buoy_jobs:await(V, fun(R) -> delegate_async(Iterator, Next, {return, R}, Yield, Done, Throw, Return) end, Throw);
resumed_async(Iterator, Next, Resumption, Yield, Done, Throw, Return) ->
    delegate_async(Iterator, Next, Resumption, Yield, Done, Throw, Return).

%% AsyncIteratorClose for a normal completion: Continue() after the return
%% method's result settles, Throw(E) for an error.
async_close(Iterator, _IsThrow, Continue, Throw) ->
    case attempt(fun() -> get_method(Iterator, <<"return">>) end) of
        {ok, undefined} -> Continue();
        {ok, Method} ->
            case attempt(fun() -> buoy_ref:call(Method, Iterator, []) end) of
                {ok, Result} ->
                    buoy_jobs:await(Result,
                        fun(R) when ?IS_OBJECT(R) -> Continue();
                           (_) -> Throw(type_error_object(<<"Iterator result is not an object">>))
                        end,
                        Throw);
                {error, E} -> Throw(E)
            end;
        {error, E} -> Throw(E)
    end.

%% %AsyncIteratorPrototype%[@@asyncDispose]: a promise of the result of the
%% return method, if any, fulfilled with undefined.
async_dispose(O) ->
    {P, Resolve, Reject} = buoy_jobs:capability(),
    case attempt(fun() -> get_method(O, <<"return">>) end) of
        {ok, undefined} -> Resolve(undefined);
        {ok, Method} ->
            case attempt(fun() -> buoy_jobs:promise_resolve(buoy_ref:call(Method, O, [])) end) of
                {ok, Wrapper} -> buoy_jobs:perform_then(Wrapper, fun(_) -> undefined end, undefined, {P, Resolve, Reject});
                {error, E} -> Reject(E)
            end;
        {error, E} -> Reject(E)
    end,
    P.

%%% Async iteration

%% GetIterator(obj, async): {Iterator, NextMethod}.
-spec async_iterator(term()) -> {term(), term()}.
async_iterator(Iterable) ->
    case get_method_of(Iterable, buoy_heap:well_known(asyncIterator)) of
        undefined -> from_sync(buoy_ref_iterator:get_iterator(Iterable));
        Method ->
            Iterator = buoy_ref:call(Method, Iterable, []),
            ?IS_OBJECT(Iterator) orelse buoy_ref:type_error(<<"Result of the Symbol.asyncIterator method is not an object">>),
            {Iterator, buoy_ref:get(Iterator, <<"next">>)}
    end.

get_method_of(V, K) when V =:= undefined; V =:= null ->
    buoy_ref:type_error(buoy_ref_string:concat(buoy_ref:describe(V), <<" is not async iterable">>)),
    K;
get_method_of(V, K) -> get_method(V, K).

%% CreateAsyncFromSyncIterator.
-spec from_sync({term(), term()}) -> {term(), term()}.
from_sync({SyncIterator, SyncNext}) ->
    O = buoy_heap:new_exotic(async_from_sync, buoy_heap:intrinsic('AsyncFromSyncIterator.prototype'), {SyncIterator, SyncNext}),
    {O, buoy_heap:get(O, <<"next">>)}.

from_sync_method(Name, O, Args) ->
    {P, Resolve, Reject} = buoy_jobs:capability(),
    {Iterator, Next} = buoy_heap:slots(O),
    Value = case Args of
        [] -> [];
        [V | _] -> [V]
    end,
    Outcome = case Name of
        <<"next">> ->
            case attempt(fun() -> object(buoy_ref:call(Next, Iterator, Value)) end) of
                {ok, Result} -> {continue, Result, true};
                Error -> Error
            end;
        <<"return">> ->
            case attempt(fun() -> get_method(Iterator, <<"return">>) end) of
                {ok, undefined} -> {settled, Resolve(buoy_ref_iterator:result(arg(1, Args), true))};
                {ok, Method} ->
                    case attempt(fun() -> object(buoy_ref:call(Method, Iterator, Value)) end) of
                        {ok, Result} -> {continue, Result, false};
                        Error -> Error
                    end;
                Error -> Error
            end;
        <<"throw">> ->
            case attempt(fun() -> get_method(Iterator, <<"throw">>) end) of
                {ok, undefined} ->
                    case attempt(fun() -> buoy_ref_iterator:close(Iterator) end) of
                        {ok, _} -> {error, type_error_object(<<"The iterator does not provide a 'throw' method">>)};
                        Error -> Error
                    end;
                {ok, Method} ->
                    case attempt(fun() -> object(buoy_ref:call(Method, Iterator, Value)) end) of
                        {ok, Result} -> {continue, Result, true};
                        Error -> Error
                    end;
                Error -> Error
            end
    end,
    case Outcome of
        {settled, _} -> ok;
        {error, E} -> Reject(E);
        {continue, R, CloseOnRejection} -> from_sync_continue(R, Iterator, CloseOnRejection, {P, Resolve, Reject})
    end,
    P.

%% AsyncFromSyncIteratorContinuation.
from_sync_continue(Result, Iterator, CloseOnRejection, {_, _, Reject} = Capability) ->
    case attempt(fun() -> {buoy_ref:truthy(buoy_ref:get(Result, <<"done">>)), buoy_ref:get(Result, <<"value">>)} end) of
        {error, E} -> Reject(E);
        {ok, {Done, Value}} ->
            Wrapper = case attempt(fun() -> buoy_jobs:promise_resolve(Value) end) of
                {error, E} when not Done, CloseOnRejection ->
                    _ = attempt(fun() -> buoy_ref_iterator:close(Iterator) end),
                    {error, E};
                Other -> Other
            end,
            case Wrapper of
                {error, E2} -> Reject(E2);
                {ok, Promise} ->
                    OnRejected = case Done orelse not CloseOnRejection of
                        true -> undefined;
                        false -> fun(E3) -> _ = attempt(fun() -> buoy_ref_iterator:close(Iterator) end), erlang:error({'$throw', E3}) end
                    end,
                    buoy_jobs:perform_then(Promise, fun(V) -> buoy_ref_iterator:result(V, Done) end, OnRejected, Capability)
            end
    end,
    ok.
