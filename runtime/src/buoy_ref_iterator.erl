%% The Iterator family: the iteration protocol that for...of, spread, and
%% array patterns use, IteratorClose, the iterators over a snapshot list
%% (arrays, Maps, Sets, and strings), and %IteratorPrototype%. Generators are
%% in buoy_ref_generator.
-module(buoy_ref_iterator).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4]).
-export([iterate/1, step/1, to_list/1, list_from_method/2, take/2, rest_list/1, for_in/1]).
-export([get_iterator/1, close/1, close_state/1, close_quietly/1]).
-export([async_next/1, async_step/1, async_close/3, async_close_quietly/2]).
-export([require_coercible/1, finish/1, pattern_cell/1, next_value/1, rest_value/1, abort/1, finish_cell/1]).
-export([object_rest/2]).
-export([list_iterator/2, list_iterator_next/1, result/2]).

-import(buoy_ref_realm, [record/4]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'ListIterator.prototype', record(object, ?ITERATOR_PROTO, ?METHODS(<<"ListIterator.prototype">>, [<<"next">>]), none)}].

-spec globals() -> [{binary(), term()}].
globals() -> [].

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"ListIterator.prototype">>, <<"next">>, This, _) ->
    case list_iterator_next(This) of
        {value, V} -> result(V, false);
        done -> result(undefined, true)
    end.

-spec result(term(), boolean()) -> term().
result(V, Done) -> buoy_heap:object(?OBJECT_PROTO, [{<<"value">>, V}, {<<"done">>, Done}]).

list_iterator(Kind, Items) ->
    buoy_heap:new_exotic(list_iterator, {'$o', 'ListIterator.prototype'}, {Kind, Items}).

-spec list_iterator_next(term()) -> {value, term()} | done.
list_iterator_next(O) ->
    case buoy_heap:slots(O) of
        {Kind, [V | Rest]} -> buoy_heap:set_slots(O, {Kind, Rest}), {value, V};
        {_, []} -> done
    end.

%% The state of a for...of, a spread, or an array pattern. Arrays read their
%% live length at each step, as the array iterator does.
-spec iterate(term()) -> term().
iterate({'$o', _} = O) ->
    case buoy_heap:class_of(O) of
        array ->
            case buoy_heap:get(O, buoy_heap:well_known(iterator)) of
                {'$f', {builtin, <<"Array.prototype.values">>}, _} -> {array, O, 0};
                _ -> protocol(O)
            end;
        generator ->
            case buoy_heap:get(O, <<"next">>) of
                {'$f', {builtin, <<"Generator.prototype.next">>}, _} -> {generator, O};
                _ -> protocol(O)
            end;
        list_iterator -> {list_iterator, O};
        Class when Class =:= array_iterator; Class =:= map_iterator; Class =:= set_iterator; Class =:= string_iterator ->
            native(Class, O);
        _ -> protocol(O)
    end;
iterate(S) when ?IS_STRING(S) -> {list, [buoy_ref_string:from_code_points([C]) || C <- buoy_ref_string:code_points(S)]};
iterate({'$f', _, _} = F) -> protocol(F);
iterate(V) -> buoy_ref:type_error(buoy_ref_string:concat(buoy_ref:describe(V), <<" is not iterable">>)).

%% A builtin iterator whose next method is the intrinsic one steps without
%% the result objects of the protocol: {native, Module, Iterator}.
native(_Class, O) ->
    case native_state(O, buoy_heap:get(O, <<"next">>)) of
        none -> protocol(O);
        State -> State
    end.

native_state(Iterator, Next) ->
    case native_module(native_class(Iterator), Next) of
        none -> none;
        Module -> {native, Module, Iterator}
    end.

native_module(array_iterator, {'$f', {builtin, <<"ArrayIterator.prototype.next">>}, _}) -> buoy_ref_array;
native_module(map_iterator, {'$f', {builtin, <<"MapIterator.prototype.next">>}, _}) -> buoy_ref_collection;
native_module(set_iterator, {'$f', {builtin, <<"SetIterator.prototype.next">>}, _}) -> buoy_ref_collection;
native_module(string_iterator, {'$f', {builtin, <<"StringIterator.prototype.next">>}, _}) -> buoy_ref_string;
native_module(_Class, _Next) -> none.

%% IteratorToList(GetIteratorFromMethod(Source, Method)). A builtin iterator
%% with its intrinsic next steps without result objects. The list is taken
%% whole, so no IteratorClose happens and `return` is not read.
-spec list_from_method(term(), term()) -> list().
list_from_method(Source, Method) ->
    Iterator = buoy_ref:call(Method, Source, []),
    ?IS_OBJECT(Iterator) orelse buoy_ref:type_error(<<"Result of the Symbol.iterator method is not an object">>),
    Next = buoy_ref:get(Iterator, <<"next">>),
    State = case native_module(buoy_heap:class_of(Iterator), Next) of
        none -> {protocol, Iterator, Next};
        Module -> {native, Module, Iterator}
    end,
    drain(State, []).

%% The class of a builtin iterator that has no return method, which
%% IteratorClose would call: only such an iterator steps natively. A user
%% object is not read, so no getter of its runs here.
native_class({'$o', _} = Iterator) ->
    Class = buoy_heap:class_of(Iterator),
    Builtin = lists:member(Class, [array_iterator, map_iterator, set_iterator, string_iterator]),
    case Builtin andalso buoy_heap:get(Iterator, <<"return">>) =:= undefined of
        true -> Class;
        false -> protocol
    end;
native_class(_) ->
    protocol.

protocol(O) ->
    {Iterator, Next} = get_iterator(O),
    case native_state(Iterator, Next) of
        none -> {protocol, Iterator, Next};
        State -> State
    end.

%% GetIterator(obj, sync): the iterator and its next method.
-spec get_iterator(term()) -> {term(), term()}.
get_iterator(O) ->
    Method = case O of
        undefined -> not_iterable(O);
        null -> not_iterable(O);
        _ -> buoy_ref:get(O, buoy_heap:well_known(iterator))
    end,
    case Method of
        {'$f', _, _} ->
            Iterator = buoy_ref:call(Method, O, []),
            ?IS_OBJECT(Iterator) orelse buoy_ref:type_error(<<"Result of the Symbol.iterator method is not an object">>),
            {Iterator, buoy_ref:get(Iterator, <<"next">>)};
        _ ->
            not_iterable(O)
    end.

-spec not_iterable(term()) -> no_return().
not_iterable(O) ->
    buoy_ref:type_error(buoy_ref_string:concat(buoy_ref:describe(O), <<" is not iterable">>)).

%% IteratorClose(iterator, normal completion): calls the return method and
%% checks its result.
-spec close(term()) -> ok.
close(Iterator) ->
    case buoy_ref:get(Iterator, <<"return">>) of
        M when M =:= undefined; M =:= null -> ok;
        Method ->
            Result = buoy_ref:call(Method, Iterator, []),
            ?IS_OBJECT(Result) orelse buoy_ref:type_error(<<"Iterator result is not an object">>),
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
    case I < buoy_heap:array_length(O) of
        true -> {value, buoy_heap:get(O, I), {array, O, I + 1}};
        false -> done
    end;
step({list, [V | Rest]}) -> {value, V, {list, Rest}};
step({list, []}) -> done;
step({for_in, [{O, K} | Rest]}) ->
    case still_enumerable(O, K) of
        true -> {value, buoy_heap:key_to_value(K), {for_in, Rest}};
        false -> step({for_in, Rest})
    end;
step({for_in, []}) -> done;
step({generator, G} = State) ->
    case buoy_ref_generator:resume(G, {next, undefined}) of
        {yield, V} -> {value, V, State};
        {yield_raw, Result} ->
            case buoy_ref:truthy(buoy_ref:get(Result, <<"done">>)) of
                true -> done;
                false -> {value, buoy_ref:get(Result, <<"value">>), State}
            end;
        {done, _} -> done
    end;
step({native, Module, O} = State) ->
    case Module:step(O) of
        {value, V} -> {value, V, State};
        done -> done
    end;
step({list_iterator, O} = State) ->
    case list_iterator_next(O) of
        {value, V} -> {value, V, State};
        done -> done
    end;
step({protocol, Iterator, Next} = State) ->
    Result = buoy_ref:call(Next, Iterator, []),
    ?IS_OBJECT(Result) orelse buoy_ref:type_error(buoy_ref_string:concat([<<"Iterator result ">>, buoy_ref:describe(Result), <<" is not an object">>])),
    case buoy_ref:truthy(buoy_ref:get(Result, <<"done">>)) of
        true -> done;
        false -> {value, buoy_ref:get(Result, <<"value">>), State}
    end.

%% for await: the result of the next method, which the loop awaits. The state
%% is {Iterator, NextMethod} from buoy_ref_generator:async_iterator/1.
-spec async_next({term(), term()}) -> term().
async_next({Iterator, Next}) -> buoy_ref:call(Next, Iterator, []).

-spec async_step(term()) -> {value, term()} | done.
async_step(Result) ->
    ?IS_OBJECT(Result) orelse
        buoy_ref:type_error(buoy_ref_string:concat([<<"Iterator result ">>, buoy_ref:describe(Result), <<" is not an object">>])),
    case buoy_ref:truthy(buoy_ref:get(Result, <<"done">>)) of
        true -> done;
        false -> {value, buoy_ref:get(Result, <<"value">>)}
    end.

%% AsyncIteratorClose for a break or a return: Continue() once the result of
%% the return method settles, or Throw(E).
-spec async_close({term(), term()}, fun(() -> term()), fun((term()) -> term())) -> term().
async_close({Iterator, _}, Continue, Throw) ->
    buoy_ref_generator:async_close(Iterator, false, Continue, Throw).

%% AsyncIteratorClose for a throw: the errors of the return method do not
%% matter, and Continue() rethrows.
-spec async_close_quietly({term(), term()}, fun(() -> term())) -> term().
async_close_quietly({Iterator, _}, Continue) ->
    Result = try
                 case buoy_ref:get(Iterator, <<"return">>) of
                     M when M =:= undefined; M =:= null -> none;
                     Method -> {ok, buoy_ref:call(Method, Iterator, [])}
                 end
             catch
                 error:_ -> none
             end,
    case Result of
        none -> Continue();
        {ok, V} -> buoy_jobs:await(V, fun(_) -> Continue() end, fun(_) -> Continue() end)
    end.

-spec to_list(term()) -> list().
to_list({'$o', _} = O) ->
    case iterate(O) of
        {array, O, 0} -> buoy_heap:array_items(O);
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
    buoy_ref:type_error(buoy_ref_string:concat([<<"Cannot destructure '">>, buoy_ref:to_string(V), <<"' as it is ">>, buoy_ref:to_string(V), <<".">>]));
require_coercible(_) -> ok.

%% The rest of an object pattern: the enumerable own properties of the
%% source that the pattern did not name, the indexes of a string too.
-spec object_rest(term(), [buoy_heap:key()]) -> term().
object_rest(S, Excluded) when ?IS_STRING(S) ->
    Rest = buoy_heap:new_object(?OBJECT_PROTO),
    [buoy_ref_class:define_field(Rest, I, buoy_ref_string:unit_string(S, I))
     || I <- lists:seq(0, buoy_ref_string:length_of(S) - 1), not lists:member(I, Excluded)],
    Rest;
object_rest(Source, Excluded) ->
    buoy_ref:object_rest(Source, Excluded).

%% The end of an array pattern whose iterator may not be done: IteratorClose.
-spec finish(term()) -> ok.
finish(done) -> ok;
finish(State) -> close_state(State).

%% The iteration of an array pattern whose elements can throw: a cell that
%% holds the state, so that the handler of the pattern knows whether the
%% iterator is done.
-spec pattern_cell(term()) -> {'$c', pos_integer()}.
pattern_cell(Source) -> buoy_heap:cell(iterate(Source)).

%% The next value of the pattern, undefined past the end. A step that throws
%% leaves the iterator done.
-spec next_value({'$c', pos_integer()}) -> term().
next_value(Cell) ->
    case buoy_heap:cell_get(Cell) of
        done -> undefined;
        State ->
            buoy_heap:cell_set(Cell, done),
            case step(State) of
                {value, V, State1} -> buoy_heap:cell_set(Cell, State1), V;
                done -> undefined
            end
    end.

%% The rest element: an array of the values left.
-spec rest_value({'$c', pos_integer()}) -> term().
rest_value(Cell) ->
    State = buoy_heap:cell_get(Cell),
    buoy_heap:cell_set(Cell, done),
    rest_list(State).

%% A throw in the pattern: IteratorClose unless the iterator is done.
-spec abort({'$c', pos_integer()}) -> ok.
abort(Cell) ->
    case buoy_heap:cell_get(Cell) of
        done -> ok;
        State -> close_quietly(State)
    end.

-spec finish_cell({'$c', pos_integer()}) -> ok.
finish_cell(Cell) -> finish(buoy_heap:cell_get(Cell)).

-spec rest_list(term()) -> term().
rest_list(done) -> buoy_heap:new_array([]);
rest_list(State) -> buoy_heap:new_array(drain(State, [])).

%% The iteration state of for...in: the enumerable string keys of the object
%% and its prototypes, each once, own keys first, each with its object, so
%% that step/1 skips a key that is gone or no longer enumerable when the loop
%% reaches it (EnumerateObjectProperties).
-spec for_in(term()) -> term().
for_in(V) when ?IS_OBJECT(V) -> {for_in, chain_keys(V, [], [])};
for_in(S) when ?IS_STRING(S) -> {list, [integer_to_binary(I) || I <- lists:seq(0, buoy_ref_string:length_of(S) - 1)]};
for_in(_) -> {list, []}.

chain_keys(null, _Seen, Acc) ->
    lists:reverse(Acc);
chain_keys(O, Seen, Acc) ->
    Own = [K || K <- buoy_heap:own_keys(O), is_integer(K) orelse ?IS_STRING(K)],
    Enumerable = buoy_heap:enumerable_keys(O),
    New = [{O, K} || K <- Enumerable, not lists:member(K, Seen)],
    chain_keys(buoy_heap:prototype_of(O), Own ++ Seen, lists:reverse(New) ++ Acc).

%% A proxy or a namespace answered for its keys already: a second
%% [[GetOwnProperty]] would run a trap or read a binding again.
still_enumerable(O, K) ->
    case buoy_heap:class_of(O) of
        Class when Class =:= proxy; Class =:= namespace; Class =:= deferred_namespace -> true;
        _ -> buoy_heap:is_enumerable(buoy_heap:get_own(O, K))
    end.
