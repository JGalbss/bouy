-module(buoy_node_histogram_tests).

%% The expected values are what node v25.9.0 printed for the same records
%% through perf_hooks.createHistogram.

-include_lib("eunit/include/eunit.hrl").

-define(MAX_SAFE, 9007199254740991).

recorded(Lowest, Highest, Figures, Values) ->
    lists:foldl(fun(V, H) -> buoy_node_histogram:record(H, V) end,
                buoy_node_histogram:new(Lowest, Highest, Figures), Values).

empty_test() ->
    H = buoy_node_histogram:new(1, ?MAX_SAFE, 3),
    ?assertEqual(9223372036854775807, buoy_node_histogram:min(H)),
    ?assertEqual(0, buoy_node_histogram:max(H)),
    ?assertEqual('NaN', buoy_node_histogram:mean(H)),
    ?assertEqual('NaN', buoy_node_histogram:stddev(H)),
    ?assertEqual(0, buoy_node_histogram:percentile(H, 50.0)),
    ?assertEqual([{100.0, 0}], buoy_node_histogram:percentiles(H)).

equivalent_values_test() ->
    H = recorded(1, ?MAX_SAFE, 3, [1, 2, 3, 1000, 1500, 2047, 2048, 2049, 4097, 123456789, 5000000000000000]),
    ?assertEqual(11, buoy_node_histogram:count(H)),
    ?assertEqual(1, buoy_node_histogram:min(H)),
    ?assertEqual(5000578883125247, buoy_node_histogram:max(H)),
    ?assertEqual(454398180301772.8, buoy_node_histogram:mean(H)),
    ?assertEqual(1436933175351203.8, buoy_node_histogram:stddev(H)),
    ?assertEqual(2047, buoy_node_histogram:percentile(H, 50.0)),
    ?assertEqual(1, buoy_node_histogram:percentile(H, 0.001)),
    ?assertEqual([{0.0, 1}, {50.0, 2047}, {75.0, 4096}, {87.5, 123404288}, {93.75, 4996180836614144},
                  {100.0, 4996180836614144}], buoy_node_histogram:percentiles(H)).

exceeds_test() ->
    H = recorded(1, 11, 1, [1, 5, 11, 12, 30]),
    ?assertEqual({3, 2}, {buoy_node_histogram:count(H), buoy_node_histogram:exceeds(H)}),
    ?assertEqual(5.666666666666667, buoy_node_histogram:mean(H)),
    ?assertEqual(4.109609335312651, buoy_node_histogram:stddev(H)),
    ?assertEqual([{0.0, 1}, {50.0, 5}, {75.0, 11}, {100.0, 11}], buoy_node_histogram:percentiles(H)).

unit_magnitude_test() ->
    H = recorded(1000, 1000000000000, 2, [I * 7919 || I <- lists:seq(1, 1000)]),
    ?assertEqual({7680, 7929855}, {buoy_node_histogram:min(H), buoy_node_histogram:max(H)}),
    ?assertEqual(3963570.688, buoy_node_histogram:mean(H)),
    ?assertEqual(2286004.0519493907, buoy_node_histogram:stddev(H)),
    ?assertEqual({3964927, 7864319, 8191}, {buoy_node_histogram:percentile(H, 50.0),
                                           buoy_node_histogram:percentile(H, 99.0),
                                           buoy_node_histogram:percentile(H, 0.001)}),
    ?assertEqual([{0.0, 7680}, {50.0, 3948544}, {75.0, 5931008}, {87.5, 6914048}, {93.75, 7405568},
                  {96.875, 7667712}, {98.4375, 7798784}, {99.21875, 7831552}, {99.609375, 7864320},
                  {99.8046875, 7897088}, {100.0, 7897088}], buoy_node_histogram:percentiles(H)).

add_test() ->
    H = recorded(1, ?MAX_SAFE, 3, lists:seq(1, 50)),
    Sum = buoy_node_histogram:add(H, recorded(1, ?MAX_SAFE, 3, lists:seq(51, 100))),
    ?assertEqual(100, buoy_node_histogram:count(Sum)),
    ?assertEqual(50.5, buoy_node_histogram:mean(Sum)),
    ?assertEqual(28.86607004772212, buoy_node_histogram:stddev(Sum)),
    ?assertEqual([{0.0, 1}, {50.0, 50}, {75.0, 75}, {87.5, 88}, {93.75, 94}, {96.875, 97}, {98.4375, 99},
                  {99.21875, 100}, {100.0, 100}], buoy_node_histogram:percentiles(Sum)).
