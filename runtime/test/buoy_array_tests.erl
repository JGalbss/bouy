-module(buoy_array_tests).

-include_lib("eunit/include/eunit.hrl").

thrown(F) ->
    try F() of
        Value -> {returned, Value}
    catch
        error:{'$throw', #{<<"name">> := Name, <<"message">> := Message}} -> <<Name/binary, ": ", Message/binary>>
    end.

a(Method, List, Args) -> buoy_array:call(Method, List, Args).

callbacks_test_() ->
    Double = fun([X | _]) -> X * 2 end,
    Indexed = fun([X, I, Whole]) -> [X, I, length(Whole)] end,
    Even = fun([X | _]) -> X rem 2 =:= 0 end,
    Sum = fun([Acc, X | _]) -> Acc + X end,
    Trace = fun([Acc, X, I, _]) -> [{X, I} | Acc] end,
    [
        ?_assertEqual([2, 4, 6], a(<<"map">>, [1, 2, 3], [Double])),
        ?_assertEqual([[a, 0, 2], [b, 1, 2]], a(<<"map">>, [a, b], [Indexed])),
        ?_assertEqual([2, 4], a(<<"filter">>, [1, 2, 3, 4], [Even])),
        ?_assertEqual(10, a(<<"reduce">>, [1, 2, 3, 4], [Sum])),
        ?_assertEqual(15, a(<<"reduce">>, [1, 2, 3, 4], [Sum, 5])),
        ?_assertEqual([{c, 2}, {b, 1}, {a, 0}], a(<<"reduce">>, [a, b, c], [Trace, []])),
        ?_assertEqual([{a, 0}, {b, 1}, {c, 2}], a(<<"reduceRight">>, [a, b, c], [Trace, []])),
        ?_assertEqual(<<"TypeError: Reduce of empty array with no initial value">>, thrown(fun() -> a(<<"reduce">>, [], [Sum]) end)),
        ?_assertEqual(2, a(<<"find">>, [1, 2, 3, 4], [Even])),
        ?_assertEqual(1, a(<<"findIndex">>, [1, 2, 3, 4], [Even])),
        ?_assertEqual(4, a(<<"findLast">>, [1, 2, 3, 4], [Even])),
        ?_assertEqual(3, a(<<"findLastIndex">>, [1, 2, 3, 4], [Even])),
        ?_assertEqual(undefined, a(<<"find">>, [1, 3], [Even])),
        ?_assertEqual(-1, a(<<"findIndex">>, [1, 3], [Even])),
        ?_assert(a(<<"some">>, [1, 2], [Even])),
        ?_assertNot(a(<<"every">>, [1, 2], [Even])),
        ?_assert(a(<<"every">>, [], [Even])),
        ?_assertEqual(undefined, a(<<"forEach">>, [1], [Double])),
        ?_assertEqual([1, 10, 2, 20], a(<<"flatMap">>, [1, 2], [fun([X | _]) -> [X, X * 10] end])),
        ?_assertEqual(<<"TypeError: undefined is not a function">>, thrown(fun() -> a(<<"map">>, [1], []) end))
    ].

search_test_() ->
    [
        ?_assertEqual(3, a(<<"at">>, [1, 2, 3], [-1])),
        ?_assertEqual(undefined, a(<<"at">>, [1, 2, 3], [5])),
        ?_assertNot(a(<<"includes">>, [1, 2, 3], ['NaN'])),
        ?_assert(a(<<"includes">>, ['NaN'], ['NaN'])),
        ?_assert(a(<<"includes">>, [1, 2.0], [2])),
        ?_assertNot(a(<<"includes">>, [1, 2, 3], [1, 1])),
        ?_assertEqual(-1, a(<<"indexOf">>, ['NaN'], ['NaN'])),
        ?_assertEqual(1, a(<<"indexOf">>, [<<"a">>, <<"b">>], [<<"b">>])),
        ?_assertEqual(3, a(<<"indexOf">>, [1, 2, 1, 2], [2, 2])),
        ?_assertEqual(2, a(<<"lastIndexOf">>, [1, 2, 3], [3])),
        ?_assertEqual(0, a(<<"lastIndexOf">>, [1, 2, 1], [1, 1])),
        ?_assertEqual(-1, a(<<"lastIndexOf">>, [1, 2, 3], [1, -5]))
    ].

build_test_() ->
    [
        ?_assertEqual([2, 3], a(<<"slice">>, [1, 2, 3], [-2])),
        ?_assertEqual([], a(<<"slice">>, [1, 2, 3], [2, 1])),
        ?_assertEqual([1, 2, [3]], a(<<"concat">>, [], [1, [2], [[3]]])),
        ?_assertEqual([1, 2, [3, [4]]], a(<<"flat">>, [1, [2, [3, [4]]]], [])),
        ?_assertEqual([1, 2, 3, 4], a(<<"flat">>, [1, [2, [3, [4]]]], ['Infinity'])),
        ?_assertEqual(<<"1,2,3">>, a(<<"join">>, [1, 2, 3], [])),
        ?_assertEqual(<<"--1">>, a(<<"join">>, [null, undefined, 1], [<<"-">>])),
        ?_assertEqual(<<"1,2,3">>, a(<<"toString">>, [1, [2, 3]], [])),
        ?_assertEqual({'$iterator', <<"Array Iterator">>, [[0, 7], [1, 8]]}, a(<<"entries">>, [7, 8], [])),
        ?_assertEqual({'$iterator', <<"Array Iterator">>, [0, 1]}, a(<<"keys">>, [7, 8], [])),
        ?_assertEqual({'$iterator', <<"Array Iterator">>, [7, 8]}, a(<<"values">>, [7, 8], [])),
        ?_assertEqual([2, 1], a(<<"toReversed">>, [1, 2], [])),
        ?_assertEqual([1, 2, 3], a(<<"toSorted">>, [3, 1, 2], [])),
        ?_assertEqual(3, a(<<"push">>, [1, 2], [3])),
        ?_assertEqual(2, buoy_array:get([a, b], <<"length">>)),
        ?_assertEqual(b, buoy_array:get([a, b], <<"1">>))
    ].

sort_test_() ->
    ByKey = fun([#{<<"k">> := A}, #{<<"k">> := B}]) -> A - B end,
    Items = [#{<<"k">> => K, <<"id">> => Id} || {K, Id} <- [{2, a}, {1, b}, {2, c}, {1, d}, {0, e}, {2, f}]],
    Ids = fun(List) -> [maps:get(<<"id">>, Item) || Item <- List] end,
    [
        %% node -e 'console.log([10, 9, 1, undefined, 2].sort())'
        ?_assertEqual([1, 10, 2, 9, undefined], element(1, buoy_array:mutate(<<"sort">>, [10, 9, 1, undefined, 2], []))),
        ?_assertEqual([<<"B">>, <<"a">>, <<"b">>, undefined], a(<<"toSorted">>, [<<"b">>, undefined, <<"a">>, <<"B">>], [])),
        ?_assertEqual([3, 2, 1], a(<<"toSorted">>, [3, 1, 2], [fun([A, B]) -> B - A end])),
        ?_assertEqual([[1, 5], [10], [2]], a(<<"toSorted">>, [[2], [1, 5], [10]], [])),
        ?_assertEqual([e, b, d, a, c, f], Ids(a(<<"toSorted">>, Items, [ByKey]))),
        %% node -e 'console.log([3, 1, 2].sort((a, b) => a > b))': V8's call order
        ?_assertEqual([3, 1, 2], a(<<"toSorted">>, [3, 1, 2], [fun([A, B]) -> A > B end])),
        ?_assertEqual([3, 1, 2], a(<<"toSorted">>, [3, 1, 2], [fun(_) -> 'NaN' end]))
    ].

mutators_test_() ->
    [
        ?_assertEqual({3, [1, 2, 3]}, buoy_array:mutate(<<"push">>, [1], [2, 3])),
        ?_assertEqual({3, [1, 2]}, buoy_array:mutate(<<"pop">>, [1, 2, 3], [])),
        ?_assertEqual({undefined, []}, buoy_array:mutate(<<"pop">>, [], [])),
        ?_assertEqual({1, [2, 3]}, buoy_array:mutate(<<"shift">>, [1, 2, 3], [])),
        ?_assertEqual({undefined, []}, buoy_array:mutate(<<"shift">>, [], [])),
        ?_assertEqual({4, [0, 1, 2, 3]}, buoy_array:mutate(<<"unshift">>, [2, 3], [0, 1])),
        ?_assertEqual({[2, 3], [1, x, y, z, 4, 5]}, buoy_array:mutate(<<"splice">>, [1, 2, 3, 4, 5], [1, 2, x, y, z])),
        ?_assertEqual({[3], [1, 2]}, buoy_array:mutate(<<"splice">>, [1, 2, 3], [-1])),
        ?_assertEqual({[], [1, 2, 3]}, buoy_array:mutate(<<"splice">>, [1, 2, 3], [])),
        ?_assertEqual({[], [1, x, 2]}, buoy_array:mutate(<<"splice">>, [1, 2], [1, 0, x])),
        ?_assertEqual({[3, 2, 1], [3, 2, 1]}, buoy_array:mutate(<<"reverse">>, [1, 2, 3], [])),
        ?_assertEqual({[1, 0, 0], [1, 0, 0]}, buoy_array:mutate(<<"fill">>, [1, 2, 3], [0, 1])),
        ?_assertEqual({[1, 0, 3], [1, 0, 3]}, buoy_array:mutate(<<"fill">>, [1, 2, 3], [0, 1, -1])),
        ?_assertEqual({[4, 5, 3, 4, 5], [4, 5, 3, 4, 5]}, buoy_array:mutate(<<"copyWithin">>, [1, 2, 3, 4, 5], [0, 3])),
        ?_assertEqual({<<"1,2">>, [1, 2]}, buoy_array:mutate(<<"join">>, [1, 2], []))
    ].

namespace_test_() ->
    [
        ?_assert(buoy_array:'isArray'([[]])),
        ?_assertNot(buoy_array:'isArray'([#{}])),
        ?_assertEqual([<<"h">>, <<"é"/utf8>>, <<"l">>], buoy_array:from([<<"hél"/utf8>>])),
        ?_assertEqual([0, 2, 4], buoy_array:from([#{<<"length">> => 3}, fun([_, I]) -> I * 2 end])),
        ?_assertEqual([a, undefined], buoy_array:from([#{<<"length">> => 2, <<"0">> => a}])),
        ?_assertEqual([1, 2], buoy_array:from([buoy_set:new([[1, 1, 2]])])),
        ?_assertEqual([[1, 2]], buoy_array:from([buoy_map:new([[[1, 2]]])])),
        ?_assertEqual([], buoy_array:from([#{}])),
        ?_assertEqual([7], buoy_array:'of'([7])),
        ?_assertEqual([undefined, undefined, undefined], buoy_array:new([3])),
        ?_assertEqual([1, 2], buoy_array:'$call'([1, 2])),
        ?_assertEqual([<<"3">>], buoy_array:new([<<"3">>])),
        ?_assertEqual(<<"RangeError: Invalid array length">>, thrown(fun() -> buoy_array:new([-1]) end)),
        ?_assertEqual(<<"RangeError: Invalid array length">>, thrown(fun() -> buoy_array:new([1.5]) end)),
        ?_assertEqual(true, buoy_rt:call(buoy_array:'$member'(<<"isArray">>), [[]])),
        ?_assertEqual({'$prototype', {'$namespace', buoy_array}}, buoy_array:'$member'(<<"prototype">>)),
        ?_assertEqual(<<"Array">>, buoy_array:'$member'(<<"name">>)),
        %% node -e 'console.log(Array.from(123), Array.from(true))'
        ?_assertEqual([], buoy_array:from([123])),
        ?_assertEqual([], buoy_array:from([true]))
    ].
