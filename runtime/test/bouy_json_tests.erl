-module(bouy_json_tests).

-include_lib("eunit/include/eunit.hrl").

thrown(F) ->
    try F() of
        Value -> {returned, Value}
    catch
        error:{'$throw', #{<<"name">> := Name, <<"message">> := Message}} -> <<Name/binary, ": ", Message/binary>>
    end.

%% [value, replacer, space] and the text JSON.stringify returns in Node.
stringify_cases() ->
    [
        {[null, null, undefined], <<"null"/utf8>>},
        {[null, null, 2], <<"null"/utf8>>},
        {[null, null, <<"--"/utf8>>], <<"null"/utf8>>},
        {[true, null, undefined], <<"true"/utf8>>},
        {[true, null, 2], <<"true"/utf8>>},
        {[true, null, <<"--"/utf8>>], <<"true"/utf8>>},
        {[false, null, undefined], <<"false"/utf8>>},
        {[false, null, 2], <<"false"/utf8>>},
        {[false, null, <<"--"/utf8>>], <<"false"/utf8>>},
        {[0, null, undefined], <<"0"/utf8>>},
        {[0, null, 2], <<"0"/utf8>>},
        {[0, null, <<"--"/utf8>>], <<"0"/utf8>>},
        {[-0.0, null, undefined], <<"0"/utf8>>},
        {[-0.0, null, 2], <<"0"/utf8>>},
        {[-0.0, null, <<"--"/utf8>>], <<"0"/utf8>>},
        {[1, null, undefined], <<"1"/utf8>>},
        {[1, null, 2], <<"1"/utf8>>},
        {[1, null, <<"--"/utf8>>], <<"1"/utf8>>},
        {[-1.5e0, null, undefined], <<"-1.5"/utf8>>},
        {[-1.5e0, null, 2], <<"-1.5"/utf8>>},
        {[-1.5e0, null, <<"--"/utf8>>], <<"-1.5"/utf8>>},
        {[1.0e21, null, undefined], <<"1e+21"/utf8>>},
        {[1.0e21, null, 2], <<"1e+21"/utf8>>},
        {[1.0e21, null, <<"--"/utf8>>], <<"1e+21"/utf8>>},
        {[1.0e-7, null, undefined], <<"1e-7"/utf8>>},
        {[1.0e-7, null, 2], <<"1e-7"/utf8>>},
        {[1.0e-7, null, <<"--"/utf8>>], <<"1e-7"/utf8>>},
        {['NaN', null, undefined], <<"null"/utf8>>},
        {['NaN', null, 2], <<"null"/utf8>>},
        {['NaN', null, <<"--"/utf8>>], <<"null"/utf8>>},
        {['Infinity', null, undefined], <<"null"/utf8>>},
        {['Infinity', null, 2], <<"null"/utf8>>},
        {['Infinity', null, <<"--"/utf8>>], <<"null"/utf8>>},
        {['-Infinity', null, undefined], <<"null"/utf8>>},
        {['-Infinity', null, 2], <<"null"/utf8>>},
        {['-Infinity', null, <<"--"/utf8>>], <<"null"/utf8>>},
        {[<<""/utf8>>, null, undefined], <<"\"\""/utf8>>},
        {[<<""/utf8>>, null, 2], <<"\"\""/utf8>>},
        {[<<""/utf8>>, null, <<"--"/utf8>>], <<"\"\""/utf8>>},
        {[<<"abc"/utf8>>, null, undefined], <<"\"abc\""/utf8>>},
        {[<<"abc"/utf8>>, null, 2], <<"\"abc\""/utf8>>},
        {[<<"abc"/utf8>>, null, <<"--"/utf8>>], <<"\"abc\""/utf8>>},
        {[<<"a\"b\\c\x{a}\x{d}\x{9}\x{8}\x{c}\x{1}\x{1f}\x{7f}\x{2028}\x{e9}\x{1f600}"/utf8>>, null, undefined], <<"\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u001f\x{7f}\x{2028}\x{e9}\x{1f600}\""/utf8>>},
        {[<<"a\"b\\c\x{a}\x{d}\x{9}\x{8}\x{c}\x{1}\x{1f}\x{7f}\x{2028}\x{e9}\x{1f600}"/utf8>>, null, 2], <<"\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u001f\x{7f}\x{2028}\x{e9}\x{1f600}\""/utf8>>},
        {[<<"a\"b\\c\x{a}\x{d}\x{9}\x{8}\x{c}\x{1}\x{1f}\x{7f}\x{2028}\x{e9}\x{1f600}"/utf8>>, null, <<"--"/utf8>>], <<"\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u001f\x{7f}\x{2028}\x{e9}\x{1f600}\""/utf8>>},
        {[[], null, undefined], <<"[]"/utf8>>},
        {[[], null, 2], <<"[]"/utf8>>},
        {[[], null, <<"--"/utf8>>], <<"[]"/utf8>>},
        {[#{}, null, undefined], <<"{}"/utf8>>},
        {[#{}, null, 2], <<"{}"/utf8>>},
        {[#{}, null, <<"--"/utf8>>], <<"{}"/utf8>>},
        {[[1, [2, []]], null, undefined], <<"[1,[2,[]]]"/utf8>>},
        {[[1, [2, []]], null, 2], <<"[\x{a}  1,\x{a}  [\x{a}    2,\x{a}    []\x{a}  ]\x{a}]"/utf8>>},
        {[[1, [2, []]], null, <<"--"/utf8>>], <<"[\x{a}--1,\x{a}--[\x{a}----2,\x{a}----[]\x{a}--]\x{a}]"/utf8>>},
        {[#{<<"a"/utf8>> => [1, #{<<"b"/utf8>> => 2}], <<"c"/utf8>> => <<"x"/utf8>>}, null, undefined], <<"{\"a\":[1,{\"b\":2}],\"c\":\"x\"}"/utf8>>},
        {[#{<<"a"/utf8>> => [1, #{<<"b"/utf8>> => 2}], <<"c"/utf8>> => <<"x"/utf8>>}, null, 2], <<"{\x{a}  \"a\": [\x{a}    1,\x{a}    {\x{a}      \"b\": 2\x{a}    }\x{a}  ],\x{a}  \"c\": \"x\"\x{a}}"/utf8>>},
        {[#{<<"a"/utf8>> => [1, #{<<"b"/utf8>> => 2}], <<"c"/utf8>> => <<"x"/utf8>>}, null, <<"--"/utf8>>], <<"{\x{a}--\"a\": [\x{a}----1,\x{a}----{\x{a}------\"b\": 2\x{a}----}\x{a}--],\x{a}--\"c\": \"x\"\x{a}}"/utf8>>},
        {[[undefined, null, 'NaN'], null, undefined], <<"[null,null,null]"/utf8>>},
        {[[undefined, null, 'NaN'], null, 2], <<"[\x{a}  null,\x{a}  null,\x{a}  null\x{a}]"/utf8>>},
        {[[undefined, null, 'NaN'], null, <<"--"/utf8>>], <<"[\x{a}--null,\x{a}--null,\x{a}--null\x{a}]"/utf8>>},
        {[#{<<"a"/utf8>> => undefined, <<"b"/utf8>> => null, <<"c"/utf8>> => 1}, null, undefined], <<"{\"b\":null,\"c\":1}"/utf8>>},
        {[#{<<"a"/utf8>> => undefined, <<"b"/utf8>> => null, <<"c"/utf8>> => 1}, null, 2], <<"{\x{a}  \"b\": null,\x{a}  \"c\": 1\x{a}}"/utf8>>},
        {[#{<<"a"/utf8>> => undefined, <<"b"/utf8>> => null, <<"c"/utf8>> => 1}, null, <<"--"/utf8>>], <<"{\x{a}--\"b\": null,\x{a}--\"c\": 1\x{a}}"/utf8>>},
        {[#{<<""/utf8>> => 1, <<"\x{e9}"/utf8>> => #{<<"\x{1f600}"/utf8>> => []}}, null, undefined], <<"{\"\":1,\"\x{e9}\":{\"\x{1f600}\":[]}}"/utf8>>},
        {[#{<<""/utf8>> => 1, <<"\x{e9}"/utf8>> => #{<<"\x{1f600}"/utf8>> => []}}, null, 2], <<"{\x{a}  \"\": 1,\x{a}  \"\x{e9}\": {\x{a}    \"\x{1f600}\": []\x{a}  }\x{a}}"/utf8>>},
        {[#{<<""/utf8>> => 1, <<"\x{e9}"/utf8>> => #{<<"\x{1f600}"/utf8>> => []}}, null, <<"--"/utf8>>], <<"{\x{a}--\"\": 1,\x{a}--\"\x{e9}\": {\x{a}----\"\x{1f600}\": []\x{a}--}\x{a}}"/utf8>>},
        {[bouy_map:new([[[1, 2]]]), null, undefined], <<"{}"/utf8>>},
        {[bouy_map:new([[[1, 2]]]), null, 2], <<"{}"/utf8>>},
        {[bouy_map:new([[[1, 2]]]), null, <<"--"/utf8>>], <<"{}"/utf8>>},
        {[bouy_set:new([[1]]), null, undefined], <<"{}"/utf8>>},
        {[bouy_set:new([[1]]), null, 2], <<"{}"/utf8>>},
        {[bouy_set:new([[1]]), null, <<"--"/utf8>>], <<"{}"/utf8>>},
        {[{'$date', 0}, null, undefined], <<"\"1970-01-01T00:00:00.000Z\""/utf8>>},
        {[{'$date', 0}, null, 2], <<"\"1970-01-01T00:00:00.000Z\""/utf8>>},
        {[{'$date', 0}, null, <<"--"/utf8>>], <<"\"1970-01-01T00:00:00.000Z\""/utf8>>},
        {[{'$date', 1700000000123}, null, undefined], <<"\"2023-11-14T22:13:20.123Z\""/utf8>>},
        {[{'$date', 1700000000123}, null, 2], <<"\"2023-11-14T22:13:20.123Z\""/utf8>>},
        {[{'$date', 1700000000123}, null, <<"--"/utf8>>], <<"\"2023-11-14T22:13:20.123Z\""/utf8>>},
        {[bouy_error:new(<<"Error"/utf8>>, <<"x"/utf8>>, #{<<"code"/utf8>> => 7}), null, undefined], <<"{\"code\":7}"/utf8>>},
        {[bouy_error:new(<<"Error"/utf8>>, <<"x"/utf8>>, #{<<"code"/utf8>> => 7}), null, 2], <<"{\x{a}  \"code\": 7\x{a}}"/utf8>>},
        {[bouy_error:new(<<"Error"/utf8>>, <<"x"/utf8>>, #{<<"code"/utf8>> => 7}), null, <<"--"/utf8>>], <<"{\x{a}--\"code\": 7\x{a}}"/utf8>>},
        {[[#{<<"id"/utf8>> => 0, <<"name"/utf8>> => <<"n0"/utf8>>}, #{<<"id"/utf8>> => 1, <<"name"/utf8>> => <<"n1"/utf8>>}, #{<<"id"/utf8>> => 2, <<"name"/utf8>> => <<"n2"/utf8>>}, #{<<"id"/utf8>> => 3, <<"name"/utf8>> => <<"n3"/utf8>>}, #{<<"id"/utf8>> => 4, <<"name"/utf8>> => <<"n4"/utf8>>}, #{<<"id"/utf8>> => 5, <<"name"/utf8>> => <<"n5"/utf8>>}, #{<<"id"/utf8>> => 6, <<"name"/utf8>> => <<"n6"/utf8>>}, #{<<"id"/utf8>> => 7, <<"name"/utf8>> => <<"n7"/utf8>>}, #{<<"id"/utf8>> => 8, <<"name"/utf8>> => <<"n8"/utf8>>}, #{<<"id"/utf8>> => 9, <<"name"/utf8>> => <<"n9"/utf8>>}, #{<<"id"/utf8>> => 10, <<"name"/utf8>> => <<"n10"/utf8>>}, #{<<"id"/utf8>> => 11, <<"name"/utf8>> => <<"n11"/utf8>>}], null, undefined], <<"[{\"id\":0,\"name\":\"n0\"},{\"id\":1,\"name\":\"n1\"},{\"id\":2,\"name\":\"n2\"},{\"id\":3,\"name\":\"n3\"},{\"id\":4,\"name\":\"n4\"},{\"id\":5,\"name\":\"n5\"},{\"id\":6,\"name\":\"n6\"},{\"id\":7,\"name\":\"n7\"},{\"id\":8,\"name\":\"n8\"},{\"id\":9,\"name\":\"n9\"},{\"id\":10,\"name\":\"n10\"},{\"id\":11,\"name\":\"n11\"}]"/utf8>>},
        {[[#{<<"id"/utf8>> => 0, <<"name"/utf8>> => <<"n0"/utf8>>}, #{<<"id"/utf8>> => 1, <<"name"/utf8>> => <<"n1"/utf8>>}, #{<<"id"/utf8>> => 2, <<"name"/utf8>> => <<"n2"/utf8>>}, #{<<"id"/utf8>> => 3, <<"name"/utf8>> => <<"n3"/utf8>>}, #{<<"id"/utf8>> => 4, <<"name"/utf8>> => <<"n4"/utf8>>}, #{<<"id"/utf8>> => 5, <<"name"/utf8>> => <<"n5"/utf8>>}, #{<<"id"/utf8>> => 6, <<"name"/utf8>> => <<"n6"/utf8>>}, #{<<"id"/utf8>> => 7, <<"name"/utf8>> => <<"n7"/utf8>>}, #{<<"id"/utf8>> => 8, <<"name"/utf8>> => <<"n8"/utf8>>}, #{<<"id"/utf8>> => 9, <<"name"/utf8>> => <<"n9"/utf8>>}, #{<<"id"/utf8>> => 10, <<"name"/utf8>> => <<"n10"/utf8>>}, #{<<"id"/utf8>> => 11, <<"name"/utf8>> => <<"n11"/utf8>>}], null, 2], <<"[\x{a}  {\x{a}    \"id\": 0,\x{a}    \"name\": \"n0\"\x{a}  },\x{a}  {\x{a}    \"id\": 1,\x{a}    \"name\": \"n1\"\x{a}  },\x{a}  {\x{a}    \"id\": 2,\x{a}    \"name\": \"n2\"\x{a}  },\x{a}  {\x{a}    \"id\": 3,\x{a}    \"name\": \"n3\"\x{a}  },\x{a}  {\x{a}    \"id\": 4,\x{a}    \"name\": \"n4\"\x{a}  },\x{a}  {\x{a}    \"id\": 5,\x{a}    \"name\": \"n5\"\x{a}  },\x{a}  {\x{a}    \"id\": 6,\x{a}    \"name\": \"n6\"\x{a}  },\x{a}  {\x{a}    \"id\": 7,\x{a}    \"name\": \"n7\"\x{a}  },\x{a}  {\x{a}    \"id\": 8,\x{a}    \"name\": \"n8\"\x{a}  },\x{a}  {\x{a}    \"id\": 9,\x{a}    \"name\": \"n9\"\x{a}  },\x{a}  {\x{a}    \"id\": 10,\x{a}    \"name\": \"n10\"\x{a}  },\x{a}  {\x{a}    \"id\": 11,\x{a}    \"name\": \"n11\"\x{a}  }\x{a}]"/utf8>>},
        {[[#{<<"id"/utf8>> => 0, <<"name"/utf8>> => <<"n0"/utf8>>}, #{<<"id"/utf8>> => 1, <<"name"/utf8>> => <<"n1"/utf8>>}, #{<<"id"/utf8>> => 2, <<"name"/utf8>> => <<"n2"/utf8>>}, #{<<"id"/utf8>> => 3, <<"name"/utf8>> => <<"n3"/utf8>>}, #{<<"id"/utf8>> => 4, <<"name"/utf8>> => <<"n4"/utf8>>}, #{<<"id"/utf8>> => 5, <<"name"/utf8>> => <<"n5"/utf8>>}, #{<<"id"/utf8>> => 6, <<"name"/utf8>> => <<"n6"/utf8>>}, #{<<"id"/utf8>> => 7, <<"name"/utf8>> => <<"n7"/utf8>>}, #{<<"id"/utf8>> => 8, <<"name"/utf8>> => <<"n8"/utf8>>}, #{<<"id"/utf8>> => 9, <<"name"/utf8>> => <<"n9"/utf8>>}, #{<<"id"/utf8>> => 10, <<"name"/utf8>> => <<"n10"/utf8>>}, #{<<"id"/utf8>> => 11, <<"name"/utf8>> => <<"n11"/utf8>>}], null, <<"--"/utf8>>], <<"[\x{a}--{\x{a}----\"id\": 0,\x{a}----\"name\": \"n0\"\x{a}--},\x{a}--{\x{a}----\"id\": 1,\x{a}----\"name\": \"n1\"\x{a}--},\x{a}--{\x{a}----\"id\": 2,\x{a}----\"name\": \"n2\"\x{a}--},\x{a}--{\x{a}----\"id\": 3,\x{a}----\"name\": \"n3\"\x{a}--},\x{a}--{\x{a}----\"id\": 4,\x{a}----\"name\": \"n4\"\x{a}--},\x{a}--{\x{a}----\"id\": 5,\x{a}----\"name\": \"n5\"\x{a}--},\x{a}--{\x{a}----\"id\": 6,\x{a}----\"name\": \"n6\"\x{a}--},\x{a}--{\x{a}----\"id\": 7,\x{a}----\"name\": \"n7\"\x{a}--},\x{a}--{\x{a}----\"id\": 8,\x{a}----\"name\": \"n8\"\x{a}--},\x{a}--{\x{a}----\"id\": 9,\x{a}----\"name\": \"n9\"\x{a}--},\x{a}--{\x{a}----\"id\": 10,\x{a}----\"name\": \"n10\"\x{a}--},\x{a}--{\x{a}----\"id\": 11,\x{a}----\"name\": \"n11\"\x{a}--}\x{a}]"/utf8>>},
        {[#{<<"nested"/utf8>> => #{<<"deeper"/utf8>> => #{<<"deepest"/utf8>> => [1, 2, #{<<"x"/utf8>> => []}]}}}, null, undefined], <<"{\"nested\":{\"deeper\":{\"deepest\":[1,2,{\"x\":[]}]}}}"/utf8>>},
        {[#{<<"nested"/utf8>> => #{<<"deeper"/utf8>> => #{<<"deepest"/utf8>> => [1, 2, #{<<"x"/utf8>> => []}]}}}, null, 2], <<"{\x{a}  \"nested\": {\x{a}    \"deeper\": {\x{a}      \"deepest\": [\x{a}        1,\x{a}        2,\x{a}        {\x{a}          \"x\": []\x{a}        }\x{a}      ]\x{a}    }\x{a}  }\x{a}}"/utf8>>},
        {[#{<<"nested"/utf8>> => #{<<"deeper"/utf8>> => #{<<"deepest"/utf8>> => [1, 2, #{<<"x"/utf8>> => []}]}}}, null, <<"--"/utf8>>], <<"{\x{a}--\"nested\": {\x{a}----\"deeper\": {\x{a}------\"deepest\": [\x{a}--------1,\x{a}--------2,\x{a}--------{\x{a}----------\"x\": []\x{a}--------}\x{a}------]\x{a}----}\x{a}--}\x{a}}"/utf8>>}
    ].

stringify_test_() ->
    [?_assertEqual(Expected, bouy_json:stringify(Args)) || {Args, Expected} <- stringify_cases()].

gap_test_() ->
    Value = #{<<"a">> => [1]},
    [
        ?_assertEqual(<<"{\n          \"a\": [\n                    1\n          ]\n}">>, bouy_json:stringify([Value, null, 20])),
        ?_assertEqual(<<"{\"a\":[1]}">>, bouy_json:stringify([Value, null, 0])),
        ?_assertEqual(<<"{\nabcdefghij\"a\": [\nabcdefghijabcdefghij1\nabcdefghij]\n}">>, bouy_json:stringify([Value, null, <<"abcdefghijklmnop">>])),
        ?_assertEqual(<<"{\"a\":5}">>, bouy_json:stringify([#{<<"a">> => #{<<"toJSON">> => fun([<<"a">>]) -> 5 end}}])),
        ?_assertEqual(undefined, bouy_json:stringify([fun(_) -> 1 end])),
        ?_assertEqual(<<"TypeError: JSON.stringify supports no replacer: pass null">>, thrown(fun() -> bouy_json:stringify([1, [<<"a">>]]) end))
    ].

%% Text and the value JSON.parse returns in Node.
parse_cases() ->
    [
        {[<<"{\"a\":1,\"b\":[true,false,null],\"c\":\"x\"}"/utf8>>], #{<<"a"/utf8>> => 1, <<"b"/utf8>> => [true, false, null], <<"c"/utf8>> => <<"x"/utf8>>}},
        {[<<"[1, 1.0, 1e2, -0, 1.5e400, -1e400, 12345678901234567890, 0.1, 1E-2]"/utf8>>], [1, 1, 100, -0.0, 'Infinity', '-Infinity', 1.2345678901234567e19, 1.0e-1, 1.0e-2]},
        {[<<"\"\\u00e9\\n\\ud83d\\ude00\""/utf8>>], <<"\x{e9}\x{a}\x{1f600}"/utf8>>},
        {[<<" {\"a\" : { \"b\" : [ ] } } "/utf8>>], #{<<"a"/utf8>> => #{<<"b"/utf8>> => []}}},
        {[<<"{\"a\":1,\"a\":2}"/utf8>>], #{<<"a"/utf8>> => 2}},
        {[<<"{\"z\":1,\"a\":2}"/utf8>>], #{<<"z"/utf8>> => 1, <<"a"/utf8>> => 2}},
        {[<<"3"/utf8>>], 3},
        {[<<"\"x\""/utf8>>], <<"x"/utf8>>},
        {[<<"null"/utf8>>], null},
        {[<<"[]"/utf8>>], []},
        {[<<"{}"/utf8>>], #{}},
        {[<<"-12"/utf8>>], -12},
        {[<<"9007199254740993"/utf8>>], 9007199254740992}
    ].

parse_test_() ->
    [?_assert(bouy_rt:strict_eq(Expected, bouy_json:parse(Args))) || {Args, Expected} <- parse_cases()] ++
        [
            %% OTP json drops the sign of -0 and -0e0. JavaScript keeps it:
            %% node -e 'console.log(1 / JSON.parse("-0"), 1 / JSON.parse("[-0e0]")[0])'
            ?_assert(is_negative_zero(bouy_json:parse([<<"-0">>]))),
            ?_assert(is_negative_zero(hd(bouy_json:parse([<<"[-0e0]">>])))),
            ?_assert(is_negative_zero(hd(bouy_json:parse([<<"[-0E2, 1]">>])))),
            ?_assertEqual([<<"-0">>, 0], bouy_json:parse([<<"[\"-0\", 0]">>])),
            ?_assertEqual(-0.5, bouy_json:parse([<<"-0.5">>])),
            ?_assertEqual(#{<<"a">> => 2}, bouy_json:parse([<<"{\"a\":1,\"a\":2}">>])),
            ?_assertEqual(<<"TypeError: JSON.parse supports no reviver">>, thrown(fun() -> bouy_json:parse([<<"1">>, fun(_) -> 1 end]) end))
        ].

%% Error messages that match V8. V8 words other syntax errors by position.
error_test_() ->
    [
        ?_assertEqual(<<"SyntaxError: Unexpected token 'x', \"xyz\" is not valid JSON">>, thrown(fun() -> bouy_json:parse([<<"xyz">>]) end)),
        ?_assertEqual(<<"SyntaxError: Unexpected token ']', \"[1,]\" is not valid JSON">>, thrown(fun() -> bouy_json:parse([<<"[1,]">>]) end)),
        ?_assertEqual(<<"SyntaxError: Unexpected end of JSON input">>, thrown(fun() -> bouy_json:parse([<<>>]) end)),
        ?_assertEqual(<<"SyntaxError: \"undefined\" is not valid JSON">>, thrown(fun() -> bouy_json:parse([undefined]) end)),
        ?_assertMatch(<<"SyntaxError: ", _/binary>>, thrown(fun() -> bouy_json:parse([<<"1 2">>]) end)),
        ?_assertMatch(<<"SyntaxError: ", _/binary>>, thrown(fun() -> bouy_json:parse([<<"{">>]) end))
    ].

members_test_() ->
    [
        ?_assertEqual(<<"[1]">>, bouy_rt:call(bouy_json:'$member'(<<"stringify">>), [[1]])),
        ?_assertEqual(undefined, bouy_json:'$member'(<<"rawJSON">>))
    ].

is_negative_zero(F) -> is_float(F) andalso F == 0 andalso <<F/float>> =:= <<(-0.0)/float>>.

%% node -e 'console.log(JSON.stringify({ a: 1 }, null, "→→→→"), JSON.stringify({ a: 1 }, null, Infinity))'
indent_text_test_() ->
    [
        ?_assertEqual(<<"{\n→→→→\"a\": 1\n}"/utf8>>, bouy_json:stringify([#{<<"a">> => 1}, null, <<"→→→→"/utf8>>])),
        ?_assertEqual(<<"{\néééééééééé\"a\": 1\n}"/utf8>>, bouy_json:stringify([#{<<"a">> => 1}, null, <<"éééééééééééé"/utf8>>])),
        ?_assertEqual(<<"{\n          \"a\": 1\n}">>, bouy_json:stringify([#{<<"a">> => 1}, null, 'Infinity']))
    ].

%% A reviver or replacer that is not callable is ignored, so that
%% `lines.map(JSON.parse)` and `xs.map(JSON.stringify)` work.
uncallable_test_() ->
    [
        ?_assertEqual(#{<<"a">> => 1}, bouy_json:parse([<<"{\"a\":1}">>, 0, [<<"{\"a\":1}">>]])),
        ?_assertEqual(<<"[1,2]">>, bouy_json:stringify([[1, 2], 0, [[1, 2]]])),
        ?_assertEqual(<<"TypeError: JSON.stringify supports no replacer: pass null">>, thrown(fun() -> bouy_json:stringify([1, fun(_) -> 1 end]) end)),
        ?_assertEqual(<<"TypeError: JSON.stringify supports no replacer: pass null">>, thrown(fun() -> bouy_json:stringify([1, [<<"a">>]]) end))
    ].

%% node -e 'console.log(JSON.parse(String.raw`"\ud800"`).length)': UTF-8 cannot hold a lone
%% surrogate, so it becomes U+FFFD, and a message never splits a character.
surrogate_test_() ->
    [
        ?_assertEqual(<<16#FFFD/utf8>>, bouy_json:parse([<<"\"\\ud800\"">>])),
        ?_assertEqual(<<"a", 16#FFFD/utf8, "b">>, bouy_json:parse([<<"\"a\\udc00b\"">>])),
        ?_assertEqual(<<"😀"/utf8>>, bouy_json:parse([<<"\"\\ud83d\\ude00\"">>])),
        ?_assertEqual(<<"\\ud800">>, bouy_json:parse([<<"\"\\\\ud800\"">>])),
        ?_assertEqual(<<"SyntaxError: Unexpected token 'é', \"é\" is not valid JSON"/utf8>>, thrown(fun() -> bouy_json:parse([<<"é"/utf8>>]) end)),
        ?_assertEqual(<<"SyntaxError: Unexpected token '€', \"[1]€\" is not valid JSON"/utf8>>, thrown(fun() -> bouy_json:parse([<<"[1]€"/utf8>>]) end))
    ].
