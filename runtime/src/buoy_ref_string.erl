%% The String family: the representation of JavaScript strings, the String
%% function and its statics, and String.prototype.
%%
%% A JavaScript string is a sequence of UTF-16 code units, which may hold
%% lone surrogates. A string has exactly one form (contract, "Reference
%% semantics"), as the 8-bit and 16-bit buffers of WTF::StringImpl in JSC:
%%
%%   a binary B             every code unit is at most 16#FF: one byte each
%%                          (Latin-1), so ASCII text is the same bytes as UTF-8
%%   {'$u16', B}            at least one code unit is above 16#FF: two bytes
%%                          each, big-endian
%%
%% So length and indexing take constant time, and =:= is string equality.
%% Text enters through from_utf8/1 and leaves through to_utf8/1, at the I/O
%% boundaries: source literals, console output, JSON text, and the host.
-module(buoy_ref_string).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, wrap/2, step/1]).
-export([from_utf8/1, to_utf8/1, from_units/1, units/1, code_points/1, from_code_points/1]).
-export([length_of/1, unit_at/2, unit_string/2, slice/3, concat/1, concat/2, compare/2, get/2]).
-export([index_of/3, is_whitespace/1, narrow/1]).

-export_type([js_string/0]).

-type js_string() :: binary() | {'$u16', binary()}.

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).

%% The longest string, as in V8: 2^29 - 24 code units.
-define(MAX_LENGTH, 536870888).

%%% The family

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Methods = ?METHODS(<<"String.prototype">>, methods()),
    Alias = fun(Name) -> {_, F} = lists:keyfind(Name, 1, Methods), F end,
    [{'String.prototype', record(string, ?OBJECT_PROTO, Methods
         ++ [{<<"length">>, 0, 0}, {<<"constructor">>, constructor()},
             {<<"trimLeft">>, Alias(<<"trimStart">>)}, {<<"trimRight">>, Alias(<<"trimEnd">>)},
             {?SYM(iterator), buoy_ref_realm:builtin(<<"String.prototype[Symbol.iterator]">>, <<"[Symbol.iterator]">>, 0, fun(This, _) -> ?MODULE:method(<<"String.prototype">>, <<"[Symbol.iterator]">>, This, []) end)}], <<>>)},
     {'StringIterator.prototype', record(object, ?ITERATOR_PROTO, ?METHODS(<<"StringIterator.prototype">>, [{<<"next">>, 0}]) ++ [{?SYM(toStringTag), <<"String Iterator">>, 4}], none)},
     {{builtin, <<"String">>}, ctor_record(<<"String">>, 1, {'$o', 'String.prototype'}, ?METHODS(<<"String">>, [{<<"fromCharCode">>, 1}, {<<"fromCodePoint">>, 1}, {<<"raw">>, 1}]), fun construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() ->
    [{<<"String">>, constructor()}]
    ++ ?METHODS(<<"globalThis">>, [{<<"encodeURI">>, 1}, {<<"encodeURIComponent">>, 1}, {<<"decodeURI">>, 1},
                                   {<<"decodeURIComponent">>, 1}, {<<"escape">>, 1}, {<<"unescape">>, 1}]).

constructor() -> buoy_ref_realm:constructor(?MODULE, <<"String">>).

methods() ->
    [{<<"at">>, 1}, {<<"charAt">>, 1}, {<<"charCodeAt">>, 1}, {<<"codePointAt">>, 1}, {<<"concat">>, 1}, {<<"endsWith">>, 1},
     {<<"includes">>, 1}, {<<"indexOf">>, 1}, {<<"isWellFormed">>, 0}, {<<"lastIndexOf">>, 1}, {<<"localeCompare">>, 1},
     {<<"match">>, 1}, {<<"matchAll">>, 1}, {<<"normalize">>, 0}, {<<"padEnd">>, 1}, {<<"padStart">>, 1}, {<<"repeat">>, 1},
     {<<"replace">>, 2}, {<<"replaceAll">>, 2}, {<<"search">>, 1}, {<<"slice">>, 2}, {<<"split">>, 2}, {<<"startsWith">>, 1}, {<<"substring">>, 2}, {<<"substr">>, 2},
     {<<"toLowerCase">>, 0}, {<<"toUpperCase">>, 0}, {<<"toLocaleLowerCase">>, 0}, {<<"toLocaleUpperCase">>, 0},
     {<<"toString">>, 0}, {<<"valueOf">>, 0}, {<<"toWellFormed">>, 0}, {<<"trim">>, 0}, {<<"trimStart">>, 0}, {<<"trimEnd">>, 0}]
    ++ [{Name, case Attribute of none -> 0; _ -> 1 end} || {Name, _Tag, Attribute} <- html_methods()].

%% The HTML methods of Annex B: the tag and the attribute of each.
html_methods() ->
    [{<<"anchor">>, <<"a">>, <<"name">>}, {<<"big">>, <<"big">>, none}, {<<"blink">>, <<"blink">>, none},
     {<<"bold">>, <<"b">>, none}, {<<"fixed">>, <<"tt">>, none}, {<<"fontcolor">>, <<"font">>, <<"color">>},
     {<<"fontsize">>, <<"font">>, <<"size">>}, {<<"italics">>, <<"i">>, none}, {<<"link">>, <<"a">>, <<"href">>},
     {<<"small">>, <<"small">>, none}, {<<"strike">>, <<"strike">>, none}, {<<"sub">>, <<"sub">>, none},
     {<<"sup">>, <<"sup">>, none}].

-spec call_constructor(binary(), term(), list()) -> js_string().
call_constructor(<<"String">>, _This, []) -> <<>>;
call_constructor(<<"String">>, _This, [{'$sym', _, _} = S | _]) -> buoy_ref:describe(S);
call_constructor(<<"String">>, _This, [V | _]) -> buoy_ref:to_string(V).

construct(NewTarget, Args) ->
    S = case Args of
        [] -> <<>>;
        [V | _] -> buoy_ref:to_string(V)
    end,
    wrap(S, buoy_ref_realm:proto_for(NewTarget, 'String.prototype')).

%% StringCreate: a String object, with its code units as read-only index
%% properties and its length.
%% shortcut: the index properties are real properties, so a wrapper costs
%% O(length); a String exotic [[GetOwnProperty]] in buoy_heap would make it
%% constant.
-spec wrap(js_string(), term()) -> term().
wrap(S, Proto) ->
    O = buoy_heap:new_exotic(string, Proto, S),
    [buoy_heap:define(O, I, #{value => unit_string(S, I), writable => false, enumerable => true, configurable => false})
     || I <- lists:seq(0, length_of(S) - 1)],
    buoy_heap:define(O, <<"length">>, #{value => length_of(S), writable => false, enumerable => false, configurable => false}),
    O.

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"String.prototype">>, Name, This, _Args) when Name =:= <<"toString">>; Name =:= <<"valueOf">> ->
    this_string_value(This, Name);
method(<<"String.prototype">>, Name, This, Args)
  when Name =:= <<"match">>; Name =:= <<"matchAll">>; Name =:= <<"replace">>; Name =:= <<"replaceAll">>;
       Name =:= <<"search">>; Name =:= <<"split">> ->
    buoy_ref_regexp:string_method(Name, This, Args);
method(<<"String.prototype">>, Name, This, Args) -> proto(Name, this_string(This, Name), Args);
method(<<"StringIterator.prototype">>, <<"next">>, This, _Args) ->
    ?IS_OBJECT(This) andalso buoy_heap:class_of(This) =:= string_iterator orelse
        buoy_ref:type_error(<<"next method called on incompatible receiver">>),
    case step(This) of
        {value, V} -> buoy_ref_iterator:result(V, false);
        done -> buoy_ref_iterator:result(undefined, true)
    end;
method(<<"globalThis">>, Name, _This, Args) -> uri(Name, buoy_ref:to_string(arg(1, Args)));
method(<<"String">>, <<"fromCharCode">>, _This, Args) ->
    from_units([buoy_ref_number:to_uint32(buoy_ref:to_number(A)) band 16#FFFF || A <- Args]);
method(<<"String">>, <<"fromCodePoint">>, _This, Args) ->
    from_code_points([code_point(buoy_ref:to_number(A)) || A <- Args]);
method(<<"String">>, <<"raw">>, _This, Args) ->
    Cooked = buoy_ref:to_object(arg(1, Args)),
    Literals = buoy_ref:to_object(buoy_ref:get(Cooked, <<"raw">>)),
    Count = buoy_ref_array:length_of(Literals),
    raw(Literals, Count, 0, buoy_ref_realm:rest(2, Args), []).

raw(_Literals, Count, _I, _Subs, Acc) when Count =< 0 -> concat(lists:reverse(Acc));
raw(Literals, Count, I, Subs, Acc) ->
    Acc1 = [buoy_ref:to_string(buoy_ref:get(Literals, I)) | Acc],
    case I + 1 >= Count of
        true -> concat(lists:reverse(Acc1));
        false ->
            case Subs of
                [Sub | Rest] -> raw(Literals, Count, I + 1, Rest, [buoy_ref:to_string(Sub) | Acc1]);
                [] -> raw(Literals, Count, I + 1, [], Acc1)
            end
    end.

this_string(V, Name) when V =:= undefined; V =:= null ->
    buoy_ref:type_error(<<"String.prototype.", Name/binary, " called on null or undefined">>);
this_string(V, _) -> buoy_ref:to_string(V).

%% thisStringValue: a string, or the [[StringData]] of a String object.
this_string_value(S, _Name) when ?IS_STRING(S) -> S;
this_string_value({'$o', _} = O, Name) ->
    case buoy_heap:class_of(O) of
        string -> buoy_heap:slots(O);
        _ -> not_a_string(Name)
    end;
this_string_value(_, Name) -> not_a_string(Name).

-spec not_a_string(binary()) -> no_return().
not_a_string(Name) -> buoy_ref:type_error(<<"String.prototype.", Name/binary, " requires that 'this' be a String">>).

code_point(N) ->
    case N of
        I when is_integer(I), I >= 0, I =< 16#10FFFF -> I;
        Z when Z == 0 -> 0;
        _ -> buoy_heap:throw_error('RangeError', concat(<<"Invalid code point ">>, buoy_ref:to_string(N)))
    end.

%% The next code point of a string iterator: {value, String}, or done.
-spec step(term()) -> {value, js_string()} | done.
step(It) ->
    case buoy_heap:slots(It) of
        {S, I} ->
            case I < length_of(S) of
                true ->
                    End = I + code_unit_count(S, I),
                    buoy_heap:set_slots(It, {S, End}),
                    {value, slice(S, I, End)};
                false ->
                    buoy_heap:set_slots(It, done),
                    done
            end;
        done -> done
    end.

%% The code units of the code point at index I: 2 for a surrogate pair.
code_unit_count(S, I) ->
    case unit_at(S, I) of
        H when H >= 16#D800, H =< 16#DBFF ->
            case I + 1 < length_of(S) andalso unit_at(S, I + 1) of
                L when is_integer(L), L >= 16#DC00, L =< 16#DFFF -> 2;
                _ -> 1
            end;
        _ -> 1
    end.

%% The iterator of a string yields its code points, a surrogate pair as one.
iterator(S) -> buoy_heap:new_exotic(string_iterator, {'$o', 'StringIterator.prototype'}, {S, 0}).

%%% The representation

-spec from_utf8(binary()) -> js_string().
from_utf8(B) ->
    case is_ascii(B) of
        true -> B;
        false -> from_code_points(decode_utf8(B))
    end.

%% UTF-8 to code points; a byte that does not decode becomes U+FFFD.
decode_utf8(B) ->
    case unicode:characters_to_list(B, utf8) of
        Codes when is_list(Codes) -> Codes;
        {_, Good, <<_, Rest/binary>>} -> Good ++ [16#FFFD | decode_utf8(Rest)];
        {_, Good, _} -> Good
    end.

%% The UTF-8 text of a string. A lone surrogate becomes U+FFFD, as Node
%% writes it.
-spec to_utf8(js_string()) -> binary().
to_utf8(B) when is_binary(B) ->
    case is_ascii(B) of
        true -> B;
        false -> unicode:characters_to_binary(B, latin1, utf8)
    end;
to_utf8({'$u16', _} = S) ->
    unicode:characters_to_binary([scalar(C) || C <- code_points(S)]).

scalar(C) when C >= 16#D800, C =< 16#DFFF -> 16#FFFD;
scalar(C) -> C.

is_ascii(<<C, Rest/binary>>) when C < 128 -> is_ascii(Rest);
is_ascii(<<>>) -> true;
is_ascii(_) -> false.

-spec from_units([0..16#FFFF]) -> js_string().
from_units(Units) ->
    case lists:all(fun(U) -> U =< 16#FF end, Units) of
        true -> list_to_binary(Units);
        false -> {'$u16', << <<U:16>> || U <- Units >>}
    end.

-spec units(js_string()) -> [0..16#FFFF].
units(B) when is_binary(B) -> binary_to_list(B);
units({'$u16', B}) -> [U || <<U:16>> <= B].

%% The code points of a string: a surrogate pair is one, a lone surrogate
%% stays itself.
-spec code_points(js_string()) -> [non_neg_integer()].
code_points(B) when is_binary(B) -> binary_to_list(B);
code_points(S) -> pair(units(S)).

pair([H, L | Rest]) when H >= 16#D800, H =< 16#DBFF, L >= 16#DC00, L =< 16#DFFF ->
    [16#10000 + ((H - 16#D800) bsl 10) + (L - 16#DC00) | pair(Rest)];
pair([U | Rest]) -> [U | pair(Rest)];
pair([]) -> [].

-spec from_code_points([non_neg_integer()]) -> js_string().
from_code_points(Codes) -> from_units(lists:flatmap(fun code_units/1, Codes)).

code_units(C) when C > 16#FFFF ->
    V = C - 16#10000,
    [16#D800 + (V bsr 10), 16#DC00 + (V band 16#3FF)];
code_units(C) -> [C].

%% The code units of a two-byte string, or the bytes of a one-byte string
%% widened to two.
wide(B) when is_binary(B) -> << <<C:16>> || <<C>> <= B >>;
wide({'$u16', W}) -> W.

%% The canonical form of a two-byte buffer.
-spec narrow(binary()) -> js_string().
narrow(W) ->
    case is_narrow(W) of
        true -> << <<C>> || <<0, C>> <= W >>;
        false -> {'$u16', W}
    end.

is_narrow(<<0, _, Rest/binary>>) -> is_narrow(Rest);
is_narrow(<<>>) -> true;
is_narrow(_) -> false.

-spec length_of(js_string()) -> non_neg_integer().
length_of(B) when is_binary(B) -> byte_size(B);
length_of({'$u16', B}) -> byte_size(B) div 2.

-spec unit_at(js_string(), non_neg_integer()) -> 0..16#FFFF.
unit_at(B, I) when is_binary(B) -> binary:at(B, I);
unit_at({'$u16', B}, I) ->
    <<_:I/binary-unit:16, U:16, _/binary>> = B,
    U.

%% The string of the one code unit at index I.
-spec unit_string(js_string(), non_neg_integer()) -> js_string().
unit_string(S, I) -> from_units([unit_at(S, I)]).

%% The code units from Start up to End, 0 =< Start =< End =< length.
-spec slice(js_string(), non_neg_integer(), non_neg_integer()) -> js_string().
slice(B, Start, End) when is_binary(B) -> binary:part(B, Start, End - Start);
slice({'$u16', B}, Start, End) -> narrow(binary:part(B, 2 * Start, 2 * (End - Start))).

-spec concat(js_string(), js_string()) -> js_string().
concat(A, B) when is_binary(A), is_binary(B) -> <<A/binary, B/binary>>;
concat(A, B) -> {'$u16', <<(wide(A))/binary, (wide(B))/binary>>}.

-spec concat([js_string()]) -> js_string().
concat(Parts) ->
    case lists:all(fun erlang:is_binary/1, Parts) of
        true -> iolist_to_binary(Parts);
        false -> {'$u16', iolist_to_binary([wide(P) || P <- Parts])}
    end.

%% The order of two strings by code units.
-spec compare(js_string(), js_string()) -> lt | eq | gt.
compare(A, B) when is_binary(A), is_binary(B) -> order(A, B);
compare(A, B) -> order(wide(A), wide(B)).

order(A, A) -> eq;
order(A, B) when A < B -> lt;
order(_, _) -> gt.

%% A property of a string primitive: length, an index, or String.prototype.
-spec get(js_string(), buoy_heap:key()) -> term().
get(S, <<"length">>) -> length_of(S);
get(S, I) when is_integer(I) ->
    case I < length_of(S) of
        true -> unit_string(S, I);
        false -> buoy_ref:get_from(buoy_heap:intrinsic('String.prototype'), I, S)
    end;
get(S, K) -> buoy_ref:get_from(buoy_heap:intrinsic('String.prototype'), K, S).

%% The index of the first Search in S at or after From, or -1.
-spec index_of(js_string(), js_string(), non_neg_integer()) -> integer().
index_of(S, Search, From) ->
    Length = length_of(S),
    case length_of(Search) of
        0 when From =< Length -> From;
        0 -> -1;
        _ when is_binary(S), is_binary(Search) -> find(S, Search, 1, From);
        _ when is_binary(Search) -> find(wide(S), wide(Search), 2, From);
        _ when is_binary(S) -> -1;
        _ -> find(wide(S), wide(Search), 2, From)
    end.

find(Hay, Needle, Width, From) when From * Width =< byte_size(Hay) ->
    Start = From * Width,
    case binary:match(Hay, Needle, [{scope, {Start, byte_size(Hay) - Start}}]) of
        nomatch -> -1;
        {Pos, _} when Pos rem Width =:= 0 -> Pos div Width;
        {Pos, _} -> find(Hay, Needle, Width, Pos div Width + 1)
    end;
find(_, _, _, _) -> -1.

last_index_of(S, Search, From) ->
    Length = length_of(S),
    SearchLength = length_of(Search),
    last_at(S, Search, SearchLength, min(From, Length - SearchLength)).

%% Whether the string holds no lone surrogate.
is_well_formed(B) when is_binary(B) -> true;
is_well_formed(S) -> not lists:any(fun(C) -> C >= 16#D800 andalso C =< 16#DFFF end, code_points(S)).

%% Applies F, a function over a list of Unicode scalars, to each run of S
%% between lone surrogates, which stay as they are.
map_scalars(S, F) ->
    Runs = runs(code_points(S), [], []),
    from_code_points(lists:append([case Run of
                                       {lone, C} -> [C];
                                       Scalars -> F(Scalars)
                                   end || Run <- Runs])).

runs([], [], Acc) -> lists:reverse(Acc);
runs([], Run, Acc) -> lists:reverse([lists:reverse(Run) | Acc]);
runs([C | Rest], Run, Acc) when C >= 16#D800, C =< 16#DFFF ->
    Acc1 = case Run of
        [] -> Acc;
        _ -> [lists:reverse(Run) | Acc]
    end,
    runs(Rest, [], [{lone, C} | Acc1]);
runs([C | Rest], Run, Acc) -> runs(Rest, [C | Run], Acc).

%% The full Unicode case mappings, with the Final_Sigma rule that
%% string:lowercase/1 leaves out.
lowercase(B) when is_binary(B) ->
    case is_ascii(B) of
        true -> string:lowercase(B);
        false -> map_scalars(B, fun lowercase_scalars/1)
    end;
lowercase(S) -> map_scalars(S, fun lowercase_scalars/1).

lowercase_scalars(Scalars) ->
    Marked = final_sigmas(Scalars, []),
    unicode:characters_to_list(string:lowercase(Marked)).

uppercase(B) when is_binary(B) ->
    case is_ascii(B) of
        true -> string:uppercase(B);
        false -> map_scalars(B, fun uppercase_scalars/1)
    end;
uppercase(S) -> map_scalars(S, fun uppercase_scalars/1).

uppercase_scalars(Scalars) -> unicode:characters_to_list(string:uppercase(Scalars)).

%% Replaces each capital sigma in the Final_Sigma context with the final
%% small sigma: after a cased letter and case-ignorable characters, and not
%% before case-ignorable characters and a cased letter.
final_sigmas([], _Before) -> [];
final_sigmas([16#3A3 | Rest], Before) ->
    C = case after_cased(Before) andalso not after_cased(Rest) of
        true -> 16#3C2;
        false -> 16#3A3
    end,
    [C | final_sigmas(Rest, [16#3A3 | Before])];
final_sigmas([C | Rest], Before) -> [C | final_sigmas(Rest, [C | Before])].

%% Whether the nearest character that is not case-ignorable is cased.
after_cased([]) -> false;
after_cased([C | Rest]) ->
    case is_case_ignorable(C) of
        true -> after_cased(Rest);
        false -> is_cased(C)
    end.

is_cased(C) ->
    case unicode_util:category(C) of
        {letter, uppercase} -> true;
        {letter, lowercase} -> true;
        {letter, titlecase} -> true;
        _ -> false
    end.

is_case_ignorable(C) when C =:= $'; C =:= $.; C =:= $:; C =:= 16#B7; C =:= 16#2018; C =:= 16#2019; C =:= 16#2024; C =:= 16#FE52; C =:= 16#FF07; C =:= 16#FF0E -> true;
is_case_ignorable(C) ->
    case unicode_util:category(C) of
        {mark, non_spacing} -> true;
        {mark, enclosing} -> true;
        {other, format} -> true;
        {letter, modifier} -> true;
        {symbol, modifier} -> true;
        _ -> false
    end.

%% localeCompare in the root collation, approximated in three levels as
%% ICU orders them: the base characters (punctuation and spaces in ICU's
%% order, then digits, then letters without case or accents), then the
%% accents in ICU's order of their weights, then lowercase before
%% uppercase. Canonically equivalent strings compare equal.
%% The options of Intl.Collator that localeCompare honors: sensitivity,
%% numeric, and caseFirst.
locale_compare(A, B, Options) ->
    KeyA = collation_key(A, Options),
    KeyB = collation_key(B, Options),
    if
        KeyA < KeyB -> -1;
        KeyA > KeyB -> 1;
        true -> 0
    end.

collation_options(O) when ?IS_OBJECT(O) ->
    Sensitivity = case buoy_ref:get(O, <<"sensitivity">>) of
        undefined -> variant;
        V ->
            case buoy_ref:to_string(V) of
                <<"base">> -> base;
                <<"accent">> -> accent;
                <<"case">> -> 'case';
                <<"variant">> -> variant;
                _ -> buoy_heap:throw_error('RangeError', <<"Value of sensitivity is out of range">>)
            end
    end,
    CaseFirst = case buoy_ref:get(O, <<"caseFirst">>) of
        undefined -> lower;
        F ->
            case buoy_ref:to_string(F) of
                <<"upper">> -> upper;
                _ -> lower
            end
    end,
    #{sensitivity => Sensitivity, numeric => buoy_ref:truthy(buoy_ref:get(O, <<"numeric">>)), case_first => CaseFirst};
collation_options(_) -> #{sensitivity => variant, numeric => false, case_first => lower}.

collation_key(S, #{sensitivity := Sensitivity, numeric := Numeric, case_first := CaseFirst}) ->
    Decomposed = unicode:characters_to_nfd_list([scalar(C) || C <- code_points(S)]),
    Elements = collation_elements(case Numeric of
                                      true -> numbers(Decomposed);
                                      false -> Decomposed
                                  end),
    Primary = [P || {P, _, _} <- Elements],
    Secondary = [W || {_, W, _} <- Elements],
    Tertiary = [case CaseFirst of upper -> 1 - T; lower -> T end || {_, _, T} <- Elements],
    case Sensitivity of
        base -> {Primary};
        accent -> {Primary, Secondary};
        'case' -> {Primary, Tertiary};
        variant -> {Primary, Secondary, Tertiary}
    end.

%% For numeric collation, each run of ASCII digits becomes {number, Value}.
numbers([]) -> [];
numbers([C | _] = Chars) when C >= $0, C =< $9 ->
    {Digits, Rest} = lists:splitwith(fun(D) -> D >= $0 andalso D =< $9 end, Chars),
    [{number, list_to_integer(Digits)} | numbers(Rest)];
numbers([C | Rest]) -> [C | numbers(Rest)].

%% The {Primary, Secondary, Tertiary} weights of each base character, its
%% accents folded into its secondary weight.
collation_elements([]) -> [];
collation_elements([{number, N} | Rest]) -> [{{2, N}, [], 0} | collation_elements(Rest)];
collation_elements([C | Rest]) ->
    {Marks, Rest1} = lists:splitwith(fun is_mark/1, Rest),
    Accents = [mark_weight(M) || M <- Marks],
    Case = case_weight(C),
    Expanded = case expansion(C) of
        {Letters, Extra} -> [{primary(L), Accents ++ Extra, Case} || L <- Letters];
        none -> [{primary(C), Accents, Case}]
    end,
    Expanded ++ collation_elements(Rest1).

%% The letters that the root collation spells as others with a secondary
%% difference: ß as ss, æ as ae, ø as o, and so on.
expansion(C) when C =:= 16#DF; C =:= 16#1E9E -> {"ss", [90]};
expansion(C) when C =:= 16#E6; C =:= 16#C6 -> {"ae", [90]};
expansion(C) when C =:= 16#153; C =:= 16#152 -> {"oe", [90]};
expansion(C) when C =:= 16#F8; C =:= 16#D8 -> {"o", [90]};
expansion(C) when C =:= 16#F0; C =:= 16#D0 -> {"d", [90]};
expansion(C) when C =:= 16#FE; C =:= 16#DE -> {"th", [90]};
expansion(_) -> none.

%% Spaces and ASCII punctuation in ICU's order, then other symbols, then
%% digits, then letters.
primary(C) ->
    case string:chr(" _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$", C) of
        I when I > 0 -> {0, I};
        0 when C >= $0, C =< $9 -> {2, C};
        0 ->
            case unicode_util:category(C) of
                {letter, _} -> {3, hd(unicode:characters_to_list(string:casefold([C])) ++ [C])};
                {number, _} -> {2, C};
                _ when C < 128 -> {0, 100 + C};
                _ -> {1, C}
            end
    end.

%% The secondary weights of the common accents, in ICU's order.
mark_weight(M) ->
    case string:chr([16#301, 16#300, 16#306, 16#302, 16#30C, 16#30A, 16#308, 16#30B, 16#303, 16#307, 16#327, 16#328, 16#304, 16#323, 16#331], M) of
        0 -> 100 + M;
        I -> I
    end.

is_mark({number, _}) -> false;
is_mark(C) ->
    case unicode_util:category(C) of
        {mark, _} -> true;
        _ -> false
    end.

case_weight(C) ->
    case unicode_util:category(C) of
        {letter, uppercase} -> 1;
        {letter, titlecase} -> 1;
        _ -> 0
    end.

last_at(_S, _Search, _Length, I) when I < 0 -> -1;
last_at(S, Search, Length, I) ->
    case slice(S, I, I + Length) =:= Search of
        true -> I;
        false -> last_at(S, Search, Length, I - 1)
    end.

%% WhiteSpace and LineTerminator, for trim and StringToNumber.
-spec is_whitespace(0..16#FFFF) -> boolean().
is_whitespace(C) ->
    C =:= 9 orelse C =:= 10 orelse C =:= 11 orelse C =:= 12 orelse C =:= 13 orelse C =:= 32 orelse
        C =:= 16#A0 orelse C =:= 16#1680 orelse (C >= 16#2000 andalso C =< 16#200A) orelse
        C =:= 16#2028 orelse C =:= 16#2029 orelse C =:= 16#202F orelse C =:= 16#205F orelse
        C =:= 16#3000 orelse C =:= 16#FEFF.

%%% String.prototype

proto(<<"[Symbol.iterator]">>, S, _Args) -> iterator(S);
proto(Name, S, Args) when Name =:= <<"anchor">>; Name =:= <<"big">>; Name =:= <<"blink">>; Name =:= <<"bold">>;
                          Name =:= <<"fixed">>; Name =:= <<"fontcolor">>; Name =:= <<"fontsize">>; Name =:= <<"italics">>;
                          Name =:= <<"link">>; Name =:= <<"small">>; Name =:= <<"strike">>; Name =:= <<"sub">>; Name =:= <<"sup">> ->
    {_, Tag, Attribute} = lists:keyfind(Name, 1, html_methods()),
    Open = case Attribute of
        none -> [<<"<">>, Tag];
        _ ->
            Value = buoy_ref:to_string(arg(1, Args)),
            Escaped = from_units(lists:flatmap(fun($") -> units(<<"&quot;">>); (U) -> [U] end, units(Value))),
            [<<"<">>, Tag, <<" ">>, Attribute, <<"=\"">>, Escaped, <<"\"">>]
    end,
    concat(Open ++ [<<">">>, S, <<"</">>, Tag, <<">">>]);
proto(<<"at">>, S, Args) ->
    Length = length_of(S),
    case integer(arg(1, Args)) of
        I when is_integer(I), I < 0, I + Length >= 0 -> unit_string(S, I + Length);
        I when is_integer(I), I >= 0, I < Length -> unit_string(S, I);
        _ -> undefined
    end;
proto(<<"charAt">>, S, Args) ->
    case position(S, arg(1, Args)) of
        {ok, I} -> unit_string(S, I);
        none -> <<>>
    end;
proto(<<"charCodeAt">>, S, Args) ->
    case position(S, arg(1, Args)) of
        {ok, I} -> unit_at(S, I);
        none -> 'NaN'
    end;
proto(<<"codePointAt">>, S, Args) ->
    case position(S, arg(1, Args)) of
        {ok, I} -> hd(pair(units(slice(S, I, I + code_unit_count(S, I)))));
        none -> undefined
    end;
proto(<<"concat">>, S, Args) -> concat([S | [buoy_ref:to_string(A) || A <- Args]]);
proto(<<"endsWith">>, S, Args) ->
    Search = search_string(<<"endsWith">>, arg(1, Args)),
    End = clamp(arg(2, Args), length_of(S), length_of(S)),
    Start = End - length_of(Search),
    Start >= 0 andalso slice(S, Start, End) =:= Search;
proto(<<"startsWith">>, S, Args) ->
    Search = search_string(<<"startsWith">>, arg(1, Args)),
    Start = clamp(arg(2, Args), 0, length_of(S)),
    End = Start + length_of(Search),
    End =< length_of(S) andalso slice(S, Start, End) =:= Search;
proto(<<"includes">>, S, Args) ->
    Search = search_string(<<"includes">>, arg(1, Args)),
    index_of(S, Search, clamp(arg(2, Args), 0, length_of(S))) >= 0;
proto(<<"indexOf">>, S, Args) ->
    Search = buoy_ref:to_string(arg(1, Args)),
    index_of(S, Search, clamp(arg(2, Args), 0, length_of(S)));
proto(<<"lastIndexOf">>, S, Args) ->
    Search = buoy_ref:to_string(arg(1, Args)),
    From = case buoy_ref:to_number(arg(2, Args)) of
        'NaN' -> length_of(S);
        N -> bound(buoy_ref_number:to_integer_or_infinity(N), 0, length_of(S))
    end,
    last_index_of(S, Search, From);
proto(<<"isWellFormed">>, S, _Args) -> is_well_formed(S);
proto(<<"toWellFormed">>, S, _Args) ->
    case is_well_formed(S) of
        true -> S;
        false -> from_code_points([scalar(C) || C <- code_points(S)])
    end;
proto(<<"localeCompare">>, S, Args) -> locale_compare(S, buoy_ref:to_string(arg(1, Args)), collation_options(arg(3, Args)));
proto(<<"padEnd">>, S, Args) -> pad(S, arg(1, Args), arg(2, Args), trailing);
proto(<<"padStart">>, S, Args) -> pad(S, arg(1, Args), arg(2, Args), leading);
proto(<<"repeat">>, S, Args) ->
    case integer(arg(1, Args)) of
        N when is_integer(N), N >= 0 ->
            N * length_of(S) > ?MAX_LENGTH andalso invalid_length(),
            case S of
                <<>> -> <<>>;
                _ when is_binary(S) -> binary:copy(S, N);
                {'$u16', W} -> {'$u16', binary:copy(W, N)}
            end;
        _ -> buoy_heap:throw_error('RangeError', concat(<<"Invalid count value: ">>, buoy_ref:to_string(buoy_ref:to_number(arg(1, Args)))))
    end;
proto(<<"slice">>, S, Args) ->
    Length = length_of(S),
    Start = relative(arg(1, Args), 0, Length),
    End = relative(arg(2, Args), Length, Length),
    slice(S, Start, max(Start, End));
proto(<<"substring">>, S, Args) ->
    Length = length_of(S),
    A = clamp(arg(1, Args), 0, Length),
    B = case arg(2, Args) of
        undefined -> Length;
        E -> clamp(E, 0, Length)
    end,
    slice(S, min(A, B), max(A, B));
proto(<<"substr">>, S, Args) ->
    Length = length_of(S),
    Start = relative(arg(1, Args), 0, Length),
    Count = case arg(2, Args) of
        undefined -> Length - Start;
        C -> clamp(C, 0, Length - Start)
    end,
    slice(S, Start, Start + Count);
proto(Name, S, _Args) when Name =:= <<"toLowerCase">>; Name =:= <<"toLocaleLowerCase">> -> lowercase(S);
proto(Name, S, _Args) when Name =:= <<"toUpperCase">>; Name =:= <<"toLocaleUpperCase">> -> uppercase(S);
proto(<<"trim">>, S, _Args) -> trim(S, both);
proto(<<"trimStart">>, S, _Args) -> trim(S, leading);
proto(<<"trimEnd">>, S, _Args) -> trim(S, trailing);
proto(<<"normalize">>, S, Args) ->
    Form = case arg(1, Args) of
        undefined -> <<"NFC">>;
        F -> buoy_ref:to_string(F)
    end,
    Normalize = case Form of
        <<"NFC">> -> fun unicode:characters_to_nfc_list/1;
        <<"NFD">> -> fun unicode:characters_to_nfd_list/1;
        <<"NFKC">> -> fun unicode:characters_to_nfkc_list/1;
        <<"NFKD">> -> fun unicode:characters_to_nfkd_list/1;
        _ -> buoy_heap:throw_error('RangeError', <<"The normalization form should be one of NFC, NFD, NFKC, NFKD.">>)
    end,
    map_scalars(S, Normalize).

%% endsWith, startsWith, and includes reject a regular expression (IsRegExp).
search_string(Name, V) ->
    case buoy_ref_regexp:is_regexp(V) of
        true -> buoy_ref:type_error(<<"First argument to String.prototype.", Name/binary, " must not be a regular expression">>);
        false -> buoy_ref:to_string(V)
    end.

-spec invalid_length() -> no_return().
invalid_length() -> buoy_heap:throw_error('RangeError', <<"Invalid string length">>).

%% ToIntegerOrInfinity of an argument.
integer(V) -> buoy_ref_number:to_integer_or_infinity(buoy_ref:to_number(V)).

%% An index argument clamped to [Low, High].
clamp(undefined, Default, _High) -> Default;
clamp(V, _Default, High) -> bound(integer(V), 0, High).

bound('-Infinity', Low, _High) -> Low;
bound('Infinity', _Low, High) -> High;
bound(I, Low, High) -> min(max(I, Low), High).

%% A relative index argument: negative counts from the end.
relative(undefined, Default, _Length) -> Default;
relative(V, _Default, Length) ->
    case integer(V) of
        '-Infinity' -> 0;
        'Infinity' -> Length;
        I when I < 0 -> max(0, Length + I);
        I -> min(I, Length)
    end.

position(S, V) ->
    case integer(V) of
        I when is_integer(I), I >= 0 ->
            case I < length_of(S) of
                true -> {ok, I};
                false -> none
            end;
        _ -> none
    end.

pad(S, MaxLengthArg, FillArg, Side) ->
    Length = length_of(S),
    MaxLength = bound(integer(MaxLengthArg), 0, 16#1FFFFFFFFFFFFF),
    Fill = case FillArg of
        undefined -> <<" ">>;
        _ -> buoy_ref:to_string(FillArg)
    end,
    case MaxLength =< Length orelse Fill =:= <<>> of
        true -> S;
        false ->
            MaxLength > ?MAX_LENGTH andalso invalid_length(),
            Needed = MaxLength - Length,
            Copies = Needed div length_of(Fill) + 1,
            Padding = slice(concat(lists:duplicate(Copies, Fill)), 0, Needed),
            case Side of
                leading -> concat(Padding, S);
                trailing -> concat(S, Padding)
            end
    end.

trim(S, Side) ->
    Units = units(S),
    Start = case Side of
        trailing -> Units;
        _ -> lists:dropwhile(fun is_whitespace/1, Units)
    end,
    Both = case Side of
        leading -> Start;
        _ -> lists:reverse(lists:dropwhile(fun is_whitespace/1, lists:reverse(Start)))
    end,
    from_units(Both).

%%% The URI functions and escape

uri(<<"encodeURI">>, S) -> encode(S, <<";/?:@&=+$,#">>);
uri(<<"encodeURIComponent">>, S) -> encode(S, <<>>);
uri(<<"decodeURI">>, S) -> decode(S, <<";/?:@&=+$,#">>);
uri(<<"decodeURIComponent">>, S) -> decode(S, <<>>);
uri(<<"escape">>, S) -> escape(units(S));
uri(<<"unescape">>, S) -> from_units(unescape(units(S))).

-spec uri_error() -> no_return().
uri_error() -> buoy_heap:throw_error('URIError', <<"URI malformed">>).

is_uri_unreserved(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse (C >= $0 andalso C =< $9)
        orelse lists:member(C, "-_.!~*'()").

%% Encode: the code points outside the unescaped set as %XX of their UTF-8.
encode(S, Extra) ->
    Reserved = binary_to_list(Extra),
    Out = lists:flatmap(fun(C) ->
                                case C < 128 andalso (is_uri_unreserved(C) orelse lists:member(C, Reserved)) of
                                    true -> [C];
                                    false ->
                                        C >= 16#D800 andalso C =< 16#DFFF andalso uri_error(),
                                        lists:flatten([io_lib:format("%~2.16.0B", [B]) || <<B>> <= <<C/utf8>>])
                                end
                        end, code_points(S)),
    list_to_binary(Out).

%% Decode: each %XX sequence as UTF-8, except the escapes of the preserved
%% characters, which stay as they are.
decode(S, Preserve) -> from_code_points(decode_units(units(S), binary_to_list(Preserve))).

decode_units([], _Preserve) -> [];
decode_units([$% | Rest], Preserve) ->
    {B, Rest1} = hex_byte(Rest),
    case B < 16#80 of
        true ->
            case lists:member(B, Preserve) of
                true -> [$%, hd(Rest), hd(tl(Rest)) | decode_units(Rest1, Preserve)];
                false -> [B | decode_units(Rest1, Preserve)]
            end;
        false ->
            N = leading_ones(B),
            (N =:= 1 orelse N > 4) andalso uri_error(),
            {Continuation, Rest2} = continuation_bytes(Rest1, N - 1, []),
            Bytes = list_to_binary([B | Continuation]),
            case unicode:characters_to_list(Bytes, utf8) of
                [C] when is_integer(C) -> [C | decode_units(Rest2, Preserve)];
                _ -> uri_error()
            end
    end;
decode_units([C | Rest], Preserve) -> [C | decode_units(Rest, Preserve)].

hex_byte([A, B | Rest]) ->
    case {hex_value(A), hex_value(B)} of
        {X, Y} when is_integer(X), is_integer(Y) -> {X * 16 + Y, Rest};
        _ -> uri_error()
    end;
hex_byte(_) -> uri_error().

hex_value(C) when C >= $0, C =< $9 -> C - $0;
hex_value(C) when C >= $a, C =< $f -> C - $a + 10;
hex_value(C) when C >= $A, C =< $F -> C - $A + 10;
hex_value(_) -> error.

leading_ones(B) when B band 16#80 =:= 0 -> 0;
leading_ones(B) when B band 16#40 =:= 0 -> 1;
leading_ones(B) when B band 16#20 =:= 0 -> 2;
leading_ones(B) when B band 16#10 =:= 0 -> 3;
leading_ones(B) when B band 16#08 =:= 0 -> 4;
leading_ones(_) -> 5.

continuation_bytes(Rest, 0, Acc) -> {lists:reverse(Acc), Rest};
continuation_bytes([$% | Rest], N, Acc) ->
    {B, Rest1} = hex_byte(Rest),
    B band 16#C0 =:= 16#80 orelse uri_error(),
    continuation_bytes(Rest1, N - 1, [B | Acc]);
continuation_bytes(_, _, _) -> uri_error().

%% escape of Annex B.
escape(Units) ->
    list_to_binary(lists:flatmap(fun(U) ->
                                         case (U >= $a andalso U =< $z) orelse (U >= $A andalso U =< $Z) orelse (U >= $0 andalso U =< $9) orelse lists:member(U, "@*_+-./") of
                                             true -> [U];
                                             false when U < 256 -> io_lib:format("%~2.16.0B", [U]);
                                             false -> io_lib:format("%u~4.16.0B", [U])
                                         end
                                 end, Units)).

%% unescape of Annex B.
unescape([$%, $u, A, B, C, D | Rest] = Units) ->
    case [hex_value(X) || X <- [A, B, C, D]] of
        [W, X, Y, Z] when is_integer(W), is_integer(X), is_integer(Y), is_integer(Z) ->
            [((W * 16 + X) * 16 + Y) * 16 + Z | unescape(Rest)];
        _ -> [hd(Units) | unescape(tl(Units))]
    end;
unescape([$%, A, B | Rest] = Units) ->
    case {hex_value(A), hex_value(B)} of
        {X, Y} when is_integer(X), is_integer(Y) -> [X * 16 + Y | unescape(Rest)];
        _ -> [hd(Units) | unescape(tl(Units))]
    end;
unescape([U | Rest]) -> [U | unescape(Rest)];
unescape([]) -> [].
