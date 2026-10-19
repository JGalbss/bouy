%% The cipher modes that OpenSSL has and OTP's crypto does not expose, on
%% the block ciphers that it does: the GCM key stream for streaming
%% encryption, OCB (RFC 7253), AES key wrap (RFC 3394 and RFC 5649), the
%% Triple-DES key wrap of CMS (RFC 3217), and ECB of Triple-DES.
-module(buoy_crypto_modes).

-export([ecb/4, gcm_j0/3, gcm_stream/4, ocb/6, aes_wrap/4, aes_unwrap/4, aes_wrap_pad/4, aes_unwrap_pad/4,
         des3_wrap/2, des3_unwrap/2]).

%% ECB of the block cipher Cipher (an OTP ECB cipher, or des_ede3) over
%% whole blocks.
-spec ecb(atom(), binary(), binary(), boolean()) -> binary().
ecb(des_ede3, Key, Data, Encrypt) ->
    << <<(crypto:crypto_one_time(des_ede3_cbc, Key, <<0:64>>, B, Encrypt))/binary>> || <<B:8/binary>> <= Data >>;
ecb(Cipher, Key, Data, Encrypt) ->
    crypto:crypto_one_time(Cipher, Key, Data, Encrypt).

%%% GCM

%% The pre-counter block J0 of GCM for IV (NIST SP 800-38D, 7.1).
-spec gcm_j0(atom(), binary(), binary()) -> non_neg_integer().
gcm_j0(_, _, <<IV:12/binary>>) ->
    binary:decode_unsigned(<<IV/binary, 1:32>>);
gcm_j0(Ecb, Key, IV) ->
    H = binary:decode_unsigned(ecb(Ecb, Key, <<0:128>>, true)),
    Pad = (16 - byte_size(IV) rem 16) rem 16,
    Blocks = <<IV/binary, 0:(Pad * 8), 0:64, (byte_size(IV) * 8):64>>,
    lists:foldl(fun(B, Y) -> gf_mult(Y bxor B, H) end, 0, [B || <<B:128>> <= Blocks]).

%% The product of X and Y in GF(2^128) as GCM defines it.
gf_mult(X, Y) -> gf_mult(X, Y, 0, 127).

gf_mult(_, _, Z, -1) -> Z;
gf_mult(X, V, Z, I) ->
    Z1 = case (X bsr I) band 1 of
        1 -> Z bxor V;
        0 -> Z
    end,
    V1 = case V band 1 of
        1 -> (V bsr 1) bxor (16#E1 bsl 120);
        0 -> V bsr 1
    end,
    gf_mult(X, V1, Z1, I - 1).

%% Data XOR the GCM key stream from counter block Counter on, with Pending
%% key stream left from before: the output, the next counter, and the key
%% stream left over. The counter increments in its low 32 bits.
-spec gcm_stream({atom(), binary()}, non_neg_integer(), binary(), binary()) -> {binary(), non_neg_integer(), binary()}.
gcm_stream({Ecb, Key}, Counter, Pending, Data) ->
    Need = byte_size(Data) - byte_size(Pending),
    Blocks = max(0, (Need + 15) div 16),
    Counters = << <<(inc32(Counter, I)):128>> || I <- lists:seq(0, Blocks - 1) >>,
    Stream = <<Pending/binary, (ecb(Ecb, Key, Counters, true))/binary>>,
    <<Used:(byte_size(Data))/binary, Left/binary>> = Stream,
    {crypto:exor(Data, Used), inc32(Counter, Blocks), Left}.

inc32(Counter, N) ->
    (Counter band (bnot 16#FFFFFFFF)) bor ((Counter + N) band 16#FFFFFFFF).

%%% OCB

%% OCB-ENCRYPT or OCB-DECRYPT of RFC 7253 with the AES ECB cipher Ecb:
%% {Output, Tag}. A decryption returns the tag that it computed.
-spec ocb(atom(), binary(), binary(), binary(), binary(), {encrypt | decrypt, pos_integer()}) -> {binary(), binary()}.
ocb(Ecb, Key, Nonce, AAD, Data, {Direction, TagLen}) ->
    Enc = fun(B) -> ecb(Ecb, Key, B, true) end,
    LStar = binary:decode_unsigned(Enc(<<0:128>>)),
    LDollar = double(LStar),
    L0 = double(LDollar),
    NonceBlock = <<((TagLen * 8) rem 128):7, 0:(120 - bit_size(Nonce)), 1:1, Nonce/binary>>,
    <<Top:122/bitstring, Bottom:6>> = NonceBlock,
    Ktop = Enc(<<Top/bitstring, 0:6>>),
    <<K1:64, K2:64>> = Ktop,
    <<_:Bottom, Offset0:128, _/bitstring>> = <<Ktop/binary, (K1 bxor ((K1 bsl 8 bor (K2 bsr 56)) band 16#FFFFFFFFFFFFFFFF)):64>>,
    Full = byte_size(Data) div 16,
    <<FullData:(Full * 16)/binary, Last/binary>> = Data,
    Offsets = offsets(Offset0, L0, Full),
    OffsetBin = << <<O:128>> || O <- Offsets >>,
    Mid = crypto:exor(FullData, OffsetBin),
    Processed = case Direction of
        encrypt -> ecb(Ecb, Key, Mid, true);
        decrypt -> ecb(Ecb, Key, Mid, false)
    end,
    FullOut = crypto:exor(Processed, OffsetBin),
    OffsetM = lists:last([Offset0 | Offsets]),
    Plain = case Direction of
        encrypt -> FullData;
        decrypt -> FullOut
    end,
    Checksum0 = lists:foldl(fun(B, Acc) -> Acc bxor B end, 0, [B || <<B:128>> <= Plain]),
    {LastOut, Checksum, OffsetFinal} = case Last of
        <<>> -> {<<>>, Checksum0, OffsetM};
        _ ->
            OffsetStar = OffsetM bxor LStar,
            Pad = Enc(<<OffsetStar:128>>),
            Out = crypto:exor(Last, binary:part(Pad, 0, byte_size(Last))),
            LastPlain = case Direction of
                encrypt -> Last;
                decrypt -> Out
            end,
            <<P:128>> = <<LastPlain/binary, 16#80, 0:((15 - byte_size(Last)) * 8)>>,
            {Out, Checksum0 bxor P, OffsetStar}
    end,
    <<T:128>> = Enc(<<(Checksum bxor OffsetFinal bxor LDollar):128>>),
    Tag = <<(T bxor ocb_hash(Enc, LStar, L0, AAD)):128>>,
    {<<FullOut/binary, LastOut/binary>>, binary:part(Tag, 0, TagLen)}.

ocb_hash(Enc, LStar, L0, AAD) ->
    Full = byte_size(AAD) div 16,
    <<FullData:(Full * 16)/binary, Last/binary>> = AAD,
    Offsets = offsets(0, L0, Full),
    OffsetBin = << <<O:128>> || O <- Offsets >>,
    Sum0 = lists:foldl(fun(B, Acc) -> Acc bxor B end, 0,
                       [B || <<B:128>> <= Enc(crypto:exor(FullData, OffsetBin))]),
    case Last of
        <<>> -> Sum0;
        _ ->
            OffsetStar = lists:last([0 | Offsets]) bxor LStar,
            <<P:128>> = <<Last/binary, 16#80, 0:((15 - byte_size(Last)) * 8)>>,
            <<S:128>> = Enc(<<(P bxor OffsetStar):128>>),
            Sum0 bxor S
    end.

%% Offset_1 .. Offset_N: Offset_i = Offset_(i-1) xor L_ntz(i).
offsets(Offset0, L0, N) ->
    {Offsets, _, _} = lists:foldl(fun(I, {Acc, Prev, Ls}) ->
        Z = ntz(I),
        Ls1 = extend(Ls, Z),
        O = Prev bxor lists:nth(Z + 1, Ls1),
        {[O | Acc], O, Ls1}
    end, {[], Offset0, [L0]}, lists:seq(1, N)),
    lists:reverse(Offsets).

extend(Ls, Z) when length(Ls) > Z -> Ls;
extend(Ls, Z) -> extend(Ls ++ [double(lists:last(Ls))], Z).

ntz(I) when I band 1 =:= 1 -> 0;
ntz(I) -> 1 + ntz(I bsr 1).

double(S) ->
    case S bsr 127 of
        1 -> ((S bsl 1) band ((1 bsl 128) - 1)) bxor 16#87;
        0 -> S bsl 1
    end.

%%% AES key wrap

%% RFC 3394 with the initial value IV (8 bytes).
-spec aes_wrap(atom(), binary(), binary(), binary()) -> binary().
aes_wrap(Ecb, Key, IV, Plain) ->
    N = byte_size(Plain) div 8,
    R0 = [B || <<B:8/binary>> <= Plain],
    {A, R} = lists:foldl(fun(J, {A0, Rs}) ->
        {A1, Rs1} = lists:foldl(fun({I, Ri}, {Ai, Acc}) ->
            <<Msb:64, Lsb:8/binary>> = ecb(Ecb, Key, <<Ai/binary, Ri/binary>>, true),
            {<<(Msb bxor (N * J + I)):64>>, [Lsb | Acc]}
        end, {A0, []}, lists:zip(lists:seq(1, N), Rs)),
        {A1, lists:reverse(Rs1)}
    end, {IV, R0}, lists:seq(0, 5)),
    iolist_to_binary([A | R]).

%% The plain bytes of Wrapped, or error when its check value is not IV.
-spec aes_unwrap(atom(), binary(), binary(), binary()) -> {ok, binary()} | error.
aes_unwrap(Ecb, Key, IV, Wrapped) ->
    case unwrap(Ecb, Key, Wrapped) of
        {IV, Plain} -> {ok, Plain};
        _ -> error
    end.

unwrap(Ecb, Key, <<A0:8/binary, Rest/binary>>) ->
    N = byte_size(Rest) div 8,
    R0 = [B || <<B:8/binary>> <= Rest],
    {A, R} = lists:foldl(fun(J, {Aj, Rs}) ->
        {A1, Rs1} = lists:foldl(fun({I, Ri}, {Ai, Acc}) ->
            <<Av:64>> = Ai,
            <<Msb:8/binary, Lsb:8/binary>> = ecb(Ecb, Key, <<(Av bxor (N * J + I)):64, Ri/binary>>, false),
            {Msb, [Lsb | Acc]}
        end, {Aj, []}, lists:reverse(lists:zip(lists:seq(1, N), Rs))),
        {A1, Rs1}
    end, {A0, R0}, lists:seq(5, 0, -1)),
    {A, iolist_to_binary(R)}.

%% RFC 5649 with the 4 bytes IV of the alternative initial value.
-spec aes_wrap_pad(atom(), binary(), binary(), binary()) -> binary().
aes_wrap_pad(Ecb, Key, IV, Plain) ->
    Len = byte_size(Plain),
    Padded = <<Plain/binary, 0:(((8 - Len rem 8) rem 8) * 8)>>,
    Aiv = <<IV/binary, Len:32>>,
    case byte_size(Padded) of
        8 -> ecb(Ecb, Key, <<Aiv/binary, Padded/binary>>, true);
        _ -> aes_wrap(Ecb, Key, Aiv, Padded)
    end.

-spec aes_unwrap_pad(atom(), binary(), binary(), binary()) -> {ok, binary()} | error.
aes_unwrap_pad(Ecb, Key, IV, Wrapped) ->
    {Aiv, Padded} = case byte_size(Wrapped) of
        16 ->
            <<A:8/binary, P:8/binary>> = ecb(Ecb, Key, Wrapped, false),
            {A, P};
        _ -> unwrap(Ecb, Key, Wrapped)
    end,
    case Aiv of
        <<IV:4/binary, Len:32>> when Len =< byte_size(Padded), byte_size(Padded) - Len < 8 ->
            <<Plain:Len/binary, Zeros/binary>> = Padded,
            case Zeros =:= <<0:(byte_size(Zeros) * 8)>> of
                true -> {ok, Plain};
                false -> error
            end;
        _ -> error
    end.

%%% CMS Triple-DES key wrap

-define(DES3_WRAP_IV, <<16#4a, 16#dd, 16#a2, 16#2c, 16#79, 16#e8, 16#21, 16#05>>).

-spec des3_wrap(binary(), binary()) -> binary().
des3_wrap(Key, Cek) ->
    Icv = binary:part(crypto:hash(sha, Cek), 0, 8),
    IV = crypto:strong_rand_bytes(8),
    Temp1 = crypto:crypto_one_time(des_ede3_cbc, Key, IV, <<Cek/binary, Icv/binary>>, true),
    Temp3 = reverse(<<IV/binary, Temp1/binary>>),
    crypto:crypto_one_time(des_ede3_cbc, Key, ?DES3_WRAP_IV, Temp3, true).

-spec des3_unwrap(binary(), binary()) -> {ok, binary()} | error.
des3_unwrap(Key, Wrapped) when byte_size(Wrapped) >= 24, byte_size(Wrapped) rem 8 =:= 0 ->
    Temp3 = crypto:crypto_one_time(des_ede3_cbc, Key, ?DES3_WRAP_IV, Wrapped, false),
    <<IV:8/binary, Temp1/binary>> = reverse(Temp3),
    Plain = crypto:crypto_one_time(des_ede3_cbc, Key, IV, Temp1, false),
    Size = byte_size(Plain) - 8,
    <<Cek:Size/binary, Icv:8/binary>> = Plain,
    case binary:part(crypto:hash(sha, Cek), 0, 8) =:= Icv of
        true -> {ok, Cek};
        false -> error
    end;
des3_unwrap(_, _) -> error.

reverse(Bin) -> list_to_binary(lists:reverse(binary_to_list(Bin))).
