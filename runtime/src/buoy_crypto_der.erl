%% DER, the encoding of the ASN.1 structures of keys and certificates, as
%% OpenSSL's d2i and i2d functions read and write them. A value is a term:
%%   {seq, [V]}, {set, [V]}, {int, Integer}, {bits, Bytes},
%%   {bits, UnusedBits, Bytes}, {octets, Bytes}, null, {oid, Tuple},
%%   {bool, Boolean}, {ctx, N, [V]} (a constructed [N]),
%%   {ctx_prim, N, Bytes} (a primitive [N]), and {tag, Tag, Bytes} for the
%%   strings, times, and any other tag, kept as the bytes of its content.
-module(buoy_crypto_der).

-export([decode/1, decode_all/1, encode/1, pem_decode/2, pem_encode/2, pem_blocks/1]).

-type value() :: term().
-export_type([value/0]).

%% The value that Der holds, which must fill it, or error.
-spec decode(binary()) -> {ok, value()} | error.
decode(Der) ->
    try value(Der) of
        {Value, <<>>} -> {ok, Value};
        _ -> error
    catch
        error:_ -> error
    end.

%% The value at the start of Der and the bytes after it, or error.
-spec decode_all(binary()) -> {ok, value(), binary()} | error.
decode_all(Der) ->
    try value(Der) of
        {Value, Rest} -> {ok, Value, Rest}
    catch
        error:_ -> error
    end.

value(<<Tag, Rest0/binary>>) ->
    {Length, Rest1} = der_length(Rest0),
    <<Content:Length/binary, Rest/binary>> = Rest1,
    {content(Tag, Content), Rest}.

der_length(<<0:1, Length:7, Rest/binary>>) -> {Length, Rest};
der_length(<<1:1, N:7, Rest/binary>>) when N >= 1, N =< 4 ->
    <<Length:(N * 8), Tail/binary>> = Rest,
    %% DER takes the shortest form.
    true = Length >= 128 andalso Length >= 1 bsl ((N - 1) * 8),
    {Length, Tail}.

content(16#30, C) -> {seq, values(C)};
content(16#31, C) -> {set, values(C)};
content(16#02, C) when byte_size(C) > 0 ->
    Bits = byte_size(C) * 8,
    <<I:Bits/signed>> = C,
    {int, I};
content(16#03, <<0, Bytes/binary>>) -> {bits, Bytes};
content(16#03, <<Unused, Bytes/binary>>) when Unused < 8 -> {bits, Unused, Bytes};
content(16#04, C) -> {octets, C};
content(16#05, <<>>) -> null;
content(16#06, C) -> {oid, oid_decode(C)};
content(16#01, <<0>>) -> {bool, false};
content(16#01, <<_>>) -> {bool, true};
content(Tag, C) when Tag band 16#E0 =:= 16#A0 -> {ctx, Tag band 16#1F, values(C)};
content(Tag, C) when Tag band 16#E0 =:= 16#80 -> {ctx_prim, Tag band 16#1F, C};
content(Tag, C) -> {tag, Tag, C}.

values(<<>>) -> [];
values(Bin) ->
    {V, Rest} = value(Bin),
    [V | values(Rest)].

oid_decode(<<First, Rest/binary>>) when First < 80 ->
    list_to_tuple([First div 40, First rem 40 | arcs(Rest, 0)]);
oid_decode(Bin) ->
    [Second | Arcs] = arcs(Bin, 0),
    list_to_tuple([2, Second - 80 | Arcs]).

arcs(<<>>, 0) -> [];
arcs(<<1:1, B:7, Rest/binary>>, Acc) -> arcs(Rest, (Acc bsl 7) bor B);
arcs(<<0:1, B:7, Rest/binary>>, Acc) -> [(Acc bsl 7) bor B | arcs(Rest, 0)].

%%% Encoding

-spec encode(value()) -> binary().
encode({seq, Vs}) -> tlv(16#30, [encode(V) || V <- Vs]);
encode({set, Vs}) -> tlv(16#31, lists:sort([encode(V) || V <- Vs]));
encode({int, I}) -> tlv(16#02, int_bytes(I));
encode({bits, Bytes}) -> tlv(16#03, [0, Bytes]);
encode({bits, Unused, Bytes}) -> tlv(16#03, [Unused, Bytes]);
encode({octets, Bytes}) -> tlv(16#04, Bytes);
encode(null) -> <<5, 0>>;
encode({oid, Oid}) -> tlv(16#06, oid_encode(tuple_to_list(Oid)));
encode({bool, true}) -> <<1, 1, 255>>;
encode({bool, false}) -> <<1, 1, 0>>;
encode({ctx, N, Vs}) -> tlv(16#A0 bor N, [encode(V) || V <- Vs]);
encode({ctx_prim, N, Bytes}) -> tlv(16#80 bor N, Bytes);
encode({tag, Tag, Bytes}) -> tlv(Tag, Bytes);
encode({raw, Der}) -> Der.

tlv(Tag, Content) ->
    Bin = iolist_to_binary(Content),
    <<Tag, (length_bytes(byte_size(Bin)))/binary, Bin/binary>>.

length_bytes(L) when L < 128 -> <<L>>;
length_bytes(L) ->
    B = binary:encode_unsigned(L),
    <<(16#80 bor byte_size(B)), B/binary>>.

%% The shortest two's complement bytes of I.
int_bytes(0) -> <<0>>;
int_bytes(I) when I > 0 ->
    case binary:encode_unsigned(I) of
        <<1:1, _/bitstring>> = B -> <<0, B/binary>>;
        B -> B
    end;
int_bytes(I) ->
    Bytes = (bit_size(binary:encode_unsigned(-I - 1)) + 8) div 8,
    <<I:(Bytes * 8)/signed>>.

oid_encode([A, B | Rest]) -> << <<(base128(X))/binary>> || X <- [A * 40 + B | Rest] >>.

base128(X) when X < 128 -> <<X>>;
base128(X) -> <<(high(X bsr 7))/binary, (X band 127)>>.

high(X) when X < 128 -> <<(16#80 bor X)>>;
high(X) -> <<(high(X bsr 7))/binary, (16#80 bor (X band 127))>>.

%%% PEM

%% The bytes of the first PEM block labelled Label in Text, and its headers,
%% as PEM_bytes_read_bio finds it after any other text.
-spec pem_decode(binary(), binary()) -> {ok, binary(), [{binary(), binary()}]} | error.
pem_decode(Text, Label) ->
    case [{Der, Headers} || {L, Der, Headers} <- pem_blocks(Text), L =:= Label] of
        [{Der, Headers} | _] -> {ok, Der, Headers};
        [] -> error
    end.

%% Each block of Text that decodes: its label, its bytes, and its headers.
-spec pem_blocks(binary()) -> [{binary(), binary(), [{binary(), binary()}]}].
pem_blocks(Text) ->
    case binary:match(Text, <<"-----BEGIN ">>) of
        nomatch -> [];
        {At, Len} ->
            Rest = binary:part(Text, At + Len, byte_size(Text) - At - Len),
            case binary:split(Rest, <<"-----">>) of
                [Label, Body0] -> block(Label, Body0);
                _ -> []
            end
    end.

block(Label, Body0) ->
    End = <<"-----END ", Label/binary, "-----">>,
    case binary:split(Body0, End) of
        [Body, Rest] ->
            Next = pem_blocks(Rest),
            try body(Body) of
                {Headers, Der} -> [{Label, Der, Headers} | Next]
            catch
                error:_ -> Next
            end;
        _ -> []
    end.

body(Body) ->
    Lines = [string:trim(L) || L <- binary:split(Body, [<<"\n">>, <<"\r">>], [global])],
    {HeaderLines, Base64} = lists:splitwith(fun(L) -> binary:match(L, <<":">>) =/= nomatch end,
                                            [L || L <- Lines, L =/= <<>>]),
    Headers = [list_to_tuple([string:trim(P) || P <- binary:split(H, <<":">>)]) || H <- HeaderLines],
    {Headers, base64:decode(iolist_to_binary(Base64))}.

%% Der as a PEM block labelled Label, with 64 characters a line.
-spec pem_encode(binary(), binary()) -> binary().
pem_encode(Label, Der) ->
    iolist_to_binary([<<"-----BEGIN ">>, Label, <<"-----\n">>, lines(base64:encode(Der)),
                      <<"-----END ">>, Label, <<"-----\n">>]).

lines(<<Line:64/binary, Rest/binary>>) -> [Line, $\n | lines(Rest)];
lines(<<>>) -> [];
lines(Line) -> [Line, $\n].
