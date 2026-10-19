%% The parser of RegExp patterns: the grammar of ECMA-262 22.2.1 with the
%% extensions of Annex B.1.2 for patterns without the u and v flags, and its
%% early errors.
%%
%% parse/3 takes the pattern as a list of source characters: code points with
%% u or v, else code units (22.2.3.3 RegExpInitialize). It returns the tree
%% that buoy_regexp_match compiles:
%%
%%   empty | {char, C} | dot | {seq, [Node]} | {alt, [Node]}
%%   {class, Negated, [Item]}     a class without v; an Item is {char, C},
%%                                {range, A, B}, or {escape, Escape}
%%   {vclass, Negated, SetExpr}   a class with v (see class_set_expression/2)
%%   {escape, Escape}             \d \D \s \S \w \W \p{..} \P{..} outside a class
%%   {group, Index, Node}         a capturing group, numbered from 1
%%   {mods, Add, Remove, Node}    (?ims-ims:...): the flags as lists of i, m, s
%%   {repeat, Min, Max, Greedy, Node, ParenIndex, ParenCount}
%%   bol | eol | word_boundary | not_word_boundary
%%   {look, ahead | behind, Positive, Node}
%%   {backref, [Index]}           \1, or \k<name> with every group of that name
%%
%% An Escape is digit, not_digit, space, not_space, word, not_word,
%% {property, Key, Negated}, where Key names the ranges of buoy_regexp_unicode,
%% or {strings, Name} for a property of strings.
-module(buoy_regexp_syntax).

-export([parse/3, has_strings/1]).

-record(p, {u :: boolean(),          % UnicodeMode
            v :: boolean(),          % UnicodeSetsMode
            named :: boolean(),      % NamedCaptureGroups
            total :: non_neg_integer(), % the capturing groups of the whole pattern
            count = 0 :: non_neg_integer(),
            names = [] :: [{term(), pos_integer(), list()}],
            path = [] :: list(),     % the alternatives that enclose the position
            disjunctions = 0 :: non_neg_integer(),
            refs = [] :: [term()]}). % the names of the \k references

-define(IS_DIGIT(C), (C >= $0 andalso C =< $9)).
-define(IS_OCTAL(C), (C >= $0 andalso C =< $7)).
-define(IS_HEX(C), (?IS_DIGIT(C) orelse (C >= $a andalso C =< $f) orelse (C >= $A andalso C =< $F))).
-define(IS_LETTER(C), ((C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z))).
-define(IS_SYNTAX(C), (C =:= $^ orelse C =:= $$ orelse C =:= $\\ orelse C =:= $. orelse C =:= $* orelse
                       C =:= $+ orelse C =:= $? orelse C =:= $( orelse C =:= $) orelse C =:= $[ orelse
                       C =:= $] orelse C =:= ${ orelse C =:= $} orelse C =:= $|)).

%% The tree of Pattern, its count of capturing groups, and the name of each
%% named group as [{Index, Name}], or {error, Message}.
-spec parse([non_neg_integer()], boolean(), boolean()) ->
          {ok, term(), non_neg_integer(), [{pos_integer(), [non_neg_integer()]}]} | {error, binary()}.
parse(_Source, true, true) ->
    {error, <<"Invalid regular expression flags">>};
parse(Source, U, V) ->
    {Total, HasNames} = prescan(Source, V, 0, false),
    P0 = #p{u = U orelse V, v = V, named = U orelse V orelse HasNames, total = Total},
    try
        {Node, Rest, P} = disjunction(Source, P0),
        Rest =:= [] orelse fail(case Rest of [$) | _] -> <<"Unmatched ')'">>; _ -> <<"Unexpected character">> end),
        Names = lists:reverse(P#p.names),
        [lists:keymember(Ref, 1, Names) orelse fail(<<"Invalid named capture referenced">>) || Ref <- P#p.refs],
        {ok, resolve(Node, Names), P#p.count, [{I, N} || {N, I, _} <- Names]}
    catch
        throw:{syntax, Message} -> {error, Message}
    end.

-spec fail(binary()) -> no_return().
fail(Message) -> throw({syntax, Message}).

%% The capturing groups of the pattern and whether it names any, from a scan
%% that skips escapes and classes.
prescan([$\\, _ | Rest], V, N, Named) -> prescan(Rest, V, N, Named);
prescan([$[ | Rest], V, N, Named) -> prescan(skip_class(Rest, V, 0), V, N, Named);
prescan([$(, $?, $<, C | Rest], V, N, _Named) when C =/= $=, C =/= $! -> prescan(Rest, V, N + 1, true);
prescan([$(, $? | Rest], V, N, Named) -> prescan(Rest, V, N, Named);
prescan([$( | Rest], V, N, Named) -> prescan(Rest, V, N + 1, Named);
prescan([_ | Rest], V, N, Named) -> prescan(Rest, V, N, Named);
prescan([], _V, N, Named) -> {N, Named}.

skip_class([$\\, _ | Rest], V, Depth) -> skip_class(Rest, V, Depth);
skip_class([$] | Rest], _V, 0) -> Rest;
skip_class([$] | Rest], V, Depth) -> skip_class(Rest, V, Depth - 1);
skip_class([$[ | Rest], true, Depth) -> skip_class(Rest, true, Depth + 1);
skip_class([_ | Rest], V, Depth) -> skip_class(Rest, V, Depth);
skip_class([], _V, _Depth) -> [].

%% \k<name> becomes a backreference to every group of that name.
resolve({named_backref, Name}, Names) -> {backref, [I || {N, I, _} <- Names, N =:= Name]};
resolve({seq, Nodes}, Names) -> {seq, [resolve(N, Names) || N <- Nodes]};
resolve({alt, Nodes}, Names) -> {alt, [resolve(N, Names) || N <- Nodes]};
resolve({group, I, Node}, Names) -> {group, I, resolve(Node, Names)};
resolve({mods, A, R, Node}, Names) -> {mods, A, R, resolve(Node, Names)};
resolve({repeat, Min, Max, G, Node, PI, PC}, Names) -> {repeat, Min, Max, G, resolve(Node, Names), PI, PC};
resolve({look, D, Pos, Node}, Names) -> {look, D, Pos, resolve(Node, Names)};
resolve(Node, _Names) -> Node.

%%% Disjunction, Alternative, Term

disjunction(S, P0) ->
    Id = P0#p.disjunctions,
    P1 = P0#p{disjunctions = Id + 1},
    Outer = P1#p.path,
    {Alternatives, S1, P2} = alternatives(S, P1, Id, 0, Outer, []),
    Node = case Alternatives of
        [One] -> One;
        Many -> {alt, Many}
    end,
    {Node, S1, P2#p{path = Outer}}.

alternatives(S, P, Id, N, Outer, Acc) ->
    {Terms, S1, P1} = terms(S, P#p{path = [{Id, N} | Outer]}, []),
    Node = case Terms of
        [] -> empty;
        [One] -> One;
        Many -> {seq, Many}
    end,
    case S1 of
        [$| | S2] -> alternatives(S2, P1, Id, N + 1, Outer, [Node | Acc]);
        _ -> {lists:reverse([Node | Acc]), S1, P1}
    end.

terms([], P, Acc) -> {lists:reverse(Acc), [], P};
terms([C | _] = S, P, Acc) when C =:= $|; C =:= $) -> {lists:reverse(Acc), S, P};
terms(S, P, Acc) ->
    {Term, S1, P1} = term(S, P),
    terms(S1, P1, [Term | Acc]).

term([$^ | S], P) -> no_quantifier(bol, S, P);
term([$$ | S], P) -> no_quantifier(eol, S, P);
term([$\\, $b | S], P) -> no_quantifier(word_boundary, S, P);
term([$\\, $B | S], P) -> no_quantifier(not_word_boundary, S, P);
term([$(, $?, $<, $= | S], P) -> lookaround(behind, true, S, P);
term([$(, $?, $<, $! | S], P) -> lookaround(behind, false, S, P);
term([$(, $?, $= | S], P) -> lookaround(ahead, true, S, P);
term([$(, $?, $! | S], P) -> lookaround(ahead, false, S, P);
term([C | _], _P) when C =:= $*; C =:= $+; C =:= $? -> fail(<<"Nothing to repeat">>);
term([${ | S] = All, P) ->
    case {P#p.u, braced(S)} of
        {true, _} -> fail(<<"Lone quantifier brackets">>);
        {false, {ok, _, _, _}} -> fail(<<"Nothing to repeat">>);
        {false, error} -> quantified({char, ${}, tl(All), P, P#p.count)
    end;
term(S, P) ->
    Before = P#p.count,
    {Atom, S1, P1} = atom(S, P),
    quantified(Atom, S1, P1, Before).

no_quantifier(Node, S, P) ->
    case quantifier(S, P) of
        none -> {Node, S, P};
        _ -> fail(<<"Nothing to repeat">>)
    end.

lookaround(Direction, Positive, S, P) ->
    Before = P#p.count,
    {Node, S1, P1} = group_body(S, P),
    Look = {look, Direction, Positive, Node},
    case Direction =:= ahead andalso not P#p.u of
        true -> quantified(Look, S1, P1, Before);
        false -> no_quantifier(Look, S1, P1)
    end.

quantified(Atom, S, P, Before) ->
    case quantifier(S, P) of
        none -> {Atom, S, P};
        {Min, Max, S1} ->
            {Greedy, S2} = case S1 of
                [$? | R] -> {false, R};
                _ -> {true, S1}
            end,
            {{repeat, Min, Max, Greedy, Atom, Before, P#p.count - Before}, S2, P}
    end.

quantifier([$* | S], _P) -> {0, infinity, S};
quantifier([$+ | S], _P) -> {1, infinity, S};
quantifier([$? | S], _P) -> {0, 1, S};
quantifier([${ | S], P) ->
    case braced(S) of
        {ok, Min, Max, _} when Max =/= infinity, Min > Max -> fail(<<"numbers out of order in {} quantifier">>);
        {ok, Min, Max, S1} -> {Min, Max, S1};
        error when P#p.u -> fail(<<"Incomplete quantifier">>);
        error -> none
    end;
quantifier(_S, _P) -> none.

%% The rest of a braced quantifier after {.
braced(S) ->
    case digits(S, none) of
        {none, _} -> error;
        {Min, [$} | R]} -> {ok, Min, Min, R};
        {Min, [$,, $} | R]} -> {ok, Min, infinity, R};
        {Min, [$, | R]} ->
            case digits(R, none) of
                {none, _} -> error;
                {Max, [$} | R1]} -> {ok, Min, Max, R1};
                _ -> error
            end;
        _ -> error
    end.

digits([C | S], Acc) when ?IS_DIGIT(C) ->
    digits(S, case Acc of none -> C - $0; _ -> Acc * 10 + C - $0 end);
digits(S, Acc) -> {Acc, S}.

%%% Atom

atom([$. | S], P) -> {dot, S, P};
atom([$(, $?, $: | S], P) -> group_body(S, P);
atom([$(, $?, $< | S], P) ->
    {Name, S1} = group_name(S, P),
    Index = P#p.count + 1,
    [fail(<<"Duplicate capture group name">>) || {N, _, Path} <- P#p.names, N =:= Name, might_both_participate(Path, P#p.path)],
    P1 = P#p{count = Index, names = [{Name, Index, P#p.path} | P#p.names]},
    {Node, S2, P2} = group_body(S1, P1),
    {{group, Index, Node}, S2, P2};
atom([$(, $? | S], P) -> modifiers(S, P);
atom([$( | S], P) ->
    Index = P#p.count + 1,
    {Node, S1, P1} = group_body(S, P#p{count = Index}),
    {{group, Index, Node}, S1, P1};
atom([$) | _], _P) -> fail(<<"Unmatched ')'">>);
atom([$[ | S], P) ->
    case P#p.v of
        true -> vclass(S, P);
        false -> class(S, P)
    end;
atom([$\\], _P) -> fail(<<"\\ at end of pattern">>);
atom([$\\ | S], P) -> atom_escape(S, P);
atom([C | S], P) when C =:= $]; C =:= $} ->
    case P#p.u of
        true -> fail(<<"Lone quantifier brackets">>);
        false -> {{char, C}, S, P}
    end;
atom([C | S], P) -> {{char, C}, S, P}.

group_body(S, P) ->
    case disjunction(S, P) of
        {Node, [$) | S1], P1} -> {Node, S1, P1};
        _ -> fail(<<"Unterminated group">>)
    end.

%% Two groups of one name are an error unless an alternative separates them:
%% their paths from the root first differ in the alternative of one disjunction.
might_both_participate([{D, A1} | _], [{D, A2} | _]) when A1 =/= A2 -> false;
might_both_participate(Path1, Path2) ->
    case common_suffix(lists:reverse(Path1), lists:reverse(Path2)) of
        {[{D, A1} | _], [{D, A2} | _]} when A1 =/= A2 -> false;
        _ -> true
    end.

common_suffix([X | R1], [X | R2]) -> common_suffix(R1, R2);
common_suffix(R1, R2) -> {R1, R2}.

%% (?ims-ims: Disjunction ), after (?.
modifiers(S, P) ->
    {Add, S1} = modifier_letters(S, []),
    {Remove, S2} = case S1 of
        [$- | R] ->
            {Rm, R1} = modifier_letters(R, []),
            Add =:= [] andalso Rm =:= [] andalso fail(<<"Invalid flag group">>),
            {Rm, R1};
        _ -> {[], S1}
    end,
    case S2 of
        [$: | S3] ->
            lists:any(fun(F) -> lists:member(F, Remove) end, Add) andalso fail(<<"Repeated flag in flag group">>),
            {Node, S4, P1} = group_body(S3, P),
            {{mods, Add, Remove, Node}, S4, P1};
        _ ->
            fail(<<"Invalid group">>)
    end.

modifier_letters([C | S], Acc) when C =:= $i; C =:= $m; C =:= $s ->
    lists:member(C, Acc) andalso fail(<<"Repeated flag in flag group">>),
    modifier_letters(S, [C | Acc]);
modifier_letters(S, Acc) -> {lists:reverse(Acc), S}.

%% GroupName after <: the name as code points, and the rest after >.
group_name(S, P) ->
    {First, S1} = identifier_char(S, P),
    is_identifier_start(First) orelse fail(<<"Invalid capture group name">>),
    group_name_rest(S1, P, [First]).

group_name_rest([$> | S], _P, Acc) -> {lists:reverse(Acc), S};
group_name_rest(S, P, Acc) ->
    {C, S1} = identifier_char(S, P),
    is_identifier_part(C) orelse fail(<<"Invalid capture group name">>),
    group_name_rest(S1, P, [C | Acc]).

identifier_char([$\\, $u | S], _P) ->
    case unicode_escape(S, true) of
        {ok, C, S1} -> {C, S1};
        error -> fail(<<"Invalid Unicode escape in capture group name">>)
    end;
identifier_char([H, L | S], #p{u = false}) when H >= 16#D800, H =< 16#DBFF, L >= 16#DC00, L =< 16#DFFF ->
    {16#10000 + ((H - 16#D800) bsl 10) + (L - 16#DC00), S};
identifier_char([C | S], _P) -> {C, S};
identifier_char([], _P) -> fail(<<"Invalid capture group name">>).

is_identifier_start(C) when C =:= $$; C =:= $_ -> true;
is_identifier_start(C) when ?IS_LETTER(C) -> true;
is_identifier_start(C) when C < 128 -> false;
is_identifier_start(C) -> buoy_regexp_charset:has_property(<<"ID_Start">>, C).

is_identifier_part(C) when C =:= $$; C =:= $_; C =:= 16#200C; C =:= 16#200D -> true;
is_identifier_part(C) when ?IS_LETTER(C); ?IS_DIGIT(C) -> true;
is_identifier_part(C) when C < 128 -> false;
is_identifier_part(C) -> buoy_regexp_charset:has_property(<<"ID_Continue">>, C).

%%% Escapes

atom_escape([C | S], P) when C >= $1, C =< $9 ->
    {N, S1} = digits([C | S], none),
    case N =< P#p.total of
        true -> {{backref, [N]}, S1, P};
        false when P#p.u -> fail(<<"Invalid escape">>);
        false -> {{char, legacy_digit_escape([C | S])}, legacy_rest([C | S]), P}
    end;
atom_escape([$k | S], #p{named = true} = P) ->
    case S of
        [$< | S1] ->
            {Name, S2} = group_name(S1, P),
            {{named_backref, Name}, S2, P#p{refs = [Name | P#p.refs]}};
        _ -> fail(<<"Invalid named reference">>)
    end;
atom_escape([C | S], P) when C =:= $d; C =:= $D; C =:= $s; C =:= $S; C =:= $w; C =:= $W ->
    {{escape, class_escape(C)}, S, P};
atom_escape([C | S], #p{u = true} = P) when C =:= $p; C =:= $P ->
    {Escape, S1} = property_escape(C =:= $P, S, P),
    {{escape, Escape}, S1, P};
atom_escape([$c | _] = S, #p{u = false} = P) ->
    case S of
        [$c, L | S1] when ?IS_LETTER(L) -> {{char, L rem 32}, S1, P};
        _ -> {{char, $\\}, S, P}
    end;
atom_escape(S, P) ->
    {C, S1} = character_escape(S, P),
    {{char, C}, S1, P}.

class_escape($d) -> digit;
class_escape($D) -> not_digit;
class_escape($s) -> space;
class_escape($S) -> not_space;
class_escape($w) -> word;
class_escape($W) -> not_word.

%% CharacterEscape after \: the character value and the rest.
character_escape([$f | S], _P) -> {12, S};
character_escape([$n | S], _P) -> {10, S};
character_escape([$r | S], _P) -> {13, S};
character_escape([$t | S], _P) -> {9, S};
character_escape([$v | S], _P) -> {11, S};
character_escape([$c, L | S], _P) when ?IS_LETTER(L) -> {L rem 32, S};
character_escape([$0, D | _], #p{u = true}) when ?IS_DIGIT(D) -> fail(<<"Invalid decimal escape">>);
character_escape([$0, D | _] = S, #p{u = false}) when ?IS_OCTAL(D) -> {legacy_octal(S), legacy_rest(S)};
character_escape([$0 | S], _P) -> {0, S};
character_escape([D | _] = S, #p{u = false}) when D >= $1, D =< $9 -> {legacy_digit_escape(S), legacy_rest(S)};
character_escape([$x, A, B | S], _P) when ?IS_HEX(A), ?IS_HEX(B) -> {hex([A, B]), S};
character_escape([$u | S], P) ->
    case unicode_escape(S, P#p.u) of
        {ok, C, S1} -> {C, S1};
        error when P#p.u -> fail(<<"Invalid Unicode escape">>);
        error -> {$u, S}
    end;
character_escape([C | S], #p{u = true}) when ?IS_SYNTAX(C); C =:= $/ -> {C, S};
character_escape([_ | _], #p{u = true}) -> fail(<<"Invalid escape">>);
character_escape([$c | _], _P) -> fail(<<"Invalid escape">>);
character_escape([$k | _], #p{named = true}) -> fail(<<"Invalid escape">>);
character_escape([C | S], _P) -> {C, S};
character_escape([], _P) -> fail(<<"\\ at end of pattern">>).

%% \8 and \9 are themselves; \1 to \7 start a legacy octal escape.
legacy_digit_escape([D | _]) when D =:= $8; D =:= $9 -> D;
legacy_digit_escape(S) -> legacy_octal(S).

%% LegacyOctalEscapeSequence: up to three octal digits with a value up to 0o377.
legacy_octal([A, B, C | _]) when A =< $3, ?IS_OCTAL(B), ?IS_OCTAL(C) -> (A - $0) * 64 + (B - $0) * 8 + C - $0;
legacy_octal([A, B | _]) when ?IS_OCTAL(A), ?IS_OCTAL(B) -> (A - $0) * 8 + B - $0;
legacy_octal([A | _]) -> A - $0.

legacy_rest([D | S]) when D =:= $8; D =:= $9 -> S;
legacy_rest([A, B, C | S]) when A =< $3, ?IS_OCTAL(A), ?IS_OCTAL(B), ?IS_OCTAL(C) -> S;
legacy_rest([A, B | S]) when ?IS_OCTAL(A), ?IS_OCTAL(B) -> S;
legacy_rest([_ | S]) -> S.

hex(Digits) -> list_to_integer(Digits, 16).

%% RegExpUnicodeEscapeSequence after \u. With UnicodeMode: \u{CodePoint} and a
%% surrogate pair of two escapes.
unicode_escape([${ | S], true) ->
    {Digits, S1} = lists:splitwith(fun(C) -> ?IS_HEX(C) end, S),
    case {Digits, S1} of
        {[_ | _], [$} | S2]} ->
            C = hex(Digits),
            case C =< 16#10FFFF of
                true -> {ok, C, S2};
                false -> error
            end;
        _ -> error
    end;
unicode_escape([A, B, C, D | S], Unicode) when ?IS_HEX(A), ?IS_HEX(B), ?IS_HEX(C), ?IS_HEX(D) ->
    Lead = hex([A, B, C, D]),
    case {Unicode, S} of
        {true, [$\\, $u, E, F, G, H | S1]} when Lead >= 16#D800, Lead =< 16#DBFF,
                                               ?IS_HEX(E), ?IS_HEX(F), ?IS_HEX(G), ?IS_HEX(H) ->
            Trail = hex([E, F, G, H]),
            case Trail >= 16#DC00 andalso Trail =< 16#DFFF of
                true -> {ok, 16#10000 + ((Lead - 16#D800) bsl 10) + (Trail - 16#DC00), S1};
                false -> {ok, Lead, S}
            end;
        _ -> {ok, Lead, S}
    end;
unicode_escape(_S, _Unicode) -> error.

%% \p{...} or \P{...} after the letter: the escape and the rest.
property_escape(Negated, [${ | S], P) ->
    {Text, S1} = lists:splitwith(fun(C) -> C =/= $} end, S),
    S1 =:= [] andalso fail(<<"Invalid property name">>),
    lists:all(fun(C) -> ?IS_LETTER(C) orelse ?IS_DIGIT(C) orelse C =:= $_ orelse C =:= $= end, Text)
        orelse fail(<<"Invalid property name">>),
    Escape = case string:split(Text, "=") of
        [Name, Value] -> {property, property_key(Name, Value), Negated};
        [Lone] -> lone_property(Lone, Negated, P)
    end,
    {Escape, tl(S1)};
property_escape(_Negated, _S, _P) ->
    fail(<<"Invalid property name">>).

property_key(Name, Value) ->
    V = list_to_binary(Value),
    Key = case Name of
        N when N =:= "General_Category"; N =:= "gc" -> prefixed(<<"gc=">>, buoy_regexp_unicode:general_category(V));
        N when N =:= "Script"; N =:= "sc" -> prefixed(<<"sc=">>, buoy_regexp_unicode:script(V));
        N when N =:= "Script_Extensions"; N =:= "scx" -> prefixed(<<"scx=">>, buoy_regexp_unicode:script(V));
        _ -> false
    end,
    Key =/= false orelse fail(<<"Invalid property name">>),
    Key.

prefixed(_Prefix, false) -> false;
prefixed(Prefix, Value) -> <<Prefix/binary, Value/binary>>.

lone_property(Lone, Negated, P) ->
    Name = list_to_binary(Lone),
    case {buoy_regexp_unicode:general_category(Name), buoy_regexp_unicode:binary_property(Name)} of
        {false, false} ->
            case P#p.v andalso buoy_regexp_charset:is_string_property(Name) of
                true when Negated -> fail(<<"Invalid property name">>);
                true -> {strings, Name};
                false -> fail(<<"Invalid property name">>)
            end;
        {false, Key} -> {property, Key, Negated};
        {Gc, _} -> {property, <<"gc=", Gc/binary>>, Negated}
    end.

%%% Character classes without v

class([$^ | S], P) -> class_ranges(S, P, true, []);
class(S, P) -> class_ranges(S, P, false, []).

class_ranges([$] | S], P, Negated, Acc) -> {{class, Negated, lists:reverse(Acc)}, S, P};
class_ranges([], _P, _Negated, _Acc) -> fail(<<"Unterminated character class">>);
class_ranges(S, P, Negated, Acc) ->
    {A, S1} = class_atom(S, P),
    case S1 of
        [$-, C | _] when C =/= $] ->
            {B, S2} = class_atom(tl(S1), P),
            class_ranges(S2, P, Negated, [range(A, B, P) | Acc]);
        _ ->
            class_ranges(S1, P, Negated, [A | Acc])
    end.

range({char, A}, {char, B}, _P) when A > B -> fail(<<"Range out of order in character class">>);
range({char, A}, {char, B}, _P) -> {range, A, B};
range(_A, _B, #p{u = true}) -> fail(<<"Invalid character class">>);
range(A, B, _P) -> {union, [A, {char, $-}, B]}.

class_atom([$\\], _P) -> fail(<<"\\ at end of pattern">>);
class_atom([$\\ | S], P) -> class_atom_escape(S, P);
class_atom([C | S], _P) -> {{char, C}, S}.

class_atom_escape([$b | S], _P) -> {{char, 8}, S};
class_atom_escape([$- | S], #p{u = true}) -> {{char, $-}, S};
class_atom_escape([$c, C | S], #p{u = false}) when ?IS_DIGIT(C); C =:= $_ -> {{char, C rem 32}, S};
class_atom_escape([$c, L | S], _P) when ?IS_LETTER(L) -> {{char, L rem 32}, S};
class_atom_escape([$c | _] = S, #p{u = false}) -> {{char, $\\}, S};
class_atom_escape([C | S], _P) when C =:= $d; C =:= $D; C =:= $s; C =:= $S; C =:= $w; C =:= $W ->
    {{escape, class_escape(C)}, S};
class_atom_escape([C | S], #p{u = true} = P) when C =:= $p; C =:= $P ->
    {Escape, S1} = property_escape(C =:= $P, S, P),
    {{escape, Escape}, S1};
class_atom_escape(S, P) ->
    {C, S1} = character_escape(S, P),
    {{char, C}, S1}.

%%% Character classes with v: ClassSetExpression
%%
%% A SetExpr is {union, [Item]}, {intersection, [Operand]}, or
%% {subtraction, [Operand]}. An Operand is {char, C}, {nested, Negated, SetExpr},
%% {escape, Escape}, or {strings, [[C]]}; a union also holds {range, A, B}.

vclass([$^ | S], P) ->
    {Expr, S1} = class_set_expression(S, P),
    has_strings(Expr) andalso fail(<<"Negated character class may contain strings">>),
    {{vclass, true, Expr}, S1, P};
vclass(S, P) ->
    {Expr, S1} = class_set_expression(S, P),
    {{vclass, false, Expr}, S1, P}.

%% The expression up to and after the closing ].
class_set_expression([$] | S], _P) -> {{union, []}, S};
class_set_expression(S, P) ->
    {First, S1} = class_set_item(S, P),
    case S1 of
        [$&, $& | _] when element(1, First) =/= range -> class_set_chain(S1, P, intersection, "&&", [First]);
        [$-, $- | _] when element(1, First) =/= range -> class_set_chain(S1, P, subtraction, "--", [First]);
        _ -> class_union(S1, P, [First])
    end.

class_union([$] | S], _P, Acc) -> {{union, lists:reverse(Acc)}, S};
class_union([$&, $& | _], _P, _Acc) -> fail(<<"Invalid set operation in character class">>);
class_union([$-, $- | _], _P, _Acc) -> fail(<<"Invalid set operation in character class">>);
class_union([], _P, _Acc) -> fail(<<"Unterminated character class">>);
class_union(S, P, Acc) ->
    {Item, S1} = class_set_item(S, P),
    class_union(S1, P, [Item | Acc]).

class_set_chain([$] | S], _P, Kind, _Op, Acc) -> {{Kind, lists:reverse(Acc)}, S};
class_set_chain([Op1, Op2 | S], P, Kind, [Op1, Op2] = Op, Acc) ->
    case S of
        [$& | _] when Kind =:= intersection -> fail(<<"Invalid set operation in character class">>);
        _ -> ok
    end,
    {Operand, S1} = class_set_operand(S, P),
    class_set_chain(S1, P, Kind, Op, [Operand | Acc]);
class_set_chain([], _P, _Kind, _Op, _Acc) -> fail(<<"Unterminated character class">>);
class_set_chain(_S, _P, _Kind, _Op, _Acc) -> fail(<<"Invalid set operation in character class">>).

%% A ClassSetRange or a ClassSetOperand.
class_set_item(S, P) ->
    case class_set_operand(S, P) of
        {{char, A}, [$-, C | _] = S1} when C =/= $- ->
            case class_set_character(tl(S1), P) of
                {B, _} when A > B -> fail(<<"Range out of order in character class">>);
                {B, S2} -> {{range, A, B}, S2}
            end;
        Result -> Result
    end.

class_set_operand([$[, $^ | S], P) ->
    {Expr, S1} = class_set_expression(S, P),
    has_strings(Expr) andalso fail(<<"Negated character class may contain strings">>),
    {{nested, true, Expr}, S1};
class_set_operand([$[ | S], P) ->
    {Expr, S1} = class_set_expression(S, P),
    {{nested, false, Expr}, S1};
class_set_operand([$\\, C | S], _P) when C =:= $d; C =:= $D; C =:= $s; C =:= $S; C =:= $w; C =:= $W ->
    {{escape, class_escape(C)}, S};
class_set_operand([$\\, C | S], P) when C =:= $p; C =:= $P ->
    {Escape, S1} = property_escape(C =:= $P, S, P),
    {{escape, Escape}, S1};
class_set_operand([$\\, $q, ${ | S], P) -> class_strings(S, P, [], []);
class_set_operand(S, P) ->
    {C, S1} = class_set_character(S, P),
    {{char, C}, S1}.

class_strings([$} | S], _P, Current, Acc) -> {{strings, lists:reverse([lists:reverse(Current) | Acc])}, S};
class_strings([$| | S], P, Current, Acc) -> class_strings(S, P, [], [lists:reverse(Current) | Acc]);
class_strings([], _P, _Current, _Acc) -> fail(<<"Unterminated class string disjunction">>);
class_strings(S, P, Current, Acc) ->
    {C, S1} = class_set_character(S, P),
    class_strings(S1, P, [C | Current], Acc).

class_set_character([$\\, $b | S], _P) -> {8, S};
class_set_character([$\\, C | S], _P) when C =:= $&; C =:= $-; C =:= $!; C =:= $#; C =:= $%; C =:= $,; C =:= $:;
                                           C =:= $;; C =:= $<; C =:= $=; C =:= $>; C =:= $@; C =:= $`; C =:= $~ ->
    {C, S};
class_set_character([$\\], _P) -> fail(<<"\\ at end of pattern">>);
class_set_character([$\\ | S], P) -> character_escape(S, P);
class_set_character([C, C | _], _P) when C =:= $&; C =:= $!; C =:= $#; C =:= $$; C =:= $%; C =:= $*; C =:= $+;
                                         C =:= $,; C =:= $.; C =:= $:; C =:= $;; C =:= $<; C =:= $=; C =:= $>;
                                         C =:= $?; C =:= $@; C =:= $^; C =:= $`; C =:= $~ ->
    fail(<<"Invalid set operation in character class">>);
class_set_character([C | _], _P) when C =:= $(; C =:= $); C =:= $[; C =:= $]; C =:= ${; C =:= $}; C =:= $/;
                                      C =:= $-; C =:= $| ->
    fail(<<"Invalid character in character class">>);
class_set_character([C | S], _P) -> {C, S};
class_set_character([], _P) -> fail(<<"Unterminated character class">>).

%% MayContainStrings of a SetExpr or an operand.
-spec has_strings(term()) -> boolean().
has_strings({union, Items}) -> lists:any(fun has_strings/1, Items);
has_strings({intersection, Operands}) -> lists:all(fun has_strings/1, Operands);
has_strings({subtraction, [First | _]}) -> has_strings(First);
has_strings({nested, false, Expr}) -> has_strings(Expr);
has_strings({escape, {strings, _}}) -> true;
has_strings({strings, Strings}) -> lists:any(fun(S) -> length(S) =/= 1 end, Strings);
has_strings(_) -> false.
