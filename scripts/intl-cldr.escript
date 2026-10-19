#!/usr/bin/env escript
%% Writes crates/buoy-native/data/cldr.etf, the CLDR locale data of Intl that the
%% formatters read through buoy_intl_cldr: the number symbols and patterns, the currency
%% names, and the unit patterns of every locale of CLDR, as the ICU of Node holds them.
%%
%% Usage: scripts/intl-cldr.escript <cldr-json-dir> <output.etf>
%%
%% <cldr-json-dir> is the cldr-json directory of the cldr-json release that Node's ICU uses
%% (process.versions.cldr), such as https://github.com/unicode-org/cldr-json/tree/48.0.0,
%% with cldr-numbers-full, cldr-units-full, cldr-misc-full, cldr-dates-full, cldr-localenames-full, and
%% cldr-core.
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
    Tz = maps:get(<<"tz">>, maps:get(<<"u">>, maps:get(<<"keyword">>, Read("cldr-bcp47/bcp47/timezone.json")))),
    Data = #{version => list_to_binary(Version), parents => Parents, locales => Deltas,
             currency_digits => currency_digits(Supplemental("currencyData")),
             numbering_digits => numbering_digits(Supplemental("numberingSystems")),
             metazones => metazones(maps:get(<<"metazoneInfo">>, Supplemental("metaZones"))),
             golden_zones => golden_zones(maps:get(<<"metazones">>, Supplemental("metaZones"))),
             primary_zones => Supplemental("primaryZones"),
             zone_regions => zone_regions(Tz),
             zone_canonical => zone_canonical(Tz),
             day_periods => day_periods(maps:get(<<"dayPeriodRuleSet">>, maps:get(<<"supplemental">>, Read("cldr-core/supplemental/dayPeriods.json"))))},
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
    Lists = maps:get(<<"listPatterns">>, maps:get(Locale, maps:get(<<"main">>, Read("cldr-misc-full/main/" ++ L ++ "/listPatterns.json")))),
    Fields = maps:get(<<"fields">>, maps:get(<<"dates">>, maps:get(Locale, maps:get(<<"main">>, Read("cldr-dates-full/main/" ++ L ++ "/dateFields.json"))))),
    Names = fun(File) ->
                    Path = "cldr-localenames-full/main/" ++ L ++ "/" ++ File ++ ".json",
                    case filelib:is_file(filename:join(Dir, Path)) of
                        true -> maps:get(<<"localeDisplayNames">>, maps:get(Locale, maps:get(<<"main">>, Read(Path))));
                        false -> #{}
                    end
            end,
    Dates = fun(File) ->
                    maps:get(<<"dates">>, maps:get(Locale, maps:get(<<"main">>, Read("cldr-dates-full/main/" ++ L ++ "/" ++ File ++ ".json"))))
            end,
    Gregorian = maps:get(<<"gregorian">>, maps:get(<<"calendars">>, Dates("ca-gregorian"))),
    maps:from_list(number_entries(Numbers) ++ currency_entries(Currencies) ++ unit_entries(Units) ++ list_entries(Lists)
                   ++ field_entries(Fields) ++ name_entries(Names) ++ calendar_entries(<<"gregory">>, Gregorian)
                   ++ zone_name_entries(maps:get(<<"timeZoneNames">>, Dates("timeZoneNames")))).

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

%%% listPatterns.json

%% The list patterns {list, Type, Style} => #{start, middle, 'end', two},
%% with Type standard, or, or unit and Style long, short, or narrow.
list_entries(Lists) ->
    [{{list, binary_to_atom(Type), binary_to_atom(Style)},
      #{start => maps:get(<<"start">>, P), middle => maps:get(<<"middle">>, P), 'end' => maps:get(<<"end">>, P),
        two => maps:get(<<"2">>, P)}}
     || {<<"listPattern-type-", Name/binary>>, P} <- maps:to_list(Lists),
        {Type, Style} <- [case binary:split(Name, <<"-">>) of [T] -> {T, <<"long">>}; [T, S] -> {T, S} end]].

%%% dateFields.json

%% The fields of dates by width, {field, Name, Width} => #{name, relative =>
%% #{Offset => Text}, future | past => #{Count => Pattern}}, with Width long,
%% short, or narrow.
field_entries(Fields) ->
    [{{field, Name, binary_to_atom(Width)}, field(Value)}
     || {Key, Value} <- maps:to_list(Fields),
        {Name, Width} <- [case binary:split(Key, <<"-">>) of [N] -> {N, <<"long">>}; [N, W] -> {N, W} end]].

field(Value) ->
    Patterns = fun(Tense) ->
                       maps:from_list([{Count, P} || {<<"relativeTimePattern-count-", Count/binary>>, P}
                                                         <- maps:to_list(maps:get(Tense, Value, #{}))])
               end,
    #{name => maps:get(<<"displayName">>, Value, undefined),
      relative => maps:from_list([{Offset, T} || {<<"relative-type-", Offset/binary>>, T} <- maps:to_list(Value)]),
      future => Patterns(<<"relativeTime-type-future">>), past => Patterns(<<"relativeTime-type-past">>)}.

%%% The display names of cldr-localenames-full

%% {Kind, Code} => Name for the languages, regions, scripts, and variants,
%% with Kind language, region, script, or variant, and Kind_short for the
%% short names; {calendar_name, Type} => Name; and display_pattern =>
%% {Pattern, Separator, KeyTypePattern}.
name_entries(Names) ->
    Coded = [{Kind, Code} || {File, Table, Kind} <- [{"languages", <<"languages">>, language}, {"territories", <<"territories">>, region},
                                                     {"scripts", <<"scripts">>, script}, {"variants", <<"variants">>, variant}],
                             Code <- maps:to_list(maps:get(Table, Names(File), #{}))],
    Display = Names("localeDisplayNames"),
    Pattern = maps:get(<<"localeDisplayPattern">>, Display, #{}),
    [{name_key(Kind, Code), Name} || {Kind, {Code, Name}} <- Coded, name_key(Kind, Code) =/= skip]
    ++ [{name_key(calendar_name, Type), Name} || {Type, Name} <- maps:to_list(maps:get(<<"calendar">>, maps:get(<<"types">>, Display, #{}), #{})),
                                                 name_key(calendar_name, Type) =/= skip]
    ++ [{display_pattern, {maps:get(<<"localePattern">>, Pattern), maps:get(<<"localeSeparator">>, Pattern),
                           maps:get(<<"localeKeyTypePattern">>, Pattern)}} || map_size(Pattern) > 0].

%% The key of a name: the short names of the alt-short entries, and no
%% other alternative.
name_key(Kind, Code) ->
    case binary:split(Code, <<"-alt-">>) of
        [Plain] -> {Kind, Plain};
        [Short, <<"short">>] -> {list_to_atom(atom_to_list(Kind) ++ "_short"), Short};
        _ -> skip
    end.

%%% Calendars of cldr-dates-full

%% The names, patterns, and skeletons of a calendar, {cal, Calendar, ...},
%% without the alternative and plural variants that ICU does not read.
calendar_entries(Cal, C) ->
    Named = fun(Table, Key) -> [{{cal, Cal, Key, Context, binary_to_atom(Width)}, plain(Names)}
                                || {Context0, Widths} <- maps:to_list(maps:get(Table, C, #{})),
                                   Context <- [binary_to_atom(Context0)], {Width, Names} <- maps:to_list(Widths)] end,
    Eras = maps:get(<<"eras">>, C, #{}),
    DateTime = maps:get(<<"dateTimeFormats">>, C, #{}),
    AtTime = maps:get(<<"standard">>, maps:get(<<"dateTimeFormats-atTime">>, C, #{}), #{}),
    Intervals = maps:get(<<"intervalFormats">>, DateTime, #{}),
    Named(<<"months">>, months) ++ Named(<<"days">>, days) ++ Named(<<"dayPeriods">>, day_periods)
    ++ [{{cal, Cal, eras, Width}, plain(maps:get(Key, Eras))} || {Key, Width} <- [{<<"eraNames">>, long}, {<<"eraAbbr">>, short},
                                                                                 {<<"eraNarrow">>, narrow}], maps:is_key(Key, Eras)]
    ++ [{{cal, Cal, Kind, binary_to_atom(Style)}, P} || {Table, Kind} <- [{<<"dateFormats">>, date_format}, {<<"timeFormats">>, time_format}],
                                                       {Style, P} <- maps:to_list(maps:get(Table, C, #{})), is_plain_key(Style)]
    ++ [{{cal, Cal, date_time, binary_to_atom(Style)}, P} || {Style, P} <- maps:to_list(DateTime), is_binary(P), is_plain_key(Style)]
    ++ [{{cal, Cal, date_time_at, binary_to_atom(Style)}, P} || {Style, P} <- maps:to_list(AtTime), is_plain_key(Style)]
    ++ [{{cal, Cal, available, Skeleton}, P} || {Skeleton, P} <- maps:to_list(maps:get(<<"availableFormats">>, DateTime, #{})),
                                               is_plain_key(Skeleton)]
    ++ [{{cal, Cal, append, Field}, P} || {Field, P} <- maps:to_list(maps:get(<<"appendItems">>, DateTime, #{}))]
    ++ [{{cal, Cal, interval, Skeleton}, plain(Diffs)} || {Skeleton, Diffs} <- maps:to_list(Intervals), is_map(Diffs),
                                                         is_plain_key(Skeleton)]
    ++ [{{cal, Cal, interval_fallback}, P} || #{<<"intervalFormatFallback">> := P} <- [Intervals]].

plain(Map) -> maps:filter(fun(K, _) -> is_plain_key(K) end, Map).

is_plain_key(Key) -> binary:match(Key, [<<"-alt-">>, <<"-count-">>]) =:= nomatch.

%%% timeZoneNames.json

%% The formats of time zone names {tz_format, Name}, the names and exemplar
%% city of each zone with its own {tz_zone, Id}, and the names of each
%% metazone {tz_meta, Name}.
zone_name_entries(T) ->
    [{{tz_format, Key}, V} || {Key, V} <- maps:to_list(T), is_binary(V)]
    ++ [{{tz_zone, Id}, V} || {Id, V} <- zones(<<>>, maps:get(<<"zone">>, T, #{}))]
    ++ [{{tz_meta, Name}, V} || {Name, V} <- maps:to_list(maps:get(<<"metazone">>, T, #{}))].

%% The zones of the nested zone table, as {"Area/City", Names}.
zones(Prefix, Table) ->
    lists:append([case is_zone(V) of
                       true -> [{<<Prefix/binary, K/binary>>, V}];
                       false -> zones(<<Prefix/binary, K/binary, "/">>, V)
                   end || {K, V} <- maps:to_list(Table), is_map(V)]).

is_zone(V) ->
    maps:is_key(<<"exemplarCity">>, V) orelse maps:is_key(<<"long">>, V) orelse maps:is_key(<<"short">>, V)
        orelse maps:is_key(<<"_type">>, V).

%%% Supplemental data

%% The metazones of each zone over time, #{Zone => [{From, To, Metazone}]},
%% with From and To in milliseconds since the epoch or undefined.
metazones(Info) ->
    maps:from_list([{Zone, [{epoch(maps:get(<<"_from">>, U, undefined)), epoch(maps:get(<<"_to">>, U, undefined)), maps:get(<<"_mzone">>, U)}
                            || #{<<"usesMetazone">> := U} <- Uses]}
                    || {Zone, Uses} <- zones(<<>>, maps:get(<<"timezone">>, Info), fun is_list/1)]).

zones(Prefix, Table, IsLeaf) ->
    lists:append([case IsLeaf(V) of
                       true -> [{<<Prefix/binary, K/binary>>, V}];
                       false -> zones(<<Prefix/binary, K/binary, "/">>, V, IsLeaf)
                   end || {K, V} <- maps:to_list(Table)]).

%% "1970-01-01 00:00" as milliseconds since the epoch.
epoch(undefined) -> undefined;
epoch(<<Y:4/binary, "-", Mo:2/binary, "-", D:2/binary, " ", H:2/binary, ":", Mi:2/binary>>) ->
    Seconds = calendar:datetime_to_gregorian_seconds({{binary_to_integer(Y), binary_to_integer(Mo), binary_to_integer(D)},
                                                      {binary_to_integer(H), binary_to_integer(Mi), 0}})
        - calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
    Seconds * 1000.

%% The zone of each metazone in each territory, #{{Metazone, Territory} => Zone}.
golden_zones(MapZones) ->
    maps:from_list([{{maps:get(<<"_other">>, Z), maps:get(<<"_territory">>, Z)}, maps:get(<<"_type">>, Z)}
                    || #{<<"mapZone">> := Z} <- MapZones]).

%% The region of each zone identifier and alias: the first two letters of
%% its BCP 47 key, or its _region.
zone_regions(Tz) ->
    maps:from_list([{Alias, Region} || {Key, V} <- maps:to_list(Tz), is_map(V), maps:is_key(<<"_alias">>, V), Key =/= <<"unk">>,
                                        Region <- [case V of #{<<"_region">> := R} -> R; _ -> string:uppercase(binary:part(Key, 0, 2)) end],
                                        Alias <- binary:split(maps:get(<<"_alias">>, V), <<" ">>, [global, trim_all])]).

%% The CLDR canonical identifier of each zone identifier and alias: the first
%% alias of its BCP 47 key, which names the zone in CLDR's data.
zone_canonical(Tz) ->
    maps:from_list([{Alias, hd(Aliases)} || {Key, V} <- maps:to_list(Tz), is_map(V), maps:is_key(<<"_alias">>, V), Key =/= <<"unk">>,
                                            Aliases <- [binary:split(maps:get(<<"_alias">>, V), <<" ">>, [global, trim_all])],
                                            Alias <- Aliases]).

%% The day period rules of each language, [{Period, {at, Minute}} |
%% {Period, {from, Minute, Before}}], with minutes since midnight.
day_periods(Rules) ->
    maps:map(fun(_, Periods) ->
                     [{Name, case R of
                                 #{<<"_at">> := At} -> {at, minutes(At)};
                                 #{<<"_from">> := From, <<"_before">> := Before} -> {from, minutes(From), minutes(Before)}
                             end} || {Name, R} <- maps:to_list(Periods)]
             end, Rules).

minutes(<<H:2/binary, ":", M:2/binary>>) -> binary_to_integer(H) * 60 + binary_to_integer(M).

%% CurrencyDigits: the fraction digits of each currency that differs from 2.
currency_digits(Data) ->
    maps:from_list([{Code, binary_to_integer(maps:get(<<"_digits">>, Info))}
                    || {Code, Info} <- maps:to_list(maps:get(<<"fractions">>, Data)), Code =/= <<"DEFAULT">>]).

%% The digits of each numbering system with simple digits, as code points.
numbering_digits(Data) ->
    maps:from_list([{Name, unicode:characters_to_list(maps:get(<<"_digits">>, Info))}
                    || {Name, Info} <- maps:to_list(Data), maps:get(<<"_type">>, Info) =:= <<"numeric">>]).
