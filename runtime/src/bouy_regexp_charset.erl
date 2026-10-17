%% The CharSets of the RegExp engine (ECMA-262 22.2.2.9): sorted lists of
%% disjoint inclusive ranges {Lo, Hi} of character values, the Unicode
%% properties, and the case mappings of Canonicalize.
%%
%% A pattern with the i flag matches a character ch against a set S when some
%% member a of S has Canonicalize(a) = Canonicalize(ch) (CharacterSetMatcher).
%% closure/2 adds to S every character that maps to the same value as one of
%% its members, so the matcher only tests membership.
-module(bouy_regexp_charset).

-export([union/2, intersect/2, subtract/2, complement/2, from_list/1, member/2, test/1]).
-export([property/1, has_property/2, is_string_property/1, property_strings/1]).
-export([digit/0, space/0, word/1, line_terminators/0]).
-export([canonicalize/2, closure/2, fold/1, fold_string/1, canonical_characters/0]).

-type ranges() :: [{non_neg_integer(), non_neg_integer()}].
-export_type([ranges/0]).

-define(STRING_PROPERTIES, [<<"Basic_Emoji">>, <<"Emoji_Keycap_Sequence">>, <<"RGI_Emoji_Modifier_Sequence">>,
                            <<"RGI_Emoji_Flag_Sequence">>, <<"RGI_Emoji_Tag_Sequence">>, <<"RGI_Emoji_ZWJ_Sequence">>]).

%%% Range sets

-spec from_list([non_neg_integer() | {non_neg_integer(), non_neg_integer()}]) -> ranges().
from_list(Items) -> merge(lists:sort([range(I) || I <- Items])).

range({_, _} = R) -> R;
range(C) -> {C, C}.

merge([{A, B}, {C, D} | Rest]) when C =< B + 1 -> merge([{A, max(B, D)} | Rest]);
merge([R | Rest]) -> [R | merge(Rest)];
merge([]) -> [].

-spec union(ranges(), ranges()) -> ranges().
union([], B) -> B;
union(A, []) -> A;
union(A, B) -> merge(lists:merge(A, B)).

-spec intersect(ranges(), ranges()) -> ranges().
intersect([{A1, B1} | R1] = L1, [{A2, B2} | R2] = L2) ->
    Lo = max(A1, A2),
    Hi = min(B1, B2),
    Rest = case B1 < B2 of
        true -> intersect(R1, L2);
        false -> intersect(L1, R2)
    end,
    case Lo =< Hi of
        true -> [{Lo, Hi} | Rest];
        false -> Rest
    end;
intersect(_, _) -> [].

-spec subtract(ranges(), ranges()) -> ranges().
subtract(A, []) -> A;
subtract(A, B) -> intersect(A, complement(B, 16#10FFFF)).

%% The characters up to Max that are not in the set.
-spec complement(ranges(), non_neg_integer()) -> ranges().
complement(Ranges, Max) -> complement(Ranges, 0, Max).

complement([{A, B} | Rest], Next, Max) when A > Next -> [{Next, min(A - 1, Max)} | complement(Rest, B + 1, Max)];
complement([{_, B} | Rest], _Next, Max) -> complement(Rest, B + 1, Max);
complement([], Next, Max) when Next =< Max -> [{Next, Max}];
complement([], _Next, _Max) -> [].

-spec member(ranges(), non_neg_integer()) -> boolean().
member(Ranges, C) -> in(Ranges, C).

in([{A, B} | _], C) when C >= A, C =< B -> true;
in([{A, _} | _], C) when C < A -> false;
in([_ | Rest], C) -> in(Rest, C);
in([], _C) -> false.

%% The membership test of a set, as a fun.
-spec test(ranges()) -> fun((non_neg_integer()) -> boolean()).
test([]) -> fun(_) -> false end;
test([{A, A}]) -> fun(C) -> C =:= A end;
test([{A, B}]) -> fun(C) -> C >= A andalso C =< B end;
test([{A, A}, {B, B}]) -> fun(C) -> C =:= A orelse C =:= B end;
test(Ranges) when length(Ranges) =< 8 -> fun(C) -> in(Ranges, C) end;
test(Ranges) ->
    Table = list_to_tuple(Ranges),
    Size = tuple_size(Table),
    fun(C) -> search(Table, C, 1, Size) end.

search(_Table, _C, Lo, Hi) when Lo > Hi -> false;
search(Table, C, Lo, Hi) ->
    Mid = (Lo + Hi) bsr 1,
    case element(Mid, Table) of
        {A, _} when C < A -> search(Table, C, Lo, Mid - 1);
        {_, B} when C > B -> search(Table, C, Mid + 1, Hi);
        _ -> true
    end.

%%% The class escapes and the line terminators

-spec digit() -> ranges().
digit() -> [{$0, $9}].

%% WhiteSpace and LineTerminator.
-spec space() -> ranges().
space() ->
    [{9, 13}, {32, 32}, {16#A0, 16#A0}, {16#1680, 16#1680}, {16#2000, 16#200A}, {16#2028, 16#2029},
     {16#202F, 16#202F}, {16#205F, 16#205F}, {16#3000, 16#3000}, {16#FEFF, 16#FEFF}].

%% WordCharacters: with a Unicode flag and i, also the characters that fold
%% into the ASCII word characters, U+017F and U+212A.
-spec word(boolean()) -> ranges().
word(false) -> [{$0, $9}, {$A, $Z}, {$_, $_}, {$a, $z}];
word(true) -> [{$0, $9}, {$A, $Z}, {$_, $_}, {$a, $z}, {16#17F, 16#17F}, {16#212A, 16#212A}].

-spec line_terminators() -> ranges().
line_terminators() -> [{10, 10}, {13, 13}, {16#2028, 16#2029}].

%%% Unicode properties

%% The ranges of a key of bouy_regexp_unicode:ranges/1.
-spec property(binary()) -> ranges().
property(Key) -> decode_ranges(numbers(base64:decode(bouy_regexp_unicode:ranges(Key))), 0, first).

decode_ranges([Start, Length | Rest], _Prev, first) -> [{Start, Start + Length} | decode_ranges(Rest, Start + Length, next)];
decode_ranges([Gap, Length | Rest], Prev, next) ->
    Start = Prev + Gap,
    [{Start, Start + Length} | decode_ranges(Rest, Start + Length, next)];
decode_ranges([], _Prev, _) -> [].

numbers(<<>>) -> [];
numbers(B) ->
    {N, Rest} = leb(B, 0, 0),
    [N | numbers(Rest)].

leb(<<1:1, Low:7, Rest/binary>>, Shift, Acc) -> leb(Rest, Shift + 7, Acc bor (Low bsl Shift));
leb(<<0:1, Low:7, Rest/binary>>, Shift, Acc) -> {Acc bor (Low bsl Shift), Rest}.

-spec has_property(binary(), non_neg_integer()) -> boolean().
has_property(Key, C) -> in(property(Key), C).

-spec is_string_property(binary()) -> boolean().
is_string_property(<<"RGI_Emoji">>) -> true;
is_string_property(Name) -> lists:member(Name, ?STRING_PROPERTIES).

%% A property of strings: its single code points, and its sequences of two
%% or more code points. RGI_Emoji is the union of the others.
-spec property_strings(binary()) -> {ranges(), [[non_neg_integer()]]}.
property_strings(<<"RGI_Emoji">>) ->
    Parts = [property_strings(N) || N <- ?STRING_PROPERTIES],
    {lists:foldl(fun({R, _}, Acc) -> union(R, Acc) end, [], Parts), lists:append([S || {_, S} <- Parts])};
property_strings(Name) ->
    {property(Name), sequences(numbers(base64:decode(bouy_regexp_unicode:strings(Name))))}.

sequences([]) -> [];
sequences([N | Rest]) ->
    {Seq, Rest1} = lists:split(N, Rest),
    [Seq | sequences(Rest1)].

%%% Case

%% Canonicalize: simple case folding with a Unicode flag (scf), else the
%% restricted toUppercase of a BMP pattern (upper).
-spec canonicalize(scf | upper, non_neg_integer()) -> non_neg_integer().
canonicalize(scf, C) -> bouy_regexp_unicode:scf(C);
canonicalize(upper, C) -> bouy_regexp_unicode:upper(C).

classes(scf) -> bouy_regexp_unicode:scf_classes();
classes(upper) -> bouy_regexp_unicode:upper_classes().

%% The set with every character whose canonical value is the canonical value
%% of a member.
-spec closure(ranges(), scf | upper) -> ranges().
closure([], _Mode) -> [];
closure(Ranges, Mode) ->
    Test = test(Ranges),
    Extra = [M || {_, Members} <- classes(Mode), lists:any(Test, Members), M <- Members, not Test(M)],
    union(Ranges, from_list(Extra)).

%% MaybeSimpleCaseFolding with v and i: each member replaced by its scf.
-spec fold(ranges()) -> ranges().
fold(Ranges) ->
    Test = test(Ranges),
    Classes = classes(scf),
    Folded = [K || {K, Members} <- Classes, lists:any(fun(M) -> M =/= K andalso Test(M) end, Members)],
    union(subtract(Ranges, non_canonical(Classes)), from_list(Folded)).

-spec fold_string([non_neg_integer()]) -> [non_neg_integer()].
fold_string(Codes) -> [bouy_regexp_unicode:scf(C) || C <- Codes].

%% AllCharacters with v and i: the code points that are their own scf.
-spec canonical_characters() -> ranges().
canonical_characters() -> complement(non_canonical(classes(scf)), 16#10FFFF).

non_canonical(Classes) -> from_list([M || {K, Members} <- Classes, M <- Members, M =/= K]).
