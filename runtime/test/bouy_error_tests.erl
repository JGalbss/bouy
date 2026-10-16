-module(bouy_error_tests).

-include_lib("eunit/include/eunit.hrl").

new_test_() ->
    Error = bouy_error:new(<<"TypeError">>, <<"bad">>),
    Tagged = bouy_error:new(<<"NotFound">>, <<"missing">>, #{<<"_tag">> => <<"NotFound">>, <<"id">> => 7}),
    [
        ?_assertMatch(#{'$error' := [{'$class', bouy_error, <<"TypeError">>}], <<"name">> := <<"TypeError">>, <<"message">> := <<"bad">>}, Error),
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

%% A class value of each class that built the error, and `Error` for all.
identity_test_() ->
    Classes = [{'$class', 'bouy@app', <<"Overflow">>}, {'$class', bouy_error, <<"RangeError">>}],
    Overflow = bouy_error:new(Classes, <<"too big">>, #{}),
    Renamed = bouy_rt:set(Overflow, <<"name">>, <<"Other">>),
    [
        ?_assert(bouy_rt:instance_of(Renamed, {'$class', 'bouy@app', <<"Overflow">>})),
        ?_assert(bouy_rt:instance_of(Renamed, {'$class', bouy_error, <<"RangeError">>})),
        ?_assert(bouy_rt:instance_of(Renamed, {'$class', bouy_error, <<"Error">>})),
        ?_assertNot(bouy_rt:instance_of(Renamed, {'$class', 'bouy@other', <<"Overflow">>})),
        ?_assertEqual({'$class', 'bouy@app', <<"Overflow">>}, bouy_rt:get(Overflow, <<"constructor">>)),
        ?_assertEqual(<<"Overflow">>, bouy_rt:get(bouy_rt:get(Overflow, <<"constructor">>), <<"name">>)),
        ?_assertNot(bouy_rt:instance_of(#{<<"$error">> => true, <<"name">> => <<"TypeError">>}, {'$class', bouy_error, <<"Error">>})),
        ?_assertEqual([<<"code">>], bouy_object:keys([bouy_error:new(<<"Error">>, <<"m">>, #{<<"code">> => 1})]))
    ].

%% A call of a namespace member that does not exist, and a module-level const
%% read before its declaration runs.
javascript_reason_test_() ->
    Undefined = try bouy_object:nope([]) catch error:R1:S1 -> bouy_rt:caught(R1, S1) end,
    Early = try persistent_term:get({'bouy@app', <<"LIMIT">>}) catch error:R2:S2 -> bouy_rt:caught(R2, S2) end,
    [
        ?_assertMatch(#{<<"name">> := <<"TypeError">>, <<"message">> := <<"Object.nope is not a function">>}, Undefined),
        ?_assertMatch(#{<<"name">> := <<"ReferenceError">>, <<"message">> := <<"Cannot access 'LIMIT' before initialization">>}, Early)
    ].
