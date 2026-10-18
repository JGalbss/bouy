-module(buoy_date_tests).

-include_lib("eunit/include/eunit.hrl").

thrown(F) ->
    try F() of
        Value -> {returned, Value}
    catch
        error:{'$throw', #{<<"name">> := Name, <<"message">> := Message}} -> <<Name/binary, ": ", Message/binary>>
    end.

d(Method, Date) -> buoy_date:call(Method, Date, []).

now_test_() ->
    Before = erlang:system_time(millisecond),
    Now = buoy_date:now([]),
    {'$date', Time} = buoy_date:new([]),
    [
        ?_assert(is_integer(Now)),
        ?_assert(Now >= Before),
        ?_assert(Time >= Now),
        ?_assert(is_integer(buoy_rt:call(buoy_date:'$member'(<<"now">>), [])))
    ].

%% performance.now(): milliseconds since the VM started, a float that never
%% decreases.
performance_now_test() ->
    First = buoy_performance:now([]),
    Second = buoy_rt:call(buoy_performance:'$member'(<<"now">>), []),
    ?assert(is_float(First)),
    ?assert(First >= 0),
    ?assert(Second >= First),
    ?assert(First =< element(1, erlang:statistics(wall_clock)) + 1).

construct_test_() ->
    [
        ?_assertEqual(<<"1970-01-01T00:00:00.000Z">>, d(<<"toISOString">>, buoy_date:new([0]))),
        ?_assertEqual(86400000, d(<<"getTime">>, buoy_date:new([86400000.7]))),
        ?_assertEqual(<<"2024-03-05T00:00:00.000Z">>, d(<<"toISOString">>, buoy_date:new([<<"2024-03-05">>]))),
        ?_assertEqual(1709634030000, d(<<"getTime">>, buoy_date:new([<<"2024-03-05T10:20:30Z">>]))),
        ?_assertEqual(<<"2024-03-05T08:20:30.500Z">>, d(<<"toISOString">>, buoy_date:new([<<"2024-03-05T10:20:30.5+02:00">>]))),
        ?_assertEqual(1709634030000, d(<<"valueOf">>, buoy_date:new([buoy_date:new([1709634030000])]))),
        ?_assertEqual('NaN', d(<<"getTime">>, buoy_date:new([1.0e20]))),
        ?_assertEqual('NaN', d(<<"getTime">>, buoy_date:new(['NaN']))),
        ?_assertEqual('NaN', d(<<"getTime">>, buoy_date:new([<<"garbage">>]))),
        ?_assertEqual(<<"TypeError: new Date(year, month, ...) is not supported by Buoy">>, thrown(fun() -> buoy_date:new([2024, 1]) end))
    ].

format_test_() ->
    Invalid = buoy_date:new([<<"garbage">>]),
    [
        %% TZ=UTC node -e 'console.log(new Date(0).toString())'
        ?_assertEqual(<<"Thu Jan 01 1970 00:00:00 GMT+0000 (Coordinated Universal Time)">>, buoy_date:to_string(buoy_date:new([0]))),
        ?_assertEqual(<<"Tue Feb 29 2000 00:00:00 GMT+0000 (Coordinated Universal Time)">>, d(<<"toString">>, buoy_date:new([951782400000]))),
        ?_assertEqual(<<"Invalid Date">>, buoy_rt:to_string(Invalid)),
        ?_assertEqual(<<"RangeError: Invalid time value">>, thrown(fun() -> d(<<"toISOString">>, Invalid) end)),
        ?_assertEqual(null, d(<<"toJSON">>, Invalid)),
        ?_assertEqual(<<"\"1970-01-01T00:00:00.000Z\"">>, buoy_json:stringify([buoy_date:new([0])])),
        ?_assertEqual(<<"1970-01-01T00:00:00.000Z">>, buoy_console:format([buoy_date:new([0])])),
        ?_assertMatch(<<_:3/binary, " ", _/binary>>, buoy_date:'$call'([])),
        ?_assertEqual(<<"TypeError: Date.prototype.getFullYear is not supported by Buoy">>, thrown(fun() -> d(<<"getFullYear">>, buoy_date:new([0])) end))
    ].

arithmetic_test_() ->
    [
        ?_assertEqual(1000, buoy_rt:sub(buoy_date:new([2000]), buoy_date:new([1000]))),
        ?_assert(buoy_rt:lt(buoy_date:new([1]), buoy_date:new([2]))),
        ?_assert(buoy_rt:instance_of(buoy_date:new([0]), {'$namespace', buoy_date}))
    ].

%% TZ=UTC node -e 'for (const t of [-62198755200000, 253402300800000, 8.64e15, -8.64e15]) console.log(String(new Date(t)), new Date(t).toISOString())'
years_test_() ->
    Cases = [
        {-62198755200000, <<"Fri Jan 01 -0001 00:00:00 GMT+0000 (Coordinated Universal Time)">>, <<"-000001-01-01T00:00:00.000Z">>},
        {253402300800000, <<"Sat Jan 01 10000 00:00:00 GMT+0000 (Coordinated Universal Time)">>, <<"+010000-01-01T00:00:00.000Z">>},
        {8640000000000000, <<"Sat Sep 13 275760 00:00:00 GMT+0000 (Coordinated Universal Time)">>, <<"+275760-09-13T00:00:00.000Z">>},
        {-8640000000000000, <<"Tue Apr 20 -271821 00:00:00 GMT+0000 (Coordinated Universal Time)">>, <<"-271821-04-20T00:00:00.000Z">>}
    ],
    [?_assertEqual({Text, Iso}, {buoy_date:to_string({'$date', Ms}), d(<<"toISOString">>, {'$date', Ms})}) || {Ms, Text, Iso} <- Cases].

%% TZ=UTC node -e 'for (const s of process.argv.slice(1)) console.log(new Date(s).getTime())' ...
parse_test_() ->
    Cases = [
        {<<"2020">>, 1577836800000}, {<<"2020-06">>, 1590969600000}, {<<"2020-01-01T10:20Z">>, 1577874000000},
        {<<"2020-13-01">>, 'NaN'}, {<<"2020-01-32">>, 'NaN'}, {<<"2020-02-30">>, 1583020800000},
        {<<"2020-01-01T24:00:00Z">>, 1577923200000}, {<<"2020-01-01T24:00:01Z">>, 'NaN'},
        {<<"2020-01-01T10:20:30+25:00">>, 'NaN'}, {<<"2020-01-01T10:20:30-0530">>, 1577893830000},
        {<<"2020-01-01T10:20:30.123456Z">>, 1577874030123}, {<<"2020-01-01T10:20:30.Z">>, 'NaN'},
        {<<"2020-01-01 10:20:30z">>, 1577874030000}, {<<"+275760-09-13T00:00:00.001Z">>, 'NaN'},
        {<<"-000000-01-01T00:00:00Z">>, 'NaN'}, {<<"20200101">>, 'NaN'}
    ],
    [?_assertEqual({Text, Ms}, {Text, d(<<"getTime">>, buoy_date:new([Text]))}) || {Text, Ms} <- Cases].
