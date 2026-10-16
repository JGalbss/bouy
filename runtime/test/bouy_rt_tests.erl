-module(bouy_rt_tests).

-include_lib("eunit/include/eunit.hrl").

%% The message of the JavaScript error that F throws.
thrown(F) ->
    try F() of
        Value -> {returned, Value}
    catch
        error:{'$throw', #{<<"name">> := Name, <<"message">> := Message}} -> <<Name/binary, ": ", Message/binary>>
    end.

arguments_test_() ->
    [
        ?_assertEqual(a, bouy_rt:arg(1, [a, b])),
        ?_assertEqual(b, bouy_rt:arg(2, [a, b])),
        ?_assertEqual(undefined, bouy_rt:arg(3, [a, b])),
        ?_assertEqual([b, c], bouy_rt:rest(2, [a, b, c])),
        ?_assertEqual([], bouy_rt:rest(4, [a, b]))
    ].

call_test_() ->
    [
        ?_assertEqual(3, bouy_rt:call(fun([A, B]) -> A + B end, [1, 2])),
        ?_assertEqual(<<"12">>, bouy_rt:call({'$namespace', bouy_string}, [12])),
        ?_assertEqual(<<"TypeError: undefined is not a function">>, thrown(fun() -> bouy_rt:call(undefined, []) end)),
        ?_assertEqual(<<"TypeError: 5 is not a function">>, thrown(fun() -> bouy_rt:call(5, []) end)),
        ?_assertEqual(<<"TypeError: \"abc\" is not a function">>, thrown(fun() -> bouy_rt:call(<<"abc">>, []) end)),
        ?_assertEqual(<<"TypeError: Object [Math] {} is not a function">>, thrown(fun() -> bouy_rt:call({'$namespace', bouy_math}, []) end))
    ].

call_method_test_() ->
    Object = #{<<"twice">> => fun([X]) -> X * 2 end, <<"n">> => 1},
    Add = fun([A, B]) -> A + B end,
    [
        ?_assertEqual(<<"1-2">>, bouy_rt:call_method([1, 2], <<"join">>, [<<"-">>])),
        ?_assertEqual(<<"ABC">>, bouy_rt:call_method(<<"abc">>, <<"toUpperCase">>, [])),
        ?_assertEqual(<<"3.14">>, bouy_rt:call_method(3.14159, <<"toFixed">>, [2])),
        ?_assertEqual(<<"NaN">>, bouy_rt:call_method('NaN', <<"toString">>, [])),
        ?_assertEqual(true, bouy_rt:call_method(bouy_map:new([[[1, 2]]]), <<"has">>, [1])),
        ?_assertEqual(false, bouy_rt:call_method(bouy_set:new([[1]]), <<"has">>, [2])),
        ?_assertEqual(<<"Error: x">>, bouy_rt:call_method(bouy_error:new(<<"Error">>, <<"x">>), <<"toString">>, [])),
        ?_assertEqual(10, bouy_rt:call_method(Object, <<"twice">>, [5])),
        ?_assertEqual(true, bouy_rt:call_method(Object, <<"hasOwnProperty">>, [<<"n">>])),
        ?_assertEqual(false, bouy_rt:call_method(Object, <<"hasOwnProperty">>, [<<"m">>])),
        ?_assertEqual(3, bouy_rt:call_method(Add, <<"call">>, [null, 1, 2])),
        ?_assertEqual(3, bouy_rt:call_method(Add, <<"apply">>, [null, [1, 2]])),
        ?_assertEqual(3, bouy_rt:call((bouy_rt:call_method(Add, <<"bind">>, [null, 1])), [2])),
        ?_assertEqual(3, bouy_rt:call_method({'$namespace', bouy_math}, <<"floor">>, [3.7])),
        ?_assertEqual(<<"true">>, bouy_rt:call_method(true, <<"toString">>, [])),
        ?_assertEqual(<<"TypeError: Cannot read properties of null (reading 'foo')">>, thrown(fun() -> bouy_rt:call_method(null, <<"foo">>, []) end)),
        ?_assertEqual(<<"TypeError: {}.foo is not a function">>, thrown(fun() -> bouy_rt:call_method(#{}, <<"foo">>, []) end)),
        ?_assertEqual(<<"TypeError: [ 1 ].nope is not a function">>, thrown(fun() -> bouy_rt:call_method([1], <<"nope">>, []) end))
    ].

mutate_test_() ->
    Map = bouy_map:new([]),
    Object = #{<<"add">> => fun([X]) -> X + 1 end},
    [
        ?_assertEqual({3, [1, 2, 3]}, bouy_rt:mutate([1, 2], <<"push">>, [3])),
        ?_assertEqual({2, [1]}, bouy_rt:mutate([1, 2], <<"pop">>, [])),
        ?_assertEqual(1, bouy_rt:get(element(2, bouy_rt:mutate(Map, <<"set">>, [a, 1])), <<"size">>)),
        ?_assertEqual({2, Object}, bouy_rt:mutate(Object, <<"add">>, [1])),
        ?_assertEqual({<<"a,b">>, [<<"a">>, <<"b">>]}, bouy_rt:mutate([<<"a">>, <<"b">>], <<"join">>, []))
    ].

add_test_() ->
    [
        ?_assertEqual(3, bouy_rt:add(1, 2)),
        ?_assertEqual(0.30000000000000004, bouy_rt:add(0.1, 0.2)),
        ?_assertEqual(<<"ab">>, bouy_rt:add(<<"a">>, <<"b">>)),
        ?_assertEqual(<<"12">>, bouy_rt:add(1, <<"2">>)),
        ?_assertEqual(<<"anull">>, bouy_rt:add(<<"a">>, null)),
        ?_assertEqual(<<"x1.5">>, bouy_rt:add(<<"x">>, 1.5)),
        ?_assertEqual(1, bouy_rt:add(1, null)),
        ?_assertEqual('NaN', bouy_rt:add(1, undefined)),
        ?_assertEqual(2, bouy_rt:add(true, 1)),
        ?_assertEqual(0, bouy_rt:add(null, null)),
        %% node -e 'console.log([1,2] + 3, {} + "x", [] + [])'
        ?_assertEqual(<<"1,23">>, bouy_rt:add([1, 2], 3)),
        ?_assertEqual(<<"[object Object]x">>, bouy_rt:add(#{}, <<"x">>)),
        ?_assertEqual(<<>>, bouy_rt:add([], [])),
        ?_assertEqual('Infinity', bouy_rt:add(1.0e308, 1.0e308)),
        ?_assertEqual('-Infinity', bouy_rt:add(-1.0e308, -1.0e308)),
        ?_assertEqual('NaN', bouy_rt:add('Infinity', '-Infinity')),
        ?_assertEqual('Infinity', bouy_rt:add('Infinity', 5)),
        ?_assertEqual(9007199254740993, bouy_rt:add(9007199254740992, 1))
    ].

arithmetic_test_() ->
    [
        ?_assertEqual(-1, bouy_rt:sub(1, 2)),
        ?_assertEqual(5, bouy_rt:sub(<<"7">>, 2)),
        ?_assertEqual('NaN', bouy_rt:sub('Infinity', 'Infinity')),
        ?_assertEqual(6, bouy_rt:mul(2, 3)),
        ?_assertEqual('Infinity', bouy_rt:mul(1.0e308, 10)),
        ?_assertEqual('-Infinity', bouy_rt:mul(-1.0e308, 10)),
        ?_assertEqual('NaN', bouy_rt:mul('Infinity', 0)),
        ?_assertEqual('-Infinity', bouy_rt:mul('Infinity', -2)),
        ?_assertEqual(-0.0, bouy_rt:mul(0.0, -1)),
        ?_assertEqual(2, bouy_rt:divide(6, 3)),
        ?_assert(is_integer(bouy_rt:divide(6, 3))),
        ?_assertEqual(3.5, bouy_rt:divide(7, 2)),
        ?_assertEqual(-3.5, bouy_rt:divide(-7, 2)),
        ?_assertEqual('Infinity', bouy_rt:divide(1, 0)),
        ?_assertEqual('-Infinity', bouy_rt:divide(-1, 0)),
        ?_assertEqual('NaN', bouy_rt:divide(0, 0)),
        ?_assertEqual('-Infinity', bouy_rt:divide(1, -0.0)),
        ?_assertEqual(-0.0, bouy_rt:divide(-1, 'Infinity')),
        ?_assertEqual('NaN', bouy_rt:divide('Infinity', 'Infinity')),
        ?_assertEqual('Infinity', bouy_rt:divide(1.0e308, 1.0e-10)),
        ?_assertEqual(2, bouy_rt:remainder(5, 3)),
        ?_assertEqual(-2, bouy_rt:remainder(-5, 3)),
        ?_assertEqual(2, bouy_rt:remainder(5, -3)),
        ?_assertEqual(1.5, bouy_rt:remainder(5.5, 2)),
        ?_assertEqual(-1.5, bouy_rt:remainder(-5.5, 2)),
        ?_assertEqual('NaN', bouy_rt:remainder(5, 0)),
        ?_assertEqual('NaN', bouy_rt:remainder('Infinity', 2)),
        ?_assertEqual(2, bouy_rt:remainder(2, 'Infinity')),
        ?_assertEqual(-0.0, bouy_rt:remainder(-0.0, 5))
    ].

power_test_() ->
    [
        ?_assertEqual(1024, bouy_rt:power(2, 10)),
        ?_assertEqual(0.5, bouy_rt:power(2, -1)),
        ?_assertEqual(9007199254740993, bouy_rt:add(bouy_rt:power(2, 53), 1)),
        ?_assertEqual('NaN', bouy_rt:power(-8, 1 / 3)),
        ?_assertEqual('Infinity', bouy_rt:power(0, -1)),
        ?_assertEqual('-Infinity', bouy_rt:power(-0.0, -1)),
        ?_assertEqual('NaN', bouy_rt:power(1, 'Infinity')),
        ?_assertEqual(1, bouy_rt:power('NaN', 0)),
        ?_assertEqual(1.4142135623730951, bouy_rt:power(2, 0.5)),
        ?_assertEqual(-8, bouy_rt:power(-2, 3)),
        ?_assertEqual('Infinity', bouy_rt:power(10.0, 400)),
        ?_assertEqual('-Infinity', bouy_rt:power(-10.0, 401)),
        ?_assertEqual(0, bouy_rt:power(0.5, 'Infinity')),
        ?_assertEqual(0, bouy_rt:power(2, '-Infinity')),
        ?_assertEqual(0.0, bouy_rt:power('Infinity', -1)),
        ?_assertEqual('-Infinity', bouy_rt:power('-Infinity', 3)),
        ?_assertEqual('Infinity', bouy_rt:power('-Infinity', 2))
    ].

negate_test_() ->
    [
        ?_assertEqual(-5, bouy_rt:negate(5)),
        ?_assertEqual(0, bouy_rt:negate(0)),
        ?_assertEqual(-0.0, bouy_rt:negate(0.0)),
        ?_assertEqual('-Infinity', bouy_rt:negate('Infinity')),
        ?_assertEqual('NaN', bouy_rt:negate('NaN')),
        ?_assertEqual(-12, bouy_rt:negate(<<"12">>))
    ].

to_number_test_() ->
    Cases = [
        {<<>>, 0}, {<<"  12  ">>, 12}, {<<"0x10">>, 16}, {<<"0b101">>, 5}, {<<"0o17">>, 15}, {<<"-0x10">>, 'NaN'},
        {<<"1e3">>, 1000.0}, {<<".5">>, 0.5}, {<<"5.">>, 5}, {<<"1_000">>, 'NaN'}, {<<"Infinity">>, 'Infinity'},
        {<<"-Infinity">>, '-Infinity'}, {<<"infinity">>, 'NaN'}, {<<"12px">>, 'NaN'}, {<<"\n\t 7 \n">>, 7},
        {<<"1e1000">>, 'Infinity'}, {null, 0}, {undefined, 'NaN'}, {true, 1}, {false, 0}, {[], 0}, {[5], 5},
        {[1, 2], 'NaN'}, {#{}, 'NaN'}, {{'$date', 5}, 5}, {<<"12345678901234567890">>, 1.2345678901234567e19}
    ],
    [?_assertEqual(Expected, bouy_rt:to_number(Input)) || {Input, Expected} <- Cases].

bitwise_test_() ->
    [
        ?_assertEqual(1, bouy_rt:bit_and(5, 3)),
        ?_assertEqual(7, bouy_rt:bit_or(5, 3)),
        ?_assertEqual(6, bouy_rt:bit_xor(5, 3)),
        ?_assertEqual(-6, bouy_rt:bit_not(5)),
        ?_assertEqual(-2147483648, bouy_rt:shift_left(1, 31)),
        ?_assertEqual(1, bouy_rt:shift_left(1, 32)),
        ?_assertEqual(-1, bouy_rt:shift_right(-1, 28)),
        ?_assertEqual(15, bouy_rt:shift_right_unsigned(-1, 28)),
        ?_assertEqual(4294967295, bouy_rt:shift_right_unsigned(-1, 0)),
        ?_assertEqual(5, bouy_rt:bit_or(4294967296 + 5, 0)),
        ?_assertEqual(1, bouy_rt:bit_or(1.9, 0)),
        ?_assertEqual(-1, bouy_rt:bit_or(-1.9, 0)),
        ?_assertEqual(0, bouy_rt:bit_or('NaN', 0)),
        ?_assertEqual(0, bouy_rt:bit_or('Infinity', 0)),
        ?_assertEqual(12, bouy_rt:bit_or(<<"12">>, 0)),
        ?_assertEqual(0, bouy_rt:bit_or(4294967296.5, 0)),
        ?_assertEqual(2147483647, bouy_rt:bit_or(-2147483649, 0))
    ].

strict_eq_test_() ->
    [
        ?_assert(bouy_rt:strict_eq(1, 1.0)),
        ?_assert(bouy_rt:strict_eq(0, -0.0)),
        ?_assertNot(bouy_rt:strict_eq('NaN', 'NaN')),
        ?_assert(bouy_rt:strict_eq(<<"a">>, <<"a">>)),
        ?_assertNot(bouy_rt:strict_eq(null, undefined)),
        ?_assertNot(bouy_rt:strict_eq(1, <<"1">>)),
        ?_assert(bouy_rt:strict_eq([1, #{<<"a">> => 2}], [1.0, #{<<"a">> => 2.0}])),
        ?_assertNot(bouy_rt:strict_eq([1], [1, 2])),
        ?_assertNot(bouy_rt:strict_eq(#{<<"a">> => 1}, #{<<"b">> => 1})),
        ?_assert(bouy_rt:strict_eq(bouy_map:new([[[a, 1]]]), element(2, bouy_map:mutate(<<"delete">>, bouy_map:new([[[a, 1], [b, 2]]]), [b])))),
        ?_assert(bouy_rt:strict_eq(bouy_set:new([[1, 2]]), bouy_set:new([[1.0, 2.0]])))
    ].

loose_eq_test_() ->
    [
        ?_assert(bouy_rt:loose_eq(null, undefined)),
        ?_assertNot(bouy_rt:loose_eq(null, 0)),
        ?_assertNot(bouy_rt:loose_eq(undefined, 0)),
        ?_assert(bouy_rt:loose_eq(<<"1">>, 1)),
        ?_assert(bouy_rt:loose_eq(true, 1)),
        ?_assert(bouy_rt:loose_eq([1], 1)),
        ?_assert(bouy_rt:loose_eq([], false)),
        ?_assert(bouy_rt:loose_eq(<<>>, 0)),
        ?_assertNot(bouy_rt:loose_eq('NaN', 'NaN')),
        ?_assert(bouy_rt:loose_eq(#{}, <<"[object Object]">>))
    ].

compare_test_() ->
    [
        ?_assert(bouy_rt:lt(1, 2)),
        ?_assert(bouy_rt:lt(<<"10">>, <<"9">>)),
        ?_assertNot(bouy_rt:lt(10, <<"9">>)),
        ?_assert(bouy_rt:lt(null, 1)),
        ?_assertNot(bouy_rt:lt(undefined, 1)),
        ?_assertNot(bouy_rt:lt('NaN', 1)),
        ?_assertNot(bouy_rt:ge('NaN', 1)),
        ?_assert(bouy_rt:gt([2], 1)),
        ?_assert(bouy_rt:lt(<<"B">>, <<"a">>)),
        ?_assert(bouy_rt:ge(null, 0)),
        ?_assert(bouy_rt:le(1, 1.0)),
        ?_assert(bouy_rt:lt(<<"z">>, <<"é"/utf8>>)),
        ?_assert(bouy_rt:lt('-Infinity', -1.0e308)),
        ?_assert(bouy_rt:gt('Infinity', 1 bsl 2000)),
        ?_assert(bouy_rt:le('Infinity', 'Infinity')),
        ?_assertNot(bouy_rt:gt(<<"abc">>, <<"abd">>))
    ].

truthy_test_() ->
    Falsy = [false, null, undefined, 0, 0.0, -0.0, 'NaN', <<>>],
    Truthy = [true, 1, -1, 0.5, <<"0">>, <<"false">>, [], #{}, 'Infinity', fun(_) -> 1 end, bouy_map:new([])],
    [?_assertNot(bouy_rt:truthy(V)) || V <- Falsy] ++ [?_assert(bouy_rt:truthy(V)) || V <- Truthy].

type_of_test_() ->
    Cases = [
        {undefined, <<"undefined">>}, {null, <<"object">>}, {true, <<"boolean">>}, {1, <<"number">>},
        {1.5, <<"number">>}, {'NaN', <<"number">>}, {<<"s">>, <<"string">>}, {fun(_) -> 1 end, <<"function">>},
        {[], <<"object">>}, {#{}, <<"object">>}, {bouy_map:new([]), <<"object">>},
        {{'$class', m, <<"C">>}, <<"function">>}, {{'$namespace', bouy_math}, <<"object">>},
        {{'$namespace', bouy_map}, <<"function">>}, {{'$namespace', bouy_json}, <<"object">>},
        {{'$namespace', bouy_ai_openai}, <<"function">>}
    ],
    [?_assertEqual(Expected, bouy_rt:type_of(V)) || {V, Expected} <- Cases].

instance_of_test_() ->
    TypeError = bouy_error:new(<<"TypeError">>, <<"x">>),
    NotFound = bouy_error:new([{'$class', 'bouy@app', <<"NotFound">>}, {'$class', bouy_error, <<"Error">>}], <<"x">>, #{<<"_tag">> => <<"NotFound">>}),
    [
        ?_assert(bouy_rt:instance_of(TypeError, {'$class', bouy_error, <<"Error">>})),
        ?_assert(bouy_rt:instance_of(TypeError, {'$class', bouy_error, <<"TypeError">>})),
        ?_assertNot(bouy_rt:instance_of(TypeError, {'$class', bouy_error, <<"RangeError">>})),
        ?_assert(bouy_rt:instance_of(NotFound, {'$class', 'bouy@app', <<"NotFound">>})),
        ?_assert(bouy_rt:instance_of(NotFound, {'$class', bouy_error, <<"Error">>})),
        ?_assertNot(bouy_rt:instance_of(#{}, {'$class', bouy_error, <<"Error">>})),
        ?_assert(bouy_rt:instance_of(bouy_map:new([]), {'$namespace', bouy_map})),
        ?_assertNot(bouy_rt:instance_of(bouy_map:new([]), {'$namespace', bouy_set})),
        ?_assert(bouy_rt:instance_of([], {'$namespace', bouy_array})),
        ?_assert(bouy_rt:instance_of([], {'$namespace', bouy_object})),
        ?_assertNot(bouy_rt:instance_of(<<"s">>, {'$namespace', bouy_object})),
        ?_assert(bouy_rt:instance_of({'$date', 0}, {'$namespace', bouy_date})),
        ?_assertEqual(<<"TypeError: Right-hand side of 'instanceof' is not an object">>, thrown(fun() -> bouy_rt:instance_of(1, 5) end))
    ].

has_test_() ->
    [
        ?_assert(bouy_rt:has(#{<<"a">> => undefined}, <<"a">>)),
        ?_assertNot(bouy_rt:has(#{}, <<"a">>)),
        ?_assert(bouy_rt:has(#{<<"1">> => x}, 1)),
        ?_assert(bouy_rt:has([a, b], 1)),
        ?_assert(bouy_rt:has([undefined], 0)),
        ?_assertNot(bouy_rt:has([a, b], 2)),
        ?_assert(bouy_rt:has([], <<"length">>)),
        ?_assertEqual(<<"TypeError: Cannot use 'in' operator to search for 'x' in 5">>, thrown(fun() -> bouy_rt:has(5, <<"x">>) end))
    ].

to_string_test_() ->
    Cases = [
        {<<"s">>, <<"s">>}, {42, <<"42">>}, {-1.5, <<"-1.5">>}, {1.0e21, <<"1e+21">>}, {-0.0, <<"0">>},
        {'NaN', <<"NaN">>}, {'-Infinity', <<"-Infinity">>}, {true, <<"true">>}, {null, <<"null">>},
        {undefined, <<"undefined">>}, {[1, [2, 3]], <<"1,2,3">>}, {[null, undefined, 1], <<",,1">>},
        {#{}, <<"[object Object]">>}, {bouy_map:new([]), <<"[object Map]">>}, {bouy_set:new([]), <<"[object Set]">>},
        {bouy_error:new(<<"TypeError">>, <<"bad">>), <<"TypeError: bad">>},
        {#{<<"toString">> => fun([]) -> <<"custom">> end}, <<"custom">>}
    ],
    [?_assertEqual(Expected, bouy_rt:to_string(V)) || {V, Expected} <- Cases] ++
        [?_assertEqual(<<"x 1 y true">>, bouy_rt:concat([<<"x ">>, 1, <<" y ">>, true]))].

get_test_() ->
    [
        ?_assertEqual(1, bouy_rt:get(#{<<"a">> => 1}, <<"a">>)),
        ?_assertEqual(undefined, bouy_rt:get(#{}, <<"a">>)),
        ?_assertEqual(x, bouy_rt:get(#{<<"1">> => x}, 1)),
        ?_assertEqual(b, bouy_rt:get([a, b], 1)),
        ?_assertEqual(b, bouy_rt:get([a, b], 1.0)),
        ?_assertEqual(a, bouy_rt:get([a, b], <<"0">>)),
        ?_assertEqual(undefined, bouy_rt:get([a, b], 2)),
        ?_assertEqual(undefined, bouy_rt:get([a, b], -1)),
        ?_assertEqual(2, bouy_rt:get([a, b], <<"length">>)),
        ?_assertEqual(3, bouy_rt:get(<<"héé"/utf8>>, <<"length">>)),
        ?_assertEqual(<<"é"/utf8>>, bouy_rt:get(<<"héé"/utf8>>, 1)),
        ?_assertEqual(2, bouy_rt:get(bouy_map:new([[[a, 1], [b, 2]]]), <<"size">>)),
        ?_assertEqual(3.141592653589793, bouy_rt:get({'$namespace', bouy_math}, <<"PI">>)),
        ?_assertEqual(<<"C">>, bouy_rt:get({'$class', m, <<"C">>}, <<"name">>)),
        ?_assertEqual(<<"x">>, bouy_rt:get(bouy_error:new(<<"Error">>, <<"x">>), <<"message">>)),
        ?_assertEqual(<<"TypeError: Cannot read properties of undefined (reading 'x')">>, thrown(fun() -> bouy_rt:get(undefined, <<"x">>) end)),
        ?_assertEqual(<<"TypeError: Cannot read properties of null (reading '0')">>, thrown(fun() -> bouy_rt:get(null, 0) end))
    ].

set_test_() ->
    [
        ?_assertEqual(#{<<"a">> => 2}, bouy_rt:set(#{<<"a">> => 1}, <<"a">>, 2)),
        ?_assertEqual(#{<<"1">> => x}, bouy_rt:set(#{}, 1, x)),
        ?_assertEqual([a, z], bouy_rt:set([a, b], 1, z)),
        ?_assertEqual([a, b, c], bouy_rt:set([a, b], 2, c)),
        ?_assertEqual([a, undefined, c], bouy_rt:set([a], 2, c)),
        ?_assertEqual([a], bouy_rt:set([a, b, c], <<"length">>, 1)),
        ?_assertEqual([a, undefined], bouy_rt:set([a], <<"length">>, 2)),
        ?_assertEqual(<<"TypeError: Cannot set properties of undefined (setting 'x')">>, thrown(fun() -> bouy_rt:set(undefined, <<"x">>, 1) end)),
        ?_assertEqual(<<"TypeError: Cannot assign to read only property '0' of string 'abc'">>, thrown(fun() -> bouy_rt:set(<<"abc">>, 0, 1) end)),
        ?_assertEqual(<<"TypeError: Cannot create property 'y' on number '5'">>, thrown(fun() -> bouy_rt:set(5, <<"y">>, 1) end)),
        ?_assertEqual(#{}, bouy_rt:delete(#{<<"a">> => 1}, <<"a">>)),
        ?_assertEqual([a, undefined], bouy_rt:delete([a, b], 1))
    ].

literal_test_() ->
    Error = bouy_error:new(<<"Error">>, <<"x">>, #{<<"code">> => 1}),
    [
        ?_assertEqual(#{<<"a">> => 1, <<"b">> => 3}, bouy_rt:object([{<<"a">>, 1}, {'$spread', #{<<"b">> => 2}}, {<<"b">>, 3}])),
        ?_assertEqual(#{<<"a">> => 9}, bouy_rt:object([{<<"a">>, 1}, {'$spread', #{<<"a">> => 9}}])),
        ?_assertEqual(#{<<"0">> => x, <<"1">> => y}, bouy_rt:object([{'$spread', [x, y]}])),
        ?_assertEqual(#{<<"0">> => <<"h">>, <<"1">> => <<"i">>}, bouy_rt:object([{'$spread', <<"hi">>}])),
        ?_assertEqual(#{}, bouy_rt:object([{'$spread', null}, {'$spread', undefined}, {'$spread', 5}])),
        ?_assertEqual(#{<<"code">> => 1}, bouy_rt:object([{'$spread', Error}])),
        ?_assertEqual(#{<<"2">> => two}, bouy_rt:object([{2, two}])),
        ?_assertEqual([0, 1, 2, 3], bouy_rt:array([{'$item', 0}, {'$spread', [1, 2]}, {'$item', 3}])),
        ?_assertEqual([<<"a">>, <<"b">>], bouy_rt:array([{'$spread', <<"ab">>}])),
        ?_assertEqual([[k, v]], bouy_rt:array([{'$spread', bouy_map:new([[[k, v]]])}])),
        ?_assertEqual(<<"TypeError: {} is not iterable">>, thrown(fun() -> bouy_rt:array([{'$spread', #{}}]) end)),
        ?_assertEqual(#{<<"b">> => 2}, bouy_rt:object_rest(#{<<"a">> => 1, <<"b">> => 2}, [<<"a">>])),
        ?_assertEqual([c], bouy_rt:array_rest([a, b, c], 2)),
        ?_assertEqual([], bouy_rt:array_rest([a], 5)),
        ?_assertEqual([<<"c">>], bouy_rt:array_rest(<<"abc">>, 2))
    ].

iteration_test_() ->
    [
        ?_assertEqual([<<"h">>, <<"é"/utf8>>, <<"😀"/utf8>>], bouy_rt:to_list(<<"hé😀"/utf8>>)),
        ?_assertEqual([[b, 2], [a, 1]], bouy_rt:to_list(bouy_map:new([[[b, 2], [a, 1]]]))),
        ?_assertEqual([3, 1], bouy_rt:to_list(bouy_set:new([[3, 1, 3]]))),
        ?_assertEqual(<<"TypeError: 5 is not iterable">>, thrown(fun() -> bouy_rt:to_list(5) end)),
        ?_assertEqual(<<"TypeError: undefined is not iterable">>, thrown(fun() -> bouy_rt:to_list(undefined) end)),
        ?_assertEqual([<<"a">>, <<"b">>], bouy_rt:keys(#{<<"b">> => 1, <<"a">> => 2})),
        ?_assertEqual([<<"0">>, <<"1">>], bouy_rt:keys([x, y])),
        ?_assertEqual([<<"code">>], bouy_rt:keys(bouy_error:new(<<"Error">>, <<"m">>, #{<<"code">> => 1}))),
        ?_assertEqual([], bouy_rt:keys(null))
    ].

caught_test_() ->
    Error = bouy_error:new(<<"Error">>, <<"x">>),
    {Reason, Stack} =
        try
            erlang:error(badarith)
        catch
            error:R:S -> {R, S}
        end,
    Caught = bouy_rt:caught(Reason, Stack),
    [
        ?_assertEqual(Error, bouy_rt:caught({'$throw', Error}, [])),
        ?_assertEqual(42, bouy_rt:caught({'$throw', 42}, [])),
        ?_assertEqual(<<"TypeError">>, bouy_rt:get(Caught, <<"name">>)),
        ?_assertEqual(<<"bad argument in an arithmetic expression">>, bouy_rt:get(Caught, <<"message">>)),
        ?_assertEqual(<<"badarith">>, bouy_rt:get(Caught, <<"erlang">>)),
        ?_assertMatch(<<"TypeError: bad argument in an arithmetic expression\n    at ", _/binary>>, bouy_rt:get(Caught, <<"stack">>)),
        ?_assertEqual(<<"no match of right hand side value 1">>, bouy_rt:get(bouy_rt:caught({badmatch, 1}, []), <<"message">>)),
        ?_assert(bouy_rt:instance_of(Caught, {'$class', bouy_error, <<"TypeError">>}))
    ].

environment_test_() ->
    os:putenv("BOUY_RT_TEST_VAR", "héllo"),
    [
        ?_assertEqual(<<"héllo"/utf8>>, bouy_rt:env(<<"BOUY_RT_TEST_VAR">>)),
        ?_assertEqual(undefined, bouy_rt:env(<<"BOUY_RT_TEST_MISSING">>)),
        ?_assertEqual([], bouy_rt:argv()),
        ?_assertEqual(#{<<"a">> => [1]}, bouy_rt:structured_clone(#{<<"a">> => [1]}))
    ].

conversion_test_() ->
    [
        ?_assertEqual(3, bouy_rt:to_integer(3.9)),
        ?_assertEqual(-3, bouy_rt:to_integer(-3.9)),
        ?_assertEqual(0, bouy_rt:to_integer('NaN')),
        ?_assertEqual('Infinity', bouy_rt:to_integer('Infinity')),
        ?_assertEqual(2, bouy_rt:relative_index(-1, 3, 0)),
        ?_assertEqual(0, bouy_rt:relative_index(-10, 3, 0)),
        ?_assertEqual(3, bouy_rt:relative_index('Infinity', 3, 0)),
        ?_assertEqual(1, bouy_rt:collection_key(1.0)),
        ?_assertEqual(0, bouy_rt:collection_key(-0.0)),
        ?_assertEqual(0.5, bouy_rt:collection_key(0.5)),
        ?_assert(bouy_rt:same_value_zero('NaN', 'NaN'))
    ].

%% `handlers[0](x)`: a key that is not a string names a property to call.
property_call_test_() ->
    Handlers = [fun([N]) -> N + 1 end, fun([N]) -> N * 2 end],
    [
        ?_assertEqual(11, bouy_rt:call_method(Handlers, 0, [10])),
        ?_assertEqual(20, bouy_rt:call_method(Handlers, 1.0, [10])),
        ?_assertEqual(42, bouy_rt:call_method([<<"double">>, fun([N]) -> N * 2 end], 1, [21])),
        ?_assertEqual(<<"one">>, bouy_rt:call_method(#{<<"1">> => fun([]) -> <<"one">> end}, 1, [])),
        ?_assertMatch(<<"TypeError: ", _/binary>>, thrown(fun() -> bouy_rt:call_method(Handlers, 5, []) end))
    ].

%% Built-in methods are properties: a read gives a function value that
%% `call`, `apply`, and `bind` run with a receiver.
member_test_() ->
    Map = bouy_rt:get([1, 2], <<"map">>),
    HasOwn = bouy_rt:get(bouy_object:'$member'(<<"prototype">>), <<"hasOwnProperty">>),
    [
        ?_assertEqual({'$method', bouy_array, <<"map">>}, Map),
        ?_assertEqual(<<"function">>, bouy_rt:type_of(Map)),
        ?_assertEqual(<<"map">>, bouy_rt:get(Map, <<"name">>)),
        ?_assertEqual([2, 3], bouy_rt:call_method(Map, <<"call">>, [[1, 2], fun([X | _]) -> X + 1 end])),
        ?_assertEqual(<<"TypeError: Array.prototype.map called on null or undefined">>, thrown(fun() -> bouy_rt:call(Map, []) end)),
        ?_assert(bouy_rt:call_method(HasOwn, <<"call">>, [#{<<"a">> => 1}, <<"a">>])),
        ?_assertEqual(<<"function">>, bouy_rt:type_of(bouy_rt:get(<<"s">>, <<"trim">>))),
        ?_assertEqual(<<"function">>, bouy_rt:type_of(bouy_rt:get(5, <<"toFixed">>))),
        ?_assertEqual(undefined, bouy_rt:get([1], <<"nope">>)),
        ?_assertEqual({'$namespace', bouy_object}, bouy_rt:get(#{}, <<"constructor">>)),
        ?_assertEqual({'$namespace', bouy_array}, bouy_rt:get([], <<"constructor">>)),
        ?_assertEqual(1, bouy_rt:get(#{<<"constructor">> => 1}, <<"constructor">>)),
        ?_assert(bouy_rt:has(#{}, <<"toString">>)),
        ?_assertNot(bouy_rt:has(#{}, <<"nope">>)),
        ?_assertEqual(<<"[object Array]">>, bouy_rt:call_method(bouy_rt:get(#{}, <<"toString">>), <<"call">>, [[]])),
        ?_assertEqual(undefined, bouy_rt:call_method({'$class', bouy_error, <<"Error">>}, <<"captureStackTrace">>, [#{}]))
    ].

%% ToPrimitive calls an own valueOf before toString, except for the string
%% hint of String() and template literals.
value_of_test_() ->
    Money = #{<<"valueOf">> => fun([]) -> 150 end},
    Both = #{<<"valueOf">> => fun([]) -> 7 end, <<"toString">> => fun([]) -> <<"seven">> end},
    [
        ?_assertEqual(151, bouy_rt:add(Money, 1)),
        ?_assertEqual(300, bouy_rt:mul(Money, 2)),
        ?_assert(bouy_rt:gt(Money, 100)),
        ?_assertEqual(<<"7">>, bouy_rt:add(Both, <<>>)),
        ?_assertEqual(<<"seven">>, bouy_rt:to_string(Both)),
        ?_assertEqual(<<"[object Object]">>, bouy_rt:to_string(Money)),
        ?_assertEqual(<<"TypeError: Cannot convert object to primitive value">>, thrown(fun() -> bouy_rt:to_string(#{<<"toString">> => fun([]) -> #{} end}) end))
    ].

%% Equal numbers share one Map key at any size.
collection_key_test_() ->
    [
        ?_assertEqual(100000000000000000000, bouy_rt:collection_key(1.0e20)),
        ?_assertEqual(1.0e21, bouy_rt:collection_key(1000000000000000000000)),
        ?_assertEqual(1.0e21, bouy_rt:collection_key(1.0e21)),
        ?_assertEqual(9007199254740993, bouy_rt:collection_key(9007199254740993)),
        ?_assertEqual(0, bouy_rt:collection_key(-0.0)),
        ?_assertEqual(1.5, bouy_rt:collection_key(1.5))
    ].

%% A message cuts a value after 40 characters, never inside one.
describe_test_() ->
    Long = #{<<"name">> => binary:copy(<<"é"/utf8>>, 60)},
    Text = bouy_rt:describe(Long),
    [
        ?_assertEqual(43, bouy_string:char_count(Text)),
        ?_assertMatch(<<_/binary>>, unicode:characters_to_binary(Text)),
        ?_assertEqual(<<"\"x\"">>, bouy_rt:describe(<<"x">>))
    ].
