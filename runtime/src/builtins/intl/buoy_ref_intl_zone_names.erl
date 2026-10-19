%% The names of time zones in Intl.DateTimeFormat, as ICU's TimeZoneFormat
%% gives them to V8: the localized GMT formats (O and OOOO), the specific
%% names (z and zzzz) of the zone or of its metazone at the instant, and the
%% generic names (v and vvvv), which fall back to the region or city of the
%% zone. The names come from CLDR (buoy_intl_cldr), keyed by the CLDR
%% identifier of the zone.
-module(buoy_ref_intl_zone_names).

-export([name/6, gmt/4]).

-define(DAY, 86400000).

%% The name of Zone (an IANA identifier, or {offset, Minutes}) in the locale
%% for a pattern field such as "zzzz", at the UTC instant T, with the offset
%% and daylight flag of the instant. Digits are the locale's digits.
-spec name(binary(), [char()], term(), integer(), {integer(), boolean()}, [char()] | undefined) -> [char()].
name(Locale, [C | _] = Field, Zone, T, {Offset, Dst}, Digits) ->
    Long = length(Field) >= 4,
    Name = case {C, Zone} of
        {_, {offset, _}} -> undefined;
        {$z, _} -> specific(Locale, canonical(Zone), T, Long, Dst);
        {$v, _} -> generic(Locale, canonical(Zone), T, Long, Offset, Dst);
        _ -> undefined
    end,
    case Name of
        undefined -> gmt(Locale, Offset, Long, Digits);
        _ -> unicode:characters_to_list(Name)
    end.

canonical(Zone) ->
    maps:get(Zone, buoy_intl_cldr:supplemental(zone_canonical), Zone).

%% The specific name: the zone's own standard or daylight name, else its
%% metazone's.
specific(Locale, Zone, T, Long, Dst) ->
    Width = width(Long),
    Kind = case Dst of
        true -> <<"daylight">>;
        false -> <<"standard">>
    end,
    case zone_name(Locale, Zone, Width, Kind) of
        undefined ->
            case metazone(Zone, T) of
                undefined -> undefined;
                Mz -> meta_name(Locale, Mz, Width, Kind)
            end;
        Name -> Name
    end.

width(true) -> <<"long">>;
width(false) -> <<"short">>.

zone_name(Locale, Zone, Width, Kind) ->
    maps:get(Kind, maps:get(Width, buoy_intl_cldr:get(Locale, {tz_zone, Zone}, #{}), #{}), undefined).

meta_name(Locale, Mz, Width, Kind) ->
    maps:get(Kind, maps:get(Width, buoy_intl_cldr:get(Locale, {tz_meta, Mz}, #{}), #{}), undefined).

%% The metazone of the zone at the instant, or undefined.
metazone(Zone, T) ->
    Uses = maps:get(Zone, buoy_intl_cldr:supplemental(metazones), []),
    case [Mz || {From, To, Mz} <- Uses, From =:= undefined orelse From =< T, To =:= undefined orelse T < To] of
        [Mz | _] -> Mz;
        [] -> undefined
    end.

%% TZGNCore::getDisplayName: the generic non-location name, else the
%% generic location name.
generic(Locale, Zone, T, Long, Offset, Dst) ->
    case non_location(Locale, Zone, T, Long, Offset, Dst) of
        undefined -> location(Locale, Zone);
        Name -> Name
    end.

non_location(Locale, Zone, T, Long, Offset, Dst) ->
    Width = width(Long),
    case zone_name(Locale, Zone, Width, <<"generic">>) of
        undefined ->
            case metazone(Zone, T) of
                undefined -> undefined;
                Mz ->
                    Standard = case not Dst andalso not uses_dst_near(Zone, T) of
                        true ->
                            case specific(Locale, Zone, T, Long, false) of
                                undefined -> undefined;
                                S ->
                                    case string:equal(S, meta_name(Locale, Mz, Width, <<"generic">>), true) of
                                        true -> undefined;
                                        false -> S
                                    end
                            end;
                        false -> undefined
                    end,
                    case Standard of
                        undefined -> meta_generic(Locale, Zone, Mz, Width, T, Offset);
                        _ -> Standard
                    end
            end;
        Name -> Name
    end.

%% Whether the zone keeps daylight time within 184 days of the instant.
uses_dst_near(Zone, T) ->
    lists:any(fun(At) -> element(2, buoy_ref_tz:info_in(iana(Zone), At)) end, [T - 184 * ?DAY, T + 184 * ?DAY]).

%% The metazone's generic name, or its partial location form when the
%% golden zone of the metazone in the locale's region has another offset.
meta_generic(Locale, Zone, Mz, Width, T, Offset) ->
    case meta_name(Locale, Mz, Width, <<"generic">>) of
        undefined -> undefined;
        Name ->
            Golden = golden(Mz, target_region(Locale)),
            case Golden =:= undefined orelse Golden =:= Zone of
                true -> Name;
                false ->
                    {GoldenOffset, _} = buoy_ref_tz:info_in(iana(Golden), T),
                    case GoldenOffset =:= Offset of
                        true -> Name;
                        false ->
                            Fallback = buoy_intl_cldr:get(Locale, {tz_format, <<"fallbackFormat">>}, <<"{1} ({0})">>),
                            fill(Fallback, [{<<"{1}">>, Name}, {<<"{0}">>, place(Locale, Zone)}])
                    end
            end
    end.

golden(Mz, Region) ->
    Golden = buoy_intl_cldr:supplemental(golden_zones),
    maps:get({Mz, Region}, Golden, maps:get({Mz, <<"001">>}, Golden, undefined)).

%% The region of the locale or of its likely subtags, else 001.
target_region(Locale) ->
    case buoy_ref_intl:region(Locale) of
        undefined ->
            case buoy_native:intl_maximize(Locale) of
                Max when is_binary(Max) -> case buoy_ref_intl:region(Max) of undefined -> <<"001">>; R -> R end;
                _ -> <<"001">>
            end;
        R -> R
    end.

%% The generic location name: the region format with the country when the
%% zone is the one or the primary zone of its country, else with its city.
location(Locale, Zone) ->
    case maps:get(Zone, buoy_intl_cldr:supplemental(zone_regions), undefined) of
        undefined -> undefined;
        Region when Region =:= <<"ZZ">>; Region =:= <<"001">> -> undefined;
        _ ->
            Format = buoy_intl_cldr:get(Locale, {tz_format, <<"regionFormat">>}, <<"{0} Time">>),
            fill(Format, [{<<"{0}">>, place(Locale, Zone)}])
    end.

%% The country of the zone when it is its country's one or primary zone,
%% else the exemplar city of the zone.
place(Locale, Zone) ->
    Regions = buoy_intl_cldr:supplemental(zone_regions),
    Region = maps:get(Zone, Regions, undefined),
    Canonical = buoy_intl_cldr:supplemental(zone_canonical),
    Zones = lists:usort([maps:get(Z, Canonical, Z) || {Z, R} <- maps:to_list(Regions), R =:= Region]),
    Primary = maps:get(Region, buoy_intl_cldr:supplemental(primary_zones), undefined),
    case (length(Zones) =:= 1 orelse Primary =:= Zone) andalso buoy_intl_cldr:get(Locale, {region, Region}) of
        Country when is_binary(Country) -> Country;
        _ -> city(Locale, Zone)
    end.

city(Locale, Zone) ->
    case maps:get(<<"exemplarCity">>, buoy_intl_cldr:get(Locale, {tz_zone, Zone}, #{}), undefined) of
        undefined ->
            Last = lists:last(binary:split(Zone, <<"/">>, [global])),
            binary:replace(Last, <<"_">>, <<" ">>, [global]);
        City -> City
    end.

fill(Pattern, Pairs) ->
    lists:foldl(fun({Key, Value}, Acc) -> binary:replace(Acc, Key, Value, [global]) end, Pattern, Pairs).

%% The IANA identifier that the zone database knows for a CLDR identifier.
iana(Zone) ->
    case buoy_ref_tz:named(Zone) of
        {ok, Id} -> Id;
        error -> Zone
    end.

%% The localized GMT format of an offset in milliseconds, long ("GMT-08:00")
%% or short ("GMT-8").
-spec gmt(binary(), integer(), boolean(), [char()] | undefined) -> [char()].
gmt(Locale, 0, _Long, _Digits) ->
    unicode:characters_to_list(buoy_intl_cldr:get(Locale, {tz_format, <<"gmtZeroFormat">>}, <<"GMT">>));
gmt(Locale, Offset, Long, Digits) ->
    Format = unicode:characters_to_list(buoy_intl_cldr:get(Locale, {tz_format, <<"gmtFormat">>}, <<"GMT{0}">>)),
    [Positive, Negative] = string:split(unicode:characters_to_list(buoy_intl_cldr:get(Locale, {tz_format, <<"hourFormat">>}, <<"+HH:mm;-HH:mm">>)), ";"),
    Pattern = case Offset < 0 of
        true -> Negative;
        false -> Positive
    end,
    Seconds = abs(Offset) div 1000,
    {H, M, S} = {Seconds div 3600, Seconds div 60 rem 60, Seconds rem 60},
    Text = offset_text(Pattern, H, M, S, Long, Digits),
    lists:flatten(string:replace(Format, "{0}", Text)).

%% The hour pattern with the offset in place: hours of two digits in the
%% long form and of one or two in the short form, minutes only when the
%% short form needs them, and seconds when there are any.
offset_text(Pattern, H, M, S, Long, Digits) ->
    {Sign, Rest} = lists:splitwith(fun(C) -> C =/= $H end, Pattern),
    {_Hours, AfterHours} = lists:splitwith(fun(C) -> C =:= $H end, Rest),
    {Separator, _} = lists:splitwith(fun(C) -> C =/= $m end, AfterHours),
    Hour = case Long of
        true -> pad(H, 2);
        false -> integer_to_list(H)
    end,
    Minutes = case Long orelse M =/= 0 orelse S =/= 0 of
        true -> Separator ++ pad(M, 2);
        false -> ""
    end,
    Secs = case S of
        0 -> "";
        _ -> Separator ++ pad(S, 2)
    end,
    localize(Sign ++ Hour ++ Minutes ++ Secs, Digits).

pad(N, Width) -> lists:duplicate(max(0, Width - length(integer_to_list(N))), $0) ++ integer_to_list(N).

localize(Text, undefined) -> Text;
localize(Text, Digits) -> [case C >= $0 andalso C =< $9 of true -> lists:nth(C - $0 + 1, Digits); false -> C end || C <- Text].
