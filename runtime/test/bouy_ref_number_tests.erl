-module(bouy_ref_number_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SAFE, 9007199254740992).

canonical_form_test_() ->
    [?_assertEqual(1, bouy_ref_number:canonical(1.0)),
     ?_assertEqual(0, bouy_ref_number:canonical(0.0)),
     ?_assert(bouy_ref_number:canonical(-0.0) =:= -0.0),
     ?_assertEqual(?SAFE, bouy_ref_number:canonical(float(?SAFE))),
     ?_assertEqual(9007199254740994.0, bouy_ref_number:canonical(?SAFE + 2)),
     %% 2^53 + 1 rounds to even, as a double does.
     ?_assertEqual(?SAFE, bouy_ref_number:canonical(float(?SAFE + 1))),
     ?_assertEqual('Infinity', bouy_ref_number:canonical(1 bsl 1100)),
     ?_assertEqual('-Infinity', bouy_ref_number:canonical(-(1 bsl 1100))),
     ?_assertEqual(2.5, bouy_ref_number:canonical(2.5))].

arithmetic_test_() ->
    N = fun(F, A, B) -> bouy_ref_number:F(A, B) end,
    [?_assert(N(mul, 0, -5) =:= -0.0),
     ?_assert(N(remainder, -5, 5) =:= -0.0),
     ?_assert(N(divide, 0, -3) =:= -0.0),
     ?_assertEqual('-Infinity', N(divide, 1, -0.0)),
     ?_assertEqual('NaN', N(divide, 0, 0)),
     ?_assertEqual(3, N(divide, 9, 3)),
     ?_assertEqual(2.5, N(divide, 5, 2)),
     ?_assertEqual(1, N(add, 0.5, 0.5)),
     ?_assertEqual('Infinity', N(mul, 1.0e308, 10)),
     ?_assertEqual('NaN', N(add, 'Infinity', '-Infinity')),
     ?_assertEqual('NaN', N(mul, 'Infinity', 0)),
     ?_assertEqual(5, N(remainder, 5, 'Infinity')),
     ?_assertEqual(?SAFE, N(add, ?SAFE, 1)),
     ?_assertEqual(12157665459056928801.0, N(power, 3, 40)),
     ?_assert(bouy_ref_number:negate(0) =:= -0.0),
     ?_assertEqual(0, bouy_ref_number:negate(-0.0))].

int32_test_() ->
    [?_assertEqual(-2147483648, bouy_ref_number:bit_or(2147483648, 0)),
     ?_assertEqual(4294967295, bouy_ref_number:shift_right_unsigned(-1, 0)),
     ?_assertEqual(1, bouy_ref_number:shift_left(1, 32)),
     ?_assertEqual(0, bouy_ref_number:bit_or('NaN', 0)),
     ?_assertEqual(-1, bouy_ref_number:to_int32(-1.9)),
     ?_assertEqual(0, bouy_ref_number:to_int32(4294967296.5))].

compare_test_() ->
    [?_assertEqual(eq, bouy_ref_number:compare(0, -0.0)),
     ?_assertEqual(undefined, bouy_ref_number:compare('NaN', 1)),
     ?_assertEqual(lt, bouy_ref_number:compare('-Infinity', -1.0e308)),
     ?_assertEqual(gt, bouy_ref_number:compare(2, 1.5))].

conversion_test_() ->
    [?_assertEqual(<<"1e+21">>, bouy_ref_number:to_string(1.0e21)),
     ?_assertEqual(<<"0">>, bouy_ref_number:to_string(-0.0)),
     ?_assertEqual(<<"-Infinity">>, bouy_ref_number:to_string('-Infinity')),
     ?_assert(bouy_ref_number:from_string(<<"-0">>) =:= -0.0),
     ?_assertEqual(1000, bouy_ref_number:from_string(<<"1e3">>)),
     ?_assertEqual(12, bouy_ref_number:from_string(<<" 12\x{A0}">>)),
     ?_assertEqual('NaN', bouy_ref_number:from_string({'$u16', <<16#20AC:16>>}))].

%% The text forms round the exact value of the double, as Node does.
formatting_test_() ->
    N = bouy_ref_number,
    [?_assertEqual(<<"1.00">>, N:to_fixed(1.005, 2)),
     ?_assertEqual(<<"0.10000000000000000555">>, N:to_fixed(0.1, 20)),
     ?_assertEqual(<<"-0.00">>, N:to_fixed(-1.5e-9, 2)),
     ?_assertEqual(<<"1e+21">>, N:to_fixed(1.0e21, 2)),
     ?_assertEqual(<<"1.23e+2">>, N:to_exponential(123.456, 2)),
     ?_assertEqual(<<"1.23456e+2">>, N:to_exponential(123.456, shortest)),
     ?_assertEqual(<<"0e+0">>, N:to_exponential(0, shortest)),
     ?_assertEqual(<<"1.2e+5">>, N:to_precision(123456, 2)),
     ?_assertEqual(<<"0.0000012">>, N:to_precision(0.000001234, 2)),
     ?_assertEqual(<<"1.235e-7">>, N:to_precision(1.2345e-7, 4)),
     ?_assertEqual(<<"ff">>, N:to_radix_string(255, 16)),
     ?_assertEqual(<<"0.1">>, N:to_radix_string(0.5, 2)),
     ?_assertEqual(<<"0.1">>, N:to_radix_string(1 / 3, 3)),
     ?_assertEqual(<<"-11111111">>, N:to_radix_string(-255, 2)),
     ?_assertEqual(<<"1.23e-18">>, N:to_string(123.0e-20)),
     ?_assertEqual(<<"5e-324">>, N:to_string(5.0e-324))].

parsing_test_() ->
    N = bouy_ref_number,
    [?_assertEqual(31, N:from_string(<<"0x1F">>)),
     ?_assertEqual(5, N:from_string(<<"0b101">>)),
     ?_assertEqual('NaN', N:from_string(<<"-0x10">>)),
     ?_assertEqual('NaN', N:from_string(<<"1_0">>)),
     ?_assertEqual(12500, N:from_string(<<" 12.5e3 ">>)),
     ?_assertEqual(0, N:from_string(<<"">>)),
     ?_assertEqual('-Infinity', N:from_string(<<"-Infinity">>)),
     ?_assertEqual('Infinity', N:from_string(<<"1e400">>)),
     ?_assertEqual(0.5, N:from_string(<<".5">>)),
     ?_assertEqual(5, N:from_string(<<"5.">>))].

big_int_test_() ->
    B = bouy_ref_bigint,
    [?_assertEqual({'$bigint', 3}, B:operate(divide, 7, 2)),
     ?_assertEqual({'$bigint', -1}, B:operate(remainder, -7, 3)),
     ?_assertEqual({'$bigint', -5}, B:operate(shift_right, -9, 1)),
     ?_assertEqual(-1, B:as_int_n(8, 255)),
     ?_assertEqual(255, B:as_uint_n(8, -1)),
     ?_assertEqual({'$bigint', 16}, B:from_string(<<" 0x10 ">>)),
     ?_assertEqual(undefined, B:from_string(<<"1.5">>)),
     ?_assertEqual(lt, B:compare_number(1, 1.5)),
     ?_assertEqual(gt, B:compare_number(2, 1.5)),
     ?_assertEqual(eq, B:compare_number(2, 2.0)),
     ?_assertEqual(undefined, B:compare_number(2, 'NaN'))].
