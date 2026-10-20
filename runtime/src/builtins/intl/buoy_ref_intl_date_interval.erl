%% The ranges of Intl.DateTimeFormat, as V8 asks ICU's DateIntervalFormat for
%% them: the interval patterns of the skeleton of the format's pattern, found
%% in the intervalFormats of the locale with ICU's skeleton distance and field
%% width adjustment, the date and time combined as ICU combines them, and the
%% fallback pattern otherwise. The source of each part comes from the spans of
%% the fields that the two dates both write, as ICU's addOverlapSpans finds
%% them.
-module(buoy_ref_intl_date_interval).

-export([format/5]).

-define(FIELDS, [era, year, month, date, am_pm, hour, minute, second, millisecond]).

%% The parts of the range between the date records F1 and F2 for a format
%% with Pattern in the locale, calendar, numbering system, and hour character:
%% [{Type, Text, Source}], or single when ICU writes one date, which V8 then
%% formats alone. Format writes a pattern for a record.
-spec format({binary(), binary(), binary(), char()}, [char()], map(), map(), fun(([char()], map()) -> [{atom(), [char()]}])) ->
          single | [{atom(), [char()], startRange | endRange | shared}].
format(Generator, Pattern, F1, F2, Format) ->
    Info = info(Generator, Pattern),
    case largest_difference(F1, F2) of
        none -> single;
        Field ->
            SameDay = lists:member(Field, [am_pm, hour, minute, second, millisecond]),
            case maps:get(Field, maps:get(patterns, Info), none) of
                none ->
                    case is_field_unit_ignored(Pattern, Field) of
                        true -> single;
                        false -> spans(fallback(Info, Pattern, SameDay, F1, F2, Format))
                    end;
                {fallback, Full} -> spans(fallback(Info, Full, SameDay, F1, F2, Format));
                {First, Second, LaterFirst} ->
                    {A, B, FirstIndex} = case LaterFirst of
                        true -> {F2, F1, 1};
                        false -> {F1, F2, 0}
                    end,
                    spans({FirstIndex, [Format(First, A), Format(Second, B)]})
            end
    end.

%% DateIntervalFormat::formatImpl: the largest calendar field that differs.
largest_difference(F1, F2) ->
    Values = fun(F) ->
                     Hour = maps:get(hour, F),
                     [maps:get(era, F), maps:get(era_year, F), {maps:get(month_name, F), maps:get(leap, F)}, maps:get(day, F),
                      Hour div 12, Hour rem 12, maps:get(minute, F), maps:get(second, F), maps:get(millisecond, F)]
             end,
    case [Field || {Field, A, B} <- lists:zip3(?FIELDS, Values(F1), Values(F2)), A =/= B] of
        [Field | _] -> Field;
        [] -> none
    end.

%% fallbackFormat: the date with the range of the times when the two
%% instants share their day and the format has a date and a time, else the
%% two dates in the fallback pattern. {FirstIndex, [Parts]}.
fallback(#{date := Date, time := Time, glue := Glue} = Info, _Pattern, true, F1, F2, Format)
  when Date =/= undefined, Time =/= undefined, Glue =/= undefined ->
    {FirstIndex, Range} = fallback_range(Info, Time, F1, F2, Format),
    {FirstIndex, lists:append([case Piece of
                                   {arg, 0} -> Range;
                                   {arg, 1} -> [Format(Date, F1)];
                                   Text -> [[{literal, Text}]]
                               end || Piece <- placeholders(Glue)])};
fallback(Info, Pattern, _SameDay, F1, F2, Format) ->
    fallback_range(Info, Pattern, F1, F2, Format).

%% fallbackFormatRange: the two dates in the fallback pattern, {0} the
%% earlier.
fallback_range(#{fallback := Fallback}, Pattern, F1, F2, Format) ->
    Pieces = placeholders(Fallback),
    FirstIndex = case [N || {arg, N} <- Pieces] of
        [1 | _] -> 1;
        _ -> 0
    end,
    {FirstIndex, [case Piece of
                      {arg, 0} -> Format(Pattern, F1);
                      {arg, 1} -> Format(Pattern, F2);
                      Text -> [{literal, Text}]
                  end || Piece <- Pieces]}.

%% The parts with their sources: FormattedValue's addOverlapSpans takes the
%% fields that both dates write, the first of each pair in one span and the
%% second in the other, and V8 names the span of the earlier date startRange.
spans({FirstIndex, Chunks}) ->
    Parts = merge_literals(lists:append(Chunks)),
    {Positioned, _} = lists:mapfoldl(fun({Type, Text}, At) -> {{Type, Text, At, At + length(Text)}, At + length(Text)} end,
                                     0, Parts),
    Fields = [P || {Type, _, _, _} = P <- Positioned, Type =/= literal],
    case overlap(Fields, none, none) of
        {none, none} -> single;
        {Span1, Span2} ->
            Source = fun(0) -> startRange; (1) -> endRange end,
            [{Type, Text, case {within(Start, End, Span1), within(Start, End, Span2)} of
                              {true, _} -> Source(FirstIndex);
                              {_, true} -> Source(1 - FirstIndex);
                              _ -> shared
                          end} || {Type, Text, Start, End} <- Positioned]
    end.

overlap([], Span1, Span2) -> {Span1, Span2};
overlap([{Type, _, Start, End} | Rest], Span1, Span2) ->
    case [P || {T, _, _, _} = P <- Rest, T =:= Type] of
        [{_, _, Start2, End2} | _] -> overlap(Rest, widen(Span1, Start, End), widen(Span2, Start2, End2));
        [] -> overlap(Rest, Span1, Span2)
    end.

widen(none, Start, End) -> {Start, End};
widen({S, E}, Start, End) -> {min(S, Start), max(E, End)}.

within(_Start, _End, none) -> false;
within(Start, End, {S, E}) -> Start >= S andalso End =< E.

merge_literals([{literal, A}, {literal, B} | Rest]) -> merge_literals([{literal, A ++ B} | Rest]);
merge_literals([{_, []} | Rest]) -> merge_literals(Rest);
merge_literals([Part | Rest]) -> [Part | merge_literals(Rest)];
merge_literals([]) -> [].

%% SimpleFormatter with {0} and {1}: [Text | {arg, N}].
placeholders(Pattern) ->
    case string:split(Pattern, "{") of
        [Text] -> [Text || Text =/= ""];
        [Before, [D, $} | After]] when D =:= $0; D =:= $1 -> [Before || Before =/= ""] ++ [{arg, D - $0} | placeholders(After)];
        [Before, After] -> [Before ++ "{" | placeholders(After)]
    end.

%%% DateIntervalFormat::initializePattern

%% The interval patterns of a format, made once per VM:
%% #{patterns => #{Field => {First, Second, LaterFirst} | {fallback, Pattern}},
%% date, time, glue, fallback}.
info({Locale, Cal, Nu, Hour} = Generator, Pattern) ->
    Key = {?MODULE, Generator, Pattern},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Info = make_info(Locale, Cal, Nu, Hour, Pattern),
            persistent_term:put(Key, Info),
            Info;
        Info -> Info
    end.

make_info(Locale, Cal, Nu, Hour, Pattern) ->
    Best = fun(Skeleton) -> buoy_ref_intl_date_skeleton:best_pattern(Locale, Cal, Nu, Skeleton, Hour, #{match_hour => false}) end,
    Skeleton = buoy_ref_intl_date_skeleton:skeleton_of(Pattern),
    Data = data(Locale, Cal),
    {DateSkeleton, NormalDate, TimeSkeleton, NormalTime} = split(normalize_hours(Skeleton, Best)),
    Glue = case DateSkeleton =/= [] andalso TimeSkeleton =/= [] of
        true ->
            Patterns = buoy_intl_cldr:get(Locale, [<<"calendar">>, <<"gregorian">>, <<"DateTimePatterns">>], []),
            case length(Patterns) >= 9 of
                true -> text(lists:nth(9, Patterns));
                false -> undefined
            end;
        false -> undefined
    end,
    Fallback = case buoy_intl_cldr:get(Locale, [<<"calendar">>, icu_calendar(Cal), <<"intervalFormats">>, <<"fallback">>]) of
        F when is_binary(F) -> unicode:characters_to_list(F);
        _ -> "{0} – {1}"
    end,
    Info0 = #{patterns => #{}, date => undefined, time => undefined, glue => Glue, fallback => Fallback,
              data => Data, skeleton => Skeleton, best => Best},
    {Found, Info1} = separate(Info0, NormalDate, NormalTime),
    Info2 = case {Found, DateSkeleton, TimeSkeleton} of
        {_, [], [_ | _]} -> time_fallbacks(Info1, TimeSkeleton);
        {false, _, _} -> Info1;
        {true, _, []} -> Info1;
        {true, _, _} -> date_time(Info1, DateSkeleton)
    end,
    maps:without([data, skeleton, best], Info2).

%% A time without a date falls back to the short date with the time when a
%% date field differs.
time_fallbacks(#{best := Best} = Info, TimeSkeleton) ->
    Pattern = Best("yMd" ++ TimeSkeleton),
    Info1 = lists:foldl(fun(Field, I) -> set_fallback(I, Field, Pattern) end, Info, [date, month, year]),
    set_fallback(Info1, era, Best("GyMd" ++ TimeSkeleton)).

%% A date and a time: the fallback for each date field, and the date with the
%% interval of the time for a change of the period, hour, or minute.
date_time(#{best := Best, skeleton := Skeleton0, glue := Glue} = Info, DateSkeleton) ->
    {Info1, _} = lists:foldl(fun({Field, Letter}, {I, Skeleton}) ->
                                     case lists:member(Letter, DateSkeleton) of
                                         true -> {I, Skeleton};
                                         false -> {set_fallback(I, Field, Best([Letter | Skeleton])), [Letter | Skeleton]}
                                     end
                             end, {Info, Skeleton0}, [{date, $d}, {month, $M}, {year, $y}, {era, $G}]),
    case Glue of
        undefined -> Info1;
        _ ->
            DatePattern = Best(DateSkeleton),
            lists:foldl(fun(Field, #{patterns := Patterns} = I) ->
                                case maps:get(Field, Patterns, none) of
                                    {[_ | _] = First, Second, LaterFirst} ->
                                        Combined = lists:append([case Piece of
                                                                     {arg, 0} -> First ++ Second;
                                                                     {arg, 1} -> DatePattern;
                                                                     Text -> Text
                                                                 end || Piece <- placeholders(Glue)]),
                                        set_pattern(I, Field, Combined, LaterFirst);
                                    _ -> I
                                end
                        end, Info1, [am_pm, hour, minute])
    end.

set_fallback(#{patterns := Patterns} = Info, Field, Pattern) ->
    Info#{patterns := Patterns#{Field => {fallback, Pattern}}}.

%% setIntervalPattern: the pattern split at the first field that repeats,
%% with the order of a latestFirst: or earliestFirst: prefix.
set_pattern(#{patterns := Patterns} = Info, Field, Pattern0, LaterFirst0) ->
    {Pattern, LaterFirst} = case Pattern0 of
        "latestFirst:" ++ Rest -> {Rest, true};
        "earliestFirst:" ++ Rest -> {Rest, false};
        _ -> {Pattern0, LaterFirst0}
    end,
    {First, Second} = lists:split(split_point(Pattern), Pattern),
    Info#{patterns := Patterns#{Field => {First, Second, LaterFirst}}}.

%% splitPatternInto2Part: the index of the first field whose letter came
%% before.
split_point(Pattern) -> split_point(Pattern, 0, false, 0, 0, #{}).

split_point([], I, _Quoted, Prev, Count, Seen) ->
    case Count > 0 andalso not maps:is_key(Prev, Seen) of
        true -> I;
        false -> I - Count
    end;
split_point([C | Rest], I, Quoted, Prev, Count, Seen) when C =/= Prev, Count > 0 ->
    case maps:is_key(Prev, Seen) of
        true -> I - Count;
        false -> split_point([C | Rest], I, Quoted, Prev, 0, Seen#{Prev => true})
    end;
split_point([$', $' | Rest], I, Quoted, Prev, Count, Seen) -> split_point(Rest, I + 2, Quoted, Prev, Count, Seen);
split_point([$' | Rest], I, Quoted, Prev, Count, Seen) -> split_point(Rest, I + 1, not Quoted, Prev, Count, Seen);
split_point([C | Rest], I, false, _Prev, Count, Seen) when (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) ->
    split_point(Rest, I + 1, false, C, Count + 1, Seen);
split_point([_ | Rest], I, Quoted, Prev, Count, Seen) -> split_point(Rest, I + 1, Quoted, Prev, Count, Seen).

%% setSeparateDateTimePtn: the interval patterns of the time skeleton, else
%% of the date skeleton, from the best skeleton of the data.
separate(#{data := Data, best := Best} = Info, Date, Time) ->
    Skeleton = case Time of
        [] -> Date;
        _ -> Time
    end,
    case best_skeleton(Data, Skeleton) of
        none -> {false, Info};
        {BestSkeleton, Difference} ->
            Info1 = Info#{date := case Date of [] -> undefined; _ -> Best(Date) end,
                          time := case Time of [] -> undefined; _ -> Best(Time) end},
            case {Difference, Time} of
                {-1, _} -> {false, Info1};
                {_, []} ->
                    {Info2, Ext2, _} = interval(Info1, date, Skeleton, BestSkeleton, Difference, none),
                    {Info3, Ext3, Extended} = interval(Info2, month, Skeleton, BestSkeleton, Difference, Ext2),
                    {Skeleton4, Best4} = case {Extended, Ext3} of
                        {true, {ExtSkeleton, ExtBest}} -> {ExtSkeleton, ExtBest};
                        _ -> {Skeleton, BestSkeleton}
                    end,
                    {Info4, Ext4, _} = interval(Info3, year, Skeleton4, Best4, Difference, Ext3),
                    {Info5, _, _} = interval(Info4, era, Skeleton4, Best4, Difference, Ext4),
                    {true, Info5};
                _ ->
                    Info2 = lists:foldl(fun(Field, I) -> element(1, interval(I, Field, Skeleton, BestSkeleton, Difference, off)) end,
                                        Info1, [minute, hour, am_pm]),
                    {true, Info2}
            end
    end.

%% setIntervalPattern for one field: {Info, Ext, Extended}. Ext is off for a
%% time skeleton, else none or the last extended skeleton and best skeleton,
%% which ICU keeps across the fields of a date; Extended is whether a pattern
%% was set while an extension stood.
interval(#{data := Data} = Info, Field, Skeleton, Best, Difference, Ext) ->
    case lookup(Data, Best, Field) of
        none ->
            case is_field_unit_ignored(Best, Field) of
                true -> {Info, Ext, false};
                false when Field =:= am_pm ->
                    case lookup(Data, Best, hour) of
                        none -> {Info, Ext, false};
                        Hour -> {set_pattern(Info, am_pm, adjust_width(Info, Skeleton, Best, Hour, Difference), false), Ext, false}
                    end;
                false when Ext =:= off -> {Info, Ext, false};
                false ->
                    Letter = letter(Field),
                    ExtBest = [Letter | Best],
                    Ext1 = {[Letter | Skeleton], ExtBest},
                    {Pattern, Best1, Difference1} =
                        case lookup(Data, ExtBest, Field) of
                            none when Difference =:= 0 ->
                                case best_skeleton(Data, ExtBest) of
                                    {Tmp, D2} when D2 =/= -1 -> {lookup(Data, Tmp, Field), Tmp, D2};
                                    _ -> {none, Best, Difference}
                                end;
                            P -> {P, Best, Difference}
                        end,
                    case Pattern of
                        none -> {Info, Ext1, false};
                        _ -> {set_found(Info, Field, Skeleton, Best1, Pattern, Difference1), Ext1, true}
                    end
            end;
        Pattern -> {set_found(Info, Field, Skeleton, Best, Pattern, Difference), Ext, is_tuple(Ext)}
    end.

set_found(#{skeleton := Original} = Info, Field, Skeleton, Best, Pattern, Difference) ->
    case Difference =/= 0 orelse lists:member($J, Original) of
        true -> set_pattern(Info, Field, adjust_width(Info, Skeleton, Best, Pattern, Difference), false);
        false -> set_pattern(Info, Field, Pattern, false)
    end.

letter(era) -> $G;
letter(year) -> $y;
letter(month) -> $M;
letter(date) -> $d;
letter(am_pm) -> $a;
letter(hour) -> $h;
letter(minute) -> $m.

%% The pattern of a skeleton of the data for the largest field that differs.
lookup(Data, Skeleton, Field) ->
    case maps:get(Skeleton, Data, #{}) of
        #{Field := Pattern} -> Pattern;
        _ -> none
    end.

%% The interval skeletons of the calendar: #{Skeleton => #{Field => Pattern}},
%% the more specific locale first, as DateIntervalSink keeps the first
%% pattern of each field.
data(Locale, Cal) ->
    Table = buoy_intl_cldr:table(Locale, [<<"calendar">>, icu_calendar(Cal), <<"intervalFormats">>]),
    maps:from_list([{binary_to_list(Skeleton), fields(Patterns)} || {Skeleton, Patterns} <- maps:to_list(Table), is_map(Patterns)]).

fields(Patterns) ->
    lists:foldl(fun({Key, Pattern}, Acc) when is_binary(Pattern) ->
                        case field_of(Key) of
                            none -> Acc;
                            Field -> maps:merge(#{Field => unicode:characters_to_list(Pattern)}, Acc)
                        end;
                   (_, Acc) -> Acc
                end, #{}, lists:sort(maps:to_list(Patterns))).

field_of(<<"G">>) -> era;
field_of(<<"y">>) -> year;
field_of(<<"M">>) -> month;
field_of(<<"d">>) -> date;
field_of(<<"a">>) -> am_pm;
field_of(<<"B">>) -> am_pm;
field_of(<<"h">>) -> hour;
field_of(<<"H">>) -> hour;
field_of(<<"m">>) -> minute;
field_of(_) -> none.

icu_calendar(<<"gregory">>) -> <<"gregorian">>;
icu_calendar(<<"ethioaa">>) -> <<"ethiopic-amete-alem">>;
icu_calendar(Cal) -> Cal.

text([P | _]) when is_binary(P) -> unicode:characters_to_list(P);
text(P) -> unicode:characters_to_list(P).

%% DateIntervalInfo::getBestSkeleton: {Skeleton, Difference}, where
%% Difference is 0 for the same fields and widths, 1 for other widths, 2 when
%% only z, k, K, a, or b differ, and -1 for other fields; or none.
best_skeleton(Data, Skeleton) ->
    Replaced = lists:any(fun(C) -> lists:member(C, "zkKab") end, Skeleton),
    Input = widths([case C of $z -> $v; $k -> $H; $K -> $h; _ -> C end || C <- Skeleton, C =/= $a, C =/= $b]),
    Best = lists:foldl(fun(_, {_, 0, _} = Done) -> Done;
                          (Candidate, {_, BestDistance, _} = Acc) ->
                               {Distance, Difference} = skeleton_distance(Input, widths(Candidate)),
                               case Distance < BestDistance of
                                   true -> {Candidate, Distance, Difference};
                                   false -> Acc
                               end
                       end, {none, infinity, 0}, lists:sort(maps:keys(Data))),
    case Best of
        {none, _, _} -> none;
        {Candidate, 0, _} -> {Candidate, case Replaced of true -> 2; false -> 0 end};
        {Candidate, _, -1} -> {Candidate, -1};
        {Candidate, _, _} when Replaced -> {Candidate, 2};
        {Candidate, _, Difference} -> {Candidate, Difference}
    end.

widths(Skeleton) ->
    lists:foldl(fun(C, Acc) -> maps:update_with(C, fun(N) -> N + 1 end, 1, Acc) end, #{}, Skeleton).

skeleton_distance(Input, Candidate) ->
    lists:foldl(fun(C, {Distance, Difference}) ->
                        case {maps:get(C, Input, 0), maps:get(C, Candidate, 0)} of
                            {Same, Same} -> {Distance, Difference};
                            {0, _} -> {Distance + 16#1000, -1};
                            {_, 0} -> {Distance + 16#1000, -1};
                            {A, B} when C =:= $M, (A =< 2 andalso B > 2) orelse (A > 2 andalso B =< 2) -> {Distance + 16#100, Difference};
                            {A, B} -> {Distance + abs(A - B), Difference}
                        end
                end, {0, 1}, lists:usort(maps:keys(Input) ++ maps:keys(Candidate))).

%% DateIntervalFormat::adjustFieldWidth: the widths of the input skeleton in
%% the pattern of the best skeleton, with the time letters of the input.
adjust_width(#{skeleton := Original}, Input, Best, Pattern0, Difference) ->
    Pattern1 = case lists:member($J, Original) of
        true ->
            P = lists:foldl(fun({From, To}, Acc) -> replace(Acc, From, To) end, Pattern0,
                            [{[16#A0, $a], ""}, {[16#202F, $a], ""}, {[$a, 16#A0], ""}, {[$a, 16#202F], ""}, {"a", ""}, {"  ", " "}]),
            string:trim(P);
        false -> Pattern0
    end,
    Pattern = case Difference of
        2 ->
            lists:foldl(fun({Letter, From, To}, Acc) ->
                                case lists:member(Letter, Input) of
                                    true -> replace(Acc, [From], [To]);
                                    false -> Acc
                                end
                        end, Pattern1, [{$z, $v, $z}, {$K, $h, $K}, {$k, $H, $k}, {$b, $a, $b}]);
        _ -> Pattern1
    end,
    InputWidths = widths(Input),
    BestWidths0 = widths(Best),
    BestWidths = lists:foldl(fun(C, Acc) ->
                                     case lists:member(C, Pattern) andalso maps:get(C, Acc, 0) =:= 0 of
                                         true -> Acc#{C => 1};
                                         false -> Acc
                                     end
                             end, BestWidths0, "ab"),
    lists:append([widen_item(Item, InputWidths, BestWidths) || Item <- pattern_items(Pattern)]).

widen_item({field, C, Count}, InputWidths, BestWidths) ->
    Key = case C of $L -> $M; _ -> C end,
    Have = maps:get(Key, BestWidths, 0),
    Want = maps:get(Key, InputWidths, 0),
    case Have =:= Count andalso Want > Have of
        true -> lists:duplicate(Want, C);
        false -> lists:duplicate(Count, C)
    end;
widen_item({text, Text}, _, _) -> Text.

%% A pattern as runs of letters outside quotes and the text between them.
pattern_items([]) -> [];
pattern_items([$' | _] = Pattern) ->
    {Quoted, Rest} = quoted(tl(Pattern), "'"),
    [{text, Quoted} | pattern_items(Rest)];
pattern_items([C | _] = Pattern) when (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) ->
    {Run, Rest} = lists:splitwith(fun(X) -> X =:= C end, Pattern),
    [{field, C, length(Run)} | pattern_items(Rest)];
pattern_items([C | Rest]) -> [{text, [C]} | pattern_items(Rest)].

quoted([$', $' | Rest], Acc) -> quoted(Rest, "''" ++ Acc);
quoted([$' | Rest], Acc) -> {lists:reverse([$' | Acc]), Rest};
quoted([C | Rest], Acc) -> quoted(Rest, [C | Acc]);
quoted([], Acc) -> {lists:reverse(Acc), []}.

%% findReplaceInPattern: a replacement outside the quoted text.
replace(Pattern, From, To) ->
    lists:append([case Item of
                      {text, [$' | _] = Quoted} -> Quoted;
                      _ -> lists:flatten(string:replace(item_text(Item), From, To, all))
                  end || Item <- quote_items(Pattern)]).

quote_items([]) -> [];
quote_items([$' | Rest]) ->
    {Quoted, After} = quoted(Rest, "'"),
    [{text, Quoted} | quote_items(After)];
quote_items(Pattern) ->
    {Plain, Rest} = lists:splitwith(fun(C) -> C =/= $' end, Pattern),
    [{plain, Plain} | quote_items(Rest)].

item_text({_, Text}) -> Text.

%% DateIntervalFormat::normalizeHourMetacharacters: the hour and day period
%% of the skeleton as the locale's pattern for the hour letter writes them.
normalize_hours(Skeleton, Best) ->
    IsHour = fun(C) -> lists:member(C, "jJChHkK") end,
    IsPeriod = fun(C) -> lists:member(C, "abB") end,
    case [C || C <- Skeleton, IsHour(C)] of
        [] -> Skeleton;
        [HourMeta | _] = Hours ->
            Periods = [C || C <- Skeleton, IsPeriod(C)],
            Converted = strip_quoted(Best([HourMeta])),
            HourChar = first_member(Converted, "hKk", $H),
            PeriodChar = case {lists:member($b, Converted), lists:member($B, Converted), Periods} of
                {true, _, _} -> $b;
                {_, true, _} -> $B;
                {_, _, [P | _]} -> P;
                _ -> $a
            end,
            PeriodLength = case HourChar =:= $H orelse HourChar =:= $k of
                true -> 0;
                false when length(Periods) >= 5; length(Hours) >= 5 -> 5;
                false when length(Periods) >= 3; length(Hours) >= 3 -> 3;
                false -> 1
            end,
            Replacement = [HourChar | lists:duplicate(PeriodLength, PeriodChar)],
            {Before, _} = lists:splitwith(fun(C) -> not IsHour(C) end, Skeleton),
            Rest = [C || C <- lists:nthtail(length(Before), Skeleton), not IsHour(C)],
            [C || C <- Before, not IsPeriod(C)] ++ Replacement ++ [C || C <- Rest, not IsPeriod(C)]
    end.

%% The first letter of Letters in the pattern, else Default (the order of the
%% checks of ICU: h, then K, then k).
first_member(Pattern, Letters, Default) ->
    case [L || L <- Letters, lists:member(L, Pattern)] of
        [L | _] -> L;
        [] -> Default
    end.

strip_quoted(Pattern) -> lists:append([Text || {plain, Text} <- quote_items(Pattern)]).

%% getDateTimeSkeleton: {Date, NormalizedDate, Time, NormalizedTime}.
split(Skeleton) ->
    Count = fun(C) -> length([X || X <- Skeleton, X =:= C]) end,
    Date = [C || C <- Skeleton, lists:member(C, "EdMyGYuQqLlWwDFgecUr")],
    Time = [C || C <- Skeleton, lists:member(C, "hHkKmzvaVZjsSAbB")],
    Other = [C || C <- Skeleton, lists:member(C, "GYuQqLlWwDFgecUr")],
    NormalDate = Other ++ lists:duplicate(Count($y), $y)
        ++ case Count($M) of 0 -> ""; N when N < 3 -> "M"; N -> lists:duplicate(min(N, 5), $M) end
        ++ case Count($E) of 0 -> ""; N when N =< 3 -> "E"; N -> lists:duplicate(min(N, 5), $E) end
        ++ case Count($d) of 0 -> ""; _ -> "d" end,
    HourChar = [C || C <- Skeleton, lists:member(C, "hHkK")],
    NormalTime = [C || C <- Skeleton, lists:member(C, "aVZjsSAbB")]
        ++ case HourChar of [] -> ""; [H | _] -> [H] end
        ++ case Count($m) of 0 -> ""; _ -> "m" end
        ++ case Count($z) of 0 -> ""; _ -> "z" end
        ++ case Count($v) of 0 -> ""; _ -> "v" end,
    {Date, NormalDate, Time, NormalTime}.

%% SimpleDateFormat::isFieldUnitIgnored: whether no field of the pattern is
%% as small as Field.
is_field_unit_ignored(Pattern, Field) ->
    Level = field_level(Field),
    not lists:any(fun({field, C, _}) -> Level =< char_level(C); (_) -> false end, pattern_items(Pattern)).

field_level(era) -> 0;
field_level(year) -> 10;
field_level(month) -> 20;
field_level(date) -> 30;
field_level(am_pm) -> 40;
field_level(hour) -> 50;
field_level(minute) -> 60;
field_level(second) -> 70;
field_level(millisecond) -> 80.

char_level(C) ->
    Levels = #{$A => 40, $D => 20, $E => 30, $F => 30, $G => 0, $H => 50, $K => 50, $L => 20, $M => 20, $O => 0, $Q => 20,
               $S => 80, $U => 10, $V => 0, $W => 30, $X => 0, $Y => 10, $Z => 0, $a => 40, $c => 30, $d => 30, $e => 30,
               $g => 0, $h => 50, $k => 50, $l => 0, $m => 60, $q => 20, $r => 10, $s => 70, $u => 10, $v => 0, $w => 20,
               $x => 0, $y => 10, $z => 0},
    maps:get(C, Levels, -1).
