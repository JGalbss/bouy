%% The `String` namespace and string methods. Strings are UTF-8 binaries,
%% and lengths and indexes count code points (contract section 3).
-module(bouy_string).

-export(['$member'/1, '$call'/1, new/1, call/3, get/2]).
-export(['fromCharCode'/1, 'fromCodePoint'/1]).
-export([char_count/1, trim/1, trim_start/1]).

-define(FUNCTIONS, [<<"fromCharCode">>, <<"fromCodePoint">>]).
-define(METHODS, [
    <<"at">>, <<"charAt">>, <<"charCodeAt">>, <<"codePointAt">>, <<"concat">>, <<"endsWith">>, <<"includes">>,
    <<"indexOf">>, <<"lastIndexOf">>, <<"localeCompare">>, <<"match">>, <<"matchAll">>, <<"padEnd">>,
    <<"padStart">>, <<"repeat">>, <<"replace">>, <<"replaceAll">>, <<"search">>, <<"slice">>, <<"split">>,
    <<"startsWith">>, <<"substr">>, <<"substring">>, <<"toLocaleLowerCase">>, <<"toLocaleUpperCase">>,
    <<"toLowerCase">>, <<"toString">>, <<"toUpperCase">>, <<"trim">>, <<"trimEnd">>, <<"trimLeft">>,
    <<"trimRight">>, <<"trimStart">>, <<"valueOf">>
]).

%%% Namespace

-spec '$member'(binary()) -> term().
'$member'(Name) -> bouy_rt:member_function(?MODULE, Name, ?FUNCTIONS).

%% `String(x)`.
-spec '$call'(list()) -> binary().
'$call'([]) -> <<>>;
'$call'([Value | _]) -> bouy_rt:to_string(Value).

%% `new String(x)` yields the primitive: Bouy has no wrapper objects.
-spec new(list()) -> binary().
new(Args) -> '$call'(Args).

%% UTF-16 code units in; surrogate pairs combine, and a lone surrogate
%% becomes U+FFFD because UTF-8 cannot hold it.
-spec 'fromCharCode'(list()) -> binary().
'fromCharCode'(Args) ->
    encode(combine_surrogates([bouy_rt:to_uint32(Arg) band 16#FFFF || Arg <- Args])).

combine_surrogates([High, Low | Rest]) when High >= 16#D800, High =< 16#DBFF, Low >= 16#DC00, Low =< 16#DFFF ->
    [16#10000 + ((High - 16#D800) bsl 10) + (Low - 16#DC00) | combine_surrogates(Rest)];
combine_surrogates([Unit | Rest]) ->
    [Unit | combine_surrogates(Rest)];
combine_surrogates([]) ->
    [].

-spec 'fromCodePoint'(list()) -> binary().
'fromCodePoint'(Args) ->
    encode([code_point(bouy_rt:to_number(Arg)) || Arg <- Args]).

code_point(N) when is_integer(N), N >= 0, N =< 16#10FFFF -> N;
code_point(F) when is_float(F), F == trunc(F) -> code_point(trunc(F));
code_point(N) -> bouy_error:throw(<<"RangeError">>, <<"Invalid code point ", (bouy_rt:to_string(N))/binary>>).

encode(CodePoints) ->
    <<<<(scalar(C))/utf8>> || C <- CodePoints>>.

scalar(C) when C >= 16#D800, C =< 16#DFFF -> 16#FFFD;
scalar(C) -> C.

%%% Properties

-spec get(binary(), term()) -> term().
get(S, <<"length">>) ->
    char_count(S);
get(S, Key) ->
    case bouy_rt:to_index(Key) of
        I when is_integer(I) -> char_at(S, I, undefined);
        none -> bouy_rt:member(?MODULE, Key, ?METHODS)
    end.

%%% Methods

-spec call(binary(), binary(), list()) -> term().
call(<<"at">>, S, Args) -> at(S, bouy_rt:arg(1, Args));
call(<<"charAt">>, S, Args) -> char_at(S, position(bouy_rt:arg(1, Args)), <<>>);
call(<<"charCodeAt">>, S, Args) -> code_at(S, position(bouy_rt:arg(1, Args)), 'NaN');
call(<<"codePointAt">>, S, Args) -> code_at(S, position(bouy_rt:arg(1, Args)), undefined);
call(<<"concat">>, S, Args) -> bouy_rt:concat([S | Args]);
call(<<"endsWith">>, S, Args) -> ends_with(S, search_text(<<"endsWith">>, Args), bouy_rt:arg(2, Args));
call(<<"includes">>, S, Args) -> index_of(S, search_text(<<"includes">>, Args), bouy_rt:arg(2, Args)) >= 0;
call(<<"indexOf">>, S, Args) -> index_of(S, bouy_rt:to_string(bouy_rt:arg(1, Args)), bouy_rt:arg(2, Args));
call(<<"lastIndexOf">>, S, Args) -> last_index_of(S, bouy_rt:to_string(bouy_rt:arg(1, Args)), bouy_rt:arg(2, Args));
call(<<"localeCompare">>, S, Args) -> locale_compare(S, bouy_rt:to_string(bouy_rt:arg(1, Args)));
call(<<"padEnd">>, S, Args) -> pad(S, bouy_rt:arg(1, Args), bouy_rt:arg(2, Args), trailing);
call(<<"padStart">>, S, Args) -> pad(S, bouy_rt:arg(1, Args), bouy_rt:arg(2, Args), leading);
call(<<"repeat">>, S, Args) -> repeat(S, bouy_rt:arg(1, Args));
call(<<"replace">>, S, Args) -> replace(S, pattern(<<"replace">>, Args), bouy_rt:arg(2, Args), first);
call(<<"replaceAll">>, S, Args) -> replace(S, pattern(<<"replaceAll">>, Args), bouy_rt:arg(2, Args), all);
call(<<"slice">>, S, Args) -> slice(S, bouy_rt:arg(1, Args), bouy_rt:arg(2, Args));
call(<<"split">>, S, Args) -> split(S, bouy_rt:arg(1, Args), bouy_rt:arg(2, Args));
call(<<"startsWith">>, S, Args) -> starts_with(S, search_text(<<"startsWith">>, Args), bouy_rt:arg(2, Args));
call(<<"substring">>, S, Args) -> substring(S, bouy_rt:arg(1, Args), bouy_rt:arg(2, Args));
call(<<"substr">>, S, Args) -> substr(S, bouy_rt:arg(1, Args), bouy_rt:arg(2, Args));
call(<<"toLowerCase">>, S, _Args) -> string:lowercase(S);
call(<<"toLocaleLowerCase">>, S, _Args) -> string:lowercase(S);
call(<<"toUpperCase">>, S, _Args) -> string:uppercase(S);
call(<<"toLocaleUpperCase">>, S, _Args) -> string:uppercase(S);
call(<<"toString">>, S, _Args) -> S;
call(<<"valueOf">>, S, _Args) -> S;
call(<<"trim">>, S, _Args) -> trim(S);
call(<<"trimStart">>, S, _Args) -> trim_start(S);
call(<<"trimEnd">>, S, _Args) -> trim_end(S);
call(<<"trimLeft">>, S, _Args) -> trim_start(S);
call(<<"trimRight">>, S, _Args) -> trim_end(S);
call(Name, _S, _Args) when Name =:= <<"match">>; Name =:= <<"matchAll">>; Name =:= <<"search">> -> no_regexp(Name);
call(Name, S, Args) -> bouy_rt:prototype_call(S, Name, Args).

%% An index argument that must name a code point: out-of-range values,
%% infinities included, become -1.
position(Arg) ->
    case bouy_rt:to_integer(Arg) of
        I when is_integer(I) -> I;
        _ -> -1
    end.

at(S, Arg) ->
    case bouy_rt:to_integer(Arg) of
        I when is_integer(I), I < 0 -> char_at(S, char_count(S) + I, undefined);
        I when is_integer(I) -> char_at(S, I, undefined);
        _ -> undefined
    end.

char_at(S, I, Missing) ->
    case code_at(S, I, none) of
        none -> Missing;
        C -> <<C/utf8>>
    end.

code_at(_S, I, Missing) when I < 0 ->
    Missing;
code_at(S, I, Missing) ->
    Offset = offset(S, I),
    case S of
        <<_:Offset/binary, C/utf8, _/binary>> -> C;
        _ -> Missing
    end.

slice(S, Start, End) ->
    Length = char_count(S),
    From = bouy_rt:relative_index(Start, Length, 0),
    To = bouy_rt:relative_index(End, Length, Length),
    chars(S, From, max(From, To)).

substring(S, Start, End) ->
    Length = char_count(S),
    From = bouy_rt:clamp(Start, 0, Length),
    To =
        case End of
            undefined -> Length;
            _ -> bouy_rt:clamp(End, 0, Length)
        end,
    chars(S, min(From, To), max(From, To)).

substr(S, Start, Count) ->
    Length = char_count(S),
    From = bouy_rt:relative_index(Start, Length, 0),
    Size =
        case Count of
            undefined -> Length - From;
            _ -> bouy_rt:clamp(Count, 0, Length - From)
        end,
    chars(S, From, From + Size).

%% The code points [From, To) of S.
chars(S, From, To) ->
    Start = offset(S, From),
    binary:part(S, Start, offset(S, To) - Start).

%% The byte offset of code point N.
offset(S, N) when byte_size(S) =:= N -> N;
offset(S, N) -> offset(S, N, 0).

offset(_S, 0, Pos) ->
    Pos;
offset(S, N, Pos) ->
    case S of
        <<_:Pos/binary, C, _/binary>> when C < 16#80 -> offset(S, N - 1, Pos + 1);
        <<_:Pos/binary, C, _/binary>> when C >= 16#F0 -> offset(S, N - 1, Pos + 4);
        <<_:Pos/binary, C, _/binary>> when C >= 16#E0 -> offset(S, N - 1, Pos + 3);
        <<_:Pos/binary, _, _/binary>> -> offset(S, N - 1, Pos + 2);
        _ -> Pos
    end.

%% The number of code points: every byte that does not continue a sequence.
-spec char_count(binary()) -> non_neg_integer().
char_count(S) ->
    byte_size(S) - byte_size(<<<<C>> || <<C>> <= S, C band 16#C0 =:= 16#80>>).

%% The code point index of a byte offset.
char_index(S, Pos) ->
    char_count(binary:part(S, 0, Pos)).

index_of(S, Search, FromArg) ->
    From = bouy_rt:clamp(FromArg, 0, char_count(S)),
    case Search of
        <<>> ->
            From;
        _ ->
            Start = offset(S, From),
            case binary:match(S, Search, [{scope, {Start, byte_size(S) - Start}}]) of
                {Pos, _} -> char_index(S, Pos);
                nomatch -> -1
            end
    end.

last_index_of(S, Search, FromArg) ->
    Length = char_count(S),
    From =
        case bouy_rt:to_number(FromArg) of
            'NaN' -> Length;
            _ -> bouy_rt:clamp(FromArg, 0, Length)
        end,
    Limit = offset(S, From),
    Candidates = [Pos || Pos <- match_positions(S, Search, 0), Pos =< Limit],
    case Candidates of
        [] -> -1;
        _ -> char_index(S, lists:last(Candidates))
    end.

%% Every byte offset where Search starts, overlapping matches included.
match_positions(S, <<>>, _) ->
    [offset(S, I) || I <- lists:seq(0, char_count(S))];
match_positions(S, Search, Start) ->
    case binary:match(S, Search, [{scope, {Start, byte_size(S) - Start}}]) of
        {Pos, _} -> [Pos | match_positions(S, Search, Pos + 1)];
        nomatch -> []
    end.

starts_with(S, Search, PositionArg) ->
    Start = offset(S, bouy_rt:clamp(PositionArg, 0, char_count(S))),
    Size = byte_size(Search),
    case S of
        <<_:Start/binary, Search:Size/binary, _/binary>> -> true;
        _ -> false
    end.

ends_with(S, Search, EndArg) ->
    Length = char_count(S),
    End =
        case EndArg of
            undefined -> byte_size(S);
            _ -> offset(S, bouy_rt:clamp(EndArg, 0, Length))
        end,
    Size = byte_size(Search),
    Start = End - Size,
    Start >= 0 andalso binary:part(S, Start, Size) =:= Search.

locale_compare(A, B) when A < B -> -1;
locale_compare(A, B) when A > B -> 1;
locale_compare(_, _) -> 0.

pad(S, MaxLengthArg, FillArg, Side) ->
    Length = char_count(S),
    MaxLength = bouy_rt:clamp(MaxLengthArg, 0, 16#1FFFFFFFFFFFFF),
    Fill =
        case FillArg of
            undefined -> <<" ">>;
            _ -> bouy_rt:to_string(FillArg)
        end,
    case MaxLength =< Length orelse Fill =:= <<>> of
        true -> S;
        false -> padded(S, padding(Fill, MaxLength - Length), Side)
    end.

padding(Fill, Count) ->
    FillLength = char_count(Fill),
    chars(binary:copy(Fill, (Count + FillLength - 1) div FillLength), 0, Count).

padded(S, Padding, leading) -> <<Padding/binary, S/binary>>;
padded(S, Padding, trailing) -> <<S/binary, Padding/binary>>.

repeat(S, CountArg) ->
    case bouy_rt:to_integer(CountArg) of
        N when is_integer(N), N >= 0 -> binary:copy(S, N);
        _ -> bouy_error:throw(<<"RangeError">>, <<"Invalid count value: ", (bouy_rt:to_string(bouy_rt:to_number(CountArg)))/binary>>)
    end.

%%% split, replace, and replaceAll with string patterns

split(S, undefined, LimitArg) ->
    limit([S], LimitArg);
split(S, Separator, LimitArg) ->
    case pattern_text(<<"split">>, Separator) of
        <<>> -> limit(bouy_rt:to_list(S), LimitArg);
        Text -> limit(binary:split(S, Text, [global]), LimitArg)
    end.

limit(Parts, undefined) -> Parts;
limit(Parts, LimitArg) -> lists:sublist(Parts, bouy_rt:to_uint32(LimitArg)).

replace(S, Pattern, Replacement, Mode) ->
    Matches = matches(S, Pattern, Mode),
    {Parts, Last} = lists:mapfoldl(
        fun(Pos, Previous) ->
            Text = [binary:part(S, Previous, Pos - Previous), replacement(Replacement, S, Pos, Pattern)],
            {Text, Pos + byte_size(Pattern)}
        end,
        0,
        Matches
    ),
    iolist_to_binary([Parts, binary:part(S, Last, byte_size(S) - Last)]).

matches(_S, <<>>, first) ->
    [0];
matches(S, <<>>, all) ->
    match_positions(S, <<>>, 0);
matches(S, Pattern, first) ->
    case binary:match(S, Pattern) of
        {Pos, _} -> [Pos];
        nomatch -> []
    end;
matches(S, Pattern, all) ->
    [Pos || {Pos, _} <- binary:matches(S, Pattern)].

replacement(F, S, Pos, Matched) when is_function(F) ->
    bouy_rt:to_string(bouy_rt:call(F, [Matched, char_index(S, Pos), S]));
replacement(Template, S, Pos, Matched) ->
    substitute(bouy_rt:to_string(Template), S, Pos, Matched).

%% GetSubstitution for a string pattern: `$$`, `$&`, `` $` ``, and `$'`.
substitute(<<"$$", Rest/binary>>, S, Pos, Matched) ->
    [$$ | substitute(Rest, S, Pos, Matched)];
substitute(<<"$&", Rest/binary>>, S, Pos, Matched) ->
    [Matched | substitute(Rest, S, Pos, Matched)];
substitute(<<"$`", Rest/binary>>, S, Pos, Matched) ->
    [binary:part(S, 0, Pos) | substitute(Rest, S, Pos, Matched)];
substitute(<<"$'", Rest/binary>>, S, Pos, Matched) ->
    End = Pos + byte_size(Matched),
    [binary:part(S, End, byte_size(S) - End) | substitute(Rest, S, Pos, Matched)];
substitute(<<C, Rest/binary>>, S, Pos, Matched) ->
    [C | substitute(Rest, S, Pos, Matched)];
substitute(<<>>, _S, _Pos, _Matched) ->
    [].

pattern(Method, Args) ->
    pattern_text(Method, bouy_rt:arg(1, Args)).

%% A pattern argument as text. Bouy does not support regular expressions
%% yet, so an object pattern is an error instead of being converted.
pattern_text(Method, Pattern) when is_map(Pattern); is_tuple(Pattern) -> no_regexp(Method);
pattern_text(_Method, Pattern) -> bouy_rt:to_string(Pattern).

search_text(Method, Args) ->
    pattern_text(Method, bouy_rt:arg(1, Args)).

-spec no_regexp(binary()) -> no_return().
no_regexp(Method) ->
    bouy_error:throw(<<"TypeError">>, <<"String.prototype.", Method/binary, " takes a string pattern: Bouy does not support regular expressions yet">>).

%%% Whitespace

%% JavaScript WhiteSpace and LineTerminator code points.
-define(IS_SPACE(C),
    (C =:= 9 orelse C =:= 10 orelse C =:= 11 orelse C =:= 12 orelse C =:= 13 orelse C =:= 32 orelse
        C =:= 16#A0 orelse C =:= 16#1680 orelse (C >= 16#2000 andalso C =< 16#200A) orelse
        C =:= 16#2028 orelse C =:= 16#2029 orelse C =:= 16#202F orelse C =:= 16#205F orelse
        C =:= 16#3000 orelse C =:= 16#FEFF)
).

-spec trim(binary()) -> binary().
trim(S) -> trim_end(trim_start(S)).

-spec trim_start(binary()) -> binary().
trim_start(<<C/utf8, Rest/binary>>) when ?IS_SPACE(C) -> trim_start(Rest);
trim_start(S) -> S.

trim_end(S) ->
    binary:part(S, 0, content_end(S, 0, 0)).

%% The byte offset just past the last code point that is not whitespace.
content_end(S, Pos, End) ->
    case S of
        <<_:Pos/binary, C/utf8, _/binary>> when ?IS_SPACE(C) -> content_end(S, Pos + utf8_size(C), End);
        <<_:Pos/binary, C/utf8, _/binary>> -> content_end(S, Pos + utf8_size(C), Pos + utf8_size(C));
        _ -> End
    end.

utf8_size(C) when C < 16#80 -> 1;
utf8_size(C) when C < 16#800 -> 2;
utf8_size(C) when C < 16#10000 -> 3;
utf8_size(_) -> 4.
