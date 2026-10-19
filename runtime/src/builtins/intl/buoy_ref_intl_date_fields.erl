%% The fields of a date pattern written out, as ICU's SimpleDateFormat writes
%% them for V8: each run of a pattern letter is a field of the date and time
%% record, numbers in the digits of the numbering system and names from the
%% calendar data of CLDR (buoy_intl_cldr), and quoted text is literal. The
%% result is a list of {Type, Text} with the part types of formatToParts.
-module(buoy_ref_intl_date_fields).

-export([format/3, tokens/1, part_type/1]).

%% The parts of Pattern for the record Fields in the context Ctx:
%% #{locale, cal, digits, zone}. Fields holds year, month, day, weekday (1 is
%% Sunday), hour, minute, second, millisecond, era, offset, dst, and instant.
-spec format([char()], map(), map()) -> [{atom(), [char()]}].
format(Pattern, Fields, Ctx) ->
    Tokens = tokens(Pattern),
    HasMinute = lists:any(fun({field, $m, _}) -> true; (_) -> false end, Tokens),
    HasSecond = lists:any(fun({field, $s, _}) -> true; (_) -> false end, Tokens),
    Ctx1 = Ctx#{has_minute => HasMinute, has_second => HasSecond},
    [case Token of
         {literal, Text} -> {literal, Text};
         {field, C, Count} -> {part_type(C), field(C, Count, Fields, Ctx1)}
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
    name(Ctx, {eras, width(Count)}, integer_to_binary(maps:get(era, F)));
field(C, Count, F, Ctx) when C =:= $y; C =:= $Y; C =:= $u ->
    Year = maps:get(era_year, F),
    case Count of
        2 -> number(Ctx, abs(Year) rem 100, 2);
        _ -> number(Ctx, Year, Count)
    end;
field($r, Count, F, Ctx) -> number(Ctx, maps:get(related_year, F, maps:get(year, F)), Count);
field($U, _Count, F, Ctx) -> number(Ctx, maps:get(era_year, F), 1);
field(C, Count, F, Ctx) when C =:= $M; C =:= $L ->
    Month = maps:get(month, F),
    case Count of
        1 -> number(Ctx, Month, 1);
        2 -> number(Ctx, Month, 2);
        _ ->
            Context = case C of $M -> format; $L -> 'stand-alone' end,
            name(Ctx, {months, Context, width(Count)}, maps:get(month_key, F, integer_to_binary(Month)))
    end;
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

width(Count) when Count =< 3 -> short;
width(4) -> long;
width(5) -> narrow;
width(_) -> long.

%% A number in the digits of the numbering system, padded to Min digits.
number(Ctx, N, Min) ->
    Text = integer_to_list(abs(N)),
    Padded = lists:duplicate(max(0, Min - length(Text)), $0) ++ Text,
    localize(Ctx, case N < 0 of true -> [$- | Padded]; false -> Padded end).

localize(Ctx, Text) ->
    case maps:get(digits, Ctx) of
        undefined -> Text;
        Digits -> [case C >= $0 andalso C =< $9 of true -> lists:nth(C - $0 + 1, Digits); false -> C end || C <- Text]
    end.

%% A name of the calendar data: the table of the key, then the format
%% context, then the gregorian calendar's.
name(Ctx, Table, Key) ->
    case lookup(Ctx, Table) of
        #{Key := Name} -> unicode:characters_to_list(Name);
        _ -> binary_to_list(Key)
    end.

lookup(#{locale := Locale, cal := Cal}, Table) ->
    Keys = case Table of
        {months, Context, Width} -> [{months, Context, cldr_width(months, Width)}, {months, format, cldr_width(months, Width)}];
        {days, Context, Width} -> [{days, Context, Width}, {days, format, Width}];
        {day_periods, Context, Width} -> [{day_periods, Context, Width}, {day_periods, format, Width}];
        {eras, Width} -> [{eras, Width}]
    end,
    first([buoy_intl_cldr:get(Locale, list_to_tuple([cal, C | tuple_to_list(K)])) || C <- lists:usort([Cal, <<"gregory">>]), K <- Keys]).

first([]) -> #{};
first([undefined | Rest]) -> first(Rest);
first([Map | _]) -> Map.

cldr_width(_, short) -> abbreviated;
cldr_width(_, long) -> wide;
cldr_width(_, narrow) -> narrow.

weekday(Ctx, Context, Count, F) ->
    Width = case Count of
        3 -> abbreviated;
        4 -> wide;
        5 -> narrow;
        6 -> short;
        _ -> abbreviated
    end,
    Key = element(maps:get(weekday, F), {<<"sun">>, <<"mon">>, <<"tue">>, <<"wed">>, <<"thu">>, <<"fri">>, <<"sat">>}),
    case lookup(Ctx, {days, Context, Width}) of
        #{Key := Name} -> unicode:characters_to_list(Name);
        _ -> binary_to_list(Key)
    end.

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

am_pm(Ctx, Count, F) ->
    Key = case maps:get(hour, F) < 12 of
        true -> <<"am">>;
        false -> <<"pm">>
    end,
    case period(Ctx, Count, Key) of
        undefined -> binary_to_list(string:uppercase(Key));
        Name -> Name
    end.

period(Ctx, Count, Key) ->
    Width = case Count of
        4 -> wide;
        5 -> narrow;
        _ when Count > 5 -> wide;
        _ -> abbreviated
    end,
    case lookup(Ctx, {day_periods, format, Width}) of
        #{Key := Name} -> unicode:characters_to_list(Name);
        _ -> undefined
    end.

%% The flexible day period of the locale's language for the hour, with noon
%% when the time is exactly noon; am and pm fall back to the a field.
flexible(#{locale := Locale} = Ctx, Count, F) ->
    Rules = maps:get(buoy_ref_intl:language(Locale), buoy_intl_cldr:supplemental(day_periods), undefined),
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

%% DayPeriodRules::getDayPeriodForHour: the period whose span holds the hour.
for_hour(Rules, Hour) ->
    Minute = Hour * 60,
    case [Name || {Name, {from, From, Before}} <- Rules, in_span(Minute, From, Before)] of
        [Name | _] -> Name;
        [] -> undefined
    end.

in_span(M, From, Before) when From < Before -> M >= From andalso M < Before;
in_span(M, From, Before) -> M >= From orelse M < Before.
