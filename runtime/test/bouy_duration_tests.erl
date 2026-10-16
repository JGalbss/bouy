-module(bouy_duration_tests).

-include_lib("eunit/include/eunit.hrl").

-import(bouy_test_runtime, [thrown/1]).

reads_each_input_test() ->
    ?assertEqual(250, bouy_duration:to_millis(250)),
    ?assertEqual(100, bouy_duration:to_millis(<<"100 millis">>)),
    ?assertEqual(1500.0, bouy_duration:to_millis(<<"1.5 seconds">>)),
    ?assertEqual(120000, bouy_duration:to_millis(<<"2 minutes">>)),
    ?assertEqual('Infinity', bouy_duration:to_millis(<<"Infinity">>)),
    ?assertEqual(3000, bouy_duration:to_millis(bouy_duration:seconds([3]))),
    ?assertMatch(#{<<"message">> := <<"Invalid Input: soon">>}, thrown(fun() -> bouy_duration:to_millis(<<"soon">>) end)).

prints_as_effect_does_test() ->
    ?assertEqual(#{<<"_id">> => <<"Duration">>, <<"_tag">> => <<"Millis">>, <<"millis">> => 100}, bouy_duration:millis([100])),
    ?assertEqual(<<"20ms">>, bouy_duration:text(20)),
    ?assertEqual(<<"2s 500ms">>, bouy_duration:text(2500)),
    ?assertEqual(<<"1h 1m">>, bouy_duration:text(3660000)),
    ?assertEqual(<<"0">>, bouy_duration:text(0)),
    ?assertEqual(<<"Infinity">>, bouy_duration:format([<<"Infinity">>])).
