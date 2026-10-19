%% The date pattern generator of Intl.DateTimeFormat: the best CLDR pattern
%% for a skeleton, a port of ICU's DateTimePatternGenerator::getBestPattern,
%% which V8 calls, so that the patterns match Node's. The patterns of a
%% locale and calendar are the canonical items, the date and time styles,
%% and the availableFormats, kept in ICU's order, since the order breaks the
%% ties of the distance. Patterns and skeletons are lists of code points.
-module(buoy_ref_intl_date_skeleton).

-export([best_pattern/4, skeleton_of/1, items/1, date_time_glue/3]).

-define(FIELDS, 16).
-define(ERA, 0).
-define(YEAR, 1).
-define(MONTH, 3).
-define(WEEKDAY, 6).
-define(DAY, 9).
-define(DAYPERIOD, 10).
-define(HOUR, 11).
-define(MINUTE, 12).
-define(SECOND, 13).
-define(FRACTION, 14).
-define(ZONE, 15).
-define(NUMERIC, 16#100).
-define(D, 16#10).
-define(NARROW, -16#101).
-define(SHORTER, -16#102).
-define(SHORT, -16#103).
-define(LONG, -16#104).
-define(EXTRA, 16#10000).
-define(MISSING, 16#1000).

%% ICU's dtTypes: {Char, Field, Type, MinLength}.
types() ->
    [{$G, ?ERA, ?SHORT, 1}, {$G, ?ERA, ?LONG, 4}, {$G, ?ERA, ?NARROW, 5},
     {$y, ?YEAR, ?NUMERIC, 1}, {$Y, ?YEAR, ?NUMERIC + ?D, 1}, {$u, ?YEAR, ?NUMERIC + 2 * ?D, 1},
     {$r, ?YEAR, ?NUMERIC + 3 * ?D, 1}, {$U, ?YEAR, ?SHORT, 1}, {$U, ?YEAR, ?LONG, 4}, {$U, ?YEAR, ?NARROW, 5},
     {$Q, 2, ?NUMERIC, 1}, {$Q, 2, ?SHORT, 3}, {$Q, 2, ?LONG, 4}, {$Q, 2, ?NARROW, 5},
     {$q, 2, ?NUMERIC + ?D, 1}, {$q, 2, ?SHORT - ?D, 3}, {$q, 2, ?LONG - ?D, 4}, {$q, 2, ?NARROW - ?D, 5},
     {$M, ?MONTH, ?NUMERIC, 1}, {$M, ?MONTH, ?SHORT, 3}, {$M, ?MONTH, ?LONG, 4}, {$M, ?MONTH, ?NARROW, 5},
     {$L, ?MONTH, ?NUMERIC + ?D, 1}, {$L, ?MONTH, ?SHORT - ?D, 3}, {$L, ?MONTH, ?LONG - ?D, 4}, {$L, ?MONTH, ?NARROW - ?D, 5},
     {$l, ?MONTH, ?NUMERIC + ?D, 1},
     {$w, 4, ?NUMERIC, 1},
     {$W, 5, ?NUMERIC, 1},
     {$E, ?WEEKDAY, ?SHORT, 1}, {$E, ?WEEKDAY, ?LONG, 4}, {$E, ?WEEKDAY, ?NARROW, 5}, {$E, ?WEEKDAY, ?SHORTER, 6},
     {$c, ?WEEKDAY, ?NUMERIC + 2 * ?D, 1}, {$c, ?WEEKDAY, ?SHORT - 2 * ?D, 3}, {$c, ?WEEKDAY, ?LONG - 2 * ?D, 4},
     {$c, ?WEEKDAY, ?NARROW - 2 * ?D, 5}, {$c, ?WEEKDAY, ?SHORTER - 2 * ?D, 6},
     {$e, ?WEEKDAY, ?NUMERIC + ?D, 1}, {$e, ?WEEKDAY, ?SHORT - ?D, 3}, {$e, ?WEEKDAY, ?LONG - ?D, 4},
     {$e, ?WEEKDAY, ?NARROW - ?D, 5}, {$e, ?WEEKDAY, ?SHORTER - ?D, 6},
     {$d, ?DAY, ?NUMERIC, 1}, {$g, ?DAY, ?NUMERIC + ?D, 1},
     {$D, 7, ?NUMERIC, 1},
     {$F, 8, ?NUMERIC, 1},
     {$a, ?DAYPERIOD, ?SHORT, 1}, {$a, ?DAYPERIOD, ?LONG, 4}, {$a, ?DAYPERIOD, ?NARROW, 5},
     {$b, ?DAYPERIOD, ?SHORT - ?D, 1}, {$b, ?DAYPERIOD, ?LONG - ?D, 4}, {$b, ?DAYPERIOD, ?NARROW - ?D, 5},
     {$B, ?DAYPERIOD, ?SHORT - 3 * ?D, 1}, {$B, ?DAYPERIOD, ?LONG - 3 * ?D, 4}, {$B, ?DAYPERIOD, ?NARROW - 3 * ?D, 5},
     {$H, ?HOUR, ?NUMERIC + 10 * ?D, 1}, {$k, ?HOUR, ?NUMERIC + 11 * ?D, 1}, {$h, ?HOUR, ?NUMERIC, 1},
     {$K, ?HOUR, ?NUMERIC + ?D, 1}, {$J, ?HOUR, ?NUMERIC + 5 * ?D, 1}, {$j, ?HOUR, ?NUMERIC + 6 * ?D, 1},
     {$C, ?HOUR, ?NUMERIC + 7 * ?D, 1},
     {$m, ?MINUTE, ?NUMERIC, 1},
     {$s, ?SECOND, ?NUMERIC, 1}, {$A, ?SECOND, ?NUMERIC + ?D, 1},
     {$S, ?FRACTION, ?NUMERIC, 1},
     {$v, ?ZONE, ?SHORT - 2 * ?D, 1}, {$v, ?ZONE, ?LONG - 2 * ?D, 4},
     {$z, ?ZONE, ?SHORT, 1}, {$z, ?ZONE, ?LONG, 4},
     {$Z, ?ZONE, ?NARROW - ?D, 1}, {$Z, ?ZONE, ?LONG - ?D, 4}, {$Z, ?ZONE, ?SHORT - ?D, 5},
     {$O, ?ZONE, ?SHORT - ?D, 1}, {$O, ?ZONE, ?LONG - ?D, 4},
     {$V, ?ZONE, ?SHORT - ?D, 1}, {$V, ?ZONE, ?LONG - ?D, 2}, {$V, ?ZONE, ?LONG - 1 - ?D, 3}, {$V, ?ZONE, ?LONG - 2 - ?D, 4},
     {$X, ?ZONE, ?NARROW - ?D, 1}, {$X, ?ZONE, ?SHORT - ?D, 2}, {$X, ?ZONE, ?LONG - ?D, 4},
     {$x, ?ZONE, ?NARROW - ?D, 1}, {$x, ?ZONE, ?SHORT - ?D, 2}, {$x, ?ZONE, ?LONG - ?D, 4}].

%% FormatParser::getCanonicalIndex with strict matching: the row of a run
%% of one letter, or none.
row([C | _] = Item) ->
    case lists:all(fun(X) -> X =:= C end, Item) of
        false -> none;
        true -> row(C, length(Item), [R || {Char, _, _, _} = R <- types(), Char =:= C])
    end.

row(_C, _Len, []) -> none;
row(_C, _Len, [R]) -> R;
row(C, Len, [R, {_, _, _, Min} = Next | Rest]) ->
    case Min =< Len of
        true -> row(C, Len, [Next | Rest]);
        false -> R
    end.

%% FormatParser::set: the runs of one letter and the single other characters.
-spec items([char()]) -> [[char()]].
items([]) -> [];
items([C | _] = Text) when (C >= $A andalso C =< $Z) orelse (C >= $a andalso C =< $z) ->
    {Run, Rest} = lists:splitwith(fun(X) -> X =:= C end, Text),
    [Run | items(Rest)];
items([C | Rest]) -> [[C] | items(Rest)].

%%% Skeletons: DateTimeMatcher::set

%% A skeleton: {Types, Original, Base, AddedDayPeriod}, where Types holds the
%% type of each field, 0 for none, and Original and Base hold {Char, Length}.
skeleton(Pattern) ->
    Empty = erlang:make_tuple(?FIELDS, {0, 0}),
    {Types, Original, Base} = fields(items(Pattern), erlang:make_tuple(?FIELDS, 0), Empty, Empty),
    {Types1, Original1, Base1} =
        case length_of(Original, ?MINUTE) > 0 andalso length_of(Original, ?FRACTION) > 0 andalso length_of(Original, ?SECOND) =:= 0 of
            true -> {set(Types, ?SECOND, ?NUMERIC + 1), set(Original, ?SECOND, {$s, 1}), set(Base, ?SECOND, {$s, 1})};
            false -> {Types, Original, Base}
        end,
    case length_of(Original1, ?HOUR) > 0 of
        false -> {Types1, Original1, Base1, false};
        true ->
            case char_of(Original1, ?HOUR) of
                H when H =:= $h; H =:= $K ->
                    case length_of(Original1, ?DAYPERIOD) of
                        0 -> {set(Types1, ?DAYPERIOD, ?SHORT), set(Original1, ?DAYPERIOD, {$a, 1}), set(Base1, ?DAYPERIOD, {$a, 1}), true};
                        _ -> {Types1, Original1, Base1, false}
                    end;
                _ -> {set(Types1, ?DAYPERIOD, 0), set(Original1, ?DAYPERIOD, {0, 0}), set(Base1, ?DAYPERIOD, {0, 0}), false}
            end
    end.

fields([], Types, Original, Base) -> {Types, Original, Base};
fields([[$' | _] | _] = Items, Types, Original, Base) ->
    {_, Rest} = quote_literal(Items),
    fields(Rest, Types, Original, Base);
fields([Item | Rest], Types, Original, Base) ->
    case row(Item) of
        none -> fields(Rest, Types, Original, Base);
        {Char, Field, Type, Min} ->
            SubField = case Type > 0 of
                true -> Type + length(Item);
                false -> Type
            end,
            fields(Rest, set(Types, Field, SubField), set(Original, Field, {hd(Item), length(Item)}), set(Base, Field, {Char, Min}))
    end.

set(Tuple, Field, Value) -> setelement(Field + 1, Tuple, Value).
length_of(Fields, Field) -> element(2, element(Field + 1, Fields)).
char_of(Fields, Field) -> element(1, element(Field + 1, Fields)).
type_of({Types, _, _, _}, Field) -> element(Field + 1, Types).

%% The text of the fields, in field order.
fields_text(Fields) ->
    lists:append([lists:duplicate(L, C) || {C, L} <- tuple_to_list(Fields), L > 0]).

%% FormatParser::getQuoteLiteral: {Literal, Rest} from a quote item.
quote_literal([Quote | Rest]) -> quote_literal(Rest, Quote).

quote_literal([], Acc) -> {Acc, []};
quote_literal([[$'], [$'] | Rest], Acc) -> quote_literal(Rest, Acc ++ "''");
quote_literal([[$'] | Rest], Acc) -> {Acc ++ "'", Rest};
quote_literal([Item | Rest], Acc) -> quote_literal(Rest, Acc ++ Item).

%% DateTimePatternGenerator::staticGetSkeleton: the skeleton of a pattern.
-spec skeleton_of([char()]) -> [char()].
skeleton_of(Pattern) ->
    {_, Original, _, _} = skeleton(Pattern),
    fields_text(Original).

field_mask({Types, _, _, _}) ->
    lists:foldl(fun(I, Mask) -> case element(I + 1, Types) of 0 -> Mask; _ -> Mask bor (1 bsl I) end end, 0, lists:seq(0, ?FIELDS - 1)).

%% DateTimeMatcher::getDistance: {Distance, MissingMask, ExtraMask}.
distance({Mine, _, _, _}, {Theirs, _, _, _}, Include) ->
    lists:foldl(fun(I, {D, Missing, Extra} = Acc) ->
                        My = case Include band (1 bsl I) of 0 -> 0; _ -> element(I + 1, Mine) end,
                        Other = element(I + 1, Theirs),
                        if
                            My =:= Other -> Acc;
                            My =:= 0 -> {D + ?EXTRA, Missing, Extra bor (1 bsl I)};
                            Other =:= 0 -> {D + ?MISSING, Missing bor (1 bsl I), Extra};
                            true -> {D + abs(My - Other), Missing, Extra}
                        end
                end, {0, 0, 0}, lists:seq(0, ?FIELDS - 1)).

%%% The pattern map of a locale and calendar

%% The generator of a locale and calendar, made once per VM: {Entries,
%% Glue, AppendFormats, AppendNames, Decimal}, where Entries is the pattern
%% map in ICU's iteration order, [{Base, Skeleton, Pattern, Specified}].
generator(Locale, Cal) ->
    Key = {?MODULE, Locale, Cal},
    case persistent_term:get(Key, undefined) of
        undefined ->
            G = make_generator(Locale, Cal),
            persistent_term:put(Key, G),
            G;
        G -> G
    end.

make_generator(Locale, Cal) ->
    Get = fun(K, Default) -> calendar_get(Locale, Cal, K, Default) end,
    Canonical = lists:foldl(fun(C, Map) -> add(Map, [C], none, false) end, boot(), "GyQMwWEDFdaHmsSv"),
    Styles = [unicode:characters_to_list(P) || Kind <- [time_format, date_format], Style <- [full, long, medium, short],
                                               P <- [Get({Kind, Style}, undefined)], P =/= undefined],
    WithStyles = lists:foldl(fun(P, Map) -> add(Map, P, none, false) end, Canonical, Styles),
    Available = available(Locale, Cal),
    Map = lists:foldl(fun({Skel, P}, M) -> add(M, unicode:characters_to_list(P), unicode:characters_to_list(Skel), true) end,
                      WithStyles, Available),
    Glue = [{Style, unicode:characters_to_list(case Get({date_time_at, Style}, undefined) of
                                                    undefined -> Get({date_time, Style}, <<"{1} {0}">>);
                                                    P -> P
                                                end)} || Style <- [full, long, medium, short]],
    Names = [{"Era", ?ERA}, {"Year", ?YEAR}, {"Quarter", 2}, {"Month", ?MONTH}, {"Week", 4}, {"Day-Of-Week", ?WEEKDAY},
             {"Day", ?DAY}, {"Hour", ?HOUR}, {"Minute", ?MINUTE}, {"Second", ?SECOND}, {"Timezone", ?ZONE}],
    AppendFormats = maps:from_list([{F, case Get({append, list_to_binary(N)}, undefined) of
                                            undefined -> [${, $0, $}, $\s, 16#251C, ${, $2, $}, $:, $\s, ${, $1, $}, 16#2524];
                                            P -> unicode:characters_to_list(P)
                                        end} || {N, F} <- Names]),
    FieldNames = [{?ERA, <<"era">>}, {?YEAR, <<"year">>}, {2, <<"quarter">>}, {?MONTH, <<"month">>}, {4, <<"week">>},
                  {5, <<"weekOfMonth">>}, {?WEEKDAY, <<"weekday">>}, {7, <<"dayOfYear">>}, {8, <<"weekdayOfMonth">>},
                  {?DAY, <<"day">>}, {?DAYPERIOD, <<"dayperiod">>}, {?HOUR, <<"hour">>}, {?MINUTE, <<"minute">>},
                  {?SECOND, <<"second">>}, {?ZONE, <<"zone">>}],
    AppendNames = maps:from_list([{F, case maps:get(name, buoy_intl_cldr:get(Locale, {field, N, long}, #{}), undefined) of
                                          undefined -> "F" ++ integer_to_list(F);
                                          Name -> unicode:characters_to_list(Name)
                                      end} || {F, N} <- FieldNames]),
    Symbols = buoy_intl_cldr:get(Locale, {symbols, buoy_intl_cldr:get(Locale, nu_default, <<"latn">>)},
                                 buoy_intl_cldr:get(Locale, {symbols, <<"latn">>}, #{})),
    Decimal = unicode:characters_to_list(maps:get(<<"decimal">>, Symbols, <<".">>)),
    {lists:append([lists:reverse(Bucket) || Bucket <- tuple_to_list(Map)]), Glue, AppendFormats, AppendNames, Decimal}.

calendar_get(Locale, Cal, Key, Default) ->
    case buoy_intl_cldr:get(Locale, list_to_tuple([cal, Cal | tuple_to_list(Key)])) of
        undefined when Cal =/= <<"gregory">> -> buoy_intl_cldr:get(Locale, list_to_tuple([cal, <<"gregory">> | tuple_to_list(Key)]), Default);
        undefined -> Default;
        V -> V
    end.

%% The availableFormats in ICU's order: the locale's own entries sorted by
%% skeleton, then those of each parent that are not set yet.
available(Locale, Cal) ->
    {_, Ordered} = lists:foldl(
                     fun(L, {Seen, Acc}) ->
                             Own = lists:sort([{S, P} || {{cal, C, available, S}, P} <- maps:to_list(buoy_intl_cldr:own(L)),
                                                         C =:= Cal, not maps:is_key(S, Seen)]),
                             {maps:merge(Seen, maps:from_list([{S, true} || {S, _} <- Own])), Acc ++ Own}
                     end, {#{}, []}, buoy_intl_cldr:locales(Locale)),
    case Ordered of
        [] when Cal =/= <<"gregory">> -> available(Locale, <<"gregory">>);
        _ -> Ordered
    end.

%% The 52 buckets of the pattern map, by the first letter of the base, each
%% newest first.
boot() -> erlang:make_tuple(52, []).

bucket(C) when C >= $A, C =< $Z -> C - $A + 1;
bucket(C) when C >= $a, C =< $z -> 26 + C - $a + 1.

%% DateTimePatternGenerator::addPatternWithOptionalSkeleton.
add(Map, Pattern, SkeletonText, Override) ->
    Specified = SkeletonText =/= none,
    Skeleton = skeleton(case SkeletonText of none -> Pattern; _ -> SkeletonText end),
    Base = fields_text(element(3, Skeleton)),
    case Base of
        [] -> Map;
        [First | _] ->
            I = bucket(First),
            Entries = lists:reverse(element(I, Map)),
            BaseHit = [S || {B, _, _, S} <- Entries, B =:= Base],
            BaseConflict = case BaseHit of
                [DupSpecified | _] -> not DupSpecified orelse (Specified andalso not Override);
                [] -> false
            end,
            SkeletonHit = [S || {_, Sk, _, S} <- Entries, element(2, Sk) =:= element(2, Skeleton)],
            if
                BaseConflict andalso not Override -> Map;
                SkeletonHit =/= [] andalso (not Override orelse (Specified andalso hd(SkeletonHit))) -> Map;
                true -> setelement(I, Map, insert(element(I, Map), Base, Skeleton, Pattern, Specified))
            end
    end.

%% PatternMap::add: overwrite the entry of the same base and types, else
%% append one (the bucket is newest first).
insert(Bucket, Base, Skeleton, Pattern, Specified) ->
    Types = element(1, Skeleton),
    case lists:splitwith(fun({B, Sk, _, _}) -> not (B =:= Base andalso element(1, Sk) =:= Types) end, lists:reverse(Bucket)) of
        {Before, [{B, Sk, _, _} | After]} -> lists:reverse(Before ++ [{B, Sk, Pattern, Specified} | After]);
        {_, []} -> [{Base, Skeleton, Pattern, Specified} | Bucket]
    end.

%%% getBestPattern

%% The best pattern for a skeleton in a locale and calendar, with the hour
%% character DefaultHour, as V8 asks for it (UDATPG_MATCH_HOUR_FIELD_LENGTH).
-spec best_pattern(binary(), binary(), [char()], char()) -> [char()].
best_pattern(Locale, Cal, Requested, DefaultHour) ->
    {Entries, Glue, _, _, _} = G = generator(Locale, Cal),
    {Mapped, UsesCapJ} = map_metacharacters(Requested, DefaultHour),
    Skeleton = skeleton(Mapped),
    Ctx = #{generator => G, request => Skeleton, hour => DefaultHour, cap_j => UsesCapJ},
    {Best, BestSpecified, {_, Missing, Extra}} = best_raw(Entries, Skeleton, -1),
    case Missing =:= 0 andalso Extra =:= 0 of
        true -> adjust(Ctx, Best, BestSpecified, false);
        false ->
            Needed = field_mask(Skeleton),
            DateMask = (1 bsl ?DAYPERIOD) - 1,
            TimeMask = (1 bsl ?FIELDS) - 1 - DateMask,
            DatePattern = best_appending(Ctx, Needed band DateMask),
            TimePattern = best_appending(Ctx, Needed band TimeMask),
            case {DatePattern, TimePattern} of
                {[], _} -> TimePattern;
                {_, []} -> DatePattern;
                _ ->
                    {_, Original, _, _} = Skeleton,
                    Style = case length_of(Original, ?MONTH) of
                        4 ->
                            case length_of(Original, ?WEEKDAY) > 0 of
                                true -> full;
                                false -> long
                            end;
                        3 -> medium;
                        _ -> short
                    end,
                    format_two(proplists:get_value(Style, Glue), TimePattern, DatePattern)
            end
    end.

%% The date-time glue pattern of a style, as text with {0} the time and {1}
%% the date.
-spec date_time_glue(binary(), binary(), atom()) -> [char()].
date_time_glue(Locale, Cal, Style) ->
    {_, Glue, _, _, _} = generator(Locale, Cal),
    proplists:get_value(Style, Glue).

%% SimpleFormatter with {0} and {1}.
format_two(Pattern, Zero, One) ->
    lists:append([case Piece of {arg, 0} -> Zero; {arg, 1} -> One; {arg, _} -> []; Text -> Text end || Piece <- placeholders(Pattern)]).

format_three(Pattern, Zero, One, Two) ->
    lists:append([case Piece of {arg, 0} -> Zero; {arg, 1} -> One; {arg, 2} -> Two; {arg, _} -> []; Text -> Text end
                  || Piece <- placeholders(Pattern)]).

placeholders([]) -> [];
placeholders([${, D, $} | Rest]) when D >= $0, D =< $9 -> [{arg, D - $0} | placeholders(Rest)];
placeholders([C | Rest]) ->
    case placeholders(Rest) of
        [Text | More] when is_list(Text) -> [[C | Text] | More];
        More -> [[C] | More]
    end.

%% mapSkeletonMetacharacters: j to the default hour, J to H, and C to the
%% default hour, each with the day period that its length asks for.
map_metacharacters(Skeleton, DefaultHour) -> map_metacharacters(Skeleton, DefaultHour, [], false, false).

map_metacharacters([], _H, Acc, _Quoted, CapJ) -> {lists:reverse(Acc), CapJ};
map_metacharacters([$' | Rest], H, Acc, Quoted, CapJ) -> map_metacharacters(Rest, H, Acc, not Quoted, CapJ);
map_metacharacters([C | Rest], H, Acc, false, CapJ) when C =:= $j; C =:= $C ->
    {Run, After} = lists:splitwith(fun(X) -> X =:= C end, Rest),
    ExtraLen = length(Run),
    HourLen = 1 + (ExtraLen band 1),
    DayPeriodLen0 = case ExtraLen < 2 of true -> 1; false -> 3 + (ExtraLen bsr 1) end,
    DayPeriodLen = case H of
        _ when H =:= $H; H =:= $k -> 0;
        _ -> DayPeriodLen0
    end,
    map_metacharacters(After, H, lists:duplicate(HourLen, H) ++ lists:duplicate(DayPeriodLen, $a) ++ Acc, false, CapJ);
map_metacharacters([$J | Rest], H, Acc, false, _CapJ) -> map_metacharacters(Rest, H, [$H | Acc], false, true);
map_metacharacters([C | Rest], H, Acc, Quoted, CapJ) when not Quoted -> map_metacharacters(Rest, H, [C | Acc], Quoted, CapJ);
map_metacharacters([_ | Rest], H, Acc, Quoted, CapJ) -> map_metacharacters(Rest, H, Acc, Quoted, CapJ).

%% getBestRaw: {Pattern, SpecifiedSkeleton | none, {Distance, Missing, Extra}}.
best_raw(Entries, Source, Include) ->
    best_raw(Entries, Entries, Source, Include, {16#7fffffff, -1, none, none, {0, 0, 0}}).

best_raw(_All, [], _Source, _Include, {_, _, Pattern, Specified, Info}) -> {Pattern, Specified, Info};
best_raw(All, [{_, Trial, _, _} | Rest], Source, Include, {BestD, BestMissing, _, _, _} = Best) ->
    {D, Missing, _} = Info = distance(Source, Trial, Include),
    case D < BestD orelse (D =:= BestD andalso BestMissing < Missing) of
        false -> best_raw(All, Rest, Source, Include, Best);
        true ->
            {Pattern, Specified} = from_skeleton(All, Trial),
            Next = {D, Missing, Pattern, Specified, Info},
            case D of
                0 -> best_raw(All, [], Source, Include, Next);
                _ -> best_raw(All, Rest, Source, Include, Next)
            end
    end.

%% PatternMap::getPatternFromSkeleton by the original fields: the first
%% entry of the bucket, with its skeleton when it was specified.
from_skeleton(Entries, {_, Original, Base, _}) ->
    First = hd(fields_text(Base)),
    hd([{P, case S of true -> Sk; false -> none end}
        || {B, Sk, P, S} <- Entries, hd(B) =:= First, element(2, Sk) =:= Original]).

%% adjustFieldTypes: the fields of a found pattern with the characters and
%% lengths of the request.
adjust(Ctx, Pattern, Specified, FixFraction) ->
    Items = items(Pattern),
    adjust(Ctx, Items, Items, Specified, FixFraction, []).

adjust(_Ctx, [], _All, _Specified, _Fix, Acc) -> lists:append(lists:reverse(Acc));
adjust(Ctx, [[$' | _] | _] = Items, All, Specified, Fix, Acc) ->
    {Literal, Rest} = quote_literal(Items),
    adjust(Ctx, Rest, All, Specified, Fix, [Literal | Acc]);
adjust(Ctx, [Item | Rest], All, Specified, Fix, Acc) ->
    case is_separator(Item, All) of
        true -> adjust(Ctx, Rest, All, Specified, Fix, [Item | Acc]);
        false ->
            case row(Item) of
                none -> adjust(Ctx, Rest, All, Specified, Fix, [Item | Acc]);
                Row -> adjust(Ctx, Rest, All, Specified, Fix, [adjust_field(Ctx, Item, Row, Specified, Fix) | Acc])
            end
    end.

adjust_field(Ctx, Item, {_, Field, RowType, _}, Specified, Fix) ->
    #{request := Request, hour := DefaultHour, cap_j := CapJ, generator := {_, _, _, _, Decimal}} = Ctx,
    {_, Original, _, _} = Request,
    case Fix andalso Field =:= ?SECOND of
        true -> Item ++ Decimal ++ lists:duplicate(length_of(Original, ?FRACTION), char_of(Original, ?FRACTION));
        false ->
            case type_of(Request, Field) of
                0 -> Item;
                ReqType ->
                    ReqChar = char_of(Original, Field),
                    ReqLen = case ReqChar =:= $E andalso length_of(Original, Field) < 3 of
                        true -> 3;
                        false -> length_of(Original, Field)
                    end,
                    AdjLen = if
                        Field =:= ?MINUTE; Field =:= ?SECOND -> length(Item);
                        Specified =/= none, ReqChar =/= $c, ReqChar =/= $e ->
                            {_, SkelOriginal, _, _} = Specified,
                            SkelLen = length_of(SkelOriginal, Field),
                            case SkelLen =:= ReqLen orelse ((RowType > 0) =/= (ReqType > 0)) of
                                true -> length(Item);
                                false -> ReqLen
                            end;
                        true -> ReqLen
                    end,
                    C0 = case Field =/= ?HOUR andalso Field =/= ?MONTH andalso Field =/= ?WEEKDAY andalso
                             (Field =/= ?YEAR orelse ReqChar =:= $Y) of
                        true -> ReqChar;
                        false -> hd(Item)
                    end,
                    C1 = case C0 =:= $E andalso AdjLen < 3 of
                        true -> $e;
                        false -> C0
                    end,
                    C = case Field of
                        ?HOUR -> hour_char(C1, ReqChar, DefaultHour, CapJ);
                        _ -> C1
                    end,
                    lists:duplicate(AdjLen, C)
            end
    end.

%% The hour character for the locale's hour cycle (CLDR's hour symbols).
hour_char(_C, ReqChar, Default, CapJ) when CapJ; ReqChar =:= Default -> Default;
hour_char(_C, $h, $K, _) -> $K;
hour_char(_C, $H, $k, _) -> $k;
hour_char(_C, $k, $H, _) -> $H;
hour_char(_C, $K, $h, _) -> $h;
hour_char(C, _ReqChar, _Default, _) -> C.

%% FormatParser::isPatternSeparator, which compares the first character of
%% the item at each index of the field, as ICU does.
is_separator(Field, All) ->
    lists:all(fun({I, C}) ->
                      lists:member(C, "'\\ :\",-") orelse
                          (I < length(All) andalso hd(lists:nth(I + 1, All)) =:= $.)
              end, lists:zip(lists:seq(0, length(Field) - 1), Field)).

%% getBestAppending: the fields of the mask from the best pattern, with
%% each missing field appended by the appendItems of the locale.
best_appending(_Ctx, 0) -> [];
best_appending(Ctx, Fields) ->
    #{request := Request, generator := {Entries, _, _, _, _}} = Ctx,
    {Temp, Specified, {_, Missing, _}} = best_raw(Entries, Request, Fields),
    Result = adjust(Ctx, Temp, Specified, false),
    appending(Ctx, Fields, Result, Specified, Missing, 0).

appending(_Ctx, _Fields, Result, _Specified, 0, _Last) -> Result;
appending(_Ctx, _Fields, Result, _Specified, Missing, Missing) -> Result;
appending(Ctx, Fields, Result, Specified, Missing, Last) ->
    SecondAndFraction = (1 bsl ?SECOND) bor (1 bsl ?FRACTION),
    case Missing band SecondAndFraction =:= 1 bsl ?FRACTION andalso Fields band SecondAndFraction =:= SecondAndFraction of
        true ->
            appending(Ctx, Fields, adjust(Ctx, Result, Specified, true), Specified, Missing band bnot (1 bsl ?FRACTION), Last);
        false ->
            #{request := Request, generator := {Entries, _, Formats, Names, _}} = Ctx,
            {Temp, Specified1, {_, Missing1, _}} = best_raw(Entries, Request, Missing),
            Adjusted = adjust(Ctx, Temp, Specified1, false),
            Top = top_bit(Missing band bnot Missing1),
            Format = maps:get(Top, Formats, [${, $0, $}, $\s, 16#251C, ${, $2, $}, $:, $\s, ${, $1, $}, 16#2524]),
            Name = "'" ++ maps:get(Top, Names, "F" ++ integer_to_list(Top)) ++ "'",
            appending(Ctx, Fields, format_three(Format, Result, Adjusted, Name), Specified1, Missing1, Missing1)
    end.

top_bit(0) -> 0;
top_bit(Mask) -> min(?ZONE, bits(Mask) - 1).

bits(0) -> 0;
bits(Mask) -> 1 + bits(Mask bsr 1).
