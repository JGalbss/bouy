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
-module(bouy_ref_string).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).
-export([from_utf8/1, to_utf8/1, from_units/1, units/1, code_points/1, from_code_points/1]).
-export([length_of/1, unit_at/2, unit_string/2, slice/3, concat/1, concat/2, compare/2, get/2]).
-export([index_of/3, is_whitespace/1]).

-export_type([js_string/0]).

-type js_string() :: binary() | {'$u16', binary()}.

-import(bouy_ref_realm, [arg/2, builtin/2, record/4, ctor_record/5]).

%%% The family

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'String.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"String.prototype">>, methods()) ++ [{<<"constructor">>, constructor()}, {?SYM(iterator), builtin(<<"String.prototype[Symbol.iterator]">>, fun(This, _) -> iterator(This) end)}], none)},
     {{builtin, <<"String">>}, ctor_record(<<"String">>, 1, {'$o', 'String.prototype'}, ?METHODS(<<"String">>, [<<"fromCharCode">>, <<"fromCodePoint">>]), fun bouy_ref_realm:not_constructible/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"String">>, constructor()}].

constructor() -> bouy_ref_realm:constructor(?MODULE, <<"String">>).

methods() ->
    [<<"at">>, <<"charAt">>, <<"charCodeAt">>, <<"codePointAt">>, <<"concat">>, <<"endsWith">>, <<"includes">>, <<"indexOf">>,
     <<"lastIndexOf">>, <<"localeCompare">>, <<"match">>, <<"matchAll">>, <<"padEnd">>, <<"padStart">>, <<"repeat">>,
     <<"replace">>, <<"replaceAll">>, <<"search">>, <<"slice">>, <<"split">>, <<"startsWith">>, <<"substring">>, <<"substr">>, <<"toLowerCase">>, <<"toUpperCase">>,
     <<"toLocaleLowerCase">>, <<"toLocaleUpperCase">>, <<"toString">>, <<"valueOf">>, <<"trim">>, <<"trimStart">>,
     <<"trimEnd">>, <<"normalize">>].

-spec call_constructor(binary(), term(), list()) -> js_string().
call_constructor(<<"String">>, _This, []) -> <<>>;
call_constructor(<<"String">>, _This, [{'$sym', _, _} = S | _]) -> bouy_ref:describe(S);
call_constructor(<<"String">>, _This, [V | _]) -> bouy_ref:to_string(V).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"String.prototype">>, Name, This, Args)
  when Name =:= <<"match">>; Name =:= <<"matchAll">>; Name =:= <<"replace">>; Name =:= <<"replaceAll">>;
       Name =:= <<"search">>; Name =:= <<"split">> ->
    bouy_ref_regexp:string_method(Name, This, Args);
method(<<"String.prototype">>, Name, This, Args) -> proto(Name, this_string(This, Name), Args);
method(<<"String">>, <<"fromCharCode">>, _This, Args) ->
    from_units([bouy_ref_number:to_uint32(bouy_ref:to_number(A)) band 16#FFFF || A <- Args]);
method(<<"String">>, <<"fromCodePoint">>, _This, Args) ->
    from_code_points([code_point(bouy_ref:to_number(A)) || A <- Args]).

this_string(V, Name) when V =:= undefined; V =:= null ->
    bouy_ref:type_error(<<"String.prototype.", Name/binary, " called on null or undefined">>);
this_string(V, _) -> bouy_ref:to_string(V).

code_point(N) when is_integer(N), N >= 0, N =< 16#10FFFF -> N;
code_point(N) -> bouy_heap:throw_error('RangeError', concat(<<"Invalid code point ">>, bouy_ref:to_string(N))).

%% The iterator of a string yields its code points, a surrogate pair as one.
iterator(This) ->
    S = this_string(This, <<"[Symbol.iterator]">>),
    bouy_ref_iterator:list_iterator(<<"String Iterator">>, [from_code_points([C]) || C <- code_points(S)]).

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
-spec get(js_string(), bouy_heap:key()) -> term().
get(S, <<"length">>) -> length_of(S);
get(S, I) when is_integer(I) ->
    case I < length_of(S) of
        true -> unit_string(S, I);
        false -> bouy_heap:get({'$o', 'String.prototype'}, I)
    end;
get(_S, K) -> bouy_heap:get({'$o', 'String.prototype'}, K).

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
        {ok, I} -> hd(pair(units(slice(S, I, min(I + 2, length_of(S))))));
        none -> undefined
    end;
proto(<<"concat">>, S, Args) -> concat([S | [bouy_ref:to_string(A) || A <- Args]]);
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
    index_of(S, bouy_ref:to_string(arg(1, Args)), clamp(arg(2, Args), 0, length_of(S)));
proto(<<"lastIndexOf">>, S, Args) ->
    Search = bouy_ref:to_string(arg(1, Args)),
    From = case bouy_ref:to_number(arg(2, Args)) of
        'NaN' -> length_of(S);
        N -> clamp(N, 0, length_of(S))
    end,
    last_index_of(S, Search, From);
proto(<<"localeCompare">>, S, Args) ->
    bouy_string:call(<<"localeCompare">>, to_utf8(S), [to_utf8(bouy_ref:to_string(arg(1, Args)))]);
proto(<<"padEnd">>, S, Args) -> pad(S, arg(1, Args), arg(2, Args), trailing);
proto(<<"padStart">>, S, Args) -> pad(S, arg(1, Args), arg(2, Args), leading);
proto(<<"repeat">>, S, Args) ->
    case integer(arg(1, Args)) of
        N when is_integer(N), N >= 0 -> concat(lists:duplicate(N, S));
        _ -> bouy_heap:throw_error('RangeError', concat(<<"Invalid count value: ">>, bouy_ref:to_string(bouy_ref:to_number(arg(1, Args)))))
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
proto(Name, S, _Args) when Name =:= <<"toLowerCase">>; Name =:= <<"toLocaleLowerCase">> ->
    from_utf8(string:lowercase(to_utf8(S)));
proto(Name, S, _Args) when Name =:= <<"toUpperCase">>; Name =:= <<"toLocaleUpperCase">> ->
    from_utf8(string:uppercase(to_utf8(S)));
proto(Name, S, _Args) when Name =:= <<"toString">>; Name =:= <<"valueOf">> -> S;
proto(<<"trim">>, S, _Args) -> trim(S, both);
proto(<<"trimStart">>, S, _Args) -> trim(S, leading);
proto(<<"trimEnd">>, S, _Args) -> trim(S, trailing);
proto(<<"normalize">>, S, Args) ->
    Form = case arg(1, Args) of
        undefined -> <<"NFC">>;
        F -> bouy_ref:to_string(F)
    end,
    Text = to_utf8(S),
    Normal = case Form of
        <<"NFC">> -> unicode:characters_to_nfc_binary(Text);
        <<"NFD">> -> unicode:characters_to_nfd_binary(Text);
        <<"NFKC">> -> unicode:characters_to_nfkc_binary(Text);
        <<"NFKD">> -> unicode:characters_to_nfkd_binary(Text);
        _ -> bouy_heap:throw_error('RangeError', <<"The normalization form should be one of NFC, NFD, NFKC, NFKD.">>)
    end,
    from_utf8(Normal).

%% endsWith, startsWith, and includes reject a regular expression (IsRegExp).
search_string(Name, V) ->
    case bouy_ref_regexp:is_regexp(V) of
        true -> bouy_ref:type_error(<<"First argument to String.prototype.", Name/binary, " must not be a regular expression">>);
        false -> bouy_ref:to_string(V)
    end.

%% ToIntegerOrInfinity of an argument.
integer(V) -> bouy_ref_number:to_integer_or_infinity(bouy_ref:to_number(V)).

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
        _ -> bouy_ref:to_string(FillArg)
    end,
    case MaxLength =< Length orelse Fill =:= <<>> of
        true -> S;
        false ->
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
