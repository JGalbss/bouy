%% Intl.ListFormat (ECMA-402 section 14): an object of the class
%% intl_list_format whose slots hold the resolved locale, type, and style.
%% The list patterns come from CLDR (buoy_intl_cldr), and Spanish and Hebrew
%% choose the conjunction from the next element as ICU's ListFormatter does.
-module(buoy_ref_intl_list_format).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, constructor/0]).
-export([format_list/3]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).
-import(buoy_ref_intl, [get_option/5]).

-define(PROTO, 'Intl.ListFormat.prototype').

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{?PROTO, record(object, ?OBJECT_PROTO,
                     ?METHODS(<<"Intl.ListFormat.prototype">>, [{<<"format">>, 1}, {<<"formatToParts">>, 1}, {<<"resolvedOptions">>, 0}])
                     ++ [{<<"constructor">>, constructor()}, {?SYM(toStringTag), <<"Intl.ListFormat">>, 4}],
                     none)},
     {{builtin, <<"Intl.ListFormat">>}, ctor_record(<<"ListFormat">>, 0, {'$o', ?PROTO},
                                                    ?METHODS(<<"Intl.ListFormat">>, [{<<"supportedLocalesOf">>, 1}]),
                                                    fun construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [].

-spec constructor() -> term().
constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Intl.ListFormat">>).

-spec call_constructor(binary(), term(), list()) -> no_return().
call_constructor(_Name, _This, _Args) -> buoy_ref:type_error(<<"Constructor Intl.ListFormat requires 'new'">>).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Intl.ListFormat">>, <<"supportedLocalesOf">>, _This, Args) ->
    buoy_ref_intl:filter_locales(buoy_ref_intl_data:available_locales(),
                                 buoy_ref_intl:canonicalize_locale_list(arg(1, Args)), arg(2, Args));
method(<<"Intl.ListFormat.prototype">>, <<"resolvedOptions">>, This, _Args) ->
    S = slots(This, <<"resolvedOptions">>),
    buoy_ref_intl:options_object([{<<"locale">>, maps:get(locale, S)}, {<<"type">>, maps:get(type, S)},
                                  {<<"style">>, maps:get(style, S)}]);
method(<<"Intl.ListFormat.prototype">>, <<"format">>, This, Args) ->
    S = slots(This, <<"format">>),
    Parts = format_list(S, strings(arg(1, Args)), element),
    buoy_ref_string:concat([V || {_, V} <- Parts]);
method(<<"Intl.ListFormat.prototype">>, <<"formatToParts">>, This, Args) ->
    S = slots(This, <<"formatToParts">>),
    buoy_heap:new_array([buoy_heap:object(?OBJECT_PROTO, [{<<"type">>, atom_to_binary(T)}, {<<"value">>, V}])
                         || {T, V} <- format_list(S, strings(arg(1, Args)), element)]).

%%% The constructor

construct(NewTarget, Args) ->
    Proto = buoy_ref_realm:proto_for(NewTarget, ?PROTO),
    Requested = buoy_ref_intl:canonicalize_locale_list(arg(1, Args)),
    Options = buoy_ref_intl:get_options_object(arg(2, Args)),
    Resolved = buoy_ref_intl:resolve_options(Requested, Options, [], [], fun(_, _) -> [] end),
    Type = get_option(Options, <<"type">>, string, [<<"conjunction">>, <<"disjunction">>, <<"unit">>], <<"conjunction">>),
    Style = get_option(Options, <<"style">>, string, [<<"long">>, <<"short">>, <<"narrow">>], <<"long">>),
    buoy_heap:new_exotic(intl_list_format, Proto,
                         #{locale => maps:get(locale, Resolved), data_locale => maps:get(data_locale, Resolved),
                           type => Type, style => Style}).

slots(This, Name) ->
    ?IS_OBJECT(This) andalso buoy_heap:class_of(This) =:= intl_list_format orelse
        buoy_ref:type_error(buoy_ref_string:concat([<<"Method Intl.ListFormat.prototype.">>, Name,
                                                    <<" called on incompatible receiver">>])),
    buoy_heap:slots(This).

%% StringListFromIterable.
strings(undefined) -> [];
strings(Iterable) -> collect(buoy_ref_iterator:iterate(Iterable), []).

collect(State, Acc) ->
    case buoy_ref_iterator:step(State) of
        done -> lists:reverse(Acc);
        {value, V, Next} when ?IS_STRING(V) -> collect(Next, [V | Acc]);
        {value, _, Next} ->
            buoy_ref_iterator:close_quietly(Next),
            buoy_ref:type_error(<<"Iterable yielded a value that is not a string">>)
    end.

%%% CreatePartsFromList

%% The parts of a list of strings, as [{Type, String}] with Type the given
%% element type or literal, in the list patterns of the object's slots.
-spec format_list(map(), [term()], atom()) -> [{atom(), term()}].
format_list(_S, [], _Element) -> [];
format_list(_S, [One], Element) -> [{Element, One}];
format_list(S, Items, Element) ->
    Locale = buoy_ref_intl:base_name(maps:get(data_locale, S)),
    Type = case maps:get(type, S) of
        <<"conjunction">> -> standard;
        <<"disjunction">> -> 'or';
        <<"unit">> -> unit
    end,
    Patterns = buoy_intl_cldr:get(Locale, {list, Type, binary_to_atom(maps:get(style, S))}, #{}),
    Language = buoy_ref_intl:language(Locale),
    Pattern = fun(Key, Next) ->
                      Text = unicode:characters_to_list(maps:get(Key, Patterns, <<"{0}, {1}">>)),
                      case Key of
                          two -> contextual(Language, Text, Next);
                          'end' -> contextual(Language, Text, Next);
                          _ -> Text
                      end
              end,
    case Items of
        [A, B] -> place(Pattern(two, B), [{Element, A}], [{Element, B}]);
        [A, B | Rest] ->
            {Middle, [Last]} = lists:split(length(Rest) - 1, Rest),
            Start = place(Pattern(start, B), [{Element, A}], [{Element, B}]),
            Body = lists:foldl(fun(Item, Acc) -> place(Pattern(middle, Item), Acc, [{Element, Item}]) end, Start, Middle),
            place(Pattern('end', Last), Body, [{Element, Last}])
    end.

%% The parts of a pattern with {0} and {1} in place.
place(Pattern, First, Second) ->
    {Before, Rest} = split_at(Pattern, "{0}"),
    {Middle, After} = split_at(Rest, "{1}"),
    literal(Before) ++ First ++ literal(Middle) ++ Second ++ literal(After).

split_at(Text, Marker) ->
    case string:split(Text, Marker) of
        [Before, After] -> {Before, After};
        [Only] -> {Only, ""}
    end.

literal("") -> [];
literal(Text) -> [{literal, buoy_ref_string:from_code_points(Text)}].

%% ICU's ContextualHandler: Spanish writes "e" for "y" before an i sound and
%% "u" for "o" before an o sound, and Hebrew a hyphen after the vav before a
%% word that is not Hebrew.
contextual(<<"es">>, "{0} y {1}", Next) ->
    case starts_with_i_sound(units(Next)) of
        true -> "{0} e {1}";
        false -> "{0} y {1}"
    end;
contextual(<<"es">>, "{0} o {1}", Next) ->
    case starts_with_o_sound(units(Next)) of
        true -> "{0} u {1}";
        false -> "{0} o {1}"
    end;
contextual(Language, [${, $0, $}, $\s, 16#05D5, ${, $1, $}], Next) when Language =:= <<"he">>; Language =:= <<"iw">> ->
    case is_hebrew(units(Next)) of
        true -> [${, $0, $}, $\s, 16#05D5, ${, $1, $}];
        false -> [${, $0, $}, $\s, 16#05D5, $-, ${, $1, $}]
    end;
contextual(_Language, Pattern, _Next) -> Pattern.

units(S) -> buoy_ref_string:units(S).

starts_with_i_sound([H, I]) when (H =:= $h orelse H =:= $H), (I =:= $i orelse I =:= $I) -> true;
starts_with_i_sound([H, I, C | _]) when (H =:= $h orelse H =:= $H), (I =:= $i orelse I =:= $I) ->
    not lists:member(C, "aAeE");
starts_with_i_sound([I | _]) -> I =:= $i orelse I =:= $I;
starts_with_i_sound([]) -> false.

starts_with_o_sound([C | _]) when C =:= $o; C =:= $O; C =:= $8 -> true;
starts_with_o_sound([H, O | _]) when (H =:= $h orelse H =:= $H), (O =:= $o orelse O =:= $O) -> true;
starts_with_o_sound([$1, $1]) -> true;
starts_with_o_sound([$1, $1, $\s | _]) -> true;
starts_with_o_sound(_) -> false.

%% Whether the first code point is of the Hebrew script.
is_hebrew([]) -> true;
is_hebrew([C | _]) ->
    (C >= 16#0591 andalso C =< 16#05C7) orelse (C >= 16#05D0 andalso C =< 16#05EA) orelse
        (C >= 16#05EF andalso C =< 16#05F4) orelse (C >= 16#FB1D andalso C =< 16#FB4F).
