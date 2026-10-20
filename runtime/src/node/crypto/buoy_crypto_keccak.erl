%% The Keccak functions that OTP's crypto does not expose: TurboSHAKE and
%% KangarooTwelve (RFC 9861, as src/crypto/crypto_turboshake.cc ports them),
%% and cSHAKE and KMAC (NIST SP 800-185), on the Keccak sponge of
%% crates/buoy-native.
-module(buoy_crypto_keccak).

-export([members/0]).

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

%% A Keccak sponge of Rounds rounds. It runs in the NIF, because a
%% permutation on Erlang integers is too slow for inputs of megabytes.
sponge(Rate, Rounds, Input, D, Length) -> buoy_native:keccak(Rounds, Rate, D, Input, Length).
