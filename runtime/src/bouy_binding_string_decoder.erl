%% internalBinding('string_decoder') (src/string_decoder.cc): decode and
%% flush of lib/string_decoder, with the state in the bytes of the decoder's
%% buffer, as the C++ StringDecoder keeps it: the incomplete character in
%% bytes 0 to 3, the missing count in byte 4, the buffered count in byte 5,
%% and the encoding in byte 6.
-module(bouy_binding_string_decoder).

-export([binding/0]).

-define(K_MISSING, 4).
-define(K_BUFFERED, 5).
-define(K_ENCODING, 6).
-define(K_SIZE, 7).

-spec binding() -> term().
binding() ->
    F = fun bouy_node:fn/3,
    A = fun bouy_node:arg/2,
    Encodings = bouy_heap:new_array([<<"ascii">>, <<"utf8">>, <<"base64">>, <<"utf16le">>, <<"latin1">>,
                                     <<"hex">>, <<"buffer">>, <<"base64url">>]),
    bouy_node:object([
        {<<"kIncompleteCharactersStart">>, 0}, {<<"kIncompleteCharactersEnd">>, 4},
        {<<"kMissingBytes">>, ?K_MISSING}, {<<"kBufferedBytes">>, ?K_BUFFERED},
        {<<"kEncodingField">>, ?K_ENCODING}, {<<"kNumFields">>, 7},
        {<<"encodings">>, Encodings},
        {<<"kSize">>, ?K_SIZE},
        {<<"decode">>, F(<<"decode">>, 2, fun(_, Args) -> decode(A(1, Args), A(2, Args)) end)},
        {<<"flush">>, F(<<"flush">>, 1, fun(_, Args) -> flush(A(1, Args)) end)}]).

state(State) ->
    <<Chars:4/binary, Missing, Buffered, Enum>> = bouy_node_encoding:view_bytes(State, 0, ?K_SIZE),
    {Chars, Missing, Buffered, bouy_node_encoding:from_enum(Enum)}.

save(State, Chars, Missing, Buffered) ->
    Padded = binary:part(<<Chars/binary, 0:32>>, 0, 4),
    bouy_node_encoding:view_write(State, 0, <<Padded/binary, Missing, Buffered>>).

decode(State, Chunk) ->
    Data = bouy_node_encoding:view_bytes(Chunk),
    {Chars, Missing, Buffered, Encoding} = state(State),
    case lists:member(Encoding, [utf8, ucs2, base64, base64url]) of
        false ->
            bouy_node_encoding:decode(Encoding, Data);
        true ->
            {Prepend, Rest, Missing1, Buffered1, Chars1} = complete(Encoding, Data, Chars, Missing, Buffered),
            case Rest of
                <<>> ->
                    save(State, Chars1, Missing1, Buffered1),
                    concat(Prepend, <<>>);
                _ ->
                    {Keep, Missing2} = tail(Encoding, Rest),
                    BodyBytes = binary:part(Rest, 0, byte_size(Rest) - Keep),
                    Tail = binary:part(Rest, byte_size(Rest) - Keep, Keep),
                    save(State, Tail, Missing2, Keep),
                    concat(Prepend, bouy_node_encoding:decode(Encoding, BodyBytes))
            end
    end.

%% The bytes that complete the buffered character, and the string of that
%% character once it is whole.
complete(_Encoding, Data, Chars, 0, Buffered) ->
    {none, Data, 0, Buffered, Chars};
complete(Encoding, Data, Chars, Missing, Buffered) ->
    {Data1, Missing1, Buffered1, Chars1} = case Encoding of
        utf8 ->
            case first_non_continuation(Data, 0, Missing) of
                {found, I} ->
                    <<Taken:I/binary, After/binary>> = Data,
                    {After, 0, Buffered + I, <<(binary:part(Chars, 0, Buffered))/binary, Taken/binary>>};
                none ->
                    {Data, Missing, Buffered, Chars}
            end;
        _ ->
            {Data, Missing, Buffered, Chars}
    end,
    Found = min(byte_size(Data1), Missing1),
    <<Piece:Found/binary, Rest/binary>> = Data1,
    Whole = <<(binary:part(Chars1, 0, Buffered1))/binary, Piece/binary>>,
    Missing2 = Missing1 - Found,
    case Missing2 of
        0 -> {bouy_node_encoding:decode(Encoding, Whole), Rest, 0, 0, Whole};
        _ -> {none, Rest, Missing2, byte_size(Whole), Whole}
    end.

first_non_continuation(Data, I, Missing) when I < byte_size(Data), I < Missing ->
    case binary:at(Data, I) band 16#C0 of
        16#80 -> first_non_continuation(Data, I + 1, Missing);
        _ -> {found, I}
    end;
first_non_continuation(_, _, _) ->
    none.

%% The bytes at the end of Data that begin an incomplete character, and how
%% many bytes it misses.
tail(utf8, Data) ->
    case binary:last(Data) band 16#80 of
        0 -> {0, 0};
        _ -> utf8_tail(Data, byte_size(Data) - 1, 0)
    end;
tail(ucs2, Data) when byte_size(Data) rem 2 =:= 1 ->
    {1, 1};
tail(ucs2, Data) ->
    case binary:last(Data) band 16#FC of
        16#D8 -> {2, 2};
        _ -> {0, 0}
    end;
tail(_Base64, Data) ->
    case byte_size(Data) rem 3 of
        0 -> {0, 0};
        N -> {N, 3 - N}
    end.

utf8_tail(Data, I, Count0) ->
    Count = Count0 + 1,
    C = binary:at(Data, I),
    case C band 16#C0 of
        16#80 when Count >= 4; I =:= 0 ->
            {0, 0};
        16#80 ->
            utf8_tail(Data, I - 1, Count);
        _ ->
            Needed = if
                C band 16#E0 =:= 16#C0 -> 2;
                C band 16#F0 =:= 16#E0 -> 3;
                C band 16#F8 =:= 16#F0 -> 4;
                true -> 0
            end,
            case Needed of
                0 -> {0, 0};
                _ when Count >= Needed -> {0, 0};
                _ -> {Count, Needed - Count}
            end
    end.

flush(State) ->
    {Chars, Missing, Buffered, Encoding} = state(State),
    {Missing1, Buffered1} = case Encoding =:= ucs2 andalso Buffered rem 2 =:= 1 of
        true -> {Missing - 1, Buffered - 1};
        false -> {Missing, Buffered}
    end,
    case Buffered1 of
        0 ->
            save(State, Chars, Missing1, 0),
            <<>>;
        _ ->
            save(State, Chars, 0, 0),
            bouy_node_encoding:decode(Encoding, binary:part(Chars, 0, Buffered1))
    end.

concat(none, Body) -> Body;
concat(Prepend, <<>>) -> Prepend;
concat(Prepend, Body) -> bouy_ref_string:concat(Prepend, Body).
