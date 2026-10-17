%% The Iterator family: the iteration protocol that for...of, spread, and
%% array patterns use, IteratorClose, the iterators over a snapshot list
%% (arrays, Maps, Sets, and strings), and %IteratorPrototype%. Generators are
%% in bouy_ref_generator.
-module(bouy_ref_iterator).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4]).
-export([iterate/1, step/1, to_list/1, take/2, rest_list/1, for_in_keys/1]).
-export([get_iterator/1, close/1, close_state/1, close_quietly/1]).
-export([async_next/1, async_step/1, async_close/3, async_close_quietly/2]).
-export([require_coercible/1, finish/1, pattern_cell/1, next_value/1, rest_value/1, abort/1, finish_cell/1]).
-export([list_iterator/2, list_iterator_next/1, result/2]).

-import(bouy_ref_realm, [arg/2, builtin/2, record/4]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Iterator.prototype', record(object, ?OBJECT_PROTO, [{?SYM(iterator), builtin(<<"[Symbol.iterator]">>, fun(This, _) -> This end)}], none)},
     {'ListIterator.prototype', record(object, ?ITERATOR_PROTO, ?METHODS(<<"ListIterator.prototype">>, [<<"next">>]), none)}].

-spec globals() -> [{binary(), term()}].
globals() -> [].

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"ListIterator.prototype">>, <<"next">>, This, _) ->
    case list_iterator_next(This) of
        {value, V} -> result(V, false);
        done -> result(undefined, true)
    end.

-spec result(term(), boolean()) -> term().
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
            case bouy_heap:get(O, bouy_heap:well_known(iterator)) of
                {'$f', {builtin, <<"Array.prototype.values">>}, _} -> {array, O, 0};
                _ -> protocol(O)
            end;
        generator ->
            case bouy_heap:get(O, <<"next">>) of
                {'$f', {builtin, <<"Generator.prototype.next">>}, _} -> {generator, O};
                _ -> protocol(O)
            end;
        list_iterator -> {list_iterator, O};
        _ -> protocol(O)
    end;
iterate(S) when ?IS_STRING(S) -> {list, [bouy_ref_string:from_code_points([C]) || C <- bouy_ref_string:code_points(S)]};
iterate({'$f', _, _} = F) -> protocol(F);
iterate(V) -> bouy_ref:type_error(bouy_ref_string:concat(bouy_ref:describe(V), <<" is not iterable">>)).

protocol(O) ->
    {Iterator, Next} = get_iterator(O),
    {protocol, Iterator, Next}.

%% GetIterator(obj, sync): the iterator and its next method.
-spec get_iterator(term()) -> {term(), term()}.
get_iterator(O) ->
    Method = case O of
        undefined -> not_iterable(O);
        null -> not_iterable(O);
        _ -> bouy_ref:get(O, bouy_heap:well_known(iterator))
    end,
    case Method of
        {'$f', _, _} ->
            Iterator = bouy_ref:call(Method, O, []),
            ?IS_OBJECT(Iterator) orelse bouy_ref:type_error(<<"Result of the Symbol.iterator method is not an object">>),
            {Iterator, bouy_ref:get(Iterator, <<"next">>)};
        _ ->
            not_iterable(O)
    end.

-spec not_iterable(term()) -> no_return().
not_iterable(O) ->
    bouy_ref:type_error(bouy_ref_string:concat(bouy_ref:describe(O), <<" is not iterable">>)).

%% IteratorClose(iterator, normal completion): calls the return method and
%% checks its result.
-spec close(term()) -> ok.
close(Iterator) ->
    case bouy_ref:get(Iterator, <<"return">>) of
        M when M =:= undefined; M =:= null -> ok;
        Method ->
            Result = bouy_ref:call(Method, Iterator, []),
            ?IS_OBJECT(Result) orelse bouy_ref:type_error(<<"Iterator result is not an object">>),
            ok
    end.

%% IteratorClose of the iterator of an iteration state, when a loop or a
%% pattern stops before the iterator is done.
-spec close_state(term()) -> ok.
close_state({protocol, Iterator, _}) -> close(Iterator);
close_state({generator, G}) -> close(G);
close_state(_) -> ok.

%% IteratorClose for a throw completion: the error of the loop wins, so the
%% errors of the return method are ignored.
-spec close_quietly(term()) -> ok.
close_quietly(State) ->
    try close_state(State) of
        _ -> ok
    catch
        error:_ -> ok
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
    case bouy_ref_generator:resume(G, {next, undefined}) of
        {yield, V} -> {value, V, State};
        {yield_raw, Result} ->
            case bouy_ref:truthy(bouy_ref:get(Result, <<"done">>)) of
                true -> done;
                false -> {value, bouy_ref:get(Result, <<"value">>), State}
            end;
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

%% for await: the result of the next method, which the loop awaits. The state
%% is {Iterator, NextMethod} from bouy_ref_generator:async_iterator/1.
-spec async_next({term(), term()}) -> term().
async_next({Iterator, Next}) -> bouy_ref:call(Next, Iterator, []).

-spec async_step(term()) -> {value, term()} | done.
async_step(Result) ->
    ?IS_OBJECT(Result) orelse
        bouy_ref:type_error(bouy_ref_string:concat([<<"Iterator result ">>, bouy_ref:describe(Result), <<" is not an object">>])),
    case bouy_ref:truthy(bouy_ref:get(Result, <<"done">>)) of
        true -> done;
        false -> {value, bouy_ref:get(Result, <<"value">>)}
    end.

%% AsyncIteratorClose for a break or a return: Continue() once the result of
%% the return method settles, or Throw(E).
-spec async_close({term(), term()}, fun(() -> term()), fun((term()) -> term())) -> term().
async_close({Iterator, _}, Continue, Throw) ->
    bouy_ref_generator:async_close(Iterator, false, Continue, Throw).

%% AsyncIteratorClose for a throw: the errors of the return method do not
%% matter, and Continue() rethrows.
-spec async_close_quietly({term(), term()}, fun(() -> term())) -> term().
async_close_quietly({Iterator, _}, Continue) ->
    Result = try
                 case bouy_ref:get(Iterator, <<"return">>) of
                     M when M =:= undefined; M =:= null -> none;
                     Method -> {ok, bouy_ref:call(Method, Iterator, [])}
                 end
             catch
                 error:_ -> none
             end,
    case Result of
        none -> Continue();
        {ok, V} -> bouy_jobs:await(V, fun(_) -> Continue() end, fun(_) -> Continue() end)
    end.

-spec to_list(term()) -> list().
to_list({'$o', _} = O) ->
    case iterate(O) of
        {array, O, 0} -> bouy_heap:array_items(O);
        State -> drain(State, [])
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

%%% Destructuring

%% An object pattern: a TypeError for undefined and null.
-spec require_coercible(term()) -> ok.
require_coercible(V) when V =:= undefined; V =:= null ->
    bouy_ref:type_error(bouy_ref_string:concat([<<"Cannot destructure '">>, bouy_ref:to_string(V), <<"' as it is ">>, bouy_ref:to_string(V), <<".">>]));
require_coercible(_) -> ok.

%% The end of an array pattern whose iterator may not be done: IteratorClose.
-spec finish(term()) -> ok.
finish(done) -> ok;
finish(State) -> close_state(State).

%% The iteration of an array pattern whose elements can throw: a cell that
%% holds the state, so that the handler of the pattern knows whether the
%% iterator is done.
-spec pattern_cell(term()) -> {'$c', pos_integer()}.
pattern_cell(Source) -> bouy_heap:cell(iterate(Source)).

%% The next value of the pattern, undefined past the end. A step that throws
%% leaves the iterator done.
-spec next_value({'$c', pos_integer()}) -> term().
next_value(Cell) ->
    case bouy_heap:cell_get(Cell) of
        done -> undefined;
        State ->
            bouy_heap:cell_set(Cell, done),
            case step(State) of
                {value, V, State1} -> bouy_heap:cell_set(Cell, State1), V;
                done -> undefined
            end
    end.

%% The rest element: an array of the values left.
-spec rest_value({'$c', pos_integer()}) -> term().
rest_value(Cell) ->
    State = bouy_heap:cell_get(Cell),
    bouy_heap:cell_set(Cell, done),
    rest_list(State).

%% A throw in the pattern: IteratorClose unless the iterator is done.
-spec abort({'$c', pos_integer()}) -> ok.
abort(Cell) ->
    case bouy_heap:cell_get(Cell) of
        done -> ok;
        State -> close_quietly(State)
    end.

-spec finish_cell({'$c', pos_integer()}) -> ok.
finish_cell(Cell) -> finish(bouy_heap:cell_get(Cell)).

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
