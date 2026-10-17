%% The Iterator constructor and %Iterator.prototype%: the iterator helpers of
%% ES2025 (map, filter, take, drop, flatMap, reduce, toArray, forEach, some,
%% every, and find), Iterator.from, and the objects that they return.
%%
%% A helper is an exotic object of class iterator_helper whose slots are
%% {State, Underlying, Step}: State is suspended_start, suspended_yield,
%% executing, or completed; Underlying is the iterator record {Iterator, Next}
%% of the iterator it reads; and Step is the state of its closure, a tagged
%% tuple that step/2 advances. A step returns {yield, V, Step1} or done.
-module(bouy_ref_iterator_prototype).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).

-import(bouy_ref_realm, [arg/2, builtin/2, record/4, ctor_record/5]).

-define(HELPER_PROTO, {'$o', 'IteratorHelper.prototype'}).
-define(WRAP_PROTO, {'$o', 'WrapForValidIterator.prototype'}).
-define(INFINITY, infinity).
-define(MAX_SAFE_INTEGER, 9007199254740991).

%%% Intrinsics

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Methods = [{<<"map">>, 1}, {<<"filter">>, 1}, {<<"take">>, 1}, {<<"drop">>, 1}, {<<"flatMap">>, 1},
               {<<"reduce">>, 1}, {<<"toArray">>, 0}, {<<"forEach">>, 1}, {<<"some">>, 1},
               {<<"every">>, 1}, {<<"find">>, 1}],
    Accessor = fun(Name) ->
        {'$accessor', builtin(<<"Iterator.prototype.get ", Name/binary>>, fun(This, _) -> getter(Name, This) end),
         builtin(<<"Iterator.prototype.set ", Name/binary>>, fun(This, Args) -> setter(Name, This, arg(1, Args)) end)}
    end,
    Proto = record(object, ?OBJECT_PROTO,
                   [{?SYM(iterator), builtin(<<"Iterator.prototype.[Symbol.iterator]">>, fun(This, _) -> This end)}]
                   ++ ?METHODS(<<"Iterator.prototype">>, [Name || {Name, _} <- Methods])
                   ++ [{?SYM(toStringTag), Accessor(<<"toStringTag">>)}, {<<"constructor">>, Accessor(<<"constructor">>)}],
                   none),
    [{'Iterator.prototype', Proto},
     {'IteratorHelper.prototype', record(object, ?ITERATOR_PROTO,
         ?METHODS(<<"IteratorHelper.prototype">>, [<<"next">>, <<"return">>]) ++ [{?SYM(toStringTag), <<"Iterator Helper">>}], none)},
     {'WrapForValidIterator.prototype', record(object, ?ITERATOR_PROTO,
         ?METHODS(<<"WrapForValidIterator.prototype">>, [<<"next">>, <<"return">>]), none)},
     {{builtin, <<"Iterator">>}, fixed(ctor_record(<<"Iterator">>, 0, ?ITERATOR_PROTO,
         ?METHODS(<<"Iterator">>, [<<"from">>, <<"concat">>]), fun construct/2))},
     {{builtin, <<"Iterator.prototype.[Symbol.iterator]">>}, function_record(<<"[Symbol.iterator]">>, 0)}]
    ++ [{{builtin, <<"Iterator.prototype.", Name/binary>>}, function_record(Name, Length)} || {Name, Length} <- Methods]
    ++ [{{builtin, <<"Iterator.from">>}, function_record(<<"from">>, 1)},
        {{builtin, <<"Iterator.concat">>}, function_record(<<"concat">>, 0)},
        {{builtin, <<"IteratorHelper.prototype.next">>}, function_record(<<"next">>, 0)},
        {{builtin, <<"IteratorHelper.prototype.return">>}, function_record(<<"return">>, 0)},
        {{builtin, <<"WrapForValidIterator.prototype.next">>}, function_record(<<"next">>, 0)},
        {{builtin, <<"WrapForValidIterator.prototype.return">>}, function_record(<<"return">>, 0)},
        {{builtin, <<"Iterator.prototype.get toStringTag">>}, function_record(<<"get [Symbol.toStringTag]">>, 0)},
        {{builtin, <<"Iterator.prototype.set toStringTag">>}, function_record(<<"set [Symbol.toStringTag]">>, 1)},
        {{builtin, <<"Iterator.prototype.get constructor">>}, function_record(<<"get constructor">>, 0)},
        {{builtin, <<"Iterator.prototype.set constructor">>}, function_record(<<"set constructor">>, 1)}].

%% The length, name, and prototype of a builtin constructor are not writable.
fixed({Class, Proto, Props, Keys, Attrs, Slots}) ->
    {Class, Proto, Props, Keys, Attrs#{<<"length">> => 4, <<"name">> => 4, <<"prototype">> => 0}, Slots}.

function_record(Name, Length) ->
    {function, ?FUNCTION_PROTO, #{<<"name">> => Name, <<"length">> => Length}, [<<"name">>, <<"length">>],
     #{<<"name">> => 4, <<"length">> => 4}, #{}}.

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Iterator">>, constructor()}].

constructor() -> bouy_ref_realm:constructor(?MODULE, <<"Iterator">>).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(_Name, _This, _Args) -> bouy_ref:type_error(<<"Constructor Iterator requires 'new'">>).

%% Iterator is abstract: new Iterator() throws, and a subclass constructs.
construct({'$f', {builtin, <<"Iterator">>}, _}, _Args) ->
    bouy_ref:type_error(<<"Abstract class Iterator not directly constructable">>);
construct(NewTarget, _Args) ->
    bouy_ref:new_this(NewTarget).

%% The accessors of Symbol.toStringTag and constructor, whose setters do not
%% write the prototype itself.
getter(<<"toStringTag">>, _This) -> <<"Iterator">>;
getter(<<"constructor">>, _This) -> constructor().

setter(Name, This, V) ->
    ?IS_OBJECT(This) orelse bouy_ref:type_error(<<"Iterator.prototype setter called on a value that is not an object">>),
    This =/= ?ITERATOR_PROTO orelse bouy_ref:type_error(<<"Cannot assign to read only property of Iterator.prototype">>),
    Key = case Name of
        <<"toStringTag">> -> ?SYM(toStringTag);
        _ -> Name
    end,
    case bouy_heap:get_own(This, Key) of
        none -> bouy_ref_class:define_field(This, Key, V);
        _ -> bouy_ref:set(This, Key, V)
    end,
    undefined.

%%% Methods

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Iterator">>, <<"from">>, _This, Args) -> from(arg(1, Args));
method(<<"Iterator">>, <<"concat">>, _This, Args) -> concat(Args);
method(<<"IteratorHelper.prototype">>, <<"next">>, This, _Args) -> helper_next(This);
method(<<"IteratorHelper.prototype">>, <<"return">>, This, _Args) -> helper_return(This);
method(<<"WrapForValidIterator.prototype">>, Name, This, _Args) -> wrap(Name, This);
method(<<"Iterator.prototype">>, Name, This, Args) ->
    ?IS_OBJECT(This) orelse
        bouy_ref:type_error(<<"Iterator.prototype.", Name/binary, " called on a value that is not an object">>),
    prototype_method(Name, This, Args).

%% Iterator.from: an iterator that inherits from Iterator.prototype as it is,
%% any other iterator wrapped.
from(O) ->
    {Iterator, Next} = flattenable(O, iterate_strings),
    case bouy_ref:instance_of(Iterator, constructor()) of
        true -> Iterator;
        false -> bouy_heap:new_exotic(wrap_for_valid_iterator, ?WRAP_PROTO, {Iterator, Next})
    end.

%% Iterator.concat: a helper over the iterables in order. Each iterable and its
%% iterator method are checked first; each iterator opens when the one before
%% it is done.
concat(Items) ->
    Iterables = [begin
                     ?IS_OBJECT(Item) orelse bouy_ref:type_error(bouy_ref_string:concat(bouy_ref:describe(Item), <<" is not an object">>)),
                     case get_method(Item, bouy_heap:well_known(iterator)) of
                         undefined -> bouy_ref:type_error(<<"The value is not iterable">>);
                         Method -> {Item, Method}
                     end
                 end || Item <- Items],
    bouy_heap:new_exotic(iterator_helper, ?HELPER_PROTO, {suspended_start, none, {concat, Iterables, none}}).

%% GetIteratorFlattenable.
flattenable(O, Primitives) ->
    case ?IS_OBJECT(O) orelse (Primitives =:= iterate_strings andalso ?IS_STRING(O)) of
        true -> ok;
        false -> bouy_ref:type_error(bouy_ref_string:concat(bouy_ref:describe(O), <<" is not an object">>))
    end,
    Iterator = case get_method(O, bouy_heap:well_known(iterator)) of
        undefined -> O;
        Method -> bouy_ref:call(Method, O, [])
    end,
    ?IS_OBJECT(Iterator) orelse bouy_ref:type_error(<<"The iterator is not an object">>),
    {Iterator, bouy_ref:get(Iterator, <<"next">>)}.

get_method(O, K) ->
    case bouy_ref:get(O, K) of
        M when M =:= undefined; M =:= null -> undefined;
        {'$f', _, _} = M -> M;
        M -> bouy_ref:type_error(bouy_ref_string:concat(bouy_ref:describe(M), <<" is not a function">>))
    end.

wrap(Name, This) ->
    {Iterator, Next} = case ?IS_OBJECT(This) andalso bouy_heap:class_of(This) =:= wrap_for_valid_iterator of
        true -> bouy_heap:slots(This);
        false -> bouy_ref:type_error(<<"WrapForValidIteratorPrototype method called on an incompatible receiver">>)
    end,
    case Name of
        <<"next">> -> bouy_ref:call(Next, Iterator, []);
        <<"return">> ->
            case get_method(Iterator, <<"return">>) of
                undefined -> bouy_ref_iterator:result(undefined, true);
                Method -> bouy_ref:call(Method, Iterator, [])
            end
    end.

%% The lazy methods validate their argument, closing the iterator when it is
%% wrong, and return a helper.
prototype_method(<<"map">>, O, Args) -> helper(O, {map, callback(O, arg(1, Args)), 0});
prototype_method(<<"filter">>, O, Args) -> helper(O, {filter, callback(O, arg(1, Args)), 0});
prototype_method(<<"flatMap">>, O, Args) -> helper(O, {flat_map, callback(O, arg(1, Args)), 0, none});
prototype_method(<<"take">>, O, Args) -> helper(O, {take, limit(O, arg(1, Args))});
prototype_method(<<"drop">>, O, Args) -> helper(O, {drop, limit(O, arg(1, Args))});
prototype_method(<<"reduce">>, O, Args) ->
    Reducer = callback(O, arg(1, Args)),
    Record = direct(O),
    case Args of
        [_, Initial | _] -> reduce(Record, Reducer, Initial, 0);
        _ ->
            case step_value(Record) of
                done -> bouy_ref:type_error(<<"Reduce of empty iterator with no initial value">>);
                {value, First} -> reduce(Record, Reducer, First, 1)
            end
    end;
prototype_method(<<"toArray">>, O, _Args) ->
    bouy_heap:new_array(collect(direct(O), []));
prototype_method(<<"forEach">>, O, Args) ->
    Fun = callback(O, arg(1, Args)),
    Record = direct(O),
    each(Record, fun(V, I) -> _ = calling(Record, Fun, [V, I]), continue end, 0),
    undefined;
prototype_method(<<"some">>, O, Args) ->
    Predicate = callback(O, arg(1, Args)),
    Record = direct(O),
    each(Record, fun(V, I) -> stop_when(Record, bouy_ref:truthy(calling(Record, Predicate, [V, I])), true) end, 0, false);
prototype_method(<<"every">>, O, Args) ->
    Predicate = callback(O, arg(1, Args)),
    Record = direct(O),
    each(Record, fun(V, I) -> stop_when(Record, not bouy_ref:truthy(calling(Record, Predicate, [V, I])), false) end, 0, true);
prototype_method(<<"find">>, O, Args) ->
    Predicate = callback(O, arg(1, Args)),
    Record = direct(O),
    each(Record, fun(V, I) -> stop_when(Record, bouy_ref:truthy(calling(Record, Predicate, [V, I])), V) end, 0, undefined).

%% A callback argument: when it is not callable, the iterator closes and the
%% method throws a TypeError.
callback(O, F) ->
    case bouy_heap:is_callable(F) of
        true -> F;
        false ->
            close_quietly(O),
            bouy_ref:type_error(bouy_ref_string:concat(bouy_ref:describe(F), <<" is not a function">>))
    end.

%% The limit of take and drop: a number that is not NaN or negative.
limit(O, V) ->
    Number = try bouy_ref:to_number(V)
             catch error:Reason:Stack -> close_quietly(O), erlang:raise(error, Reason, Stack)
             end,
    Integer = case Number of
        'NaN' -> close_quietly(O), bouy_heap:throw_error('RangeError', <<"The limit must be a number">>);
        'Infinity' -> ?INFINITY;
        '-Infinity' -> -1;
        N when is_float(N) -> trunc(N);
        N -> N
    end,
    case Integer of
        ?INFINITY -> Integer;
        _ when Integer >= 0, Integer =< ?MAX_SAFE_INTEGER -> Integer;
        _ ->
            close_quietly(O),
            bouy_heap:throw_error('RangeError', <<"The limit must be between 0 and 2^53 - 1">>)
    end.

close_quietly(O) ->
    try bouy_ref_iterator:close(O) of
        _ -> ok
    catch
        error:_ -> ok
    end.

%% GetIteratorDirect.
direct(O) -> {O, bouy_ref:get(O, <<"next">>)}.

helper(O, Step) ->
    bouy_heap:new_exotic(iterator_helper, ?HELPER_PROTO, {suspended_start, direct(O), Step}).

%% IteratorStepValue: {value, V} or done. An error leaves the iterator done.
step_value({Iterator, Next}) ->
    Result = bouy_ref:call(Next, Iterator, []),
    ?IS_OBJECT(Result) orelse
        bouy_ref:type_error(bouy_ref_string:concat([<<"Iterator result ">>, bouy_ref:describe(Result), <<" is not an object">>])),
    case bouy_ref:truthy(bouy_ref:get(Result, <<"done">>)) of
        true -> done;
        false -> {value, bouy_ref:get(Result, <<"value">>)}
    end.

%% A call of a callback: when it throws, the iterator closes first.
calling({Iterator, _}, F, Args) ->
    try bouy_ref:call(F, undefined, Args)
    catch error:Reason:Stack -> close_quietly(Iterator), erlang:raise(error, Reason, Stack)
    end.

stop_when({Iterator, _}, true, Result) -> bouy_ref_iterator:close(Iterator), {stop, Result};
stop_when(_Record, false, _Result) -> continue.

each(Record, Fun, Index) -> each(Record, Fun, Index, undefined).

each(Record, Fun, Index, Default) ->
    case step_value(Record) of
        done -> Default;
        {value, V} ->
            case Fun(V, Index) of
                continue -> each(Record, Fun, Index + 1, Default);
                {stop, Result} -> Result
            end
    end.

reduce(Record, Reducer, Accumulator, Index) ->
    case step_value(Record) of
        done -> Accumulator;
        {value, V} -> reduce(Record, Reducer, calling(Record, Reducer, [Accumulator, V, Index]), Index + 1)
    end.

collect(Record, Acc) ->
    case step_value(Record) of
        done -> lists:reverse(Acc);
        {value, V} -> collect(Record, [V | Acc])
    end.

%%% Helpers

helper_slots(H) ->
    case ?IS_OBJECT(H) andalso bouy_heap:class_of(H) =:= iterator_helper of
        true -> bouy_heap:slots(H);
        false -> bouy_ref:type_error(<<"Iterator Helper method called on an object that is not an iterator helper">>)
    end.

%% %IteratorHelperPrototype%.next: GeneratorResume of the closure.
helper_next(H) ->
    case helper_slots(H) of
        {executing, _, _} -> bouy_ref:type_error(<<"Generator is already running">>);
        {completed, _, _} -> bouy_ref_iterator:result(undefined, true);
        {_, Underlying, Step} ->
            bouy_heap:set_slots(H, {executing, Underlying, Step}),
            try step(Underlying, Step) of
                {yield, V, Step1} ->
                    bouy_heap:set_slots(H, {suspended_yield, Underlying, Step1}),
                    bouy_ref_iterator:result(V, false);
                done ->
                    bouy_heap:set_slots(H, {completed, Underlying, Step}),
                    bouy_ref_iterator:result(undefined, true)
            catch
                Class:Reason:Stack ->
                    bouy_heap:set_slots(H, {completed, Underlying, Step}),
                    erlang:raise(Class, Reason, Stack)
            end
    end.

%% %IteratorHelperPrototype%.return: closes the inner iterator of flatMap and
%% then the underlying iterator.
helper_return(H) ->
    case helper_slots(H) of
        {executing, _, _} -> bouy_ref:type_error(<<"Generator is already running">>);
        {completed, _, _} -> bouy_ref_iterator:result(undefined, true);
        {_, none, {concat, _, Current} = Step} ->
            bouy_heap:set_slots(H, {completed, none, Step}),
            case Current of
                {Inner, _} -> bouy_ref_iterator:close(Inner);
                none -> ok
            end,
            bouy_ref_iterator:result(undefined, true);
        {_, {Iterator, _} = Underlying, Step} ->
            bouy_heap:set_slots(H, {completed, Underlying, Step}),
            case Step of
                {flat_map, _, _, {Inner, _}} ->
                    try bouy_ref_iterator:close(Inner)
                    catch error:Reason:Stack -> close_quietly(Iterator), erlang:raise(error, Reason, Stack)
                    end;
                _ -> ok
            end,
            bouy_ref_iterator:close(Iterator),
            bouy_ref_iterator:result(undefined, true)
    end.

%% One step of the closure of a helper.
step(Underlying, {map, Mapper, Counter}) ->
    case step_value(Underlying) of
        done -> done;
        {value, V} -> {yield, calling(Underlying, Mapper, [V, Counter]), {map, Mapper, Counter + 1}}
    end;
step(Underlying, {filter, Predicate, Counter} = Step) ->
    case step_value(Underlying) of
        done -> done;
        {value, V} ->
            case bouy_ref:truthy(calling(Underlying, Predicate, [V, Counter])) of
                true -> {yield, V, {filter, Predicate, Counter + 1}};
                false -> step(Underlying, setelement(3, Step, Counter + 1))
            end
    end;
step({Iterator, _}, {take, 0}) ->
    bouy_ref_iterator:close(Iterator),
    done;
step(Underlying, {take, Remaining}) ->
    case step_value(Underlying) of
        done -> done;
        {value, V} -> {yield, V, {take, decrement(Remaining)}}
    end;
step(Underlying, {drop, 0}) ->
    case step_value(Underlying) of
        done -> done;
        {value, V} -> {yield, V, {drop, 0}}
    end;
step(Underlying, {drop, Remaining}) ->
    case step_value(Underlying) of
        done -> done;
        {value, _} -> step(Underlying, {drop, decrement(Remaining)})
    end;
step(Underlying, {flat_map, Mapper, Counter, none}) ->
    case step_value(Underlying) of
        done -> done;
        {value, V} ->
            Mapped = calling(Underlying, Mapper, [V, Counter]),
            {Iterator, _} = Underlying,
            Inner = try flattenable(Mapped, reject_strings)
                    catch error:Reason:Stack -> close_quietly(Iterator), erlang:raise(error, Reason, Stack)
                    end,
            step(Underlying, {flat_map, Mapper, Counter + 1, Inner})
    end;
step({Iterator, _} = Underlying, {flat_map, Mapper, Counter, Inner} = Step) ->
    Value = try step_value(Inner)
            catch error:Reason:Stack -> close_quietly(Iterator), erlang:raise(error, Reason, Stack)
            end,
    case Value of
        done -> step(Underlying, {flat_map, Mapper, Counter, none});
        {value, V} -> {yield, V, Step}
    end;
step(_None, {concat, [], none}) ->
    done;
step(None, {concat, [{Iterable, Method} | Rest], none}) ->
    Iterator = bouy_ref:call(Method, Iterable, []),
    ?IS_OBJECT(Iterator) orelse bouy_ref:type_error(<<"The iterator is not an object">>),
    step(None, {concat, Rest, direct(Iterator)});
step(None, {concat, Rest, Current} = Step) ->
    case step_value(Current) of
        done -> step(None, {concat, Rest, none});
        {value, V} -> {yield, V, Step}
    end.

decrement(?INFINITY) -> ?INFINITY;
decrement(N) -> N - 1.
