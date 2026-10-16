%% `Set`. A Set is `{'$set', {Index, Next}}`: Index maps each member to its
%% sequence number, and Next is the next sequence number. Iteration sorts by
%% sequence, so members keep insertion order (contract section 3).
-module(bouy_set).

-export(['$member'/1, new/1, call/3, get/2, mutate/3]).
-export([items/1]).

-type set_value() :: {'$set', {#{term() => non_neg_integer()}, non_neg_integer()}}.
-export_type([set_value/0]).

-spec '$member'(binary()) -> undefined.
'$member'(_Name) -> undefined.

%% `new Set(iterable)`.
-spec new(list()) -> set_value().
new(Args) ->
    case bouy_rt:arg(1, Args) of
        Empty when Empty =:= undefined; Empty =:= null -> empty();
        Iterable -> lists:foldl(fun(Item, Set) -> add(Set, Item) end, empty(), bouy_rt:to_list(Iterable))
    end.

empty() -> {'$set', {#{}, 0}}.

-spec get(set_value(), term()) -> term().
get({'$set', {Index, _}}, <<"size">>) -> map_size(Index);
get(_Set, _Key) -> undefined.

%% The members in insertion order.
-spec items(set_value()) -> list().
items({'$set', {Index, _}}) ->
    [Item || {_, Item} <- lists:sort([{Sequence, Item} || Item := Sequence <- Index])].

-spec call(binary(), set_value(), list()) -> term().
call(<<"has">>, {'$set', {Index, _}}, Args) ->
    maps:is_key(bouy_rt:collection_key(bouy_rt:arg(1, Args)), Index);
call(<<"forEach">>, Set, Args) ->
    F = bouy_rt:arg(1, Args),
    lists:foreach(fun(Item) -> bouy_rt:call(F, [Item, Item, Set]) end, items(Set)),
    undefined;
call(Name, Set, _Args) when Name =:= <<"values">>; Name =:= <<"keys">> ->
    items(Set);
call(<<"entries">>, Set, _Args) ->
    [[Item, Item] || Item <- items(Set)];
call(<<"add">>, Set, Args) ->
    element(2, mutate(<<"add">>, Set, Args));
call(Name, Set, Args) when Name =:= <<"delete">>; Name =:= <<"clear">> ->
    element(1, mutate(Name, Set, Args));
call(Name, Set, _Args) ->
    bouy_rt:no_method(Set, Name).

-spec mutate(binary(), set_value(), list()) -> {term(), set_value()}.
mutate(<<"add">>, Set, Args) ->
    New = add(Set, bouy_rt:arg(1, Args)),
    {New, New};
mutate(<<"delete">>, {'$set', {Index, Next}}, Args) ->
    Key = bouy_rt:collection_key(bouy_rt:arg(1, Args)),
    {maps:is_key(Key, Index), {'$set', {maps:remove(Key, Index), Next}}};
mutate(<<"clear">>, _Set, _Args) ->
    {undefined, empty()};
mutate(Name, Set, Args) ->
    {call(Name, Set, Args), Set}.

add({'$set', {Index, Next}} = Set, Item) ->
    Key = bouy_rt:collection_key(Item),
    case maps:is_key(Key, Index) of
        true -> Set;
        false -> {'$set', {Index#{Key => Next}, Next + 1}}
    end.
