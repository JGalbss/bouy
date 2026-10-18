-module(buoy_number_tests).

-include_lib("eunit/include/eunit.hrl").

thrown(F) ->
    try F() of
        Value -> {returned, Value}
    catch
        error:{'$throw', #{<<"name">> := Name, <<"message">> := Message}} -> <<Name/binary, ": ", Message/binary>>
    end.

method(N, Name, Args) -> buoy_number:call(Name, N, Args).

to_string_test_() ->
    Cases = [
        {0, <<"0">>}, {-0.0, <<"0">>}, {1.0, <<"1">>}, {100.0, <<"100">>}, {0.30000000000000004, <<"0.30000000000000004">>},
        {1.0e21, <<"1e+21">>}, {1.0e20, <<"100000000000000000000">>}, {1.0e-7, <<"1e-7">>}, {1.0e-6, <<"0.000001">>},
        {1.23e-18, <<"1.23e-18">>}, {-1.5e-9, <<"-1.5e-9">>}, {1.7976931348623157e308, <<"1.7976931348623157e+308">>},
        {5.0e-324, <<"5e-324">>}, {9007199254740992.0, <<"9007199254740992">>}, {123456789.123, <<"123456789.123">>},
        {1.0e100, <<"1e+100">>}, {123456789012345680000.0, <<"123456789012345680000">>}, {1.5, <<"1.5">>},
        {'NaN', <<"NaN">>}, {'Infinity', <<"Infinity">>}, {'-Infinity', <<"-Infinity">>},
        {12345678901234567890123, <<"12345678901234567890123">>}
    ],
    [?_assertEqual(Expected, buoy_number:to_string(N)) || {N, Expected} <- Cases].

to_fixed_test_() ->
    %% Exact decimal rounding with ties away from zero, as V8 does.
    Cases = [
        {2.5, 0, <<"3">>}, {0.5, 0, <<"1">>}, {1.5, 0, <<"2">>}, {1.25, 1, <<"1.3">>}, {1.45, 1, <<"1.4">>},
        {1.005, 2, <<"1.00">>}, {8.345, 2, <<"8.35">>}, {-2.5, 0, <<"-3">>}, {-0.0001, 2, <<"-0.00">>},
        {-0.0, 2, <<"0.00">>}, {1.0e21, 2, <<"1e+21">>}, {1.0e20, 2, <<"100000000000000000000.00">>},
        {123.456, undefined, <<"123">>}, {1.0e-6, 7, <<"0.0000010">>}, {5.0e-7, 10, <<"0.0000005000">>},
        {1.23e-10, 20, <<"0.00000000012300000000">>}, {42, 2, <<"42.00">>}, {'NaN', 2, <<"NaN">>}
    ],
    [?_assertEqual(Expected, method(N, <<"toFixed">>, [D])) || {N, D, Expected} <- Cases] ++
        [?_assertEqual(<<"RangeError: toFixed() digits argument must be between 0 and 100">>, thrown(fun() -> method(1, <<"toFixed">>, [101]) end))].

to_precision_test_() ->
    Cases = [
        {123.456, 4, <<"123.5">>}, {0.000123, 2, <<"0.00012">>}, {123456, 2, <<"1.2e+5">>}, {1.5, 1, <<"2">>},
        {2.5, 1, <<"3">>}, {1.0e-7, 3, <<"1.00e-7">>}, {0, 3, <<"0.00">>}, {123, undefined, <<"123">>},
        {99.99, 3, <<"100">>}, {1.0e21, 3, <<"1.00e+21">>}
    ],
    [?_assertEqual(Expected, method(N, <<"toPrecision">>, [P])) || {N, P, Expected} <- Cases] ++
        [?_assertEqual(<<"RangeError: toPrecision() argument must be between 1 and 100">>, thrown(fun() -> method(1, <<"toPrecision">>, [0]) end))].

to_exponential_test_() ->
    Cases = [
        {123.456, 2, <<"1.23e+2">>}, {0, undefined, <<"0e+0">>}, {123456, undefined, <<"1.23456e+5">>},
        {1.5, 0, <<"2e+0">>}, {0.00015, 1, <<"1.5e-4">>}, {-5, 3, <<"-5.000e+0">>}
    ],
    [?_assertEqual(Expected, method(N, <<"toExponential">>, [D])) || {N, D, Expected} <- Cases].

radix_test_() ->
    Cases = [
        {255, 16, <<"ff">>}, {-255, 2, <<"-11111111">>}, {0.5, 2, <<"0.1">>}, {255.5, 16, <<"ff.8">>},
        {0.1, 3, <<"0.0022002200220022002200220022002201">>}, {3.14159, 36, <<"3.53i0tuycp">>},
        {1.0e21, 16, <<"3635c9adc5dea00000">>}, {-0.75, 8, <<"-0.6">>}, {123.456, 36, <<"3f.gez4w97ry">>},
        {1 / 3, 2, <<"0.010101010101010101010101010101010101010101010101010101">>}, {0, 2, <<"0">>}, {'NaN', 2, <<"NaN">>}
    ],
    [?_assertEqual(Expected, method(N, <<"toString">>, [R])) || {N, R, Expected} <- Cases] ++
        [?_assertEqual(<<"RangeError: toString() radix argument must be between 2 and 36">>, thrown(fun() -> method(1, <<"toString">>, [1]) end))].

locale_test_() ->
    Cases = [
        {1234567.891, <<"1,234,567.891">>}, {0.0001, <<"0">>}, {-0.0001, <<"-0">>}, {1.0005, <<"1.001">>},
        {1.2345, <<"1.235">>}, {1.0e21, <<"1,000,000,000,000,000,000,000">>}, {'NaN', <<"NaN">>},
        {'Infinity', <<"∞"/utf8>>}, {-1234.5, <<"-1,234.5">>}, {999.9999, <<"1,000">>}, {12, <<"12">>}
    ],
    [?_assertEqual(Expected, method(N, <<"toLocaleString">>, [])) || {N, Expected} <- Cases].

parse_int_test_() ->
    Cases = [
        {[<<"42px">>], 42}, {[<<"  -0x1F">>], -31}, {[<<"0x">>], 'NaN'}, {[<<"abc">>], 'NaN'}, {[<<"101">>, 2], 5},
        {[<<"z">>, 36], 35}, {[<<"1e3">>], 1}, {[0.0000005], 5}, {[<<"12">>, 1], 'NaN'}, {[<<"12">>, 37], 'NaN'},
        {[<<"  +7 ">>], 7}, {[<<>>], 'NaN'}, {[<<"0b11">>], 0}, {[<<"08">>], 8}, {[<<"ff">>, 16], 255},
        {[<<"0xff">>, 16], 255}, {[null], 'NaN'}, {[<<"Infinity">>], 'NaN'}, {[<<"-">>], 'NaN'}, {[<<"123">>, 0], 123},
        {[<<" 5"/utf8>>], 5}, {[<<"12345678901234567890">>], 1.2345678901234567e19},
        %% node -e 'console.log(parseInt("9007199254740993", 36))' on arm64
        {[<<"9007199254740993">>, 36], 1.9896986116031812e24}
    ],
    [?_assertEqual(Expected, buoy_number:'parseInt'(Args)) || {Args, Expected} <- Cases].

parse_float_test_() ->
    Cases = [
        {<<"3.14abc">>, 3.14}, {<<".5">>, 0.5}, {<<"5.">>, 5}, {<<"-.5e-3x">>, -0.0005}, {<<"1e">>, 1},
        {<<"Infinityx">>, 'Infinity'}, {<<"-Infinity">>, '-Infinity'}, {<<"abc">>, 'NaN'}, {<<"  42  ">>, 42},
        {<<"1e400">>, 'Infinity'}, {<<"0x10">>, 0}, {<<"1_000">>, 1}, {<<"+.e1">>, 'NaN'}, {<<"e5">>, 'NaN'}
    ],
    [?_assertEqual(Expected, buoy_number:'parseFloat'([Text])) || {Text, Expected} <- Cases].

number_call_test_() ->
    [
        ?_assertEqual(0, buoy_number:'$call'([])),
        ?_assertEqual(12, buoy_number:'$call'([<<" 12 ">>])),
        ?_assertEqual('NaN', buoy_number:'$call'([<<"12px">>])),
        ?_assertEqual(1, buoy_number:new([true]))
    ].

predicates_test_() ->
    [
        ?_assert(buoy_number:'isInteger'([5])),
        ?_assert(buoy_number:'isInteger'([5.0])),
        ?_assertNot(buoy_number:'isInteger'([5.5])),
        ?_assertNot(buoy_number:'isInteger'(['Infinity'])),
        ?_assertNot(buoy_number:'isInteger'([<<"5">>])),
        ?_assert(buoy_number:'isSafeInteger'([9007199254740991])),
        ?_assertNot(buoy_number:'isSafeInteger'([9007199254740992])),
        ?_assert(buoy_number:'isFinite'([1.5])),
        ?_assertNot(buoy_number:'isFinite'(['Infinity'])),
        ?_assertNot(buoy_number:'isFinite'([<<"5">>])),
        ?_assert(buoy_number:'$isFinite'([<<"5">>])),
        ?_assert(buoy_number:'isNaN'(['NaN'])),
        ?_assertNot(buoy_number:'isNaN'([<<"abc">>])),
        ?_assert(buoy_number:'$isNaN'([<<"abc">>])),
        ?_assert(buoy_number:'$isNaN'([])),
        ?_assertNot(buoy_number:'$isNaN'([<<"12">>]))
    ].

members_test_() ->
    [
        ?_assertEqual(9007199254740991, buoy_number:'$member'(<<"MAX_SAFE_INTEGER">>)),
        ?_assertEqual(2.220446049250313e-16, buoy_number:'$member'(<<"EPSILON">>)),
        ?_assertEqual('NaN', buoy_number:'$member'(<<"NaN">>)),
        ?_assertEqual(5, buoy_rt:call(buoy_number:'$member'(<<"parseInt">>), [<<"5">>])),
        ?_assertEqual(undefined, buoy_number:'$member'(<<"nope">>))
    ].

from_string_test_() ->
    [
        ?_assertEqual(0, buoy_number:from_string(<<"  ">>)),
        ?_assertEqual(-0.0, buoy_number:from_string(<<"-0.0">>)),
        ?_assertEqual(0.0, buoy_number:from_string(<<"1e-400">>)),
        ?_assertEqual(7, buoy_number:from_string(<<"\x{2028} 7 \x{2029}"/utf8>>)),
        ?_assertEqual(9007199254740992.0, buoy_number:from_string(<<"9007199254740993">>))
    ].
