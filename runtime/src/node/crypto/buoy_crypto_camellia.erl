%% The Camellia block cipher of RFC 3713, for the camellia ciphers of
%% OpenSSL that OTP's crypto does not expose. The 64-bit halves of the
%% Feistel network are pairs of 32-bit words, so no bignum is made.
-module(buoy_crypto_camellia).

-export([schedule/2, block/2]).

-define(M32, 16#FFFFFFFF).
-define(M64, 16#FFFFFFFFFFFFFFFF).
-define(M128, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF).

-define(S1, {16#70, 16#82, 16#2C, 16#EC, 16#B3, 16#27, 16#C0, 16#E5, 16#E4, 16#85, 16#57, 16#35, 16#EA, 16#0C, 16#AE, 16#41,
                 16#23, 16#EF, 16#6B, 16#93, 16#45, 16#19, 16#A5, 16#21, 16#ED, 16#0E, 16#4F, 16#4E, 16#1D, 16#65, 16#92, 16#BD,
                 16#86, 16#B8, 16#AF, 16#8F, 16#7C, 16#EB, 16#1F, 16#CE, 16#3E, 16#30, 16#DC, 16#5F, 16#5E, 16#C5, 16#0B, 16#1A,
                 16#A6, 16#E1, 16#39, 16#CA, 16#D5, 16#47, 16#5D, 16#3D, 16#D9, 16#01, 16#5A, 16#D6, 16#51, 16#56, 16#6C, 16#4D,
                 16#8B, 16#0D, 16#9A, 16#66, 16#FB, 16#CC, 16#B0, 16#2D, 16#74, 16#12, 16#2B, 16#20, 16#F0, 16#B1, 16#84, 16#99,
                 16#DF, 16#4C, 16#CB, 16#C2, 16#34, 16#7E, 16#76, 16#05, 16#6D, 16#B7, 16#A9, 16#31, 16#D1, 16#17, 16#04, 16#D7,
                 16#14, 16#58, 16#3A, 16#61, 16#DE, 16#1B, 16#11, 16#1C, 16#32, 16#0F, 16#9C, 16#16, 16#53, 16#18, 16#F2, 16#22,
                 16#FE, 16#44, 16#CF, 16#B2, 16#C3, 16#B5, 16#7A, 16#91, 16#24, 16#08, 16#E8, 16#A8, 16#60, 16#FC, 16#69, 16#50,
                 16#AA, 16#D0, 16#A0, 16#7D, 16#A1, 16#89, 16#62, 16#97, 16#54, 16#5B, 16#1E, 16#95, 16#E0, 16#FF, 16#64, 16#D2,
                 16#10, 16#C4, 16#00, 16#48, 16#A3, 16#F7, 16#75, 16#DB, 16#8A, 16#03, 16#E6, 16#DA, 16#09, 16#3F, 16#DD, 16#94,
                 16#87, 16#5C, 16#83, 16#02, 16#CD, 16#4A, 16#90, 16#33, 16#73, 16#67, 16#F6, 16#F3, 16#9D, 16#7F, 16#BF, 16#E2,
                 16#52, 16#9B, 16#D8, 16#26, 16#C8, 16#37, 16#C6, 16#3B, 16#81, 16#96, 16#6F, 16#4B, 16#13, 16#BE, 16#63, 16#2E,
                 16#E9, 16#79, 16#A7, 16#8C, 16#9F, 16#6E, 16#BC, 16#8E, 16#29, 16#F5, 16#F9, 16#B6, 16#2F, 16#FD, 16#B4, 16#59,
                 16#78, 16#98, 16#06, 16#6A, 16#E7, 16#46, 16#71, 16#BA, 16#D4, 16#25, 16#AB, 16#42, 16#88, 16#A2, 16#8D, 16#FA,
                 16#72, 16#07, 16#B9, 16#55, 16#F8, 16#EE, 16#AC, 16#0A, 16#36, 16#49, 16#2A, 16#68, 16#3C, 16#38, 16#F1, 16#A4,
                 16#40, 16#28, 16#D3, 16#7B, 16#BB, 16#C9, 16#43, 16#C1, 16#15, 16#E3, 16#AD, 16#F4, 16#77, 16#C7, 16#80, 16#9E}).
-define(S2, {16#E0, 16#05, 16#58, 16#D9, 16#67, 16#4E, 16#81, 16#CB, 16#C9, 16#0B, 16#AE, 16#6A, 16#D5, 16#18, 16#5D, 16#82,
                 16#46, 16#DF, 16#D6, 16#27, 16#8A, 16#32, 16#4B, 16#42, 16#DB, 16#1C, 16#9E, 16#9C, 16#3A, 16#CA, 16#25, 16#7B,
                 16#0D, 16#71, 16#5F, 16#1F, 16#F8, 16#D7, 16#3E, 16#9D, 16#7C, 16#60, 16#B9, 16#BE, 16#BC, 16#8B, 16#16, 16#34,
                 16#4D, 16#C3, 16#72, 16#95, 16#AB, 16#8E, 16#BA, 16#7A, 16#B3, 16#02, 16#B4, 16#AD, 16#A2, 16#AC, 16#D8, 16#9A,
                 16#17, 16#1A, 16#35, 16#CC, 16#F7, 16#99, 16#61, 16#5A, 16#E8, 16#24, 16#56, 16#40, 16#E1, 16#63, 16#09, 16#33,
                 16#BF, 16#98, 16#97, 16#85, 16#68, 16#FC, 16#EC, 16#0A, 16#DA, 16#6F, 16#53, 16#62, 16#A3, 16#2E, 16#08, 16#AF,
                 16#28, 16#B0, 16#74, 16#C2, 16#BD, 16#36, 16#22, 16#38, 16#64, 16#1E, 16#39, 16#2C, 16#A6, 16#30, 16#E5, 16#44,
                 16#FD, 16#88, 16#9F, 16#65, 16#87, 16#6B, 16#F4, 16#23, 16#48, 16#10, 16#D1, 16#51, 16#C0, 16#F9, 16#D2, 16#A0,
                 16#55, 16#A1, 16#41, 16#FA, 16#43, 16#13, 16#C4, 16#2F, 16#A8, 16#B6, 16#3C, 16#2B, 16#C1, 16#FF, 16#C8, 16#A5,
                 16#20, 16#89, 16#00, 16#90, 16#47, 16#EF, 16#EA, 16#B7, 16#15, 16#06, 16#CD, 16#B5, 16#12, 16#7E, 16#BB, 16#29,
                 16#0F, 16#B8, 16#07, 16#04, 16#9B, 16#94, 16#21, 16#66, 16#E6, 16#CE, 16#ED, 16#E7, 16#3B, 16#FE, 16#7F, 16#C5,
                 16#A4, 16#37, 16#B1, 16#4C, 16#91, 16#6E, 16#8D, 16#76, 16#03, 16#2D, 16#DE, 16#96, 16#26, 16#7D, 16#C6, 16#5C,
                 16#D3, 16#F2, 16#4F, 16#19, 16#3F, 16#DC, 16#79, 16#1D, 16#52, 16#EB, 16#F3, 16#6D, 16#5E, 16#FB, 16#69, 16#B2,
                 16#F0, 16#31, 16#0C, 16#D4, 16#CF, 16#8C, 16#E2, 16#75, 16#A9, 16#4A, 16#57, 16#84, 16#11, 16#45, 16#1B, 16#F5,
                 16#E4, 16#0E, 16#73, 16#AA, 16#F1, 16#DD, 16#59, 16#14, 16#6C, 16#92, 16#54, 16#D0, 16#78, 16#70, 16#E3, 16#49,
                 16#80, 16#50, 16#A7, 16#F6, 16#77, 16#93, 16#86, 16#83, 16#2A, 16#C7, 16#5B, 16#E9, 16#EE, 16#8F, 16#01, 16#3D}).
-define(S3, {16#38, 16#41, 16#16, 16#76, 16#D9, 16#93, 16#60, 16#F2, 16#72, 16#C2, 16#AB, 16#9A, 16#75, 16#06, 16#57, 16#A0,
                 16#91, 16#F7, 16#B5, 16#C9, 16#A2, 16#8C, 16#D2, 16#90, 16#F6, 16#07, 16#A7, 16#27, 16#8E, 16#B2, 16#49, 16#DE,
                 16#43, 16#5C, 16#D7, 16#C7, 16#3E, 16#F5, 16#8F, 16#67, 16#1F, 16#18, 16#6E, 16#AF, 16#2F, 16#E2, 16#85, 16#0D,
                 16#53, 16#F0, 16#9C, 16#65, 16#EA, 16#A3, 16#AE, 16#9E, 16#EC, 16#80, 16#2D, 16#6B, 16#A8, 16#2B, 16#36, 16#A6,
                 16#C5, 16#86, 16#4D, 16#33, 16#FD, 16#66, 16#58, 16#96, 16#3A, 16#09, 16#95, 16#10, 16#78, 16#D8, 16#42, 16#CC,
                 16#EF, 16#26, 16#E5, 16#61, 16#1A, 16#3F, 16#3B, 16#82, 16#B6, 16#DB, 16#D4, 16#98, 16#E8, 16#8B, 16#02, 16#EB,
                 16#0A, 16#2C, 16#1D, 16#B0, 16#6F, 16#8D, 16#88, 16#0E, 16#19, 16#87, 16#4E, 16#0B, 16#A9, 16#0C, 16#79, 16#11,
                 16#7F, 16#22, 16#E7, 16#59, 16#E1, 16#DA, 16#3D, 16#C8, 16#12, 16#04, 16#74, 16#54, 16#30, 16#7E, 16#B4, 16#28,
                 16#55, 16#68, 16#50, 16#BE, 16#D0, 16#C4, 16#31, 16#CB, 16#2A, 16#AD, 16#0F, 16#CA, 16#70, 16#FF, 16#32, 16#69,
                 16#08, 16#62, 16#00, 16#24, 16#D1, 16#FB, 16#BA, 16#ED, 16#45, 16#81, 16#73, 16#6D, 16#84, 16#9F, 16#EE, 16#4A,
                 16#C3, 16#2E, 16#C1, 16#01, 16#E6, 16#25, 16#48, 16#99, 16#B9, 16#B3, 16#7B, 16#F9, 16#CE, 16#BF, 16#DF, 16#71,
                 16#29, 16#CD, 16#6C, 16#13, 16#64, 16#9B, 16#63, 16#9D, 16#C0, 16#4B, 16#B7, 16#A5, 16#89, 16#5F, 16#B1, 16#17,
                 16#F4, 16#BC, 16#D3, 16#46, 16#CF, 16#37, 16#5E, 16#47, 16#94, 16#FA, 16#FC, 16#5B, 16#97, 16#FE, 16#5A, 16#AC,
                 16#3C, 16#4C, 16#03, 16#35, 16#F3, 16#23, 16#B8, 16#5D, 16#6A, 16#92, 16#D5, 16#21, 16#44, 16#51, 16#C6, 16#7D,
                 16#39, 16#83, 16#DC, 16#AA, 16#7C, 16#77, 16#56, 16#05, 16#1B, 16#A4, 16#15, 16#34, 16#1E, 16#1C, 16#F8, 16#52,
                 16#20, 16#14, 16#E9, 16#BD, 16#DD, 16#E4, 16#A1, 16#E0, 16#8A, 16#F1, 16#D6, 16#7A, 16#BB, 16#E3, 16#40, 16#4F}).
-define(S4, {16#70, 16#2C, 16#B3, 16#C0, 16#E4, 16#57, 16#EA, 16#AE, 16#23, 16#6B, 16#45, 16#A5, 16#ED, 16#4F, 16#1D, 16#92,
                 16#86, 16#AF, 16#7C, 16#1F, 16#3E, 16#DC, 16#5E, 16#0B, 16#A6, 16#39, 16#D5, 16#5D, 16#D9, 16#5A, 16#51, 16#6C,
                 16#8B, 16#9A, 16#FB, 16#B0, 16#74, 16#2B, 16#F0, 16#84, 16#DF, 16#CB, 16#34, 16#76, 16#6D, 16#A9, 16#D1, 16#04,
                 16#14, 16#3A, 16#DE, 16#11, 16#32, 16#9C, 16#53, 16#F2, 16#FE, 16#CF, 16#C3, 16#7A, 16#24, 16#E8, 16#60, 16#69,
                 16#AA, 16#A0, 16#A1, 16#62, 16#54, 16#1E, 16#E0, 16#64, 16#10, 16#00, 16#A3, 16#75, 16#8A, 16#E6, 16#09, 16#DD,
                 16#87, 16#83, 16#CD, 16#90, 16#73, 16#F6, 16#9D, 16#BF, 16#52, 16#D8, 16#C8, 16#C6, 16#81, 16#6F, 16#13, 16#63,
                 16#E9, 16#A7, 16#9F, 16#BC, 16#29, 16#F9, 16#2F, 16#B4, 16#78, 16#06, 16#E7, 16#71, 16#D4, 16#AB, 16#88, 16#8D,
                 16#72, 16#B9, 16#F8, 16#AC, 16#36, 16#2A, 16#3C, 16#F1, 16#40, 16#D3, 16#BB, 16#43, 16#15, 16#AD, 16#77, 16#80,
                 16#82, 16#EC, 16#27, 16#E5, 16#85, 16#35, 16#0C, 16#41, 16#EF, 16#93, 16#19, 16#21, 16#0E, 16#4E, 16#65, 16#BD,
                 16#B8, 16#8F, 16#EB, 16#CE, 16#30, 16#5F, 16#C5, 16#1A, 16#E1, 16#CA, 16#47, 16#3D, 16#01, 16#D6, 16#56, 16#4D,
                 16#0D, 16#66, 16#CC, 16#2D, 16#12, 16#20, 16#B1, 16#99, 16#4C, 16#C2, 16#7E, 16#05, 16#B7, 16#31, 16#17, 16#D7,
                 16#58, 16#61, 16#1B, 16#1C, 16#0F, 16#16, 16#18, 16#22, 16#44, 16#B2, 16#B5, 16#91, 16#08, 16#A8, 16#FC, 16#50,
                 16#D0, 16#7D, 16#89, 16#97, 16#5B, 16#95, 16#FF, 16#D2, 16#C4, 16#48, 16#F7, 16#DB, 16#03, 16#DA, 16#3F, 16#94,
                 16#5C, 16#02, 16#4A, 16#33, 16#67, 16#F3, 16#7F, 16#E2, 16#9B, 16#26, 16#37, 16#3B, 16#96, 16#4B, 16#BE, 16#2E,
                 16#79, 16#8C, 16#6E, 16#8E, 16#F5, 16#B6, 16#FD, 16#59, 16#98, 16#6A, 16#46, 16#BA, 16#25, 16#42, 16#A2, 16#FA,
                 16#07, 16#55, 16#EE, 16#0A, 16#49, 16#68, 16#38, 16#A4, 16#28, 16#7B, 16#C9, 16#C1, 16#E3, 16#F4, 16#C7, 16#9E}).

-type key() :: {non_neg_integer(), non_neg_integer()}.
-type schedule() :: {key(), key(), [[key()]], [{key(), key()}], key(), key()}.
-export_type([schedule/0]).

%% The subkeys of Key (16, 24, or 32 bytes) for encryption, or for
%% decryption, which takes them in the reverse order (section 2.3.3).
-spec schedule(binary(), boolean()) -> schedule().
schedule(Key, true) -> subkeys(Key);
schedule(Key, false) ->
    {Kw1, Kw2, Rounds, Fls, Kw3, Kw4} = subkeys(Key),
    {Kw3, Kw4, lists:reverse([lists:reverse(R) || R <- Rounds]), lists:reverse([{B, A} || {A, B} <- Fls]), Kw1, Kw2}.

subkeys(Key) ->
    {KL, KR} = case Key of
        <<L:128>> -> {L, 0};
        <<L:128, R:64>> -> {L, (R bsl 64) bor (bnot R band ?M64)};
        <<L:128, R:128>> -> {L, R}
    end,
    KA = feistel(feistel(KL bxor KR, 16#A09E667F3BCC908B, 16#B67AE8584CAA73B2) bxor KL,
                 16#C6EF372FE94F82BE, 16#54FF53A5F1D36F1C),
    Sub = fun(K, N) -> rotl128(K, N) end,
    case byte_size(Key) of
        16 ->
            Ks = halves([Sub(KA, 0), Sub(KL, 15), Sub(KA, 15)]) ++
                 [hi(Sub(KL, 45)), lo(Sub(KL, 45)), hi(Sub(KA, 45)), lo(Sub(KL, 60))] ++ halves([Sub(KA, 60)]) ++
                 halves([Sub(KL, 94), Sub(KA, 94), Sub(KL, 111)]),
            Fls = [pair(Sub(KA, 30)), pair(Sub(KL, 77))],
            {hi(KL), lo(KL), chunks(Ks), Fls, hi(Sub(KA, 111)), lo(Sub(KA, 111))};
        _ ->
            KB = feistel(KA bxor KR, 16#10E527FADE682D1D, 16#B05688C2B3E6C1FD),
            Ks = halves([Sub(KB, 0), Sub(KR, 15), Sub(KA, 15), Sub(KB, 30), Sub(KL, 45), Sub(KA, 45),
                         Sub(KR, 60), Sub(KB, 60), Sub(KL, 77), Sub(KR, 94), Sub(KA, 94), Sub(KL, 111)]),
            Fls = [pair(Sub(KR, 30)), pair(Sub(KL, 60)), pair(Sub(KA, 77))],
            {hi(KL), lo(KL), chunks(Ks), Fls, hi(Sub(KB, 111)), lo(Sub(KB, 111))}
    end.

%% Two rounds of the key schedule on a 128-bit value (section 2.2).
feistel(X, Sigma1, Sigma2) ->
    D1 = X bsr 64,
    D2 = (X band ?M64) bxor join(f(split(D1), split(Sigma1))),
    D1b = D1 bxor join(f(split(D2), split(Sigma2))),
    (D1b bsl 64) bor D2.

rotl128(X, 0) -> X;
rotl128(X, N) -> ((X bsl N) bor (X bsr (128 - N))) band ?M128.

hi(X) -> split(X bsr 64).
lo(X) -> split(X band ?M64).
pair(X) -> {hi(X), lo(X)}.
halves(Xs) -> lists:append([[hi(X), lo(X)] || X <- Xs]).
split(X) -> {X bsr 32, X band ?M32}.
join({H, L}) -> (H bsl 32) bor L.

chunks([]) -> [];
chunks(Ks) ->
    {Six, Rest} = lists:split(6, Ks),
    [Six | chunks(Rest)].

%% One 16-byte block under a schedule (section 2.3).
-spec block(schedule(), binary()) -> binary().
block({{W1h, W1l}, {W2h, W2l}, [First | Rounds], Fls, {W3h, W3l}, {W4h, W4l}},
      <<D1h:32, D1l:32, D2h:32, D2l:32>>) ->
    {A, B} = rounds(First, {{D1h bxor W1h, D1l bxor W1l}, {D2h bxor W2h, D2l bxor W2l}}),
    {{Ah, Al}, {Bh, Bl}} = lists:foldl(fun({Group, {Ke1, Ke2}}, {X, Y}) -> rounds(Group, {fl(X, Ke1), flinv(Y, Ke2)}) end,
                                       {A, B}, lists:zip(Rounds, Fls)),
    <<(Bh bxor W3h):32, (Bl bxor W3l):32, (Ah bxor W4h):32, (Al bxor W4l):32>>.

%% Six rounds: D2 ^= F(D1, k), then D1 ^= F(D2, k'), three times.
rounds([K1, K2, K3, K4, K5, K6], {D1, D2}) ->
    {A1, B1} = round2(D1, D2, K1, K2),
    {A2, B2} = round2(A1, B1, K3, K4),
    round2(A2, B2, K5, K6).

round2(D1, D2, Ka, Kb) ->
    D2b = xor64(D2, f(D1, Ka)),
    {xor64(D1, f(D2b, Kb)), D2b}.

xor64({A, B}, {C, D}) -> {A bxor C, B bxor D}.

-compile({inline, [s/2]}).
s(T, X) -> element(X + 1, T).

%% The F-function (section 2.4.1).
f({H, L}, {Kh, Kl}) ->
    X1 = H bxor Kh,
    X2 = L bxor Kl,
    T1 = s(?S1, X1 bsr 24), T2 = s(?S2, (X1 bsr 16) band 255), T3 = s(?S3, (X1 bsr 8) band 255), T4 = s(?S4, X1 band 255),
    T5 = s(?S2, X2 bsr 24), T6 = s(?S3, (X2 bsr 16) band 255), T7 = s(?S4, (X2 bsr 8) band 255), T8 = s(?S1, X2 band 255),
    Y1 = T1 bxor T3 bxor T4 bxor T6 bxor T7 bxor T8,
    Y2 = T1 bxor T2 bxor T4 bxor T5 bxor T7 bxor T8,
    Y3 = T1 bxor T2 bxor T3 bxor T5 bxor T6 bxor T8,
    Y4 = T2 bxor T3 bxor T4 bxor T5 bxor T6 bxor T7,
    Y5 = T1 bxor T2 bxor T6 bxor T7 bxor T8,
    Y6 = T2 bxor T3 bxor T5 bxor T7 bxor T8,
    Y7 = T3 bxor T4 bxor T5 bxor T6 bxor T8,
    Y8 = T1 bxor T4 bxor T5 bxor T6 bxor T7,
    {(Y1 bsl 24) bor (Y2 bsl 16) bor (Y3 bsl 8) bor Y4, (Y5 bsl 24) bor (Y6 bsl 16) bor (Y7 bsl 8) bor Y8}.

%% FL and FLINV (section 2.4.2).
fl({X1, X2}, {K1, K2}) ->
    X2b = X2 bxor rotl32(X1 band K1),
    {X1 bxor (X2b bor K2), X2b}.

flinv({Y1, Y2}, {K1, K2}) ->
    Y1b = Y1 bxor (Y2 bor K2),
    {Y1b, Y2 bxor rotl32(Y1b band K1)}.

rotl32(X) -> ((X bsl 1) bor (X bsr 31)) band ?M32.
