%% The cipher modes that OpenSSL has and OTP's crypto does not expose, on
%% the block ciphers that it does and on Camellia and ARIA: the GCM key
%% stream for streaming encryption, GCM and CCM in one pass, OCB (RFC 7253),
%% XTS (IEEE 1619), the stream of ECB, CBC, CFB, CFB1, CFB8, OFB, and CTR
%% as EVP_CipherUpdate runs it, AES key wrap (RFC 3394 and RFC 5649), and
%% the Triple-DES key wrap of CMS (RFC 3217).
-module(buoy_crypto_modes).

-export([ecb/4, gcm_j0/3, gcm_stream/4, gcm/7, ccm/7, ocb/6, xts/5, aes_wrap/4, aes_unwrap/4, aes_wrap_pad/4,
         aes_unwrap_pad/4, des3_wrap/2, des3_unwrap/2]).
-export([stream_init/6, stream_update/2, stream_final/1]).

%% A block cipher: an OTP ECB cipher such as aes_128_ecb, des_ede3,
%% camellia, or aria.
-type block_cipher() :: atom().

%% ECB of the block cipher Cipher over whole blocks.
-spec ecb(block_cipher(), binary(), binary(), boolean()) -> binary().
ecb(des_ede3, Key, Data, Encrypt) ->
    << <<(crypto:crypto_one_time(des_ede3_cbc, Key, <<0:64>>, B, Encrypt))/binary>> || <<B:8/binary>> <= Data >>;
ecb(Cipher, Key, Data, Encrypt) when Cipher =:= camellia; Cipher =:= aria ->
    F = block_fun(Cipher, Key, Encrypt),
    << <<(F(B))/binary>> || <<B:16/binary>> <= Data >>;
ecb(Cipher, Key, Data, Encrypt) ->
    crypto:crypto_one_time(Cipher, Key, Data, Encrypt).

%% The function of one block of Cipher under Key, with the key schedule made once.
block_fun(camellia, Key, Encrypt) ->
    Schedule = buoy_crypto_camellia:schedule(Key, Encrypt),
    fun(B) -> buoy_crypto_camellia:block(Schedule, B) end;
block_fun(aria, Key, Encrypt) ->
    Schedule = buoy_crypto_aria:schedule(Key, Encrypt),
    fun(B) -> buoy_crypto_aria:block(Schedule, B) end;
block_fun(Cipher, Key, Encrypt) ->
    fun(B) -> ecb(Cipher, Key, B, Encrypt) end.

block_size(des_ede3) -> 8;
block_size(_) -> 16.

%%% Streams

%% The state of a mode of Cipher as EVP_CipherInit leaves it. Only ECB and
%% CBC decrypt with the inverse cipher; the feedback modes encrypt both ways.
-spec stream_init(ecb | cbc | cfb | cfb1 | cfb8 | ofb | ctr, block_cipher(), binary(), binary(), boolean(),
                  boolean()) -> map().
stream_init(Mode, Cipher, Key, IV, Encrypt, Padding) ->
    Forward = Encrypt orelse (Mode =/= ecb andalso Mode =/= cbc),
    #{mode => Mode, size => block_size(Cipher), block => block_fun(Cipher, Key, Forward), encrypt => Encrypt,
      padding => Padding, register => IV, stream => <<>>, num => 0, buffer => <<>>}.

%% The output of an update. ECB and CBC give whole blocks, and a decryption
%% with padding holds its last block back for the final step.
-spec stream_update(map(), binary()) -> {binary(), map()}.
stream_update(#{mode := Mode, size := Size, buffer := Buffer, encrypt := Encrypt, padding := Padding} = S, Data)
  when Mode =:= ecb; Mode =:= cbc ->
    All = <<Buffer/binary, Data/binary>>,
    Whole = byte_size(All) div Size * Size,
    Keep = case not Encrypt andalso Padding andalso Whole > 0 andalso Whole =:= byte_size(All) of
        true -> Size;
        false -> byte_size(All) - Whole
    end,
    Take = byte_size(All) - Keep,
    <<Now:Take/binary, Rest/binary>> = All,
    {Out, S1} = blocks(S, Now),
    {Out, S1#{buffer := Rest}};
stream_update(S, Data) ->
    feedback(S, Data, []).

%% The output of the final step, or error(final) when the data does not
%% end a block or its padding is wrong, as EVP_CipherFinal fails.
-spec stream_final(map()) -> binary().
stream_final(#{mode := Mode} = S) when Mode =:= ecb; Mode =:= cbc ->
    case S of
        #{encrypt := true, padding := true, buffer := B, size := Size} ->
            N = Size - byte_size(B),
            element(1, blocks(S, <<B/binary, (binary:copy(<<N>>, N))/binary>>));
        #{padding := false, buffer := <<>>} ->
            <<>>;
        #{encrypt := false, padding := true, buffer := B, size := Size} when byte_size(B) =:= Size ->
            {Plain, _} = blocks(S, B),
            N = binary:last(Plain),
            case N >= 1 andalso N =< Size andalso binary:part(Plain, Size - N, N) =:= binary:copy(<<N>>, N) of
                true -> binary:part(Plain, 0, Size - N);
                false -> error(final)
            end;
        _ ->
            error(final)
    end;
stream_final(_) ->
    <<>>.

blocks(#{mode := ecb, block := F, size := Size} = S, Data) ->
    {<< <<(F(B))/binary>> || <<B:Size/binary>> <= Data >>, S};
blocks(#{mode := cbc, block := F, size := Size, encrypt := true, register := IV} = S, Data) ->
    {Out, Last} = lists:mapfoldl(fun(P, Prev) -> C = F(crypto:exor(P, Prev)), {C, C} end, IV,
                                 [B || <<B:Size/binary>> <= Data]),
    {iolist_to_binary(Out), S#{register := Last}};
blocks(#{mode := cbc, block := F, size := Size, register := IV} = S, Data) ->
    {Out, Last} = lists:mapfoldl(fun(C, Prev) -> {crypto:exor(F(C), Prev), C} end, IV,
                                 [B || <<B:Size/binary>> <= Data]),
    {iolist_to_binary(Out), S#{register := Last}}.

%% The feedback modes, as CRYPTO_cfb128_encrypt, CRYPTO_ofb128_encrypt,
%% CRYPTO_ctr128_encrypt, CRYPTO_cfb128_8_encrypt, and
%% CRYPTO_cfb128_1_encrypt run them: Num counts the bytes of the register
%% that the stream has used.
feedback(S, <<>>, Acc) ->
    {iolist_to_binary(lists:reverse(Acc)), S};
feedback(#{mode := cfb8, block := F, size := Size, encrypt := Encrypt, register := Reg} = S, <<B, Rest/binary>>, Acc) ->
    <<K, _/binary>> = F(Reg),
    Out = B bxor K,
    Fed = case Encrypt of
        true -> Out;
        false -> B
    end,
    feedback(S#{register := <<(binary:part(Reg, 1, Size - 1))/binary, Fed>>}, Rest, [Out | Acc]);
feedback(#{mode := cfb1} = S, <<B, Rest/binary>>, Acc) ->
    {Out, S1} = cfb1_byte(S, B, 7, 0),
    feedback(S1, Rest, [Out | Acc]);
feedback(#{mode := Mode, block := F, size := Size, encrypt := Encrypt, num := Num, register := Reg0} = S, Data, Acc) ->
    L = min(Size - Num, byte_size(Data)),
    <<Chunk:L/binary, Rest/binary>> = Data,
    S1 = case {Mode, Num} of
        {cfb, 0} -> S#{register := F(Reg0)};
        {ofb, 0} -> S#{register := F(Reg0)};
        {ctr, 0} -> <<Counter:(Size * 8)>> = Reg0, S#{stream := F(Reg0), register := <<(Counter + 1):(Size * 8)>>};
        _ -> S
    end,
    Pad = case Mode of
        ctr -> maps:get(stream, S1);
        _ -> maps:get(register, S1)
    end,
    Out = crypto:exor(Chunk, binary:part(Pad, Num, L)),
    S2 = case {Mode, Encrypt} of
        {cfb, true} -> S1#{register := replace(maps:get(register, S1), Num, Out)};
        {cfb, false} -> S1#{register := replace(maps:get(register, S1), Num, Chunk)};
        _ -> S1
    end,
    feedback(S2#{num := (Num + L) rem Size}, Rest, [Out | Acc]).

replace(Bin, At, Part) ->
    <<Head:At/binary, _:(byte_size(Part))/binary, Tail/binary>> = Bin,
    <<Head/binary, Part/binary, Tail/binary>>.

%% One byte of CFB1, a bit at a time from the high bit, each with a block.
cfb1_byte(S, _, -1, Out) ->
    {Out, S};
cfb1_byte(#{block := F, size := Size, encrypt := Encrypt, register := Reg} = S, B, Bit, Out) ->
    <<K:1, _/bitstring>> = F(Reg),
    In = (B bsr Bit) band 1,
    O = In bxor K,
    Fed = case Encrypt of
        true -> O;
        false -> In
    end,
    <<_:1, Shifted:(Size * 8 - 1)/bitstring>> = Reg,
    cfb1_byte(S#{register := <<Shifted/bitstring, Fed:1>>}, B, Bit - 1, Out bor (O bsl Bit)).

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

%% GCM in one pass on the ECB cipher Ecb, as crypto_one_time_aead runs it:
%% {Out, Tag} for an encryption with a tag of TagOrLen bytes, and Out, or
%% error when the tag TagOrLen does not match, for a decryption.
-spec gcm(block_cipher(), binary(), binary(), binary(), binary(), pos_integer() | binary(), boolean()) ->
    {binary(), binary()} | binary() | error.
gcm(Ecb, Key, IV, Data, AAD, TagOrLen, Encrypt) ->
    H = binary:decode_unsigned(ecb(Ecb, Key, <<0:128>>, true)),
    J0 = gcm_j0(Ecb, Key, IV),
    {Out, _, _} = gcm_stream({Ecb, Key}, inc32(J0, 1), <<>>, Data),
    Ciphertext = case Encrypt of
        true -> Out;
        false -> Data
    end,
    Blocks = <<(pad16(AAD))/binary, (pad16(Ciphertext))/binary, (bit_size(AAD)):64, (bit_size(Ciphertext)):64>>,
    S = lists:foldl(fun(B, Y) -> gf_mult(Y bxor B, H) end, 0, [B || <<B:128>> <= Blocks]),
    Full = crypto:exor(ecb(Ecb, Key, <<J0:128>>, true), <<S:128>>),
    tagged(Encrypt, Out, Full, TagOrLen).

tagged(true, Out, Full, Length) -> {Out, binary:part(Full, 0, Length)};
tagged(false, Out, Full, Tag) ->
    case crypto:hash_equals(binary:part(Full, 0, byte_size(Tag)), Tag) of
        true -> Out;
        false -> error
    end.

pad16(Bin) -> <<Bin/binary, 0:(((16 - byte_size(Bin) rem 16) rem 16) * 8)>>.

%% CCM of NIST SP 800-38C on the ECB cipher Ecb, as gcm/7.
-spec ccm(block_cipher(), binary(), binary(), binary(), binary(), pos_integer() | binary(), boolean()) ->
    {binary(), binary()} | binary() | error.
ccm(Ecb, Key, Nonce, Data, AAD, TagOrLen, Encrypt) ->
    Enc = fun(B) -> ecb(Ecb, Key, B, true) end,
    L = 15 - byte_size(Nonce),
    M = case Encrypt of
        true -> TagOrLen;
        false -> byte_size(TagOrLen)
    end,
    Counter = fun(I) -> <<(L - 1), Nonce/binary, I:(L * 8)>> end,
    Stream = Enc(<< <<(Counter(I))/binary>> || I <- lists:seq(1, (byte_size(Data) + 15) div 16) >>),
    Out = crypto:exor(Data, binary:part(Stream, 0, byte_size(Data))),
    Plain = case Encrypt of
        true -> Data;
        false -> Out
    end,
    Adata = case AAD of
        <<>> -> 0;
        _ -> 1
    end,
    B0 = <<0:1, Adata:1, ((M - 2) div 2):3, (L - 1):3, Nonce/binary, (byte_size(Plain)):(L * 8)>>,
    Mac = lists:foldl(fun(B, X) -> Enc(crypto:exor(X, B)) end, <<0:128>>,
                      [B || <<B:16/binary>> <= <<B0/binary, (pad16(aad_length(AAD)))/binary, (pad16(Plain))/binary>>]),
    tagged(Encrypt, Out, crypto:exor(Mac, Enc(Counter(0))), TagOrLen).

%% The length of the associated data before it (SP 800-38C, A.2.2).
aad_length(<<>>) -> <<>>;
aad_length(AAD) when byte_size(AAD) < 16#FF00 -> <<(byte_size(AAD)):16, AAD/binary>>;
aad_length(AAD) when byte_size(AAD) < 1 bsl 32 -> <<16#FFFE:16, (byte_size(AAD)):32, AAD/binary>>;
aad_length(AAD) -> <<16#FFFF:16, (byte_size(AAD)):64, AAD/binary>>.

%%% XTS

%% XTS of IEEE 1619 on one data unit of at least one block: Key is the two
%% keys of the AES cipher Ecb, and IV the tweak. A last partial block steals
%% the end of the block before it.
-spec xts(atom(), binary(), binary(), binary(), boolean()) -> binary().
xts(Ecb, Key, IV, Data, Encrypt) ->
    Half = byte_size(Key) div 2,
    <<K1:Half/binary, K2:Half/binary>> = Key,
    <<T0:128/little>> = ecb(Ecb, K2, IV, true),
    Full = byte_size(Data) div 16,
    Tail = byte_size(Data) rem 16,
    Tweaks = tweaks(T0, Full + 1),
    Run = fun(Bin, Ts) ->
        Mask = << <<T:128/little>> || T <- Ts >>,
        crypto:exor(ecb(Ecb, K1, crypto:exor(Bin, Mask), Encrypt), Mask)
    end,
    case Tail of
        0 ->
            Run(Data, lists:sublist(Tweaks, Full));
        _ ->
            Head = (Full - 1) * 16,
            <<First:Head/binary, Last:16/binary, Partial:Tail/binary>> = Data,
            {Before, [TLast, TNext]} = lists:split(Full - 1, Tweaks),
            %% Decryption takes the two last tweaks in the other order.
            {TA, TB} = case Encrypt of
                true -> {TLast, TNext};
                false -> {TNext, TLast}
            end,
            CC = Run(Last, [TA]),
            <<Stolen:Tail/binary, Kept/binary>> = CC,
            <<(Run(First, Before))/binary, (Run(<<Partial/binary, Kept/binary>>, [TB]))/binary, Stolen/binary>>
    end.

%% The tweaks T, T*a, T*a^2, ... of GF(2^128) in little-endian order.
tweaks(T, N) ->
    {Ts, _} = lists:mapfoldl(fun(_, X) -> {X, xts_double(X)} end, T, lists:seq(1, N)),
    Ts.

xts_double(X) ->
    case X bsr 127 of
        1 -> ((X bsl 1) band ((1 bsl 128) - 1)) bxor 16#87;
        0 -> X bsl 1
    end.

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
