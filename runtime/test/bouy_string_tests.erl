-module(bouy_string_tests).

-include_lib("eunit/include/eunit.hrl").

thrown(F) ->
    try F() of
        Value -> {returned, Value}
    catch
        error:{'$throw', #{<<"name">> := Name, <<"message">> := Message}} -> <<Name/binary, ": ", Message/binary>>
    end.

s(Method, Receiver, Args) -> bouy_string:call(Method, Receiver, Args).

-define(S, <<"Hello, Wörld! 😀 héllo"/utf8>>).

index_test_() ->
    [
        ?_assertEqual(<<"h">>, s(<<"at">>, <<"hello">>, [0])),
        ?_assertEqual(<<"o">>, s(<<"at">>, <<"hello">>, [-1])),
        ?_assertEqual(undefined, s(<<"at">>, <<"hello">>, [5])),
        ?_assertEqual(undefined, s(<<"at">>, <<"hello">>, [-6])),
        ?_assertEqual(undefined, s(<<"at">>, <<"abc">>, ['Infinity'])),
        ?_assertEqual(<<"😀"/utf8>>, s(<<"at">>, ?S, [14])),
        ?_assertEqual(<<"e">>, s(<<"charAt">>, <<"hello">>, [1])),
        ?_assertEqual(<<>>, s(<<"charAt">>, <<"hello">>, [10])),
        ?_assertEqual(<<"h">>, s(<<"charAt">>, <<"hello">>, [])),
        ?_assertEqual(101, s(<<"charCodeAt">>, <<"hello">>, [1])),
        ?_assertEqual('NaN', s(<<"charCodeAt">>, <<"hello">>, [10])),
        ?_assertEqual(233, s(<<"charCodeAt">>, <<"héllo"/utf8>>, [1])),
        ?_assertEqual(16#1F600, s(<<"codePointAt">>, ?S, [14])),
        ?_assertEqual(undefined, s(<<"codePointAt">>, <<"abc">>, [5])),
        %% Code points: JavaScript says 22, because the emoji is two UTF-16 units.
        ?_assertEqual(21, bouy_string:get(?S, <<"length">>)),
        ?_assertEqual(<<"W">>, bouy_string:get(?S, <<"7">>)),
        ?_assertEqual(undefined, bouy_string:get(<<"ab">>, 2)),
        ?_assertEqual(undefined, bouy_string:get(<<"ab">>, <<"x">>))
    ].

search_test_() ->
    [
        ?_assert(s(<<"endsWith">>, <<"hello">>, [<<"llo">>])),
        ?_assert(s(<<"endsWith">>, <<"hello">>, [<<"hel">>, 3])),
        ?_assert(s(<<"endsWith">>, <<"hello">>, [<<>>])),
        ?_assert(s(<<"endsWith">>, ?S, [<<"héllo"/utf8>>])),
        ?_assert(s(<<"endsWith">>, <<"hello">>, [<<"lo">>, 100])),
        ?_assert(s(<<"includes">>, <<"hello">>, [<<"ell">>])),
        ?_assertNot(s(<<"includes">>, <<"hello">>, [<<"ell">>, 2])),
        ?_assert(s(<<"includes">>, ?S, [<<"😀"/utf8>>])),
        ?_assertEqual(2, s(<<"indexOf">>, <<"hello">>, [<<"l">>])),
        ?_assertEqual(3, s(<<"indexOf">>, <<"hello">>, [<<"l">>, 3])),
        ?_assertEqual(0, s(<<"indexOf">>, <<"hello">>, [<<>>])),
        ?_assertEqual(5, s(<<"indexOf">>, <<"hello">>, [<<>>, 10])),
        ?_assertEqual(-1, s(<<"indexOf">>, <<"hello">>, [<<"z">>])),
        ?_assertEqual(0, s(<<"indexOf">>, <<"aaa">>, [<<"a">>, -5])),
        ?_assertEqual(3, s(<<"lastIndexOf">>, <<"hello">>, [<<"l">>])),
        ?_assertEqual(2, s(<<"lastIndexOf">>, <<"hello">>, [<<"l">>, 2])),
        ?_assertEqual(1, s(<<"lastIndexOf">>, <<"aaa">>, [<<"aa">>])),
        ?_assertEqual(5, s(<<"lastIndexOf">>, <<"hello">>, [<<>>])),
        ?_assertEqual(2, s(<<"lastIndexOf">>, <<"hello">>, [<<>>, 2])),
        ?_assertEqual(0, s(<<"lastIndexOf">>, <<"hello">>, [<<"h">>, -5])),
        ?_assertEqual(-1, s(<<"lastIndexOf">>, <<"hello">>, [<<"z">>])),
        ?_assert(s(<<"startsWith">>, <<"hello">>, [<<"hel">>])),
        ?_assert(s(<<"startsWith">>, <<"hello">>, [<<"ell">>, 1])),
        ?_assert(s(<<"startsWith">>, ?S, [<<"Wö"/utf8>>, 7])),
        ?_assert(s(<<"startsWith">>, <<"hello">>, [<<"h">>, -3])),
        ?_assertEqual(-1, s(<<"localeCompare">>, <<"a">>, [<<"b">>])),
        ?_assertEqual(1, s(<<"localeCompare">>, <<"b">>, [<<"a">>])),
        ?_assertEqual(0, s(<<"localeCompare">>, <<"a">>, [<<"a">>]))
    ].

slice_test_() ->
    [
        ?_assertEqual(<<"ell">>, s(<<"slice">>, <<"hello">>, [1, -1])),
        ?_assertEqual(<<"llo">>, s(<<"slice">>, <<"hello">>, [-3])),
        ?_assertEqual(<<>>, s(<<"slice">>, <<"hello">>, [3, 1])),
        ?_assertEqual(<<"hello">>, s(<<"slice">>, <<"hello">>, ['NaN'])),
        ?_assertEqual(<<"Wörld"/utf8>>, s(<<"slice">>, ?S, [7, 12])),
        ?_assertEqual(<<"héllo"/utf8>>, s(<<"slice">>, ?S, [-5])),
        ?_assertEqual(<<"hello">>, s(<<"slice">>, <<"hello">>, [-100, 100])),
        ?_assertEqual(<<"el">>, s(<<"substring">>, <<"hello">>, [3, 1])),
        ?_assertEqual(<<"he">>, s(<<"substring">>, <<"hello">>, [-2, 2])),
        ?_assertEqual(<<"llo">>, s(<<"substring">>, <<"hello">>, [2])),
        ?_assertEqual(<<"he">>, s(<<"substring">>, <<"hello">>, ['NaN', 2])),
        ?_assertEqual(<<"ell">>, s(<<"substr">>, <<"hello">>, [1, 3])),
        ?_assertEqual(<<"ll">>, s(<<"substr">>, <<"hello">>, [-3, 2])),
        ?_assertEqual(<<>>, s(<<"substr">>, <<"hello">>, [1, -1]))
    ].

case_and_trim_test_() ->
    [
        ?_assertEqual(<<"héllo wörld"/utf8>>, s(<<"toLowerCase">>, <<"HÉLLO WÖRLD"/utf8>>, [])),
        ?_assertEqual(<<"HÉLLO WÖRLD STRASSE"/utf8>>, s(<<"toUpperCase">>, <<"héllo wörld straße"/utf8>>, [])),
        ?_assertEqual(<<"x">>, s(<<"trim">>, <<"\x{a0} x \x{feff}\x{3000}"/utf8>>, [])),
        ?_assertEqual(<<"x">>, s(<<"trim">>, <<"\t\n x \r\n">>, [])),
        ?_assertEqual(<<"x  ">>, s(<<"trimStart">>, <<"  x  ">>, [])),
        ?_assertEqual(<<"  x">>, s(<<"trimEnd">>, <<"  x  ">>, [])),
        ?_assertEqual(<<"x">>, s(<<"trimEnd">>, <<"x\x{2028}"/utf8>>, [])),
        ?_assertEqual(<<>>, s(<<"trim">>, <<"   ">>, [])),
        %% U+0085 is not JavaScript whitespace.
        ?_assertEqual(<<"\x{85}x"/utf8>>, s(<<"trim">>, <<"\x{85}x"/utf8>>, []))
    ].

pad_and_repeat_test_() ->
    [
        ?_assertEqual(<<"abcxyxy">>, s(<<"padEnd">>, <<"abc">>, [7, <<"xy">>])),
        ?_assertEqual(<<"abc">>, s(<<"padEnd">>, <<"abc">>, [2])),
        ?_assertEqual(<<"abc   ">>, s(<<"padEnd">>, <<"abc">>, [6])),
        ?_assertEqual(<<"121abc">>, s(<<"padStart">>, <<"abc">>, [6, <<"12">>])),
        ?_assertEqual(<<"005">>, s(<<"padStart">>, <<"5">>, [3, <<"0">>])),
        ?_assertEqual(<<"abc">>, s(<<"padStart">>, <<"abc">>, [6, <<>>])),
        ?_assertEqual(<<"ababab">>, s(<<"repeat">>, <<"ab">>, [3])),
        ?_assertEqual(<<>>, s(<<"repeat">>, <<"ab">>, [0])),
        ?_assertEqual(<<"RangeError: Invalid count value: -1">>, thrown(fun() -> s(<<"repeat">>, <<"a">>, [-1]) end)),
        ?_assertEqual(<<"RangeError: Invalid count value: Infinity">>, thrown(fun() -> s(<<"repeat">>, <<"a">>, ['Infinity']) end))
    ].

replace_test_() ->
    Upper = fun([Match, Offset, Whole]) -> <<(string:uppercase(Match))/binary, (integer_to_binary(Offset))/binary, Whole/binary>> end,
    [
        ?_assertEqual(<<"abbc">>, s(<<"replace">>, <<"abc">>, [<<"b">>, <<"$&$&">>])),
        ?_assertEqual(<<"a$c">>, s(<<"replace">>, <<"abc">>, [<<"b">>, <<"$$">>])),
        ?_assertEqual(<<"a[a|c]c">>, s(<<"replace">>, <<"abc">>, [<<"b">>, <<"[$`|$']">>])),
        ?_assertEqual(<<"baa">>, s(<<"replace">>, <<"aaa">>, [<<"a">>, <<"b">>])),
        ?_assertEqual(<<"-ab">>, s(<<"replace">>, <<"ab">>, [<<>>, <<"-">>])),
        ?_assertEqual(<<"abc">>, s(<<"replace">>, <<"abc">>, [<<"x">>, <<"y">>])),
        ?_assertEqual(<<"a$1b">>, s(<<"replace">>, <<"a$b">>, [<<"$">>, <<"$1">>])),
        ?_assertEqual(<<"aB1abcc">>, s(<<"replace">>, <<"abc">>, [<<"b">>, Upper])),
        ?_assertEqual(<<"bbb">>, s(<<"replaceAll">>, <<"aaa">>, [<<"a">>, <<"b">>])),
        ?_assertEqual(<<"-a-b-">>, s(<<"replaceAll">>, <<"ab">>, [<<>>, <<"-">>])),
        ?_assertEqual(<<"a$1b$1c">>, s(<<"replaceAll">>, <<"a.b.c">>, [<<".">>, <<"$1">>])),
        ?_assertEqual(<<"bb">>, s(<<"replaceAll">>, <<"aaaa">>, [<<"aa">>, <<"b">>])),
        ?_assertEqual(<<"HeLLo, WörLd! 😀 héLLo"/utf8>>, s(<<"replaceAll">>, ?S, [<<"l">>, <<"L">>])),
        ?_assertEqual(
            <<"TypeError: String.prototype.replace takes a string pattern: Bouy does not support regular expressions yet">>,
            thrown(fun() -> s(<<"replace">>, <<"a">>, [#{}, <<"b">>]) end)
        ),
        ?_assertMatch(<<"TypeError: String.prototype.match", _/binary>>, thrown(fun() -> s(<<"match">>, <<"a">>, [<<"a">>]) end))
    ].

split_test_() ->
    [
        ?_assertEqual([<<"a">>, <<"b">>, <<>>, <<"c">>], s(<<"split">>, <<"a,b,,c">>, [<<",">>])),
        ?_assertEqual([<<>>], s(<<"split">>, <<>>, [<<",">>])),
        ?_assertEqual([<<"a">>, <<"b">>, <<"c">>], s(<<"split">>, <<"abc">>, [<<>>])),
        ?_assertEqual([], s(<<"split">>, <<>>, [<<>>])),
        ?_assertEqual([<<"a">>, <<"b">>], s(<<"split">>, <<"a,b,c">>, [<<",">>, 2])),
        ?_assertEqual([<<"abc">>], s(<<"split">>, <<"abc">>, [])),
        ?_assertEqual([<<"a">>, <<"b">>, <<"c">>], s(<<"split">>, <<"a1b1c">>, [1])),
        ?_assertEqual([<<"a">>, <<"b">>], s(<<"split">>, <<"abc">>, [<<>>, 2])),
        ?_assertEqual([], s(<<"split">>, <<"a,b">>, [<<",">>, 0])),
        ?_assertEqual([<<>>, <<"es">>, <<>>], s(<<"split">>, <<"test">>, [<<"t">>])),
        ?_assertEqual([<<"a">>, <<"b">>], s(<<"split">>, <<"a,b">>, [<<",">>, -1])),
        ?_assertEqual([<<"h">>, <<"é"/utf8>>, <<"😀"/utf8>>], s(<<"split">>, <<"hé😀"/utf8>>, [<<>>]))
    ].

other_methods_test_() ->
    [
        ?_assertEqual(<<"a1null2,3undefined">>, s(<<"concat">>, <<"a">>, [1, null, [2, 3], undefined])),
        ?_assertEqual(<<"abc">>, s(<<"toString">>, <<"abc">>, [])),
        ?_assertEqual(<<"abc">>, s(<<"valueOf">>, <<"abc">>, [])),
        ?_assertEqual(<<"TypeError: \"abc\".nope is not a function">>, thrown(fun() -> s(<<"nope">>, <<"abc">>, []) end))
    ].

namespace_test_() ->
    [
        ?_assertEqual(<<"Hi">>, bouy_string:'fromCharCode'([72, 105])),
        ?_assertEqual(<<"😀"/utf8>>, bouy_string:'fromCharCode'([16#D83D, 16#DE00])),
        ?_assertEqual(<<"A">>, bouy_string:'fromCharCode'([65.7])),
        ?_assertEqual(<<"A">>, bouy_string:'fromCharCode'([16#10041])),
        ?_assertEqual(<<16#FFFF/utf8>>, bouy_string:'fromCharCode'([-1])),
        ?_assertEqual(<<16#FFFD/utf8>>, bouy_string:'fromCharCode'([16#D800])),
        ?_assertEqual(<<"😀"/utf8>>, bouy_string:'fromCodePoint'([16#1F600])),
        ?_assertEqual(<<"RangeError: Invalid code point 1114112">>, thrown(fun() -> bouy_string:'fromCodePoint'([16#110000]) end)),
        ?_assertEqual(<<>>, bouy_string:'$call'([])),
        ?_assertEqual(<<"1,2">>, bouy_string:'$call'([[1, 2]])),
        ?_assertEqual(<<"null">>, bouy_string:new([null])),
        ?_assertEqual(<<"x">>, bouy_rt:call(bouy_string:'$member'(<<"fromCharCode">>), [120])),
        ?_assertEqual(undefined, bouy_string:'$member'(<<"raw">>))
    ].

helpers_test_() ->
    [
        ?_assertEqual(0, bouy_string:char_count(<<>>)),
        ?_assertEqual(4, bouy_string:char_count(<<"hé😀!"/utf8>>)),
        ?_assertEqual(<<"x ">>, bouy_string:trim_start(<<"\x{3000}x "/utf8>>))
    ].
