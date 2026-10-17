-module(bouy_ref_buffer_tests).

-include_lib("eunit/include/eunit.hrl").

%% The element encodings round each value as the specification does.
encoding_test_() ->
    E = fun(Kind, V) -> bouy_ref_buffer:decode(Kind, bouy_ref_buffer:encode(Kind, V)) end,
    [?_assertEqual(44, E(uint8, 300)),
     ?_assertEqual(-1, E(int8, 255)),
     ?_assertEqual(255, E(uint8c, 300)),
     ?_assertEqual(2, E(uint8c, 2.5)),
     ?_assertEqual(4, E(uint8c, 3.5)),
     ?_assertEqual(0, E(uint8c, -5)),
     ?_assertEqual(65535, E(uint16, -1)),
     ?_assertEqual(-2147483648, E(int32, 2147483648)),
     ?_assertEqual(0, E(uint32, 'NaN')),
     ?_assertEqual('NaN', E(float32, 'NaN')),
     ?_assertEqual('Infinity', E(float32, 1.0e300)),
     ?_assertEqual(1.100000023841858, E(float32, 1.1)),
     ?_assertEqual(1.3369140625, E(float16, 1.337)),
     ?_assertEqual('Infinity', E(float16, 65520)),
     ?_assertEqual(65504, E(float16, 65519)),
     ?_assert(E(float16, -0.0) =:= -0.0),
     ?_assertEqual(5.960464477539063e-8, E(float16, 5.960464477539063e-8)),
     ?_assertEqual({'$bigint', -2}, E(bigint64, {'$bigint', 18446744073709551614})),
     ?_assertEqual({'$bigint', 18446744073709551614}, E(biguint64, {'$bigint', -2}))].

%% Bytes land in little-endian words, across word boundaries.
storage_test() ->
    Pid = self(),
    spawn(fun() ->
                  B = bouy_ref_buffer:allocate(16),
                  bouy_ref_buffer:write(B, 6, <<1, 2, 3, 4>>),
                  Pid ! {bytes, bouy_ref_buffer:read(B, 5, 6), bouy_ref_buffer:byte_length(B)}
          end),
    receive
        {bytes, Bytes, Length} ->
            ?assertEqual(<<0, 1, 2, 3, 4, 0>>, Bytes),
            ?assertEqual(16, Length)
    end.

%% Uint8Array.fromBase64 and fromHex decode with the chunk rules of the
%% proposal, through the method of the family.
base64_test() ->
    Pid = self(),
    spawn(fun() ->
                  bouy_ref:init_realm(),
                  A = bouy_ref_typed_array:method(<<"Uint8Array">>, <<"fromBase64">>, undefined, [<<"SGk=">>]),
                  B = bouy_ref_typed_array:method(<<"Uint8Array">>, <<"fromHex">>, undefined, [<<"ff00">>]),
                  Text = bouy_ref_typed_array:method(<<"Uint8Array.prototype">>, <<"toBase64">>, A, []),
                  Strict = try bouy_ref_typed_array:method(<<"Uint8Array">>, <<"fromBase64">>, undefined, [<<"SGl=">>, strict_options()])
                           catch error:{'$throw', _} -> rejected
                           end,
                  Pid ! {result, [bouy_ref:get(A, 0), bouy_ref:get(A, 1), bouy_ref:get(B, 0), Text, Strict]}
          end),
    receive
        {result, Result} -> ?assertEqual([$H, $i, 255, <<"SGk=">>, rejected], Result)
    end.

strict_options() -> bouy_heap:object({'$o', 'Object.prototype'}, [{<<"lastChunkHandling">>, <<"strict">>}]).
