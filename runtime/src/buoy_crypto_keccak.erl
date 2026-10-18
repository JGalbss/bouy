%% The Keccak functions that OTP's crypto does not expose: TurboSHAKE and
%% KangarooTwelve (RFC 9861, as src/crypto/crypto_turboshake.cc ports them),
%% and cSHAKE and KMAC (NIST SP 800-185), on Keccak-p[1600] with 64-bit
%% lanes in Erlang integers.
-module(buoy_crypto_keccak).

-export([members/0, turboshake/4, kangaroo_twelve/4, kmac/5]).

-define(MASK, 16#FFFFFFFFFFFFFFFF).
-define(SIGN, 0).

-spec members() -> [{binary(), term()}].
members() ->
    Job = fun buoy_crypto_job:class/2,
    [{<<"TurboShakeJob">>, Job(<<"TurboShakeJob">>, fun turboshake_job/1)},
     {<<"KangarooTwelveJob">>, Job(<<"KangarooTwelveJob">>, fun k12_job/1)},
     {<<"KmacJob">>, Job(<<"KmacJob">>, fun kmac_job/1)}].

%% new TurboShakeJob(mode, algorithm, domainSeparation, outputLength, data)
turboshake_job([Algorithm, Domain, Length, Data | _]) ->
    Rate = case buoy_crypto:string(Algorithm) of
        <<"TurboSHAKE128">> -> 168;
        <<"TurboSHAKE256">> -> 136
    end,
    Bytes = buoy_crypto:bytes(Data),
    {fun() -> {ok, turboshake(Rate, Bytes, Domain, Length)} end, fun buoy_crypto:array_buffer/1}.

%% new KangarooTwelveJob(mode, algorithm, customization, outputLength, data)
k12_job([Algorithm, Custom, Length, Data | _]) ->
    Variant = case buoy_crypto:string(Algorithm) of
        <<"KT128">> -> kt128;
        <<"KT256">> -> kt256
    end,
    C = optional_bytes(Custom),
    Bytes = buoy_crypto:bytes(Data),
    {fun() -> {ok, kangaroo_twelve(Variant, Bytes, C, Length)} end, fun buoy_crypto:array_buffer/1}.

%% new KmacJob(mode, signMode, key, algorithm, customization, length, data, signature)
kmac_job([Mode, KeyHandle, Algorithm, Custom, Length, Data | Rest]) ->
    Key = buoy_crypto_keys:secret_bytes(KeyHandle),
    Rate = case buoy_crypto:string(Algorithm) of
        <<"KMAC128">> -> 168;
        <<"KMAC256">> -> 136
    end,
    C = optional_bytes(Custom),
    Bytes = buoy_crypto:bytes(Data),
    Work = fun() ->
        byte_size(Key) > 0 orelse buoy_crypto:fail({message, <<"KMAC failed">>}),
        {ok, kmac(Rate, Key, Bytes, Length, C)}
    end,
    case Mode of
        ?SIGN -> {Work, fun buoy_crypto:array_buffer/1};
        _ ->
            Signature = buoy_crypto:bytes(hd(Rest)),
            {Work, fun(Mac) -> byte_size(Mac) > 0 andalso buoy_crypto:equal_bytes(Mac, Signature) end}
    end.

optional_bytes(undefined) -> <<>>;
optional_bytes(V) -> buoy_crypto:bytes(V).

%%% TurboSHAKE and KangarooTwelve

%% TurboSHAKE with the rate Rate (168 or 136 bytes) and the domain byte D.
-spec turboshake(pos_integer(), binary(), byte(), non_neg_integer()) -> binary().
turboshake(Rate, Input, D, Length) -> sponge(Rate, 12, Input, D, Length).

%% KT128 or KT256 of Message with the customization Custom.
-spec kangaroo_twelve(kt128 | kt256, binary(), binary(), non_neg_integer()) -> binary().
kangaroo_twelve(Variant, Message, Custom, Length) ->
    {Rate, CvLen} = case Variant of
        kt128 -> {168, 32};
        kt256 -> {136, 64}
    end,
    S = <<Message/binary, Custom/binary, (length_encode(byte_size(Custom)))/binary>>,
    case byte_size(S) =< 8192 of
        true -> turboshake(Rate, S, 16#07, Length);
        false ->
            <<First:8192/binary, Rest/binary>> = S,
            Cvs = [turboshake(Rate, Chunk, 16#0B, CvLen) || Chunk <- chunks(Rest)],
            Final = iolist_to_binary([First, 16#03, <<0:56>>, Cvs, length_encode(length(Cvs)), 16#FF, 16#FF]),
            turboshake(Rate, Final, 16#06, Length)
    end.

chunks(<<Chunk:8192/binary, Rest/binary>>) when Rest =/= <<>> -> [Chunk | chunks(Rest)];
chunks(Last) -> [Last].

%% length_encode of RFC 9861: the bytes of X, then their count.
length_encode(0) -> <<0>>;
length_encode(X) ->
    B = binary:encode_unsigned(X),
    <<B/binary, (byte_size(B))>>.

%%% cSHAKE and KMAC

%% KMAC128 (Rate 168) or KMAC256 (Rate 136) of Data under Key, Length
%% bytes long, with the customization Custom.
-spec kmac(pos_integer(), binary(), binary(), non_neg_integer(), binary()) -> binary().
kmac(_, _, _, 0, _) -> <<>>;
kmac(Rate, Key, Data, Length, Custom) ->
    X = <<(bytepad(encode_string(Key), Rate))/binary, Data/binary, (right_encode(Length * 8))/binary>>,
    cshake(Rate, X, Length, <<"KMAC">>, Custom).

cshake(Rate, X, Length, Name, Custom) ->
    Prefix = bytepad(<<(encode_string(Name))/binary, (encode_string(Custom))/binary>>, Rate),
    sponge(Rate, 24, <<Prefix/binary, X/binary>>, 16#04, Length).

left_encode(X) ->
    B = case binary:encode_unsigned(X) of
        <<>> -> <<0>>;
        Bytes -> Bytes
    end,
    <<(byte_size(B)), B/binary>>.

right_encode(X) ->
    B = binary:encode_unsigned(X),
    <<B/binary, (byte_size(B))>>.

encode_string(S) -> <<(left_encode(byte_size(S) * 8))/binary, S/binary>>.

bytepad(X, W) ->
    Z = <<(left_encode(W))/binary, X/binary>>,
    Pad = (W - byte_size(Z) rem W) rem W,
    <<Z/binary, 0:(Pad * 8)>>.

%%% The sponge

%% A Keccak sponge of Rounds rounds: Input absorbed with the domain byte D
%% and pad10*1, and Length bytes squeezed. A lane is two 32-bit halves, low
%% then high, so that every value stays a small integer.
sponge(Rate, Rounds, Input, D, Length) ->
    State = absorb_all(erlang:make_tuple(50, 0), Rate, Rounds, Input, D),
    squeeze(State, Rate, Rounds, Length, []).

absorb_all(State, Rate, Rounds, Input, D) when byte_size(Input) >= Rate ->
    <<Block:Rate/binary, Rest/binary>> = Input,
    absorb_all(permute(absorb(State, Block, 1), Rounds), Rate, Rounds, Rest, D);
absorb_all(State, Rate, Rounds, Last, D) ->
    Pad = <<Last/binary, D, 0:((Rate - byte_size(Last) - 1) * 8)>>,
    <<Head:(Rate - 1)/binary, LastByte>> = Pad,
    permute(absorb(State, <<Head/binary, (LastByte bxor 16#80)>>, 1), Rounds).

absorb(State, <<Lo:32/little, Hi:32/little, Rest/binary>>, I) ->
    S1 = setelement(I, State, element(I, State) bxor Lo),
    absorb(setelement(I + 1, S1, element(I + 1, S1) bxor Hi), Rest, I + 2);
absorb(State, <<>>, _) -> State.

squeeze(State, Rate, Rounds, Length, Acc) ->
    Out = << <<(element(2 * I + 1, State)):32/little, (element(2 * I + 2, State)):32/little>>
             || I <- lists:seq(0, Rate div 8 - 1) >>,
    case Length =< Rate of
        true -> iolist_to_binary(lists:reverse([binary:part(Out, 0, Length) | Acc]));
        false -> squeeze(permute(State, Rounds), Rate, Rounds, Length - Rate, [Out | Acc])
    end.

-define(M, 16#FFFFFFFF).

%% The round constants of Keccak-f[1600], as {Low, High}.
iotas() ->
    {{16#00000001, 16#00000000}, {16#00008082, 16#00000000}, {16#0000808a, 16#80000000},
     {16#80008000, 16#80000000}, {16#0000808b, 16#00000000}, {16#80000001, 16#00000000},
     {16#80008081, 16#80000000}, {16#00008009, 16#80000000}, {16#0000008a, 16#00000000},
     {16#00000088, 16#00000000}, {16#80008009, 16#00000000}, {16#8000000a, 16#00000000},
     {16#8000808b, 16#00000000}, {16#0000008b, 16#80000000}, {16#00008089, 16#80000000},
     {16#00008003, 16#80000000}, {16#00008002, 16#80000000}, {16#00000080, 16#80000000},
     {16#0000800a, 16#00000000}, {16#8000000a, 16#80000000}, {16#80008081, 16#80000000},
     {16#00008080, 16#80000000}, {16#80000001, 16#00000000}, {16#80008008, 16#80000000}}.

%% Keccak-p[1600, Rounds]: the last Rounds rounds of Keccak-f[1600].
permute(State, Rounds) -> permute(State, 24 - Rounds, iotas()).

permute(State, 24, _) -> State;
permute(State, R, Iotas) ->
    {IL, IH} = element(R + 1, Iotas),
    permute(round(State, IL, IH), R + 1, Iotas).

%% One round: theta, rho, pi, chi, and iota, unrolled over the 25 lanes
%% (lane 5y + x is A[y][x]; rho and pi follow keccak1600.c).
round({L0, H0, L1, H1, L2, H2, L3, H3, L4, H4, L5, H5, L6, H6, L7, H7, L8, H8, L9, H9, L10, H10, L11, H11, L12, H12, L13, H13, L14, H14, L15, H15, L16, H16, L17, H17, L18, H18, L19, H19, L20, H20, L21, H21, L22, H22, L23, H23, L24, H24}, IL, IH) ->
    CL0 = L0 bxor L5 bxor L10 bxor L15 bxor L20,
    CH0 = H0 bxor H5 bxor H10 bxor H15 bxor H20,
    CL1 = L1 bxor L6 bxor L11 bxor L16 bxor L21,
    CH1 = H1 bxor H6 bxor H11 bxor H16 bxor H21,
    CL2 = L2 bxor L7 bxor L12 bxor L17 bxor L22,
    CH2 = H2 bxor H7 bxor H12 bxor H17 bxor H22,
    CL3 = L3 bxor L8 bxor L13 bxor L18 bxor L23,
    CH3 = H3 bxor H8 bxor H13 bxor H18 bxor H23,
    CL4 = L4 bxor L9 bxor L14 bxor L19 bxor L24,
    CH4 = H4 bxor H9 bxor H14 bxor H19 bxor H24,
    DL0 = CL4 bxor (((CL1 bsl 1) band ?M) bor (CH1 bsr 31)),
    DH0 = CH4 bxor (((CH1 bsl 1) band ?M) bor (CL1 bsr 31)),
    DL1 = CL0 bxor (((CL2 bsl 1) band ?M) bor (CH2 bsr 31)),
    DH1 = CH0 bxor (((CH2 bsl 1) band ?M) bor (CL2 bsr 31)),
    DL2 = CL1 bxor (((CL3 bsl 1) band ?M) bor (CH3 bsr 31)),
    DH2 = CH1 bxor (((CH3 bsl 1) band ?M) bor (CL3 bsr 31)),
    DL3 = CL2 bxor (((CL4 bsl 1) band ?M) bor (CH4 bsr 31)),
    DH3 = CH2 bxor (((CH4 bsl 1) band ?M) bor (CL4 bsr 31)),
    DL4 = CL3 bxor (((CL0 bsl 1) band ?M) bor (CH0 bsr 31)),
    DH4 = CH3 bxor (((CH0 bsl 1) band ?M) bor (CL0 bsr 31)),
    XL0 = L0 bxor DL0, XH0 = H0 bxor DH0,
    TL0 = XL0, TH0 = XH0,
    XL1 = L1 bxor DL1, XH1 = H1 bxor DH1,
    TL1 = ((XL1 bsl 1) band ?M) bor (XH1 bsr 31),
    TH1 = ((XH1 bsl 1) band ?M) bor (XL1 bsr 31),
    XL2 = L2 bxor DL2, XH2 = H2 bxor DH2,
    TL2 = ((XH2 bsl 30) band ?M) bor (XL2 bsr 2),
    TH2 = ((XL2 bsl 30) band ?M) bor (XH2 bsr 2),
    XL3 = L3 bxor DL3, XH3 = H3 bxor DH3,
    TL3 = ((XL3 bsl 28) band ?M) bor (XH3 bsr 4),
    TH3 = ((XH3 bsl 28) band ?M) bor (XL3 bsr 4),
    XL4 = L4 bxor DL4, XH4 = H4 bxor DH4,
    TL4 = ((XL4 bsl 27) band ?M) bor (XH4 bsr 5),
    TH4 = ((XH4 bsl 27) band ?M) bor (XL4 bsr 5),
    XL5 = L5 bxor DL0, XH5 = H5 bxor DH0,
    TL5 = ((XH5 bsl 4) band ?M) bor (XL5 bsr 28),
    TH5 = ((XL5 bsl 4) band ?M) bor (XH5 bsr 28),
    XL6 = L6 bxor DL1, XH6 = H6 bxor DH1,
    TL6 = ((XH6 bsl 12) band ?M) bor (XL6 bsr 20),
    TH6 = ((XL6 bsl 12) band ?M) bor (XH6 bsr 20),
    XL7 = L7 bxor DL2, XH7 = H7 bxor DH2,
    TL7 = ((XL7 bsl 6) band ?M) bor (XH7 bsr 26),
    TH7 = ((XH7 bsl 6) band ?M) bor (XL7 bsr 26),
    XL8 = L8 bxor DL3, XH8 = H8 bxor DH3,
    TL8 = ((XH8 bsl 23) band ?M) bor (XL8 bsr 9),
    TH8 = ((XL8 bsl 23) band ?M) bor (XH8 bsr 9),
    XL9 = L9 bxor DL4, XH9 = H9 bxor DH4,
    TL9 = ((XL9 bsl 20) band ?M) bor (XH9 bsr 12),
    TH9 = ((XH9 bsl 20) band ?M) bor (XL9 bsr 12),
    XL10 = L10 bxor DL0, XH10 = H10 bxor DH0,
    TL10 = ((XL10 bsl 3) band ?M) bor (XH10 bsr 29),
    TH10 = ((XH10 bsl 3) band ?M) bor (XL10 bsr 29),
    XL11 = L11 bxor DL1, XH11 = H11 bxor DH1,
    TL11 = ((XL11 bsl 10) band ?M) bor (XH11 bsr 22),
    TH11 = ((XH11 bsl 10) band ?M) bor (XL11 bsr 22),
    XL12 = L12 bxor DL2, XH12 = H12 bxor DH2,
    TL12 = ((XH12 bsl 11) band ?M) bor (XL12 bsr 21),
    TH12 = ((XL12 bsl 11) band ?M) bor (XH12 bsr 21),
    XL13 = L13 bxor DL3, XH13 = H13 bxor DH3,
    TL13 = ((XL13 bsl 25) band ?M) bor (XH13 bsr 7),
    TH13 = ((XH13 bsl 25) band ?M) bor (XL13 bsr 7),
    XL14 = L14 bxor DL4, XH14 = H14 bxor DH4,
    TL14 = ((XH14 bsl 7) band ?M) bor (XL14 bsr 25),
    TH14 = ((XL14 bsl 7) band ?M) bor (XH14 bsr 25),
    XL15 = L15 bxor DL0, XH15 = H15 bxor DH0,
    TL15 = ((XH15 bsl 9) band ?M) bor (XL15 bsr 23),
    TH15 = ((XL15 bsl 9) band ?M) bor (XH15 bsr 23),
    XL16 = L16 bxor DL1, XH16 = H16 bxor DH1,
    TL16 = ((XH16 bsl 13) band ?M) bor (XL16 bsr 19),
    TH16 = ((XL16 bsl 13) band ?M) bor (XH16 bsr 19),
    XL17 = L17 bxor DL2, XH17 = H17 bxor DH2,
    TL17 = ((XL17 bsl 15) band ?M) bor (XH17 bsr 17),
    TH17 = ((XH17 bsl 15) band ?M) bor (XL17 bsr 17),
    XL18 = L18 bxor DL3, XH18 = H18 bxor DH3,
    TL18 = ((XL18 bsl 21) band ?M) bor (XH18 bsr 11),
    TH18 = ((XH18 bsl 21) band ?M) bor (XL18 bsr 11),
    XL19 = L19 bxor DL4, XH19 = H19 bxor DH4,
    TL19 = ((XL19 bsl 8) band ?M) bor (XH19 bsr 24),
    TH19 = ((XH19 bsl 8) band ?M) bor (XL19 bsr 24),
    XL20 = L20 bxor DL0, XH20 = H20 bxor DH0,
    TL20 = ((XL20 bsl 18) band ?M) bor (XH20 bsr 14),
    TH20 = ((XH20 bsl 18) band ?M) bor (XL20 bsr 14),
    XL21 = L21 bxor DL1, XH21 = H21 bxor DH1,
    TL21 = ((XL21 bsl 2) band ?M) bor (XH21 bsr 30),
    TH21 = ((XH21 bsl 2) band ?M) bor (XL21 bsr 30),
    XL22 = L22 bxor DL2, XH22 = H22 bxor DH2,
    TL22 = ((XH22 bsl 29) band ?M) bor (XL22 bsr 3),
    TH22 = ((XL22 bsl 29) band ?M) bor (XH22 bsr 3),
    XL23 = L23 bxor DL3, XH23 = H23 bxor DH3,
    TL23 = ((XH23 bsl 24) band ?M) bor (XL23 bsr 8),
    TH23 = ((XL23 bsl 24) band ?M) bor (XH23 bsr 8),
    XL24 = L24 bxor DL4, XH24 = H24 bxor DH4,
    TL24 = ((XL24 bsl 14) band ?M) bor (XH24 bsr 18),
    TH24 = ((XH24 bsl 14) band ?M) bor (XL24 bsr 18),
    PL0 = TL0, PH0 = TH0,
    PL1 = TL6, PH1 = TH6,
    PL2 = TL12, PH2 = TH12,
    PL3 = TL18, PH3 = TH18,
    PL4 = TL24, PH4 = TH24,
    PL5 = TL3, PH5 = TH3,
    PL6 = TL9, PH6 = TH9,
    PL7 = TL10, PH7 = TH10,
    PL8 = TL16, PH8 = TH16,
    PL9 = TL22, PH9 = TH22,
    PL10 = TL1, PH10 = TH1,
    PL11 = TL7, PH11 = TH7,
    PL12 = TL13, PH12 = TH13,
    PL13 = TL19, PH13 = TH19,
    PL14 = TL20, PH14 = TH20,
    PL15 = TL4, PH15 = TH4,
    PL16 = TL5, PH16 = TH5,
    PL17 = TL11, PH17 = TH11,
    PL18 = TL17, PH18 = TH17,
    PL19 = TL23, PH19 = TH23,
    PL20 = TL2, PH20 = TH2,
    PL21 = TL8, PH21 = TH8,
    PL22 = TL14, PH22 = TH14,
    PL23 = TL15, PH23 = TH15,
    PL24 = TL21, PH24 = TH21,
    {(PL0 bxor ((PL1 bxor ?M) band PL2)) bxor IL,
     (PH0 bxor ((PH1 bxor ?M) band PH2)) bxor IH,
     PL1 bxor ((PL2 bxor ?M) band PL3),
     PH1 bxor ((PH2 bxor ?M) band PH3),
     PL2 bxor ((PL3 bxor ?M) band PL4),
     PH2 bxor ((PH3 bxor ?M) band PH4),
     PL3 bxor ((PL4 bxor ?M) band PL0),
     PH3 bxor ((PH4 bxor ?M) band PH0),
     PL4 bxor ((PL0 bxor ?M) band PL1),
     PH4 bxor ((PH0 bxor ?M) band PH1),
     PL5 bxor ((PL6 bxor ?M) band PL7),
     PH5 bxor ((PH6 bxor ?M) band PH7),
     PL6 bxor ((PL7 bxor ?M) band PL8),
     PH6 bxor ((PH7 bxor ?M) band PH8),
     PL7 bxor ((PL8 bxor ?M) band PL9),
     PH7 bxor ((PH8 bxor ?M) band PH9),
     PL8 bxor ((PL9 bxor ?M) band PL5),
     PH8 bxor ((PH9 bxor ?M) band PH5),
     PL9 bxor ((PL5 bxor ?M) band PL6),
     PH9 bxor ((PH5 bxor ?M) band PH6),
     PL10 bxor ((PL11 bxor ?M) band PL12),
     PH10 bxor ((PH11 bxor ?M) band PH12),
     PL11 bxor ((PL12 bxor ?M) band PL13),
     PH11 bxor ((PH12 bxor ?M) band PH13),
     PL12 bxor ((PL13 bxor ?M) band PL14),
     PH12 bxor ((PH13 bxor ?M) band PH14),
     PL13 bxor ((PL14 bxor ?M) band PL10),
     PH13 bxor ((PH14 bxor ?M) band PH10),
     PL14 bxor ((PL10 bxor ?M) band PL11),
     PH14 bxor ((PH10 bxor ?M) band PH11),
     PL15 bxor ((PL16 bxor ?M) band PL17),
     PH15 bxor ((PH16 bxor ?M) band PH17),
     PL16 bxor ((PL17 bxor ?M) band PL18),
     PH16 bxor ((PH17 bxor ?M) band PH18),
     PL17 bxor ((PL18 bxor ?M) band PL19),
     PH17 bxor ((PH18 bxor ?M) band PH19),
     PL18 bxor ((PL19 bxor ?M) band PL15),
     PH18 bxor ((PH19 bxor ?M) band PH15),
     PL19 bxor ((PL15 bxor ?M) band PL16),
     PH19 bxor ((PH15 bxor ?M) band PH16),
     PL20 bxor ((PL21 bxor ?M) band PL22),
     PH20 bxor ((PH21 bxor ?M) band PH22),
     PL21 bxor ((PL22 bxor ?M) band PL23),
     PH21 bxor ((PH22 bxor ?M) band PH23),
     PL22 bxor ((PL23 bxor ?M) band PL24),
     PH22 bxor ((PH23 bxor ?M) band PH24),
     PL23 bxor ((PL24 bxor ?M) band PL20),
     PH23 bxor ((PH24 bxor ?M) band PH20),
     PL24 bxor ((PL20 bxor ?M) band PL21),
     PH24 bxor ((PH20 bxor ?M) band PH21)}.
