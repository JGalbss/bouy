%% The `Array` namespace and array methods. Arrays are lists. A mutator
%% returns {Result, NewList} and the compiler writes NewList back (contract
%% section 6).
-module(bouy_array).

-export(['$member'/1, '$call'/1, new/1, call/3, get/2, mutate/3]).
-export(['isArray'/1, from/1, 'of'/1]).
-export([join/2, set/3]).

-define(FUNCTIONS, [<<"isArray">>, <<"from">>, <<"of">>]).
-define(MUTATORS, [<<"push">>, <<"pop">>, <<"shift">>, <<"unshift">>, <<"splice">>, <<"sort">>, <<"reverse">>, <<"fill">>, <<"copyWithin">>]).
-define(METHODS, [
    <<"at">>, <<"concat">>, <<"entries">>, <<"every">>, <<"filter">>, <<"find">>, <<"findIndex">>, <<"findLast">>,
    <<"findLastIndex">>, <<"flat">>, <<"flatMap">>, <<"forEach">>, <<"includes">>, <<"indexOf">>, <<"join">>,
    <<"keys">>, <<"lastIndexOf">>, <<"map">>, <<"reduce">>, <<"reduceRight">>, <<"slice">>, <<"some">>,
    <<"toReversed">>, <<"toSorted">>, <<"toString">>, <<"values">>
    | ?MUTATORS
]).

%%% Namespace

-spec '$member'(binary()) -> term().
'$member'(Name) -> bouy_rt:member_function(?MODULE, Name, ?FUNCTIONS).

%% `Array(n)` and `Array(a, b)`.
-spec '$call'(list()) -> list().
'$call'([N]) when is_number(N); N =:= 'NaN'; N =:= 'Infinity'; N =:= '-Infinity' ->
    case bouy_number:'isSafeInteger'([N]) andalso N >= 0 of
        true -> lists:duplicate(trunc(N), undefined);
        false -> bouy_error:throw(<<"RangeError">>, <<"Invalid array length">>)
    end;
'$call'(Items) ->
    Items.

-spec new(list()) -> list().
new(Args) -> '$call'(Args).

-spec 'isArray'(list()) -> boolean().
'isArray'(Args) -> is_list(bouy_rt:arg(1, Args)).

-spec 'of'(list()) -> list().
'of'(Items) -> Items.

%% `Array.from(iterable or { length }, mapFn)`.
-spec from(list()) -> list().
from(Args) ->
    Items = source_items(bouy_rt:arg(1, Args)),
    case bouy_rt:arg(2, Args) of
        undefined -> Items;
        F -> map_indexed(fun(Item, I) -> bouy_rt:call(F, [Item, I]) end, Items)
    end.

%% An object without `length`, and a number or a boolean, which ToObject
%% makes an object without `length`, give no items.
source_items(#{<<"length">> := Length} = ArrayLike) ->
    [bouy_rt:get(ArrayLike, I) || I <- lists:seq(0, bouy_rt:clamp(Length, 0, 16#FFFFFFFF) - 1)];
source_items(Value) when is_map(Value); is_number(Value); is_boolean(Value); is_atom(Value), Value =/= undefined, Value =/= null ->
    [];
source_items(Iterable) ->
    bouy_rt:to_list(Iterable).

%%% Properties

-spec get(list(), term()) -> term().
get(L, <<"length">>) ->
    length(L);
get(L, Key) ->
    case bouy_rt:to_index(Key) of
        I when is_integer(I) -> nth(I, L);
        none -> bouy_rt:member(?MODULE, Key, ?METHODS)
    end.

nth(0, [Item | _]) -> Item;
nth(I, [_ | Rest]) -> nth(I - 1, Rest);
nth(_, []) -> undefined.

%% `list[key] = value`: writing past the end pads with undefined, and
%% `length` truncates or pads.
-spec set(list(), term(), term()) -> list().
set(L, <<"length">>, Length) ->
    resize(L, bouy_rt:clamp(Length, 0, 16#FFFFFFFF));
set(L, Key, Value) ->
    case bouy_rt:to_index(Key) of
        I when is_integer(I) -> replace(L, I, Value);
        none -> bouy_error:throw(<<"TypeError">>, <<"Cannot set property '", (bouy_rt:to_key(Key))/binary, "' on an array">>)
    end.

replace([_ | Rest], 0, Value) -> [Value | Rest];
replace([Item | Rest], I, Value) -> [Item | replace(Rest, I - 1, Value)];
replace([], I, Value) -> lists:duplicate(I, undefined) ++ [Value].

resize(L, Length) when length(L) >= Length -> lists:sublist(L, Length);
resize(L, Length) -> L ++ lists:duplicate(Length - length(L), undefined).

%%% Methods

-spec call(binary(), list(), list()) -> term().
call(<<"at">>, L, Args) -> at(L, bouy_rt:arg(1, Args));
call(<<"concat">>, L, Args) -> L ++ lists:append([spread(Arg) || Arg <- Args]);
call(<<"entries">>, L, _Args) -> bouy_iterator:new(<<"Array Iterator">>, map_indexed(fun(Item, I) -> [I, Item] end, L));
call(<<"every">>, L, Args) -> every(L, bouy_rt:arg(1, Args));
call(<<"filter">>, L, Args) -> filter(L, bouy_rt:arg(1, Args));
call(<<"find">>, L, Args) -> find(L, bouy_rt:arg(1, Args), item);
call(<<"findIndex">>, L, Args) -> find(L, bouy_rt:arg(1, Args), index);
call(<<"findLast">>, L, Args) -> find_last(L, bouy_rt:arg(1, Args), item);
call(<<"findLastIndex">>, L, Args) -> find_last(L, bouy_rt:arg(1, Args), index);
call(<<"flat">>, L, Args) -> flat(L, depth(bouy_rt:arg(1, Args)));
call(<<"flatMap">>, L, Args) -> flat(map(L, bouy_rt:arg(1, Args)), 1);
call(<<"forEach">>, L, Args) -> for_each(L, bouy_rt:arg(1, Args));
call(<<"includes">>, L, Args) -> includes(L, bouy_rt:arg(1, Args), bouy_rt:arg(2, Args));
call(<<"indexOf">>, L, Args) -> index_of(L, bouy_rt:arg(1, Args), bouy_rt:arg(2, Args));
call(<<"join">>, L, Args) -> join(L, separator(bouy_rt:arg(1, Args)));
call(<<"keys">>, L, _Args) -> bouy_iterator:new(<<"Array Iterator">>, lists:seq(0, length(L) - 1));
call(<<"lastIndexOf">>, L, Args) -> last_index_of(L, Args);
call(<<"map">>, L, Args) -> map(L, bouy_rt:arg(1, Args));
call(<<"reduce">>, L, Args) -> reduce(map_indexed(fun(Item, I) -> {I, Item} end, L), L, Args);
call(<<"reduceRight">>, L, Args) -> reduce(lists:reverse(map_indexed(fun(Item, I) -> {I, Item} end, L)), L, Args);
call(<<"slice">>, L, Args) -> slice(L, bouy_rt:arg(1, Args), bouy_rt:arg(2, Args));
call(<<"some">>, L, Args) -> some(L, bouy_rt:arg(1, Args));
call(<<"toReversed">>, L, _Args) -> lists:reverse(L);
call(<<"toSorted">>, L, Args) -> sort(L, bouy_rt:arg(1, Args));
call(<<"toString">>, L, _Args) -> join(L, <<",">>);
call(<<"values">>, L, _Args) -> bouy_iterator:new(<<"Array Iterator">>, L);
call(Name, L, Args) ->
    case lists:member(Name, ?MUTATORS) of
        true -> element(1, mutate(Name, L, Args));
        false -> bouy_rt:prototype_call(L, Name, Args)
    end.

-spec mutate(binary(), list(), list()) -> {term(), list()}.
mutate(<<"push">>, L, Items) ->
    New = L ++ Items,
    {length(New), New};
mutate(<<"pop">>, [], _Args) ->
    {undefined, []};
mutate(<<"pop">>, L, _Args) ->
    {lists:last(L), lists:droplast(L)};
mutate(<<"shift">>, [], _Args) ->
    {undefined, []};
mutate(<<"shift">>, [First | Rest], _Args) ->
    {First, Rest};
mutate(<<"unshift">>, L, Items) ->
    New = Items ++ L,
    {length(New), New};
mutate(<<"splice">>, L, Args) ->
    splice(L, Args);
mutate(<<"sort">>, L, Args) ->
    Sorted = sort(L, bouy_rt:arg(1, Args)),
    {Sorted, Sorted};
mutate(<<"reverse">>, L, _Args) ->
    Reversed = lists:reverse(L),
    {Reversed, Reversed};
mutate(<<"fill">>, L, Args) ->
    Filled = fill(L, Args),
    {Filled, Filled};
mutate(<<"copyWithin">>, L, Args) ->
    Copied = copy_within(L, Args),
    {Copied, Copied};
mutate(Name, L, Args) ->
    {call(Name, L, Args), L}.

%%% Iteration

%% Callbacks receive (item, index, array).
map(L, F) -> map_indexed(fun(Item, I) -> bouy_rt:call(F, [Item, I, L]) end, L).

map_indexed(F, L) -> map_indexed(F, L, 0).

map_indexed(F, [Item | Rest], I) -> [F(Item, I) | map_indexed(F, Rest, I + 1)];
map_indexed(_, [], _) -> [].

for_each(L, F) ->
    lists:foreach(fun({I, Item}) -> bouy_rt:call(F, [Item, I, L]) end, lists:enumerate(0, L)),
    undefined.

filter(L, F) ->
    [Item || {I, Item} <- lists:enumerate(0, L), bouy_rt:truthy(bouy_rt:call(F, [Item, I, L]))].

every(L, F) -> lists:all(fun({I, Item}) -> bouy_rt:truthy(bouy_rt:call(F, [Item, I, L])) end, lists:enumerate(0, L)).

some(L, F) -> lists:any(fun({I, Item}) -> bouy_rt:truthy(bouy_rt:call(F, [Item, I, L])) end, lists:enumerate(0, L)).

find(L, F, Want) ->
    found(search(lists:enumerate(0, L), L, F), Want).

find_last(L, F, Want) ->
    found(search(lists:reverse(lists:enumerate(0, L)), L, F), Want).

search([{I, Item} | Rest], L, F) ->
    case bouy_rt:truthy(bouy_rt:call(F, [Item, I, L])) of
        true -> {I, Item};
        false -> search(Rest, L, F)
    end;
search([], _L, _F) ->
    none.

found({_, Item}, item) -> Item;
found({I, _}, index) -> I;
found(none, item) -> undefined;
found(none, index) -> -1.

reduce(Indexed, L, [F]) ->
    case Indexed of
        [{_, First} | Rest] -> fold(F, First, Rest, L);
        [] -> bouy_error:throw(<<"TypeError">>, <<"Reduce of empty array with no initial value">>)
    end;
reduce(Indexed, L, [F, Initial | _]) ->
    fold(F, Initial, Indexed, L);
reduce(_Indexed, _L, []) ->
    bouy_error:throw(<<"TypeError">>, <<"undefined is not a function">>).

fold(F, Acc, [{I, Item} | Rest], L) -> fold(F, bouy_rt:call(F, [Acc, Item, I, L]), Rest, L);
fold(_, Acc, [], _) -> Acc.

%%% Searching

includes(L, Value, FromArg) ->
    lists:any(fun(Item) -> bouy_rt:same_value_zero(Item, Value) end, lists:nthtail(start(L, FromArg), L)).

index_of(L, Value, FromArg) ->
    Skipped = start(L, FromArg),
    position(fun(Item) -> bouy_rt:strict_eq(Item, Value) end, lists:nthtail(Skipped, L), Skipped).

position(Test, [Item | Rest], I) ->
    case Test(Item) of
        true -> I;
        false -> position(Test, Rest, I + 1)
    end;
position(_, [], _) ->
    -1.

last_index_of(L, Args) ->
    Value = bouy_rt:arg(1, Args),
    Length = length(L),
    Last =
        case Args of
            [_, FromArg | _] -> last_start(bouy_rt:to_integer(FromArg), Length);
            _ -> Length - 1
        end,
    Candidates = [I || {I, Item} <- lists:enumerate(0, L), I =< Last, bouy_rt:strict_eq(Item, Value)],
    case Candidates of
        [] -> -1;
        _ -> lists:last(Candidates)
    end.

start(L, FromArg) -> bouy_rt:relative_index(FromArg, length(L), 0).

last_start('-Infinity', _Length) -> -1;
last_start('Infinity', Length) -> Length - 1;
last_start(I, Length) when I < 0 -> Length + I;
last_start(I, Length) -> min(I, Length - 1).

at(L, Arg) ->
    case bouy_rt:to_integer(Arg) of
        I when is_integer(I), I < 0 -> nth(length(L) + I, L);
        I when is_integer(I) -> nth(I, L);
        _ -> undefined
    end.

%%% Building

slice(L, Start, End) ->
    Length = length(L),
    From = bouy_rt:relative_index(Start, Length, 0),
    To = bouy_rt:relative_index(End, Length, Length),
    lists:sublist(L, From + 1, max(0, To - From)).

spread(Arg) when is_list(Arg) -> Arg;
spread(Arg) -> [Arg].

depth(undefined) -> 1;
depth(Arg) ->
    case bouy_rt:to_integer(Arg) of
        'Infinity' -> infinity;
        D when is_integer(D) -> D;
        _ -> 0
    end.

flat(L, Depth) ->
    lists:flatmap(fun(Item) -> flatten(Item, Depth) end, L).

flatten(Item, infinity) when is_list(Item) -> flat(Item, infinity);
flatten(Item, Depth) when is_list(Item), is_integer(Depth), Depth > 0 -> flat(Item, Depth - 1);
flatten(Item, _) -> [Item].

-spec join(list(), binary()) -> binary().
join(L, Separator) ->
    iolist_to_binary(lists:join(Separator, [join_item(Item) || Item <- L])).

join_item(undefined) -> <<>>;
join_item(null) -> <<>>;
join_item(Item) -> bouy_rt:to_string(Item).

separator(undefined) -> <<",">>;
separator(Separator) -> bouy_rt:to_string(Separator).

splice(L, Args) ->
    Length = length(L),
    Start = bouy_rt:relative_index(bouy_rt:arg(1, Args), Length, 0),
    Count =
        case Args of
            [] -> 0;
            [_] -> Length - Start;
            [_, CountArg | _] -> bouy_rt:clamp(CountArg, 0, Length - Start)
        end,
    {Before, Rest} = lists:split(Start, L),
    {Removed, After} = lists:split(Count, Rest),
    {Removed, Before ++ bouy_rt:rest(3, Args) ++ After}.

fill(L, Args) ->
    Length = length(L),
    Value = bouy_rt:arg(1, Args),
    From = bouy_rt:relative_index(bouy_rt:arg(2, Args), Length, 0),
    To = bouy_rt:relative_index(bouy_rt:arg(3, Args), Length, Length),
    [fill_item(I, Item, From, To, Value) || {I, Item} <- lists:enumerate(0, L)].

fill_item(I, _Item, From, To, Value) when I >= From, I < To -> Value;
fill_item(_I, Item, _From, _To, _Value) -> Item.

copy_within(L, Args) ->
    Length = length(L),
    Target = bouy_rt:relative_index(bouy_rt:arg(1, Args), Length, 0),
    From = bouy_rt:relative_index(bouy_rt:arg(2, Args), Length, 0),
    To = bouy_rt:relative_index(bouy_rt:arg(3, Args), Length, Length),
    Count = max(0, min(To - From, Length - Target)),
    Segment = lists:sublist(L, From + 1, Count),
    lists:sublist(L, Target) ++ Segment ++ lists:nthtail(Target + Count, L).

%%% Sorting

%% Both sorts are stable. undefined sorts last without a comparator call,
%% and a comparator sees the calls that V8 makes (bouy_sort).
sort(L, Compare) ->
    {Undefined, Defined} = lists:partition(fun(Item) -> Item =:= undefined end, L),
    sorted(Defined, Compare) ++ Undefined.

sorted(Items, undefined) ->
    [Item || {_, Item} <- lists:keysort(1, [{bouy_rt:to_string(Item), Item} || Item <- Items])];
sorted(Items, Compare) ->
    bouy_sort:sort(Items, Compare).
