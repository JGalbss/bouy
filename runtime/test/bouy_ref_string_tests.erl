-module(bouy_ref_string_tests).

-include_lib("eunit/include/eunit.hrl").

-define(EURO, {'$u16', <<16#20AC:16>>}).

boundary_test_() ->
    [?_assertEqual(<<"plain">>, bouy_ref_string:from_utf8(<<"plain">>)),
     ?_assertEqual(<<"caf", 233>>, bouy_ref_string:from_utf8(<<"café"/utf8>>)),
     ?_assertEqual(?EURO, bouy_ref_string:from_utf8(<<"€"/utf8>>)),
     ?_assertEqual({'$u16', <<16#D83D:16, 16#DE00:16>>}, bouy_ref_string:from_utf8(<<"😀"/utf8>>)),
     ?_assertEqual(<<"a", 16#FFFD/utf8>>, bouy_ref_string:to_utf8(bouy_ref_string:from_utf8(<<"a", 255>>))),
     ?_assertEqual(<<"café"/utf8>>, bouy_ref_string:to_utf8(<<"caf", 233>>)),
     ?_assertEqual(<<"€😀"/utf8>>, bouy_ref_string:to_utf8({'$u16', <<16#20AC:16, 16#D83D:16, 16#DE00:16>>})),
     %% A lone surrogate leaves as U+FFFD, as Node writes it.
     ?_assertEqual(<<16#FFFD/utf8>>, bouy_ref_string:to_utf8({'$u16', <<16#D800:16>>}))].

canonical_form_test_() ->
    Mixed = bouy_ref_string:concat(<<"é">>, ?EURO),
    [?_assertEqual({'$u16', <<233:16, 16#20AC:16>>}, Mixed),
     ?_assertEqual(<<233>>, bouy_ref_string:slice(Mixed, 0, 1)),
     ?_assertEqual(?EURO, bouy_ref_string:slice(Mixed, 1, 2)),
     ?_assertEqual(<<"ab">>, bouy_ref_string:from_units([$a, $b])),
     ?_assertEqual(<<"abc">>, bouy_ref_string:concat([<<"a">>, <<"b">>, <<"c">>])),
     ?_assertEqual(2, bouy_ref_string:length_of(Mixed)),
     ?_assertEqual(16#20AC, bouy_ref_string:unit_at(Mixed, 1))].

search_test_() ->
    %% The units 0x0041 0x4141 hold the bytes 41 41 at an odd offset: no match there.
    Hay = {'$u16', <<16#0041:16, 16#4141:16, 16#4100:16>>},
    [?_assertEqual(1, bouy_ref_string:index_of(Hay, {'$u16', <<16#4141:16>>}, 0)),
     ?_assertEqual(-1, bouy_ref_string:index_of(Hay, {'$u16', <<16#4141:16, 16#4141:16>>}, 0)),
     ?_assertEqual(0, bouy_ref_string:index_of(Hay, <<"A">>, 0)),
     ?_assertEqual(3, bouy_ref_string:index_of(<<"abc">>, <<>>, 3)),
     ?_assertEqual(-1, bouy_ref_string:index_of(<<"abc">>, ?EURO, 0))].

order_test_() ->
    [?_assertEqual(lt, bouy_ref_string:compare(<<"Z">>, <<"a">>)),
     ?_assertEqual(lt, bouy_ref_string:compare(<<233>>, ?EURO)),
     ?_assertEqual(gt, bouy_ref_string:compare({'$u16', <<16#FFFF:16>>}, {'$u16', <<16#D83D:16, 16#DE00:16>>})),
     ?_assertEqual(eq, bouy_ref_string:compare(<<"x">>, <<"x">>))].

code_points_test() ->
    S = {'$u16', <<$a:16, 16#D83D:16, 16#DE00:16, 16#D800:16>>},
    ?assertEqual([$a, 16#1F600, 16#D800], bouy_ref_string:code_points(S)),
    ?assertEqual(S, bouy_ref_string:from_code_points([$a, 16#1F600, 16#D800])).
