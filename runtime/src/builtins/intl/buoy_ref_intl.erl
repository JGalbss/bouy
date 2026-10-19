%% The Intl family: the Intl namespace object, Intl.getCanonicalLocales and
%% Intl.supportedValuesOf, and the abstract operations of ECMA-402 that the
%% Intl constructors share (sections 6 and 9 of ECMA-402): language tags,
%% CanonicalizeLocaleList, the Unicode locale extension, ResolveLocale,
%% FilterLocales, and the options. The CLDR data and its algorithms come from
%% ICU4X through buoy_native (docs/design/intl.md), as V8 and JavaScriptCore
%% take them from ICU; the operations that user code can observe, such as
%% the reads of options and their order, stay here.
-module(buoy_ref_intl).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4]).
-export([canonicalize_locale_list/1, canonicalize_tag/1, canonicalize_uvalue/2, default_locale/0]).
-export([base_name/1, language/1, script/1, region/1, variants/1]).
-export([unicode_extension/1, extension_components/1, insert_extension/3, remove_extension/1]).
-export([lookup_matcher/2, resolve_locale/5, resolve_options/5, filter_locales/3, options_object/1]).
-export([coerce_options/1, get_options_object/1, get_option/5, range_error/1, is_type/1, is_language/1, is_script/1, is_region/1, is_variant/1]).

-import(buoy_ref_realm, [arg/2, record/4]).

%% A key of the -t- extension: a letter, then a digit.
-define(IS_TKEY(K), (byte_size(K) =:= 2 andalso binary_part(K, 1, 1) >= <<"0">> andalso binary_part(K, 1, 1) =< <<"9">>)).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Intl', record(object, ?OBJECT_PROTO,
                     ?METHODS(<<"Intl">>, [{<<"getCanonicalLocales">>, 1}, {<<"supportedValuesOf">>, 1}])
                     ++ [{<<"Collator">>, buoy_ref_intl_collator:constructor()}, {<<"Locale">>, buoy_ref_intl_locale:constructor()},
                         {<<"ListFormat">>, buoy_ref_intl_list_format:constructor()},
                         {<<"NumberFormat">>, buoy_ref_intl_number_format:constructor()},
                         {<<"PluralRules">>, buoy_ref_intl_plural_rules:constructor()},
                         {<<"Segmenter">>, buoy_ref_intl_segmenter:constructor()},
                         {?SYM(toStringTag), <<"Intl">>, 4}],
                     none)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Intl">>, {'$o', 'Intl'}}].

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Intl">>, <<"getCanonicalLocales">>, _This, Args) ->
    buoy_heap:new_array(canonicalize_locale_list(arg(1, Args)));
method(<<"Intl">>, <<"supportedValuesOf">>, _This, Args) ->
    Key = buoy_ref:to_string(arg(1, Args)),
    buoy_heap:new_array(supported_values(Key)).

%% AvailableCanonical* of ECMA-402 section 6: each sorted by code units.
supported_values(<<"calendar">>) -> buoy_ref_intl_data:calendars();
supported_values(<<"collation">>) -> collations();
supported_values(<<"currency">>) -> buoy_ref_intl_data:currencies();
supported_values(<<"numberingSystem">>) -> buoy_ref_intl_data:numbering_systems();
supported_values(<<"timeZone">>) -> buoy_ref_intl_data:time_zones();
supported_values(<<"unit">>) -> buoy_ref_intl_data:units();
supported_values(Key) -> range_error(buoy_ref_string:concat([<<"Invalid key : ">>, Key])).

%% The collation types that ICU4X has data for in some available locale, so
%% that Intl.Collator supports each one: made once per VM.
collations() ->
    case persistent_term:get({?MODULE, collations}, undefined) of
        undefined ->
            Types = lists:usort([T || L <- buoy_ref_intl_data:available_locales(), T <- buoy_native:intl_collation_types(L)]),
            persistent_term:put({?MODULE, collations}, Types),
            Types;
        Types -> Types
    end.

-spec range_error(term()) -> no_return().
range_error(Message) -> buoy_heap:throw_error('RangeError', Message).

%%% Language tags (ECMA-402 section 6.2)

%% CanonicalizeLocaleList: the canonical tags of locales, in order, once each.
-spec canonicalize_locale_list(term()) -> [binary()].
canonicalize_locale_list(undefined) ->
    [];
canonicalize_locale_list(Locales) ->
    Object = case ?IS_STRING(Locales) orelse is_locale(Locales) of
        true -> buoy_heap:new_array([Locales]);
        false -> buoy_ref:to_object(Locales)
    end,
    Length = buoy_ref_array:length_of(Object),
    lists:foldl(fun(K, Seen) ->
                        case buoy_heap:has(Object, K) of
                            false -> Seen;
                            true ->
                                Tag = canonical_or_throw(tag_of(buoy_ref:get(Object, K))),
                                case lists:member(Tag, Seen) of
                                    true -> Seen;
                                    false -> Seen ++ [Tag]
                                end
                        end
                end, [], lists:seq(0, Length - 1)).

tag_of(Element) when ?IS_STRING(Element) -> Element;
tag_of(Element) when ?IS_OBJECT(Element) ->
    case is_locale(Element) of
        true -> maps:get(locale, buoy_heap:slots(Element));
        false -> buoy_ref:to_string(Element)
    end;
tag_of(_Element) -> buoy_ref:type_error(<<"Language ID should be string or object.">>).

is_locale(V) -> ?IS_OBJECT(V) andalso buoy_heap:class_of(V) =:= intl_locale.

canonical_or_throw(Tag) ->
    case canonicalize_tag(Tag) of
        {ok, Canonical} -> Canonical;
        error -> range_error(buoy_ref_string:concat([<<"Incorrect locale information provided">>]))
    end.

%% IsWellFormedLanguageTag, then CanonicalizeUnicodeLocaleId: ICU4X replaces
%% the aliases of the language identifier and orders the subtags, and the
%% values of the -u- and -t- extensions take their CLDR aliases here
%% (buoy_intl_aliases), with a -u- value of "true" removed.
-spec canonicalize_tag(term()) -> {ok, binary()} | error.
canonicalize_tag(Tag) when is_binary(Tag) ->
    case is_ascii_tag(Tag) andalso buoy_native:intl_canonicalize(Tag) of
        Canonical when is_binary(Canonical) -> {ok, extension_values(Canonical)};
        _ -> error
    end;
canonicalize_tag(_Tag) ->
    error.

is_ascii_tag(Tag) ->
    lists:all(fun(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
                        (C >= $0 andalso C =< $9) orelse C =:= $- end, binary_to_list(Tag)).

%% The values of the -u- and -t- extensions of a canonical tag in their
%% canonical form.
extension_values(Tag) ->
    join(values(binary:split(Tag, <<"-">>, [global]), base)).

values([], _Section) -> [];
values([<<"x">> | Rest], _Section) -> [<<"x">> | Rest];
values([S | Rest], _Section) when byte_size(S) =:= 1 -> [S | values(Rest, section(S))];
values([Key | Rest], Section) when (Section =:= u andalso byte_size(Key) =:= 2) orelse (Section =:= t andalso ?IS_TKEY(Key)) ->
    {Value, After} = lists:splitwith(fun(S) -> byte_size(S) > 2 end, Rest),
    case buoy_intl_aliases:value(Key, join(Value)) of
        <<"true">> when Section =:= u -> [Key | values(After, Section)];
        <<>> -> [Key | values(After, Section)];
        Canonical -> [Key, Canonical | values(After, Section)]
    end;
values([S | Rest], Section) -> [S | values(Rest, Section)].

section(<<"u">>) -> u;
section(<<"t">>) -> t;
section(_) -> other.

%% CanonicalizeUValue: the canonical form of a value of the -u- key Key.
%% A value of "true" is the empty value, as UTS #35 removes it.
-spec canonicalize_uvalue(binary(), binary()) -> binary().
canonicalize_uvalue(Key, Value) ->
    case buoy_intl_aliases:value(Key, string:lowercase(Value)) of
        <<"true">> -> <<>>;
        Canonical -> Canonical
    end.

%% DefaultLocale: the language of LC_ALL, LC_MESSAGES, or LANG, as Node's ICU
%% reads it, else en-US.
-spec default_locale() -> binary().
default_locale() ->
    case persistent_term:get({?MODULE, default_locale}, undefined) of
        undefined ->
            Locale = find_default([os:getenv("LC_ALL"), os:getenv("LC_MESSAGES"), os:getenv("LANG")]),
            persistent_term:put({?MODULE, default_locale}, Locale),
            Locale;
        Locale ->
            Locale
    end.

find_default([]) -> <<"en-US">>;
find_default([Value | Rest]) when is_list(Value), Value =/= "", Value =/= "C", Value =/= "POSIX" ->
    Tag = list_to_binary(lists:map(fun($_) -> $-; (C) -> C end, hd(string:split(hd(string:split(Value, ".")), "@")))),
    case canonicalize_tag(Tag) of
        {ok, Canonical} -> remove_extension(Canonical);
        error -> find_default(Rest)
    end;
find_default([_ | Rest]) -> find_default(Rest).

%%% The parts of a tag (ECMA-402 section 15.5)

%% GetLocaleBaseName: the unicode_language_id, before the first singleton.
-spec base_name(binary()) -> binary().
base_name(Tag) ->
    Subtags = binary:split(Tag, <<"-">>, [global]),
    iolist_to_binary(lists:join(<<"-">>, [hd(Subtags) | lists:takewhile(fun(S) -> byte_size(S) > 1 end, tl(Subtags))])).

-spec language(binary()) -> binary().
language(Tag) -> hd(binary:split(Tag, <<"-">>)).

-spec script(binary()) -> binary() | undefined.
script(Tag) ->
    case binary:split(base_name(Tag), <<"-">>, [global]) of
        [_, S | _] -> case is_script(S) of true -> S; false -> undefined end;
        _ -> undefined
    end.

-spec region(binary()) -> binary() | undefined.
region(Tag) ->
    case binary:split(base_name(Tag), <<"-">>, [global]) of
        [_, R | _] when byte_size(R) =/= 4 -> case is_region(R) of true -> R; false -> undefined end;
        [_, _, R | _] -> case is_region(R) of true -> R; false -> undefined end;
        _ -> undefined
    end.

-spec variants(binary()) -> binary() | undefined.
variants(Tag) ->
    case lists:dropwhile(fun(S) -> not is_variant(S) end, tl(binary:split(base_name(Tag), <<"-">>, [global]))) of
        [] -> undefined;
        Variants -> iolist_to_binary(lists:join(<<"-">>, Variants))
    end.

%% The nonterminals of UTS #35 that ECMA-402 names.
-spec is_language(binary()) -> boolean().
is_language(S) -> (in_range(S, 2, 3) orelse in_range(S, 5, 8)) andalso all(S, fun is_alpha/1).
-spec is_script(binary()) -> boolean().
is_script(S) -> byte_size(S) =:= 4 andalso all(S, fun is_alpha/1).
-spec is_region(binary()) -> boolean().
is_region(S) -> (byte_size(S) =:= 2 andalso all(S, fun is_alpha/1)) orelse (byte_size(S) =:= 3 andalso all(S, fun is_digit/1)).
-spec is_variant(binary()) -> boolean().
is_variant(<<D, _/binary>> = S) when D >= $0, D =< $9, byte_size(S) =:= 4 -> all(S, fun is_alnum/1);
is_variant(S) -> in_range(S, 5, 8) andalso all(S, fun is_alnum/1).
%% The type nonterminal: subtags of 3 to 8 letters and digits.
-spec is_type(term()) -> boolean().
is_type(S) when not is_binary(S) -> false;
is_type(S) -> lists:all(fun(T) -> in_range(T, 3, 8) andalso all(T, fun is_alnum/1) end, binary:split(S, <<"-">>, [global])).

in_range(S, Min, Max) -> byte_size(S) >= Min andalso byte_size(S) =< Max.
all(S, Pred) -> lists:all(Pred, binary_to_list(S)).
is_alpha(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z).
is_digit(C) -> C >= $0 andalso C =< $9.
is_alnum(C) -> is_alpha(C) orelse is_digit(C).

%%% The Unicode locale extension (ECMA-402 section 9.2)

%% The Unicode locale extension sequence of a canonical tag, "-u-...", or
%% none.
-spec unicode_extension(binary()) -> binary() | none.
unicode_extension(Tag) ->
    case split_extension(Tag) of
        {_, <<>>, _} -> none;
        {_, Extension, _} -> Extension
    end.

%% The tag without its Unicode locale extension sequence.
-spec remove_extension(binary()) -> binary().
remove_extension(Tag) ->
    {Before, _, After} = split_extension(Tag),
    <<Before/binary, After/binary>>.

%% {Before, "-u-...", After}: the -u- sequence outside the private use part.
split_extension(Tag) ->
    Subtags = binary:split(Tag, <<"-">>, [global]),
    {Head, Tail} = lists:splitwith(fun(S) -> S =/= <<"u">> andalso S =/= <<"x">> end, Subtags),
    case Tail of
        [<<"u">> | Rest] ->
            {Ext, After} = lists:splitwith(fun(S) -> byte_size(S) > 1 end, Rest),
            {join(Head), iolist_to_binary([<<"-u">> | [[$-, S] || S <- Ext]]), iolist_to_binary([[$-, S] || S <- After])};
        _ ->
            {Tag, <<>>, <<>>}
    end.

join(Subtags) -> iolist_to_binary(lists:join(<<"-">>, Subtags)).

%% UnicodeExtensionComponents: {Attributes, [{Key, Value}]}, the first of
%% each attribute and key.
-spec extension_components(binary()) -> {[binary()], [{binary(), binary()}]}.
extension_components(<<"-u-", Rest/binary>>) ->
    components(binary:split(Rest, <<"-">>, [global]), [], []).

components([], Attributes, Keywords) ->
    {lists:reverse(Attributes), lists:reverse([{K, join(lists:reverse(V))} || {K, V} <- Keywords])};
components([S | Rest], Attributes, []) when byte_size(S) =/= 2 ->
    components(Rest, case lists:member(S, Attributes) of true -> Attributes; false -> [S | Attributes] end, []);
components([S | Rest], Attributes, Keywords) when byte_size(S) =:= 2 ->
    components(Rest, Attributes, [{S, []} | Keywords]);
components([S | Rest], Attributes, [{K, V} | Keywords]) ->
    components(Rest, Attributes, [{K, [S | V]} | Keywords]).

%% InsertUnicodeExtensionAndCanonicalize. A repeated key keeps its first
%% value, as UnicodeExtensionComponents reads it.
-spec insert_extension(binary(), [binary()], [{binary(), binary()}]) -> binary().
insert_extension(Locale, [], []) ->
    canonical(Locale);
insert_extension(Locale, Attributes, Keywords) ->
    Extension = iolist_to_binary([<<"-u">>, [[$-, A] || A <- Attributes],
                                  [case V of <<>> -> [$-, K]; _ -> [$-, K, $-, V] end || {K, V} <- Keywords]]),
    New = case binary:match(Locale, <<"-x-">>) of
        nomatch -> <<Locale/binary, Extension/binary>>;
        {Index, _} -> <<(binary:part(Locale, 0, Index))/binary, Extension/binary, (binary:part(Locale, Index, byte_size(Locale) - Index))/binary>>
    end,
    canonical(New).

canonical(Tag) ->
    {ok, Canonical} = canonicalize_tag(Tag),
    Canonical.

%%% Locale resolution (ECMA-402 section 9.2)

%% LookupMatchingLocaleByPrefix: {Locale, Extension} of the first requested
%% locale whose prefix is available, or undefined.
-spec lookup_matcher([binary()], [binary()]) -> {binary(), binary() | none} | undefined.
lookup_matcher(_Available, []) ->
    undefined;
lookup_matcher(Available, [Requested | Rest]) ->
    Extension = unicode_extension(Requested),
    case prefix_match(Available, remove_extension(Requested)) of
        undefined -> lookup_matcher(Available, Rest);
        Locale -> {Locale, Extension}
    end.

prefix_match(_Available, <<>>) -> undefined;
prefix_match(Available, Prefix) ->
    case lists:member(Prefix, Available) of
        true -> Prefix;
        false -> prefix_match(Available, truncate(Prefix))
    end.

%% The prefix without its last subtag, and without a singleton before it.
truncate(Prefix) ->
    case binary:matches(Prefix, <<"-">>) of
        [] -> <<>>;
        Matches ->
            {Pos, _} = lists:last(Matches),
            Cut = drop_singletons(Prefix, Pos),
            binary:part(Prefix, 0, Cut)
    end.

drop_singletons(Prefix, Pos) when Pos >= 2 ->
    case binary:at(Prefix, Pos - 2) of
        $- -> drop_singletons(Prefix, Pos - 2);
        _ -> Pos
    end;
drop_singletons(_Prefix, Pos) -> Pos.

%% ResolveLocale. Options is a map from each relevant key to its option
%% value or undefined, with localeMatcher, and LocaleData(Locale, Key) gives
%% the values that the locale supports for Key, its default first. The
%% result has locale and a value for each relevant key.
-spec resolve_locale([binary()], [binary()], map(), [binary()], fun((binary(), binary()) -> [term()])) -> map().
resolve_locale(Available, Requested, Options, Relevant, LocaleData) ->
    %% "best fit" is the lookup of RFC 4647, as in V8 without ICU's matcher data.
    {Found, Extension} = case lookup_matcher(Available, Requested) of
        undefined -> {default_locale(), none};
        Match -> Match
    end,
    Keywords = case Extension of
        none -> [];
        _ -> element(2, extension_components(Extension))
    end,
    {Result, Supported} = lists:foldl(
        fun(Key, {Acc, SupportedAcc}) ->
                Data = LocaleData(Found, Key),
                Default = case Data of [D | _] -> D; [] -> null end,
                {Value0, Keyword0} = case lists:keyfind(Key, 1, Keywords) of
                    {_, <<>>} ->
                        case lists:member(<<"true">>, Data) of
                            true -> {<<"true">>, {Key, <<>>}};
                            false -> {Default, none}
                        end;
                    {_, Requested1} ->
                        case lists:member(Requested1, Data) of
                            true -> {Requested1, {Key, Requested1}};
                            false -> {Default, none}
                        end;
                    false -> {Default, none}
                end,
                {Value, Keyword} = case maps:get(Key, Options, undefined) of
                    OptionValue when ?IS_STRING(OptionValue) ->
                        Canonical = case canonicalize_uvalue(Key, OptionValue) of
                            <<>> -> <<"true">>;
                            C -> C
                        end,
                        case Canonical =/= Value0 andalso lists:member(Canonical, Data) of
                            true -> {Canonical, none};
                            false -> {Value0, Keyword0}
                        end;
                    _ -> {Value0, Keyword0}
                end,
                {Acc#{Key => Value}, case Keyword of none -> SupportedAcc; _ -> SupportedAcc ++ [Keyword] end}
        end, {#{}, []}, Relevant),
    Locale = case Supported of
        [] -> Found;
        _ -> insert_extension(Found, [], Supported)
    end,
    Result#{locale => Locale, data_locale => Found}.

%% ResolveOptions: the localeMatcher option, then each resolution option of
%% Descriptors, [{Key, Property, Type, Values}], whose value must match the
%% type nonterminal, then ResolveLocale over the available locales.
-spec resolve_options([binary()], term(), [{binary(), binary(), string | boolean, [term()] | empty}], [binary()],
                      fun((binary(), binary()) -> [term()])) -> map().
resolve_options(Requested, Options, Descriptors, Relevant, LocaleData) ->
    Matcher = get_option(Options, <<"localeMatcher">>, string, [<<"lookup">>, <<"best fit">>], <<"best fit">>),
    Opt = lists:foldl(
        fun({Key, Property, Type, Values}, Acc) ->
                case get_option(Options, Property, Type, Values, undefined) of
                    undefined -> Acc;
                    Value ->
                        Text = case Value of
                            true -> <<"true">>;
                            false -> <<"false">>;
                            _ -> Value
                        end,
                        is_type(Text) orelse range_error(buoy_ref_string:concat([<<"Invalid ">>, Property, <<" : ">>, Text])),
                        Acc#{Key => Text}
                end
        end, #{<<"localeMatcher">> => Matcher}, Descriptors),
    resolve_locale(buoy_ref_intl_data:available_locales(), Requested, Opt, Relevant, LocaleData).

%% An object with a data property for each pair whose value is not
%% undefined, as resolvedOptions makes it.
-spec options_object([{binary(), term()}]) -> term().
options_object(Pairs) ->
    O = buoy_heap:new_object(?OBJECT_PROTO),
    [buoy_heap:define(O, K, #{value => V, writable => true, enumerable => true, configurable => true})
     || {K, V} <- Pairs, V =/= undefined],
    O.

%% FilterLocales: the requested locales that an available locale matches, as
%% an array.
-spec filter_locales([binary()], [binary()], term()) -> term().
filter_locales(Available, Requested, Options) ->
    Opts = coerce_options(Options),
    _Matcher = get_option(Opts, <<"localeMatcher">>, string, [<<"lookup">>, <<"best fit">>], <<"best fit">>),
    buoy_heap:new_array([R || R <- Requested, lookup_matcher(Available, [R]) =/= undefined]).

%%% Options (ECMA-402 section 9.2)

%% CoerceOptionsToObject.
-spec coerce_options(term()) -> term().
coerce_options(undefined) -> buoy_heap:new_object(null);
coerce_options(Options) -> buoy_ref:to_object(Options).

%% GetOptionsObject: undefined as an empty object, another object as it is.
-spec get_options_object(term()) -> term().
get_options_object(undefined) -> buoy_heap:new_object(null);
get_options_object(Options) when ?IS_OBJECT(Options) -> Options;
get_options_object(_Options) -> buoy_ref:type_error(<<"Options must be an object">>).

%% GetOption: Type is string or boolean, Values the allowed values or empty,
%% and Default the value for undefined, or required.
-spec get_option(term(), binary(), string | boolean, [term()] | empty, term()) -> term().
get_option(Options, Key, Type, Values, Default) ->
    case buoy_ref:get(Options, Key) of
        undefined when Default =:= required -> buoy_ref:type_error(buoy_ref_string:concat([Key, <<" is required">>]));
        undefined -> Default;
        Value ->
            Converted = case Type of
                boolean -> buoy_ref:truthy(Value);
                string -> buoy_ref:to_string(Value)
            end,
            case Values =:= empty orelse lists:member(Converted, Values) of
                true -> Converted;
                false -> range_error(buoy_ref_string:concat([<<"Value ">>, buoy_ref:to_string(Value),
                                                             <<" out of range for Intl options property ">>, Key]))
            end
    end.
