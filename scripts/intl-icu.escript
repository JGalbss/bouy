#!/usr/bin/env escript
%% Writes crates/buoy-native/data/cldr.etf, the locale data of Intl, from the resource
%% bundle sources of the ICU that Node bundles (process.versions.icu), so that every
%% formatter reads the strings that Node's ICU reads: the locales, curr, unit, lang, region,
%% and zone trees of each locale, and the supplemental tables that the formatters use.
%%
%% Usage: scripts/intl-icu.escript <icu-data-dir> <output.etf>
%%
%% <icu-data-dir> is the data directory of icu4c-<version>-data.zip of the ICU release,
%% such as https://github.com/unicode-org/icu/releases/download/release-78.3/icu4c-78.3-data.zip,
%% with locales/, curr/, unit/, lang/, region/, zone/, and misc/.
%%
%% Each locale is its resource tree as ICU's genrb reads the .txt files, with the trees of
%% the six directories merged: a table is a map, an array a list, a string a UTF-8
%% binary, an integer an integer, and an alias {alias, Path}. buoy_intl_cldr reads a path
%% from the locale, then from each parent (%%Parent, else the locale less its last subtag,
%% then root), and follows an alias from the locale of the request, as ICU's
%% ures_getByKeyWithFallback does. The file is the external term format of #{version,
%% locales, parents, aliases, supplemental}, where each value of locales is the external
%% term format of the locale's tree.
-mode(compile).

main([Dir, Output]) ->
    Trees = lists:foldl(fun(Sub, Acc) -> read_tree(filename:join(Dir, Sub), Acc) end, #{},
                        ["locales", "curr", "unit", "lang", "region", "zone"]),
    Parents = maps:from_list([{L, tag(P)} || {L, #{<<"%%Parent">> := P}} <- maps:to_list(Trees)]),
    Aliases = maps:from_list([{L, tag(A)} || {L, #{<<"%%ALIAS">> := A}} <- maps:to_list(Trees)]),
    Locales = maps:from_list([{L, term_to_binary(maps:without([<<"%%Parent">>, <<"%%ALIAS">>], T), [{compressed, 9}])}
                              || {L, T} <- maps:to_list(Trees), not maps:is_key(<<"%%ALIAS">>, T)]),
    Misc = fun(Name) -> {_, Tree} = parse_file(filename:join([Dir, "misc", Name ++ ".txt"])), Tree end,
    Version = maps:get(<<"ICUVersion">>, Misc("icuver")),
    Data = #{version => Version, locales => Locales, parents => Parents, aliases => Aliases,
             supplemental => #{currency_meta => maps:get(<<"CurrencyMeta">>, element(2, parse_file(filename:join([Dir, "curr", "supplementalData.txt"])))),
                               numbering_systems => Misc("numberingSystems"),
                               meta_zones => Misc("metaZones"),
                               timezone_types => Misc("timezoneTypes"),
                               zone_regions => zone_regions(Misc("zoneinfo64")),
                               day_periods => Misc("dayPeriods")}},
    ok = filelib:ensure_dir(Output),
    ok = file:write_file(Output, term_to_binary(Data, [{compressed, 9}, deterministic]));
main(_) ->
    io:format(standard_error, "usage: scripts/intl-icu.escript <icu-data-dir> <output.etf>~n", []),
    halt(1).

%% The trees of the .txt files of a directory merged into Acc, by locale tag.
read_tree(Dir, Acc) ->
    Files = [F || F <- filelib:wildcard("*.txt", Dir), not lists:member(F, ["pool.txt", "res_index.txt", "tzdbNames.txt", "supplementalData.txt"])],
    lists:foldl(fun(File, A) ->
                        {_Name, Tree} = parse_file(filename:join(Dir, File)),
                        Tag = tag(list_to_binary(filename:rootname(File))),
                        maps:update_with(Tag, fun(Old) -> merge(Old, Tree) end, Tree, A)
                end, Acc, Files).

merge(A, B) when is_map(A), is_map(B) -> maps:merge_with(fun(_, X, Y) -> merge(X, Y) end, A, B);
merge(_A, B) -> B.

%% An ICU locale name as a language tag: underscores to hyphens.
tag(Name) -> binary:replace(Name, <<"_">>, <<"-">>, [global]).

%% The region of each zone of zoneinfo64: its Names with their Regions.
zone_regions(Info) ->
    maps:from_list(lists:zip(maps:get(<<"Names">>, Info), maps:get(<<"Regions">>, Info))).

%%% The resource bundle source format of genrb

parse_file(Path) ->
    {ok, Bin} = file:read_file(Path),
    Chars = case unicode:characters_to_list(Bin) of
        [16#FEFF | Rest] -> Rest;
        All -> All
    end,
    {[{Name, Value}], []} = resources(tokens(Chars), []),
    {Name, Value}.

%% The tokens: open, close, comma, colon, {string, Text}, and {word, Text}.
tokens([]) -> [];
tokens([$/, $/ | Rest]) -> tokens(lists:dropwhile(fun(C) -> C =/= $\n end, Rest));
tokens([$/, $* | Rest]) -> tokens(skip_comment(Rest));
tokens([C | Rest]) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r -> tokens(Rest);
tokens([${ | Rest]) -> [open | tokens(Rest)];
tokens([$} | Rest]) -> [close | tokens(Rest)];
tokens([$, | Rest]) -> [comma | tokens(Rest)];
tokens([$: | Rest]) -> [colon | tokens(Rest)];
tokens([$" | Rest]) ->
    {Text, After} = string_literal(Rest, []),
    case tokens(After) of
        [{string, More} | Tail] -> [{string, Text ++ More} | Tail];
        Tail -> [{string, Text} | Tail]
    end;
tokens(Text) ->
    {Word, Rest} = lists:splitwith(fun(C) -> not lists:member(C, " \t\r\n{}:,\"") end, Text),
    [{word, Word} | tokens(Rest)].

skip_comment([$*, $/ | Rest]) -> Rest;
skip_comment([_ | Rest]) -> skip_comment(Rest).

string_literal([$" | Rest], Acc) -> {lists:reverse(Acc), Rest};
string_literal([$\\, $u, A, B, C, D | Rest], Acc) -> string_literal(Rest, [list_to_integer([A, B, C, D], 16) | Acc]);
string_literal([$\\, $U, A, B, C, D, E, F, G, H | Rest], Acc) -> string_literal(Rest, [list_to_integer([A, B, C, D, E, F, G, H], 16) | Acc]);
string_literal([$\\, $n | Rest], Acc) -> string_literal(Rest, [$\n | Acc]);
string_literal([$\\, $t | Rest], Acc) -> string_literal(Rest, [$\t | Acc]);
string_literal([$\\, C | Rest], Acc) -> string_literal(Rest, [C | Acc]);
string_literal([C | Rest], Acc) -> string_literal(Rest, [C | Acc]).

%% Named resources until a close: {[{Key, Value}], Rest}.
resources([close | _] = Rest, Acc) -> {lists:reverse(Acc), Rest};
resources([], Acc) -> {lists:reverse(Acc), []};
resources([Key | Rest], Acc) ->
    Name = case Key of {word, W} -> W; {string, S} -> S end,
    {Type, Rest1} = case Rest of
        [colon, {word, T} | R] -> {T, R};
        R -> {none, R}
    end,
    [open | Rest2] = Rest1,
    {Value, [close | Rest3]} = body(Type, Rest2),
    resources(Rest3, [{bin(Name), Value} | Acc]).

bin(Text) -> unicode:characters_to_binary(Text).

%% The value of a resource of the type, inferring the type of an untyped one.
body("table", Tokens) -> table(Tokens);
body("array", Tokens) -> array(Tokens, []);
body("int", [{word, W} | Rest]) -> {list_to_integer(W), Rest};
body("intvector", Tokens) -> int_vector(Tokens, []);
body("alias", [{string, S} | Rest]) -> {{alias, bin(S)}, Rest};
body("bin", Tokens) -> {binary, lists:dropwhile(fun(T) -> T =/= close end, Tokens)};
body("import", [{string, _} | Rest]) -> {import, Rest};
body(_, [close | _] = Rest) -> {#{}, Rest};
body(_, [{string, S}, close | _] = Tokens) -> {bin(S), tl(Tokens)};
body(_, [{string, _}, comma | _] = Tokens) -> array(Tokens, []);
body(_, [open | _] = Tokens) -> array(Tokens, []);
body(_, Tokens) -> table(Tokens).

table(Tokens) ->
    {Pairs, Rest} = resources(Tokens, []),
    {maps:from_list(Pairs), Rest}.

%% The items of an array: strings and unnamed resources.
array([close | _] = Rest, Acc) -> {lists:reverse(Acc), Rest};
array([comma | Rest], Acc) -> array(Rest, Acc);
array([{string, S} | Rest], Acc) -> array(Rest, [bin(S) | Acc]);
array([colon, {word, T}, open | Rest], Acc) ->
    {Value, [close | Rest1]} = body(T, Rest),
    array(Rest1, [Value | Acc]);
array([open | Rest], Acc) ->
    {Value, [close | Rest1]} = body(none, Rest),
    array(Rest1, [Value | Acc]);
array([{word, W} | Rest], Acc) -> array(Rest, [bin(W) | Acc]).

int_vector([close | _] = Rest, Acc) -> {lists:reverse(Acc), Rest};
int_vector([comma | Rest], Acc) -> int_vector(Rest, Acc);
int_vector([{word, W} | Rest], Acc) -> int_vector(Rest, [list_to_integer(W) | Acc]).
