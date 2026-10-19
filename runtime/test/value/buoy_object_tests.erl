-module(buoy_object_tests).

-include_lib("eunit/include/eunit.hrl").

thrown(F) ->
    try F() of
        Value -> {returned, Value}
    catch
        error:{'$throw', #{<<"name">> := Name, <<"message">> := Message}} -> <<Name/binary, ": ", Message/binary>>
    end.

object_test_() ->
    Object = #{<<"b">> => 1, <<"a">> => 2},
    Error = buoy_error:new(<<"Error">>, <<"m">>, #{<<"code">> => 7}),
    [
        %% Keys come out in Erlang term order, not insertion order.
        ?_assertEqual([<<"a">>, <<"b">>], buoy_object:keys([Object])),
        ?_assertEqual([2, 1], buoy_object:values([Object])),
        ?_assertEqual([[<<"a">>, 2], [<<"b">>, 1]], buoy_object:entries([Object])),
        ?_assertEqual([<<"0">>, <<"1">>], buoy_object:keys([<<"ab">>])),
        ?_assertEqual([<<"0">>, <<"1">>], buoy_object:keys([[4, 5]])),
        ?_assertEqual([], buoy_object:keys([5])),
        ?_assertEqual([], buoy_object:keys([buoy_map:new([[[a, 1]]])])),
        ?_assertEqual([<<"code">>], buoy_object:keys([Error])),
        ?_assertEqual(<<"TypeError: Cannot convert undefined or null to object">>, thrown(fun() -> buoy_object:keys([null]) end)),
        ?_assertEqual(<<"TypeError: Cannot convert undefined or null to object">>, thrown(fun() -> buoy_object:entries([]) end))
    ].

%% A private field of a class lives under an atom key, which no property
%% lists: keys, spreads, JSON, and console output skip it.
private_field_test_() ->
    This = #{<<"owner">> => <<"ann">>, '#pin' => <<"1234">>},
    [
        ?_assertEqual([<<"owner">>], buoy_object:keys([This])),
        ?_assertEqual(#{<<"owner">> => <<"ann">>}, buoy_rt:object([{'$spread', This}])),
        ?_assertEqual(<<"{\"owner\":\"ann\"}">>, buoy_json:stringify([This])),
        ?_assertEqual(<<"{ owner: 'ann' }">>, buoy_console:inspect(This)),
        ?_assertEqual(<<"{}">>, buoy_console:inspect(#{'#pin' => 1})),
        ?_assertNot(buoy_rt:has(This, <<"#pin">>))
    ].

from_entries_test_() ->
    [
        ?_assertEqual(#{<<"a">> => 1, <<"b">> => 2}, buoy_object:'fromEntries'([[[<<"a">>, 1], [<<"b">>, 2]]])),
        ?_assertEqual(#{<<"a">> => 3}, buoy_object:'fromEntries'([[[<<"a">>, 1], [<<"a">>, 3]]])),
        ?_assertEqual(#{<<"1">> => x}, buoy_object:'fromEntries'([buoy_map:new([[[1, x]]])]))
    ].

assign_test_() ->
    [
        ?_assertEqual(#{<<"a">> => 3, <<"b">> => 2}, buoy_object:assign([#{<<"a">> => 1}, #{<<"b">> => 2}, null, #{<<"a">> => 3}])),
        ?_assertEqual([z, b], buoy_object:assign([[a, b], #{<<"0">> => z}])),
        ?_assertEqual(<<"TypeError: Cannot convert undefined or null to object">>, thrown(fun() -> buoy_object:assign([undefined, #{}]) end))
    ].

has_own_test_() ->
    Error = buoy_error:new(<<"Error">>, <<"m">>),
    [
        ?_assert(buoy_object:'hasOwn'([#{<<"a">> => 1}, <<"a">>])),
        ?_assertNot(buoy_object:'hasOwn'([#{<<"a">> => 1}, <<"b">>])),
        ?_assert(buoy_object:'hasOwn'([[a], 0])),
        ?_assert(buoy_object:'hasOwn'([[a], <<"length">>])),
        ?_assert(buoy_object:'hasOwn'([Error, <<"message">>])),
        ?_assertNot(buoy_object:'hasOwn'([Error, <<"$error">>]))
    ].

namespace_test_() ->
    Object = #{<<"a">> => 1},
    [
        ?_assertEqual(Object, buoy_object:freeze([Object])),
        ?_assertEqual(#{}, buoy_object:'$call'([])),
        ?_assertEqual(#{}, buoy_object:new([null])),
        ?_assertEqual(Object, buoy_object:'$call'([Object])),
        ?_assertEqual([<<"a">>], buoy_rt:call(buoy_object:'$member'(<<"keys">>), [Object])),
        ?_assertEqual(undefined, buoy_object:'$member'(<<"defineProperty">>)),
        ?_assertEqual([{<<"0">>, <<"h">>}, {<<"1">>, <<"é"/utf8>>}], buoy_object:own_entries(<<"hé"/utf8>>)),
        ?_assertEqual([], buoy_object:own_entries(undefined))
    ].
