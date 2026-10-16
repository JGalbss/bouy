-module(bouy_iterator_tests).

-include_lib("eunit/include/eunit.hrl").

%% `next` as a mutator advances the iterator that a variable holds; as a
%% call it reads the first item.
next_test_() ->
    Iterator = bouy_iterator:new(<<"Map Iterator">>, [a, b]),
    {First, Rest} = bouy_rt:mutate(Iterator, <<"next">>, []),
    {Second, Done} = bouy_rt:mutate(Rest, <<"next">>, []),
    [
        ?_assertEqual(#{<<"value">> => a, <<"done">> => false}, First),
        ?_assertEqual(#{<<"value">> => b, <<"done">> => false}, Second),
        ?_assertEqual(#{<<"value">> => undefined, <<"done">> => true}, element(1, bouy_rt:mutate(Done, <<"next">>, []))),
        ?_assertEqual(#{<<"value">> => a, <<"done">> => false}, bouy_rt:call_method(Iterator, <<"next">>, [])),
        ?_assertEqual([b], bouy_rt:to_list(Rest)),
        ?_assertNot(bouy_array:'isArray'([Iterator])),
        ?_assertEqual(undefined, bouy_rt:get(Iterator, <<"length">>))
    ].

helpers_test_() ->
    Iterator = bouy_iterator:new(<<"Set Iterator">>, [1, 2, 3]),
    Double = fun([X | _]) -> X * 2 end,
    [
        ?_assertEqual([2, 4, 6], bouy_rt:to_list(bouy_rt:call_method(Iterator, <<"map">>, [Double]))),
        ?_assertEqual([2, 3], bouy_rt:call_method(bouy_rt:call_method(Iterator, <<"filter">>, [fun([X | _]) -> X > 1 end]), <<"toArray">>, [])),
        ?_assertEqual(6, bouy_rt:call_method(Iterator, <<"reduce">>, [fun([A, B | _]) -> A + B end])),
        ?_assertEqual([1, 2], bouy_rt:to_list(bouy_rt:call_method(Iterator, <<"take">>, [2]))),
        ?_assertEqual([3], bouy_rt:to_list(bouy_rt:call_method(Iterator, <<"drop">>, [2]))),
        ?_assertEqual(2, bouy_rt:call_method(Iterator, <<"find">>, [fun([X | _]) -> X > 1 end])),
        ?_assert(bouy_rt:call_method(Iterator, <<"every">>, [fun([X | _]) -> X > 0 end])),
        ?_assertEqual(<<"Iterator Helper">>, element(2, bouy_rt:call_method(Iterator, <<"map">>, [Double])))
    ].
