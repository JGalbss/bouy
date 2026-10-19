#!/usr/bin/env escript
%% Writes crates/buoy-native/data/cldr.etf, the CLDR locale data of Intl that the
%% formatters read through buoy_intl_cldr: the number symbols and patterns, the currency
%% names, and the unit patterns of every locale of CLDR, as the ICU of Node holds them.
%%
%% Usage: scripts/intl-cldr.escript <cldr-json-dir> <output.etf>
%%
%% <cldr-json-dir> is the cldr-json directory of the cldr-json release that Node's ICU uses
%% (process.versions.cldr), such as https://github.com/unicode-org/cldr-json/tree/48.0.0,
%% with cldr-numbers-full, cldr-units-full, and cldr-core.
%%
%% cldr-json holds resolved data, so each locale holds what it inherits. The file keeps
%% for each locale only the entries that differ from its parent, and buoy_intl_cldr reads
%% an entry from the locale, then from each parent. The file is the external term format
%% of #{version, parents, locales, currency_digits, numbering_digits}, where each value of
%% locales is the external term format of the map of the locale's entries.
-mode(compile).

main([Dir, Output]) ->
    Read = fun(Path) ->
                   {ok, Text} = file:read_file(filename:join(Dir, Path)),
                   json:decode(Text)
           end,
    Supplemental = fun(Name) -> maps:get(list_to_binary(Name), maps:get(<<"supplemental">>, Read("cldr-core/supplemental/" ++ Name ++ ".json"))) end,
    Locales = lists:sort(filelib:wildcard("*", filename:join(Dir, "cldr-numbers-full/main"))),
    Parents = maps:get(<<"parentLocale">>, Supplemental("parentLocales")),
    Entries = maps:from_list([{list_to_binary(L), entries(Dir, Read, L)} || L <- Locales]),
    Deltas = maps:map(fun(L, E) -> term_to_binary(delta(E, resolved_parent(L, Parents, Entries)), [{compressed, 9}]) end,
                      Entries),
    Version = string:prefix(filename:basename(filename:dirname(filename:absname(Dir))), "cldr-json-"),
    Data = #{version => list_to_binary(Version), parents => Parents, locales => Deltas,
             currency_digits => currency_digits(Supplemental("currencyData")),
             numbering_digits => numbering_digits(Supplemental("numberingSystems"))},
    ok = filelib:ensure_dir(Output),
    ok = file:write_file(Output, term_to_binary(Data, [{compressed, 9}, deterministic]));
main(_) ->
    io:format(standard_error, "usage: scripts/intl-cldr.escript <cldr-json-dir> <output.etf>~n", []),
    halt(1).

%% The entries of the parent of L, which cldr-json resolves: the explicit
%% parent of parentLocales.json, else L without its last subtag.
resolved_parent(L, Parents, Entries) ->
    Parent = case Parents of
        #{L := P} -> P;
        _ ->
            case string:split(L, "-", trailing) of
                [Shorter, _] -> Shorter;
                [_] -> none
            end
    end,
    case Entries of
        #{Parent := E} -> E;
        _ when Parent =:= none -> #{};
        _ -> resolved_parent(Parent, Parents, Entries)
    end.

delta(Entries, Parent) ->
    maps:filter(fun(K, V) -> maps:get(K, Parent, '$none') =/= V end, Entries).

entries(Dir, Read, L) ->
    Locale = list_to_binary(L),
    Numbers = maps:get(<<"numbers">>, maps:get(Locale, maps:get(<<"main">>, Read("cldr-numbers-full/main/" ++ L ++ "/numbers.json")))),
    Currencies = maps:get(<<"currencies">>, maps:get(<<"numbers">>, maps:get(Locale, maps:get(<<"main">>,
                                                                                                Read("cldr-numbers-full/main/" ++ L ++ "/currencies.json"))))),
    UnitsPath = "cldr-units-full/main/" ++ L ++ "/units.json",
    Units = case filelib:is_file(filename:join(Dir, UnitsPath)) of
        true -> maps:get(<<"units">>, maps:get(Locale, maps:get(<<"main">>, Read(UnitsPath))));
        false -> #{}
    end,
    maps:from_list(number_entries(Numbers) ++ currency_entries(Currencies) ++ unit_entries(Units)).

%%% numbers.json

number_entries(Numbers) ->
    [{nu_default, maps:get(<<"defaultNumberingSystem">>, Numbers)},
     {min_grouping, binary_to_integer(maps:get(<<"minimumGroupingDigits">>, Numbers))}]
    ++ lists:append([system_entries(Kind, Nu, Value) || {Key, Value} <- maps:to_list(Numbers),
                                                        [Kind, Nu] <- [string:split(Key, "-numberSystem-")], Nu =/= Key]).

system_entries(<<"symbols">>, Nu, Symbols) ->
    [{{symbols, Nu}, Symbols}];
system_entries(<<"decimalFormats">>, Nu, Formats) ->
    [{{format, Nu, decimal}, maps:get(<<"standard">>, Formats)}
     | [{{compact, Nu, Width, decimal}, compact(maps:get(<<"decimalFormat">>, maps:get(atom_to_binary(Width), Formats)))}
        || Width <- [short, long], maps:is_key(atom_to_binary(Width), Formats)]];
system_entries(<<"scientificFormats">>, Nu, Formats) ->
    [{{format, Nu, scientific}, maps:get(<<"standard">>, Formats)}];
system_entries(<<"percentFormats">>, Nu, Formats) ->
    [{{format, Nu, percent}, maps:get(<<"standard">>, Formats)}];
system_entries(<<"currencyFormats">>, Nu, Formats) ->
    Spacing = maps:get(<<"currencySpacing">>, Formats),
    Side = fun(Name) ->
                   S = maps:get(Name, Spacing),
                   {maps:get(<<"currencyMatch">>, S), maps:get(<<"surroundingMatch">>, S), maps:get(<<"insertBetween">>, S)}
           end,
    [{{format, Nu, Kind}, Pattern} || {Name, Kind} <- [{<<"standard">>, currency}, {<<"accounting">>, accounting}],
                                      #{Name := Pattern} <- [Formats]]
    ++ [{{spacing, Nu}, {Side(<<"beforeCurrency">>), Side(<<"afterCurrency">>)}},
        {{currency_unit, Nu}, maps:from_list([{Count, P} || {<<"unitPattern-count-", Count/binary>>, P} <- maps:to_list(Formats)])}]
    ++ [{{compact, Nu, short, currency}, compact(maps:get(<<"standard">>, Short))} || #{<<"short">> := Short} <- [Formats]];
system_entries(<<"miscPatterns">>, Nu, Patterns) ->
    [{{misc, Nu}, Patterns}];
system_entries(_Kind, _Nu, _Value) ->
    [].

%% The compact patterns as [{Type, Count, Pattern}], such as {1000, <<"one">>,
%% <<"0K">>}, sorted by type, without the alphaNextToNumber variants that
%% ICU does not read.
compact(Patterns) ->
    lists:sort([{binary_to_integer(Type), Count, P} || {Key, P} <- maps:to_list(Patterns),
                                                       [Type, Count] <- [string:split(Key, "-count-")],
                                                       binary:match(Count, <<"-alt-">>) =:= nomatch]).

%%% currencies.json

currency_entries(Currencies) ->
    [{{currency, Code}, maps:from_list([{currency_key(K), V} || {K, V} <- maps:to_list(Names), currency_key(K) =/= skip])}
     || {Code, Names} <- maps:to_list(Currencies)].

currency_key(<<"displayName">>) -> name;
currency_key(<<"displayName-count-", Count/binary>>) -> Count;
currency_key(<<"symbol">>) -> symbol;
currency_key(<<"symbol-alt-narrow">>) -> narrow;
currency_key(_) -> skip.

%%% units.json

%% The patterns of each unit of ECMA-402 and of each unit of CLDR that is one
%% of them per another, by width: {unit, Width, Unit} => #{Count | per =>
%% Pattern}, the compound pattern {per, Width}, and the duration patterns of
%% the digital style {duration, Type}.
unit_entries(Units) ->
    Sanctioned = sanctioned(),
    [{{unit, binary_to_atom(Width), Unit}, unit_patterns(Value)}
     || Width <- [<<"long">>, <<"short">>, <<"narrow">>], #{Width := Table} <- [Units], {Key, Value} <- maps:to_list(Table),
        [_Category, Unit] <- [string:split(Key, "-")], is_wanted(Unit, Sanctioned)]
    ++ [{{per, binary_to_atom(Width)}, maps:get(<<"compoundUnitPattern">>, maps:get(<<"per">>, Table))}
        || Width <- [<<"long">>, <<"short">>, <<"narrow">>], #{Width := Table} <- [Units], maps:is_key(<<"per">>, Table)]
    ++ [{{duration, Type}, maps:get(<<"durationUnitPattern">>, V)} || {<<"durationUnit-type-", Type/binary>>, V} <- maps:to_list(Units)].

is_wanted(Unit, Sanctioned) ->
    lists:member(Unit, Sanctioned) orelse
        case string:split(Unit, "-per-") of
            [A, B] -> lists:member(A, Sanctioned) andalso lists:member(B, Sanctioned);
            _ -> false
        end.

unit_patterns(Value) ->
    maps:from_list([{Count, P} || {<<"unitPattern-count-", Count/binary>>, P} <- maps:to_list(Value)]
                   ++ [{per, P} || #{<<"perUnitPattern">> := P} <- [Value]]).

%% Table 1 of ECMA-402: the simple units that NumberFormat formats.
sanctioned() ->
    [<<"acre">>, <<"bit">>, <<"byte">>, <<"celsius">>, <<"centimeter">>, <<"day">>, <<"degree">>, <<"fahrenheit">>,
     <<"fluid-ounce">>, <<"foot">>, <<"gallon">>, <<"gigabit">>, <<"gigabyte">>, <<"gram">>, <<"hectare">>,
     <<"hour">>, <<"inch">>, <<"kilobit">>, <<"kilobyte">>, <<"kilogram">>, <<"kilometer">>, <<"liter">>,
     <<"megabit">>, <<"megabyte">>, <<"meter">>, <<"microsecond">>, <<"mile">>, <<"mile-scandinavian">>,
     <<"milliliter">>, <<"millimeter">>, <<"millisecond">>, <<"minute">>, <<"month">>, <<"nanosecond">>,
     <<"ounce">>, <<"percent">>, <<"petabyte">>, <<"pound">>, <<"second">>, <<"stone">>, <<"terabit">>,
     <<"terabyte">>, <<"week">>, <<"yard">>, <<"year">>].

%%% Supplemental data

%% CurrencyDigits: the fraction digits of each currency that differs from 2.
currency_digits(Data) ->
    maps:from_list([{Code, binary_to_integer(maps:get(<<"_digits">>, Info))}
                    || {Code, Info} <- maps:to_list(maps:get(<<"fractions">>, Data)), Code =/= <<"DEFAULT">>]).

%% The digits of each numbering system with simple digits, as code points.
numbering_digits(Data) ->
    maps:from_list([{Name, unicode:characters_to_list(maps:get(<<"_digits">>, Info))}
                    || {Name, Info} <- maps:to_list(Data), maps:get(<<"_type">>, Info) =:= <<"numeric">>]).
