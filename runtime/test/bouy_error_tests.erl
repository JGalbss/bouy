-module(bouy_error_tests).

-include_lib("eunit/include/eunit.hrl").

new_test_() ->
    Error = bouy_error:new(<<"TypeError">>, <<"bad">>),
    Tagged = bouy_error:new(<<"NotFound">>, <<"missing">>, #{<<"_tag">> => <<"NotFound">>, <<"id">> => 7}),
    [
        ?_assertMatch(#{<<"$error">> := true, <<"name">> := <<"TypeError">>, <<"message">> := <<"bad">>}, Error),
        ?_assertMatch(<<"TypeError: bad\n    at ", _/binary>>, maps:get(<<"stack">>, Error)),
        ?_assertEqual(<<"NotFound">>, maps:get(<<"_tag">>, Tagged)),
        ?_assertEqual(7, bouy_error:get(Tagged, <<"id">>)),
        ?_assertEqual(undefined, bouy_error:get(Tagged, <<"nope">>)),
        ?_assertEqual(#{<<"_tag">> => <<"NotFound">>, <<"id">> => 7}, bouy_error:fields(Tagged))
    ].

throw_test_() ->
    [
        ?_assertError({'$throw', #{<<"name">> := <<"RangeError">>, <<"message">> := <<"r">>}}, bouy_error:throw(<<"RangeError">>, <<"r">>)),
        ?_assertError({'$throw', #{<<"code">> := 1}}, bouy_error:throw(<<"Error">>, <<"e">>, #{<<"code">> => 1}))
    ].

constructors_test_() ->
    WithCause = bouy_error:'Error#new'([<<"outer">>, #{<<"cause">> => <<"inner">>}]),
    [
        ?_assertMatch(#{<<"name">> := <<"Error">>, <<"message">> := <<"boom">>}, bouy_error:'Error#new'([<<"boom">>])),
        ?_assertMatch(#{<<"message">> := <<>>}, bouy_error:'Error#new'([])),
        ?_assertMatch(#{<<"message">> := <<"42">>}, bouy_error:'Error#new'([42])),
        ?_assertMatch(#{<<"name">> := <<"TypeError">>}, bouy_error:'TypeError#new'([<<"t">>])),
        ?_assertMatch(#{<<"name">> := <<"RangeError">>}, bouy_error:'RangeError#new'([<<"r">>])),
        ?_assertMatch(#{<<"name">> := <<"SyntaxError">>}, bouy_error:'SyntaxError#new'([<<"s">>])),
        ?_assertEqual(<<"inner">>, bouy_error:get(WithCause, <<"cause">>)),
        ?_assertEqual(#{}, bouy_error:fields(WithCause))
    ].

to_string_test_() ->
    [
        ?_assertEqual(<<"Error: boom">>, bouy_error:to_string(bouy_error:new(<<"Error">>, <<"boom">>))),
        ?_assertEqual(<<"Error">>, bouy_error:to_string(bouy_error:new(<<"Error">>, <<>>))),
        ?_assertEqual(<<"just message">>, bouy_error:to_string(bouy_error:new(<<>>, <<"just message">>))),
        ?_assertEqual(<<"TypeError: x">>, bouy_error:call(<<"toString">>, bouy_error:new(<<"TypeError">>, <<"x">>), []))
    ].

from_erlang_test_() ->
    Message = fun(Reason) -> maps:get(<<"message">>, bouy_error:from_erlang(Reason, [{m, f, 1, [{file, "m.erl"}, {line, 3}]}])) end,
    [
        ?_assertEqual(<<"bad argument in an arithmetic expression">>, Message(badarith)),
        ?_assertEqual(<<"bad argument in m:f/1">>, Message(badarg)),
        ?_assertEqual(<<"no function clause matching in m:f/1">>, Message(function_clause)),
        ?_assertEqual(<<"no case clause matching {a,1}">>, Message({case_clause, {a, 1}})),
        ?_assertEqual(<<"undefined function in m:f/1">>, Message(undef)),
        ?_assertEqual(<<"key <<\"k\">> not found">>, Message({badkey, <<"k">>})),
        ?_assertEqual(<<"{custom,reason}">>, Message({custom, reason})),
        ?_assertMatch(
            <<"TypeError: bad argument in an arithmetic expression\n    at m:f/1 (m.erl:3)">>,
            maps:get(<<"stack">>, bouy_error:from_erlang(badarith, [{m, f, 1, [{file, "m.erl"}, {line, 3}]}]))
        )
    ].
