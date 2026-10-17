%% The system time zone of the Date family: the offset from UTC at any
%% instant, read from the TZif data of the zone (RFC 8536).
%%
%% The zone is the TZ environment variable, a zone name under the zoneinfo
%% directory or a POSIX rule such as "EST5EDT,M3.2.0,M11.1.0", or else
%% /etc/localtime. The transitions of the file give the offset up to the
%% last one, the first time type gives it before the first one (the local
%% mean time of a zone, as ICU and V8 use it), and the POSIX rule of the
%% footer gives it after the last one. The parsed zone lives in
%% persistent_term, keyed by the value of TZ.
-module(bouy_ref_tz).

-export([offset/1, local_to_utc/1, name/1, zone/0, parse_posix/1, parse_tzif/1]).

-define(DAY_MS, 86400000).

-type rule() :: {fixed, integer(), binary()} | {dst, {integer(), binary()}, {integer(), binary()}, term(), term()}.
-type zone() :: #{transitions := tuple(), types := tuple(), rule := rule() | none}.

%% The offset of local time from UTC, in milliseconds, at the UTC time T
%% in milliseconds, and whether daylight saving time applies.
-spec offset(integer()) -> {integer(), boolean(), binary()}.
offset(T) ->
    Seconds = floor_div(T, 1000),
    lookup(zone(), Seconds).

%% UTC(t) of the specification: the UTC time of the local time L. In an
%% overlap the earlier instant wins; in a gap the offset from before the
%% transition applies, so the time moves forward by the gap.
-spec local_to_utc(integer()) -> integer().
local_to_utc(L) ->
    {Before, _, _} = offset(L - ?DAY_MS),
    {After, _, _} = offset(L + ?DAY_MS),
    Candidates = [U || O <- lists:usort([Before, After]), U <- [L - O], element(1, offset(U)) =:= O],
    case Candidates of
        [] -> L - Before;
        _ -> lists:min(Candidates)
    end.

%% The long name of the zone at the UTC time T, as V8 prints it in
%% toString: "Eastern Standard Time".
-spec name(integer()) -> binary().
name(T) ->
    {Offset, Dst, Abbreviation} = offset(T),
    case long_name(Abbreviation) of
        undefined when Abbreviation =:= <<"LMT">> -> standard_name(Offset, Dst);
        undefined -> gmt_name(Offset);
        Name -> Name
    end.

%% The name for local mean time: the name of the zone's standard time.
standard_name(Offset, _Dst) ->
    #{types := Types} = zone(),
    Names = [long_name(A) || {_, false, A} <- tuple_to_list(Types), A =/= <<"LMT">>],
    case [N || N <- Names, N =/= undefined] of
        [Name | _] -> Name;
        [] -> gmt_name(Offset)
    end.

gmt_name(0) -> <<"GMT">>;
gmt_name(Offset) ->
    Sign = case Offset < 0 of
        true -> $-;
        false -> $+
    end,
    Minutes = abs(Offset) div 60000,
    iolist_to_binary(io_lib:format("GMT~c~2..0w:~2..0w", [Sign, Minutes div 60, Minutes rem 60])).

long_name(<<"UTC">>) -> <<"Coordinated Universal Time">>;
long_name(<<"UCT">>) -> <<"Coordinated Universal Time">>;
long_name(<<"GMT">>) -> <<"Greenwich Mean Time">>;
long_name(<<"EST">>) -> <<"Eastern Standard Time">>;
long_name(<<"EDT">>) -> <<"Eastern Daylight Time">>;
long_name(<<"EWT">>) -> <<"Eastern War Time">>;
long_name(<<"EPT">>) -> <<"Eastern Peace Time">>;
long_name(<<"CST">>) -> <<"Central Standard Time">>;
long_name(<<"CDT">>) -> <<"Central Daylight Time">>;
long_name(<<"MST">>) -> <<"Mountain Standard Time">>;
long_name(<<"MDT">>) -> <<"Mountain Daylight Time">>;
long_name(<<"PST">>) -> <<"Pacific Standard Time">>;
long_name(<<"PDT">>) -> <<"Pacific Daylight Time">>;
long_name(<<"AKST">>) -> <<"Alaska Standard Time">>;
long_name(<<"AKDT">>) -> <<"Alaska Daylight Time">>;
long_name(<<"HST">>) -> <<"Hawaii-Aleutian Standard Time">>;
long_name(<<"BST">>) -> <<"British Summer Time">>;
long_name(<<"IST">>) -> <<"India Standard Time">>;
long_name(<<"CET">>) -> <<"Central European Standard Time">>;
long_name(<<"CEST">>) -> <<"Central European Summer Time">>;
long_name(<<"EET">>) -> <<"Eastern European Standard Time">>;
long_name(<<"EEST">>) -> <<"Eastern European Summer Time">>;
long_name(<<"WET">>) -> <<"Western European Standard Time">>;
long_name(<<"WEST">>) -> <<"Western European Summer Time">>;
long_name(<<"JST">>) -> <<"Japan Standard Time">>;
long_name(<<"KST">>) -> <<"Korean Standard Time">>;
long_name(<<"AEST">>) -> <<"Australian Eastern Standard Time">>;
long_name(<<"AEDT">>) -> <<"Australian Eastern Daylight Time">>;
long_name(_) -> undefined.

%%% The zone

-spec zone() -> zone().
zone() ->
    Key = os:getenv("TZ"),
    case persistent_term:get({?MODULE, Key}, undefined) of
        undefined ->
            Zone = load(Key),
            persistent_term:put({?MODULE, Key}, Zone),
            Zone;
        Zone -> Zone
    end.

load(false) -> file_zone("/etc/localtime");
load("") -> utc();
load(":" ++ Name) -> load(Name);
load(Name) ->
    Path = case Name of
        "/" ++ _ -> Name;
        _ -> filename:join(zoneinfo(), Name)
    end,
    case filelib:is_regular(Path) of
        true -> file_zone(Path);
        false ->
            case parse_posix(list_to_binary(Name)) of
                {ok, Rule} -> #{transitions => {}, types => {}, rule => Rule};
                error -> utc()
            end
    end.

zoneinfo() ->
    case [D || D <- ["/usr/share/zoneinfo", "/var/db/timezone/zoneinfo", "/usr/lib/zoneinfo"], filelib:is_dir(D)] of
        [D | _] -> D;
        [] -> "/usr/share/zoneinfo"
    end.

utc() -> #{transitions => {}, types => {}, rule => {fixed, 0, <<"UTC">>}}.

file_zone(Path) ->
    case file:read_file(Path) of
        {ok, Data} ->
            case parse_tzif(Data) of
                {ok, Zone} -> Zone;
                error -> utc()
            end;
        {error, _} -> utc()
    end.

%% A TZif file: the version 2 data with 64-bit times when the file has it.
-spec parse_tzif(binary()) -> {ok, zone()} | error.
parse_tzif(<<"TZif", Version, _:15/binary, Counts:24/binary, Rest/binary>>) ->
    <<IsUt:32, IsStd:32, Leap:32, Time:32, Type:32, Char:32>> = Counts,
    V1Size = Time * 5 + Type * 6 + Char + Leap * 8 + IsStd + IsUt,
    case Version >= $2 of
        true ->
            <<_:V1Size/binary, "TZif", _, _:15/binary, Counts2:24/binary, Data/binary>> = Rest,
            <<IsUt2:32, IsStd2:32, Leap2:32, Time2:32, Type2:32, Char2:32>> = Counts2,
            {Transitions, Indexes, Types, Chars, Tail} = blocks(Data, 64, Time2, Type2, Char2),
            Skip = Leap2 * 12 + IsStd2 + IsUt2,
            <<_:Skip/binary, Footer/binary>> = Tail,
            {ok, zone(Transitions, Indexes, Types, Chars, footer(Footer))};
        false ->
            {Transitions, Indexes, Types, Chars, _} = blocks(Rest, 32, Time, Type, Char),
            {ok, zone(Transitions, Indexes, Types, Chars, none)}
    end;
parse_tzif(_) -> error.

blocks(Data, Bits, Time, Type, Char) ->
    TimeBytes = Time * Bits div 8,
    <<TimeBin:TimeBytes/binary, IndexBin:Time/binary, Rest/binary>> = Data,
    TypeBytes = Type * 6,
    <<TypeBin:TypeBytes/binary, Chars:Char/binary, Tail/binary>> = Rest,
    Transitions = [T || <<T:Bits/signed>> <= TimeBin],
    Indexes = binary_to_list(IndexBin),
    Types = [{Offset, Dst =:= 1, Abbr} || <<Offset:32/signed, Dst, Abbr>> <= TypeBin],
    {Transitions, Indexes, Types, Chars, Tail}.

zone(Transitions, Indexes, Types, Chars, Rule) ->
    Named = list_to_tuple([{Offset * 1000, Dst, abbreviation(Chars, Abbr)} || {Offset, Dst, Abbr} <- Types]),
    #{transitions => list_to_tuple(lists:zip(Transitions, Indexes)), types => Named, rule => Rule}.

abbreviation(Chars, Start) ->
    <<_:Start/binary, Rest/binary>> = Chars,
    hd(binary:split(Rest, <<0>>)).

footer(<<"\n", Rest/binary>>) ->
    case binary:split(Rest, <<"\n">>) of
        [<<>> | _] -> none;
        [Text | _] ->
            case parse_posix(Text) of
                {ok, Rule} -> Rule;
                error -> none
            end
    end;
footer(_) -> none.

%%% Lookup

lookup(#{transitions := Transitions, types := Types, rule := Rule}, Seconds) ->
    Count = tuple_size(Transitions),
    case Count of
        0 -> rule_offset(Rule, Seconds, Types);
        _ ->
            {First, _} = element(1, Transitions),
            {Last, LastType} = element(Count, Transitions),
            if
                Seconds < First -> element(1, Types);
                Seconds >= Last, Rule =/= none -> rule_offset(Rule, Seconds, Types);
                Seconds >= Last -> element(LastType + 1, Types);
                true -> element(search(Transitions, Seconds, 1, Count) + 1, Types)
            end
    end.

%% The type index of the last transition at or before Seconds.
search(Transitions, Seconds, Low, High) when Low >= High ->
    {_, Type} = element(Low, Transitions),
    case element(Low, Transitions) of
        {T, _} when T =< Seconds -> Type;
        _ -> element(2, element(Low - 1, Transitions))
    end;
search(Transitions, Seconds, Low, High) ->
    Mid = (Low + High + 1) div 2,
    case element(Mid, Transitions) of
        {T, _} when T =< Seconds -> search(Transitions, Seconds, Mid, High);
        _ -> search(Transitions, Seconds, Low, Mid - 1)
    end.

rule_offset(none, _Seconds, Types) when tuple_size(Types) > 0 -> element(1, Types);
rule_offset(none, _Seconds, _Types) -> {0, false, <<"UTC">>};
rule_offset({fixed, Offset, Name}, _Seconds, _Types) -> {Offset, false, Name};
rule_offset({dst, {Std, StdName}, {Dst, DstName}, Start, End}, Seconds, _Types) ->
    Year = year_of(Seconds + Std div 1000),
    %% The start is in standard time and the end in daylight time, both local.
    StartUtc = rule_time(Start, Year) - Std div 1000,
    EndUtc = rule_time(End, Year) - Dst div 1000,
    InDst = case StartUtc < EndUtc of
        true -> Seconds >= StartUtc andalso Seconds < EndUtc;
        false -> not (Seconds >= EndUtc andalso Seconds < StartUtc)
    end,
    case InDst of
        true -> {Dst, true, DstName};
        false -> {Std, false, StdName}
    end.

%% The local seconds since the epoch of a rule date in Year.
rule_time({{month, M, W, D}, Time}, Year) ->
    First = days_from_civil(Year, M, 1),
    FirstWeekday = weekday(First),
    Day1 = 1 + ((D - FirstWeekday + 7) rem 7),
    DaysInMonth = days_in_month(Year, M),
    Day = case W of
        5 -> last_day(Day1, DaysInMonth);
        _ -> min(Day1 + (W - 1) * 7, last_day(Day1, DaysInMonth))
    end,
    (days_from_civil(Year, M, Day)) * 86400 + Time;
rule_time({{julian, N}, Time}, Year) ->
    %% Jn counts 1..365 and never February 29.
    Leap = case is_leap(Year) andalso N >= 60 of
        true -> 1;
        false -> 0
    end,
    (days_from_civil(Year, 1, 1) + N - 1 + Leap) * 86400 + Time;
rule_time({{day, N}, Time}, Year) ->
    (days_from_civil(Year, 1, 1) + N) * 86400 + Time.

last_day(Day, DaysInMonth) when Day + 7 > DaysInMonth -> Day;
last_day(Day, DaysInMonth) -> last_day(Day + 7, DaysInMonth).

weekday(Days) -> ((Days rem 7) + 11) rem 7.

year_of(Seconds) ->
    {Y, _, _} = civil_from_days(floor_div(Seconds, 86400)),
    Y.

is_leap(Y) -> (Y rem 4 =:= 0 andalso Y rem 100 =/= 0) orelse Y rem 400 =:= 0.

days_in_month(Y, 2) ->
    case is_leap(Y) of
        true -> 29;
        false -> 28
    end;
days_in_month(_, M) when M =:= 4; M =:= 6; M =:= 9; M =:= 11 -> 30;
days_in_month(_, _) -> 31.

%% Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant).
days_from_civil(Y0, M, D) ->
    Y = case M =< 2 of
        true -> Y0 - 1;
        false -> Y0
    end,
    Era = floor_div(Y, 400),
    Yoe = Y - Era * 400,
    Mp = (M + 9) rem 12,
    Doy = (153 * Mp + 2) div 5 + D - 1,
    Doe = Yoe * 365 + Yoe div 4 - Yoe div 100 + Doy,
    Era * 146097 + Doe - 719468.

civil_from_days(Z0) ->
    Z = Z0 + 719468,
    Era = floor_div(Z, 146097),
    Doe = Z - Era * 146097,
    Yoe = (Doe - Doe div 1460 + Doe div 36524 - Doe div 146096) div 365,
    Y = Yoe + Era * 400,
    Doy = Doe - (365 * Yoe + Yoe div 4 - Yoe div 100),
    Mp = (5 * Doy + 2) div 153,
    D = Doy - (153 * Mp + 2) div 5 + 1,
    M = case Mp < 10 of
        true -> Mp + 3;
        false -> Mp - 9
    end,
    case M =< 2 of
        true -> {Y + 1, M, D};
        false -> {Y, M, D}
    end.

floor_div(A, B) when A >= 0 -> A div B;
floor_div(A, B) -> -((-A + B - 1) div B).

%%% POSIX TZ rules

%% "std offset [dst [offset] [,start[/time],end[/time]]]". Offsets in a
%% rule are hours west of UTC, so the result negates them.
-spec parse_posix(binary()) -> {ok, rule()} | error.
parse_posix(Text) ->
    try
        {StdName, R1} = posix_name(Text),
        {StdOffset, R2} = posix_offset(R1),
        Std = -StdOffset * 1000,
        case R2 of
            <<>> -> {ok, {fixed, Std, StdName}};
            _ ->
                {DstName, R3} = posix_name(R2),
                {Dst, R4} = case R3 of
                    <<C, _/binary>> when C =:= $+; C =:= $-; C >= $0, C =< $9 ->
                        {O, R} = posix_offset(R3),
                        {-O * 1000, R};
                    _ -> {Std + 3600000, R3}
                end,
                {Start, End} = case R4 of
                    <<",", Rules/binary>> ->
                        [S, E] = binary:split(Rules, <<",">>),
                        {posix_date(S), posix_date(E)};
                    <<>> -> {posix_date(<<"M3.2.0">>), posix_date(<<"M11.1.0">>)}
                end,
                {ok, {dst, {Std, StdName}, {Dst, DstName}, Start, End}}
        end
    catch
        _:_ -> error
    end.

posix_name(<<"<", Rest/binary>>) ->
    [Name, Tail] = binary:split(Rest, <<">">>),
    {Name, Tail};
posix_name(Text) ->
    Size = length(lists:takewhile(fun(C) -> (C >= $A andalso C =< $Z) orelse (C >= $a andalso C =< $z) end, binary_to_list(Text))),
    Size >= 3 orelse error(badarg),
    <<Name:Size/binary, Rest/binary>> = Text,
    {Name, Rest}.

%% A signed time [+-]hh[:mm[:ss]] in seconds.
posix_offset(<<"-", Rest/binary>>) ->
    {S, R} = posix_clock(Rest),
    {-S, R};
posix_offset(<<"+", Rest/binary>>) -> posix_clock(Rest);
posix_offset(Text) -> posix_clock(Text).

posix_clock(Text) ->
    {Parts, Rest} = clock_parts(Text, []),
    [H | MS] = Parts ++ [0, 0],
    [M, S | _] = MS,
    {H * 3600 + M * 60 + S, Rest}.

clock_parts(Text, Acc) ->
    {Digits, Rest} = lists:splitwith(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Text)),
    Digits =/= [] orelse error(badarg),
    Acc1 = [list_to_integer(Digits) | Acc],
    case Rest of
        ":" ++ More when length(Acc1) < 3 -> clock_parts(list_to_binary(More), Acc1);
        _ -> {lists:reverse(Acc1), list_to_binary(Rest)}
    end.

posix_date(Text) ->
    {Date, Time} = case binary:split(Text, <<"/">>) of
        [D, T] -> {D, element(1, posix_offset(T))};
        [D] -> {D, 7200}
    end,
    Rule = case Date of
        <<"M", Spec/binary>> ->
            [M, W, Day] = [binary_to_integer(P) || P <- binary:split(Spec, <<".">>, [global])],
            {month, M, W, Day};
        <<"J", N/binary>> -> {julian, binary_to_integer(N)};
        N -> {day, binary_to_integer(N)}
    end,
    {Rule, Time}.
