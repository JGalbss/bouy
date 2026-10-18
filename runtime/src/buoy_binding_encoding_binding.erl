%% internalBinding('encoding_binding') (src/encoding_binding.cc): the UTF-8
%% coding of TextEncoder and TextDecoder.
-module(buoy_binding_encoding_binding).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    Results = buoy_node:typed_array(<<"Uint32Array">>, 2),
    buoy_node:object([
        {<<"encodeInto">>, F(<<"encodeInto">>, 2, fun(_, Args) -> encode_into(A(1, Args), A(2, Args), Results) end)},
        {<<"encodeUtf8String">>, F(<<"encodeUtf8String">>, 1, fun(_, Args) ->
            Bytes = buoy_ref_string:to_utf8(buoy_ref:to_string(A(1, Args))),
            View = buoy_node:typed_array(<<"Uint8Array">>, byte_size(Bytes)),
            buoy_node_encoding:view_write(View, 0, Bytes),
            View
        end)},
        {<<"decodeUTF8">>, F(<<"decodeUTF8">>, 3, fun(_, Args) -> decode_utf8(A(1, Args), A(2, Args), A(3, Args)) end)},
        {<<"toASCII">>, F(<<"toASCII">>, 1, fun(_, Args) -> buoy_ref:to_string(A(1, Args)) end)},
        {<<"toUnicode">>, F(<<"toUnicode">>, 1, fun(_, Args) -> buoy_ref:to_string(A(1, Args)) end)},
        {<<"encodeIntoResults">>, Results}]).

%% encodeInto(source, dest): writes the whole characters that fit and
%% records [read code units, written bytes] in the results.
encode_into(Source, Dest, Results) ->
    Room = buoy_node_encoding:view_length(Dest),
    {Read, Bytes} = fit(buoy_ref_string:code_points(Source), Room, 0, []),
    buoy_node_encoding:view_write(Dest, 0, Bytes),
    buoy_heap:set(Results, 0, Read),
    buoy_heap:set(Results, 1, byte_size(Bytes)),
    undefined.

fit([C | Rest], Room, Read, Acc) ->
    Scalar = case C >= 16#D800 andalso C =< 16#DFFF of
        true -> 16#FFFD;
        false -> C
    end,
    Bytes = <<Scalar/utf8>>,
    case byte_size(Bytes) =< Room of
        true ->
            Units = case C > 16#FFFF of true -> 2; false -> 1 end,
            fit(Rest, Room - byte_size(Bytes), Read + Units, [Bytes | Acc]);
        false ->
            {Read, iolist_to_binary(lists:reverse(Acc))}
    end;
fit([], _Room, Read, Acc) ->
    {Read, iolist_to_binary(lists:reverse(Acc))}.

%% decodeUTF8(input, ignoreBOM, fatal)
decode_utf8(Input, IgnoreBom, Fatal) ->
    Bytes0 = buoy_node_encoding:view_bytes(Input),
    Bytes = case {buoy_ref:truthy(IgnoreBom), Bytes0} of
        {false, <<16#EF, 16#BB, 16#BF, Rest/binary>>} -> Rest;
        _ -> Bytes0
    end,
    case buoy_ref:truthy(Fatal) andalso not valid_utf8(Bytes) of
        true ->
            buoy_node:throw_code('TypeError', <<"ERR_ENCODING_INVALID_ENCODED_DATA">>,
                                 <<"The encoded data was not valid for encoding utf-8">>);
        false ->
            buoy_node_encoding:decode_utf8(Bytes)
    end.

valid_utf8(Bytes) ->
    case unicode:characters_to_list(Bytes, utf8) of
        L when is_list(L) -> not lists:any(fun(C) -> C >= 16#D800 andalso C =< 16#DFFF end, L);
        _ -> false
    end.
