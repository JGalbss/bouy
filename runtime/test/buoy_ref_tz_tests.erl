-module(buoy_ref_tz_tests).

-include_lib("eunit/include/eunit.hrl").

posix_rule_test() ->
    {ok, Rule} = buoy_ref_tz:parse_posix(<<"EST5EDT,M3.2.0,M11.1.0">>),
    ?assertMatch({dst, {-18000000, <<"EST">>}, {-14400000, <<"EDT">>}, _, _}, Rule),
    ?assertEqual({ok, {fixed, 0, <<"UTC">>}}, buoy_ref_tz:parse_posix(<<"UTC0">>)),
    ?assertEqual({ok, {fixed, 19800000, <<"+0530">>}}, buoy_ref_tz:parse_posix(<<"<+0530>-5:30">>)),
    ?assertEqual(error, buoy_ref_tz:parse_posix(<<"1">>)).

%% New York under its POSIX rule: the offsets on each side of the changes,
%% the gap that moves a local time forward, and the overlap that takes the
%% earlier instant.
dst_rule_test() ->
    with_tz("EST5EDT,M3.2.0,M11.1.0", fun() ->
        Summer = 1625140800000, % 2021-07-01T12:00:00Z
        ?assertMatch({-14400000, true, <<"EDT">>}, buoy_ref_tz:offset(Summer)),
        ?assertMatch({-18000000, false, <<"EST">>}, buoy_ref_tz:offset(1609502400000)),
        %% 2021-03-14T02:30 local does not exist: it is 03:30 EDT, 07:30Z.
        ?assertEqual(1615707000000, buoy_ref_tz:local_to_utc(1615689000000)),
        %% 2021-11-07T01:30 local happens twice: the EDT one, 05:30Z, wins.
        ?assertEqual(1636263000000, buoy_ref_tz:local_to_utc(1636248600000)),
        ?assertEqual(<<"Eastern Daylight Time">>, buoy_ref_tz:name(Summer))
    end).

date_text_test() ->
    with_tz("UTC0", fun() ->
        T = 1792242309007, % 2026-10-17T13:05:09.007Z
        ?assertEqual(T, buoy_ref_date:parse(<<"2026-10-17T13:05:09.007Z">>)),
        ?assertEqual(T - 7, buoy_ref_date:parse(<<"Sat, 17 Oct 2026 13:05:09 GMT">>)),
        ?assertEqual(T - 7, buoy_ref_date:parse(<<"Sat Oct 17 2026 13:05:09 GMT+0000 (Coordinated Universal Time)">>)),
        ?assertEqual('NaN', buoy_ref_date:parse(<<"-000000-01-01T00:00:00Z">>)),
        ?assertEqual(8640000000000000, buoy_ref_date:parse(<<"+275760-09-13T00:00:00.000Z">>)),
        ?assertEqual(<<"2026-10-17T13:05:09.007Z">>, buoy_ref_date:to_iso_string(T)),
        ?assertEqual(<<"-271821-04-20T00:00:00.000Z">>, buoy_ref_date:to_iso_string(-8640000000000000))
    end).

%% Temporal names a zone of the tz database in any case. A link resolves to
%% its target, the zones of UTC to "UTC", and other text to no zone.
named_zone_test() ->
    ?assertEqual({ok, <<"America/New_York">>}, buoy_ref_tz:named(<<"AMERICA/NEW_YORK">>)),
    ?assertEqual({ok, <<"America/New_York">>}, buoy_ref_tz:named(<<"US/Eastern">>)),
    ?assertEqual({ok, <<"UTC">>}, buoy_ref_tz:named(<<"etc/utc">>)),
    ?assertEqual(error, buoy_ref_tz:named(<<"Mars/Olympus_Mons">>)),
    ?assertEqual(error, buoy_ref_tz:named(<<"../../../etc/passwd">>)),
    ?assertEqual(-14400000, buoy_ref_tz:offset_in(<<"America/New_York">>, 1625140800000)),
    ?assertEqual(-18000000, buoy_ref_tz:offset_in(<<"America/New_York">>, 1609502400000)),
    ?assertEqual({-1, 12, 31}, buoy_ref_tz:civil_from_days(-719529)).

system_zone_test() ->
    with_tz("Europe/Paris", fun() -> ?assertEqual(<<"Europe/Paris">>, buoy_ref_tz:system_id()) end),
    with_tz(":Asia/Tokyo", fun() -> ?assertEqual(<<"Asia/Tokyo">>, buoy_ref_tz:system_id()) end),
    with_tz("<+0530>-5:30", fun() -> ?assertEqual(<<"UTC">>, buoy_ref_tz:system_id()) end).

with_tz(Tz, Test) ->
    Old = os:getenv("TZ"),
    os:putenv("TZ", Tz),
    try Test()
    after
        case Old of
            false -> os:unsetenv("TZ");
            _ -> os:putenv("TZ", Old)
        end
    end.
