%% The Iterator family: the iteration protocol that for...of, spread, and
%% array patterns use, the iterators over a snapshot list (arrays, Maps,
%% Sets, and strings), generators, and their prototypes.
-module(bouy_ref_iterator).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4]).
-export([iterate/1, step/1, to_list/1, take/2, rest_list/1, close/1, for_in_keys/1]).
-export([make_generator/1, generator_resume/2, list_iterator/2, list_iterator_next/1, result/2]).

-import(bouy_ref_realm, [arg/2, builtin/2, record/4]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Iterator.prototype', record(object, ?OBJECT_PROTO, [{?SYM(iterator), builtin(<<"[Symbol.iterator]">>, fun(This, _) -> This end)}], none)},
     {'ListIterator.prototype', record(object, ?ITERATOR_PROTO, ?METHODS(<<"ListIterator.prototype">>, [<<"next">>]), none)},
     {'Generator.prototype', record(object, ?ITERATOR_PROTO, ?METHODS(<<"Generator.prototype">>, [<<"next">>, <<"return">>, <<"throw">>]) ++ [{?SYM(toStringTag), <<"Generator">>}], none)}].

-spec globals() -> [{binary(), term()}].
globals() -> [].

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"ListIterator.prototype">>, <<"next">>, This, _) ->
    case list_iterator_next(This) of
        {value, V} -> result(V, false);
        done -> result(undefined, true)
    end;
method(<<"Generator.prototype">>, Name, This, Args) ->
    Resumption = case Name of
        <<"next">> -> {next, arg(1, Args)};
        <<"return">> -> {return, arg(1, Args)};
        <<"throw">> -> {throw, arg(1, Args)}
    end,
    case generator_resume(This, Resumption) of
        {yield, V} -> result(V, false);
        {done, V} -> result(V, true)
    end.

result(V, Done) -> bouy_heap:object(?OBJECT_PROTO, [{<<"value">>, V}, {<<"done">>, Done}]).

list_iterator(Kind, Items) ->
    bouy_heap:new_exotic(list_iterator, {'$o', 'ListIterator.prototype'}, {Kind, Items}).

-spec list_iterator_next(term()) -> {value, term()} | done.
list_iterator_next(O) ->
    case bouy_heap:slots(O) of
        {Kind, [V | Rest]} -> bouy_heap:set_slots(O, {Kind, Rest}), {value, V};
        {_, []} -> done
    end.

%% The state of a for...of, a spread, or an array pattern. Arrays read their
%% live length at each step, as the array iterator does.
-spec iterate(term()) -> term().
iterate({'$o', _} = O) ->
    case bouy_heap:class_of(O) of
        array ->
            case plain_array(O) of
                true -> {array, O, 0};
                false -> protocol(O)
            end;
        generator -> {generator, O};
        list_iterator -> {list_iterator, O};
        _ -> protocol(O)
    end;
iterate(S) when ?IS_STRING(S) -> {list, [bouy_ref_string:from_code_points([C]) || C <- bouy_ref_string:code_points(S)]};
iterate({'$f', _, _} = F) -> protocol(F);
iterate(V) -> bouy_ref:type_error(bouy_ref_string:concat(bouy_ref:describe(V), <<" is not iterable">>)).

%% Whether an array iterates with the builtin array iterator, so the loop can
%% read its elements directly: its Symbol.iterator is Array.prototype's.
plain_array(O) ->
    case bouy_heap:get(O, bouy_heap:well_known(iterator)) of
        {'$f', {builtin, <<"Array.prototype.values">>}, _} -> true;
        _ -> false
    end.

%% IteratorClose after a destructuring that did not exhaust the iterator: the
%% return method runs, and its result must be an object.
-spec close(term()) -> ok.
close({protocol, Iterator, _}) ->
    case bouy_ref:get(Iterator, <<"return">>) of
        Return when Return =:= undefined; Return =:= null ->
            ok;
        Return ->
            Result = bouy_ref:call(Return, Iterator, []),
            ?IS_OBJECT(Result) orelse bouy_ref:type_error(<<"Iterator result is not an object">>),
            ok
    end;
close({generator, G}) ->
    _ = generator_resume(G, {return, undefined}),
    ok;
close(_State) ->
    ok.

protocol(O) ->
    case bouy_ref:get(O, bouy_heap:well_known(iterator)) of
        {'$f', _, _} = Method ->
            Iterator = bouy_ref:call(Method, O, []),
            ?IS_OBJECT(Iterator) orelse bouy_ref:type_error(<<"Result of the Symbol.iterator method is not an object">>),
            {protocol, Iterator, bouy_ref:get(Iterator, <<"next">>)};
        _ ->
            bouy_ref:type_error(bouy_ref_string:concat(bouy_ref:describe(O), <<" is not iterable">>))
    end.

%% The next value: {value, V, State1}, or done.
-spec step(term()) -> {value, term(), term()} | done.
step({array, O, I}) ->
    case I < bouy_heap:array_length(O) of
        true -> {value, bouy_heap:get(O, I), {array, O, I + 1}};
        false -> done
    end;
step({list, [V | Rest]}) -> {value, V, {list, Rest}};
step({list, []}) -> done;
step({generator, G} = State) ->
    case generator_resume(G, {next, undefined}) of
        {yield, V} -> {value, V, State};
        {done, _} -> done
    end;
step({list_iterator, O} = State) ->
    case list_iterator_next(O) of
        {value, V} -> {value, V, State};
        done -> done
    end;
step({protocol, Iterator, Next} = State) ->
    Result = bouy_ref:call(Next, Iterator, []),
    ?IS_OBJECT(Result) orelse bouy_ref:type_error(bouy_ref_string:concat([<<"Iterator result ">>, bouy_ref:describe(Result), <<" is not an object">>])),
    case bouy_ref:truthy(bouy_ref:get(Result, <<"done">>)) of
        true -> done;
        false -> {value, bouy_ref:get(Result, <<"value">>), State}
    end.

-spec to_list(term()) -> list().
to_list({'$o', _} = O) ->
    case bouy_heap:class_of(O) of
        array ->
            case plain_array(O) of
                true -> bouy_heap:array_items(O);
                false -> drain(protocol(O), [])
            end;
        _ ->
            drain(iterate(O), [])
    end;
to_list(V) ->
    drain(iterate(V), []).

drain(State, Acc) ->
    case step(State) of
        {value, V, State1} -> drain(State1, [V | Acc]);
        done -> lists:reverse(Acc)
    end.

%% The first N values of an array pattern, undefined past the end, and the
%% state for a rest element.
-spec take(term(), non_neg_integer()) -> {list(), term()}.
take(V, N) -> take(iterate(V), N, []).

take(State, 0, Acc) -> {lists:reverse(Acc), State};
take(done, N, Acc) -> take(done, N - 1, [undefined | Acc]);
take(State, N, Acc) ->
    case step(State) of
        {value, V, State1} -> take(State1, N - 1, [V | Acc]);
        done -> take(done, N - 1, [undefined | Acc])
    end.

-spec rest_list(term()) -> term().
rest_list(done) -> bouy_heap:new_array([]);
rest_list(State) -> bouy_heap:new_array(drain(State, [])).

%% for...in: the enumerable string keys of the object and its prototypes,
%% each once, own keys first.
-spec for_in_keys(term()) -> [binary()].
for_in_keys(V) when ?IS_OBJECT(V) -> [bouy_heap:key_to_value(K) || K <- chain_keys(V, [], [])];
for_in_keys(S) when ?IS_STRING(S) -> [integer_to_binary(I) || I <- lists:seq(0, bouy_ref_string:length_of(S) - 1)];
for_in_keys(_) -> [].

chain_keys(null, _Seen, Acc) ->
    lists:reverse(Acc);
chain_keys(O, Seen, Acc) ->
    Own = [K || K <- bouy_heap:own_keys(O), is_integer(K) orelse ?IS_STRING(K)],
    Enumerable = bouy_heap:enumerable_keys(O),
    New = [K || K <- Enumerable, not lists:member(K, Seen)],
    chain_keys(bouy_heap:prototype_of(O), Own ++ Seen, lists:reverse(New) ++ Acc).

-spec make_generator(fun(() -> term())) -> term().
make_generator(Start) ->
    bouy_heap:new_exotic(generator, {'$o', 'Generator.prototype'}, {suspended_start, Start}).

-spec generator_resume(term(), {next | throw | return, term()}) -> {yield, term()} | {done, term()}.
generator_resume(G, Resumption) ->
    case bouy_heap:slots(G) of
        {suspended_start, Start} ->
            case Resumption of
                {next, _} -> run_generator(G, Start);
                {return, V} -> bouy_heap:set_slots(G, completed), {done, V};
                {throw, E} -> bouy_heap:set_slots(G, completed), erlang:error({'$throw', E})
            end;
        {suspended_yield, Continuation} ->
            run_generator(G, fun() -> Continuation(Resumption) end);
        executing ->
            bouy_ref:type_error(<<"Generator is already running">>);
        completed ->
            case Resumption of
                {next, _} -> {done, undefined};
                {return, V} -> {done, V};
                {throw, E} -> erlang:error({'$throw', E})
            end
    end.

run_generator(G, Body) ->
    bouy_heap:set_slots(G, executing),
    try Body() of
        {yield, V, Continuation} ->
            bouy_heap:set_slots(G, {suspended_yield, Continuation}),
            {yield, V};
        {done, V} ->
            bouy_heap:set_slots(G, completed),
            {done, V}
    catch
        Class:Reason:Stack ->
            bouy_heap:set_slots(G, completed),
            erlang:raise(Class, Reason, Stack)
    end.
