#!/usr/bin/env escript
%% Writes runtime/src/bouy_regexp_unicode.erl, the Unicode data of the RegExp engine,
%% from the files of the Unicode Character Database.
%%
%% Usage: scripts/regexp-unicode.escript <ucd-dir> <output.erl>
%%
%% <ucd-dir> holds these files of one Unicode release, flat: UnicodeData.txt,
%% SpecialCasing.txt, CaseFolding.txt, Scripts.txt, ScriptExtensions.txt, PropList.txt,
%% DerivedCoreProperties.txt, DerivedNormalizationProps.txt, DerivedBinaryProperties.txt,
%% DerivedGeneralCategory.txt, emoji-data.txt, PropertyValueAliases.txt,
%% emoji-sequences.txt, and emoji-zwj-sequences.txt. They come from
%% https://www.unicode.org/Public/<version>/ucd/ (the extracted/ and emoji/ files too)
%% and https://www.unicode.org/Public/<version>/emoji/. test262 pins the version in the
%% header of test/built-ins/RegExp/property-escapes/generated/*.js.
-mode(compile).

%% Table 66 of ECMA-262: each binary property and the aliases that RegExp accepts.
binary_properties() ->
    [{"ASCII", []}, {"ASCII_Hex_Digit", ["AHex"]}, {"Alphabetic", ["Alpha"]}, {"Any", []}, {"Assigned", []},
     {"Bidi_Control", ["Bidi_C"]}, {"Bidi_Mirrored", ["Bidi_M"]}, {"Case_Ignorable", ["CI"]}, {"Cased", []},
     {"Changes_When_Casefolded", ["CWCF"]}, {"Changes_When_Casemapped", ["CWCM"]},
     {"Changes_When_Lowercased", ["CWL"]}, {"Changes_When_NFKC_Casefolded", ["CWKCF"]},
     {"Changes_When_Titlecased", ["CWT"]}, {"Changes_When_Uppercased", ["CWU"]}, {"Dash", []},
     {"Default_Ignorable_Code_Point", ["DI"]}, {"Deprecated", ["Dep"]}, {"Diacritic", ["Dia"]}, {"Emoji", []},
     {"Emoji_Component", ["EComp"]}, {"Emoji_Modifier", ["EMod"]}, {"Emoji_Modifier_Base", ["EBase"]},
     {"Emoji_Presentation", ["EPres"]}, {"Extended_Pictographic", ["ExtPict"]}, {"Extender", ["Ext"]},
     {"Grapheme_Base", ["Gr_Base"]}, {"Grapheme_Extend", ["Gr_Ext"]}, {"Hex_Digit", ["Hex"]},
     {"IDS_Binary_Operator", ["IDSB"]}, {"IDS_Trinary_Operator", ["IDST"]}, {"ID_Continue", ["IDC"]},
     {"ID_Start", ["IDS"]}, {"Ideographic", ["Ideo"]}, {"Join_Control", ["Join_C"]},
     {"Logical_Order_Exception", ["LOE"]}, {"Lowercase", ["Lower"]}, {"Math", []},
     {"Noncharacter_Code_Point", ["NChar"]}, {"Pattern_Syntax", ["Pat_Syn"]}, {"Pattern_White_Space", ["Pat_WS"]},
     {"Quotation_Mark", ["QMark"]}, {"Radical", []}, {"Regional_Indicator", ["RI"]},
     {"Sentence_Terminal", ["STerm"]}, {"Soft_Dotted", ["SD"]}, {"Terminal_Punctuation", ["Term"]},
     {"Unified_Ideograph", ["UIdeo"]}, {"Uppercase", ["Upper"]}, {"Variation_Selector", ["VS"]},
     {"White_Space", ["space"]}, {"XID_Continue", ["XIDC"]}, {"XID_Start", ["XIDS"]}].

%% Table 67: the binary properties of strings.
string_properties() ->
    ["Basic_Emoji", "Emoji_Keycap_Sequence", "RGI_Emoji_Modifier_Sequence", "RGI_Emoji_Flag_Sequence",
     "RGI_Emoji_Tag_Sequence", "RGI_Emoji_ZWJ_Sequence"].

main([Dir, Out]) ->
    File = fun(Name) -> filename:join(Dir, Name) end,
    Props = lists:foldl(fun(Name, Acc) -> property_file(File(Name), Acc) end, #{},
                        ["PropList.txt", "DerivedCoreProperties.txt", "DerivedNormalizationProps.txt",
                         "DerivedBinaryProperties.txt", "emoji-data.txt"]),
    Categories = category_file(File("DerivedGeneralCategory.txt")),
    Aliases = value_aliases(File("PropertyValueAliases.txt")),
    Binary = binary_ranges(Props, Categories),
    Gc = category_ranges(Categories, Aliases),
    {Sc, Scx} = script_ranges(File("Scripts.txt"), File("ScriptExtensions.txt"), Aliases),
    {StringCodes, StringSeqs} = string_property_data(File("emoji-sequences.txt"), File("emoji-zwj-sequences.txt")),
    Scf = case_folding(File("CaseFolding.txt")),
    Upper = uppercase(File("UnicodeData.txt"), File("SpecialCasing.txt")),
    Version = version(File("DerivedGeneralCategory.txt")),
    Source = [header(Version),
              alias_function(binary_property, [{N, N} || {N, _} <- binary_properties()]
                             ++ [{A, N} || {N, As} <- binary_properties(), A <- As]),
              alias_function(general_category, maps:get(gc, Aliases)),
              alias_function(script, maps:get(sc, Aliases)),
              ranges_function([{N, R} || {N, R} <- Binary]
                              ++ [{"gc=" ++ N, R} || {N, R} <- Gc]
                              ++ [{"sc=" ++ N, R} || {N, R} <- Sc]
                              ++ [{"scx=" ++ N, R} || {N, R} <- Scx]
                              ++ [{N, R} || {N, R} <- StringCodes]),
              strings_function(StringSeqs),
              map_function(scf, Scf),
              map_function(upper, Upper),
              classes_function(scf_classes, Scf),
              classes_function(upper_classes, Upper)],
    ok = file:write_file(Out, Source),
    io:format("wrote ~s: Unicode ~s, ~b bytes~n", [Out, Version, iolist_size(Source)]);
main(_) ->
    io:format(standard_error, "usage: regexp-unicode.escript <ucd-dir> <output.erl>~n", []),
    halt(2).

%%% Parsing

%% The data lines of a UCD file: the fields before the comment, trimmed.
data_lines(Path) ->
    {ok, Text} = file:read_file(Path),
    Lines = binary:split(Text, <<"\n">>, [global]),
    [Fields || Line <- Lines,
               [Data | _] <- [binary:split(Line, <<"#">>)],
               Fields <- [[string:trim(F) || F <- binary:split(Data, <<";">>, [global])]],
               Fields =/= [<<>>]].

code_range(Field) ->
    case binary:split(Field, <<"..">>) of
        [A, B] -> {hex(A), hex(B)};
        [A] -> {hex(A), hex(A)}
    end.

hex(B) -> binary_to_integer(string:trim(B), 16).

%% Binary properties: the two-field lines of each file.
property_file(Path, Acc) ->
    lists:foldl(fun([Range, Name], A) ->
                        maps:update_with(binary_to_list(Name), fun(L) -> [code_range(Range) | L] end,
                                         [code_range(Range)], A);
                   (_, A) -> A
                end, Acc, data_lines(Path)).

category_file(Path) ->
    lists:foldl(fun([Range, Gc], A) ->
                        maps:update_with(binary_to_list(Gc), fun(L) -> [code_range(Range) | L] end,
                                         [code_range(Range)], A)
                end, #{}, data_lines(Path)).

%% The aliases of the gc and sc values: [{Alias, Canonical}], the canonical being the
%% short name.
value_aliases(Path) ->
    Rows = [{binary_to_list(P), [binary_to_list(V) || V <- Vs, V =/= <<>>]} || [P | Vs] <- data_lines(Path)],
    Pairs = fun(Prop) -> [{A, Short} || {P, [Short | _] = Names} <- Rows, P =:= Prop, A <- Names] end,
    #{gc => Pairs("gc"), sc => Pairs("sc"),
      sc_long => [{Long, Short} || {"sc", [Short, Long | _]} <- Rows]}.

version(Path) ->
    {ok, <<"# DerivedGeneralCategory-", Rest/binary>>} = file:read_file(Path),
    [V | _] = binary:split(Rest, <<".txt">>),
    binary_to_list(V).

%%% Range sets: sorted lists of disjoint {Lo, Hi}

normalize(Ranges) -> merge(lists:sort(Ranges)).

merge([{A, B}, {C, D} | Rest]) when C =< B + 1 -> merge([{A, max(B, D)} | Rest]);
merge([R | Rest]) -> [R | merge(Rest)];
merge([]) -> [].

union(A, B) -> normalize(A ++ B).

complement(Ranges) -> complement(Ranges, 0).
complement([{A, B} | Rest], Next) when A > Next -> [{Next, A - 1} | complement(Rest, B + 1)];
complement([{_, B} | Rest], _Next) -> complement(Rest, B + 1);
complement([], Next) when Next =< 16#10FFFF -> [{Next, 16#10FFFF}];
complement([], _) -> [].

subtract(A, B) -> intersect(A, complement(B)).

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

%%% The properties

binary_ranges(Props, Categories) ->
    Assigned = complement(normalize(maps:get("Cn", Categories))),
    Special = #{"Any" => [{0, 16#10FFFF}], "ASCII" => [{0, 16#7F}], "Assigned" => Assigned},
    [{Name, case Special of
                #{Name := R} -> R;
                _ -> normalize(maps:get(Name, Props))
            end} || {Name, _} <- binary_properties()].

category_ranges(Categories, #{gc := Aliases}) ->
    Shorts = lists:usort([S || {_, S} <- Aliases]),
    Base = maps:map(fun(_, R) -> normalize(R) end, Categories),
    Groups = #{"L" => ["Lu", "Ll", "Lt", "Lm", "Lo"], "LC" => ["Lu", "Ll", "Lt"], "M" => ["Mn", "Mc", "Me"],
               "N" => ["Nd", "Nl", "No"], "P" => ["Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po"],
               "S" => ["Sm", "Sc", "Sk", "So"], "Z" => ["Zs", "Zl", "Zp"], "C" => ["Cc", "Cf", "Cs", "Co", "Cn"]},
    [{S, case Groups of
             #{S := Members} -> normalize(lists:append([maps:get(M, Base) || M <- Members]));
             _ -> maps:get(S, Base)
         end} || S <- Shorts].

script_ranges(ScriptsPath, ExtensionsPath, #{sc := Aliases, sc_long := Longs}) ->
    Short = maps:from_list(Longs),
    ByScript = lists:foldl(fun([Range, Long], A) ->
                                   S = maps:get(binary_to_list(Long), Short),
                                   maps:update_with(S, fun(L) -> [code_range(Range) | L] end, [code_range(Range)], A)
                           end, #{}, data_lines(ScriptsPath)),
    Known = normalize(lists:append(maps:values(ByScript))),
    Sc0 = maps:map(fun(_, R) -> normalize(R) end, ByScript#{"Zzzz" => complement(Known)}),
    Extensions = [{code_range(Range), [binary_to_list(S) || S <- string:lexemes(Scripts, " ")]}
                  || [Range, Scripts] <- data_lines(ExtensionsPath)],
    Listed = normalize([R || {R, _} <- Extensions]),
    Shorts = lists:usort([S || {_, S} <- Aliases]),
    Sc = [{S, maps:get(S, Sc0, [])} || S <- Shorts],
    Scx = [{S, union(subtract(maps:get(S, Sc0, []), Listed), [R || {R, Ss} <- Extensions, lists:member(S, Ss)])}
           || S <- Shorts],
    {Sc, Scx}.

%% The properties of strings: their single code points as ranges, and their sequences
%% of two or more code points. RGI_Emoji is the union of the others, which the runtime
%% computes.
string_property_data(SequencesPath, ZwjPath) ->
    Rows = [{binary_to_list(Name), Codes} || [Codes, Name | _] <- data_lines(SequencesPath) ++ data_lines(ZwjPath)],
    Entries = lists:append([[{Name, Seq} || Seq <- sequences(Codes)] || {Name, Codes} <- Rows]),
    Names = string_properties(),
    For = fun(Ns) ->
                  Singles = normalize([{C, C} || {N, [C]} <- Entries, lists:member(N, Ns)]),
                  Seqs = lists:usort([S || {N, [_, _ | _] = S} <- Entries, lists:member(N, Ns)]),
                  {Singles, Seqs}
          end,
    All = [{N, For([N])} || N <- Names],
    {[{N, Singles} || {N, {Singles, _}} <- All], [{N, Seqs} || {N, {_, Seqs}} <- All]}.

sequences(Codes) ->
    case binary:split(Codes, <<"..">>) of
        [A, B] -> [[C] || C <- lists:seq(hex(A), hex(B))];
        [_] -> [[hex(C) || C <- string:lexemes(Codes, " ")]]
    end.

%%% Case mappings

%% Simple case folding: the C and S lines of CaseFolding.txt.
case_folding(Path) ->
    [{hex(C), hex(F)} || [C, Status, F | _] <- data_lines(Path), Status =:= <<"C">> orelse Status =:= <<"S">>].

%% Canonicalize of a BMP pattern with the i flag: toUppercase of one code unit, kept only
%% when it is one code unit and it does not move a non-ASCII character into ASCII.
uppercase(DataPath, SpecialPath) ->
    Multi = [hex(C) || [C, _Lower, _Title, Upper | Rest] <- data_lines(SpecialPath),
                       Rest =:= [] orelse Rest =:= [<<>>],
                       length(string:lexemes(Upper, " ")) =/= 1],
    [{C, U} || [Code, _Name, _Gc, _, _, _, _, _, _, _, _, _, Up | _] <- data_lines(DataPath),
               Up =/= <<>>,
               C <- [hex(Code)], U <- [hex(Up)],
               C =< 16#FFFF, U =< 16#FFFF, C =/= U,
               not lists:member(C, Multi),
               not (C >= 128 andalso U < 128)].

%%% Output

header(Version) ->
    ["%% Generated by scripts/regexp-unicode.escript from the Unicode Character Database ", Version, ".\n"
     "%% Do not edit: run the script again for a new Unicode release.\n"
     "%%\n"
     "%% binary_property/1, general_category/1, and script/1 map a name or alias that\n"
     "%% RegExp accepts to the key of ranges/1, or false. ranges/1 returns the code point\n"
     "%% ranges of a key, base64 of LEB128 numbers: the first start, then for each range its\n"
     "%% length minus one and the gap to the next start. strings/1 holds the sequences of\n"
     "%% a property of strings in the same numbers, each sequence its length then its code\n"
     "%% points. scf/1 is simple case folding, upper/1 the Canonicalize of a BMP pattern,\n"
     "%% and scf_classes/0 and upper_classes/0 list each value that several code points\n"
     "%% map to, with those code points.\n"
     "-module(bouy_regexp_unicode).\n\n"
     "-export([version/0, binary_property/1, general_category/1, script/1, ranges/1, strings/1]).\n"
     "-export([scf/1, upper/1, scf_classes/0, upper_classes/0]).\n\n"
     "-spec version() -> string().\n"
     "version() -> \"", Version, "\".\n\n"].

alias_function(Name, Pairs) ->
    F = atom_to_list(Name),
    ["-spec ", F, "(binary()) -> binary() | false.\n",
     [[F, "(<<\"", A, "\">>) -> <<\"", C, "\">>;\n"] || {A, C} <- lists:ukeysort(1, Pairs)],
     F, "(_) -> false.\n\n"].

ranges_function(Entries) ->
    ["-spec ranges(binary()) -> binary().\n",
     [["ranges(<<\"", N, "\">>) -> <<\"", base64:encode(encode_ranges(R)), "\">>;\n"] || {N, R} <- Entries],
     "ranges(_) -> <<>>.\n\n"].

strings_function(Entries) ->
    ["-spec strings(binary()) -> binary().\n",
     [["strings(<<\"", N, "\">>) -> <<\"", base64:encode(encode_strings(S)), "\">>;\n"] || {N, S} <- Entries],
     "strings(_) -> <<>>.\n\n"].

encode_ranges([]) -> <<>>;
encode_ranges([{A, B} | Rest]) -> iolist_to_binary([leb(A), leb(B - A), gaps(B, Rest)]).

gaps(_, []) -> [];
gaps(Prev, [{A, B} | Rest]) -> [leb(A - Prev), leb(B - A) | gaps(B, Rest)].

encode_strings(Seqs) -> iolist_to_binary([[leb(length(S)), [leb(C) || C <- S]] || S <- Seqs]).

leb(N) when N < 128 -> <<N>>;
leb(N) -> <<(N band 127 bor 128), (leb(N bsr 7))/binary>>.

map_function(Name, Pairs) ->
    F = atom_to_list(Name),
    ["-spec ", F, "(non_neg_integer()) -> non_neg_integer().\n",
     [[F, "(", integer_to_list(C), ") -> ", integer_to_list(V), ";\n"] || {C, V} <- lists:keysort(1, Pairs)],
     F, "(C) -> C.\n\n"].

%% Each value that two or more code points map to, with all of them: [{Value, Members}].
classes_function(Name, Pairs) ->
    F = atom_to_list(Name),
    ByValue = lists:foldl(fun({C, V}, A) -> maps:update_with(V, fun(L) -> [C | L] end, [C, V], A) end, #{}, Pairs),
    Classes = [{V, lists:usort(Cs)} || {V, Cs} <- lists:keysort(1, maps:to_list(ByValue))],
    ["-spec ", F, "() -> [{non_neg_integer(), [non_neg_integer(), ...]}].\n",
     F, "() ->\n    ", io_lib:format("~w", [Classes]), ".\n"].
