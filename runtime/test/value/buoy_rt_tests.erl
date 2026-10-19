-module(buoy_rt_tests).

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
        ?_assertEqual(a, buoy_rt:arg(1, [a, b])),
        ?_assertEqual(b, buoy_rt:arg(2, [a, b])),
        ?_assertEqual(undefined, buoy_rt:arg(3, [a, b])),
        ?_assertEqual([b, c], buoy_rt:rest(2, [a, b, c])),
        ?_assertEqual([], buoy_rt:rest(4, [a, b]))
    ].

call_test_() ->
    [
        ?_assertEqual(3, buoy_rt:call(fun([A, B]) -> A + B end, [1, 2])),
        ?_assertEqual(<<"12">>, buoy_rt:call({'$namespace', buoy_string}, [12])),
        ?_assertEqual(<<"TypeError: undefined is not a function">>, thrown(fun() -> buoy_rt:call(undefined, []) end)),
        ?_assertEqual(<<"TypeError: 5 is not a function">>, thrown(fun() -> buoy_rt:call(5, []) end)),
        ?_assertEqual(<<"TypeError: \"abc\" is not a function">>, thrown(fun() -> buoy_rt:call(<<"abc">>, []) end)),
        ?_assertEqual(<<"TypeError: Object [Math] {} is not a function">>, thrown(fun() -> buoy_rt:call({'$namespace', buoy_math}, []) end))
    ].

call_method_test_() ->
    Object = #{<<"twice">> => fun([X]) -> X * 2 end, <<"n">> => 1},
    Add = fun([A, B]) -> A + B end,
    [
        ?_assertEqual(<<"1-2">>, buoy_rt:call_method([1, 2], <<"join">>, [<<"-">>])),
        ?_assertEqual(<<"ABC">>, buoy_rt:call_method(<<"abc">>, <<"toUpperCase">>, [])),
        ?_assertEqual(<<"3.14">>, buoy_rt:call_method(3.14159, <<"toFixed">>, [2])),
        ?_assertEqual(<<"NaN">>, buoy_rt:call_method('NaN', <<"toString">>, [])),
        ?_assertEqual(true, buoy_rt:call_method(buoy_map:new([[[1, 2]]]), <<"has">>, [1])),
        ?_assertEqual(false, buoy_rt:call_method(buoy_set:new([[1]]), <<"has">>, [2])),
        ?_assertEqual(<<"Error: x">>, buoy_rt:call_method(buoy_error:new(<<"Error">>, <<"x">>), <<"toString">>, [])),
        ?_assertEqual(10, buoy_rt:call_method(Object, <<"twice">>, [5])),
        ?_assertEqual(true, buoy_rt:call_method(Object, <<"hasOwnProperty">>, [<<"n">>])),
        ?_assertEqual(false, buoy_rt:call_method(Object, <<"hasOwnProperty">>, [<<"m">>])),
        ?_assertEqual(3, buoy_rt:call_method(Add, <<"call">>, [null, 1, 2])),
        ?_assertEqual(3, buoy_rt:call_method(Add, <<"apply">>, [null, [1, 2]])),
        ?_assertEqual(3, buoy_rt:call((buoy_rt:call_method(Add, <<"bind">>, [null, 1])), [2])),
        ?_assertEqual(3, buoy_rt:call_method({'$namespace', buoy_math}, <<"floor">>, [3.7])),
        ?_assertEqual(<<"true">>, buoy_rt:call_method(true, <<"toString">>, [])),
        ?_assertEqual(<<"TypeError: Cannot read properties of null (reading 'foo')">>, thrown(fun() -> buoy_rt:call_method(null, <<"foo">>, []) end)),
        ?_assertEqual(<<"TypeError: {}.foo is not a function">>, thrown(fun() -> buoy_rt:call_method(#{}, <<"foo">>, []) end)),
        ?_assertEqual(<<"TypeError: [ 1 ].nope is not a function">>, thrown(fun() -> buoy_rt:call_method([1], <<"nope">>, []) end))
    ].

mutate_test_() ->
    Map = buoy_map:new([]),
    Object = #{<<"add">> => fun([X]) -> X + 1 end},
    [
        ?_assertEqual({3, [1, 2, 3]}, buoy_rt:mutate([1, 2], <<"push">>, [3])),
        ?_assertEqual({2, [1]}, buoy_rt:mutate([1, 2], <<"pop">>, [])),
        ?_assertEqual(1, buoy_rt:get(element(2, buoy_rt:mutate(Map, <<"set">>, [a, 1])), <<"size">>)),
        ?_assertEqual({2, Object}, buoy_rt:mutate(Object, <<"add">>, [1])),
        ?_assertEqual({<<"a,b">>, [<<"a">>, <<"b">>]}, buoy_rt:mutate([<<"a">>, <<"b">>], <<"join">>, []))
    ].

add_test_() ->
    [
        ?_assertEqual(3, buoy_rt:add(1, 2)),
        ?_assertEqual(0.30000000000000004, buoy_rt:add(0.1, 0.2)),
        ?_assertEqual(<<"ab">>, buoy_rt:add(<<"a">>, <<"b">>)),
        ?_assertEqual(<<"12">>, buoy_rt:add(1, <<"2">>)),
        ?_assertEqual(<<"anull">>, buoy_rt:add(<<"a">>, null)),
        ?_assertEqual(<<"x1.5">>, buoy_rt:add(<<"x">>, 1.5)),
        ?_assertEqual(1, buoy_rt:add(1, null)),
        ?_assertEqual('NaN', buoy_rt:add(1, undefined)),
        ?_assertEqual(2, buoy_rt:add(true, 1)),
        ?_assertEqual(0, buoy_rt:add(null, null)),
        %% node -e 'console.log([1,2] + 3, {} + "x", [] + [])'
        ?_assertEqual(<<"1,23">>, buoy_rt:add([1, 2], 3)),
        ?_assertEqual(<<"[object Object]x">>, buoy_rt:add(#{}, <<"x">>)),
        ?_assertEqual(<<>>, buoy_rt:add([], [])),
        ?_assertEqual('Infinity', buoy_rt:add(1.0e308, 1.0e308)),
        ?_assertEqual('-Infinity', buoy_rt:add(-1.0e308, -1.0e308)),
        ?_assertEqual('NaN', buoy_rt:add('Infinity', '-Infinity')),
        ?_assertEqual('Infinity', buoy_rt:add('Infinity', 5)),
        ?_assertEqual(9007199254740993, buoy_rt:add(9007199254740992, 1))
    ].

arithmetic_test_() ->
    [
        ?_assertEqual(-1, buoy_rt:sub(1, 2)),
        ?_assertEqual(5, buoy_rt:sub(<<"7">>, 2)),
        ?_assertEqual('NaN', buoy_rt:sub('Infinity', 'Infinity')),
        ?_assertEqual(6, buoy_rt:mul(2, 3)),
        ?_assertEqual('Infinity', buoy_rt:mul(1.0e308, 10)),
        ?_assertEqual('-Infinity', buoy_rt:mul(-1.0e308, 10)),
        ?_assertEqual('NaN', buoy_rt:mul('Infinity', 0)),
        ?_assertEqual('-Infinity', buoy_rt:mul('Infinity', -2)),
        ?_assertEqual(-0.0, buoy_rt:mul(0.0, -1)),
        ?_assertEqual(2, buoy_rt:divide(6, 3)),
        ?_assert(is_integer(buoy_rt:divide(6, 3))),
        ?_assertEqual(3.5, buoy_rt:divide(7, 2)),
        ?_assertEqual(-3.5, buoy_rt:divide(-7, 2)),
        ?_assertEqual('Infinity', buoy_rt:divide(1, 0)),
        ?_assertEqual('-Infinity', buoy_rt:divide(-1, 0)),
        ?_assertEqual('NaN', buoy_rt:divide(0, 0)),
        ?_assertEqual('-Infinity', buoy_rt:divide(1, -0.0)),
        ?_assertEqual(-0.0, buoy_rt:divide(-1, 'Infinity')),
        ?_assertEqual('NaN', buoy_rt:divide('Infinity', 'Infinity')),
        ?_assertEqual('Infinity', buoy_rt:divide(1.0e308, 1.0e-10)),
        ?_assertEqual(2, buoy_rt:remainder(5, 3)),
        ?_assertEqual(-2, buoy_rt:remainder(-5, 3)),
        ?_assertEqual(2, buoy_rt:remainder(5, -3)),
        ?_assertEqual(1.5, buoy_rt:remainder(5.5, 2)),
        ?_assertEqual(-1.5, buoy_rt:remainder(-5.5, 2)),
        ?_assertEqual('NaN', buoy_rt:remainder(5, 0)),
        ?_assertEqual('NaN', buoy_rt:remainder('Infinity', 2)),
        ?_assertEqual(2, buoy_rt:remainder(2, 'Infinity')),
        ?_assertEqual(-0.0, buoy_rt:remainder(-0.0, 5))
    ].

power_test_() ->
    [
        ?_assertEqual(1024, buoy_rt:power(2, 10)),
        ?_assertEqual(0.5, buoy_rt:power(2, -1)),
        ?_assertEqual(9007199254740993, buoy_rt:add(buoy_rt:power(2, 53), 1)),
        ?_assertEqual('NaN', buoy_rt:power(-8, 1 / 3)),
        ?_assertEqual('Infinity', buoy_rt:power(0, -1)),
        ?_assertEqual('-Infinity', buoy_rt:power(-0.0, -1)),
        ?_assertEqual('NaN', buoy_rt:power(1, 'Infinity')),
        ?_assertEqual(1, buoy_rt:power('NaN', 0)),
        ?_assertEqual(1.4142135623730951, buoy_rt:power(2, 0.5)),
        ?_assertEqual(-8, buoy_rt:power(-2, 3)),
        ?_assertEqual('Infinity', buoy_rt:power(10.0, 400)),
        ?_assertEqual('-Infinity', buoy_rt:power(-10.0, 401)),
        ?_assertEqual(0, buoy_rt:power(0.5, 'Infinity')),
        ?_assertEqual(0, buoy_rt:power(2, '-Infinity')),
        ?_assertEqual(0.0, buoy_rt:power('Infinity', -1)),
        ?_assertEqual('-Infinity', buoy_rt:power('-Infinity', 3)),
        ?_assertEqual('Infinity', buoy_rt:power('-Infinity', 2))
    ].

negate_test_() ->
    [
        ?_assertEqual(-5, buoy_rt:negate(5)),
        ?_assertEqual(0, buoy_rt:negate(0)),
        ?_assertEqual(-0.0, buoy_rt:negate(0.0)),
        ?_assertEqual('-Infinity', buoy_rt:negate('Infinity')),
        ?_assertEqual('NaN', buoy_rt:negate('NaN')),
        ?_assertEqual(-12, buoy_rt:negate(<<"12">>))
    ].

to_number_test_() ->
    Cases = [
        {<<>>, 0}, {<<"  12  ">>, 12}, {<<"0x10">>, 16}, {<<"0b101">>, 5}, {<<"0o17">>, 15}, {<<"-0x10">>, 'NaN'},
        {<<"1e3">>, 1000.0}, {<<".5">>, 0.5}, {<<"5.">>, 5}, {<<"1_000">>, 'NaN'}, {<<"Infinity">>, 'Infinity'},
        {<<"-Infinity">>, '-Infinity'}, {<<"infinity">>, 'NaN'}, {<<"12px">>, 'NaN'}, {<<"\n\t 7 \n">>, 7},
        {<<"1e1000">>, 'Infinity'}, {null, 0}, {undefined, 'NaN'}, {true, 1}, {false, 0}, {[], 0}, {[5], 5},
        {[1, 2], 'NaN'}, {#{}, 'NaN'}, {{'$date', 5}, 5}, {<<"12345678901234567890">>, 1.2345678901234567e19}
    ],
    [?_assertEqual(Expected, buoy_rt:to_number(Input)) || {Input, Expected} <- Cases].

bitwise_test_() ->
    [
        ?_assertEqual(1, buoy_rt:bit_and(5, 3)),
        ?_assertEqual(7, buoy_rt:bit_or(5, 3)),
        ?_assertEqual(6, buoy_rt:bit_xor(5, 3)),
        ?_assertEqual(-6, buoy_rt:bit_not(5)),
        ?_assertEqual(-2147483648, buoy_rt:shift_left(1, 31)),
        ?_assertEqual(1, buoy_rt:shift_left(1, 32)),
        ?_assertEqual(-1, buoy_rt:shift_right(-1, 28)),
        ?_assertEqual(15, buoy_rt:shift_right_unsigned(-1, 28)),
        ?_assertEqual(4294967295, buoy_rt:shift_right_unsigned(-1, 0)),
        ?_assertEqual(5, buoy_rt:bit_or(4294967296 + 5, 0)),
        ?_assertEqual(1, buoy_rt:bit_or(1.9, 0)),
        ?_assertEqual(-1, buoy_rt:bit_or(-1.9, 0)),
        ?_assertEqual(0, buoy_rt:bit_or('NaN', 0)),
        ?_assertEqual(0, buoy_rt:bit_or('Infinity', 0)),
        ?_assertEqual(12, buoy_rt:bit_or(<<"12">>, 0)),
        ?_assertEqual(0, buoy_rt:bit_or(4294967296.5, 0)),
        ?_assertEqual(2147483647, buoy_rt:bit_or(-2147483649, 0))
    ].

strict_eq_test_() ->
    [
        ?_assert(buoy_rt:strict_eq(1, 1.0)),
        ?_assert(buoy_rt:strict_eq(0, -0.0)),
        ?_assertNot(buoy_rt:strict_eq('NaN', 'NaN')),
        ?_assert(buoy_rt:strict_eq(<<"a">>, <<"a">>)),
        ?_assertNot(buoy_rt:strict_eq(null, undefined)),
        ?_assertNot(buoy_rt:strict_eq(1, <<"1">>)),
        ?_assert(buoy_rt:strict_eq([1, #{<<"a">> => 2}], [1.0, #{<<"a">> => 2.0}])),
        ?_assertNot(buoy_rt:strict_eq([1], [1, 2])),
        ?_assertNot(buoy_rt:strict_eq(#{<<"a">> => 1}, #{<<"b">> => 1})),
        ?_assert(buoy_rt:strict_eq(buoy_map:new([[[a, 1]]]), element(2, buoy_map:mutate(<<"delete">>, buoy_map:new([[[a, 1], [b, 2]]]), [b])))),
        ?_assert(buoy_rt:strict_eq(buoy_set:new([[1, 2]]), buoy_set:new([[1.0, 2.0]])))
    ].

loose_eq_test_() ->
    [
        ?_assert(buoy_rt:loose_eq(null, undefined)),
        ?_assertNot(buoy_rt:loose_eq(null, 0)),
        ?_assertNot(buoy_rt:loose_eq(undefined, 0)),
        ?_assert(buoy_rt:loose_eq(<<"1">>, 1)),
        ?_assert(buoy_rt:loose_eq(true, 1)),
        ?_assert(buoy_rt:loose_eq([1], 1)),
        ?_assert(buoy_rt:loose_eq([], false)),
        ?_assert(buoy_rt:loose_eq(<<>>, 0)),
        ?_assertNot(buoy_rt:loose_eq('NaN', 'NaN')),
        ?_assert(buoy_rt:loose_eq(#{}, <<"[object Object]">>))
    ].

compare_test_() ->
    [
        ?_assert(buoy_rt:lt(1, 2)),
        ?_assert(buoy_rt:lt(<<"10">>, <<"9">>)),
        ?_assertNot(buoy_rt:lt(10, <<"9">>)),
        ?_assert(buoy_rt:lt(null, 1)),
        ?_assertNot(buoy_rt:lt(undefined, 1)),
        ?_assertNot(buoy_rt:lt('NaN', 1)),
        ?_assertNot(buoy_rt:ge('NaN', 1)),
        ?_assert(buoy_rt:gt([2], 1)),
        ?_assert(buoy_rt:lt(<<"B">>, <<"a">>)),
        ?_assert(buoy_rt:ge(null, 0)),
        ?_assert(buoy_rt:le(1, 1.0)),
        ?_assert(buoy_rt:lt(<<"z">>, <<"é"/utf8>>)),
        ?_assert(buoy_rt:lt('-Infinity', -1.0e308)),
        ?_assert(buoy_rt:gt('Infinity', 1 bsl 2000)),
        ?_assert(buoy_rt:le('Infinity', 'Infinity')),
        ?_assertNot(buoy_rt:gt(<<"abc">>, <<"abd">>))
    ].

truthy_test_() ->
    Falsy = [false, null, undefined, 0, 0.0, -0.0, 'NaN', <<>>],
    Truthy = [true, 1, -1, 0.5, <<"0">>, <<"false">>, [], #{}, 'Infinity', fun(_) -> 1 end, buoy_map:new([])],
    [?_assertNot(buoy_rt:truthy(V)) || V <- Falsy] ++ [?_assert(buoy_rt:truthy(V)) || V <- Truthy].

type_of_test_() ->
    Cases = [
        {undefined, <<"undefined">>}, {null, <<"object">>}, {true, <<"boolean">>}, {1, <<"number">>},
        {1.5, <<"number">>}, {'NaN', <<"number">>}, {<<"s">>, <<"string">>}, {fun(_) -> 1 end, <<"function">>},
        {[], <<"object">>}, {#{}, <<"object">>}, {buoy_map:new([]), <<"object">>},
        {{'$class', m, <<"C">>}, <<"function">>}, {{'$namespace', buoy_math}, <<"object">>},
        {{'$namespace', buoy_map}, <<"function">>}, {{'$namespace', buoy_json}, <<"object">>},
        {{'$namespace', buoy_ai_openai}, <<"function">>}
    ],
    [?_assertEqual(Expected, buoy_rt:type_of(V)) || {V, Expected} <- Cases].

instance_of_test_() ->
    TypeError = buoy_error:new(<<"TypeError">>, <<"x">>),
    NotFound = buoy_error:new([{'$class', 'buoy@app', <<"NotFound">>}, {'$class', buoy_error, <<"Error">>}], <<"x">>, #{<<"_tag">> => <<"NotFound">>}),
    [
        ?_assert(buoy_rt:instance_of(TypeError, {'$class', buoy_error, <<"Error">>})),
        ?_assert(buoy_rt:instance_of(TypeError, {'$class', buoy_error, <<"TypeError">>})),
        ?_assertNot(buoy_rt:instance_of(TypeError, {'$class', buoy_error, <<"RangeError">>})),
        ?_assert(buoy_rt:instance_of(NotFound, {'$class', 'buoy@app', <<"NotFound">>})),
        ?_assert(buoy_rt:instance_of(NotFound, {'$class', buoy_error, <<"Error">>})),
        ?_assertNot(buoy_rt:instance_of(#{}, {'$class', buoy_error, <<"Error">>})),
        ?_assert(buoy_rt:instance_of(buoy_map:new([]), {'$namespace', buoy_map})),
        ?_assertNot(buoy_rt:instance_of(buoy_map:new([]), {'$namespace', buoy_set})),
        ?_assert(buoy_rt:instance_of([], {'$namespace', buoy_array})),
        ?_assert(buoy_rt:instance_of([], {'$namespace', buoy_object})),
        ?_assertNot(buoy_rt:instance_of(<<"s">>, {'$namespace', buoy_object})),
        ?_assert(buoy_rt:instance_of({'$date', 0}, {'$namespace', buoy_date})),
        ?_assertEqual(<<"TypeError: Right-hand side of 'instanceof' is not an object">>, thrown(fun() -> buoy_rt:instance_of(1, 5) end))
    ].

has_test_() ->
    [
        ?_assert(buoy_rt:has(#{<<"a">> => undefined}, <<"a">>)),
        ?_assertNot(buoy_rt:has(#{}, <<"a">>)),
        ?_assert(buoy_rt:has(#{<<"1">> => x}, 1)),
        ?_assert(buoy_rt:has([a, b], 1)),
        ?_assert(buoy_rt:has([undefined], 0)),
        ?_assertNot(buoy_rt:has([a, b], 2)),
        ?_assert(buoy_rt:has([], <<"length">>)),
        ?_assertEqual(<<"TypeError: Cannot use 'in' operator to search for 'x' in 5">>, thrown(fun() -> buoy_rt:has(5, <<"x">>) end))
    ].

to_string_test_() ->
    Cases = [
        {<<"s">>, <<"s">>}, {42, <<"42">>}, {-1.5, <<"-1.5">>}, {1.0e21, <<"1e+21">>}, {-0.0, <<"0">>},
        {'NaN', <<"NaN">>}, {'-Infinity', <<"-Infinity">>}, {true, <<"true">>}, {null, <<"null">>},
        {undefined, <<"undefined">>}, {[1, [2, 3]], <<"1,2,3">>}, {[null, undefined, 1], <<",,1">>},
        {#{}, <<"[object Object]">>}, {buoy_map:new([]), <<"[object Map]">>}, {buoy_set:new([]), <<"[object Set]">>},
        {buoy_error:new(<<"TypeError">>, <<"bad">>), <<"TypeError: bad">>},
        {#{<<"toString">> => fun([]) -> <<"custom">> end}, <<"custom">>}
    ],
    [?_assertEqual(Expected, buoy_rt:to_string(V)) || {V, Expected} <- Cases] ++
        [?_assertEqual(<<"x 1 y true">>, buoy_rt:concat([<<"x ">>, 1, <<" y ">>, true]))].

get_test_() ->
    [
        ?_assertEqual(1, buoy_rt:get(#{<<"a">> => 1}, <<"a">>)),
        ?_assertEqual(undefined, buoy_rt:get(#{}, <<"a">>)),
        ?_assertEqual(x, buoy_rt:get(#{<<"1">> => x}, 1)),
        ?_assertEqual(b, buoy_rt:get([a, b], 1)),
        ?_assertEqual(b, buoy_rt:get([a, b], 1.0)),
        ?_assertEqual(a, buoy_rt:get([a, b], <<"0">>)),
        ?_assertEqual(undefined, buoy_rt:get([a, b], 2)),
        ?_assertEqual(undefined, buoy_rt:get([a, b], -1)),
        ?_assertEqual(2, buoy_rt:get([a, b], <<"length">>)),
        ?_assertEqual(3, buoy_rt:get(<<"héé"/utf8>>, <<"length">>)),
        ?_assertEqual(<<"é"/utf8>>, buoy_rt:get(<<"héé"/utf8>>, 1)),
        ?_assertEqual(2, buoy_rt:get(buoy_map:new([[[a, 1], [b, 2]]]), <<"size">>)),
        ?_assertEqual(3.141592653589793, buoy_rt:get({'$namespace', buoy_math}, <<"PI">>)),
        ?_assertEqual(<<"C">>, buoy_rt:get({'$class', m, <<"C">>}, <<"name">>)),
        ?_assertEqual(<<"x">>, buoy_rt:get(buoy_error:new(<<"Error">>, <<"x">>), <<"message">>)),
        ?_assertEqual(<<"TypeError: Cannot read properties of undefined (reading 'x')">>, thrown(fun() -> buoy_rt:get(undefined, <<"x">>) end)),
        ?_assertEqual(<<"TypeError: Cannot read properties of null (reading '0')">>, thrown(fun() -> buoy_rt:get(null, 0) end))
    ].

set_test_() ->
    [
        ?_assertEqual(#{<<"a">> => 2}, buoy_rt:set(#{<<"a">> => 1}, <<"a">>, 2)),
        ?_assertEqual(#{<<"1">> => x}, buoy_rt:set(#{}, 1, x)),
        ?_assertEqual([a, z], buoy_rt:set([a, b], 1, z)),
        ?_assertEqual([a, b, c], buoy_rt:set([a, b], 2, c)),
        ?_assertEqual([a, undefined, c], buoy_rt:set([a], 2, c)),
        ?_assertEqual([a], buoy_rt:set([a, b, c], <<"length">>, 1)),
        ?_assertEqual([a, undefined], buoy_rt:set([a], <<"length">>, 2)),
        ?_assertEqual(<<"TypeError: Cannot set properties of undefined (setting 'x')">>, thrown(fun() -> buoy_rt:set(undefined, <<"x">>, 1) end)),
        ?_assertEqual(<<"TypeError: Cannot assign to read only property '0' of string 'abc'">>, thrown(fun() -> buoy_rt:set(<<"abc">>, 0, 1) end)),
        ?_assertEqual(<<"TypeError: Cannot create property 'y' on number '5'">>, thrown(fun() -> buoy_rt:set(5, <<"y">>, 1) end)),
        ?_assertEqual(#{}, buoy_rt:delete(#{<<"a">> => 1}, <<"a">>)),
        ?_assertEqual([a, undefined], buoy_rt:delete([a, b], 1))
    ].

literal_test_() ->
    Error = buoy_error:new(<<"Error">>, <<"x">>, #{<<"code">> => 1}),
    [
        ?_assertEqual(#{<<"a">> => 1, <<"b">> => 3}, buoy_rt:object([{<<"a">>, 1}, {'$spread', #{<<"b">> => 2}}, {<<"b">>, 3}])),
        ?_assertEqual(#{<<"a">> => 9}, buoy_rt:object([{<<"a">>, 1}, {'$spread', #{<<"a">> => 9}}])),
        ?_assertEqual(#{<<"0">> => x, <<"1">> => y}, buoy_rt:object([{'$spread', [x, y]}])),
        ?_assertEqual(#{<<"0">> => <<"h">>, <<"1">> => <<"i">>}, buoy_rt:object([{'$spread', <<"hi">>}])),
        ?_assertEqual(#{}, buoy_rt:object([{'$spread', null}, {'$spread', undefined}, {'$spread', 5}])),
        ?_assertEqual(#{<<"code">> => 1}, buoy_rt:object([{'$spread', Error}])),
        ?_assertEqual(#{<<"2">> => two}, buoy_rt:object([{2, two}])),
        ?_assertEqual([0, 1, 2, 3], buoy_rt:array([{'$item', 0}, {'$spread', [1, 2]}, {'$item', 3}])),
        ?_assertEqual([<<"a">>, <<"b">>], buoy_rt:array([{'$spread', <<"ab">>}])),
        ?_assertEqual([[k, v]], buoy_rt:array([{'$spread', buoy_map:new([[[k, v]]])}])),
        ?_assertEqual(<<"TypeError: {} is not iterable">>, thrown(fun() -> buoy_rt:array([{'$spread', #{}}]) end)),
        ?_assertEqual(#{<<"b">> => 2}, buoy_rt:object_rest(#{<<"a">> => 1, <<"b">> => 2}, [<<"a">>])),
        ?_assertEqual([c], buoy_rt:array_rest([a, b, c], 2)),
        ?_assertEqual([], buoy_rt:array_rest([a], 5)),
        ?_assertEqual([<<"c">>], buoy_rt:array_rest(<<"abc">>, 2))
    ].

iteration_test_() ->
    [
        ?_assertEqual([<<"h">>, <<"é"/utf8>>, <<"😀"/utf8>>], buoy_rt:to_list(<<"hé😀"/utf8>>)),
        ?_assertEqual([[b, 2], [a, 1]], buoy_rt:to_list(buoy_map:new([[[b, 2], [a, 1]]]))),
        ?_assertEqual([3, 1], buoy_rt:to_list(buoy_set:new([[3, 1, 3]]))),
        ?_assertEqual(<<"TypeError: 5 is not iterable">>, thrown(fun() -> buoy_rt:to_list(5) end)),
        ?_assertEqual(<<"TypeError: undefined is not iterable">>, thrown(fun() -> buoy_rt:to_list(undefined) end)),
        ?_assertEqual([<<"a">>, <<"b">>], buoy_rt:keys(#{<<"b">> => 1, <<"a">> => 2})),
        ?_assertEqual([<<"0">>, <<"1">>], buoy_rt:keys([x, y])),
        ?_assertEqual([<<"code">>], buoy_rt:keys(buoy_error:new(<<"Error">>, <<"m">>, #{<<"code">> => 1}))),
        ?_assertEqual([], buoy_rt:keys(null))
    ].

caught_test_() ->
    Error = buoy_error:new(<<"Error">>, <<"x">>),
    {Reason, Stack} =
        try
            erlang:error(badarith)
        catch
            error:R:S -> {R, S}
        end,
    Caught = buoy_rt:caught(Reason, Stack),
    [
        ?_assertEqual(Error, buoy_rt:caught({'$throw', Error}, [])),
        ?_assertEqual(42, buoy_rt:caught({'$throw', 42}, [])),
        ?_assertEqual(<<"TypeError">>, buoy_rt:get(Caught, <<"name">>)),
        ?_assertEqual(<<"bad argument in an arithmetic expression">>, buoy_rt:get(Caught, <<"message">>)),
        ?_assertEqual(<<"badarith">>, buoy_rt:get(Caught, <<"erlang">>)),
        ?_assertMatch(<<"TypeError: bad argument in an arithmetic expression\n    at ", _/binary>>, buoy_rt:get(Caught, <<"stack">>)),
        ?_assertEqual(<<"no match of right hand side value 1">>, buoy_rt:get(buoy_rt:caught({badmatch, 1}, []), <<"message">>)),
        ?_assert(buoy_rt:instance_of(Caught, {'$class', buoy_error, <<"TypeError">>}))
    ].

environment_test_() ->
    os:putenv("BUOY_RT_TEST_VAR", "héllo"),
    [
        ?_assertEqual(<<"héllo"/utf8>>, buoy_rt:env(<<"BUOY_RT_TEST_VAR">>)),
        ?_assertEqual(undefined, buoy_rt:env(<<"BUOY_RT_TEST_MISSING">>)),
        ?_assertEqual([], buoy_rt:argv()),
        ?_assertEqual(#{<<"a">> => [1]}, buoy_rt:structured_clone(#{<<"a">> => [1]}))
    ].

conversion_test_() ->
    [
        ?_assertEqual(3, buoy_rt:to_integer(3.9)),
        ?_assertEqual(-3, buoy_rt:to_integer(-3.9)),
        ?_assertEqual(0, buoy_rt:to_integer('NaN')),
        ?_assertEqual('Infinity', buoy_rt:to_integer('Infinity')),
        ?_assertEqual(2, buoy_rt:relative_index(-1, 3, 0)),
        ?_assertEqual(0, buoy_rt:relative_index(-10, 3, 0)),
        ?_assertEqual(3, buoy_rt:relative_index('Infinity', 3, 0)),
        ?_assertEqual(1, buoy_rt:collection_key(1.0)),
        ?_assertEqual(0, buoy_rt:collection_key(-0.0)),
        ?_assertEqual(0.5, buoy_rt:collection_key(0.5)),
        ?_assert(buoy_rt:same_value_zero('NaN', 'NaN'))
    ].

%% `handlers[0](x)`: a key that is not a string names a property to call.
property_call_test_() ->
    Handlers = [fun([N]) -> N + 1 end, fun([N]) -> N * 2 end],
    [
        ?_assertEqual(11, buoy_rt:call_method(Handlers, 0, [10])),
        ?_assertEqual(20, buoy_rt:call_method(Handlers, 1.0, [10])),
        ?_assertEqual(42, buoy_rt:call_method([<<"double">>, fun([N]) -> N * 2 end], 1, [21])),
        ?_assertEqual(<<"one">>, buoy_rt:call_method(#{<<"1">> => fun([]) -> <<"one">> end}, 1, [])),
        ?_assertMatch(<<"TypeError: ", _/binary>>, thrown(fun() -> buoy_rt:call_method(Handlers, 5, []) end))
    ].

%% Built-in methods are properties: a read gives a function value that
%% `call`, `apply`, and `bind` run with a receiver.
member_test_() ->
    Map = buoy_rt:get([1, 2], <<"map">>),
    HasOwn = buoy_rt:get(buoy_object:'$member'(<<"prototype">>), <<"hasOwnProperty">>),
    [
        ?_assertEqual({'$method', buoy_array, <<"map">>}, Map),
        ?_assertEqual(<<"function">>, buoy_rt:type_of(Map)),
        ?_assertEqual(<<"map">>, buoy_rt:get(Map, <<"name">>)),
        ?_assertEqual([2, 3], buoy_rt:call_method(Map, <<"call">>, [[1, 2], fun([X | _]) -> X + 1 end])),
        ?_assertEqual(<<"TypeError: Array.prototype.map called on null or undefined">>, thrown(fun() -> buoy_rt:call(Map, []) end)),
        ?_assert(buoy_rt:call_method(HasOwn, <<"call">>, [#{<<"a">> => 1}, <<"a">>])),
        ?_assertEqual(<<"function">>, buoy_rt:type_of(buoy_rt:get(<<"s">>, <<"trim">>))),
        ?_assertEqual(<<"function">>, buoy_rt:type_of(buoy_rt:get(5, <<"toFixed">>))),
        ?_assertEqual(undefined, buoy_rt:get([1], <<"nope">>)),
        ?_assertEqual({'$namespace', buoy_object}, buoy_rt:get(#{}, <<"constructor">>)),
        ?_assertEqual({'$namespace', buoy_array}, buoy_rt:get([], <<"constructor">>)),
        ?_assertEqual(1, buoy_rt:get(#{<<"constructor">> => 1}, <<"constructor">>)),
        ?_assert(buoy_rt:has(#{}, <<"toString">>)),
        ?_assertNot(buoy_rt:has(#{}, <<"nope">>)),
        ?_assertEqual(<<"[object Array]">>, buoy_rt:call_method(buoy_rt:get(#{}, <<"toString">>), <<"call">>, [[]])),
        ?_assertEqual(undefined, buoy_rt:call_method({'$class', buoy_error, <<"Error">>}, <<"captureStackTrace">>, [#{}]))
    ].

%% ToPrimitive calls an own valueOf before toString, except for the string
%% hint of String() and template literals.
value_of_test_() ->
    Money = #{<<"valueOf">> => fun([]) -> 150 end},
    Both = #{<<"valueOf">> => fun([]) -> 7 end, <<"toString">> => fun([]) -> <<"seven">> end},
    [
        ?_assertEqual(151, buoy_rt:add(Money, 1)),
        ?_assertEqual(300, buoy_rt:mul(Money, 2)),
        ?_assert(buoy_rt:gt(Money, 100)),
        ?_assertEqual(<<"7">>, buoy_rt:add(Both, <<>>)),
        ?_assertEqual(<<"seven">>, buoy_rt:to_string(Both)),
        ?_assertEqual(<<"[object Object]">>, buoy_rt:to_string(Money)),
        ?_assertEqual(<<"TypeError: Cannot convert object to primitive value">>, thrown(fun() -> buoy_rt:to_string(#{<<"toString">> => fun([]) -> #{} end}) end))
    ].

%% Equal numbers share one Map key at any size.
collection_key_test_() ->
    [
        ?_assertEqual(100000000000000000000, buoy_rt:collection_key(1.0e20)),
        ?_assertEqual(1.0e21, buoy_rt:collection_key(1000000000000000000000)),
        ?_assertEqual(1.0e21, buoy_rt:collection_key(1.0e21)),
        ?_assertEqual(9007199254740993, buoy_rt:collection_key(9007199254740993)),
        ?_assertEqual(0, buoy_rt:collection_key(-0.0)),
        ?_assertEqual(1.5, buoy_rt:collection_key(1.5))
    ].

%% A message cuts a value after 40 characters, never inside one.
describe_test_() ->
    Long = #{<<"name">> => binary:copy(<<"é"/utf8>>, 60)},
    Text = buoy_rt:describe(Long),
    [
        ?_assertEqual(43, buoy_string:char_count(Text)),
        ?_assertMatch(<<_/binary>>, unicode:characters_to_binary(Text)),
        ?_assertEqual(<<"\"x\"">>, buoy_rt:describe(<<"x">>))
    ].
