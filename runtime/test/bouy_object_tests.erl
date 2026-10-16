-module(bouy_object_tests).

-include_lib("eunit/include/eunit.hrl").

thrown(F) ->
    try F() of
        Value -> {returned, Value}
    catch
        error:{'$throw', #{<<"name">> := Name, <<"message">> := Message}} -> <<Name/binary, ": ", Message/binary>>
    end.

object_test_() ->
    Object = #{<<"b">> => 1, <<"a">> => 2},
    Error = bouy_error:new(<<"Error">>, <<"m">>, #{<<"code">> => 7}),
    [
        %% Keys come out in Erlang term order, not insertion order.
        ?_assertEqual([<<"a">>, <<"b">>], bouy_object:keys([Object])),
        ?_assertEqual([2, 1], bouy_object:values([Object])),
        ?_assertEqual([[<<"a">>, 2], [<<"b">>, 1]], bouy_object:entries([Object])),
        ?_assertEqual([<<"0">>, <<"1">>], bouy_object:keys([<<"ab">>])),
        ?_assertEqual([<<"0">>, <<"1">>], bouy_object:keys([[4, 5]])),
        ?_assertEqual([], bouy_object:keys([5])),
        ?_assertEqual([], bouy_object:keys([bouy_map:new([[[a, 1]]])])),
        ?_assertEqual([<<"code">>], bouy_object:keys([Error])),
        ?_assertEqual(<<"TypeError: Cannot convert undefined or null to object">>, thrown(fun() -> bouy_object:keys([null]) end)),
        ?_assertEqual(<<"TypeError: Cannot convert undefined or null to object">>, thrown(fun() -> bouy_object:entries([]) end))
    ].

%% A private field of a class lives under an atom key, which no property
%% lists: keys, spreads, JSON, and console output skip it.
private_field_test_() ->
    This = #{<<"owner">> => <<"ann">>, '#pin' => <<"1234">>},
    [
        ?_assertEqual([<<"owner">>], bouy_object:keys([This])),
        ?_assertEqual(#{<<"owner">> => <<"ann">>}, bouy_rt:object([{'$spread', This}])),
        ?_assertEqual(<<"{\"owner\":\"ann\"}">>, bouy_json:stringify([This])),
        ?_assertEqual(<<"{ owner: 'ann' }">>, bouy_console:inspect(This)),
        ?_assertEqual(<<"{}">>, bouy_console:inspect(#{'#pin' => 1})),
        ?_assertNot(bouy_rt:has(This, <<"#pin">>))
    ].

from_entries_test_() ->
    [
        ?_assertEqual(#{<<"a">> => 1, <<"b">> => 2}, bouy_object:'fromEntries'([[[<<"a">>, 1], [<<"b">>, 2]]])),
        ?_assertEqual(#{<<"a">> => 3}, bouy_object:'fromEntries'([[[<<"a">>, 1], [<<"a">>, 3]]])),
        ?_assertEqual(#{<<"1">> => x}, bouy_object:'fromEntries'([bouy_map:new([[[1, x]]])]))
    ].

assign_test_() ->
    [
        ?_assertEqual(#{<<"a">> => 3, <<"b">> => 2}, bouy_object:assign([#{<<"a">> => 1}, #{<<"b">> => 2}, null, #{<<"a">> => 3}])),
        ?_assertEqual([z, b], bouy_object:assign([[a, b], #{<<"0">> => z}])),
        ?_assertEqual(<<"TypeError: Cannot convert undefined or null to object">>, thrown(fun() -> bouy_object:assign([undefined, #{}]) end))
    ].

has_own_test_() ->
    Error = bouy_error:new(<<"Error">>, <<"m">>),
    [
        ?_assert(bouy_object:'hasOwn'([#{<<"a">> => 1}, <<"a">>])),
        ?_assertNot(bouy_object:'hasOwn'([#{<<"a">> => 1}, <<"b">>])),
        ?_assert(bouy_object:'hasOwn'([[a], 0])),
        ?_assert(bouy_object:'hasOwn'([[a], <<"length">>])),
        ?_assert(bouy_object:'hasOwn'([Error, <<"message">>])),
        ?_assertNot(bouy_object:'hasOwn'([Error, <<"$error">>]))
    ].

namespace_test_() ->
    Object = #{<<"a">> => 1},
    [
        ?_assertEqual(Object, bouy_object:freeze([Object])),
        ?_assertEqual(#{}, bouy_object:'$call'([])),
        ?_assertEqual(#{}, bouy_object:new([null])),
        ?_assertEqual(Object, bouy_object:'$call'([Object])),
        ?_assertEqual([<<"a">>], bouy_rt:call(bouy_object:'$member'(<<"keys">>), [Object])),
        ?_assertEqual(undefined, bouy_object:'$member'(<<"defineProperty">>)),
        ?_assertEqual([{<<"0">>, <<"h">>}, {<<"1">>, <<"é"/utf8>>}], bouy_object:own_entries(<<"hé"/utf8>>)),
        ?_assertEqual([], bouy_object:own_entries(undefined))
    ].
