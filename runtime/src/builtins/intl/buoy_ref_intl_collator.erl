%% Intl.Collator (ECMA-402 section 10): an object of the class intl_collator
%% whose slots hold the resolved options and the collator of ICU4X that
%% compares (buoy_native:intl_collator_new/3), made on the first compare.
-module(buoy_ref_intl_collator).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, constructor/0]).
-export([collator/2, compare_strings/3, compare_default/2]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).
-import(buoy_ref_intl, [get_option/5]).

-define(PROTO, 'Intl.Collator.prototype').

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Compare = {'$accessor', buoy_ref_realm:builtin(<<"get Intl.Collator.prototype.compare">>, <<"get compare">>, 0,
                                                    fun(This, _) -> bound_compare(This) end), undefined},
    [{?PROTO, record(object, ?OBJECT_PROTO, ?METHODS(<<"Intl.Collator.prototype">>, [{<<"resolvedOptions">>, 0}])
                     ++ [{<<"compare">>, Compare, 4}, {<<"constructor">>, constructor()}, {?SYM(toStringTag), <<"Intl.Collator">>, 4}],
                     none)},
     {{builtin, <<"Intl.Collator">>}, ctor_record(<<"Collator">>, 0, {'$o', ?PROTO},
                                                  ?METHODS(<<"Intl.Collator">>, [{<<"supportedLocalesOf">>, 1}]),
                                                  fun construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [].

-spec constructor() -> term().
constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Intl.Collator">>).

%% Intl.Collator called as a function constructs, with itself as newTarget.
-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(_Name, _This, Args) -> construct(buoy_ref_realm:current(constructor()), Args).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Intl.Collator">>, <<"supportedLocalesOf">>, _This, Args) ->
    buoy_ref_intl:filter_locales(buoy_ref_intl_data:available_locales(),
                                 buoy_ref_intl:canonicalize_locale_list(arg(1, Args)), arg(2, Args));
method(<<"Intl.Collator.prototype">>, <<"resolvedOptions">>, This, _Args) ->
    Slots = slots(This, <<"resolvedOptions">>),
    buoy_ref_intl:options_object([{<<"locale">>, maps:get(locale, Slots)}, {<<"usage">>, maps:get(usage, Slots)},
                                  {<<"sensitivity">>, maps:get(sensitivity, Slots)},
                                  {<<"ignorePunctuation">>, maps:get(ignore_punctuation, Slots)},
                                  {<<"collation">>, maps:get(collation, Slots)}, {<<"numeric">>, maps:get(numeric, Slots)},
                                  {<<"caseFirst">>, maps:get(case_first, Slots)}]).

%%% The constructor

construct(NewTarget, Args) ->
    Proto = buoy_ref_realm:proto_for(NewTarget, ?PROTO),
    Requested = buoy_ref_intl:canonicalize_locale_list(arg(1, Args)),
    Options = buoy_ref_intl:coerce_options(arg(2, Args)),
    Usage = get_option(Options, <<"usage">>, string, [<<"sort">>, <<"search">>], <<"sort">>),
    Resolved = buoy_ref_intl:resolve_options(
                 Requested, Options,
                 [{<<"co">>, <<"collation">>, string, empty}, {<<"kn">>, <<"numeric">>, boolean, empty},
                  {<<"kf">>, <<"caseFirst">>, string, [<<"upper">>, <<"lower">>, <<"false">>]}],
                 [<<"co">>, <<"kf">>, <<"kn">>], fun locale_data/2),
    Collation = case maps:get(<<"co">>, Resolved) of
        null -> <<"default">>;
        C -> C
    end,
    Sensitivity = get_option(Options, <<"sensitivity">>, string, [<<"base">>, <<"accent">>, <<"case">>, <<"variant">>], <<"variant">>),
    %% Thai ignores punctuation by default, as in ICU's root for th.
    DefaultIgnore = buoy_ref_intl:language(maps:get(data_locale, Resolved)) =:= <<"th">>,
    Ignore = get_option(Options, <<"ignorePunctuation">>, boolean, empty, DefaultIgnore),
    buoy_heap:new_exotic(intl_collator, Proto,
                         #{locale => maps:get(locale, Resolved), usage => Usage, collation => Collation,
                           numeric => maps:get(<<"kn">>, Resolved) =:= <<"true">>, case_first => maps:get(<<"kf">>, Resolved),
                           sensitivity => Sensitivity, ignore_punctuation => Ignore, bound => undefined, collator => undefined}).

%% [[SortLocaleData]]: the collation types of the locale after null, the
%% numeric values, and the case orders, the default of each first.
locale_data(Locale, <<"co">>) ->
    [null | [T || T <- buoy_native:intl_collation_types(Locale), T =/= <<"emoji">>, T =/= <<"eor">>]
           ++ [<<"emoji">>, <<"eor">>]];
locale_data(_Locale, <<"kn">>) ->
    [<<"false">>, <<"true">>];
locale_data(Locale, <<"kf">>) ->
    case buoy_ref_intl:language(Locale) of
        Upper when Upper =:= <<"da">>; Upper =:= <<"mt">> -> [<<"upper">>, <<"false">>, <<"lower">>];
        _ -> [<<"false">>, <<"lower">>, <<"upper">>]
    end.

%%% compare

slots(This, Name) ->
    ?IS_OBJECT(This) andalso buoy_heap:class_of(This) =:= intl_collator orelse
        buoy_ref:type_error(buoy_ref_string:concat([<<"Method Intl.Collator.prototype.">>, Name, <<" called on incompatible receiver">>])),
    buoy_heap:slots(This).

%% get Intl.Collator.prototype.compare: one bound function for each collator.
bound_compare(This) ->
    Slots = slots(This, <<"compare">>),
    case maps:get(bound, Slots) of
        undefined ->
            F = buoy_heap:function(fun(_, Args) ->
                                           X = buoy_ref:to_string(arg(1, Args)),
                                           Y = buoy_ref:to_string(arg(2, Args)),
                                           compare_strings(This, X, Y)
                                   end, <<>>, 2, #{}),
            buoy_heap:set_slots(This, (buoy_heap:slots(This))#{bound => F}),
            F;
        F -> F
    end.

%% CompareStrings.
-spec compare_strings(term(), term(), term()) -> -1 | 0 | 1.
compare_strings(Collator, X, Y) ->
    buoy_native:intl_collator_compare(native(Collator), buoy_ref_string:wide(X), buoy_ref_string:wide(Y)).

%% CompareStrings of a collator of the default locale and default options,
%% which localeCompare without locales and options uses: made once per VM.
-spec compare_default(term(), term()) -> -1 | 0 | 1.
compare_default(X, Y) ->
    Native = case persistent_term:get({?MODULE, default}, undefined) of
        undefined ->
            Made = collator(buoy_ref_intl:default_locale(), #{}),
            persistent_term:put({?MODULE, default}, Made),
            Made;
        Made -> Made
    end,
    buoy_native:intl_collator_compare(Native, buoy_ref_string:wide(X), buoy_ref_string:wide(Y)).

native(Collator) ->
    Slots = buoy_heap:slots(Collator),
    case maps:get(collator, Slots) of
        undefined ->
            Native = collator(maps:get(locale, Slots), Slots),
            buoy_heap:set_slots(Collator, Slots#{collator => Native}),
            Native;
        Native -> Native
    end.

%% The ICU4X collator of resolved options: the language identifier of the
%% locale with the keywords co, kf, and kn of the options.
-spec collator(binary(), map()) -> reference().
collator(Locale, Slots) ->
    Keywords = [{<<"co">>, maps:get(collation, Slots, <<"default">>)}, {<<"kf">>, maps:get(case_first, Slots, <<"false">>)},
                {<<"kn">>, case maps:get(numeric, Slots, false) of true -> <<"true">>; false -> <<"false">> end}],
    Tag = iolist_to_binary([buoy_ref_intl:base_name(Locale), <<"-u">>,
                            [[$-, K, $-, V] || {K, V} <- Keywords, V =/= <<"default">>]]),
    case buoy_native:intl_collator_new(Tag, binary_to_atom(maps:get(sensitivity, Slots, <<"variant">>)),
                                       maps:get(ignore_punctuation, Slots, false)) of
        nil -> buoy_native:intl_collator_new(<<"und">>, variant, false);
        Native -> Native
    end.
