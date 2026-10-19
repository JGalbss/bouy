%% The CLDR locale data of Intl (scripts/intl-cldr.escript), which the NIF
%% library holds in the external term format (buoy_native:intl_cldr/0). Each
%% locale holds the entries that differ from its parent, so an entry comes
%% from the locale or from the nearest ancestor that has it, as ICU's
%% resource bundles inherit. The data decodes once per VM, and each locale
%% on its first read.
-module(buoy_intl_cldr).

-export([get/2, get/3, locales/1, own/1, currency_digits/1, numbering_digits/1, supplemental/1]).

%% The entry Key of Locale, a language tag without extensions, or undefined.
-spec get(binary(), term()) -> term().
get(Locale, Key) ->
    find(locales(Locale), Key).

%% The entry Key of Locale, or Default.
-spec get(binary(), term(), term()) -> term().
get(Locale, Key, Default) ->
    case get(Locale, Key) of
        undefined -> Default;
        Value -> Value
    end.

find([], _Key) -> undefined;
find([L | Rest], Key) ->
    case entries(L) of
        #{Key := Value} -> Value;
        _ -> find(Rest, Key)
    end.

%% The locales that Locale reads from, the most specific first: the locale
%% with the script that its likely subtags give when that script is not the
%% one of its language alone, as zh-TW reads zh-Hant-TW, then each parent.
-spec locales(binary()) -> [binary()].
locales(Locale) ->
    case persistent_term:get({?MODULE, chain, Locale}, undefined) of
        undefined ->
            Chain = chain(with_script(Locale)),
            persistent_term:put({?MODULE, chain, Locale}, Chain),
            Chain;
        Chain -> Chain
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

chain(<<"und">>) -> [];
chain(Locale) ->
    [Locale | chain(parent(Locale))].

parent(Locale) ->
    case data() of
        #{parents := #{Locale := Parent}} -> Parent;
        _ ->
            case binary:matches(Locale, <<"-">>) of
                [] -> <<"und">>;
                Matches -> binary:part(Locale, 0, element(1, lists:last(Matches)))
            end
    end.

%% The entries of one locale of the chain that differ from its parent.
-spec own(binary()) -> map().
own(Locale) -> entries(Locale).

%% A table of the supplemental data, such as metazones.
-spec supplemental(atom()) -> term().
supplemental(Name) -> maps:get(Name, data()).

entries(Locale) ->
    case persistent_term:get({?MODULE, locale, Locale}, undefined) of
        undefined ->
            Entries = case data() of
                #{locales := #{Locale := Delta}} -> binary_to_term(Delta);
                _ -> #{}
            end,
            persistent_term:put({?MODULE, locale, Locale}, Entries),
            Entries;
        Entries -> Entries
    end.

data() ->
    case persistent_term:get(?MODULE, undefined) of
        undefined ->
            Data = binary_to_term(buoy_native:intl_cldr()),
            persistent_term:put(?MODULE, Data),
            Data;
        Data -> Data
    end.

%% CurrencyDigits: the fraction digits of a currency, 2 when CLDR has none.
-spec currency_digits(binary()) -> non_neg_integer().
currency_digits(Code) ->
    maps:get(Code, maps:get(currency_digits, data()), 2).

%% The ten digits of a numbering system with simple digits, as code points,
%% or undefined.
-spec numbering_digits(binary()) -> [char()] | undefined.
numbering_digits(Name) ->
    maps:get(Name, maps:get(numbering_digits, data()), undefined).
