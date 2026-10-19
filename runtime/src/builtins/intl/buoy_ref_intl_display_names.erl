%% Intl.DisplayNames (ECMA-402 section 12): an object of the class
%% intl_display_names whose slots hold the resolved options. The names come
%% from ICU's data (buoy_intl_cldr), and a language tag is named the way ICU's
%% LocaleDisplayNames names it for V8: a dialect name when CLDR has one, else
%% the language with its script, region, and variants in the locale's
%% display pattern.
-module(buoy_ref_intl_display_names).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, constructor/0]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).
-import(buoy_ref_intl, [get_option/5, range_error/1]).

-define(PROTO, 'Intl.DisplayNames.prototype').

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{?PROTO, record(object, ?OBJECT_PROTO,
                     ?METHODS(<<"Intl.DisplayNames.prototype">>, [{<<"of">>, 1}, {<<"resolvedOptions">>, 0}])
                     ++ [{<<"constructor">>, constructor()}, {?SYM(toStringTag), <<"Intl.DisplayNames">>, 4}],
                     none)},
     {{builtin, <<"Intl.DisplayNames">>}, ctor_record(<<"DisplayNames">>, 2, {'$o', ?PROTO},
                                                      ?METHODS(<<"Intl.DisplayNames">>, [{<<"supportedLocalesOf">>, 1}]),
                                                      fun construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [].

-spec constructor() -> term().
constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Intl.DisplayNames">>).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(_Name, _This, _Args) -> buoy_ref:type_error(<<"Constructor Intl.DisplayNames requires 'new'">>).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Intl.DisplayNames">>, <<"supportedLocalesOf">>, _This, Args) ->
    buoy_ref_intl:filter_locales(buoy_ref_intl_data:available_locales(),
                                 buoy_ref_intl:canonicalize_locale_list(arg(1, Args)), arg(2, Args));
method(<<"Intl.DisplayNames.prototype">>, <<"resolvedOptions">>, This, _Args) ->
    S = slots(This, <<"resolvedOptions">>),
    buoy_ref_intl:options_object([{<<"locale">>, maps:get(locale, S)}, {<<"style">>, maps:get(style, S)},
                                  {<<"type">>, maps:get(type, S)}, {<<"fallback">>, maps:get(fallback, S)},
                                  {<<"languageDisplay">>, maps:get(language_display, S)}]);
method(<<"Intl.DisplayNames.prototype">>, <<"of">>, This, Args) ->
    S = slots(This, <<"of">>),
    Code = canonical_code(maps:get(type, S), buoy_ref:to_string(arg(1, Args))),
    case name(S, Code) of
        undefined -> undefined;
        Name -> buoy_ref_string:from_utf8(iolist_to_binary(Name))
    end.

%%% The constructor

construct(NewTarget, Args) ->
    Proto = buoy_ref_realm:proto_for(NewTarget, ?PROTO),
    Requested = buoy_ref_intl:canonicalize_locale_list(arg(1, Args)),
    Options = case arg(2, Args) of
        undefined -> buoy_ref:type_error(<<"Intl.DisplayNames requires an options object">>);
        O -> buoy_ref_intl:get_options_object(O)
    end,
    Resolved = buoy_ref_intl:resolve_options(Requested, Options, [], [], fun(_, _) -> [] end),
    Style = get_option(Options, <<"style">>, string, [<<"narrow">>, <<"short">>, <<"long">>], <<"long">>),
    Type = get_option(Options, <<"type">>, string,
                      [<<"language">>, <<"region">>, <<"script">>, <<"currency">>, <<"calendar">>, <<"dateTimeField">>], required),
    Fallback = get_option(Options, <<"fallback">>, string, [<<"code">>, <<"none">>], <<"code">>),
    LanguageDisplay = get_option(Options, <<"languageDisplay">>, string, [<<"dialect">>, <<"standard">>], <<"dialect">>),
    buoy_heap:new_exotic(intl_display_names, Proto,
                         #{locale => maps:get(locale, Resolved), data_locale => maps:get(data_locale, Resolved),
                           style => Style, type => Type, fallback => Fallback,
                           language_display => case Type of <<"language">> -> LanguageDisplay; _ -> undefined end}).

slots(This, Name) ->
    ?IS_OBJECT(This) andalso buoy_heap:class_of(This) =:= intl_display_names orelse
        buoy_ref:type_error(buoy_ref_string:concat([<<"Method Intl.DisplayNames.prototype.">>, Name,
                                                    <<" called on incompatible receiver">>])),
    buoy_heap:slots(This).

%%% CanonicalCodeForDisplayNames

%% Every well-formed code is ASCII, which the engine holds as a binary.
canonical_code(_Type, Code) when not is_binary(Code) -> range_error(<<"invalid_argument">>);
canonical_code(<<"language">>, Code) ->
    is_language_id(Code) orelse range_error(<<"invalid_argument">>),
    case buoy_ref_intl:canonicalize_tag(Code) of
        {ok, Canonical} -> Canonical;
        error -> range_error(<<"invalid_argument">>)
    end;
canonical_code(<<"region">>, Code) ->
    buoy_ref_intl:is_region(Code) orelse range_error(<<"invalid_argument">>),
    string:uppercase(Code);
canonical_code(<<"script">>, Code) ->
    buoy_ref_intl:is_script(Code) orelse range_error(<<"invalid_argument">>),
    <<First:1/binary, Rest/binary>> = Code,
    <<(string:uppercase(First))/binary, (string:lowercase(Rest))/binary>>;
canonical_code(<<"calendar">>, Code) ->
    (buoy_ref_intl:is_type(Code) andalso binary:match(Code, <<"_">>) =:= nomatch) orelse range_error(<<"invalid_argument">>),
    string:lowercase(Code);
canonical_code(<<"dateTimeField">>, Code) ->
    lists:member(Code, [<<"era">>, <<"year">>, <<"quarter">>, <<"month">>, <<"weekOfYear">>, <<"weekday">>, <<"day">>,
                        <<"dayPeriod">>, <<"hour">>, <<"minute">>, <<"second">>, <<"timeZoneName">>])
        orelse range_error(<<"invalid_argument">>),
    Code;
canonical_code(<<"currency">>, Code) ->
    (is_binary(Code) andalso byte_size(Code) =:= 3 andalso
     lists:all(fun(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) end, binary_to_list(Code)))
        orelse range_error(<<"invalid_argument">>),
    string:uppercase(Code).

%% A unicode_language_id without extensions or private use: a language, an
%% optional script and region, and variants.
is_language_id(Code) ->
    case binary:split(Code, [<<"-">>, <<"_">>], [global]) of
        [Language | Rest] ->
            buoy_ref_intl:is_language(Language) andalso
                not lists:any(fun(S) -> byte_size(S) =:= 1 end, Rest) andalso
                binary:match(Code, <<"_">>) =:= nomatch;
        _ -> false
    end.

%%% Names

name(S, Code) ->
    Locale = buoy_ref_intl:base_name(maps:get(data_locale, S)),
    Short = maps:get(style, S) =/= <<"long">>,
    Substitute = maps:get(fallback, S) =:= <<"code">>,
    case maps:get(type, S) of
        <<"language">> -> language_name(Locale, Code, Short, maps:get(language_display, S) =:= <<"dialect">>, Substitute);
        <<"region">> -> or_code(lookup(Locale, region, Code, Short), Code, Substitute);
        <<"script">> -> or_code(lookup(Locale, script, Code, Short), Code, Substitute);
        <<"currency">> ->
            case buoy_intl_cldr:get(Locale, [<<"Currencies">>, Code]) of
                [_, Name | _] -> Name;
                _ -> or_code(undefined, Code, Substitute)
            end;
        <<"calendar">> ->
            Type = case Code of
                <<"gregory">> -> <<"gregorian">>;
                <<"ethioaa">> -> <<"ethiopic-amete-alem">>;
                _ -> Code
            end,
            or_code(lookup(Locale, calendar_name, Type, Short), Type, Substitute);
        <<"dateTimeField">> -> or_code(field_name(Locale, Code, maps:get(style, S)), Code, Substitute)
    end.

or_code(undefined, Code, true) -> Code;
or_code(Name, _Code, _Substitute) -> Name.

%% The name of Kind for Code in ICU's tables, the short one first for a
%% short style.
lookup(Locale, Kind, Code, Short) ->
    Path = case Kind of
        language -> [<<"Languages">>, binary:replace(Code, <<"-">>, <<"_">>, [global])];
        region -> [<<"Countries">>, Code];
        script -> [<<"Scripts">>, Code];
        calendar_name -> [<<"Types">>, <<"calendar">>, Code]
    end,
    Plain = buoy_intl_cldr:get(Locale, Path),
    case Short of
        true ->
            [Table | Rest] = Path,
            buoy_intl_cldr:get(Locale, [<<Table/binary, "%short">> | Rest], Plain);
        false -> Plain
    end.

%% The display name of a date field in a width, falling back to the wider.
field_name(Locale, Code, Style) ->
    Field = case Code of
        <<"weekOfYear">> -> <<"week">>;
        <<"dayPeriod">> -> <<"dayperiod">>;
        <<"timeZoneName">> -> <<"zone">>;
        _ -> Code
    end,
    Widths = case Style of
        <<"narrow">> -> [<<"-narrow">>, <<"-short">>, <<>>];
        <<"short">> -> [<<"-short">>, <<>>];
        <<"long">> -> [<<>>]
    end,
    first([buoy_intl_cldr:get(Locale, [<<"fields">>, <<Field/binary, W/binary>>, <<"dn">>]) || W <- Widths]).

first([]) -> undefined;
first([undefined | Rest]) -> first(Rest);
first([Name | _]) -> Name.

%% LocaleDisplayNamesImpl::localeDisplayName.
language_name(Locale, Code, Short, Dialect, Substitute) ->
    {Language, Script, Region, Variants} = subtags(Code),
    %% ICU appends each candidate to the one before without clearing it, so
    %% with a script and a region only the full candidate can match.
    Dialects = case {Dialect, Script, Region} of
        {false, _, _} -> [];
        {true, none, none} -> [];
        {true, none, _} -> [{[Language, $-, Region], Script, none}];
        {true, _, none} -> [{[Language, $-, Script], none, Region}];
        {true, _, _} -> [{[Language, $-, Script, $-, Region], none, none}]
    end,
    Found = first([case lookup(Locale, language, iolist_to_binary(Id), Short) of
                       undefined -> undefined;
                       Name -> {Name, S, R}
                   end || {Id, S, R} <- Dialects]),
    {Base, LeftScript, LeftRegion} = case Found of
        undefined -> {or_code(lookup(Locale, language, Language, Short), Language, Substitute), Script, Region};
        Dialected -> Dialected
    end,
    Parts = [case Kind of
                 script -> or_code(lookup(Locale, script, Value, Short), Value, Substitute);
                 region -> or_code(lookup(Locale, region, Value, Short), Value, Substitute);
                 variant -> or_code(buoy_intl_cldr:get(Locale, [<<"Variants">>, string:uppercase(Value)]), Value, Substitute)
             end || {Kind, Value} <- [{script, LeftScript}, {region, LeftRegion}] ++ [{variant, V} || V <- Variants],
                    Value =/= none],
    case Base =:= undefined orelse lists:member(undefined, Parts) of
        true -> undefined;
        false when Parts =:= [] -> Base;
        false ->
            Pattern = buoy_intl_cldr:get(Locale, [<<"localeDisplayPattern">>, <<"pattern">>], <<"{0} ({1})">>),
            Separator = buoy_intl_cldr:get(Locale, [<<"localeDisplayPattern">>, <<"separator">>], <<"{0}, {1}">>),
            Remainder = lists:foldl(fun(Part, Acc) -> fill(Separator, Acc, Part) end, hd(Parts), tl(Parts)),
            fill(Pattern, Base, brackets(Pattern, Remainder))
    end.

%% The parentheses of the remainder as brackets, the fullwidth ones when the
%% pattern has fullwidth parentheses.
brackets(Pattern, Text) ->
    Chars = unicode:characters_to_list(Text),
    {Open, Close, NewOpen, NewClose} = case lists:member(16#FF08, unicode:characters_to_list(Pattern)) of
        true -> {16#FF08, 16#FF09, 16#FF3B, 16#FF3D};
        false -> {$(, $), $[, $]}
    end,
    unicode:characters_to_binary([case C of Open -> NewOpen; Close -> NewClose; _ -> C end || C <- Chars]).

fill(Pattern, Zero, One) ->
    iolist_to_binary(string:replace(string:replace(Pattern, <<"{0}">>, Zero), <<"{1}">>, One)).

%% {Language, Script, Region, Variants} of a canonical language id.
subtags(Code) ->
    [Language | Rest] = binary:split(Code, <<"-">>, [global]),
    {Script, Rest1} = case Rest of
        [S | R1] when byte_size(S) =:= 4 -> {S, R1};
        _ -> {none, Rest}
    end,
    {Region, Variants} = case Rest1 of
        [G | R2] when byte_size(G) =:= 2; byte_size(G) =:= 3 -> {G, R2};
        _ -> {none, Rest1}
    end,
    {Language, Script, Region, Variants}.
