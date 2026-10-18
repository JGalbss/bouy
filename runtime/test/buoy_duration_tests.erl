-module(buoy_duration_tests).

-include_lib("eunit/include/eunit.hrl").

-import(buoy_test_runtime, [thrown/1]).

reads_each_input_test() ->
    ?assertEqual(250, buoy_duration:to_millis(250)),
    ?assertEqual(100, buoy_duration:to_millis(<<"100 millis">>)),
    ?assertEqual(1500.0, buoy_duration:to_millis(<<"1.5 seconds">>)),
    ?assertEqual(120000, buoy_duration:to_millis(<<"2 minutes">>)),
    ?assertEqual('Infinity', buoy_duration:to_millis(<<"Infinity">>)),
    ?assertEqual(3000, buoy_duration:to_millis(buoy_duration:seconds([3]))),
    ?assertMatch(#{<<"message">> := <<"Invalid Input: soon">>}, thrown(fun() -> buoy_duration:to_millis(<<"soon">>) end)).

prints_as_effect_does_test() ->
    ?assertEqual(#{<<"_id">> => <<"Duration">>, <<"_tag">> => <<"Millis">>, <<"millis">> => 100}, buoy_duration:millis([100])),
    ?assertEqual(<<"20ms">>, buoy_duration:text(20)),
    ?assertEqual(<<"2s 500ms">>, buoy_duration:text(2500)),
    ?assertEqual(<<"1h 1m">>, buoy_duration:text(3660000)),
    ?assertEqual(<<"0">>, buoy_duration:text(0)),
    ?assertEqual(<<"Infinity">>, buoy_duration:format([<<"Infinity">>])).
