%% internalBinding('buffer') (src/node_buffer.cc): the byte operations of
%% Buffer on the bytes of typed arrays, with the encodings of
%% buoy_node_encoding.
-module(buoy_binding_buffer).

-include("buoy_ref.hrl").

-export([binding/0]).

-import(buoy_node_encoding, [view_bytes/1, view_bytes/3, view_write/3, view_length/1]).

%% Buffer.constants.MAX_LENGTH and MAX_STRING_LENGTH of Node 25 on 64-bit
%% machines, which bounds-check the arguments of Buffer.
-define(K_MAX_LENGTH, 9007199254740991).
-define(K_STRING_MAX_LENGTH, 536870888).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    Slices = [{<<"asciiSlice">>, ascii}, {<<"base64Slice">>, base64}, {<<"base64urlSlice">>, base64url},
              {<<"latin1Slice">>, latin1}, {<<"hexSlice">>, hex}, {<<"ucs2Slice">>, ucs2}, {<<"utf8Slice">>, utf8}],
    Writes = [{<<"base64Write">>, base64}, {<<"base64urlWrite">>, base64url}, {<<"hexWrite">>, hex},
              {<<"ucs2Write">>, ucs2}, {<<"asciiWriteStatic">>, ascii}, {<<"latin1WriteStatic">>, latin1},
              {<<"utf8WriteStatic">>, utf8}],
    buoy_node:object(
        [{Name, F(Name, 3, fun(_, Args) -> slice(Encoding, A(1, Args), A(2, Args), A(3, Args)) end)} || {Name, Encoding} <- Slices]
        ++ [{Name, F(Name, 4, fun(_, Args) -> write(Encoding, A(1, Args), A(2, Args), A(3, Args), A(4, Args)) end)} || {Name, Encoding} <- Writes]
        ++ [
        {<<"setBufferPrototype">>, F(<<"setBufferPrototype">>, 1, fun(_, Args) ->
            erlang:put('$buoy_node_buffer_proto', A(1, Args)),
            undefined
        end)},
        {<<"createUnsafeArrayBuffer">>, F(<<"createUnsafeArrayBuffer">>, 1, fun(_, Args) ->
            C = buoy_ref_realm:global(<<"ArrayBuffer">>),
            buoy_heap:construct(C, [A(1, Args)], C)
        end)},
        {<<"byteLengthUtf8">>, F(<<"byteLengthUtf8">>, 1, fun(_, Args) -> buoy_node_encoding:utf8_length(A(1, Args)) end)},
        {<<"copy">>, F(<<"copy">>, 5, fun(_, Args) -> copy(Args) end)},
        {<<"copyArrayBuffer">>, F(<<"copyArrayBuffer">>, 5, fun(_, Args) ->
            [Dest, DestOffset, Source, SourceOffset, Count] = [A(I, Args) || I <- lists:seq(1, 5)],
            view_write(Dest, int(DestOffset), view_bytes(Source, int(SourceOffset), int(SourceOffset) + int(Count))),
            undefined
        end)},
        {<<"compare">>, F(<<"compare">>, 2, fun(_, Args) -> compare(view_bytes(A(1, Args)), view_bytes(A(2, Args))) end)},
        {<<"compareOffset">>, F(<<"compareOffset">>, 6, fun(_, Args) -> compare_offset(Args) end)},
        {<<"fill">>, F(<<"fill">>, 5, fun(_, Args) -> fill(Args) end)},
        {<<"indexOfBuffer">>, F(<<"indexOfBuffer">>, 5, fun(_, Args) ->
            Step = case buoy_node_encoding:from_enum(A(4, Args)) of ucs2 -> 2; _ -> 1 end,
            index_of(A(1, Args), view_bytes(A(2, Args)), A(3, Args), A(5, Args), Step)
        end)},
        {<<"indexOfNumber">>, F(<<"indexOfNumber">>, 4, fun(_, Args) ->
            index_of_number(view_bytes(A(1, Args)), int(A(2, Args)) band 255, A(3, Args), buoy_ref:truthy(A(4, Args)))
        end)},
        {<<"indexOfString">>, F(<<"indexOfString">>, 5, fun(_, Args) ->
            Encoding = buoy_node_encoding:from_enum(A(4, Args)),
            Step = case Encoding of ucs2 -> 2; _ -> 1 end,
            index_of(A(1, Args), buoy_node_encoding:encode(Encoding, A(2, Args)), A(3, Args), A(5, Args), Step)
        end)},
        {<<"swap16">>, F(<<"swap16">>, 1, fun(_, Args) -> swap(A(1, Args), 2) end)},
        {<<"swap32">>, F(<<"swap32">>, 1, fun(_, Args) -> swap(A(1, Args), 4) end)},
        {<<"swap64">>, F(<<"swap64">>, 1, fun(_, Args) -> swap(A(1, Args), 8) end)},
        {<<"isUtf8">>, F(<<"isUtf8">>, 1, fun(_, Args) -> is_utf8(validated_bytes(A(1, Args))) end)},
        {<<"isAscii">>, F(<<"isAscii">>, 1, fun(_, Args) -> lists:all(fun(C) -> C < 128 end, binary_to_list(validated_bytes(A(1, Args)))) end)},
        {<<"kMaxLength">>, ?K_MAX_LENGTH},
        {<<"kStringMaxLength">>, ?K_STRING_MAX_LENGTH},
        {<<"atob">>, F(<<"atob">>, 1, fun(_, Args) -> atob(A(1, Args)) end)},
        {<<"btoa">>, F(<<"btoa">>, 1, fun(_, Args) -> btoa(A(1, Args)) end)},
        {<<"setDetachKey">>, F(<<"setDetachKey">>, 2, fun(_, _) -> undefined end)}]).

int(undefined) -> 0;
int(V) ->
    case buoy_ref:to_number(V) of
        N when is_integer(N) -> N;
        N when is_float(N) -> trunc(N);
        'Infinity' -> ?K_MAX_LENGTH;
        _ -> 0
    end.

%% ParseArrayIndex: undefined gives Default, a negative index is out of range.
index_arg(undefined, Default) -> Default;
index_arg(V, _Default) ->
    case int(V) of
        N when N < 0 -> out_of_range();
        N -> N
    end.

-spec out_of_range() -> no_return().
out_of_range() -> buoy_node:throw_code('RangeError', <<"ERR_OUT_OF_RANGE">>, <<"Index out of range">>).

slice(Encoding, View, Start, End) ->
    Length = view_length(View),
    case Length of
        0 ->
            <<>>;
        _ ->
            S = index_arg(Start, 0),
            E0 = index_arg(End, Length),
            E = max(S, E0),
            E =< Length orelse out_of_range(),
            string_length(Encoding, E - S) > 16#1fffffe8 andalso too_long(),
            buoy_node_encoding:decode(Encoding, view_bytes(View, S, E))
    end.

%% The length of the string that Count bytes decode to, at most: V8 makes no
%% string longer than 0x1fffffe8 code units, so Node throws before it reads.
string_length(ucs2, Count) -> Count div 2;
string_length(hex, Count) -> Count * 2;
string_length(Base64, Count) when Base64 =:= base64; Base64 =:= base64url -> (Count + 2) div 3 * 4;
string_length(_, Count) -> Count.

-spec too_long() -> no_return().
too_long() ->
    buoy_node:throw_code('Error', <<"ERR_STRING_TOO_LONG">>, <<"Cannot create a string longer than 0x1fffffe8 characters">>).

write(Encoding, View, String, Offset, MaxLength) ->
    ?IS_STRING(String) orelse buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>, <<"argument must be a string">>),
    Length = view_length(View),
    At = index_arg(Offset, 0),
    At =< Length orelse buoy_node:throw_code('RangeError', <<"ERR_BUFFER_OUT_OF_BOUNDS">>, <<"\"offset\" is outside of buffer bounds">>),
    Max = min(Length - At, index_arg(MaxLength, Length - At)),
    case Max of
        0 ->
            0;
        _ ->
            Bytes = fit(Encoding, String, Max),
            view_write(View, At, Bytes),
            byte_size(Bytes)
    end.

%% The bytes of String in Encoding that fit in Max bytes: UTF-8 keeps whole
%% characters, UTF-16 whole code units.
fit(utf8, String, Max) ->
    Bytes = buoy_ref_string:to_utf8(String),
    case byte_size(Bytes) =< Max of
        true -> Bytes;
        false -> whole_utf8(Bytes, Max)
    end;
fit(ucs2, String, Max) ->
    Bytes = buoy_node_encoding:encode(ucs2, String),
    binary:part(Bytes, 0, min(byte_size(Bytes), Max - Max rem 2));
fit(Encoding, String, Max) ->
    Bytes = buoy_node_encoding:encode(Encoding, String),
    binary:part(Bytes, 0, min(byte_size(Bytes), Max)).

%% The longest prefix of Max bytes or fewer that ends on a character
%% boundary.
whole_utf8(Bytes, Max) ->
    Cut = boundary(Bytes, Max),
    binary:part(Bytes, 0, Cut).

boundary(_Bytes, 0) -> 0;
boundary(Bytes, Cut) ->
    case binary:at(Bytes, Cut) of
        C when C band 16#C0 =:= 16#80 -> boundary(Bytes, Cut - 1);
        _ -> Cut
    end.

%% copy(source, target, targetStart, sourceStart, nb)
copy(Args) ->
    [Source, Target, TargetStart, SourceStart, Count] = [buoy_node:arg(I, Args) || I <- lists:seq(1, 5)],
    S = int(SourceStart),
    N = int(Count),
    view_write(Target, int(TargetStart), view_bytes(Source, S, S + N)),
    N.

compare(A, B) when A < B -> -1;
compare(A, B) when A > B -> 1;
compare(_, _) -> 0.

%% compareOffset(source, target, targetStart, sourceStart, targetEnd, sourceEnd)
compare_offset(Args) ->
    [Source, Target, TargetStart, SourceStart, TargetEnd, SourceEnd] = [buoy_node:arg(I, Args) || I <- lists:seq(1, 6)],
    SourceLength = view_length(Source),
    TargetLength = view_length(Target),
    TS = index_arg(TargetStart, 0),
    SS = index_arg(SourceStart, 0),
    TE = index_arg(TargetEnd, TargetLength),
    SE = index_arg(SourceEnd, SourceLength),
    SS =< SourceLength orelse buoy_node:throw_code('RangeError', <<"ERR_OUT_OF_RANGE">>, <<"The value of \"sourceStart\" is out of range.">>),
    TS =< TargetLength orelse buoy_node:throw_code('RangeError', <<"ERR_OUT_OF_RANGE">>, <<"The value of \"targetStart\" is out of range.">>),
    Len = min(min(max(0, SE - SS), max(0, TE - TS)), SourceLength - SS),
    A = view_bytes(Source, SS, SS + Len),
    B = view_bytes(Target, TS, TS + Len),
    case compare(A, B) of
        0 -> compare(max(0, SE - SS), max(0, TE - TS));
        R -> R
    end.

%% fill(buffer, value, start, end, encoding): -2 when the range is out of
%% bounds, -1 when the value encodes to no bytes.
fill(Args) ->
    [View, Value, Start, End, Encoding] = [buoy_node:arg(I, Args) || I <- lists:seq(1, 5)],
    Length = view_length(View),
    S = index_arg(Start, 0),
    E = index_arg(End, 0),
    case S > E orelse E > Length of
        true ->
            -2;
        false ->
            Count = E - S,
            Pattern = case Value of
                V when ?IS_STRING(V) ->
                    Enc = case buoy_node_encoding:parse(Encoding) of
                        {ok, Found} -> Found;
                        error -> utf8
                    end,
                    buoy_node_encoding:encode(Enc, V);
                V when ?IS_OBJECT(V) ->
                    case buoy_heap:class_of(V) of
                        typed_array -> view_bytes(V);
                        _ -> <<(int(V) band 255)>>
                    end;
                V ->
                    <<(int(V) band 255)>>
            end,
            case {Pattern, Count} of
                {_, 0} -> undefined;
                {<<>>, _} -> -1;
                _ ->
                    Repeated = binary:copy(Pattern, Count div byte_size(Pattern) + 1),
                    view_write(View, S, binary:part(Repeated, 0, Count)),
                    undefined
            end
    end.

%% indexOf over the bytes of View: the first match at or after the offset,
%% or for a backward search the last match at or before it. Step is 2 for
%% UTF-16, whose matches start at even indexes.
%% IndexOfString and IndexOfBuffer of node_buffer.cc: the byte index of the
%% first match at or after the offset, or of the last one at or before it.
%% A UCS-2 search runs over whole code units.
index_of(View, Needle, ByteOffset, Forward, Step) ->
    Haystack = view_bytes(View),
    Length = byte_size(Haystack),
    NeedleLength = byte_size(Needle),
    IsForward = buoy_ref:truthy(Forward),
    Offset = search_offset(Length, integer(ByteOffset), NeedleLength, IsForward),
    if
        NeedleLength =:= 0 -> Offset;
        Length =:= 0 -> -1;
        Offset =< -1 -> -1;
        IsForward andalso NeedleLength + Offset > Length -> -1;
        NeedleLength > Length -> -1;
        Step =:= 2 andalso (Length < 2 orelse NeedleLength < 2) -> -1;
        Step =:= 2 ->
            Units = binary:part(Haystack, 0, Length - Length rem 2),
            Unit = binary:part(Needle, 0, NeedleLength - NeedleLength rem 2),
            Start = (Offset div 2) * 2,
            case IsForward of
                true -> search_forward(Units, Unit, Start, 2);
                false -> search_backward(Units, Unit, min(Start, byte_size(Units) - byte_size(Unit)) div 2 * 2, 2)
            end;
        IsForward -> search_forward(Haystack, Needle, Offset, 1);
        true -> search_backward(Haystack, Needle, min(Offset, Length - NeedleLength), 1)
    end.

%% IndexOfNumber: memchr from the offset, or memrchr up to it.
index_of_number(Haystack, Byte, ByteOffset, IsForward) ->
    Length = byte_size(Haystack),
    case search_offset(Length, integer(ByteOffset), 1, IsForward) of
        Offset when Offset =< -1; Length =:= 0 -> -1;
        Offset when IsForward -> search_forward(Haystack, <<Byte>>, Offset, 1);
        Offset -> search_backward(Haystack, <<Byte>>, min(Offset, Length - 1), 1)
    end.

integer(V) ->
    case buoy_ref:to_number(V) of
        N when is_integer(N) -> N;
        N when is_float(N) -> trunc(N);
        'Infinity' -> 16#7FFFFFFF;
        '-Infinity' -> -16#80000000;
        _ -> 0
    end.

%% IndexOfOffset: where a search starts, or -1 when none can match.
search_offset(Length, Offset, NeedleLength, IsForward) when Offset < 0 ->
    if
        Offset + Length >= 0 -> Length + Offset;
        IsForward orelse NeedleLength =:= 0 -> 0;
        true -> -1
    end;
search_offset(Length, Offset, NeedleLength, IsForward) ->
    if
        Offset + NeedleLength =< Length -> Offset;
        NeedleLength =:= 0 -> Length;
        IsForward -> -1;
        true -> Length - 1
    end.

search_forward(Haystack, Needle, From, Step) when From + byte_size(Needle) =< byte_size(Haystack) ->
    case binary:match(Haystack, Needle, [{scope, {From, byte_size(Haystack) - From}}]) of
        {At, _} when (At - From) rem Step =:= 0 -> At;
        {At, _} -> search_forward(Haystack, Needle, At + 1, Step);
        nomatch -> -1
    end;
search_forward(_, _, _, _) -> -1.

search_backward(_Haystack, _Needle, At, _Step) when At < 0 -> -1;
search_backward(Haystack, Needle, At, Step) ->
    case binary:part(Haystack, At, byte_size(Needle)) =:= Needle andalso At rem Step =:= 0 of
        true -> At;
        false -> search_backward(Haystack, Needle, At - 1, Step)
    end.

swap(View, Size) ->
    Bytes = view_bytes(View),
    Swapped = << <<(reverse(Unit))/binary>> || <<Unit:Size/binary>> <= Bytes >>,
    view_write(View, 0, Swapped),
    undefined.

reverse(Bin) -> list_to_binary(lists:reverse(binary_to_list(Bin))).

%% The bytes that isUtf8 and isAscii check: a detached buffer is
%% ERR_INVALID_STATE, as in node_buffer.cc.
validated_bytes(View) ->
    Buffer = case buoy_heap:class_of(View) of
        typed_array -> element(2, buoy_heap:slots(View));
        data_view -> element(1, buoy_heap:slots(View));
        _ -> View
    end,
    buoy_ref_buffer:is_detached(Buffer) andalso
        buoy_node:throw_code('Error', <<"ERR_INVALID_STATE">>, <<"Cannot validate on a detached buffer">>),
    view_bytes(View).

is_utf8(Bytes) ->
    case unicode:characters_to_list(Bytes, utf8) of
        L when is_list(L) -> not lists:any(fun(C) -> C >= 16#D800 andalso C =< 16#DFFF end, L);
        _ -> false
    end.

%% atob(input): forgiving base64 (WHATWG), -2 for an invalid character, -1
%% for a lone last character.
atob(Input) ->
    Units = buoy_ref_string:units(buoy_ref:to_string(Input)),
    Clean = [U || U <- Units, not lists:member(U, [9, 10, 12, 13, 32])],
    Trimmed = case length(Clean) rem 4 of
        0 -> strip_padding(Clean);
        _ -> Clean
    end,
    case lists:all(fun is_base64/1, Trimmed) of
        false ->
            -2;
        true when length(Trimmed) rem 4 =:= 1 ->
            -1;
        true ->
            buoy_node_encoding:encode(base64, list_to_binary(Trimmed))
    end.

strip_padding(Units) ->
    case lists:reverse(Units) of
        [$=, $= | Rest] -> lists:reverse(Rest);
        [$= | Rest] -> lists:reverse(Rest);
        _ -> Units
    end.

is_base64(C) -> (C >= $A andalso C =< $Z) orelse (C >= $a andalso C =< $z) orelse (C >= $0 andalso C =< $9)
                    orelse C =:= $+ orelse C =:= $/.

%% btoa(input): -1 for a code unit above 0xFF.
btoa(Input) ->
    Units = buoy_ref_string:units(buoy_ref:to_string(Input)),
    case lists:all(fun(U) -> U =< 16#FF end, Units) of
        true -> base64:encode(list_to_binary(Units));
        false -> -1
    end.
