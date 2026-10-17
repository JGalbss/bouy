%% The RegExp engine below the JavaScript surface: the parser and its early
%% errors, the matcher on the examples of ECMA-262 22.2.2, the CharSets, and
%% the Unicode tables.
-module(bouy_regexp_tests).

-include_lib("eunit/include/eunit.hrl").

%% The match of Pattern with Flags in Subject from From: {Start, End, Captures},
%% each capture a binary or undefined, or nomatch, or {error, Message}.
match(Pattern, Flags, Subject) -> match(Pattern, Flags, Subject, 0).

match(Pattern, Flags, Subject, From) ->
    Has = fun(F) -> lists:member(F, Flags) end,
    Unicode = Has($u) orelse Has($v),
    S = bouy_ref_string:from_utf8(unicode:characters_to_binary(Pattern)),
    Source = case Unicode of
        true -> bouy_ref_string:code_points(S);
        false -> bouy_ref_string:units(S)
    end,
    case bouy_regexp_syntax:parse(Source, Has($u), Has($v)) of
        {error, Message} -> {error, Message};
        {ok, Tree, Groups, _Names} ->
            Program = bouy_regexp_match:compile(Tree, Groups, #{i => Has($i), m => Has($m), s => Has($s), u => Has($u), v => Has($v)}),
            Input = bouy_ref_string:from_utf8(unicode:characters_to_binary(Subject)),
            case bouy_regexp_match:search(Program, bouy_regexp_match:input(Input), From, Has($y)) of
                nomatch -> nomatch;
                {match, Start, End, Captures} ->
                    {Start, End, [text(Input, C) || C <- tuple_to_list(Captures)]}
            end
    end.

text(_S, undefined) -> undefined;
text(S, {A, B}) -> bouy_ref_string:to_utf8(bouy_ref_string:slice(S, A, B)).

spec_examples_test_() ->
    [?_assertEqual({0, 1, []}, match("a|ab", "", "abc")),
     ?_assertEqual({0, 3, [<<"a">>, <<"a">>, undefined, <<"bc">>, undefined, <<"bc">>]}, match("((a)|(ab))((c)|(bc))", "", "abc")),
     ?_assertEqual({0, 5, []}, match("a[a-z]{2,4}", "", "abcdefghi")),
     ?_assertEqual({0, 3, []}, match("a[a-z]{2,4}?", "", "abcdefghi")),
     ?_assertEqual({0, 4, [<<"ba">>]}, match("(aa|aabaac|ba|b|c)*", "", "aabaac")),
     ?_assertEqual({0, 10, [<<"z">>, <<"ac">>, <<"a">>, undefined, <<"c">>]}, match("(z)((a+)?(b+)?(c))*", "", "zaacbbbcac")),
     ?_assertEqual({0, 0, [undefined]}, match("(a*)*", "", "b")),
     ?_assertEqual({0, 1, [<<>>]}, match("(a*)b\\1+", "", "baaaac")),
     ?_assertEqual({1, 1, [<<"aaa">>]}, match("(?=(a+))", "", "baaabac")),
     ?_assertEqual({3, 6, [<<"a">>]}, match("(?=(a+))a*b\\1", "", "baaabac")),
     ?_assertEqual({0, 8, [<<"ba">>, undefined, <<"abaac">>]}, match("(.*?)a(?!(a+)b\\2c)\\2(.*)", "", "baaabaac"))].

lookbehind_test_() ->
    [?_assertEqual({6, 11, [<<".53">>]}, match("(?<=\\$)\\d+(\\.\\d*)?", "", "cost $10.53")),
     ?_assertEqual({2, 3, [<<"1">>, <<"2">>]}, match("(?<=(\\d)(\\d))x", "", "12x")),
     ?_assertEqual(nomatch, match("(?<!a)b", "", "ab")),
     ?_assertEqual({2, 4, []}, match("(?<=\\u{1F600})..", "u", "😀ab"))].

flags_test_() ->
    [?_assertEqual({3, 9, []}, match("[a-z]+", "i", "123ABCdef")),
     ?_assertEqual({2, 3, []}, match("^b", "m", "a\nb")),
     ?_assertEqual(nomatch, match("^b", "", "a\nb")),
     ?_assertEqual({0, 3, []}, match("a.c", "s", "a\nc")),
     ?_assertEqual(nomatch, match("a.c", "", "a\nc")),
     ?_assertEqual(nomatch, match("b", "y", "ab")),
     ?_assertEqual({1, 2, []}, match("b", "y", "ab", 1)),
     ?_assertEqual({3, 5, []}, match("(?i:a)b", "", "AB Ab")),
     ?_assertEqual({0, 2, []}, match("(?-i:a)b", "i", "aB"))].

unicode_test_() ->
    [?_assertEqual({0, 2, []}, match(".", "u", "😀")),
     ?_assertEqual({0, 1, []}, match(".", "", "😀")),
     ?_assertEqual(nomatch, match("\\uD83D", "u", "😀")),
     ?_assertEqual({0, 1, []}, match("\\uD83D", "", "😀")),
     ?_assertEqual({3, 6, []}, match("\\p{Lu}+", "u", "abcDÉFghi")),
     ?_assertEqual({3, 6, []}, match("[\\p{L}--[a-z]]+", "v", "abcDEFghi")),
     ?_assertEqual({2, 5, []}, match("[\\q{abc|d}]", "v", "xxabc")),
     ?_assertEqual(nomatch, match("ſ", "i", "s")),
     ?_assertEqual({0, 1, []}, match("ſ", "iu", "s")),
     ?_assertEqual({0, 1, []}, match("\\w", "iu", "ſ")),
     ?_assertEqual(nomatch, match("\\w", "i", "ſ"))].

annex_b_test_() ->
    [?_assertEqual({0, 2, []}, match("x{", "", "x{")),
     ?_assertEqual({0, 1, []}, match("\\8", "", "8")),
     ?_assertEqual({0, 1, []}, match("\\1", "", "\x01")),
     ?_assertEqual({0, 3, []}, match("\\c1", "", "\\c1")),
     ?_assertEqual({0, 1, []}, match("[\\c1]", "", "\x11")),
     ?_assertEqual({0, 1, []}, match("\\k", "", "k")),
     ?_assertEqual({0, 1, []}, match("]", "", "]")),
     ?_assertEqual({0, 4, []}, match("\\u{4}", "", "uuuu"))].

named_groups_test_() ->
    [?_assertEqual({0, 1, [undefined, <<"y">>]}, match("(?<a>x)|(?<a>y)", "", "y")),
     ?_assertEqual({1, 3, [<<"b">>]}, match("\\k<n>(?<n>b)\\k<n>", "", "abb")),
     ?_assertEqual({error, <<"Duplicate capture group name">>}, match("(?<a>x)(?<a>y)", "", "")),
     ?_assertEqual({error, <<"Invalid named capture referenced">>}, match("(?<a>x)\\k<b>", "", ""))].

early_errors_test_() ->
    [?_assertEqual({error, <<"Unterminated group">>}, match("(", "", "")),
     ?_assertEqual({error, <<"Unmatched ')'">>}, match(")", "", "")),
     ?_assertEqual({error, <<"Nothing to repeat">>}, match("a**", "", "")),
     ?_assertEqual({error, <<"Nothing to repeat">>}, match("{1}", "", "")),
     ?_assertEqual({error, <<"Lone quantifier brackets">>}, match("}", "u", "")),
     ?_assertEqual({error, <<"Range out of order in character class">>}, match("[b-a]", "", "")),
     ?_assertEqual({error, <<"Invalid character class">>}, match("[\\d-a]", "u", "")),
     ?_assertEqual({error, <<"numbers out of order in {} quantifier">>}, match("a{2,1}", "", "")),
     ?_assertEqual({error, <<"Invalid escape">>}, match("\\a", "u", "")),
     ?_assertEqual({error, <<"Invalid property name">>}, match("\\p{Latin}", "u", "")),
     ?_assertEqual({error, <<"Negated character class may contain strings">>}, match("[^\\q{ab}]", "v", "")),
     ?_assertEqual({error, <<"Invalid set operation in character class">>}, match("[a-z&&b]", "v", "")),
     ?_assertEqual({error, <<"Repeated flag in flag group">>}, match("(?i-i:a)", "", "")),
     ?_assertEqual({error, <<"Invalid flag group">>}, match("(?-:a)", "", ""))].

long_input_test() ->
    %% A quantified character backtracks in a loop, so a long run does not grow the stack.
    Long = lists:duplicate(200000, $a),
    ?assertEqual({0, 200001, []}, match("^a*b$", "", Long ++ "b")),
    ?assertEqual({0, 200000, []}, match("^\\p{L}+$", "u", Long)).

charset_test_() ->
    C = bouy_regexp_charset,
    [?_assertEqual([{1, 5}, {7, 9}], C:union([{1, 3}, {7, 9}], [{2, 5}])),
     ?_assertEqual([{2, 3}], C:intersect([{1, 3}, {7, 9}], [{2, 5}])),
     ?_assertEqual([{1, 1}, {7, 9}], C:subtract([{1, 3}, {7, 9}], [{2, 5}])),
     ?_assertEqual([{0, 0}, {4, 16#FFFF}], C:complement([{1, 3}], 16#FFFF)),
     ?_assert(lists:member({$k, $k}, C:closure([{16#212A, 16#212A}], scf))),
     ?_assertEqual([{16#41, 16#41}], C:closure([{16#41, 16#41}], upper) -- [{16#61, 16#61}]),
     ?_assertEqual([{$a, $z}], C:fold([{$A, $Z}])),
     ?_assert(C:has_property(<<"ID_Start">>, 16#4E00)),
     ?_assertNot(C:has_property(<<"ID_Start">>, $1))].

unicode_tables_test_() ->
    [?_assertEqual("17.0.0", bouy_regexp_unicode:version()),
     ?_assertEqual(<<"Lu">>, bouy_regexp_unicode:general_category(<<"Uppercase_Letter">>)),
     ?_assertEqual(<<"Latn">>, bouy_regexp_unicode:script(<<"Latin">>)),
     ?_assertEqual(<<"White_Space">>, bouy_regexp_unicode:binary_property(<<"space">>)),
     ?_assertEqual(false, bouy_regexp_unicode:binary_property(<<"WSpace">>)),
     ?_assertEqual($k, bouy_regexp_unicode:scf(16#212A)),
     ?_assertEqual(16#212A, bouy_regexp_unicode:upper(16#212A)),
     ?_assertEqual(16#DF, bouy_regexp_unicode:upper(16#DF))].
