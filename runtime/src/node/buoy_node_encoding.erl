%% The byte encodings of Node (src/string_bytes.cc): JavaScript strings to and
%% from bytes in utf8, utf16le, latin1, ascii, hex, base64, and base64url,
%% and the bytes of typed arrays. Buffer, string_decoder, and fs share them.
-module(buoy_node_encoding).

-include("buoy_ref.hrl").

-export([parse/1, from_enum/1, encode/2, decode/2, decode_utf8/1, utf8_length/1]).
-export([view_bytes/1, view_bytes/3, view_write/3, view_length/1, new_buffer/1]).
-export([write_buffer_bytes/1]).

-type encoding() :: utf8 | ucs2 | latin1 | ascii | hex | base64 | base64url | buffer.
-export_type([encoding/0]).

%% The encoding of a name, as Node's ParseEncoding reads it, or error.
-spec parse(term()) -> {ok, encoding()} | error.
parse(Name) when ?IS_STRING(Name) ->
    case string:lowercase(buoy_ref_string:to_utf8(Name)) of
        <<"utf8">> -> {ok, utf8};
        <<"utf-8">> -> {ok, utf8};
        <<"ucs2">> -> {ok, ucs2};
        <<"ucs-2">> -> {ok, ucs2};
        <<"utf16le">> -> {ok, ucs2};
        <<"utf-16le">> -> {ok, ucs2};
        <<"latin1">> -> {ok, latin1};
        <<"binary">> -> {ok, latin1};
        <<"ascii">> -> {ok, ascii};
        <<"hex">> -> {ok, hex};
        <<"base64">> -> {ok, base64};
        <<"base64url">> -> {ok, base64url};
        <<"buffer">> -> {ok, buffer};
        _ -> error
    end;
parse(_) ->
    error.

%% The encoding of Node's enum encoding (src/node.h), as encodingsMap of
%% internal/util numbers them.
-spec from_enum(term()) -> encoding().
from_enum(0) -> ascii;
from_enum(1) -> utf8;
from_enum(2) -> base64;
from_enum(3) -> ucs2;
from_enum(4) -> latin1;
from_enum(5) -> hex;
from_enum(6) -> buffer;
from_enum(7) -> base64url;
from_enum(_) -> utf8.

%%% Strings to bytes

-spec encode(encoding(), term()) -> binary().
encode(utf8, S) -> buoy_ref_string:to_utf8(S);
encode(buffer, S) -> buoy_ref_string:to_utf8(S);
encode(ucs2, S) -> << <<U:16/little>> || U <- buoy_ref_string:units(S) >>;
encode(latin1, S) -> latin1(S);
encode(ascii, S) -> latin1(S);
encode(hex, S) -> unhex(latin1(S), []);
encode(base64, S) -> unbase64(latin1(S));
encode(base64url, S) -> unbase64(latin1(S)).

latin1(B) when is_binary(B) -> B;
latin1(S) -> << <<(U band 16#FF)>> || U <- buoy_ref_string:units(S) >>.

%% Pairs of hex digits until the first pair that is not one.
unhex(<<A, B, Rest/binary>>, Acc) ->
    case {hex_value(A), hex_value(B)} of
        {H, L} when is_integer(H), is_integer(L) -> unhex(Rest, [H * 16 + L | Acc]);
        _ -> list_to_binary(lists:reverse(Acc))
    end;
unhex(_, Acc) ->
    list_to_binary(lists:reverse(Acc)).

hex_value(C) when C >= $0, C =< $9 -> C - $0;
hex_value(C) when C >= $a, C =< $f -> C - $a + 10;
hex_value(C) when C >= $A, C =< $F -> C - $A + 10;
hex_value(_) -> none.

%% Node's lenient base64: both alphabets, characters outside them skipped,
%% and the text ends at the first '='.
unbase64(Text) ->
    Sextets = sextets(Text, []),
    groups(Sextets, []).

sextets(<<$=, _/binary>>, Acc) -> lists:reverse(Acc);
sextets(<<C, Rest/binary>>, Acc) ->
    case sextet(C) of
        none -> sextets(Rest, Acc);
        V -> sextets(Rest, [V | Acc])
    end;
sextets(<<>>, Acc) -> lists:reverse(Acc).

sextet(C) when C >= $A, C =< $Z -> C - $A;
sextet(C) when C >= $a, C =< $z -> C - $a + 26;
sextet(C) when C >= $0, C =< $9 -> C - $0 + 52;
sextet($+) -> 62;
sextet($-) -> 62;
sextet($/) -> 63;
sextet($_) -> 63;
sextet(_) -> none.

groups([A, B, C, D | Rest], Acc) ->
    groups(Rest, [<<A:6, B:6, C:6, D:6>> | Acc]);
groups([A, B, C], Acc) ->
    <<X:16, _:2>> = <<A:6, B:6, C:6>>,
    iolist_to_binary(lists:reverse([<<X:16>> | Acc]));
groups([A, B], Acc) ->
    <<X:8, _:4>> = <<A:6, B:6>>,
    iolist_to_binary(lists:reverse([<<X:8>> | Acc]));
groups(_, Acc) ->
    iolist_to_binary(lists:reverse(Acc)).

%% The number of UTF-8 bytes of a string: a lone surrogate takes three.
-spec utf8_length(term()) -> non_neg_integer().
utf8_length(B) when is_binary(B) ->
    byte_size(B) + length([C || <<C>> <= B, C >= 16#80]);
utf8_length(S) ->
    lists:sum([cp_length(C) || C <- buoy_ref_string:code_points(S)]).

cp_length(C) when C < 16#80 -> 1;
cp_length(C) when C < 16#800 -> 2;
cp_length(C) when C < 16#10000 -> 3;
cp_length(_) -> 4.

%%% Bytes to strings

-spec decode(encoding(), binary()) -> term().
decode(utf8, Bytes) -> decode_utf8(Bytes);
decode(buffer, Bytes) -> decode_utf8(Bytes);
decode(ucs2, Bytes) ->
    Even = byte_size(Bytes) - byte_size(Bytes) rem 2,
    <<Pairs:Even/binary, _/binary>> = Bytes,
    buoy_ref_string:from_units([U || <<U:16/little>> <= Pairs]);
decode(latin1, Bytes) -> Bytes;
decode(ascii, Bytes) -> << <<(C band 16#7F)>> || <<C>> <= Bytes >>;
decode(hex, Bytes) -> << <<(hex_digit(C bsr 4)), (hex_digit(C band 15))>> || <<C>> <= Bytes >>;
decode(base64, Bytes) -> base64:encode(Bytes);
decode(base64url, Bytes) -> base64:encode(Bytes, #{mode => urlsafe, padding => false}).

hex_digit(D) when D < 10 -> $0 + D;
hex_digit(D) -> $a + D - 10.

%% The WHATWG UTF-8 decoder: each maximal invalid subsequence becomes one
%% U+FFFD.
-spec decode_utf8(binary()) -> term().
decode_utf8(Bytes) ->
    case is_ascii(Bytes) of
        true -> Bytes;
        false -> buoy_ref_string:from_code_points(utf8(Bytes, []))
    end.

is_ascii(<<C, Rest/binary>>) when C < 128 -> is_ascii(Rest);
is_ascii(<<>>) -> true;
is_ascii(_) -> false.

utf8(<<>>, Acc) ->
    lists:reverse(Acc);
utf8(<<C, Rest/binary>>, Acc) when C < 16#80 ->
    utf8(Rest, [C | Acc]);
utf8(<<C, Rest/binary>>, Acc) when C >= 16#C2, C =< 16#DF ->
    continue(Rest, 1, C band 16#1F, 16#80, 16#BF, Acc);
utf8(<<16#E0, Rest/binary>>, Acc) ->
    continue(Rest, 2, 0, 16#A0, 16#BF, Acc);
utf8(<<16#ED, Rest/binary>>, Acc) ->
    continue(Rest, 2, 16#D, 16#80, 16#9F, Acc);
utf8(<<C, Rest/binary>>, Acc) when C >= 16#E1, C =< 16#EF ->
    continue(Rest, 2, C band 16#F, 16#80, 16#BF, Acc);
utf8(<<16#F0, Rest/binary>>, Acc) ->
    continue(Rest, 3, 0, 16#90, 16#BF, Acc);
utf8(<<16#F4, Rest/binary>>, Acc) ->
    continue(Rest, 3, 4, 16#80, 16#8F, Acc);
utf8(<<C, Rest/binary>>, Acc) when C >= 16#F1, C =< 16#F3 ->
    continue(Rest, 3, C band 7, 16#80, 16#BF, Acc);
utf8(<<_, Rest/binary>>, Acc) ->
    utf8(Rest, [16#FFFD | Acc]).

%% Needed more continuation bytes; the first lies in [Lower, Upper], the
%% others in [0x80, 0xBF].
continue(Rest, 0, Code, _, _, Acc) ->
    utf8(Rest, [Code | Acc]);
continue(<<C, Rest/binary>>, Needed, Code, Lower, Upper, Acc) when C >= Lower, C =< Upper ->
    continue(Rest, Needed - 1, (Code bsl 6) bor (C band 16#3F), 16#80, 16#BF, Acc);
continue(Rest, _, _, _, _, Acc) ->
    utf8(Rest, [16#FFFD | Acc]).

%%% Typed arrays

%% The bytes of an ArrayBuffer view, or of the range [Start, End) of it.
-spec view_bytes(term()) -> binary().
view_bytes(View) ->
    {Buffer, Offset, Length} = view(View),
    buoy_ref_buffer:read(Buffer, Offset, Length).

-spec view_bytes(term(), non_neg_integer(), non_neg_integer()) -> binary().
view_bytes(View, Start, End) ->
    {Buffer, Offset, _} = view(View),
    buoy_ref_buffer:read(Buffer, Offset + Start, max(0, End - Start)).

%% The bytes of the Uint8Array of a StreamBase writeBuffer, or the TypeError
%% that StreamBase::WriteBuffer throws for any other value.
-spec write_buffer_bytes(term()) -> binary().
write_buffer_bytes(View) ->
    IsUint8Array = buoy_heap:is_object(View) andalso buoy_heap:class_of(View) =:= typed_array
        andalso element(1, buoy_heap:slots(View)) =:= uint8,
    IsUint8Array orelse buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>, <<"Second argument must be a buffer">>),
    view_bytes(View).

%% Writes Bytes into the view at the byte index At.
-spec view_write(term(), non_neg_integer(), binary()) -> ok.
view_write(View, At, Bytes) ->
    {Buffer, Offset, _} = view(View),
    buoy_ref_buffer:write(Buffer, Offset + At, Bytes).

%% The length in bytes of an ArrayBuffer view.
-spec view_length(term()) -> non_neg_integer().
view_length(View) ->
    {_, _, Length} = view(View),
    Length.

view(View) ->
    case buoy_heap:class_of(View) of
        typed_array ->
            {Kind, Buffer, Offset, Length} = buoy_heap:slots(View),
            Count = case Length of
                auto -> (buoy_ref_buffer:byte_length(Buffer) - Offset) div buoy_ref_buffer:element_size(Kind);
                N -> N
            end,
            {Buffer, Offset, Count * buoy_ref_buffer:element_size(Kind)};
        data_view ->
            {Buffer, Offset, Length} = buoy_heap:slots(View),
            Count = case Length of
                auto -> buoy_ref_buffer:byte_length(Buffer) - Offset;
                N -> N
            end,
            {Buffer, Offset, Count};
        array_buffer ->
            {View, 0, buoy_ref_buffer:byte_length(View)};
        shared_array_buffer ->
            {View, 0, buoy_ref_buffer:byte_length(View)}
    end.

%% A new Buffer (a Uint8Array whose prototype is Buffer.prototype, as
%% setBufferPrototype set it) that holds Bytes.
-spec new_buffer(binary()) -> term().
new_buffer(Bytes) ->
    View = buoy_node:typed_array(<<"Uint8Array">>, byte_size(Bytes)),
    view_write(View, 0, Bytes),
    case erlang:get('$buoy_node_buffer_proto') of
        undefined -> ok;
        Proto -> buoy_heap:set_prototype_of(View, Proto)
    end,
    View.
