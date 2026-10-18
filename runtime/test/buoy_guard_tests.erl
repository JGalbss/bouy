-module(buoy_guard_tests).
-include_lib("eunit/include/eunit.hrl").

limit_test_() ->
    Default = 4 * 1024 * 1024 * 1024,
    [
        ?_assertEqual(Default, buoy_guard:limit("")),
        ?_assertEqual(Default, buoy_guard:limit("lots")),
        ?_assertEqual(Default, buoy_guard:limit("0")),
        ?_assertEqual(Default, buoy_guard:limit("5X")),
        ?_assertEqual(1000, buoy_guard:limit("1000")),
        ?_assertEqual(128 * 1024 * 1024, buoy_guard:limit("128M")),
        ?_assertEqual(2 * 1024 * 1024 * 1024, buoy_guard:limit(" 2g "))
    ].
