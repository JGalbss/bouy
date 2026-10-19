%% The fields of a date pattern written out, as ICU's SimpleDateFormat writes
%% them for V8: each run of a pattern letter is a field of the date and time
%% record, numbers in the digits of the numbering system and names from the
%% calendar data of CLDR (buoy_intl_cldr), and quoted text is literal. The
%% result is a list of {Type, Text} with the part types of formatToParts.
-module(buoy_ref_intl_date_fields).

-export([format/3, tokens/1, part_type/1]).

%% The parts of Pattern for the record Fields in the context Ctx:
%% #{locale, cal, digits, zone, overrides}, where overrides maps a pattern
%% letter, or all, to the numbering system that writes its numbers. Fields holds year, month, day, weekday (1 is
%% Sunday), hour, minute, second, millisecond, era, offset, dst, and instant.
-spec format([char()], map(), map()) -> [{atom(), [char()]}].
format(Pattern, Fields, Ctx) ->
    Tokens = tokens(Pattern),
    HasMinute = lists:any(fun({field, $m, _}) -> true; (_) -> false end, Tokens),
    HasSecond = lists:any(fun({field, $s, _}) -> true; (_) -> false end, Tokens),
    Ctx1 = Ctx#{has_minute => HasMinute, has_second => HasSecond},
    [case Token of
         {literal, Text} -> {literal, Text};
         {field, C, Count} ->
             Overrides = maps:get(overrides, Ctx1),
             {part_type(C), field(C, Count, Fields, Ctx1#{numbering => maps:get(C, Overrides, maps:get(all, Overrides, none))})}
     end || Token <- Tokens].

%% The tokens of a pattern: {field, Char, Count} for a run of a letter and
%% {literal, Text} for the rest, with the quotes resolved.
-spec tokens([char()]) -> [{field, char(), pos_integer()} | {literal, [char()]}].
tokens([]) -> [];
tokens([$', $' | Rest]) -> literal("'", tokens(Rest));
tokens([$' | Rest]) ->
    {Text, After} = quoted(Rest, []),
    literal(Text, tokens(After));
tokens([C | _] = All) when (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) ->
    {Run, Rest} = lists:splitwith(fun(X) -> X =:= C end, All),
    [{field, C, length(Run)} | tokens(Rest)];
tokens([C | Rest]) -> literal([C], tokens(Rest)).

literal(Text, [{literal, More} | Rest]) -> [{literal, Text ++ More} | Rest];
literal(Text, Rest) -> [{literal, Text} | Rest].

quoted([], Acc) -> {lists:reverse(Acc), []};
quoted([$', $' | Rest], Acc) -> quoted(Rest, [$' | Acc]);
quoted([$' | Rest], Acc) -> {lists:reverse(Acc), Rest};
quoted([C | Rest], Acc) -> quoted(Rest, [C | Acc]).

%% The part type of a pattern letter (V8's IcuDateFieldIdToDateType).
-spec part_type(char()) -> atom().
part_type($G) -> era;
part_type(C) when C =:= $y; C =:= $Y; C =:= $u -> year;
part_type($U) -> yearName;
part_type($r) -> relatedYear;
part_type(C) when C =:= $M; C =:= $L -> month;
part_type($d) -> day;
part_type(C) when C =:= $h; C =:= $H; C =:= $k; C =:= $K -> hour;
part_type($m) -> minute;
part_type($s) -> second;
part_type(C) when C =:= $E; C =:= $e; C =:= $c -> weekday;
part_type(C) when C =:= $a; C =:= $b; C =:= $B -> dayPeriod;
part_type(C) when C =:= $z; C =:= $Z; C =:= $O; C =:= $v; C =:= $V; C =:= $X; C =:= $x -> timeZoneName;
part_type($S) -> fractionalSecond;
part_type(_) -> literal.

%%% The fields

field($G, Count, F, Ctx) ->
    Width = case Count of 4 -> <<"wide">>; 5 -> <<"narrow">>; _ -> <<"abbreviated">> end,
    Era = integer_to_binary(maps:get(era, F)),
    case calendar(Ctx, [<<"eras">>, Width, Era]) of
        Name when is_binary(Name) -> unicode:characters_to_list(Name);
        _ -> binary_to_list(Era)
    end;
field(C, Count, F, Ctx) when C =:= $y; C =:= $Y; C =:= $u ->
    Year = case {maps:get(numbering, Ctx), maps:get(era_year, F)} of
        %% ICU drops the millennium of a Hebrew year in Hebrew numerals.
        {<<"hebr">>, Y} when Y > 5000, Y < 6000 -> Y - 5000;
        {_, Y} -> Y
    end,
    case Count of
        2 -> number(Ctx, abs(Year) rem 100, 2);
        _ -> number(Ctx, Year, Count)
    end;
field($r, Count, F, Ctx) -> number(Ctx, maps:get(related_year, F, maps:get(year, F)), Count);
field($U, _Count, F, Ctx) ->
    Cyclic = maps:get(cyclic, F, maps:get(era_year, F)),
    indexed(Ctx, [<<"cyclicNameSets">>, <<"years">>, <<"format">>, <<"abbreviated">>], Cyclic - 1, number(Ctx, Cyclic, 1));
field(C, Count, F, Ctx) when C =:= $M; C =:= $L ->
    Month = maps:get(month, F),
    Context = case C of $M -> <<"format">>; $L -> <<"stand-alone">> end,
    {Name, PatternPath} = case Count of
        _ when Count =< 2 -> {number(Ctx, Month, Count), [<<"numeric">>, <<"all">>]};
        _ ->
            Width = case Count of 3 -> <<"abbreviated">>; 5 -> <<"narrow">>; _ -> <<"wide">> end,
            {names(Ctx, [<<"monthNames">>, Context, Width], [<<"monthNames">>, <<"format">>, Width],
                   maps:get(month_name, F), integer_to_list(Month)), [Context, Width]}
    end,
    leap_month(Ctx, maps:get(leap, F), PatternPath, Name);
field($d, Count, F, Ctx) -> number(Ctx, maps:get(day, F), Count);
field($E, Count, F, Ctx) -> weekday(Ctx, format, max(Count, 3), F);
field($e, Count, F, Ctx) when Count =< 2 -> number(Ctx, local_weekday(F, Ctx), Count);
field($e, Count, F, Ctx) -> weekday(Ctx, format, Count, F);
field($c, Count, F, Ctx) when Count =< 2 -> number(Ctx, local_weekday(F, Ctx), 1);
field($c, Count, F, Ctx) -> weekday(Ctx, 'stand-alone', Count, F);
field($a, Count, F, Ctx) -> am_pm(Ctx, Count, F);
field($b, Count, F, Ctx) ->
    Hour = maps:get(hour, F),
    Exact = (not maps:get(has_minute, Ctx) orelse maps:get(minute, F) =:= 0) andalso
        (not maps:get(has_second, Ctx) orelse maps:get(second, F) =:= 0),
    case Hour =:= 12 andalso Exact andalso period(Ctx, Count, <<"noon">>) of
        Name when is_list(Name) -> Name;
        _ -> am_pm(Ctx, Count, F)
    end;
field($B, Count, F, Ctx) -> flexible(Ctx, Count, F);
field($h, Count, F, Ctx) -> number(Ctx, case maps:get(hour, F) rem 12 of 0 -> 12; H -> H end, Count);
field($H, Count, F, Ctx) -> number(Ctx, maps:get(hour, F), Count);
field($K, Count, F, Ctx) -> number(Ctx, maps:get(hour, F) rem 12, Count);
field($k, Count, F, Ctx) -> number(Ctx, case maps:get(hour, F) of 0 -> 24; H -> H end, Count);
field($m, Count, F, Ctx) -> number(Ctx, maps:get(minute, F), Count);
field($s, Count, F, Ctx) -> number(Ctx, maps:get(second, F), Count);
field($S, Count, F, Ctx) ->
    Ms = maps:get(millisecond, F),
    Digits = lists:duplicate(3 - length(integer_to_list(Ms)), $0) ++ integer_to_list(Ms),
    Text = case Count =< 3 of
        true -> lists:sublist(Digits, Count);
        false -> Digits ++ lists:duplicate(Count - 3, $0)
    end,
    localize(Ctx, Text);
field(C, Count, F, Ctx) when C =:= $z; C =:= $O; C =:= $v ->
    Field = case C of
        $O -> "O";
        _ -> lists:duplicate(Count, C)
    end,
    case C of
        $O -> buoy_ref_intl_zone_names:gmt(maps:get(locale, Ctx), maps:get(offset, F), Count >= 4, maps:get(digits, Ctx));
        _ -> buoy_ref_intl_zone_names:name(maps:get(locale, Ctx), Field, maps:get(zone, Ctx), maps:get(instant, F),
                                           {maps:get(offset, F), maps:get(dst, F)}, maps:get(digits, Ctx))
    end;
field(C, Count, _F, _Ctx) -> lists:duplicate(Count, C).

%% The month name in the leap month pattern of the calendar, as "{0}bis",
%% when the month is a leap month and the calendar has such patterns.
leap_month(Ctx, true, Path, Name) ->
    case calendar(Ctx, [<<"monthPatterns">> | Path] ++ [<<"leap">>]) of
        Pattern when is_binary(Pattern) -> lists:flatten(string:replace(unicode:characters_to_list(Pattern), "{0}", Name));
        _ -> Name
    end;
leap_month(_Ctx, false, _Path, Name) -> Name.

%% A number in the numbering system of the field's override, else in the
%% digits of the format's numbering system, padded to Min digits.
number(#{numbering := <<"hebr">>}, N, _Min) when N > 0 -> hebrew(N);
number(#{numbering := <<"hanidays">>}, N, _Min) when N > 0, N =< 30 -> hanidays(N);
number(#{numbering := <<"jpanyear">>}, 1, _Min) -> [16#5143];
number(#{numbering := <<"hanidec">>} = Ctx, N, Min) ->
    number(Ctx#{numbering := none, digits := buoy_intl_cldr:numbering_digits(<<"hanidec">>)}, N, Min);
number(Ctx, N, Min) ->
    Text = integer_to_list(abs(N)),
    Padded = lists:duplicate(max(0, Min - length(Text)), $0) ++ Text,
    localize(Ctx, case N < 0 of true -> [$- | Padded]; false -> Padded end).

%% A number in Hebrew letters, as ICU's hebr rules write it: each thousand
%% apart, 15 and 16 as 9+6 and 9+7, a geresh after a single letter, and
%% gershayim before the last of several.
hebrew(N) when N >= 1000, N rem 1000 > 0 -> hebrew(N div 1000) ++ hebrew(N rem 1000);
hebrew(N) when N >= 1000 -> hebrew(N div 1000);
hebrew(N) ->
    case hebrew_letters(N) of
        [Letter] -> [Letter, 16#05F3];
        Letters ->
            {Init, [Last]} = lists:split(length(Letters) - 1, Letters),
            Init ++ [16#05F4, Last]
    end.

hebrew_letters(0) -> [];
hebrew_letters(N) when N >= 400 -> [16#05EA | hebrew_letters(N - 400)];
hebrew_letters(N) when N >= 100 -> [16#05E6 + N div 100 | hebrew_letters(N rem 100)];
hebrew_letters(N) when N =:= 15; N =:= 16 -> [16#05D8, 16#05D0 + N - 10];
hebrew_letters(N) when N >= 10 ->
    [element(N div 10, {16#05D9, 16#05DB, 16#05DC, 16#05DE, 16#05E0, 16#05E1, 16#05E2, 16#05E4, 16#05E6}) | hebrew_letters(N rem 10)];
hebrew_letters(N) -> [16#05D0 + N - 1].

%% A day of a Chinese month as ICU's hanidays rules write it: 初一 to 初十,
%% then 十一 to 二十, 廿一 to 廿九, and 三十.
hanidays(N) ->
    Digit = fun(D) -> element(D, {16#4E00, 16#4E8C, 16#4E09, 16#56DB, 16#4E94, 16#516D, 16#4E03, 16#516B, 16#4E5D, 16#5341}) end,
    case N of
        _ when N =< 10 -> [16#521D, Digit(N)];
        _ when N < 20 -> [16#5341, Digit(N - 10)];
        20 -> [Digit(2), 16#5341];
        30 -> [Digit(3), 16#5341];
        _ -> [16#5EFF, Digit(N - 20)]
    end.

localize(Ctx, Text) ->
    case maps:get(digits, Ctx) of
        undefined -> Text;
        Digits -> [case C >= $0 andalso C =< $9 of true -> lists:nth(C - $0 + 1, Digits); false -> C end || C <- Text]
    end.

%% The calendar resource at Path under calendar/<cal> of ICU's data, else
%% under calendar/gregorian.
calendar(#{locale := Locale, cal := Cal}, Path) ->
    buoy_ref_intl_date_skeleton:calendar_resource(Locale, Cal, Path, undefined).

%% The name at Index (from 0) of an array of the calendar, else Fallback.
indexed(Ctx, Path, Index, Fallback) ->
    case calendar(Ctx, Path) of
        List when is_list(List), Index >= 0, Index < length(List) -> unicode:characters_to_list(lists:nth(Index + 1, List));
        _ -> Fallback
    end.

%% The name of the context's array, else of the format context's.
names(Ctx, Path, FormatPath, Index, Fallback) ->
    case indexed(Ctx, Path, Index, none) of
        none -> indexed(Ctx, FormatPath, Index, Fallback);
        Name -> Name
    end.

weekday(Ctx, Context, Count, F) ->
    Width = case Count of
        4 -> <<"wide">>;
        5 -> <<"narrow">>;
        6 -> <<"short">>;
        _ -> <<"abbreviated">>
    end,
    Ctx1 = case Context of format -> <<"format">>; 'stand-alone' -> <<"stand-alone">> end,
    names(Ctx, [<<"dayNames">>, Ctx1, Width], [<<"dayNames">>, <<"format">>, Width], maps:get(weekday, F) - 1,
          integer_to_list(maps:get(weekday, F))).

%% The weekday counted from the first day of the week of the locale's region.
local_weekday(F, #{locale := Locale}) ->
    First = case buoy_ref_intl_data:week(region_of(Locale)) of
        {Day, _} -> Day;
        none -> 7
    end,
    Iso = case maps:get(weekday, F) of 1 -> 7; W -> W - 1 end,
    ((Iso - First + 7) rem 7) + 1.

region_of(Locale) ->
    case buoy_ref_intl:region(Locale) of
        undefined -> <<"001">>;
        R -> R
    end.

%% The AM/PM marker of the hour: AmPmMarkersAbbr, AmPmMarkers for 4
%% letters, AmPmMarkersNarrow for 5.
am_pm(Ctx, Count, F) ->
    Table = case Count of
        4 -> <<"AmPmMarkers">>;
        5 -> <<"AmPmMarkersNarrow">>;
        _ -> <<"AmPmMarkersAbbr">>
    end,
    Index = case maps:get(hour, F) < 12 of true -> 0; false -> 1 end,
    indexed(Ctx, [Table], Index, case Index of 0 -> "AM"; 1 -> "PM" end).

%% A day period name of the format context, or undefined.
period(Ctx, Count, Key) ->
    Width = case Count of
        4 -> <<"wide">>;
        5 -> <<"narrow">>;
        _ when Count > 5 -> <<"wide">>;
        _ -> <<"abbreviated">>
    end,
    %% DateFormatSymbols fills a missing wide or narrow name with the abbreviated one.
    case {calendar(Ctx, [<<"dayPeriod">>, <<"format">>, Width, Key]), calendar(Ctx, [<<"dayPeriod">>, <<"format">>, <<"abbreviated">>, Key])} of
        {Name, _} when is_binary(Name) -> unicode:characters_to_list(Name);
        {_, Name} when is_binary(Name) -> unicode:characters_to_list(Name);
        _ -> undefined
    end.

%% The flexible day period of the locale's language for the hour, with noon
%% when the time is exactly noon; am and pm fall back to the a field.
flexible(#{locale := Locale} = Ctx, Count, F) ->
    Rules = day_period_rules(buoy_ref_intl:language(Locale)),
    case Rules of
        undefined -> am_pm(Ctx, Count, F);
        _ ->
            Hour = maps:get(hour, F),
            Minute = case maps:get(has_minute, Ctx) of true -> maps:get(minute, F); false -> 0 end,
            Second = case maps:get(has_second, Ctx) of true -> maps:get(second, F); false -> 0 end,
            Noon = Hour =:= 12 andalso Minute =:= 0 andalso Second =:= 0 andalso lists:keymember(<<"noon">>, 1, Rules),
            Period = case Noon of
                true -> <<"noon">>;
                false -> for_hour(Rules, Hour)
            end,
            Name = case Period of
                P when P =:= <<"am">>; P =:= <<"pm">>; P =:= undefined -> undefined;
                P -> period(Ctx, Count, P)
            end,
            case Name of
                undefined when Period =:= <<"noon">> ->
                    case for_hour(Rules, Hour) of
                        P2 when P2 =:= <<"am">>; P2 =:= <<"pm">>; P2 =:= undefined -> am_pm(Ctx, Count, F);
                        P2 -> case period(Ctx, Count, P2) of undefined -> am_pm(Ctx, Count, F); N -> N end
                    end;
                undefined -> am_pm(Ctx, Count, F);
                _ -> Name
            end
    end.

%% The day period rules of a language in ICU's dayPeriods data:
%% [{Period, {at, Minute} | {from, Minute, Before}}], or undefined.
day_period_rules(Language) ->
    Data = buoy_intl_cldr:supplemental(day_periods),
    case maps:get(Language, maps:get(<<"locales">>, Data), undefined) of
        undefined -> undefined;
        Set ->
            [{Name, case Rule of
                        #{<<"at">> := At} -> {at, minutes(At)};
                        #{<<"from">> := From, <<"before">> := Before} -> {from, minutes(From), minutes(Before)}
                    end} || {Name, Rule} <- maps:to_list(maps:get(Set, maps:get(<<"rules">>, Data)))]
    end.

minutes(<<H:2/binary, ":", M:2/binary>>) -> binary_to_integer(H) * 60 + binary_to_integer(M).

%% DayPeriodRules::getDayPeriodForHour: the period whose span holds the hour.
for_hour(Rules, Hour) ->
    Minute = Hour * 60,
    case [Name || {Name, {from, From, Before}} <- Rules, in_span(Minute, From, Before)] of
        [Name | _] -> Name;
        [] -> undefined
    end.

in_span(M, From, Before) when From < Before -> M >= From andalso M < Before;
in_span(M, From, Before) -> M >= From orelse M < Before.
