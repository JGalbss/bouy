%% Iterators: what `keys()`, `values()`, and `entries()` of Map, Set, and
%% Array return, and the iterator helpers. An iterator is
%% `{'$iterator', Kind, Items}`: Kind names it for `console.log`, and Items
%% are the items it has not yielded yet. `next` is a mutator (contract
%% section 6), so `it.next()` advances the iterator that `it` holds, and
%% `m.keys().next()` reads the first key.
-module(buoy_iterator).

-export([new/2, call/3, get/2, mutate/3]).

-define(METHODS, [
    <<"next">>, <<"toArray">>, <<"map">>, <<"filter">>, <<"take">>, <<"drop">>, <<"flatMap">>,
    <<"reduce">>, <<"forEach">>, <<"some">>, <<"every">>, <<"find">>
]).
-define(HELPER, <<"Iterator Helper">>).

-type iterator() :: {'$iterator', binary(), list()}.
-export_type([iterator/0]).

-spec new(binary(), list()) -> iterator().
new(Kind, Items) -> {'$iterator', Kind, Items}.

-spec get(iterator(), term()) -> term().
get(_Iterator, Key) -> buoy_rt:member(?MODULE, Key, ?METHODS).

-spec mutate(binary(), iterator(), list()) -> {term(), iterator()}.
mutate(<<"next">>, {'$iterator', Kind, [Item | Rest]}, _Args) ->
    {#{<<"value">> => Item, <<"done">> => false}, {'$iterator', Kind, Rest}};
mutate(<<"next">>, {'$iterator', _, []} = Iterator, _Args) ->
    {#{<<"value">> => undefined, <<"done">> => true}, Iterator};
mutate(Name, Iterator, Args) ->
    {call(Name, Iterator, Args), Iterator}.

%% The helpers consume the iterator: they run at once over the items that
%% are left, and the lazy ones return a new iterator.
-spec call(binary(), iterator(), list()) -> term().
call(<<"next">>, Iterator, Args) -> element(1, mutate(<<"next">>, Iterator, Args));
call(<<"toArray">>, {'$iterator', _, Items}, _Args) -> Items;
call(<<"map">>, Iterator, Args) -> new(?HELPER, [Result || {_, _, Result} <- results(Iterator, Args)]);
call(<<"filter">>, Iterator, Args) -> new(?HELPER, [Item || {_, Item, Result} <- results(Iterator, Args), buoy_rt:truthy(Result)]);
call(<<"flatMap">>, Iterator, Args) -> new(?HELPER, lists:append([buoy_rt:to_list(Result) || {_, _, Result} <- results(Iterator, Args)]));
call(<<"take">>, {'$iterator', _, Items}, Args) -> new(?HELPER, lists:sublist(Items, limit(Args, length(Items))));
call(<<"drop">>, {'$iterator', _, Items}, Args) -> new(?HELPER, lists:nthtail(limit(Args, length(Items)), Items));
call(<<"forEach">>, Iterator, Args) -> _ = results(Iterator, Args), undefined;
call(<<"some">>, Iterator, Args) -> search(Iterator, Args, true) =/= none;
call(<<"every">>, Iterator, Args) -> search(Iterator, Args, false) =:= none;
call(<<"find">>, Iterator, Args) ->
    case search(Iterator, Args, true) of
        {found, Item} -> Item;
        none -> undefined
    end;
call(<<"reduce">>, {'$iterator', _, Items}, Args) -> reduce(lists:enumerate(0, Items), Args);
call(Name, Iterator, Args) -> buoy_rt:prototype_call(Iterator, Name, Args).

%% Each item with its counter and the result of the callback for it.
results({'$iterator', _, Items}, Args) ->
    F = buoy_rt:arg(1, Args),
    [{Index, Item, buoy_rt:call(F, [Item, Index])} || {Index, Item} <- lists:enumerate(0, Items)].

%% The first item for which the callback is truthy (Want true) or falsy.
search({'$iterator', _, Items}, Args, Want) ->
    first(lists:enumerate(0, Items), buoy_rt:arg(1, Args), Want).

first([{Index, Item} | Rest], F, Want) ->
    case buoy_rt:truthy(buoy_rt:call(F, [Item, Index])) of
        Want -> {found, Item};
        _ -> first(Rest, F, Want)
    end;
first([], _F, _Want) ->
    none.

reduce(Indexed, [F]) ->
    case Indexed of
        [{_, First} | Rest] -> fold(F, First, Rest);
        [] -> buoy_error:throw(<<"TypeError">>, <<"Reduce of empty iterator with no initial value">>)
    end;
reduce(Indexed, [F, Initial | _]) ->
    fold(F, Initial, Indexed);
reduce(_Indexed, []) ->
    buoy_error:throw(<<"TypeError">>, <<"undefined is not a function">>).

fold(F, Acc, [{Index, Item} | Rest]) -> fold(F, buoy_rt:call(F, [Acc, Item, Index]), Rest);
fold(_F, Acc, []) -> Acc.

%% The count of `take` and `drop`: a number that is not negative.
limit(Args, Length) ->
    case buoy_rt:to_number(buoy_rt:arg(1, Args)) of
        'Infinity' -> Length;
        N when is_number(N), N >= 0 -> min(trunc(N), Length);
        N -> buoy_error:throw(<<"RangeError">>, <<(buoy_rt:to_string(N))/binary, " must be positive">>)
    end.
