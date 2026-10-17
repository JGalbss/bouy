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
