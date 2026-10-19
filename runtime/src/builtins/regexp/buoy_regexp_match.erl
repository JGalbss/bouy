%% The matcher of the RegExp engine: compiles the tree of buoy_regexp_syntax
%% into the Matcher closures of ECMA-262 22.2.2 and runs them.
%%
%% A Matcher is fun(Input, Index, Captures, Continue) -> {End, Captures} | false,
%% and Continue is fun(Index, Captures) -> {End, Captures} | false, as the spec
%% writes them: backtracking returns false to the last choice point. Input is
%% {Binary, Width, Length}, the units of a string of buoy_ref_string (Width 1
%% for a one-byte string, 2 for a two-byte one). Indexes count code units. With
%% the u or v flag a character is a code point, so a surrogate pair is read as
%% one, and every index stays on a character boundary. Captures is a tuple
%% with one element per group: undefined or {Start, End}.
%%
%% A node without choice points compiles to a step instead,
%% fun(Input, Index) -> NewIndex | false: characters, literals, classes, and
%% assertions. Steps run without continuations, and a quantified step backtracks
%% in a loop over its positions rather than in nested calls.
-module(buoy_regexp_match).

-export([compile/3, search/4, search_all/3, input/1]).

-export_type([program/0]).

-record(c, {i :: boolean(), m :: boolean(), s :: boolean(), u :: boolean(), v :: boolean(),
            dir = forward :: forward | backward}).

-type program() :: #{matcher := fun(), groups := non_neg_integer(), unicode := boolean(), first := first()}
                 | #{native := reference(), groups := non_neg_integer(), unicode := boolean()}.
%% What every match starts with: a literal run of code units, a character that
%% passes a test, or anything.
-type first() :: {literal, binary() | none, binary()} | {test, fun((non_neg_integer()) -> boolean())} | any.

%% The Matcher of a pattern tree, for the flags i, m, s, u, and v: the program of the
%% native matcher of buoy_nif when it loads, else the closures of this module.
-spec compile(term(), non_neg_integer(), map()) -> program().
compile(Tree, Groups, #{i := I, m := M, s := S, u := U, v := V}) ->
    C = #c{i = I, m = M, s = S, u = U orelse V, v = V},
    case native(Tree, Groups, C) of
        {ok, Native} -> #{native => Native, groups => Groups, unicode => U orelse V};
        error ->
            {cps, Matcher} = to_cps(node(Tree, C)),
            #{matcher => Matcher, groups => Groups, unicode => U orelse V, first => first(Tree, C)}
    end.

%%% The native matcher
%%
%% lower/2 turns the tree into the tree of crates/buoy-nif/src/regexp.rs, with each
%% character, class, and escape resolved to its CharSet by the functions of this module,
%% so the sets keep one source:
%%
%%   empty | {set, Ranges} | {literal, Units} | {seq, [Node]} | {alt, [Node]}
%%   {group, Index, Node} | {repeat, Min, Max | infinity, Greedy, Node, ParenIndex, ParenCount}
%%   {bol, Multiline} | {eol, Multiline} | {boundary, Wanted, WordRanges}
%%   {look, Ahead, Positive, Node} | {backref, [Index], none | [{Char, Canonical}]}
%%
%% A set holds code units without u or v, and code points with them. The native matcher
%% runs the same algorithm as the closures, in time slices.

native(Tree, Groups, C) ->
    case buoy_nif:available() of
        true -> buoy_nif:regexp_compile(lower(Tree, C), Groups, C#c.u);
        false -> error
    end.

lower(empty, _C) -> empty;
lower({char, Ch}, #c{i = false}) -> {set, [{Ch, Ch}]};
lower({char, Ch}, C) -> {set, closure([{Ch, Ch}], C)};
lower({literal, Chars}, #c{u = U} = C) ->
    case U andalso lists:any(fun(X) -> X >= 16#D800 andalso X =< 16#DFFF end, Chars) of
        true -> {seq, [lower({char, X}, C) || X <- Chars]};
        false when U -> {literal, lists:flatmap(fun to_units/1, Chars)};
        false -> {literal, Chars}
    end;
lower(dot, #c{s = true} = C) -> {set, [{0, max_char(C)}]};
lower(dot, C) -> {set, buoy_regexp_charset:complement([{10, 10}, {13, 13}, {16#2028, 16#2029}], max_char(C))};
lower({class, Negated, Items}, C) -> {set, lower_set(class_set(Items, C), Negated, C)};
lower({vclass, Negated, Expr}, C) ->
    {Ranges, Strings} = set_expression(Expr, C),
    case Negated of
        true -> lower_strings(complement(Ranges, C), [], C);
        false -> lower_strings(Ranges, Strings, C)
    end;
lower({escape, Escape}, #c{v = true} = C) ->
    {Ranges, Strings} = escape_set(Escape, C),
    lower_strings(Ranges, Strings, C);
lower({escape, Escape}, C) -> {set, lower_set(escape_ranges(Escape, C), false, C)};
lower({seq, Nodes}, C) -> {seq, [lower(N, C) || N <- literals(Nodes, C)]};
lower({alt, Nodes}, C) -> {alt, [lower(N, C) || N <- Nodes]};
lower({group, Index, Node}, C) -> {group, Index, lower(Node, C)};
lower({mods, Add, Remove, Node}, C) -> lower(Node, modify(C, Add, Remove));
lower({repeat, Min, Max, Greedy, Node, ParenIndex, ParenCount}, C) ->
    {repeat, Min, Max, Greedy, lower(Node, C), ParenIndex, ParenCount};
lower(bol, C) -> {bol, C#c.m};
lower(eol, C) -> {eol, C#c.m};
lower(word_boundary, C) -> {boundary, true, word(C)};
lower(not_word_boundary, C) -> {boundary, false, word(C)};
lower({look, Direction, Positive, Node}, C) -> {look, Direction =:= ahead, Positive, lower(Node, C)};
lower({backref, Indexes}, C) -> {backref, Indexes, canonical_table(C)}.

%% The set of set_node/3.
lower_set(Ranges, false, C) -> closure(Ranges, C);
lower_set(Ranges, true, C) -> buoy_regexp_charset:complement(closure(Ranges, C), max_char(C)).

%% The node of strings_node/3.
lower_strings(Ranges, [], C) -> {set, closure(Ranges, C)};
lower_strings(Ranges, Strings, C) ->
    Sorted = lists:sort(fun(A, B) -> length(A) >= length(B) end, [S || S <- Strings, S =/= []]),
    Literals = [{seq, [lower({char, X}, C) || X <- S]} || S <- Sorted],
    Empty = [empty || lists:member([], Strings)],
    {alt, Literals ++ [{set, closure(Ranges, C)}] ++ Empty}.

%% The Canonicalize of a backreference with i, as the pairs of each character that
%% another character shares its canonical value with.
canonical_table(#c{i = false}) -> none;
canonical_table(#c{u = true}) -> [{X, Canonical} || {Canonical, Members} <- buoy_regexp_unicode:scf_classes(), X <- Members];
canonical_table(#c{u = false}) -> [{X, Canonical} || {Canonical, Members} <- buoy_regexp_unicode:upper_classes(), X <- Members].

%% The input of a string of buoy_ref_string.
-spec input(buoy_ref_string:js_string()) -> {binary(), 1 | 2, non_neg_integer()}.
input(B) when is_binary(B) -> {B, 1, byte_size(B)};
input({'$u16', B}) -> {B, 2, byte_size(B) div 2}.

%% The first match at or after LastIndex, or only at LastIndex when Sticky:
%% {match, Index, End, Captures} or nomatch. Index is the LastIndex of the
%% attempt that matched (22.2.7.2 RegExpBuiltinExec); with a Unicode flag the
%% matcher starts at the character that holds it. Without Sticky, the scan
%% skips the positions where the first character of a match cannot be.
-spec search(program(), {binary(), 1 | 2, non_neg_integer()}, non_neg_integer(), boolean()) ->
          {match, non_neg_integer(), non_neg_integer(), tuple()} | nomatch.
search(#{native := Native}, {B, W, _}, From, Sticky) ->
    native_search(Native, B, W =:= 2, From, Sticky, start);
search(#{matcher := F, groups := Groups, unicode := Unicode, first := First}, In, From, Sticky) ->
    Skip = case Sticky of
        true -> any;
        false -> First
    end,
    attempt(F, Skip, In, From, Sticky, Unicode, erlang:make_tuple(Groups, undefined)).

%% Every match from index 0, as the loops of Symbol.match and Symbol.replace with g find
%% them: after an empty match the next search starts one character on.
-spec search_all(program(), {binary(), 1 | 2, non_neg_integer()}, boolean()) ->
          [{match, non_neg_integer(), non_neg_integer(), tuple()}].
search_all(#{native := Native}, {B, W, _}, Sticky) -> native_all(Native, B, W =:= 2, Sticky, start, []);
search_all(#{unicode := Unicode} = Program, In, Sticky) -> all(Program, In, Unicode, Sticky, 0, []).

all(Program, {_, _, L} = In, Unicode, Sticky, LastIndex, Acc) when LastIndex =< L ->
    case search(Program, In, LastIndex, Sticky) of
        nomatch -> lists:reverse(Acc);
        {match, Index, End, _} = Match ->
            Next = case End =< Index of
                true -> advance(In, End, Unicode);
                false -> End
            end,
            all(Program, In, Unicode, Sticky, Next, [Match | Acc])
    end;
all(_Program, _In, _Unicode, _Sticky, _LastIndex, Acc) -> lists:reverse(Acc).

native_all(Native, B, Wide, Sticky, State, Acc) ->
    case buoy_nif:regexp_search_all(Native, B, Wide, Sticky, State) of
        {done, Matches} -> lists:append(lists:reverse([Matches | Acc]));
        {more, Paused, Matches} -> native_all(Native, B, Wide, Sticky, Paused, [Matches | Acc]);
        overflow -> buoy_heap:throw_error('RangeError', <<"Maximum call stack size exceeded">>)
    end.

%% The native matcher runs in time slices and returns its state when a slice ends.
native_search(Native, B, Wide, From, Sticky, State) ->
    case buoy_nif:regexp_search(Native, B, Wide, From, Sticky, State) of
        {more, Paused} -> native_search(Native, B, Wide, From, Sticky, Paused);
        overflow -> buoy_heap:throw_error('RangeError', <<"Maximum call stack size exceeded">>);
        Found -> Found
    end.

attempt(F, First, {_, _, L} = In, I0, Sticky, Unicode, Caps0) when I0 =< L ->
    case candidate(First, In, I0, Unicode) of
        none -> nomatch;
        I ->
            Start = case Unicode of
                true -> character_start(In, I);
                false -> I
            end,
            case F(In, Start, Caps0, fun done/2) of
                {End, Caps} -> {match, I, End, Caps};
                false when Sticky -> nomatch;
                false -> attempt(F, First, In, advance(In, I, Unicode), Sticky, Unicode, Caps0)
            end
    end;
attempt(_F, _First, _In, _I, _Sticky, _Unicode, _Caps0) ->
    nomatch.

%% The first position at or after I where a match may start, or none.
candidate(any, _In, I, _Unicode) -> I;
candidate({test, Test}, {B, W, L} = In, I, Unicode) when I < L ->
    Char = case Unicode of
        true -> element(1, char_at(In, character_start(In, I)));
        false -> unit(B, W, I)
    end,
    case Test(Char) of
        true -> I;
        false -> candidate({test, Test}, In, advance(In, I, Unicode), Unicode)
    end;
candidate({test, _}, _In, _I, _Unicode) -> none;
candidate({literal, none, _Wide}, {_, 1, _}, _I, _Unicode) -> none;
candidate({literal, Narrow, _Wide}, {B, 1, L}, I, _Unicode) ->
    case binary:match(B, Narrow, [{scope, {I, L - I}}]) of
        nomatch -> none;
        {Pos, _} -> Pos
    end;
candidate({literal, _Narrow, Wide} = First, {B, 2, L} = In, I, Unicode) ->
    case binary:match(B, Wide, [{scope, {2 * I, 2 * (L - I)}}]) of
        nomatch -> none;
        {Pos, _} when Pos rem 2 =:= 0 -> Pos div 2;
        {Pos, _} -> candidate(First, In, Pos div 2 + 1, Unicode)
    end.

%% What a match of the tree starts with: a literal run without i, else the
%% test of a first character that the pattern requires.
first(Tree, C) ->
    case literal_prefix(Tree, C) of
        Units when length(Units) >= 2 ->
            Narrow = case lists:all(fun(X) -> X =< 16#FF end, Units) of
                true -> list_to_binary(Units);
                false -> none
            end,
            {literal, Narrow, << <<X:16>> || X <- Units >>};
        _ -> first_test(Tree, C)
    end.

literal_prefix({seq, Nodes}, #c{i = false, u = U}) ->
    Chars = lists:takewhile(fun({char, _}) -> true; (_) -> false end, Nodes),
    Codes = [X || {char, X} <- Chars],
    case U andalso lists:any(fun(X) -> X >= 16#D800 andalso X =< 16#DFFF end, Codes) of
        true -> [];
        false when U -> lists:flatmap(fun to_units/1, Codes);
        false -> Codes
    end;
literal_prefix(_Tree, _C) -> [].

first_test({seq, [Node | _]}, C) -> first_test(Node, C);
first_test({group, _, Node}, C) -> first_test(Node, C);
first_test({repeat, Min, _, _, Node, _, _}, C) when Min >= 1 -> first_test(Node, C);
first_test({mods, Add, Remove, Node}, C) -> first_test(Node, modify(C, Add, Remove));
first_test({alt, Nodes}, C) ->
    Tests = [first_test(N, C) || N <- Nodes],
    case lists:member(any, Tests) of
        true -> any;
        false ->
            Funs = [T || {test, T} <- Tests],
            {test, fun(X) -> lists:any(fun(T) -> T(X) end, Funs) end}
    end;
first_test(Node, C) when element(1, Node) =:= char; element(1, Node) =:= class; element(1, Node) =:= vclass;
                         element(1, Node) =:= escape; Node =:= dot ->
    case node(Node, C) of
        {char, Test, _} -> {test, Test};
        _ -> any
    end;
first_test(_Node, _C) -> any.

done(I, Caps) -> {I, Caps}.

%% AdvanceStringIndex.
advance({B, W, L}, I, true) when I + 1 < L ->
    case is_high(unit(B, W, I)) andalso is_low(unit(B, W, I + 1)) of
        true -> I + 2;
        false -> I + 1
    end;
advance(_In, I, _Unicode) -> I + 1.

%% The index of the character that holds the code unit at I.
character_start({B, W, L}, I) when I > 0, I < L ->
    case is_low(unit(B, W, I)) andalso is_high(unit(B, W, I - 1)) of
        true -> I - 1;
        false -> I
    end;
character_start(_In, I) -> I.

%%% Reading the input

unit(B, 1, I) -> binary:at(B, I);
unit(B, 2, I) ->
    <<_:I/binary-unit:16, U:16, _/binary>> = B,
    U.

is_high(U) -> U >= 16#D800 andalso U =< 16#DBFF.
is_low(U) -> U >= 16#DC00 andalso U =< 16#DFFF.

pair(H, L) -> 16#10000 + ((H - 16#D800) bsl 10) + (L - 16#DC00).

%% The code point at I, I < Length, and the index after it.
char_at({B, 1, _}, I) -> {binary:at(B, I), I + 1};
char_at({B, 2, L}, I) ->
    U = unit(B, 2, I),
    case is_high(U) andalso I + 1 < L of
        true ->
            V = unit(B, 2, I + 1),
            case is_low(V) of
                true -> {pair(U, V), I + 2};
                false -> {U, I + 1}
            end;
        false -> {U, I + 1}
    end.

%% The code point that ends at I, I > 0, and the index before it.
char_before({B, 1, _}, I) -> {binary:at(B, I - 1), I - 1};
char_before({B, 2, _}, I) ->
    U = unit(B, 2, I - 1),
    case is_low(U) andalso I >= 2 of
        true ->
            V = unit(B, 2, I - 2),
            case is_high(V) of
                true -> {pair(V, U), I - 2};
                false -> {U, I - 1}
            end;
        false -> {U, I - 1}
    end.

is_line_terminator(C) -> C =:= 10 orelse C =:= 13 orelse C =:= 16#2028 orelse C =:= 16#2029.

%%% Nodes
%%
%% A compiled node is {step, Step}, {char, Test, Step} for a step of one
%% character, or {cps, Matcher}.

node(empty, _C) -> {step, fun(_In, I) -> I end};
node({char, Ch}, #c{i = false} = C) -> char_node(fun(X) -> X =:= Ch end, C);
node({char, Ch}, C) -> char_node(buoy_regexp_charset:test(closure([{Ch, Ch}], C)), C);
node({literal, Chars}, C) -> literal(Chars, C);
node(dot, #c{s = true} = C) -> char_node(fun(_) -> true end, C);
node(dot, C) -> char_node(fun(X) -> not is_line_terminator(X) end, C);
node({class, Negated, Items}, C) -> set_node(class_set(Items, C), Negated, C);
node({vclass, Negated, Expr}, C) ->
    {Ranges, Strings} = set_expression(Expr, C),
    case Negated of
        true -> strings_node(complement(Ranges, C), [], C);
        false -> strings_node(Ranges, Strings, C)
    end;
node({escape, Escape}, #c{v = true} = C) ->
    {Ranges, Strings} = escape_set(Escape, C),
    strings_node(Ranges, Strings, C);
node({escape, Escape}, C) -> set_node(escape_ranges(Escape, C), false, C);
node({seq, Nodes}, C) -> sequence(Nodes, C);
node({alt, Nodes}, C) -> alternatives([node(N, C) || N <- Nodes], C);
node({group, Index, Node}, C) -> group(Index, node(Node, C), C#c.dir);
node({mods, Add, Remove, Node}, C) -> node(Node, modify(C, Add, Remove));
node({repeat, Min, Max, Greedy, Node, ParenIndex, ParenCount}, C) ->
    repeat(Min, Max, Greedy, node(Node, C), ParenIndex, ParenCount, C);
node(bol, C) -> {step, bol(C)};
node(eol, C) -> {step, eol(C)};
node(word_boundary, C) -> {step, boundary(true, C)};
node(not_word_boundary, C) -> {step, boundary(false, C)};
node({look, ahead, Positive, Node}, C) -> look(Positive, node(Node, C#c{dir = forward}));
node({look, behind, Positive, Node}, C) -> look(Positive, node(Node, C#c{dir = backward}));
node({backref, Indexes}, C) -> backref(Indexes, C).

%% UpdateModifiers.
modify(C, Add, Remove) ->
    Flag = fun(F, Old) ->
                   case {lists:member(F, Remove), lists:member(F, Add)} of
                       {true, _} -> false;
                       {_, true} -> true;
                       _ -> Old
                   end
           end,
    C#c{i = Flag($i, C#c.i), m = Flag($m, C#c.m), s = Flag($s, C#c.s)}.

to_cps({cps, _} = Node) -> Node;
to_cps({char, _, Step}) -> to_cps({step, Step});
to_cps({step, Step}) ->
    {cps, fun(In, I, Caps, K) ->
                  case Step(In, I) of
                      false -> false;
                      I2 -> K(I2, Caps)
                  end
          end}.

step_of({step, Step}) -> Step;
step_of({char, _, Step}) -> Step.

is_step({cps, _}) -> false;
is_step(_) -> true.

%%% Characters

char_node(Test, C) -> {char, Test, char_step(Test, C)}.

char_step(Test, #c{u = false, dir = forward}) ->
    fun({B, W, L}, I) when I < L ->
            case Test(unit(B, W, I)) of
                true -> I + 1;
                false -> false
            end;
       (_In, _I) -> false
    end;
char_step(Test, #c{u = false, dir = backward}) ->
    fun({B, W, _}, I) when I > 0 ->
            case Test(unit(B, W, I - 1)) of
                true -> I - 1;
                false -> false
            end;
       (_In, _I) -> false
    end;
char_step(Test, #c{u = true, dir = forward}) ->
    fun({_, _, L} = In, I) when I < L ->
            {Ch, I2} = char_at(In, I),
            case Test(Ch) of
                true -> I2;
                false -> false
            end;
       (_In, _I) -> false
    end;
char_step(Test, #c{u = true, dir = backward}) ->
    fun(In, I) when I > 0 ->
            {Ch, I2} = char_before(In, I),
            case Test(Ch) of
                true -> I2;
                false -> false
            end;
       (_In, _I) -> false
    end.

%% A run of characters without i, compared as units. A lone surrogate with a
%% Unicode flag must not match half of a pair, so it goes character by character.
literal(Chars, #c{u = U} = C) ->
    Units = case U of
        true -> lists:flatmap(fun to_units/1, Chars);
        false -> Chars
    end,
    case U andalso lists:any(fun(X) -> X >= 16#D800 andalso X =< 16#DFFF end, Chars) of
        true -> sequence_of([node({char, X}, C) || X <- Chars], C);
        false -> {step, literal_step(Units, C#c.dir)}
    end.

to_units(C) when C > 16#FFFF ->
    V = C - 16#10000,
    [16#D800 + (V bsr 10), 16#DC00 + (V band 16#3FF)];
to_units(C) -> [C].

literal_step(Units, Dir) ->
    N = length(Units),
    Narrow = case lists:all(fun(X) -> X =< 16#FF end, Units) of
        true -> list_to_binary(Units);
        false -> none
    end,
    Wide = << <<X:16>> || X <- Units >>,
    case Dir of
        forward ->
            fun({B, 1, L}, I) when I + N =< L ->
                    case binary:part(B, I, N) of
                        Narrow -> I + N;
                        _ -> false
                    end;
               ({B, 2, L}, I) when I + N =< L ->
                    case binary:part(B, 2 * I, 2 * N) of
                        Wide -> I + N;
                        _ -> false
                    end;
               (_In, _I) -> false
            end;
        backward ->
            fun({B, 1, _}, I) when I >= N ->
                    case binary:part(B, I - N, N) of
                        Narrow -> I - N;
                        _ -> false
                    end;
               ({B, 2, _}, I) when I >= N ->
                    case binary:part(B, 2 * (I - N), 2 * N) of
                        Wide -> I - N;
                        _ -> false
                    end;
               (_In, _I) -> false
            end
    end.

%%% Sets

%% The CharacterSetMatcher of a set: with i, of its closure under Canonicalize.
set_node(Ranges, Negated, C) ->
    Test = buoy_regexp_charset:test(closure(Ranges, C)),
    case Negated of
        true -> char_node(fun(X) -> not Test(X) end, C);
        false -> char_node(Test, C)
    end.

closure(Ranges, #c{i = false}) -> Ranges;
closure(Ranges, C) -> buoy_regexp_charset:closure(Ranges, canonical_mode(C)).

canonical_mode(#c{u = true}) -> scf;
canonical_mode(#c{u = false}) -> upper.

max_char(#c{u = true}) -> 16#10FFFF;
max_char(#c{u = false}) -> 16#FFFF.

%% CharacterComplement.
complement(Ranges, #c{v = true, i = true}) -> buoy_regexp_charset:intersect(buoy_regexp_charset:canonical_characters(), buoy_regexp_charset:complement(Ranges, 16#10FFFF));
complement(Ranges, C) -> buoy_regexp_charset:complement(Ranges, max_char(C)).

%% The set of a class without v.
class_set(Items, C) -> lists:foldl(fun(Item, Acc) -> buoy_regexp_charset:union(class_item(Item, C), Acc) end, [], Items).

class_item({char, X}, _C) -> [{X, X}];
class_item({range, A, B}, _C) -> [{A, B}];
class_item({union, Items}, C) -> class_set(Items, C);
class_item({escape, Escape}, C) -> escape_ranges(Escape, C).

%% The set of a class escape without v.
escape_ranges(digit, _C) -> buoy_regexp_charset:digit();
escape_ranges(not_digit, C) -> complement(buoy_regexp_charset:digit(), C);
escape_ranges(space, _C) -> buoy_regexp_charset:space();
escape_ranges(not_space, C) -> complement(buoy_regexp_charset:space(), C);
escape_ranges(word, C) -> word(C);
escape_ranges(not_word, C) -> complement(word(C), C);
escape_ranges({property, Key, false}, _C) -> buoy_regexp_charset:property(Key);
escape_ranges({property, Key, true}, C) -> complement(buoy_regexp_charset:property(Key), C).

word(C) -> buoy_regexp_charset:word(C#c.u andalso C#c.i).

%%% Sets with v: CharSets of characters and strings

%% {Ranges, Strings}: Strings are the members of two or more characters, or
%% none, as lists of code points.
set_expression({union, Items}, C) ->
    lists:foldl(fun(Item, Acc) -> set_union(set_item(Item, C), Acc) end, {[], []}, Items);
set_expression({intersection, [First | Rest]}, C) ->
    lists:foldl(fun(Item, {R, S}) ->
                        {R2, S2} = set_item(Item, C),
                        {buoy_regexp_charset:intersect(R, R2), [X || X <- S, lists:member(X, S2)]}
                end, set_item(First, C), Rest);
set_expression({subtraction, [First | Rest]}, C) ->
    lists:foldl(fun(Item, {R, S}) ->
                        {R2, S2} = set_item(Item, C),
                        {buoy_regexp_charset:subtract(R, R2), [X || X <- S, not lists:member(X, S2)]}
                end, set_item(First, C), Rest).

set_union({R1, S1}, {R2, S2}) -> {buoy_regexp_charset:union(R1, R2), lists:usort(S1 ++ S2)}.

set_item({char, X}, C) -> maybe_fold({[{X, X}], []}, C);
set_item({range, A, B}, C) -> maybe_fold({[{A, B}], []}, C);
set_item({nested, false, Expr}, C) -> set_expression(Expr, C);
set_item({nested, true, Expr}, C) ->
    {Ranges, _} = set_expression(Expr, C),
    {complement(Ranges, C), []};
set_item({escape, Escape}, C) -> escape_set(Escape, C);
set_item({strings, Strings}, C) -> maybe_fold(strings_set(Strings), C).

strings_set(Strings) ->
    {buoy_regexp_charset:from_list([X || [X] <- Strings]), lists:usort([S || S <- Strings, length(S) =/= 1])}.

%% MaybeSimpleCaseFolding.
maybe_fold({Ranges, Strings}, #c{v = true, i = true}) ->
    {Folded, Rest} = lists:partition(fun(S) -> length(S) =:= 1 end,
                                     [buoy_regexp_charset:fold_string(S) || S <- Strings]),
    {buoy_regexp_charset:union(buoy_regexp_charset:fold(Ranges), buoy_regexp_charset:from_list([X || [X] <- Folded])),
     lists:usort(Rest)};
maybe_fold(Set, _C) -> Set.

%% The set of a class escape with v.
escape_set(word, C) -> maybe_fold({word(C), []}, C);
escape_set(not_word, C) ->
    {Word, []} = maybe_fold({word(C), []}, C),
    {complement(Word, C), []};
%% A lone General_Category value folds too, as V8 does: the spec text of
%% UnicodePropertyValueExpression skips MaybeSimpleCaseFolding for it, and test262
%% does not tell the two apart.
escape_set({property, Key, Negated}, C) ->
    {Set, []} = maybe_fold({buoy_regexp_charset:property(Key), []}, C),
    case Negated of
        true -> {complement(Set, C), []};
        false -> {Set, []}
    end;
escape_set({strings, Name}, C) -> maybe_fold(buoy_regexp_charset:property_strings(Name), C);
escape_set(Escape, C) -> {escape_ranges(Escape, C), []}.

%% A set with strings: each string, longest first, then the single
%% characters, then the empty string (22.2.2.7 CompileAtom).
strings_node(Ranges, [], C) -> set_node(Ranges, false, C);
strings_node(Ranges, Strings, C) ->
    Sorted = lists:sort(fun(A, B) -> length(A) >= length(B) end, [S || S <- Strings, S =/= []]),
    Literals = [sequence_of([node({char, X}, C) || X <- S], C) || S <- Sorted],
    Empty = [{step, fun(_In, I) -> I end} || lists:member([], Strings)],
    alternatives(Literals ++ [set_node(Ranges, false, C)] ++ Empty, C).

%%% Sequences and alternatives

sequence(Nodes, C) -> sequence_of([node(N, C) || N <- literals(Nodes, C)], C).

%% Runs of two or more characters without i become one literal.
literals(Nodes, #c{i = false}) -> runs(Nodes, []);
literals(Nodes, _C) -> Nodes.

runs([{char, X} | Rest], Run) -> runs(Rest, [X | Run]);
runs(Rest, []) -> next_run(Rest);
runs(Rest, [X]) -> [{char, X} | next_run(Rest)];
runs(Rest, Run) -> [{literal, lists:reverse(Run)} | next_run(Rest)].

next_run([Node | Rest]) -> [Node | runs(Rest, [])];
next_run([]) -> [].

%% MatchSequence over compiled nodes, which run right to left backward.
sequence_of(Compiled, #c{dir = Dir}) ->
    Ordered = case Dir of
        forward -> Compiled;
        backward -> lists:reverse(Compiled)
    end,
    chain(join_steps(Ordered)).

join_steps([A, B | Rest]) ->
    case is_step(A) andalso is_step(B) of
        true ->
            S1 = step_of(A),
            S2 = step_of(B),
            join_steps([{step, fun(In, I) ->
                                       case S1(In, I) of
                                           false -> false;
                                           I2 -> S2(In, I2)
                                       end
                               end} | Rest]);
        false -> [A | join_steps([B | Rest])]
    end;
join_steps(Nodes) -> Nodes.

chain([]) -> {step, fun(_In, I) -> I end};
chain([Node]) -> Node;
chain([Node | Rest]) ->
    Next = chain(Rest),
    case {is_step(Node), Next} of
        {true, {cps, M}} ->
            S = step_of(Node),
            {cps, fun(In, I, Caps, K) ->
                          case S(In, I) of
                              false -> false;
                              I2 -> M(In, I2, Caps, K)
                          end
                  end};
        {false, {cps, M2}} ->
            {cps, M1} = Node,
            {cps, fun(In, I, Caps, K) -> M1(In, I, Caps, fun(I2, Caps2) -> M2(In, I2, Caps2, K) end) end};
        {false, _} ->
            {cps, M1} = Node,
            S = step_of(Next),
            {cps, fun(In, I, Caps, K) ->
                          M1(In, I, Caps, fun(I2, Caps2) ->
                                                  case S(In, I2) of
                                                      false -> false;
                                                      I3 -> K(I3, Caps2)
                                                  end
                                          end)
                  end}
    end.

%% MatchTwoAlternatives. Alternatives of one character each become one
%% character: when the first matches and the rest of the pattern fails, the
%% second can only call the rest again with the same state.
alternatives([Node], _C) -> Node;
alternatives(Nodes, C) ->
    case lists:all(fun(N) -> element(1, N) =:= char end, Nodes) of
        true ->
            Tests = [T || {char, T, _} <- Nodes],
            char_node(fun(X) -> lists:any(fun(T) -> T(X) end, Tests) end, C);
        false -> choice(Nodes)
    end.

choice(Nodes) ->
    Matchers = [M || {cps, M} <- [to_cps(N) || N <- Nodes]],
    {cps, fun(In, I, Caps, K) -> first(Matchers, In, I, Caps, K) end}.

first([M], In, I, Caps, K) -> M(In, I, Caps, K);
first([M | Rest], In, I, Caps, K) ->
    case M(In, I, Caps, K) of
        false -> first(Rest, In, I, Caps, K);
        Result -> Result
    end.

%%% Groups, lookarounds, and backreferences

group(Index, Node, Dir) ->
    Range = fun(I, I2) when Dir =:= forward -> {I, I2};
               (I, I2) -> {I2, I}
            end,
    case is_step(Node) of
        true ->
            S = step_of(Node),
            {cps, fun(In, I, Caps, K) ->
                          case S(In, I) of
                              false -> false;
                              I2 -> K(I2, setelement(Index, Caps, Range(I, I2)))
                          end
                  end};
        false ->
            {cps, M} = Node,
            {cps, fun(In, I, Caps, K) -> M(In, I, Caps, fun(I2, Caps2) -> K(I2, setelement(Index, Caps2, Range(I, I2))) end) end}
    end.

look(Positive, Node) ->
    case {is_step(Node), Positive} of
        {true, true} ->
            S = step_of(Node),
            {step, fun(In, I) ->
                           case S(In, I) of
                               false -> false;
                               _ -> I
                           end
                   end};
        {true, false} ->
            S = step_of(Node),
            {step, fun(In, I) ->
                           case S(In, I) of
                               false -> I;
                               _ -> false
                           end
                   end};
        {false, true} ->
            {cps, M} = Node,
            {cps, fun(In, I, Caps, K) ->
                          case M(In, I, Caps, fun done/2) of
                              false -> false;
                              {_, Caps2} -> K(I, Caps2)
                          end
                  end};
        {false, false} ->
            {cps, M} = Node,
            {cps, fun(In, I, Caps, K) ->
                          case M(In, I, Caps, fun done/2) of
                              false -> K(I, Caps);
                              _ -> false
                          end
                  end}
    end.

%% BackreferenceMatcher.
backref(Indexes, C) ->
    Compare = backref_compare(C),
    {cps, fun(In, I, Caps, K) ->
                  case captured(Indexes, Caps) of
                      undefined -> K(I, Caps);
                      {S, E} ->
                          case Compare(In, S, E, I) of
                              false -> false;
                              I2 -> K(I2, Caps)
                          end
                  end
          end}.

captured([N | Rest], Caps) ->
    case element(N, Caps) of
        undefined -> captured(Rest, Caps);
        Range -> Range
    end;
captured([], _Caps) -> undefined.

backref_compare(#c{u = false, i = false, dir = forward}) ->
    fun({B, W, L}, S, E, I) when I + E - S =< L ->
            case binary:part(B, W * S, W * (E - S)) =:= binary:part(B, W * I, W * (E - S)) of
                true -> I + E - S;
                false -> false
            end;
       (_In, _S, _E, _I) -> false
    end;
backref_compare(#c{u = false, i = false, dir = backward}) ->
    fun({B, W, _}, S, E, I) when I - (E - S) >= 0 ->
            case binary:part(B, W * S, W * (E - S)) =:= binary:part(B, W * (I - (E - S)), W * (E - S)) of
                true -> I - (E - S);
                false -> false
            end;
       (_In, _S, _E, _I) -> false
    end;
backref_compare(#c{u = false, dir = forward}) ->
    fun({B, W, L} = _In, S, E, I) when I + E - S =< L ->
            Same = lists:all(fun(K) -> same_upper(unit(B, W, S + K), unit(B, W, I + K)) end, lists:seq(0, E - S - 1)),
            case Same of
                true -> I + E - S;
                false -> false
            end;
       (_In, _S, _E, _I) -> false
    end;
backref_compare(#c{u = false, dir = backward}) ->
    fun({B, W, _}, S, E, I) when I - (E - S) >= 0 ->
            G = I - (E - S),
            Same = lists:all(fun(K) -> same_upper(unit(B, W, S + K), unit(B, W, G + K)) end, lists:seq(0, E - S - 1)),
            case Same of
                true -> G;
                false -> false
            end;
       (_In, _S, _E, _I) -> false
    end;
backref_compare(#c{i = I, dir = Dir}) ->
    Canon = case I of
        true -> fun buoy_regexp_unicode:scf/1;
        false -> fun(X) -> X end
    end,
    case Dir of
        forward -> fun(In, S, E, Pos) -> forward_same(In, S, E, Pos, Canon) end;
        backward -> fun(In, S, E, Pos) -> backward_same(In, S, E, Pos, Canon) end
    end.

same_upper(A, A) -> true;
same_upper(A, B) -> buoy_regexp_unicode:upper(A) =:= buoy_regexp_unicode:upper(B).

forward_same(_In, S, E, I, _Canon) when S >= E -> I;
forward_same({_, _, L}, _S, _E, I, _Canon) when I >= L -> false;
forward_same(In, S, E, I, Canon) ->
    {A, S2} = char_at(In, S),
    {B, I2} = char_at(In, I),
    case A =:= B orelse Canon(A) =:= Canon(B) of
        true -> forward_same(In, S2, E, I2, Canon);
        false -> false
    end.

backward_same(_In, S, E, I, _Canon) when E =< S -> I;
backward_same(_In, _S, _E, I, _Canon) when I =< 0 -> false;
backward_same(In, S, E, I, Canon) ->
    {A, E2} = char_before(In, E),
    {B, I2} = char_before(In, I),
    case A =:= B orelse Canon(A) =:= Canon(B) of
        true -> backward_same(In, S, E2, I2, Canon);
        false -> false
    end.

%%% Assertions

bol(#c{m = false}) ->
    fun(_In, 0) -> 0;
       (_In, _I) -> false
    end;
bol(#c{m = true}) ->
    fun(_In, 0) -> 0;
       ({B, W, _}, I) ->
            case is_line_terminator(unit(B, W, I - 1)) of
                true -> I;
                false -> false
            end
    end.

eol(#c{m = false}) ->
    fun({_, _, L}, L) -> L;
       (_In, _I) -> false
    end;
eol(#c{m = true}) ->
    fun({_, _, L}, L) -> L;
       ({B, W, _}, I) ->
            case is_line_terminator(unit(B, W, I)) of
                true -> I;
                false -> false
            end
    end.

%% \b and \B. Every word character is one code unit, so IsWordChar reads units.
boundary(Wanted, C) ->
    Word = buoy_regexp_charset:test(word(C)),
    fun({B, W, L}, I) ->
            Before = I > 0 andalso Word(unit(B, W, I - 1)),
            After = I < L andalso Word(unit(B, W, I)),
            case (Before =/= After) =:= Wanted of
                true -> I;
                false -> false
            end
    end.

%%% Quantifiers

repeat(_Min, 0, _Greedy, _Node, _ParenIndex, _ParenCount, _C) ->
    {step, fun(_In, I) -> I end};
repeat(Min, Max, Greedy, {char, _Test, Step}, _ParenIndex, _ParenCount, C) ->
    char_repeat(Min, Max, Greedy, Step, C);
repeat(Min, Max, Greedy, {step, Step}, _ParenIndex, _ParenCount, _C) ->
    step_repeat(Min, Max, Greedy, Step);
repeat(Min, Max, Greedy, {cps, M}, ParenIndex, ParenCount, _C) ->
    Clear = [ParenIndex + K || K <- lists:seq(1, ParenCount)],
    {cps, fun(In, I, Caps, K) -> repeat_matcher(M, Min, Max, Greedy, In, I, Caps, K, Clear) end}.

%% RepeatMatcher.
repeat_matcher(_M, _Min, 0, _Greedy, _In, I, Caps, K, _Clear) ->
    K(I, Caps);
repeat_matcher(M, Min, Max, Greedy, In, I, Caps, K, Clear) ->
    D = fun(I2, _Caps2) when Min =:= 0, I2 =:= I -> false;
           (I2, Caps2) -> repeat_matcher(M, max(Min - 1, 0), decrement(Max), Greedy, In, I2, Caps2, K, Clear)
        end,
    Cleared = lists:foldl(fun(N, Acc) -> setelement(N, Acc, undefined) end, Caps, Clear),
    case {Min, Greedy} of
        {0, false} ->
            case K(I, Caps) of
                false -> M(In, I, Cleared, D);
                Z -> Z
            end;
        {0, true} ->
            case M(In, I, Cleared, D) of
                false -> K(I, Caps);
                Z -> Z
            end;
        _ ->
            M(In, I, Cleared, D)
    end.

decrement(infinity) -> infinity;
decrement(N) -> N - 1.

%% A quantified step has no captures and one way to match, so the choice is
%% only the count of iterations. An optional iteration that does not move
%% fails, as the empty check of RepeatMatcher.
step_repeat(Min, Max, Greedy, Step) ->
    {cps, fun(In, I, Caps, K) ->
                  case required(Step, In, I, Min) of
                      false -> false;
                      I1 when Greedy -> try_each(optional(Step, In, I1, decrement_by(Max, Min), [I1]), Caps, K);
                      I1 -> lazy_steps(Step, In, I1, decrement_by(Max, Min), Caps, K)
                  end
          end}.

decrement_by(infinity, _N) -> infinity;
decrement_by(Max, N) -> Max - N.

required(_Step, _In, I, 0) -> I;
required(Step, In, I, N) ->
    case Step(In, I) of
        false -> false;
        I2 -> required(Step, In, I2, N - 1)
    end.

optional(_Step, _In, _I, 0, Acc) -> Acc;
optional(Step, In, I, Left, Acc) ->
    case Step(In, I) of
        false -> Acc;
        I -> Acc;
        I2 -> optional(Step, In, I2, decrement(Left), [I2 | Acc])
    end.

try_each([I | Rest], Caps, K) ->
    case K(I, Caps) of
        false -> try_each(Rest, Caps, K);
        Z -> Z
    end;
try_each([], _Caps, _K) -> false.

lazy_steps(Step, In, I, Left, Caps, K) ->
    case K(I, Caps) of
        false when Left =:= 0 -> false;
        false ->
            case Step(In, I) of
                false -> false;
                I -> false;
                I2 -> lazy_steps(Step, In, I2, decrement(Left), Caps, K)
            end;
        Z -> Z
    end.

%% A quantified character: the greedy form scans ahead, then gives back one
%% character at a time, so the depth of the stack does not grow with the count.
char_repeat(Min, Max, true, Step, C) ->
    Back = give_back(C),
    {cps, fun(In, I, Caps, K) ->
                  case required(Step, In, I, Min) of
                      false -> false;
                      I1 ->
                          End = scan(Step, In, I1, decrement_by(Max, Min)),
                          retreat(In, I1, End, Caps, K, Back)
                  end
          end};
char_repeat(Min, Max, false, Step, _C) ->
    {cps, fun(In, I, Caps, K) ->
                  case required(Step, In, I, Min) of
                      false -> false;
                      I1 -> lazy_steps(Step, In, I1, decrement_by(Max, Min), Caps, K)
                  end
          end}.

scan(_Step, _In, I, 0) -> I;
scan(Step, In, I, Left) ->
    case Step(In, I) of
        false -> I;
        I2 -> scan(Step, In, I2, decrement(Left))
    end.

retreat(In, Stop, I, Caps, K, Back) ->
    case K(I, Caps) of
        false when I =:= Stop -> false;
        false -> retreat(In, Stop, Back(In, I), Caps, K, Back);
        Z -> Z
    end.

%% The position one character back toward the start of a scan.
give_back(#c{u = false, dir = forward}) -> fun(_In, I) -> I - 1 end;
give_back(#c{u = false, dir = backward}) -> fun(_In, I) -> I + 1 end;
give_back(#c{u = true, dir = forward}) -> fun(In, I) -> element(2, char_before(In, I)) end;
give_back(#c{u = true, dir = backward}) -> fun(In, I) -> element(2, char_at(In, I)) end.
