-module(bouy_guard_tests).
-include_lib("eunit/include/eunit.hrl").

limit_test_() ->
    Default = 4 * 1024 * 1024 * 1024,
    [
        ?_assertEqual(Default, bouy_guard:limit("")),
        ?_assertEqual(Default, bouy_guard:limit("lots")),
        ?_assertEqual(Default, bouy_guard:limit("0")),
        ?_assertEqual(Default, bouy_guard:limit("5X")),
        ?_assertEqual(1000, bouy_guard:limit("1000")),
        ?_assertEqual(128 * 1024 * 1024, bouy_guard:limit("128M")),
        ?_assertEqual(2 * 1024 * 1024 * 1024, bouy_guard:limit(" 2g "))
    ].
