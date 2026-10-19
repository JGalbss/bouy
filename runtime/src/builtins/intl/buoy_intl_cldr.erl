%% The locale data of Intl: the resource bundles of the ICU that Node bundles
%% (scripts/intl-icu.escript), which the NIF library holds in the external
%% term format (buoy_native:intl_cldr/0). A locale is its resource tree, and
%% a path reads from the locale, then from each parent up to root, and
%% follows an alias from the locale of the request, as ICU's
%% ures_getByKeyWithFallback does. The data decodes once per VM, and each
%% locale on its first read.
-module(buoy_intl_cldr).

-export([get/2, get/3, table/2, ordered/2, locales/1, currency_digits/1, numbering_digits/1, supplemental/1]).

%% The resource at Path, a list of keys, for Locale, a language tag without
%% extensions: a binary, an integer, a list, or a map, or undefined.
-spec get(binary(), [binary()]) -> term().
get(Locale, Path) ->
    find(Locale, locales(Locale), Path).

%% The resource at Path, or Default.
-spec get(binary(), [binary()], term()) -> term().
get(Locale, Path, Default) ->
    case get(Locale, Path) of
        undefined -> Default;
        Value -> Value
    end.

find(_Request, [], _Path) -> undefined;
find(Request, [L | Rest], Path) ->
    case walk(Request, tree(L), Path) of
        missing -> find(Request, Rest, Path);
        Value -> Value
    end.

%% The value at Path in a tree, or missing; an alias on the way restarts
%% the read from the locale of the request.
walk(Request, {alias, Target}, Path) -> resolve(Request, Target, Path);
walk(_Request, Value, []) -> Value;
walk(Request, Map, [Key | Rest]) when is_map(Map) ->
    case Map of
        #{Key := Value} -> walk(Request, Value, Rest);
        _ -> missing
    end;
walk(_Request, _Value, _Path) -> missing.

resolve(Request, <<"/LOCALE/", Target/binary>>, Path) ->
    case get(Request, binary:split(Target, <<"/">>, [global]) ++ Path) of
        undefined -> missing;
        Value -> Value
    end;
resolve(_Request, _Target, _Path) -> missing.

%% The table at Path with the entries of every locale of the chain, the
%% most specific winning at each leaf, as ures_getAllItemsWithFallback gives
%% them, with each alias resolved.
-spec table(binary(), [binary()]) -> map().
table(Locale, Path) ->
    lists:foldl(fun(L, Acc) ->
                        case raw(Locale, tree(L), Path) of
                            Map when is_map(Map) -> deep_merge(Acc, resolved(Locale, Map));
                            {alias, <<"/LOCALE/", Target/binary>>} ->
                                deep_merge(Acc, table(Locale, binary:split(Target, <<"/">>, [global])));
                            _ -> Acc
                        end
                end, #{}, lists:reverse(locales(Locale))).

%% The entries of the table at Path in the order of ICU's
%% ures_getAllChildrenWithFallback: the entries of the locale sorted by key,
%% then those of each parent that are not there yet; an alias of the table
%% continues with the entries of its target.
-spec ordered(binary(), [binary()]) -> [{binary(), term()}].
ordered(Locale, Path) ->
    {_, Entries} = ordered(Locale, Path, locales(Locale), #{}, []),
    Entries.

ordered(_Request, _Path, [], Seen, Acc) -> {Seen, Acc};
ordered(Request, Path, [L | Rest], Seen, Acc) ->
    case raw(Request, tree(L), Path) of
        Map when is_map(Map) ->
            Own = [{K, V} || {K, V} <- lists:sort(maps:to_list(resolved(Request, Map))), not maps:is_key(K, Seen)],
            ordered(Request, Path, Rest, maps:merge(Seen, maps:from_list([{K, true} || {K, _} <- Own])), Acc ++ Own);
        {alias, <<"/LOCALE/", Target/binary>>} ->
            ordered(Request, binary:split(Target, <<"/">>, [global]), locales(Request), Seen, Acc);
        _ -> ordered(Request, Path, Rest, Seen, Acc)
    end.

deep_merge(Parent, Child) ->
    maps:merge_with(fun(_, P, C) when is_map(P), is_map(C) -> deep_merge(P, C); (_, _, C) -> C end, Parent, Child).

%% The value at Path in a tree, with an alias at its end left in place.
raw(_Request, Value, []) -> Value;
raw(Request, {alias, Target}, Path) -> resolve(Request, Target, Path);
raw(Request, Map, [Key | Rest]) when is_map(Map) ->
    case Map of
        #{Key := Value} -> raw(Request, Value, Rest);
        _ -> missing
    end;
raw(_Request, _Value, _Path) -> missing.

resolved(Request, Map) ->
    maps:filtermap(fun(_, {alias, Target}) ->
                           case resolve(Request, Target, []) of
                               missing -> false;
                               Value -> {true, Value}
                           end;
                      (_, Value) -> {true, Value}
                   end, Map).

%% The locales that Locale reads from, the most specific first, ending with
%% root: the locale with the script that its likely subtags give when that
%% script is not the one of its language alone, as zh-TW reads zh-Hant-TW,
%% then each parent.
-spec locales(binary()) -> [binary()].
locales(Locale) ->
    case persistent_term:get({?MODULE, chain, Locale}, undefined) of
        undefined ->
            Chain = chain(aliased(with_script(Locale))),
            persistent_term:put({?MODULE, chain, Locale}, Chain),
            Chain;
        Chain -> Chain
    end.

aliased(Locale) ->
    case data() of
        #{aliases := #{Locale := Target}} -> Target;
        _ -> Locale
    end.

with_script(Locale) ->
    Language = buoy_ref_intl:language(Locale),
    case buoy_ref_intl:script(Locale) =:= undefined andalso Locale =/= Language of
        false -> Locale;
        true ->
            Script = likely_script(Locale),
            case Script =/= undefined andalso Script =/= likely_script(Language) of
                true -> iolist_to_binary([Language, $-, Script, binary:part(Locale, byte_size(Language), byte_size(Locale) - byte_size(Language))]);
                false -> Locale
            end
    end.

likely_script(Tag) ->
    case buoy_native:intl_maximize(Tag) of
        Max when is_binary(Max) -> buoy_ref_intl:script(Max);
        _ -> undefined
    end.

chain(<<"root">>) -> [<<"root">>];
chain(Locale) -> [Locale | chain(parent(Locale))].

parent(Locale) ->
    case data() of
        #{parents := #{Locale := Parent}} -> Parent;
        _ ->
            case binary:matches(Locale, <<"-">>) of
                [] -> <<"root">>;
                Matches -> binary:part(Locale, 0, element(1, lists:last(Matches)))
            end
    end.

tree(Locale) ->
    case persistent_term:get({?MODULE, locale, Locale}, undefined) of
        undefined ->
            Tree = case data() of
                #{locales := #{Locale := Packed}} -> binary_to_term(Packed);
                _ -> #{}
            end,
            persistent_term:put({?MODULE, locale, Locale}, Tree),
            Tree;
        Tree -> Tree
    end.

data() ->
    case persistent_term:get(?MODULE, undefined) of
        undefined ->
            Data = binary_to_term(buoy_native:intl_cldr()),
            persistent_term:put(?MODULE, Data),
            Data;
        Data -> Data
    end.

%% A supplemental table: currency_meta, numbering_systems, meta_zones,
%% timezone_types, zone_regions, or day_periods.
-spec supplemental(atom()) -> term().
supplemental(Name) -> maps:get(Name, maps:get(supplemental, data())).

%% CurrencyDigits: the fraction digits of a currency in ICU's currencyMeta,
%% else 2.
-spec currency_digits(binary()) -> non_neg_integer().
currency_digits(Code) ->
    Meta = supplemental(currency_meta),
    case maps:get(Code, Meta, maps:get(<<"DEFAULT">>, Meta, [2])) of
        [Digits | _] -> Digits;
        _ -> 2
    end.

%% The ten digits of a numbering system with simple digits, as code points,
%% or undefined; latn is undefined, since its digits need no mapping.
-spec numbering_digits(binary()) -> [char()] | undefined.
numbering_digits(<<"latn">>) -> undefined;
numbering_digits(Name) ->
    case maps:get(Name, maps:get(<<"numberingSystems">>, supplemental(numbering_systems)), undefined) of
        #{<<"algorithmic">> := 0, <<"desc">> := Desc} -> unicode:characters_to_list(Desc);
        _ -> undefined
    end.
