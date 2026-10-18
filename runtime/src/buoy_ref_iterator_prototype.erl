%% The Iterator constructor and %Iterator.prototype%: the iterator helpers of
%% ES2025 (map, filter, take, drop, flatMap, reduce, toArray, forEach, some,
%% every, and find), chunks, windows, includes, Iterator.from, Iterator.concat,
%% Iterator.zip, Iterator.zipKeyed, and the objects that they return.
%%
%% A helper is an exotic object of class iterator_helper whose slots are
%% {State, Underlying, Step}: State is suspended_start, suspended_yield,
%% executing, or completed; Underlying is the iterator record {Iterator, Next}
%% of the iterator it reads; and Step is the state of its closure, a tagged
%% tuple that step/2 advances. A step returns {yield, V, Step1} or done.
-module(buoy_ref_iterator_prototype).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).

-import(buoy_ref_realm, [arg/2, builtin/2, record/4, ctor_record/5]).

-define(HELPER_PROTO, {'$o', 'IteratorHelper.prototype'}).
-define(WRAP_PROTO, {'$o', 'WrapForValidIterator.prototype'}).
-define(INFINITY, infinity).
-define(MAX_SAFE_INTEGER, 9007199254740991).

%%% Intrinsics

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Methods = [{<<"map">>, 1}, {<<"filter">>, 1}, {<<"take">>, 1}, {<<"drop">>, 1}, {<<"flatMap">>, 1},
               {<<"reduce">>, 1}, {<<"toArray">>, 0}, {<<"forEach">>, 1}, {<<"some">>, 1},
               {<<"every">>, 1}, {<<"find">>, 1}, {<<"chunks">>, 1}, {<<"windows">>, 1}, {<<"includes">>, 1}, {<<"join">>, 1}],
    Accessor = fun(Name) ->
        {'$accessor', builtin(<<"Iterator.prototype.get ", Name/binary>>, fun(This, _) -> getter(Name, This) end),
         builtin(<<"Iterator.prototype.set ", Name/binary>>, fun(This, Args) -> setter(Name, This, arg(1, Args)) end)}
    end,
    Proto = record(object, ?OBJECT_PROTO,
                   [{?SYM(iterator), builtin(<<"Iterator.prototype.[Symbol.iterator]">>, fun(This, _) -> This end)},
                    {?SYM(dispose), builtin(<<"Iterator.prototype.[Symbol.dispose]">>, fun(This, _) -> dispose(This) end)}]
                   ++ ?METHODS(<<"Iterator.prototype">>, [Name || {Name, _} <- Methods])
                   ++ [{?SYM(toStringTag), Accessor(<<"toStringTag">>)}, {<<"constructor">>, Accessor(<<"constructor">>)}],
                   none),
    [{'Iterator.prototype', Proto},
     {'IteratorHelper.prototype', record(object, ?ITERATOR_PROTO,
         ?METHODS(<<"IteratorHelper.prototype">>, [<<"next">>, <<"return">>]) ++ [{?SYM(toStringTag), <<"Iterator Helper">>}], none)},
     {'WrapForValidIterator.prototype', record(object, ?ITERATOR_PROTO,
         ?METHODS(<<"WrapForValidIterator.prototype">>, [<<"next">>, <<"return">>]), none)},
     {{builtin, <<"Iterator">>}, fixed(ctor_record(<<"Iterator">>, 0, ?ITERATOR_PROTO,
         ?METHODS(<<"Iterator">>, [<<"from">>, <<"concat">>, <<"zip">>, <<"zipKeyed">>]), fun construct/2))},
     {{builtin, <<"Iterator.prototype.[Symbol.iterator]">>}, function_record(<<"[Symbol.iterator]">>, 0)},
     {{builtin, <<"Iterator.prototype.[Symbol.dispose]">>}, function_record(<<"[Symbol.dispose]">>, 0)}]
    ++ [{{builtin, <<"Iterator.prototype.", Name/binary>>}, function_record(Name, Length)} || {Name, Length} <- Methods]
    ++ [{{builtin, <<"Iterator.from">>}, function_record(<<"from">>, 1)},
        {{builtin, <<"Iterator.concat">>}, function_record(<<"concat">>, 0)},
        {{builtin, <<"Iterator.zip">>}, function_record(<<"zip">>, 1)},
        {{builtin, <<"Iterator.zipKeyed">>}, function_record(<<"zipKeyed">>, 1)},
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

constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Iterator">>).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(_Name, _This, _Args) -> buoy_ref:type_error(<<"Constructor Iterator requires 'new'">>).

%% Iterator is abstract: new Iterator() throws, and a subclass constructs.
construct({'$f', {builtin, <<"Iterator">>}, _}, _Args) ->
    buoy_ref:type_error(<<"Abstract class Iterator not directly constructable">>);
construct(NewTarget, _Args) ->
    buoy_heap:new_object(buoy_ref_realm:proto_for(NewTarget, 'Iterator.prototype')).

%% The accessors of Symbol.toStringTag and constructor, whose setters do not
%% write the prototype itself.
getter(<<"toStringTag">>, _This) -> <<"Iterator">>;
getter(<<"constructor">>, _This) -> constructor().

setter(Name, This, V) ->
    ?IS_OBJECT(This) orelse buoy_ref:type_error(<<"Iterator.prototype setter called on a value that is not an object">>),
    This =/= ?ITERATOR_PROTO orelse buoy_ref:type_error(<<"Cannot assign to read only property of Iterator.prototype">>),
    Key = case Name of
        <<"toStringTag">> -> ?SYM(toStringTag);
        _ -> Name
    end,
    case buoy_heap:get_own(This, Key) of
        none -> buoy_ref_class:define_field(This, Key, V);
        _ -> buoy_ref:set(This, Key, V)
    end,
    undefined.

%%% Methods

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Iterator">>, <<"from">>, _This, Args) -> from(arg(1, Args));
method(<<"Iterator">>, <<"concat">>, _This, Args) -> concat(Args);
method(<<"Iterator">>, <<"zip">>, _This, Args) -> zip(arg(1, Args), arg(2, Args));
method(<<"Iterator">>, <<"zipKeyed">>, _This, Args) -> zip_keyed(arg(1, Args), arg(2, Args));
method(<<"IteratorHelper.prototype">>, <<"next">>, This, _Args) -> helper_next(This);
method(<<"IteratorHelper.prototype">>, <<"return">>, This, _Args) -> helper_return(This);
method(<<"WrapForValidIterator.prototype">>, Name, This, _Args) -> wrap(Name, This);
method(<<"Iterator.prototype">>, Name, This, Args) ->
    ?IS_OBJECT(This) orelse
        buoy_ref:type_error(<<"Iterator.prototype.", Name/binary, " called on a value that is not an object">>),
    prototype_method(Name, This, Args).

%% Iterator.from: an iterator that inherits from Iterator.prototype as it is,
%% any other iterator wrapped.
from(O) ->
    {Iterator, Next} = flattenable(O, iterate_strings),
    case buoy_ref:instance_of(Iterator, constructor()) of
        true -> Iterator;
        false -> buoy_heap:new_exotic(wrap_for_valid_iterator, ?WRAP_PROTO, {Iterator, Next})
    end.

%% %IteratorPrototype%[@@dispose]: calls the return method, if any.
dispose(O) ->
    case get_method(O, <<"return">>) of
        undefined -> ok;
        Method -> buoy_ref:call(Method, O, [])
    end,
    undefined.

%% Iterator.concat: a helper over the iterables in order. Each iterable and its
%% iterator method are checked first; each iterator opens when the one before
%% it is done.
concat(Items) ->
    Iterables = [begin
                     ?IS_OBJECT(Item) orelse buoy_ref:type_error(buoy_ref_string:concat(buoy_ref:describe(Item), <<" is not an object">>)),
                     case get_method(Item, buoy_heap:well_known(iterator)) of
                         undefined -> buoy_ref:type_error(<<"The value is not iterable">>);
                         Method -> {Item, Method}
                     end
                 end || Item <- Items],
    buoy_heap:new_exotic(iterator_helper, ?HELPER_PROTO, {suspended_start, none, {concat, Iterables, none}}).

%% Iterator.zip: a helper that yields an array of one value of each iterator.
%% It reads the options and opens every iterator first. Here and below, Open
%% holds the iterators opened so far, last first: the order of IteratorCloseAll.
zip(Iterables, Options) ->
    {Mode, PaddingOption} = zip_options(Iterables, Options),
    Open = open_iterables(buoy_ref_iterator:get_iterator(Iterables), []),
    Padding = zip_padding(PaddingOption, length(Open), Open),
    zip_helper(lists:reverse(Open), Padding, Mode, array).

%% Iterator.zipKeyed: zip over the own enumerable properties of an object,
%% whose results are objects with the same keys.
zip_keyed(Iterables, Options) ->
    {Mode, PaddingOption} = zip_options(Iterables, Options),
    {Keys, Open} = open_keyed(Iterables, buoy_heap:own_keys(Iterables), [], []),
    Padding = case PaddingOption of
        undefined -> [undefined || _ <- Keys];
        _ -> [closing_all(Open, fun() -> buoy_ref:get(PaddingOption, K) end) || K <- Keys]
    end,
    zip_helper(lists:reverse(Open), Padding, Mode, {keys, Keys}).

zip_options(Iterables, Options) ->
    ?IS_OBJECT(Iterables) orelse buoy_ref:type_error(buoy_ref_string:concat(buoy_ref:describe(Iterables), <<" is not an object">>)),
    Mode = case Options of
        undefined -> shortest;
        _ when ?IS_OBJECT(Options) -> zip_mode(buoy_ref:get(Options, <<"mode">>));
        _ -> buoy_ref:type_error(<<"The options argument must be an object">>)
    end,
    {Mode, padding_option(Mode, Options)}.

zip_mode(undefined) -> shortest;
zip_mode(<<"shortest">>) -> shortest;
zip_mode(<<"longest">>) -> longest;
zip_mode(<<"strict">>) -> strict;
zip_mode(_) -> buoy_ref:type_error(<<"The mode must be \"shortest\", \"longest\", or \"strict\"">>).

padding_option(longest, Options) ->
    case buoy_ref:get(Options, <<"padding">>) of
        Padding when Padding =:= undefined; ?IS_OBJECT(Padding) -> Padding;
        _ -> buoy_ref:type_error(<<"The padding must be an object">>)
    end;
padding_option(_Mode, _Options) -> undefined.

open_iterables(Input, Open) ->
    case closing_all(Open, fun() -> step_value(Input) end) of
        done -> Open;
        {value, V} ->
            Iterator = try flattenable(V, reject_strings)
                       catch error:Reason:Stack -> abort_all(Open ++ [Input], Reason, Stack)
                       end,
            open_iterables(Input, [Iterator | Open])
    end.

open_keyed(_O, [], Keys, Open) -> {lists:reverse(Keys), Open};
open_keyed(O, [K | Rest], Keys, Open) ->
    Value = closing_all(Open, fun() ->
                                      case buoy_heap:is_enumerable(buoy_heap:get_own(O, K)) of
                                          true -> buoy_ref:get(O, K);
                                          false -> undefined
                                      end
                              end),
    case Value of
        undefined -> open_keyed(O, Rest, Keys, Open);
        _ -> open_keyed(O, Rest, [K | Keys], [closing_all(Open, fun() -> flattenable(Value, reject_strings) end) | Open])
    end.

%% The padding of zip: the values of the padding iterable, then undefined.
zip_padding(undefined, Count, _Open) -> lists:duplicate(Count, undefined);
zip_padding(Iterable, Count, Open) ->
    read_padding(closing_all(Open, fun() -> buoy_ref_iterator:get_iterator(Iterable) end), Count, Open, []).

read_padding({Iterator, _}, 0, Open, Padding) ->
    closing_all(Open, fun() -> buoy_ref_iterator:close(Iterator) end),
    lists:reverse(Padding);
read_padding(Record, Count, Open, Padding) ->
    case closing_all(Open, fun() -> step_value(Record) end) of
        done -> lists:reverse(Padding, lists:duplicate(Count, undefined));
        {value, V} -> read_padding(Record, Count - 1, Open, [V | Padding])
    end.

%% IteratorZip: each entry is {open, Record, Padding}, or {padded, Padding}
%% once the iterator is done in longest mode.
zip_helper(Iterators, Padding, Mode, Finish) ->
    Entries = lists:zipwith(fun(Record, Pad) -> {open, Record, Pad} end, Iterators, Padding),
    buoy_heap:new_exotic(iterator_helper, ?HELPER_PROTO, {suspended_start, none, {zip, Entries, Mode, Finish}}).

%% IfAbruptCloseIterators: when Fun throws, the iterators of Open close and
%% the error of Fun wins.
closing_all(Open, Fun) ->
    try Fun()
    catch error:Reason:Stack -> abort_all(Open, Reason, Stack)
    end.

%% IteratorCloseAll for a throw completion: the errors of the return methods
%% are ignored.
abort_all(Open, Reason, Stack) ->
    lists:foreach(fun({Iterator, _}) -> close_quietly(Iterator) end, Open),
    erlang:raise(error, Reason, Stack).

%% IteratorCloseAll for a normal or return completion: the first error of a
%% return method wins, and the iterators after it still close.
close_all([]) -> ok;
close_all([{Iterator, _} | Rest]) ->
    closing_all(Rest, fun() -> buoy_ref_iterator:close(Iterator) end),
    close_all(Rest).

%% GetIteratorFlattenable.
flattenable(O, Primitives) ->
    case ?IS_OBJECT(O) orelse (Primitives =:= iterate_strings andalso ?IS_STRING(O)) of
        true -> ok;
        false -> buoy_ref:type_error(buoy_ref_string:concat(buoy_ref:describe(O), <<" is not an object">>))
    end,
    Iterator = case get_method(O, buoy_heap:well_known(iterator)) of
        undefined -> O;
        Method -> buoy_ref:call(Method, O, [])
    end,
    ?IS_OBJECT(Iterator) orelse buoy_ref:type_error(<<"The iterator is not an object">>),
    {Iterator, buoy_ref:get(Iterator, <<"next">>)}.

get_method(O, K) ->
    case buoy_ref:get(O, K) of
        M when M =:= undefined; M =:= null -> undefined;
        {'$f', _, _} = M -> M;
        M -> buoy_ref:type_error(buoy_ref_string:concat(buoy_ref:describe(M), <<" is not a function">>))
    end.

wrap(Name, This) ->
    {Iterator, Next} = case ?IS_OBJECT(This) andalso buoy_heap:class_of(This) =:= wrap_for_valid_iterator of
        true -> buoy_heap:slots(This);
        false -> buoy_ref:type_error(<<"WrapForValidIteratorPrototype method called on an incompatible receiver">>)
    end,
    case Name of
        <<"next">> -> buoy_ref:call(Next, Iterator, []);
        <<"return">> ->
            case get_method(Iterator, <<"return">>) of
                undefined -> buoy_ref_iterator:result(undefined, true);
                Method -> buoy_ref:call(Method, Iterator, [])
            end
    end.

%% The lazy methods validate their argument, closing the iterator when it is
%% wrong, and return a helper.
prototype_method(<<"map">>, O, Args) -> helper(O, {map, callback(O, arg(1, Args)), 0});
prototype_method(<<"filter">>, O, Args) -> helper(O, {filter, callback(O, arg(1, Args)), 0});
prototype_method(<<"flatMap">>, O, Args) -> helper(O, {flat_map, callback(O, arg(1, Args)), 0, none});
prototype_method(<<"take">>, O, Args) -> helper(O, {take, limit(O, arg(1, Args))});
prototype_method(<<"drop">>, O, Args) -> helper(O, {drop, limit(O, arg(1, Args))});
prototype_method(<<"chunks">>, O, Args) -> helper(O, {chunks, window_size(O, arg(1, Args)), [], 0});
prototype_method(<<"windows">>, O, Args) ->
    Size = window_size(O, arg(1, Args)),
    helper(O, {windows, Size, undersized(O, arg(2, Args)), [], 0});
prototype_method(<<"includes">>, O, Args) ->
    Skip = skipped_elements(O, arg(2, Args)),
    Search = arg(1, Args),
    Record = direct(O),
    %% An integer is less than the atom infinity in term order.
    each(Record, fun(V, I) -> stop_when(Record, I >= Skip andalso buoy_ref_number:same_value_zero(V, Search), true) end, 0, false);
%% Iterator.prototype.join (stage 2.7): the separator first, which closes the
%% iterator when it does not convert, then `next`. A value that does not
%% convert closes the iterator too, and null and undefined join as "".
prototype_method(<<"join">>, O, Args) ->
    Separator = case arg(1, Args) of
        undefined -> <<",">>;
        S -> closing_on_error(O, fun() -> buoy_ref:to_string(S) end)
    end,
    Record = direct(O),
    buoy_ref_string:concat(join(Record, Separator, []));
prototype_method(<<"reduce">>, O, Args) ->
    Reducer = callback(O, arg(1, Args)),
    Record = direct(O),
    case Args of
        [_, Initial | _] -> reduce(Record, Reducer, Initial, 0);
        _ ->
            case step_value(Record) of
                done -> buoy_ref:type_error(<<"Reduce of empty iterator with no initial value">>);
                {value, First} -> reduce(Record, Reducer, First, 1)
            end
    end;
prototype_method(<<"toArray">>, O, _Args) ->
    buoy_heap:new_array(collect(direct(O), []));
prototype_method(<<"forEach">>, O, Args) ->
    Fun = callback(O, arg(1, Args)),
    Record = direct(O),
    each(Record, fun(V, I) -> _ = calling(Record, Fun, [V, I]), continue end, 0),
    undefined;
prototype_method(<<"some">>, O, Args) ->
    Predicate = callback(O, arg(1, Args)),
    Record = direct(O),
    each(Record, fun(V, I) -> stop_when(Record, buoy_ref:truthy(calling(Record, Predicate, [V, I])), true) end, 0, false);
prototype_method(<<"every">>, O, Args) ->
    Predicate = callback(O, arg(1, Args)),
    Record = direct(O),
    each(Record, fun(V, I) -> stop_when(Record, not buoy_ref:truthy(calling(Record, Predicate, [V, I])), false) end, 0, true);
prototype_method(<<"find">>, O, Args) ->
    Predicate = callback(O, arg(1, Args)),
    Record = direct(O),
    each(Record, fun(V, I) -> stop_when(Record, buoy_ref:truthy(calling(Record, Predicate, [V, I])), V) end, 0, undefined).

%% A callback argument: when it is not callable, the iterator closes and the
%% method throws a TypeError.
callback(O, F) ->
    case buoy_heap:is_callable(F) of
        true -> F;
        false ->
            close_quietly(O),
            buoy_ref:type_error(buoy_ref_string:concat(buoy_ref:describe(F), <<" is not a function">>))
    end.

%% The limit of take and drop: a number that is not NaN or negative.
limit(O, V) ->
    Number = try buoy_ref:to_number(V)
             catch error:Reason:Stack -> close_quietly(O), erlang:raise(error, Reason, Stack)
             end,
    Integer = case Number of
        'NaN' -> close_quietly(O), buoy_heap:throw_error('RangeError', <<"The limit must be a number">>);
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
            buoy_heap:throw_error('RangeError', <<"The limit must be between 0 and 2^53 - 1">>)
    end.

%% The size of chunks and windows: an integral Number from 1 to 2^32 - 1. These
%% arguments are not coerced.
window_size(O, Size) ->
    buoy_ref_number:is_integral(Size) orelse reject(O, 'TypeError', <<"The size must be an integer">>),
    (Size >= 1 andalso Size =< 16#FFFFFFFF) orelse reject(O, 'RangeError', <<"The size must be between 1 and 2^32 - 1">>),
    trunc(Size).

undersized(_O, undefined) -> only_full;
undersized(_O, <<"only-full">>) -> only_full;
undersized(_O, <<"allow-partial">>) -> allow_partial;
undersized(O, _) -> reject(O, 'TypeError', <<"undersized must be \"only-full\" or \"allow-partial\"">>).

%% The skippedElements of includes: +Infinity or an integer from 0 to 2^53 - 1.
skipped_elements(_O, undefined) -> 0;
skipped_elements(_O, 'Infinity') -> ?INFINITY;
skipped_elements(O, '-Infinity') -> reject(O, 'RangeError', <<"skippedElements must not be negative">>);
skipped_elements(O, N) ->
    buoy_ref_number:is_integral(N) orelse reject(O, 'TypeError', <<"skippedElements must be an integer">>),
    (N >= 0 andalso N =< ?MAX_SAFE_INTEGER) orelse reject(O, 'RangeError', <<"skippedElements must be between 0 and 2^53 - 1">>),
    trunc(N).

%% An argument that is not valid: the iterator closes, and the method throws.
-spec reject(term(), atom(), binary()) -> no_return().
reject(O, Type, Message) ->
    close_quietly(O),
    buoy_heap:throw_error(Type, Message).

join({Iterator, _} = Record, Separator, Acc) ->
    case step_value(Record) of
        done ->
            lists:reverse(Acc);
        {value, V} ->
            Text = case V of
                Nullish when Nullish =:= undefined; Nullish =:= null -> <<>>;
                _ -> closing_on_error(Iterator, fun() -> buoy_ref:to_string(V) end)
            end,
            join(Record, Separator, [Text | separated(Separator, Acc)])
    end.

separated(_Separator, []) -> [];
separated(Separator, Acc) -> [Separator | Acc].

%% IfAbruptCloseIterator: when Fun throws, O closes, and the error stands.
closing_on_error(O, Fun) ->
    try Fun()
    catch error:Reason:Stack -> close_quietly(O), erlang:raise(error, Reason, Stack)
    end.

close_quietly(O) ->
    try buoy_ref_iterator:close(O) of
        _ -> ok
    catch
        error:_ -> ok
    end.

%% GetIteratorDirect.
direct(O) -> {O, buoy_ref:get(O, <<"next">>)}.

helper(O, Step) ->
    buoy_heap:new_exotic(iterator_helper, ?HELPER_PROTO, {suspended_start, direct(O), Step}).

%% IteratorStep: the result object, or done. An error leaves the iterator done.
iterator_step({Iterator, Next}) ->
    Result = buoy_ref:call(Next, Iterator, []),
    ?IS_OBJECT(Result) orelse
        buoy_ref:type_error(buoy_ref_string:concat([<<"Iterator result ">>, buoy_ref:describe(Result), <<" is not an object">>])),
    case buoy_ref:truthy(buoy_ref:get(Result, <<"done">>)) of
        true -> done;
        false -> Result
    end.

%% IteratorStepValue: {value, V} or done.
step_value(Record) ->
    case iterator_step(Record) of
        done -> done;
        Result -> {value, buoy_ref:get(Result, <<"value">>)}
    end.

%% A call of a callback: when it throws, the iterator closes first.
calling({Iterator, _}, F, Args) ->
    try buoy_ref:call(F, undefined, Args)
    catch error:Reason:Stack -> close_quietly(Iterator), erlang:raise(error, Reason, Stack)
    end.

stop_when({Iterator, _}, true, Result) -> buoy_ref_iterator:close(Iterator), {stop, Result};
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
    case ?IS_OBJECT(H) andalso buoy_heap:class_of(H) =:= iterator_helper of
        true -> buoy_heap:slots(H);
        false -> buoy_ref:type_error(<<"Iterator Helper method called on an object that is not an iterator helper">>)
    end.

%% %IteratorHelperPrototype%.next: GeneratorResume of the closure.
helper_next(H) ->
    case helper_slots(H) of
        {executing, _, _} -> buoy_ref:type_error(<<"Generator is already running">>);
        {completed, _, _} -> buoy_ref_iterator:result(undefined, true);
        {_, Underlying, Step} ->
            buoy_heap:set_slots(H, {executing, Underlying, Step}),
            try step(Underlying, Step) of
                {yield, V, Step1} ->
                    buoy_heap:set_slots(H, {suspended_yield, Underlying, Step1}),
                    buoy_ref_iterator:result(V, false);
                done ->
                    buoy_heap:set_slots(H, {completed, Underlying, Step}),
                    buoy_ref_iterator:result(undefined, true)
            catch
                Class:Reason:Stack ->
                    buoy_heap:set_slots(H, {completed, Underlying, Step}),
                    erlang:raise(Class, Reason, Stack)
            end
    end.

%% %IteratorHelperPrototype%.return: closes the inner iterator of flatMap or
%% concat, then the underlying iterator. From suspended-yield the closure
%% resumes to close them, so the helper is executing meanwhile.
helper_return(H) ->
    case helper_slots(H) of
        {executing, _, _} -> buoy_ref:type_error(<<"Generator is already running">>);
        {completed, _, _} -> buoy_ref_iterator:result(undefined, true);
        {State, Underlying, Step} ->
            During = case State of
                suspended_start -> completed;
                suspended_yield -> executing
            end,
            buoy_heap:set_slots(H, {During, Underlying, Step}),
            try close_helper(Underlying, Step)
            after
                buoy_heap:set_slots(H, {completed, Underlying, Step})
            end,
            buoy_ref_iterator:result(undefined, true)
    end.

close_helper(none, {concat, _, {Inner, _}}) -> buoy_ref_iterator:close(Inner);
close_helper(none, {concat, _, none}) -> ok;
close_helper(none, {zip, Entries, _, _}) -> close_all(open_records(Entries, []));
close_helper(_Underlying, exhausted) -> ok;
close_helper({Iterator, _}, {flat_map, _, _, {Inner, _}}) ->
    try buoy_ref_iterator:close(Inner)
    catch error:Reason:Stack -> close_quietly(Iterator), erlang:raise(error, Reason, Stack)
    end,
    buoy_ref_iterator:close(Iterator);
close_helper({Iterator, _}, _Step) ->
    buoy_ref_iterator:close(Iterator).

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
            case buoy_ref:truthy(calling(Underlying, Predicate, [V, Counter])) of
                true -> {yield, V, {filter, Predicate, Counter + 1}};
                false -> step(Underlying, setelement(3, Step, Counter + 1))
            end
    end;
step({Iterator, _}, {take, 0}) ->
    buoy_ref_iterator:close(Iterator),
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
    Iterator = buoy_ref:call(Method, Iterable, []),
    ?IS_OBJECT(Iterator) orelse buoy_ref:type_error(<<"The iterator is not an object">>),
    step(None, {concat, Rest, direct(Iterator)});
step(None, {concat, Rest, Current} = Step) ->
    case step_value(Current) of
        done -> step(None, {concat, Rest, none});
        {value, V} -> {yield, V, Step}
    end;
%% chunks and windows keep their buffer newest first. After the last partial
%% buffer the underlying iterator is done, so return does not close it.
step(Underlying, {chunks, Size, Buffer, Count}) ->
    case step_value(Underlying) of
        done when Count > 0 -> {yield, buoy_heap:new_array(lists:reverse(Buffer)), exhausted};
        done -> done;
        {value, V} when Count < Size - 1 -> step(Underlying, {chunks, Size, [V | Buffer], Count + 1});
        {value, V} -> {yield, buoy_heap:new_array(lists:reverse(Buffer, [V])), {chunks, Size, [], 0}}
    end;
step(Underlying, {windows, Size, Undersized, Buffer, Count}) ->
    case step_value(Underlying) of
        done when Undersized =:= allow_partial, Count > 0, Count < Size ->
            {yield, buoy_heap:new_array(lists:reverse(Buffer)), exhausted};
        done -> done;
        {value, V} when Count < Size - 1 -> step(Underlying, {windows, Size, Undersized, [V | Buffer], Count + 1});
        {value, V} ->
            Window = [V | lists:sublist(Buffer, Size - 1)],
            {yield, buoy_heap:new_array(lists:reverse(Window)), {windows, Size, Undersized, Window, Size}}
    end;
step(_Underlying, exhausted) ->
    done;
step(_None, {zip, [], _Mode, _Finish}) ->
    done;
step(_None, {zip, Entries, Mode, Finish}) ->
    case zip_row(Entries, Mode, [], []) of
        done -> done;
        {Values, Entries1} -> {yield, zip_result(Finish, Values), {zip, Entries1, Mode, Finish}}
    end.

%% One value of each iterator of zip: {Values, Entries}, or done. Seen holds the
%% entries before the current one, newest first.
zip_row([], _Mode, Seen, Values) ->
    {lists:reverse(Values), lists:reverse(Seen)};
zip_row([{padded, Pad} = Entry | Rest], Mode, Seen, Values) ->
    zip_row(Rest, Mode, [Entry | Seen], [Pad | Values]);
zip_row([{open, Record, Pad} = Entry | Rest], Mode, Seen, Values) ->
    Next = try step_value(Record)
           catch error:Reason:Stack -> abort_all(open_records(Rest, Seen), Reason, Stack)
           end,
    case Next of
        {value, V} -> zip_row(Rest, Mode, [Entry | Seen], [V | Values]);
        done when Mode =:= shortest -> close_all(open_records(Rest, Seen)), done;
        done when Mode =:= strict, Seen =:= [] -> strict_rest(Rest);
        done when Mode =:= strict -> closing_all(open_records(Rest, Seen), fun mismatch/0);
        done ->
            case open_records(Rest, Seen) of
                [] -> done;
                _ -> zip_row(Rest, Mode, [{padded, Pad} | Seen], [Pad | Values])
            end
    end.

%% Strict mode after the first iterator is done: every other one must be done.
strict_rest([]) ->
    done;
strict_rest([{open, Record, _} = Entry | Rest]) ->
    Next = try iterator_step(Record)
           catch error:Reason:Stack -> abort_all(open_records(Rest, []), Reason, Stack)
           end,
    case Next of
        done -> strict_rest(Rest);
        _ -> closing_all(open_records(Rest, [Entry]), fun mismatch/0)
    end.

-spec mismatch() -> no_return().
mismatch() -> buoy_ref:type_error(<<"The iterators of a strict zip have different lengths">>).

%% The open iterators of the entries Rest and Seen, last first.
open_records(Rest, Seen) -> [Record || {open, Record, _} <- lists:reverse(Rest, Seen)].

zip_result(array, Values) -> buoy_heap:new_array(Values);
zip_result({keys, Keys}, Values) -> buoy_heap:object(null, lists:zip(Keys, Values)).

decrement(?INFINITY) -> ?INFINITY;
decrement(N) -> N - 1.
