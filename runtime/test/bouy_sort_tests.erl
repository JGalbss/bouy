-module(bouy_sort_tests).

-include_lib("eunit/include/eunit.hrl").

ids(Rows) -> [Id || #{<<"id">> := Id} <- Rows].

row(Id, K) -> #{<<"id">> => Id, <<"k">> => K}.

%% The orders that Node gives for comparators that are not consistent:
%% node -e 'console.log([{k:1,id:"a"},{k:1,id:"b"}].sort((x, y) => x.k < y.k ? -1 : 1))'
inconsistent_test_() ->
    NoZero = fun([#{<<"k">> := A}, #{<<"k">> := B}]) when A < B -> -1; (_) -> 1 end,
    Ages = [row(Id, Age) || {Id, Age} <- lists:enumerate(0, [30, 25, 30, 20, 25, 30, 20])],
    Older = fun([#{<<"k">> := A}, #{<<"k">> := B}]) when A > B -> 1; (_) -> -1 end,
    [
        ?_assertEqual([a, b], ids(bouy_sort:sort([row(a, 1), row(b, 1)], NoZero))),
        ?_assertEqual([2, 1], bouy_sort:sort([2, 1], fun([A, B]) -> A > B end)),
        ?_assertEqual([0, 1, 2, 3, 'NaN'], bouy_sort:sort([1, 2, 3, 'NaN', 0], fun([A, B]) -> bouy_rt:sub(A, B) end)),
        %% node -e 'console.log([30,25,30,20,25,30,20].map((age, id) => ({id, age})).sort((x, y) => x.age > y.age ? 1 : -1).map((p) => p.id).join(""))'
        ?_assertEqual([6, 3, 4, 1, 5, 2, 0], ids(bouy_sort:sort(Ages, Older)))
    ].

%% A consistent comparator gives the stable order on short and long arrays.
stable_test_() ->
    rand:seed(exsss, {7, 8, 9}),
    Cases = [[{rand:uniform(Range), I} || I <- lists:seq(1, N)] || N <- [0, 1, 2, 7, 8, 63, 64, 65, 300, 2000], Range <- [2, 1000]],
    ByKey = fun([{A, _}, {B, _}]) -> A - B end,
    [?_assertEqual(lists:keysort(1, Items), bouy_sort:sort(Items, ByKey)) || Items <- Cases].
