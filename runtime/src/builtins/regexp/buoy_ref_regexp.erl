%% The RegExp family (ECMA-262 22.2): the RegExp constructor, RegExp.prototype
%% and its Symbol.match, matchAll, replace, search, and split protocols, the
%% RegExp String Iterator, regular expression literals, and the methods of
%% String.prototype that take a pattern.
%%
%% A RegExp is an object of the class regexp. Its slots hold the internal slots
%% [[OriginalSource]] and [[OriginalFlags]], and the compiled matcher of
%% buoy_regexp_match with the names of its groups. buoy_regexp_syntax parses
%% the pattern. Each realm keeps the matchers it compiled by source and flags,
%% so a literal in a loop compiles once.
-module(buoy_ref_regexp).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).
-export([literal/2, string_method/3, is_regexp/1, display/1]).

-import(buoy_ref_realm, [arg/2]).
-import(buoy_ref, [type_error/1]).

-define(PROTO, {'$o', 'RegExp.prototype'}).
-define(IS_DIGIT(C), (C >= $0 andalso C =< $9)).
-define(ITERATOR, {'$o', 'RegExpStringIterator.prototype'}).
-define(CACHE, '$buoy_regexp_cache').
%% The legacy static properties of RegExp: {Input, LastMatch}, where LastMatch
%% is {String, Start, End, Captures} or none.
-define(LEGACY, '$buoy_regexp_legacy').
-define(LEGACY_NAMES, [<<"$1">>, <<"$2">>, <<"$3">>, <<"$4">>, <<"$5">>, <<"$6">>, <<"$7">>, <<"$8">>, <<"$9">>,
                       <<"input">>, <<"$_">>, <<"lastMatch">>, <<"$&">>, <<"lastParen">>, <<"$+">>,
                       <<"leftContext">>, <<"$`">>, <<"rightContext">>, <<"$'">>]).
-define(CACHE_SIZE, 256).
-define(MAX_LENGTH, 9007199254740991).
%% The attribute bits of a builtin property: writable 1, enumerable 2, configurable 4.
-define(METHOD, 5).
-define(CONFIGURABLE, 4).

-define(GETTERS, [<<"dotAll">>, <<"flags">>, <<"global">>, <<"hasIndices">>, <<"ignoreCase">>, <<"multiline">>,
                  <<"source">>, <<"sticky">>, <<"unicode">>, <<"unicodeSets">>]).
-define(SYMBOL_METHODS, [{match, 1}, {matchAll, 1}, {replace, 2}, {search, 1}, {split, 2}]).
-define(PROTO_METHODS, [{<<"exec">>, 1}, {<<"test">>, 1}, {<<"toString">>, 0}, {<<"compile">>, 2}]).
-define(STRING_METHODS, [{<<"match">>, 1}, {<<"matchAll">>, 1}, {<<"replace">>, 2}, {<<"replaceAll">>, 2}, {<<"search">>, 1},
                         {<<"split">>, 2}]).

%%% The family

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Methods = [method_entry(<<"RegExp.prototype">>, N) || {N, _} <- ?PROTO_METHODS],
    Symbols = [symbol_entry(S) || {S, _} <- ?SYMBOL_METHODS],
    Getters = [{G, getter(<<"RegExp.prototype">>, G), ?CONFIGURABLE} || G <- ?GETTERS],
    Escape = method_entry(<<"RegExp">>, <<"escape">>),
    Species = {?SYM(species), getter(<<"RegExp">>, <<"[Symbol.species]">>), ?CONFIGURABLE},
    Legacy = [{N, legacy_accessor(N), ?CONFIGURABLE} || N <- ?LEGACY_NAMES],
    Next = method_entry(<<"RegExpStringIterator.prototype">>, <<"next">>),
    Records = [{'RegExp.prototype', object_record(?OBJECT_PROTO, Methods ++ Symbols ++ Getters ++ [{<<"constructor">>, constructor(), ?METHOD}])},
               {'RegExpStringIterator.prototype', object_record(?ITERATOR_PROTO, [Next, {?SYM(toStringTag), <<"RegExp String Iterator">>, ?CONFIGURABLE}])},
               {{builtin, <<"RegExp">>}, function_record(<<"RegExp">>, 2, [{<<"prototype">>, ?PROTO, 0}, Escape, Species | Legacy],
                                                         #{construct => fun construct/2, kind => builtin})}],
    Records ++ [{{builtin, Full}, function_record(Name, Length, [], #{})} || {Full, Name, Length} <- function_names()].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"RegExp">>, constructor()}].

constructor() -> buoy_ref_realm:constructor(?MODULE, <<"RegExp">>).

%% The full name, the name property, and the length of each builtin function,
%% with the methods of String.prototype that this module implements.
function_names() ->
    [{<<"RegExp.prototype.", N/binary>>, N, L} || {N, L} <- ?PROTO_METHODS]
    ++ [{symbol_full_name(S), symbol_name(S), L} || {S, L} <- ?SYMBOL_METHODS]
    ++ [{<<"RegExp.prototype.get ", G/binary>>, <<"get ", G/binary>>, 0} || G <- ?GETTERS]
    ++ [{<<"RegExp.escape">>, <<"escape">>, 1}, {<<"RegExp.get [Symbol.species]">>, <<"get [Symbol.species]">>, 0},
        {<<"RegExpStringIterator.prototype.next">>, <<"next">>, 0}]
    ++ [{<<"RegExp.get ", N/binary>>, <<"get ", N/binary>>, 0} || N <- ?LEGACY_NAMES]
    ++ [{<<"RegExp.set ", N/binary>>, <<"set ", N/binary>>, 1} || N <- [<<"input">>, <<"$_">>]]
    ++ [{<<"String.prototype.", N/binary>>, N, L} || {N, L} <- ?STRING_METHODS].

method_entry(Owner, Name) ->
    {Name, buoy_ref_realm:builtin(<<Owner/binary, ".", Name/binary>>, fun(This, Args) -> ?MODULE:method(Owner, Name, This, Args) end), ?METHOD}.

symbol_entry(Symbol) ->
    Name = symbol_name(Symbol),
    {?SYM(Symbol), buoy_ref_realm:builtin(symbol_full_name(Symbol), fun(This, Args) -> ?MODULE:method(<<"RegExp.prototype">>, Name, This, Args) end), ?METHOD}.

symbol_name(Symbol) -> <<"[Symbol.", (atom_to_binary(Symbol))/binary, "]">>.
symbol_full_name(Symbol) -> <<"RegExp.prototype", (symbol_name(Symbol))/binary>>.

%% A legacy static accessor of RegExp: input and $_ also have a setter.
legacy_accessor(Name) ->
    {'$accessor', Getter, _} = getter(<<"RegExp">>, Name),
    Setter = case Name of
        N when N =:= <<"input">>; N =:= <<"$_">> ->
            buoy_ref_realm:builtin(<<"RegExp.set ", Name/binary>>, fun(This, Args) -> ?MODULE:method(<<"RegExp">>, <<"set input">>, This, Args) end);
        _ -> undefined
    end,
    {'$accessor', Getter, Setter}.

getter(Owner, Name) ->
    Getter = buoy_ref_realm:builtin(<<Owner/binary, ".get ", Name/binary>>, fun(This, _) -> ?MODULE:method(Owner, Name, This, []) end),
    {'$accessor', Getter, undefined}.

%% A heap record from {Key, Value, Attributes}.
object_record(Proto, Entries) -> record(object, Proto, Entries, none).

function_record(Name, Length, Entries, Slots) ->
    record(function, ?FUNCTION_PROTO, [{<<"length">>, Length, ?CONFIGURABLE}, {<<"name">>, Name, ?CONFIGURABLE} | Entries], Slots).

record(Class, Proto, Entries, Slots) ->
    Props = maps:from_list([{K, V} || {K, V, _} <- Entries]),
    Keys = lists:reverse([K || {K, _, _} <- Entries]),
    Attrs = maps:from_list([{K, A} || {K, _, A} <- Entries, A =/= 7]),
    {Class, Proto, Props, Keys, Attrs, Slots}.

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"RegExp">>, _This, Args) -> regexp(undefined, arg(1, Args), arg(2, Args)).

construct(NewTarget, Args) -> regexp(NewTarget, arg(1, Args), arg(2, Args)).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"RegExp.prototype">>, Name, This, Args) -> proto(Name, This, Args);
method(<<"RegExp">>, <<"escape">>, _This, Args) -> escape(arg(1, Args));
method(<<"RegExp">>, <<"[Symbol.species]">>, This, _Args) -> This;
method(<<"RegExp">>, <<"set input">>, This, Args) -> legacy_set_input(This, arg(1, Args));
method(<<"RegExp">>, Name, This, _Args) -> legacy_get(Name, This);
method(<<"RegExpStringIterator.prototype">>, <<"next">>, This, _Args) -> iterator_next(This).

%%% Creation

%% 22.2.4.1 RegExp ( pattern, flags ). NewTarget is undefined for a call.
regexp(NewTarget, Pattern, Flags) ->
    IsRegExp = is_regexp(Pattern),
    Unchanged = NewTarget =:= undefined andalso IsRegExp andalso Flags =:= undefined andalso
        buoy_ref:get(Pattern, <<"constructor">>) =:= constructor(),
    case Unchanged of
        true -> Pattern;
        false ->
            Target = case NewTarget of
                undefined -> constructor();
                _ -> NewTarget
            end,
            {Source, Flags1} = case is_regexp_object(Pattern) of
                true ->
                    #{source := S, flags := F} = buoy_heap:slots(Pattern),
                    {S, default(Flags, F)};
                false when IsRegExp ->
                    S = buoy_ref:get(Pattern, <<"source">>),
                    {S, default(Flags, fun() -> buoy_ref:get(Pattern, <<"flags">>) end)};
                false ->
                    {Pattern, Flags}
            end,
            initialize(alloc(Target), Source, Flags1)
    end.

default(undefined, F) when is_function(F) -> F();
default(undefined, V) -> V;
default(V, _) -> V.

%% RegExpCreate.
create(Pattern, Flags) -> initialize(alloc(constructor()), Pattern, Flags).

%% RegExpAlloc.
alloc(NewTarget) ->
    Proto = case NewTarget of
        {'$f', {builtin, <<"RegExp">>}, _} -> ?PROTO;
        _ -> buoy_ref_realm:proto_for(NewTarget, 'RegExp.prototype')
    end,
    %% [[LegacyFeaturesEnabled]]: RegExp itself, not a subclass, made the object.
    Legacy = case NewTarget of
        {'$f', {builtin, <<"RegExp">>}, _} -> true;
        _ -> false
    end,
    O = buoy_heap:new_exotic(regexp, Proto, #{legacy => Legacy}),
    buoy_heap:define(O, <<"lastIndex">>, #{value => undefined, writable => true, enumerable => false, configurable => false}).

%% RegExpInitialize.
initialize(O, Pattern, Flags) ->
    Source = case Pattern of
        undefined -> <<>>;
        _ -> buoy_ref:to_string(Pattern)
    end,
    FlagText = case Flags of
        undefined -> <<>>;
        _ -> buoy_ref:to_string(Flags)
    end,
    {_Program, Names} = program(Source, FlagText),
    buoy_heap:set_slots(O, (buoy_heap:slots(O))#{source => Source, flags => FlagText, names => Names}),
    buoy_heap:set(O, <<"lastIndex">>, 0),
    O.

%% A regular expression literal: a new object each evaluation, with the
%% matcher compiled once per realm. The source and flags are strings, so this
%% is RegExpCreate without its steps that could run user code.
-spec literal(buoy_ref_string:js_string(), binary()) -> term().
literal(Source, Flags) ->
    {_Program, Names} = program(Source, Flags),
    O = buoy_heap:new_exotic(regexp, buoy_heap:intrinsic('RegExp.prototype'), #{legacy => true, source => Source, flags => Flags, names => Names}),
    buoy_heap:define(O, <<"lastIndex">>, #{value => 0, writable => true, enumerable => false, configurable => false}).

%% The matcher of an initialized RegExp. The object keeps its source and flags,
%% not the matcher: the collector scans the slots of each live object, and many
%% objects share one matcher.
matcher(#{source := Source, flags := Flags}) -> element(1, program(Source, Flags)).

%% The compiled matcher and the group names of a source and its flags.
program(Source, Flags) ->
    Cache = case erlang:get(?CACHE) of
        undefined -> #{};
        C -> C
    end,
    case Cache of
        #{{Source, Flags} := Compiled} -> Compiled;
        _ ->
            Compiled = compile(Source, Flags),
            Cache1 = case map_size(Cache) >= ?CACHE_SIZE of
                true -> #{};
                false -> Cache
            end,
            erlang:put(?CACHE, Cache1#{{Source, Flags} => Compiled}),
            Compiled
    end.

compile(Source, Flags) ->
    Set = flag_set(Flags),
    U = maps:get(u, Set),
    V = maps:get(v, Set),
    Chars = case U orelse V of
        true -> buoy_ref_string:code_points(Source);
        false -> buoy_ref_string:units(Source)
    end,
    case buoy_regexp_syntax:parse(Chars, U, V) of
        {ok, Tree, Groups, Names} ->
            {buoy_regexp_match:compile(Tree, Groups, Set), [{I, buoy_ref_string:from_code_points(N)} || {I, N} <- Names]};
        {error, Message} ->
            buoy_heap:throw_error('SyntaxError', buoy_ref_string:concat([<<"Invalid regular expression: /">>, Source, <<"/">>, Flags, <<": ">>, Message]))
    end.

flag_set(Flags) ->
    Units = buoy_ref_string:units(Flags),
    Valid = lists:all(fun(C) -> lists:member(C, "dgimsuvy") end, Units) andalso length(lists:usort(Units)) =:= length(Units)
        andalso not (lists:member($u, Units) andalso lists:member($v, Units)),
    Valid orelse buoy_heap:throw_error('SyntaxError', buoy_ref_string:concat([<<"Invalid flags supplied to RegExp constructor '">>, Flags, <<"'">>])),
    maps:from_list([{list_to_atom([F]), lists:member(F, Units)} || F <- "dgimsuvy"]).

%%% Predicates

%% IsRegExp.
-spec is_regexp(term()) -> boolean().
is_regexp(V) when ?IS_OBJECT(V) ->
    case buoy_ref:get(V, ?SYM(match)) of
        undefined -> is_regexp_object(V);
        M -> buoy_ref:truthy(M)
    end;
is_regexp(_) -> false.

%% Whether V has a [[RegExpMatcher]] slot.
is_regexp_object({'$o', _} = V) ->
    buoy_heap:class_of(V) =:= regexp andalso is_map_key(source, buoy_heap:slots(V));
is_regexp_object(_) -> false.

this_regexp(V, Name) ->
    is_regexp_object(V) orelse
        type_error(buoy_ref_string:concat([<<"RegExp.prototype.">>, Name, <<" requires that 'this' be a RegExp object">>])),
    V.

this_object(V, _Name) when ?IS_OBJECT(V) -> V;
this_object(_V, Name) ->
    type_error(buoy_ref_string:concat([<<"RegExp.prototype.">>, Name, <<" requires that 'this' be an Object">>])).

%% The text that console.log prints: /source/flags.
-spec display(term()) -> binary().
display(O) ->
    case buoy_heap:slots(O) of
        #{source := Source, flags := Flags} -> buoy_ref_string:to_utf8(buoy_ref_string:concat([<<"/">>, escape_pattern(Source), <<"/">>, Flags]));
        _ -> <<"/(?:)/">>
    end.

%%% RegExp.prototype

proto(<<"exec">>, This, Args) ->
    R = this_regexp(This, <<"exec">>),
    builtin_exec(R, buoy_ref:to_string(arg(1, Args)));
proto(<<"test">>, This, Args) ->
    R = this_object(This, <<"test">>),
    regexp_exec(R, buoy_ref:to_string(arg(1, Args))) =/= null;
proto(<<"toString">>, This, _Args) ->
    R = this_object(This, <<"toString">>),
    Source = buoy_ref:to_string(buoy_ref:get(R, <<"source">>)),
    Flags = buoy_ref:to_string(buoy_ref:get(R, <<"flags">>)),
    buoy_ref_string:concat([<<"/">>, Source, <<"/">>, Flags]);
proto(<<"compile">>, This, Args) ->
    R = this_regexp(This, <<"compile">>),
    maps:get(legacy, buoy_heap:slots(R)) orelse type_error(<<"RegExp.prototype.compile requires a RegExp that RegExp itself made">>),
    {Pattern, Flags} = case is_regexp_object(arg(1, Args)) of
        true ->
            arg(2, Args) =:= undefined orelse type_error(<<"Cannot supply flags when constructing one RegExp from another">>),
            #{source := S, flags := F} = buoy_heap:slots(arg(1, Args)),
            {S, F};
        false -> {arg(1, Args), arg(2, Args)}
    end,
    initialize(R, Pattern, Flags);
proto(<<"flags">>, This, _Args) ->
    R = this_object(This, <<"flags">>),
    Flags = [F || {F, Name} <- [{$d, <<"hasIndices">>}, {$g, <<"global">>}, {$i, <<"ignoreCase">>}, {$m, <<"multiline">>},
                                {$s, <<"dotAll">>}, {$u, <<"unicode">>}, {$v, <<"unicodeSets">>}, {$y, <<"sticky">>}],
                  buoy_ref:truthy(buoy_ref:get(R, Name))],
    list_to_binary(Flags);
proto(<<"source">>, This, _Args) ->
    case This =:= buoy_heap:intrinsic('RegExp.prototype') of
        true -> <<"(?:)">>;
        false ->
            this_object(This, <<"source">>),
            #{source := Source} = has_slots(This, <<"source">>),
            escape_pattern(Source)
    end;
proto(<<"[Symbol.match]">>, This, Args) -> symbol_match(this_object(This, <<"[Symbol.match]">>), buoy_ref:to_string(arg(1, Args)));
proto(<<"[Symbol.matchAll]">>, This, Args) -> symbol_match_all(this_object(This, <<"[Symbol.matchAll]">>), buoy_ref:to_string(arg(1, Args)));
proto(<<"[Symbol.replace]">>, This, Args) -> symbol_replace(this_object(This, <<"[Symbol.replace]">>), buoy_ref:to_string(arg(1, Args)), arg(2, Args));
proto(<<"[Symbol.search]">>, This, Args) -> symbol_search(this_object(This, <<"[Symbol.search]">>), buoy_ref:to_string(arg(1, Args)));
proto(<<"[Symbol.split]">>, This, Args) -> symbol_split(this_object(This, <<"[Symbol.split]">>), buoy_ref:to_string(arg(1, Args)), arg(2, Args));
proto(Name, This, _Args) ->
    Flag = case Name of
        <<"dotAll">> -> $s;
        <<"global">> -> $g;
        <<"hasIndices">> -> $d;
        <<"ignoreCase">> -> $i;
        <<"multiline">> -> $m;
        <<"sticky">> -> $y;
        <<"unicode">> -> $u;
        <<"unicodeSets">> -> $v
    end,
    has_flag(This, Flag, Name).

%% RegExpHasFlag: undefined for RegExp.prototype of the current realm.
has_flag(This, Flag, Name) ->
    case This =:= buoy_heap:intrinsic('RegExp.prototype') of
        true -> undefined;
        false -> object_has_flag(This, Flag, Name)
    end.

object_has_flag(This, Flag, Name) ->
    this_object(This, Name),
    #{flags := Flags} = has_slots(This, Name),
    lists:member(Flag, buoy_ref_string:units(Flags)).

has_slots(This, Name) ->
    case is_regexp_object(This) of
        true -> buoy_heap:slots(This);
        false -> type_error(buoy_ref_string:concat([<<"RegExp.prototype.">>, Name, <<" getter called on non-RegExp object">>]))
    end.

%% EscapeRegExpPattern: / outside a class and the line terminators become
%% escapes, so /source/flags reads back as the same literal.
escape_pattern(<<>>) -> <<"(?:)">>;
escape_pattern(Source) -> buoy_ref_string:from_units(escape_units(buoy_ref_string:units(Source), false)).

escape_units([$\\, C | Rest], InClass) -> [$\\ | line_escape(C, true)] ++ escape_units(Rest, InClass);
escape_units([$/ | Rest], false) -> [$\\, $/ | escape_units(Rest, false)];
escape_units([$[ | Rest], false) -> [$[ | escape_units(Rest, true)];
escape_units([$] | Rest], true) -> [$] | escape_units(Rest, false)];
escape_units([C | Rest], InClass) -> line_escape(C, false) ++ escape_units(Rest, InClass);
escape_units([], _InClass) -> [].

line_escape(10, Escaped) -> slash(Escaped, "n");
line_escape(13, Escaped) -> slash(Escaped, "r");
line_escape(16#2028, Escaped) -> slash(Escaped, "u2028");
line_escape(16#2029, Escaped) -> slash(Escaped, "u2029");
line_escape(C, _Escaped) -> [C].

slash(true, Text) -> Text;
slash(false, Text) -> [$\\ | Text].

%%% Matching

%% RegExpExec.
regexp_exec(R, S) ->
    case buoy_ref:get(R, <<"exec">>) of
        {'$f', _, _} = Exec ->
            case buoy_ref:call(Exec, R, [S]) of
                Result when ?IS_OBJECT(Result); Result =:= null -> Result;
                _ -> type_error(<<"The result of a RegExp exec method must be an object or null">>)
            end;
        _ ->
            builtin_exec(this_regexp(R, <<"exec">>), S)
    end.

%% RegExpBuiltinExec.
builtin_exec(R, S) ->
    Length = buoy_ref_string:length_of(S),
    LastIndex0 = to_length(buoy_ref:get(R, <<"lastIndex">>)),
    #{flags := Flags, names := Names, legacy := Legacy} = Slots = buoy_heap:slots(R),
    Program = matcher(Slots),
    Units = buoy_ref_string:units(Flags),
    Global = lists:member($g, Units),
    Sticky = lists:member($y, Units),
    Updates = Global orelse Sticky,
    LastIndex = case Updates of
        true -> LastIndex0;
        false -> 0
    end,
    Found = case LastIndex > Length of
        true -> nomatch;
        false -> buoy_regexp_match:search(Program, buoy_regexp_match:input(S), LastIndex, Sticky)
    end,
    case Found of
        nomatch ->
            Updates andalso buoy_heap:set(R, <<"lastIndex">>, 0),
            null;
        {match, Index, End, Captures} ->
            Updates andalso buoy_heap:set(R, <<"lastIndex">>, End),
            Legacy andalso erlang:put(?LEGACY, {S, {S, Index, End, Captures}}),
            match_array(S, Index, End, Captures, Names, lists:member($d, Units))
    end.

match_array(S, Index, End, Captures, Names, HasIndices) ->
    Ranges = [{Index, End} | tuple_to_list(Captures)],
    Values = [substring(S, Range) || Range <- Ranges],
    A = buoy_heap:new_array(Values),
    data(A, <<"index">>, Index),
    data(A, <<"input">>, S),
    {Groups, GroupNames} = groups(lists:zip(lists:seq(1, length(Values) - 1), tl(Values)), Names),
    data(A, <<"groups">>, Groups),
    HasIndices andalso data(A, <<"indices">>, indices_array(Ranges, GroupNames, Groups =/= undefined)),
    A.

substring(_S, undefined) -> undefined;
substring(S, {Start, End}) -> buoy_ref_string:slice(S, Start, End).

%% The groups object, and the name of each capture or undefined.
groups(_Captures, []) -> {undefined, []};
groups(Captures, Names) ->
    G = buoy_heap:new_object(null),
    {GroupNames, _} = lists:mapfoldl(fun({I, Value}, Matched) ->
                                             case lists:keyfind(I, 1, Names) of
                                                 false -> {undefined, Matched};
                                                 {_, Name} ->
                                                     case lists:member(Name, Matched) of
                                                         true -> {undefined, Matched};
                                                         false ->
                                                             data(G, Name, Value),
                                                             {Name, case Value of undefined -> Matched; _ -> [Name | Matched] end}
                                                     end
                                             end
                                     end, [], Captures),
    {G, GroupNames}.

%% MakeMatchIndicesIndexPairArray.
indices_array(Ranges, GroupNames, HasGroups) ->
    Pairs = [case R of undefined -> undefined; {A, B} -> buoy_heap:new_array([A, B]) end || R <- Ranges],
    Array = buoy_heap:new_array(Pairs),
    Groups = case HasGroups of
        true ->
            G = buoy_heap:new_object(null),
            [data(G, Name, Pair) || {Name, Pair} <- lists:zip(GroupNames, tl(Pairs)), Name =/= undefined],
            G;
        false -> undefined
    end,
    data(Array, <<"groups">>, Groups),
    Array.

%% CreateDataPropertyOrThrow.
data(O, K, V) -> buoy_heap:define(O, K, #{value => V, writable => true, enumerable => true, configurable => true}).

to_length(V) ->
    case buoy_ref_number:to_integer_or_infinity(buoy_ref:to_number(V)) of
        'Infinity' -> ?MAX_LENGTH;
        '-Infinity' -> 0;
        I when I =< 0 -> 0;
        I -> min(I, ?MAX_LENGTH)
    end.

to_integer(V) -> buoy_ref_number:to_integer_or_infinity(buoy_ref:to_number(V)).

%% AdvanceStringIndex.
advance(S, I, true) ->
    case I + 1 < buoy_ref_string:length_of(S) of
        true ->
            H = buoy_ref_string:unit_at(S, I),
            L = buoy_ref_string:unit_at(S, I + 1),
            case H >= 16#D800 andalso H =< 16#DBFF andalso L >= 16#DC00 andalso L =< 16#DFFF of
                true -> I + 2;
                false -> I + 1
            end;
        false -> I + 1
    end;
advance(_S, I, false) -> I + 1.

flags_of(R) -> buoy_ref_string:units(buoy_ref:to_string(buoy_ref:get(R, <<"flags">>))).

full_unicode(Flags) -> lists:member($u, Flags) orelse lists:member($v, Flags).

%% After an empty match, lastIndex moves past it.
skip_empty(R, S, <<>>, Unicode) ->
    buoy_ref:set(R, <<"lastIndex">>, advance(S, to_length(buoy_ref:get(R, <<"lastIndex">>)), Unicode));
skip_empty(_R, _S, _Matched, _Unicode) -> ok.

%% Whether the protocols can read R without running user code: a RegExp whose
%% prototype is RegExp.prototype and whose only own property is a numeric
%% lastIndex, in a realm that has not written to RegExp.prototype. A realm has no
%% heap entry for an intrinsic until it writes to it (contract 17.2), so exec,
%% flags, and the flag accessors are the builtins.
pristine({'$o', _} = R) ->
    erlang:get('RegExp.prototype') =:= undefined andalso is_regexp_object(R) andalso
        buoy_heap:prototype_of(R) =:= ?PROTO andalso buoy_heap:own_keys(R) =:= [<<"lastIndex">>] andalso
        case buoy_heap:get_own(R, <<"lastIndex">>) of
            {data, V, _} -> ?IS_NUMBER(V);
            _ -> false
        end;
pristine(_) -> false.

%% The matcher of a pristine RegExp with the g flag, for the loops of
%% Symbol.match and Symbol.replace: {ok, Program, Unicode, Sticky} or none.
global_program(R) ->
    case pristine(R) of
        true ->
            #{flags := Flags} = Slots = buoy_heap:slots(R),
            Units = buoy_ref_string:units(Flags),
            case lists:member($g, Units) of
                true -> {ok, matcher(Slots), full_unicode(Units), lists:member($y, Units)};
                false -> none
            end;
        false -> none
    end.

%% Every match of the loop of Symbol.match and Symbol.replace with g, from
%% lastIndex 0: after an empty match the next search starts one character on.
all_matches(Program, S, Unicode, Sticky) ->
    all_matches(Program, buoy_regexp_match:input(S), S, buoy_ref_string:length_of(S), Unicode, Sticky, 0, []).

all_matches(Program, In, S, Length, Unicode, Sticky, LastIndex, Acc) when LastIndex =< Length ->
    case buoy_regexp_match:search(Program, In, LastIndex, Sticky) of
        nomatch -> lists:reverse(Acc);
        {match, Index, End, _} = Match ->
            Next = case End =< Index of
                true -> advance(S, End, Unicode);
                false -> End
            end,
            all_matches(Program, In, S, Length, Unicode, Sticky, Next, [Match | Acc])
    end;
all_matches(_Program, _In, _S, _Length, _Unicode, _Sticky, _LastIndex, Acc) ->
    lists:reverse(Acc).

symbol_match(R, S) ->
    case global_program(R) of
        {ok, Program, Unicode, Sticky} ->
            Matches = all_matches(Program, S, Unicode, Sticky),
            buoy_ref:set(R, <<"lastIndex">>, 0),
            case Matches of
                [] -> null;
                _ -> buoy_heap:new_array([buoy_ref_string:slice(S, Index, End) || {match, Index, End, _} <- Matches])
            end;
        none ->
            Flags = flags_of(R),
            case lists:member($g, Flags) of
                false -> regexp_exec(R, S);
                true ->
                    Unicode = full_unicode(Flags),
                    buoy_ref:set(R, <<"lastIndex">>, 0),
                    match_all(R, S, Unicode, [])
            end
    end.

match_all(R, S, Unicode, Acc) ->
    case regexp_exec(R, S) of
        null when Acc =:= [] -> null;
        null -> buoy_heap:new_array(lists:reverse(Acc));
        Match ->
            Matched = buoy_ref:to_string(buoy_ref:get(Match, 0)),
            skip_empty(R, S, Matched, Unicode),
            match_all(R, S, Unicode, [Matched | Acc])
    end.

symbol_match_all(R, S) ->
    C = species_constructor(R),
    Flags = buoy_ref:to_string(buoy_ref:get(R, <<"flags">>)),
    Matcher = buoy_ref:construct(C, [R, Flags]),
    LastIndex = to_length(buoy_ref:get(R, <<"lastIndex">>)),
    buoy_ref:set(Matcher, <<"lastIndex">>, LastIndex),
    Units = buoy_ref_string:units(Flags),
    buoy_heap:new_exotic(regexp_string_iterator, ?ITERATOR, {Matcher, S, lists:member($g, Units), full_unicode(Units), false}).

iterator_next({'$o', _} = O) ->
    case buoy_heap:class_of(O) of
        regexp_string_iterator -> iterator_step(O, buoy_heap:slots(O));
        _ -> type_error(<<"%RegExpStringIterator%.next requires that 'this' be a RegExp String Iterator">>)
    end;
iterator_next(_) -> type_error(<<"%RegExpStringIterator%.next requires that 'this' be an Object">>).

iterator_step(_O, {_, _, _, _, true}) -> buoy_ref_iterator:result(undefined, true);
iterator_step(O, {R, S, Global, Unicode, false}) ->
    case regexp_exec(R, S) of
        null ->
            buoy_heap:set_slots(O, {R, S, Global, Unicode, true}),
            buoy_ref_iterator:result(undefined, true);
        Match when not Global ->
            buoy_heap:set_slots(O, {R, S, Global, Unicode, true}),
            buoy_ref_iterator:result(Match, false);
        Match ->
            skip_empty(R, S, buoy_ref:to_string(buoy_ref:get(Match, 0)), Unicode),
            buoy_ref_iterator:result(Match, false)
    end.

%% SpeciesConstructor(R, %RegExp%).
species_constructor(R) ->
    case buoy_ref:get(R, <<"constructor">>) of
        undefined -> constructor();
        C when ?IS_OBJECT(C) ->
            case buoy_ref:get(C, ?SYM(species)) of
                Species when Species =:= undefined; Species =:= null -> constructor();
                Species ->
                    is_constructor(Species) orelse type_error(<<"object.constructor[Symbol.species] is not a constructor">>),
                    Species
            end;
        _ -> type_error(<<"The .constructor property is not an object">>)
    end.

is_constructor({'$f', _, _} = F) ->
    case buoy_heap:slots(F) of
        #{construct := _} -> true;
        #{kind := normal} -> true;
        _ -> false
    end;
is_constructor(_) -> false.

symbol_replace(R, S, ReplaceValue) ->
    Length = buoy_ref_string:length_of(S),
    Functional = buoy_heap:is_callable(ReplaceValue),
    Template = case Functional of
        true -> ReplaceValue;
        false -> buoy_ref:to_string(ReplaceValue)
    end,
    {Parts, Next} = case global_program(R) of
        {ok, Program, Unicode, Sticky} ->
            Matches = all_matches(Program, S, Unicode, Sticky),
            buoy_ref:set(R, <<"lastIndex">>, 0),
            #{names := Names} = buoy_heap:slots(R),
            lists:foldl(fun({match, Index, End, Caps}, {Acc, NextPosition}) ->
                                Captures = [substring(S, C) || C <- tuple_to_list(Caps)],
                                {Named, _} = groups(lists:enumerate(1, Captures), Names),
                                Match = {buoy_ref_string:slice(S, Index, End), Index, Captures, Named},
                                replace_match(Match, S, Functional, Template, Acc, NextPosition)
                        end, {[], 0}, Matches);
        none ->
            Flags = flags_of(R),
            Global = lists:member($g, Flags),
            Global andalso buoy_ref:set(R, <<"lastIndex">>, 0),
            Results = replace_results(R, S, Global, full_unicode(Flags), []),
            lists:foldl(fun(Result, {Acc, NextPosition}) ->
                                replace_match(match_record(Result, Length), S, Functional, Template, Acc, NextPosition)
                        end, {[], 0}, Results)
    end,
    case Next >= Length of
        true -> buoy_ref_string:concat(lists:reverse(Parts));
        false -> buoy_ref_string:concat(lists:reverse([buoy_ref_string:slice(S, Next, Length) | Parts]))
    end.

replace_results(R, S, Global, Unicode, Acc) ->
    case regexp_exec(R, S) of
        null -> lists:reverse(Acc);
        Result when not Global -> lists:reverse([Result | Acc]);
        Result ->
            skip_empty(R, S, buoy_ref:to_string(buoy_ref:get(Result, 0)), Unicode),
            replace_results(R, S, Global, Unicode, [Result | Acc])
    end.

%% The matched text, position, captures, and groups of a result of RegExpExec,
%% read in the order of RegExp.prototype[Symbol.replace].
match_record(Result, Length) ->
    Count = max(to_length(buoy_ref:get(Result, <<"length">>)) - 1, 0),
    Matched = buoy_ref:to_string(buoy_ref:get(Result, 0)),
    Position = clamp(to_integer(buoy_ref:get(Result, <<"index">>)), Length),
    Captures = [case buoy_ref:get(Result, N) of
                    undefined -> undefined;
                    V -> buoy_ref:to_string(V)
                end || N <- lists:seq(1, Count)],
    {Matched, Position, Captures, buoy_ref:get(Result, <<"groups">>)}.

replace_match({Matched, Position, Captures, Named}, S, Functional, Template, Acc, NextPosition) ->
    Replacement = case Functional of
        true ->
            Extra = case Named of
                undefined -> [];
                _ -> [Named]
            end,
            buoy_ref:to_string(buoy_ref:call(Template, undefined, [Matched | Captures] ++ [Position, S | Extra]));
        false ->
            Groups = case Named of
                undefined -> undefined;
                _ -> to_object(Named)
            end,
            substitution(Matched, S, Position, Captures, Groups, Template)
    end,
    case Position >= NextPosition of
        true -> {[Replacement, buoy_ref_string:slice(S, NextPosition, Position) | Acc], Position + buoy_ref_string:length_of(Matched)};
        false -> {Acc, NextPosition}
    end.

clamp('-Infinity', _Length) -> 0;
clamp('Infinity', Length) -> Length;
clamp(I, Length) -> min(max(I, 0), Length).

to_object(V) when V =:= undefined; V =:= null -> type_error(<<"Cannot convert undefined or null to object">>);
to_object(V) -> V.

%% GetSubstitution.
substitution(Matched, S, Position, Captures, Groups, Template) ->
    buoy_ref_string:concat(substitute(buoy_ref_string:units(Template), Matched, S, Position, Captures, Groups)).

substitute([$$, $$ | Rest], M, S, P, C, G) -> [<<"$">> | substitute(Rest, M, S, P, C, G)];
substitute([$$, $` | Rest], M, S, P, C, G) -> [buoy_ref_string:slice(S, 0, P) | substitute(Rest, M, S, P, C, G)];
substitute([$$, $& | Rest], M, S, P, C, G) -> [M | substitute(Rest, M, S, P, C, G)];
substitute([$$, $' | Rest], M, S, P, C, G) ->
    Length = buoy_ref_string:length_of(S),
    Tail = min(P + buoy_ref_string:length_of(M), Length),
    [buoy_ref_string:slice(S, Tail, Length) | substitute(Rest, M, S, P, C, G)];
substitute([$$, D1, D2 | Rest], M, S, P, C, G) when ?IS_DIGIT(D1), ?IS_DIGIT(D2), (D1 - $0) * 10 + D2 - $0 =< length(C),
                                                   (D1 - $0) * 10 + D2 - $0 >= 1 ->
    [capture((D1 - $0) * 10 + D2 - $0, C) | substitute(Rest, M, S, P, C, G)];
substitute([$$, D | Rest], M, S, P, C, G) when ?IS_DIGIT(D), D - $0 >= 1, D - $0 =< length(C) ->
    [capture(D - $0, C) | substitute(Rest, M, S, P, C, G)];
substitute([$$, $< | Rest], M, S, P, C, G) when G =/= undefined ->
    case lists:splitwith(fun(U) -> U =/= $> end, Rest) of
        {Name, [$> | Rest1]} ->
            Value = case buoy_ref:get(G, buoy_ref_string:from_units(Name)) of
                undefined -> <<>>;
                V -> buoy_ref:to_string(V)
            end,
            [Value | substitute(Rest1, M, S, P, C, G)];
        _ -> [<<"$<">> | substitute(Rest, M, S, P, C, G)]
    end;
substitute([U | Rest], M, S, P, C, G) -> [buoy_ref_string:from_units([U]) | substitute(Rest, M, S, P, C, G)];
substitute([], _M, _S, _P, _C, _G) -> [].

capture(N, Captures) ->
    case lists:nth(N, Captures) of
        undefined -> <<>>;
        V -> V
    end.

symbol_search(R, S) ->
    Previous = buoy_ref:get(R, <<"lastIndex">>),
    same_value(Previous, 0) orelse buoy_ref:set(R, <<"lastIndex">>, 0),
    Result = regexp_exec(R, S),
    Current = buoy_ref:get(R, <<"lastIndex">>),
    same_value(Current, Previous) orelse buoy_ref:set(R, <<"lastIndex">>, Previous),
    case Result of
        null -> -1;
        _ -> buoy_ref:get(Result, <<"index">>)
    end.

%% SameValue for the lastIndex checks: -0 differs from +0.
same_value(A, B) when is_float(A), is_float(B) -> <<A/float>> =:= <<B/float>>;
same_value(A, B) when is_number(A), is_number(B) -> A =:= B;
same_value(A, B) -> A =:= B.

symbol_split(R, S, Limit) ->
    case pristine(R) andalso erlang:get({builtin, <<"RegExp">>}) =:= undefined of
        true -> fast_split(R, S, Limit);
        false -> generic_split(R, S, Limit)
    end.

generic_split(R, S, Limit) ->
    C = species_constructor(R),
    Flags = buoy_ref:to_string(buoy_ref:get(R, <<"flags">>)),
    Units = buoy_ref_string:units(Flags),
    Unicode = full_unicode(Units),
    NewFlags = case lists:member($y, Units) of
        true -> Flags;
        false -> buoy_ref_string:concat(Flags, <<"y">>)
    end,
    Splitter = buoy_ref:construct(C, [R, NewFlags]),
    Lim = case Limit of
        undefined -> 16#FFFFFFFF;
        _ -> buoy_ref_number:to_uint32(buoy_ref:to_number(Limit))
    end,
    Size = buoy_ref_string:length_of(S),
    case {Lim, Size} of
        {0, _} -> buoy_heap:new_array([]);
        {_, 0} ->
            case regexp_exec(Splitter, S) of
                null -> buoy_heap:new_array([S]);
                _ -> buoy_heap:new_array([])
            end;
        _ -> buoy_heap:new_array(split_loop(Splitter, S, Size, Unicode, Lim, 0, 0, [], 0))
    end.

split_loop(Splitter, S, Size, Unicode, Lim, LastEnd, Search, Acc, Count) when Search < Size ->
    buoy_ref:set(Splitter, <<"lastIndex">>, Search),
    case regexp_exec(Splitter, S) of
        null -> split_loop(Splitter, S, Size, Unicode, Lim, LastEnd, advance(S, Search, Unicode), Acc, Count);
        Match ->
            End = min(to_length(buoy_ref:get(Splitter, <<"lastIndex">>)), Size),
            case End =:= LastEnd of
                true -> split_loop(Splitter, S, Size, Unicode, Lim, LastEnd, advance(S, Search, Unicode), Acc, Count);
                false ->
                    Acc1 = [buoy_ref_string:slice(S, LastEnd, Search) | Acc],
                    case Count + 1 =:= Lim of
                        true -> lists:reverse(Acc1);
                        false ->
                            Captures = max(to_length(buoy_ref:get(Match, <<"length">>)) - 1, 0),
                            case split_captures(fun(I) -> buoy_ref:get(Match, I) end, 1, Captures, Acc1, Count + 1, Lim) of
                                {done, Final} -> lists:reverse(Final);
                                {more, Acc2, Count2} -> split_loop(Splitter, S, Size, Unicode, Lim, End, End, Acc2, Count2)
                            end
                    end
            end
    end;
split_loop(_Splitter, S, Size, _Unicode, _Lim, LastEnd, _Search, Acc, _Count) ->
    lists:reverse([buoy_ref_string:slice(S, LastEnd, Size) | Acc]).

split_captures(_Capture, I, N, Acc, Count, _Lim) when I > N -> {more, Acc, Count};
split_captures(Capture, I, N, Acc, Count, Lim) ->
    Acc1 = [Capture(I) | Acc],
    case Count + 1 =:= Lim of
        true -> {done, Acc1};
        false -> split_captures(Capture, I + 1, N, Acc1, Count + 1, Lim)
    end.

%% Symbol.split when the splitter that the spec constructs runs no user code:
%% the matcher of R searches ahead instead of trying each position sticky.
%% A position fails sticky exactly when the search passes it.
fast_split(R, S, Limit) ->
    #{flags := Flags} = Slots = buoy_heap:slots(R),
    Program = matcher(Slots),
    Unicode = full_unicode(buoy_ref_string:units(Flags)),
    Lim = case Limit of
        undefined -> 16#FFFFFFFF;
        _ -> buoy_ref_number:to_uint32(buoy_ref:to_number(Limit))
    end,
    In = buoy_regexp_match:input(S),
    Size = buoy_ref_string:length_of(S),
    case {Lim, Size} of
        {0, _} -> buoy_heap:new_array([]);
        {_, 0} ->
            case buoy_regexp_match:search(Program, In, 0, true) of
                nomatch -> buoy_heap:new_array([S]);
                _ -> buoy_heap:new_array([])
            end;
        _ -> buoy_heap:new_array(fast_split_loop(Program, In, S, Size, Unicode, Lim, 0, 0, [], 0))
    end.

fast_split_loop(Program, In, S, Size, Unicode, Lim, LastEnd, Search, Acc, Count) when Search < Size ->
    case buoy_regexp_match:search(Program, In, Search, false) of
        {match, Index, End0, Caps} when Index < Size ->
            End = min(End0, Size),
            case End =:= LastEnd of
                true -> fast_split_loop(Program, In, S, Size, Unicode, Lim, LastEnd, advance(S, Index, Unicode), Acc, Count);
                false ->
                    Acc1 = [buoy_ref_string:slice(S, LastEnd, Index) | Acc],
                    case Count + 1 =:= Lim of
                        true -> lists:reverse(Acc1);
                        false ->
                            Capture = fun(I) -> substring(S, element(I, Caps)) end,
                            case split_captures(Capture, 1, tuple_size(Caps), Acc1, Count + 1, Lim) of
                                {done, Final} -> lists:reverse(Final);
                                {more, Acc2, Count2} -> fast_split_loop(Program, In, S, Size, Unicode, Lim, End, End, Acc2, Count2)
                            end
                    end
            end;
        _ -> lists:reverse([buoy_ref_string:slice(S, LastEnd, Size) | Acc])
    end;
fast_split_loop(_Program, _In, S, Size, _Unicode, _Lim, LastEnd, _Search, Acc, _Count) ->
    lists:reverse([buoy_ref_string:slice(S, LastEnd, Size) | Acc]).

%%% The legacy static properties

%% GetLegacyRegExpStaticProperty. Before any match, each is the empty string.
legacy_get(Name, This) ->
    legacy_receiver(This),
    {Input, Match} = case erlang:get(?LEGACY) of
        undefined -> {<<>>, none};
        State -> State
    end,
    legacy_value(Name, Input, Match).

legacy_value(Name, Input, _Match) when Name =:= <<"input">>; Name =:= <<"$_">> -> Input;
legacy_value(_Name, _Input, none) -> <<>>;
legacy_value(Name, _Input, {S, Start, End, _Captures}) when Name =:= <<"lastMatch">>; Name =:= <<"$&">> ->
    buoy_ref_string:slice(S, Start, End);
legacy_value(Name, _Input, {S, _Start, _End, Captures}) when Name =:= <<"lastParen">>; Name =:= <<"$+">> ->
    case tuple_size(Captures) of
        0 -> <<>>;
        N -> legacy_capture(S, element(N, Captures))
    end;
legacy_value(Name, _Input, {S, Start, _End, _Captures}) when Name =:= <<"leftContext">>; Name =:= <<"$`">> ->
    buoy_ref_string:slice(S, 0, Start);
legacy_value(Name, _Input, {S, _Start, End, _Captures}) when Name =:= <<"rightContext">>; Name =:= <<"$'">> ->
    buoy_ref_string:slice(S, End, buoy_ref_string:length_of(S));
legacy_value(<<"$", D>>, _Input, {S, _Start, _End, Captures}) when D - $0 =< tuple_size(Captures) ->
    legacy_capture(S, element(D - $0, Captures));
legacy_value(_Name, _Input, _Match) -> <<>>.

legacy_capture(_S, undefined) -> <<>>;
legacy_capture(S, Range) -> substring(S, Range).

%% SetLegacyRegExpStaticProperty for input and $_.
legacy_set_input(This, Value) ->
    legacy_receiver(This),
    Input = buoy_ref:to_string(Value),
    Match = case erlang:get(?LEGACY) of
        undefined -> none;
        {_, M} -> M
    end,
    erlang:put(?LEGACY, {Input, Match}),
    undefined.

legacy_receiver(This) ->
    This =:= constructor() orelse type_error(<<"RegExp legacy static properties require that 'this' be RegExp">>).

%%% RegExp.escape

escape(S) when ?IS_STRING(S) ->
    Codes = buoy_ref_string:code_points(S),
    buoy_ref_string:concat(escape_codes(Codes, true));
escape(_) -> type_error(<<"RegExp.escape requires a string">>).

escape_codes([C | Rest], true) when ?IS_DIGIT(C); (C >= $a andalso C =< $z); (C >= $A andalso C =< $Z) ->
    [hex_escape(C) | escape_codes(Rest, false)];
escape_codes([C | Rest], _First) -> [encode_escape(C) | escape_codes(Rest, false)];
escape_codes([], _First) -> [].

hex_escape(C) -> list_to_binary(io_lib:format("\\x~2.16.0b", [C])).

%% EncodeForRegExpEscape.
encode_escape(C) when C =:= $^; C =:= $$; C =:= $\\; C =:= $.; C =:= $*; C =:= $+; C =:= $?; C =:= $(; C =:= $);
                      C =:= $[; C =:= $]; C =:= ${; C =:= $}; C =:= $|; C =:= $/ ->
    <<$\\, C>>;
encode_escape(9) -> <<"\\t">>;
encode_escape(10) -> <<"\\n">>;
encode_escape(11) -> <<"\\v">>;
encode_escape(12) -> <<"\\f">>;
encode_escape(13) -> <<"\\r">>;
encode_escape(C) ->
    Punctuator = lists:member(C, ",-=<>#&!%:;@~'`\""),
    Space = buoy_ref_string:is_whitespace(C) orelse C =:= 16#2028 orelse C =:= 16#2029,
    Surrogate = C >= 16#D800 andalso C =< 16#DFFF,
    case Punctuator orelse Space orelse Surrogate of
        true when C =< 16#FF -> hex_escape(C);
        true -> list_to_binary(io_lib:format("\\u~4.16.0b", [C]));
        false -> buoy_ref_string:from_code_points([C])
    end.

%%% The methods of String.prototype that take a pattern

%% String.prototype.match, matchAll, replace, replaceAll, search, and split.
-spec string_method(binary(), term(), list()) -> term().
string_method(Name, This, _Args) when This =:= undefined; This =:= null ->
    type_error(<<"String.prototype.", Name/binary, " called on null or undefined">>);
string_method(<<"match">>, This, Args) ->
    Pattern = arg(1, Args),
    case custom(Pattern, match) of
        {ok, Matcher} -> buoy_ref:call(Matcher, Pattern, [This]);
        none ->
            S = buoy_ref:to_string(This),
            buoy_ref:call_method(create(Pattern, undefined), ?SYM(match), [S])
    end;
string_method(<<"matchAll">>, This, Args) ->
    Pattern = arg(1, Args),
    require_global(Pattern, <<"matchAll">>),
    case custom(Pattern, matchAll) of
        {ok, Matcher} -> buoy_ref:call(Matcher, Pattern, [This]);
        none ->
            S = buoy_ref:to_string(This),
            buoy_ref:call_method(create(Pattern, <<"g">>), ?SYM(matchAll), [S])
    end;
string_method(<<"search">>, This, Args) ->
    Pattern = arg(1, Args),
    case custom(Pattern, search) of
        {ok, Searcher} -> buoy_ref:call(Searcher, Pattern, [This]);
        none ->
            S = buoy_ref:to_string(This),
            buoy_ref:call_method(create(Pattern, undefined), ?SYM(search), [S])
    end;
string_method(<<"replace">>, This, Args) ->
    Search = arg(1, Args),
    Replace = arg(2, Args),
    case custom(Search, replace) of
        {ok, Replacer} -> buoy_ref:call(Replacer, Search, [This, Replace]);
        none -> replace_string(buoy_ref:to_string(This), Search, Replace, first)
    end;
string_method(<<"replaceAll">>, This, Args) ->
    Search = arg(1, Args),
    Replace = arg(2, Args),
    require_global(Search, <<"replaceAll">>),
    case custom(Search, replace) of
        {ok, Replacer} -> buoy_ref:call(Replacer, Search, [This, Replace]);
        none -> replace_string(buoy_ref:to_string(This), Search, Replace, all)
    end;
string_method(<<"split">>, This, Args) ->
    Separator = arg(1, Args),
    Limit = arg(2, Args),
    case custom(Separator, split) of
        {ok, Splitter} -> buoy_ref:call(Splitter, Separator, [This, Limit]);
        none -> split_string(buoy_ref:to_string(This), Separator, Limit)
    end.

%% The method of a well-known symbol of an object pattern: GetMethod.
custom(V, Symbol) when ?IS_OBJECT(V) ->
    case buoy_ref:get(V, ?SYM(Symbol)) of
        M when M =:= undefined; M =:= null -> none;
        {'$f', _, _} = M -> {ok, M};
        _ -> type_error(buoy_ref_string:concat([<<"Symbol.">>, atom_to_binary(Symbol), <<" is not a function">>]))
    end;
custom(_V, _Symbol) -> none.

%% matchAll and replaceAll reject a RegExp without the g flag.
require_global(V, Name) when ?IS_OBJECT(V) ->
    case is_regexp(V) of
        true ->
            Flags = buoy_ref:get(V, <<"flags">>),
            (Flags =:= undefined orelse Flags =:= null) andalso type_error(<<"Cannot convert undefined or null to object">>),
            lists:member($g, buoy_ref_string:units(buoy_ref:to_string(Flags))) orelse
                type_error(<<"String.prototype.", Name/binary, " called with a non-global RegExp argument">>);
        false -> ok
    end;
require_global(_V, _Name) -> ok.

replace_string(S, SearchValue, ReplaceValue, Count) ->
    Search = buoy_ref:to_string(SearchValue),
    Functional = buoy_heap:is_callable(ReplaceValue),
    Template = case Functional of
        true -> ReplaceValue;
        false -> buoy_ref:to_string(ReplaceValue)
    end,
    SearchLength = buoy_ref_string:length_of(Search),
    Positions = positions(S, Search, 0, max(1, SearchLength), Count),
    Replace = fun(Position) ->
                      case Functional of
                          true -> buoy_ref:to_string(buoy_ref:call(Template, undefined, [Search, Position, S]));
                          false -> substitution(Search, S, Position, [], undefined, Template)
                      end
              end,
    {Parts, End} = lists:mapfoldl(fun(Position, From) ->
                                          Preserved = buoy_ref_string:slice(S, From, Position),
                                          {[Preserved, Replace(Position)], Position + SearchLength}
                                  end, 0, Positions),
    Length = buoy_ref_string:length_of(S),
    Tail = case End < Length of
        true -> [buoy_ref_string:slice(S, End, Length)];
        false -> []
    end,
    case Positions of
        [] -> S;
        _ -> buoy_ref_string:concat(lists:append(Parts) ++ Tail)
    end.

positions(S, Search, From, Advance, Count) ->
    case buoy_ref_string:index_of(S, Search, From) of
        -1 -> [];
        I when Count =:= first -> [I];
        I -> [I | positions(S, Search, I + Advance, Advance, Count)]
    end.

split_string(S, Separator, Limit) ->
    Lim = case Limit of
        undefined -> 16#FFFFFFFF;
        _ -> buoy_ref_number:to_uint32(buoy_ref:to_number(Limit))
    end,
    R = buoy_ref:to_string(Separator),
    Length = buoy_ref_string:length_of(S),
    case {Lim, Separator, buoy_ref_string:length_of(R)} of
        {0, _, _} -> buoy_heap:new_array([]);
        {_, undefined, _} -> buoy_heap:new_array([S]);
        {_, _, 0} -> buoy_heap:new_array([buoy_ref_string:unit_string(S, I) || I <- lists:seq(0, min(Lim, Length) - 1)]);
        _ when Length =:= 0 -> buoy_heap:new_array([S]);
        _ -> buoy_heap:new_array(lists:sublist(split_parts(S, R, 0), Lim))
    end.

split_parts(S, Separator, From) ->
    case buoy_ref_string:index_of(S, Separator, From) of
        -1 -> [buoy_ref_string:slice(S, From, buoy_ref_string:length_of(S))];
        I -> [buoy_ref_string:slice(S, From, I) | split_parts(S, Separator, I + buoy_ref_string:length_of(Separator))]
    end.
