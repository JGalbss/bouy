%% The ciphers of internalBinding('crypto') (src/crypto/crypto_cipher.cc,
%% crypto_aes.cc, crypto_chacha20_poly1305.cc, and the cipher of
%% crypto_rsa.cc) on OTP's crypto: CipherBase under createCipheriv and
%% createDecipheriv, getCiphers, getCipherInfo, the RSA functions
%% publicEncrypt, privateDecrypt, privateEncrypt, and publicDecrypt, and
%% the cipher jobs of WebCrypto.
-module(buoy_crypto_cipher).

-export([members/0, exists/1, otp_cipher/1, rsa_crypt/5]).

-define(NO_TAG, undefined).
-define(RSA_PKCS1_PADDING, 1).
-define(RSA_NO_PADDING, 3).
-define(RSA_PKCS1_OAEP_PADDING, 4).
-define(RSA_X931_PADDING, 5).
-define(ENCRYPT, 0).

-spec members() -> [{binary(), term()}].
members() ->
    F = fun buoy_crypto:fn/3,
    [{<<"CipherBase">>, buoy_crypto:class(<<"CipherBase">>, fun init/2, [
        {<<"update">>, 0, fun update/2},
        {<<"final">>, 0, fun final/2},
        {<<"setAutoPadding">>, 0, fun set_auto_padding/2},
        {<<"getAuthTag">>, 0, fun get_auth_tag/2},
        {<<"setAuthTag">>, 0, fun set_auth_tag/2},
        {<<"setAAD">>, 0, fun set_aad/2}])},
     {<<"getSSLCiphers">>, F(<<"getSSLCiphers">>, 0, fun(_, _) -> buoy_heap:new_array(ssl_ciphers()) end)},
     {<<"getCiphers">>, F(<<"getCiphers">>, 0, fun(_, _) -> buoy_heap:new_array([N || {N, _, _, _, _, _, _} <- table()]) end)},
     {<<"publicEncrypt">>, F(<<"publicEncrypt">>, 0, fun(_, Args) -> public_key_cipher(public, encrypt, Args) end)},
     {<<"privateDecrypt">>, F(<<"privateDecrypt">>, 0, fun(_, Args) -> public_key_cipher(private, decrypt, Args) end)},
     {<<"privateEncrypt">>, F(<<"privateEncrypt">>, 0, fun(_, Args) -> public_key_cipher(private, sign, Args) end)},
     {<<"publicDecrypt">>, F(<<"publicDecrypt">>, 0, fun(_, Args) -> public_key_cipher(public, recover, Args) end)},
     {<<"getCipherInfo">>, F(<<"getCipherInfo">>, 3, fun cipher_info/2)},
     {<<"AESCipherJob">>, buoy_crypto_job:class(<<"AESCipherJob">>, fun aes_job/1)},
     {<<"ChaCha20Poly1305CipherJob">>, buoy_crypto_job:class(<<"ChaCha20Poly1305CipherJob">>, fun chacha_job/1)},
     {<<"RSACipherJob">>, buoy_crypto_job:class(<<"RSACipherJob">>, fun rsa_job/1)}].

%%% The ciphers

%% The ciphers of EVP_CIPHER_do_all_sorted as Node 25.9.0 lists them: the
%% name, the canonical name, the NID, the mode, the key length, the IV
%% length, and the block size (0 for a stream cipher).
table() ->
    [
     {<<"aes-128-cbc">>, <<"aes-128-cbc">>, 419, cbc, 16, 16, 16},
     {<<"aes-128-ccm">>, <<"id-aes128-ccm">>, 896, ccm, 16, 12, 1},
     {<<"aes-128-cfb">>, <<"aes-128-cfb">>, 421, cfb, 16, 16, 1},
     {<<"aes-128-cfb1">>, <<"aes-128-cfb1">>, 650, cfb, 16, 16, 1},
     {<<"aes-128-cfb8">>, <<"aes-128-cfb8">>, 653, cfb, 16, 16, 1},
     {<<"aes-128-ctr">>, <<"aes-128-ctr">>, 904, ctr, 16, 16, 1},
     {<<"aes-128-ecb">>, <<"aes-128-ecb">>, 418, ecb, 16, 0, 16},
     {<<"aes-128-gcm">>, <<"id-aes128-gcm">>, 895, gcm, 16, 12, 1},
     {<<"aes-128-ocb">>, <<"aes-128-ocb">>, 958, ocb, 16, 12, 16},
     {<<"aes-128-ofb">>, <<"aes-128-ofb">>, 420, ofb, 16, 16, 1},
     {<<"aes-128-xts">>, <<"aes-128-xts">>, 913, xts, 32, 16, 1},
     {<<"aes-192-cbc">>, <<"aes-192-cbc">>, 423, cbc, 24, 16, 16},
     {<<"aes-192-ccm">>, <<"id-aes192-ccm">>, 899, ccm, 24, 12, 1},
     {<<"aes-192-cfb">>, <<"aes-192-cfb">>, 425, cfb, 24, 16, 1},
     {<<"aes-192-cfb1">>, <<"aes-192-cfb1">>, 651, cfb, 24, 16, 1},
     {<<"aes-192-cfb8">>, <<"aes-192-cfb8">>, 654, cfb, 24, 16, 1},
     {<<"aes-192-ctr">>, <<"aes-192-ctr">>, 905, ctr, 24, 16, 1},
     {<<"aes-192-ecb">>, <<"aes-192-ecb">>, 422, ecb, 24, 0, 16},
     {<<"aes-192-gcm">>, <<"id-aes192-gcm">>, 898, gcm, 24, 12, 1},
     {<<"aes-192-ocb">>, <<"aes-192-ocb">>, 959, ocb, 24, 12, 16},
     {<<"aes-192-ofb">>, <<"aes-192-ofb">>, 424, ofb, 24, 16, 1},
     {<<"aes-256-cbc">>, <<"aes-256-cbc">>, 427, cbc, 32, 16, 16},
     {<<"aes-256-ccm">>, <<"id-aes256-ccm">>, 902, ccm, 32, 12, 1},
     {<<"aes-256-cfb">>, <<"aes-256-cfb">>, 429, cfb, 32, 16, 1},
     {<<"aes-256-cfb1">>, <<"aes-256-cfb1">>, 652, cfb, 32, 16, 1},
     {<<"aes-256-cfb8">>, <<"aes-256-cfb8">>, 655, cfb, 32, 16, 1},
     {<<"aes-256-ctr">>, <<"aes-256-ctr">>, 906, ctr, 32, 16, 1},
     {<<"aes-256-ecb">>, <<"aes-256-ecb">>, 426, ecb, 32, 0, 16},
     {<<"aes-256-gcm">>, <<"id-aes256-gcm">>, 901, gcm, 32, 12, 1},
     {<<"aes-256-ocb">>, <<"aes-256-ocb">>, 960, ocb, 32, 12, 16},
     {<<"aes-256-ofb">>, <<"aes-256-ofb">>, 428, ofb, 32, 16, 1},
     {<<"aes-256-xts">>, <<"aes-256-xts">>, 914, xts, 64, 16, 1},
     {<<"aes128">>, <<"aes-128-cbc">>, 419, cbc, 16, 16, 16},
     {<<"aes128-wrap">>, <<"id-aes128-wrap">>, 788, wrap, 16, 8, 8},
     {<<"aes128-wrap-pad">>, <<"id-aes128-wrap-pad">>, 897, wrap, 16, 4, 8},
     {<<"aes192">>, <<"aes-192-cbc">>, 423, cbc, 24, 16, 16},
     {<<"aes192-wrap">>, <<"id-aes192-wrap">>, 789, wrap, 24, 8, 8},
     {<<"aes192-wrap-pad">>, <<"id-aes192-wrap-pad">>, 900, wrap, 24, 4, 8},
     {<<"aes256">>, <<"aes-256-cbc">>, 427, cbc, 32, 16, 16},
     {<<"aes256-wrap">>, <<"id-aes256-wrap">>, 790, wrap, 32, 8, 8},
     {<<"aes256-wrap-pad">>, <<"id-aes256-wrap-pad">>, 903, wrap, 32, 4, 8},
     {<<"aria-128-cbc">>, <<"aria-128-cbc">>, 1066, cbc, 16, 16, 16},
     {<<"aria-128-ccm">>, <<"aria-128-ccm">>, 1120, ccm, 16, 12, 1},
     {<<"aria-128-cfb">>, <<"aria-128-cfb">>, 1067, cfb, 16, 16, 1},
     {<<"aria-128-cfb1">>, <<"aria-128-cfb1">>, 1080, cfb, 16, 16, 1},
     {<<"aria-128-cfb8">>, <<"aria-128-cfb8">>, 1083, cfb, 16, 16, 1},
     {<<"aria-128-ctr">>, <<"aria-128-ctr">>, 1069, ctr, 16, 16, 1},
     {<<"aria-128-ecb">>, <<"aria-128-ecb">>, 1065, ecb, 16, 0, 16},
     {<<"aria-128-gcm">>, <<"aria-128-gcm">>, 1123, gcm, 16, 12, 1},
     {<<"aria-128-ofb">>, <<"aria-128-ofb">>, 1068, ofb, 16, 16, 1},
     {<<"aria-192-cbc">>, <<"aria-192-cbc">>, 1071, cbc, 24, 16, 16},
     {<<"aria-192-ccm">>, <<"aria-192-ccm">>, 1121, ccm, 24, 12, 1},
     {<<"aria-192-cfb">>, <<"aria-192-cfb">>, 1072, cfb, 24, 16, 1},
     {<<"aria-192-cfb1">>, <<"aria-192-cfb1">>, 1081, cfb, 24, 16, 1},
     {<<"aria-192-cfb8">>, <<"aria-192-cfb8">>, 1084, cfb, 24, 16, 1},
     {<<"aria-192-ctr">>, <<"aria-192-ctr">>, 1074, ctr, 24, 16, 1},
     {<<"aria-192-ecb">>, <<"aria-192-ecb">>, 1070, ecb, 24, 0, 16},
     {<<"aria-192-gcm">>, <<"aria-192-gcm">>, 1124, gcm, 24, 12, 1},
     {<<"aria-192-ofb">>, <<"aria-192-ofb">>, 1073, ofb, 24, 16, 1},
     {<<"aria-256-cbc">>, <<"aria-256-cbc">>, 1076, cbc, 32, 16, 16},
     {<<"aria-256-ccm">>, <<"aria-256-ccm">>, 1122, ccm, 32, 12, 1},
     {<<"aria-256-cfb">>, <<"aria-256-cfb">>, 1077, cfb, 32, 16, 1},
     {<<"aria-256-cfb1">>, <<"aria-256-cfb1">>, 1082, cfb, 32, 16, 1},
     {<<"aria-256-cfb8">>, <<"aria-256-cfb8">>, 1085, cfb, 32, 16, 1},
     {<<"aria-256-ctr">>, <<"aria-256-ctr">>, 1079, ctr, 32, 16, 1},
     {<<"aria-256-ecb">>, <<"aria-256-ecb">>, 1075, ecb, 32, 0, 16},
     {<<"aria-256-gcm">>, <<"aria-256-gcm">>, 1125, gcm, 32, 12, 1},
     {<<"aria-256-ofb">>, <<"aria-256-ofb">>, 1078, ofb, 32, 16, 1},
     {<<"aria128">>, <<"aria-128-cbc">>, 1066, cbc, 16, 16, 16},
     {<<"aria192">>, <<"aria-192-cbc">>, 1071, cbc, 24, 16, 16},
     {<<"aria256">>, <<"aria-256-cbc">>, 1076, cbc, 32, 16, 16},
     {<<"camellia-128-cbc">>, <<"camellia-128-cbc">>, 751, cbc, 16, 16, 16},
     {<<"camellia-128-cfb">>, <<"camellia-128-cfb">>, 757, cfb, 16, 16, 1},
     {<<"camellia-128-cfb1">>, <<"camellia-128-cfb1">>, 760, cfb, 16, 16, 1},
     {<<"camellia-128-cfb8">>, <<"camellia-128-cfb8">>, 763, cfb, 16, 16, 1},
     {<<"camellia-128-ctr">>, <<"camellia-128-ctr">>, 963, ctr, 16, 16, 1},
     {<<"camellia-128-ecb">>, <<"camellia-128-ecb">>, 754, ecb, 16, 0, 16},
     {<<"camellia-128-ofb">>, <<"camellia-128-ofb">>, 766, ofb, 16, 16, 1},
     {<<"camellia-192-cbc">>, <<"camellia-192-cbc">>, 752, cbc, 24, 16, 16},
     {<<"camellia-192-cfb">>, <<"camellia-192-cfb">>, 758, cfb, 24, 16, 1},
     {<<"camellia-192-cfb1">>, <<"camellia-192-cfb1">>, 761, cfb, 24, 16, 1},
     {<<"camellia-192-cfb8">>, <<"camellia-192-cfb8">>, 764, cfb, 24, 16, 1},
     {<<"camellia-192-ctr">>, <<"camellia-192-ctr">>, 967, ctr, 24, 16, 1},
     {<<"camellia-192-ecb">>, <<"camellia-192-ecb">>, 755, ecb, 24, 0, 16},
     {<<"camellia-192-ofb">>, <<"camellia-192-ofb">>, 767, ofb, 24, 16, 1},
     {<<"camellia-256-cbc">>, <<"camellia-256-cbc">>, 753, cbc, 32, 16, 16},
     {<<"camellia-256-cfb">>, <<"camellia-256-cfb">>, 759, cfb, 32, 16, 1},
     {<<"camellia-256-cfb1">>, <<"camellia-256-cfb1">>, 762, cfb, 32, 16, 1},
     {<<"camellia-256-cfb8">>, <<"camellia-256-cfb8">>, 765, cfb, 32, 16, 1},
     {<<"camellia-256-ctr">>, <<"camellia-256-ctr">>, 971, ctr, 32, 16, 1},
     {<<"camellia-256-ecb">>, <<"camellia-256-ecb">>, 756, ecb, 32, 0, 16},
     {<<"camellia-256-ofb">>, <<"camellia-256-ofb">>, 768, ofb, 32, 16, 1},
     {<<"camellia128">>, <<"camellia-128-cbc">>, 751, cbc, 16, 16, 16},
     {<<"camellia192">>, <<"camellia-192-cbc">>, 752, cbc, 24, 16, 16},
     {<<"camellia256">>, <<"camellia-256-cbc">>, 753, cbc, 32, 16, 16},
     {<<"chacha20">>, <<"chacha20">>, 1019, stream, 32, 16, 0},
     {<<"chacha20-poly1305">>, <<"chacha20-poly1305">>, 1018, stream, 32, 12, 0},
     {<<"des-ede">>, <<"des-ede">>, 32, ecb, 16, 0, 8},
     {<<"des-ede-cbc">>, <<"des-ede-cbc">>, 43, cbc, 16, 8, 8},
     {<<"des-ede-cfb">>, <<"des-ede-cfb">>, 60, cfb, 16, 8, 1},
     {<<"des-ede-ecb">>, <<"des-ede">>, 32, ecb, 16, 0, 8},
     {<<"des-ede-ofb">>, <<"des-ede-ofb">>, 62, ofb, 16, 8, 1},
     {<<"des-ede3">>, <<"des-ede3">>, 33, ecb, 24, 0, 8},
     {<<"des-ede3-cbc">>, <<"des-ede3-cbc">>, 44, cbc, 24, 8, 8},
     {<<"des-ede3-cfb">>, <<"des-ede3-cfb">>, 61, cfb, 24, 8, 1},
     {<<"des-ede3-cfb1">>, <<"des-ede3-cfb1">>, 658, cfb, 24, 8, 1},
     {<<"des-ede3-cfb8">>, <<"des-ede3-cfb8">>, 659, cfb, 24, 8, 1},
     {<<"des-ede3-ecb">>, <<"des-ede3">>, 33, ecb, 24, 0, 8},
     {<<"des-ede3-ofb">>, <<"des-ede3-ofb">>, 63, ofb, 24, 8, 1},
     {<<"des3">>, <<"des-ede3-cbc">>, 44, cbc, 24, 8, 8},
     {<<"des3-wrap">>, <<"id-smime-alg-cms3deswrap">>, 246, wrap, 24, 0, 8},
     {<<"id-aes128-CCM">>, <<"id-aes128-ccm">>, 896, ccm, 16, 12, 1},
     {<<"id-aes128-GCM">>, <<"id-aes128-gcm">>, 895, gcm, 16, 12, 1},
     {<<"id-aes128-wrap">>, <<"id-aes128-wrap">>, 788, wrap, 16, 8, 8},
     {<<"id-aes128-wrap-pad">>, <<"id-aes128-wrap-pad">>, 897, wrap, 16, 4, 8},
     {<<"id-aes192-CCM">>, <<"id-aes192-ccm">>, 899, ccm, 24, 12, 1},
     {<<"id-aes192-GCM">>, <<"id-aes192-gcm">>, 898, gcm, 24, 12, 1},
     {<<"id-aes192-wrap">>, <<"id-aes192-wrap">>, 789, wrap, 24, 8, 8},
     {<<"id-aes192-wrap-pad">>, <<"id-aes192-wrap-pad">>, 900, wrap, 24, 4, 8},
     {<<"id-aes256-CCM">>, <<"id-aes256-ccm">>, 902, ccm, 32, 12, 1},
     {<<"id-aes256-GCM">>, <<"id-aes256-gcm">>, 901, gcm, 32, 12, 1},
     {<<"id-aes256-wrap">>, <<"id-aes256-wrap">>, 790, wrap, 32, 8, 8},
     {<<"id-aes256-wrap-pad">>, <<"id-aes256-wrap-pad">>, 903, wrap, 32, 4, 8},
     {<<"id-smime-alg-CMS3DESwrap">>, <<"id-smime-alg-cms3deswrap">>, 246, wrap, 24, 0, 8},
     {<<"sm4">>, <<"sm4-cbc">>, 1134, cbc, 16, 16, 16},
     {<<"sm4-cbc">>, <<"sm4-cbc">>, 1134, cbc, 16, 16, 16},
     {<<"sm4-cfb">>, <<"sm4-cfb">>, 1137, cfb, 16, 16, 1},
     {<<"sm4-ctr">>, <<"sm4-ctr">>, 1139, ctr, 16, 16, 1},
     {<<"sm4-ecb">>, <<"sm4-ecb">>, 1133, ecb, 16, 0, 16},
     {<<"sm4-ofb">>, <<"sm4-ofb">>, 1135, ofb, 16, 16, 1}
    ].

-type cipher() :: #{name := binary(), nid := integer(), mode := atom(), key := non_neg_integer(),
                    iv := non_neg_integer(), block := non_neg_integer(), impl := term()}.

%% The cipher of a name or an alias, in any case (EVP_get_cipherbyname).
-spec lookup(binary()) -> {ok, cipher()} | error.
lookup(Name) ->
    Lower = string:lowercase(Name),
    case lists:keyfind(Lower, 1, [{string:lowercase(N), R} || {N, _, _, _, _, _, _} = R <- table()]) of
        {_, Row} -> {ok, cipher(Row)};
        false ->
            case lists:keyfind(Lower, 2, table()) of
                false -> error;
                Row -> {ok, cipher(Row)}
            end
    end.

lookup_nid(Nid) ->
    case lists:keyfind(Nid, 3, table()) of
        false -> error;
        Row -> {ok, cipher(Row)}
    end.

cipher({_, Canonical, Nid, Mode, Key, IV, Block}) ->
    #{name => Canonical, nid => Nid, mode => Mode, key => Key, iv => IV, block => Block,
      impl => impl(Canonical, Mode, Key)}.

%% The cipher of Name when OTP's crypto runs it as one stream: its
%% canonical name, OTP's name, and its key, IV, and block sizes.
-spec otp_cipher(binary()) -> {ok, map()} | error.
otp_cipher(Name) ->
    case lookup(Name) of
        {ok, #{name := Canonical, impl := {otp, Otp}, key := Key, iv := IV, block := Block}} ->
            {ok, #{name => Canonical, otp => Otp, key => Key, iv => IV, block => Block}};
        _ -> error
    end.

%% Whether Name names a cipher (for the cipher of an encrypted key).
-spec exists(binary()) -> boolean().
exists(Name) -> lookup(Name) =/= error.

%% How OTP's crypto, or buoy_crypto_modes, runs a cipher.
impl(<<"aes-", _:3/binary, "-", Suffix/binary>>, _, Key) -> aes_impl(Suffix, Key * 8);
impl(<<"id-aes", _:3/binary, "-wrap">>, _, Key) -> {wrap, aes_ecb(Key * 8)};
impl(<<"id-aes", _:3/binary, "-wrap-pad">>, _, Key) -> {wrap_pad, aes_ecb(Key * 8)};
impl(<<"id-aes", _:3/binary, "-", Suffix/binary>>, _, Key) -> aes_impl(Suffix, Key * 8);
impl(<<"id-smime-alg-cms3deswrap">>, _, _) -> des3_wrap;
impl(<<"des-ede3-cbc">>, _, _) -> {otp, des_ede3_cbc};
impl(<<"des-ede3-cfb">>, _, _) -> {otp, des_ede3_cfb};
impl(<<"des-ede3">>, _, _) -> {ecb, des_ede3};
impl(<<"des-ede-cbc">>, _, _) -> {two_key, {otp, des_ede3_cbc}};
impl(<<"des-ede-cfb">>, _, _) -> {two_key, {otp, des_ede3_cfb}};
impl(<<"des-ede">>, _, _) -> {two_key, {ecb, des_ede3}};
impl(<<"chacha20">>, _, _) -> {otp, chacha20};
impl(<<"chacha20-poly1305">>, _, _) -> chacha20_poly1305;
impl(<<"sm4-cbc">>, _, _) -> {otp, sm4_cbc};
impl(<<"sm4-ecb">>, _, _) -> {otp, sm4_ecb};
impl(<<"sm4-cfb">>, _, _) -> {otp, sm4_cfb};
impl(<<"sm4-ofb">>, _, _) -> {otp, sm4_ofb};
impl(<<"sm4-ctr">>, _, _) -> {otp, sm4_ctr};
impl(_, _, _) -> unsupported.

aes_impl(<<"cfb">>, Bits) -> {otp, aes(Bits, <<"cfb128">>)};
aes_impl(<<"cfb8">>, Bits) -> {otp, aes(Bits, <<"cfb8">>)};
aes_impl(<<"gcm">>, Bits) -> {gcm, aes_ecb(Bits), aes(Bits, <<"gcm">>)};
aes_impl(<<"ccm">>, Bits) -> {ccm, aes(Bits, <<"ccm">>)};
aes_impl(<<"ocb">>, Bits) -> {ocb, aes_ecb(Bits)};
aes_impl(Mode, Bits) when Mode =:= <<"cbc">>; Mode =:= <<"ecb">>; Mode =:= <<"ctr">>; Mode =:= <<"ofb">> ->
    {otp, aes(Bits, Mode)};
aes_impl(_, _) -> unsupported.

aes(Bits, Mode) -> binary_to_atom(iolist_to_binary(["aes_", integer_to_binary(Bits), "_", Mode])).

aes_ecb(Bits) -> aes(Bits, <<"ecb">>).

%%% CipherBase

%% new CipherBase(isEncrypt, cipher, key, iv, authTagLength)
init(This, Args) ->
    [IsEncrypt, NameValue, KeyValue, IVValue, TagValue | _] = Args ++ lists:duplicate(5, undefined),
    Name = buoy_crypto:string(NameValue),
    Cipher = case lookup(Name) of
        {ok, C} -> C;
        error -> buoy_crypto:fail_code(<<"ERR_CRYPTO_UNKNOWN_CIPHER">>)
    end,
    Key = buoy_crypto_keys:secret_bytes(KeyValue),
    IV = case IVValue of
        null -> <<>>;
        _ -> buoy_crypto:bytes(IVValue)
    end,
    TagLen = case TagValue of
        -1 -> ?NO_TAG;
        N -> N
    end,
    State = init_iv(Name, Cipher, Key, IV, TagLen, IsEncrypt =:= true),
    buoy_crypto:put_state(This, {cipher, State}).

%% InitIv and CommonInit: check the IV and the key, and the tag length of
%% an authenticated mode.
init_iv(Name, #{mode := Mode, iv := ExpectedIV, impl := Impl} = Cipher, Key, IV, TagLen, Encrypt) ->
    HasIV = IV =/= <<>>,
    Aead = is_aead(Cipher),
    (not HasIV andalso ExpectedIV =/= 0) andalso invalid_iv(),
    (not Aead andalso HasIV andalso byte_size(IV) =/= ExpectedIV) andalso invalid_iv(),
    (Impl =:= chacha20_poly1305 andalso byte_size(IV) > 12) andalso invalid_iv(),
    Impl =:= unsupported andalso buoy_crypto:fail({openssl, unsupported}),
    State0 = #{cipher => Cipher, encrypt => Encrypt, key => Key, iv => IV, live => true, padding => true,
               tag_len => ?NO_TAG, tag => undefined, tag_state => unknown, aad => [], started => false,
               auth_failed => false, plaintext_len => undefined, total => 0, engine => undefined},
    State = case Aead of
        true -> init_authenticated(Name, Mode, Impl, IV, TagLen, State0);
        false -> State0
    end,
    byte_size(Key) =:= key_length(Cipher) orelse buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_KEYLEN">>),
    State.

key_length(#{impl := {two_key, _}}) -> 16;
key_length(#{key := Key}) -> Key.

invalid_iv() -> buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_IV">>).

is_aead(#{impl := Impl}) ->
    Impl =:= chacha20_poly1305 orelse (is_tuple(Impl) andalso lists:member(element(1, Impl), [gcm, ccm, ocb])).

init_authenticated(Name, Mode, Impl, IV, TagLen, State) ->
    valid_iv_length(Mode, Impl, byte_size(IV)) orelse invalid_iv(),
    case Mode of
        gcm ->
            case TagLen of
                ?NO_TAG -> State;
                _ ->
                    is_gcm_tag_length(TagLen) orelse invalid_tag_length(TagLen),
                    State#{tag_len := TagLen}
            end;
        _ ->
            Len = case {TagLen, Impl} of
                {?NO_TAG, chacha20_poly1305} -> 16;
                {?NO_TAG, _} ->
                    buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_AUTH_TAG">>, <<"authTagLength required for ", Name/binary>>);
                _ -> TagLen
            end,
            valid_tag_length(Mode, Impl, Len) orelse invalid_tag_length(Len),
            State#{tag_len := Len}
    end.

valid_iv_length(ccm, _, L) -> L >= 7 andalso L =< 13;
valid_iv_length(ocb, _, L) -> L >= 1 andalso L =< 15;
valid_iv_length(_, chacha20_poly1305, L) -> L >= 1 andalso L =< 12;
valid_iv_length(_, _, L) -> L >= 1.

is_gcm_tag_length(L) -> L =:= 4 orelse L =:= 8 orelse (L >= 12 andalso L =< 16).

valid_tag_length(ccm, _, L) -> L >= 4 andalso L =< 16 andalso L rem 2 =:= 0;
valid_tag_length(_, _, L) -> L >= 1 andalso L =< 16.

invalid_tag_length(L) ->
    buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_AUTH_TAG">>,
                          <<"Invalid authentication tag length: ", (integer_to_binary(L))/binary>>).

state(This) -> buoy_crypto:state(This, cipher).

save(This, State) -> buoy_crypto:put_state(This, {cipher, State}).

%% update(data, inputEncoding)
update(This, Args) ->
    Data = buoy_crypto:data(buoy_node:arg(1, Args), buoy_node:arg(2, Args)),
    State = state(This),
    case State of
        #{live := false} -> buoy_crypto:throw_error(<<"Trying to add data in unsupported state">>);
        _ -> ok
    end,
    {Out, State1} = cipher_update(State, Data),
    save(This, State1#{started := true, total := maps:get(total, State1) + byte_size(Data)}),
    buoy_crypto:buffer(Out).

cipher_update(#{cipher := #{mode := ccm}} = S, Data) -> ccm_update(S, Data);
cipher_update(#{cipher := #{impl := {gcm, Ecb, _}}, key := Key, iv := IV} = S, Data) ->
    {Counter, Pending, Acc} = case maps:get(engine, S) of
        undefined -> {gcm_first_counter(Ecb, Key, IV), <<>>, []};
        {gcm, C, P, A} -> {C, P, A}
    end,
    {Out, Counter1, Pending1} = buoy_crypto_modes:gcm_stream({Ecb, Key}, Counter, Pending, Data),
    {Out, S#{engine := {gcm, Counter1, Pending1, [Acc, Data]}}};
cipher_update(#{cipher := #{impl := chacha20_poly1305}, key := Key, iv := IV} = S, Data) ->
    {Ref, Acc} = case maps:get(engine, S) of
        undefined -> {crypto:crypto_init(chacha20, Key, <<1:32/little, (chacha_nonce(IV))/binary>>, true), []};
        {chacha, R, A} -> {R, A}
    end,
    {crypto:crypto_update(Ref, Data), S#{engine := {chacha, Ref, [Acc, Data]}}};
cipher_update(#{cipher := #{impl := {ocb, _}}} = S, Data) ->
    Acc = case maps:get(engine, S) of
        undefined -> [];
        {ocb, A} -> A
    end,
    {<<>>, S#{engine := {ocb, [Acc, Data]}}};
cipher_update(#{cipher := #{impl := Impl}} = S, Data) when Impl =:= des3_wrap; element(1, Impl) =:= wrap;
                                                           element(1, Impl) =:= wrap_pad ->
    case maps:get(engine, S) of
        undefined -> {wrap(S, Data), S#{engine := wrapped}};
        wrapped -> {<<>>, S}
    end;
cipher_update(S, Data) ->
    case otp_state(S) of
        {{ecb, _, _} = Ecb, S1} ->
            {Out, Ecb1} = ecb_update(Ecb, Data, maps:get(encrypt, S1), maps:get(padding, S1)),
            {Out, S1#{engine := {otp, Ecb1}}};
        {Ref, S1} -> {crypto:crypto_update(Ref, Data), S1}
    end.

%% ECB of Triple-DES as EVP_CipherUpdate runs it: whole blocks out, and a
%% decryption with padding holds the last block back for final().
ecb_update({ecb, Key, Buffer}, Data, Encrypt, Padding) ->
    All = <<Buffer/binary, Data/binary>>,
    Whole = byte_size(All) div 8 * 8,
    Keep = case not Encrypt andalso Padding andalso Whole > 0 andalso Whole =:= byte_size(All) of
        true -> 8;
        false -> byte_size(All) - Whole
    end,
    Take = byte_size(All) - Keep,
    <<Now:Take/binary, Rest/binary>> = All,
    {buoy_crypto_modes:ecb(des_ede3, Key, Now, Encrypt), {ecb, Key, Rest}}.

ecb_final({ecb, Key, Buffer}, true, true) ->
    N = 8 - byte_size(Buffer),
    buoy_crypto_modes:ecb(des_ede3, Key, <<Buffer/binary, (binary:copy(<<N>>, N))/binary>>, true);
ecb_final({ecb, _, <<>>}, _, false) -> <<>>;
ecb_final({ecb, Key, <<_:8/binary>> = Buffer}, false, true) ->
    Plain = buoy_crypto_modes:ecb(des_ede3, Key, Buffer, false),
    N = binary:last(Plain),
    case N >= 1 andalso N =< 8 andalso binary:part(Plain, 8 - N, N) =:= binary:copy(<<N>>, N) of
        true -> binary:part(Plain, 0, 8 - N);
        false -> error(final)
    end;
ecb_final(_, _, _) -> error(final).

gcm_first_counter(Ecb, Key, IV) ->
    J0 = buoy_crypto_modes:gcm_j0(Ecb, Key, IV),
    (J0 band (bnot 16#FFFFFFFF)) bor ((J0 + 1) band 16#FFFFFFFF).

chacha_nonce(IV) -> <<0:((12 - byte_size(IV)) * 8), IV/binary>>.

%% The OTP stream of a cipher of OTP's crypto, made on first use, as the
%% padding may change until then.
otp_state(#{engine := {otp, Ref}} = S) -> {Ref, S};
otp_state(#{cipher := #{impl := Impl}, key := Key, iv := IV, encrypt := Encrypt, padding := Padding} = S) ->
    {Otp, K} = case Impl of
        {two_key, Inner} -> {Inner, <<Key/binary, (binary:part(Key, 0, 8))/binary>>};
        _ -> {Impl, Key}
    end,
    Pad = case Padding of
        true -> pkcs_padding;
        false -> none
    end,
    Ref = case Otp of
        {otp, Atom} ->
            Opts = [{encrypt, Encrypt}] ++ [{padding, Pad} || block_size(Atom) > 1],
            case IV of
                <<>> -> crypto:crypto_init(Atom, K, Opts);
                _ -> crypto:crypto_init(Atom, K, IV, Opts)
            end;
        {ecb, des_ede3} -> {ecb, K, <<>>}
    end,
    {Ref, S#{engine := {otp, Ref}}}.

block_size(Atom) ->
    case crypto:cipher_info(Atom) of
        #{block_size := B} -> B;
        _ -> 1
    end.

%% A wrap mode wraps or unwraps all its data in one update.
wrap(#{cipher := #{impl := des3_wrap}, key := Key, encrypt := true}, Data) ->
    buoy_crypto_modes:des3_wrap(Key, Data);
wrap(#{cipher := #{impl := des3_wrap}, key := Key}, Data) ->
    unwrapped(buoy_crypto_modes:des3_unwrap(Key, Data));
wrap(#{cipher := #{impl := {wrap, Ecb}}, key := Key, iv := IV, encrypt := Encrypt}, Data) ->
    Initial = default(IV, <<16#A6A6A6A6A6A6A6A6:64>>),
    (byte_size(Data) rem 8 =:= 0 andalso byte_size(Data) >= 16 + 8 * bool(not Encrypt)) orelse
        buoy_crypto:throw_error(<<"Trying to add data in unsupported state">>),
    case Encrypt of
        true -> buoy_crypto_modes:aes_wrap(Ecb, Key, Initial, Data);
        false -> unwrapped(buoy_crypto_modes:aes_unwrap(Ecb, Key, Initial, Data))
    end;
wrap(#{cipher := #{impl := {wrap_pad, Ecb}}, key := Key, iv := IV, encrypt := Encrypt}, Data) ->
    Initial = default(IV, <<16#A65959A6:32>>),
    case Encrypt of
        true -> buoy_crypto_modes:aes_wrap_pad(Ecb, Key, Initial, Data);
        false -> unwrapped(buoy_crypto_modes:aes_unwrap_pad(Ecb, Key, Initial, Data))
    end.

bool(true) -> 1;
bool(false) -> 0.

default(<<>>, Default) -> Default;
default(IV, _) -> IV.

unwrapped({ok, Plain}) -> Plain;
unwrapped(error) -> buoy_crypto:throw_error(<<"Trying to add data in unsupported state">>).

%% CCM takes its data in one update, and its length must match the length
%% that setAAD announced.
ccm_update(#{plaintext_len := Announced, iv := IV} = S, Data) ->
    (Announced =:= undefined orelse Announced =:= byte_size(Data)) orelse
        buoy_crypto:throw_error(<<"Trying to add data in unsupported state">>),
    byte_size(Data) =< ccm_max(byte_size(IV)) orelse buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_MESSAGELEN">>),
    maps:get(engine, S) =:= undefined orelse buoy_crypto:throw_error(<<"Trying to add data in unsupported state">>),
    #{cipher := #{impl := {ccm, Atom}}, key := Key, aad := AAD, tag_len := TagLen} = S,
    case S of
        #{encrypt := true} ->
            {Out, Tag} = crypto:crypto_one_time_aead(Atom, Key, IV, Data, iolist_to_binary(AAD), TagLen, true),
            {Out, S#{engine := done, tag := Tag}};
        #{tag := undefined} ->
            {<<>>, S#{engine := done, auth_failed := true}};
        #{tag := Tag} ->
            case crypto:crypto_one_time_aead(Atom, Key, IV, Data, iolist_to_binary(AAD), Tag, false) of
                error -> {<<>>, S#{engine := done, auth_failed := true}};
                Out -> {Out, S#{engine := done}}
            end
    end.

ccm_max(12) -> 16777215;
ccm_max(13) -> 65535;
ccm_max(_) -> 2147483647.

%% final()
final(This, _) ->
    State = state(This),
    maps:get(live, State) orelse buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_STATE">>),
    Aead = is_aead(maps:get(cipher, State)),
    case cipher_final(State) of
        {ok, Out, State1} ->
            save(This, State1#{live := false}),
            buoy_crypto:buffer(Out);
        {error, Reason, State1} ->
            save(This, State1#{live := false}),
            case {Reason, Aead} of
                {none, true} -> buoy_crypto:throw_error(<<"Unsupported state or unable to authenticate data">>);
                {none, false} -> buoy_crypto:throw_error(<<"Unsupported state">>);
                {Openssl, _} -> buoy_crypto:throw_openssl(Openssl)
            end
    end.

cipher_final(#{cipher := #{mode := ccm}, encrypt := false, auth_failed := Failed} = S) ->
    case Failed of
        true -> {error, none, S};
        false -> {ok, <<>>, S}
    end;
cipher_final(#{cipher := #{mode := ccm}} = S) ->
    case maps:get(engine, S) of
        undefined -> {error, tag_not_set, S};
        _ -> {ok, <<>>, S#{tag_state := computed}}
    end;
cipher_final(#{cipher := #{impl := {gcm, Ecb, Atom}}, key := Key, iv := IV, aad := AAD} = S) ->
    Data = case maps:get(engine, S) of
        undefined -> <<>>;
        {gcm, _, _, Acc} -> iolist_to_binary(Acc)
    end,
    _ = Ecb,
    aead_final(S, fun(Encrypt, TagOrLen) ->
        crypto:crypto_one_time_aead(Atom, Key, IV, Data, iolist_to_binary(AAD), TagOrLen, Encrypt)
    end, 16, <<>>);
cipher_final(#{cipher := #{impl := chacha20_poly1305}, key := Key, iv := IV, aad := AAD} = S) ->
    Data = case maps:get(engine, S) of
        undefined -> <<>>;
        {chacha, _, Acc} -> iolist_to_binary(Acc)
    end,
    aead_final(S, fun(Encrypt, TagOrLen) ->
        crypto:crypto_one_time_aead(chacha20_poly1305, Key, chacha_nonce(IV), Data, iolist_to_binary(AAD),
                                    TagOrLen, Encrypt)
    end, 16, <<>>);
cipher_final(#{cipher := #{impl := {ocb, Ecb}}, key := Key, iv := IV, aad := AAD, encrypt := Encrypt,
               tag_len := TagLen} = S) ->
    Data = case maps:get(engine, S) of
        undefined -> <<>>;
        {ocb, Acc} -> iolist_to_binary(Acc)
    end,
    Direction = case Encrypt of
        true -> encrypt;
        false -> decrypt
    end,
    {Out, Tag} = buoy_crypto_modes:ocb(Ecb, Key, IV, iolist_to_binary(AAD), Data, {Direction, TagLen}),
    case {Encrypt, maps:get(tag, S)} of
        {true, _} -> {ok, Out, S#{tag := Tag, tag_state := computed}};
        {false, Tag} -> {ok, Out, S};
        {false, _} -> {error, none, S}
    end;
cipher_final(#{cipher := #{impl := Impl}} = S) when Impl =:= des3_wrap; element(1, Impl) =:= wrap;
                                                    element(1, Impl) =:= wrap_pad ->
    {ok, <<>>, S};
cipher_final(S) ->
    {Ref, S1} = otp_state(S),
    try final_bytes(Ref, S1) of
        Out -> {ok, Out, S1}
    catch
        error:{error, _, _} -> {error, final_error(S1), S1};
        error:final -> {error, final_error(S1), S1}
    end.

final_bytes({ecb, _, _} = Ecb, #{encrypt := Encrypt, padding := Padding}) -> ecb_final(Ecb, Encrypt, Padding);
final_bytes(Ref, _) -> crypto:crypto_final(Ref).

%% The OpenSSL error of a failed EVP_CipherFinal_ex.
final_error(#{encrypt := true}) -> wrong_final_block_length;
final_error(#{total := Total, cipher := #{block := Block}}) when Block > 1, Total rem Block =/= 0; Total =:= 0 ->
    wrong_final_block_length;
final_error(_) -> bad_decrypt.

%% The final step of GCM and ChaCha20-Poly1305: the tag of an encryption,
%% or the check of the tag of a decryption.
aead_final(#{encrypt := true, tag_len := TagLen} = S, Run, Default, Out) ->
    Len = case TagLen of
        ?NO_TAG -> Default;
        _ -> TagLen
    end,
    {_, Tag} = Run(true, Len),
    {ok, Out, S#{tag := Tag, tag_len := Len, tag_state := computed}};
aead_final(#{tag := undefined} = S, _, _, _) ->
    {error, none, S};
aead_final(#{tag := Tag} = S, Run, _, Out) ->
    case Run(false, Tag) of
        error -> {error, none, S};
        _ -> {ok, Out, S}
    end.

set_auto_padding(This, Args) ->
    State = state(This),
    case State of
        #{live := false} -> false;
        _ ->
            save(This, State#{padding := Args =:= [] orelse hd(Args) =:= true}),
            true
    end.

%% getAuthTag(): the tag after final() of an encryption.
get_auth_tag(This, _) ->
    case state(This) of
        #{live := false, encrypt := true, tag_state := computed, tag := Tag} -> buoy_crypto:buffer(Tag);
        _ -> undefined
    end.

%% setAuthTag(tag)
set_auth_tag(This, Args) ->
    State = state(This),
    #{cipher := Cipher, live := Live, encrypt := Encrypt, tag_state := TagState, tag_len := TagLen} = State,
    case Live andalso is_aead(Cipher) andalso not Encrypt andalso TagState =:= unknown of
        false -> false;
        true ->
            Tag = buoy_crypto:bytes(buoy_node:arg(1, Args)),
            Len = byte_size(Tag),
            Valid = case Cipher of
                #{mode := gcm} -> (TagLen =:= ?NO_TAG orelse TagLen =:= Len) andalso is_gcm_tag_length(Len);
                _ -> TagLen =:= Len
            end,
            Valid orelse invalid_tag_length(Len),
            (maps:get(mode, Cipher) =:= gcm andalso TagLen =:= ?NO_TAG andalso Len =/= 16) andalso
                gcm_short_tag_warning(),
            save(This, State#{tag := Tag, tag_len := Len, tag_state := set}),
            true
    end.

%% ProcessEmitDeprecationWarning: process.emitWarning(message, type, code).
gcm_short_tag_warning() ->
    Process = buoy_node_loop:process(),
    buoy_heap:call(buoy_heap:get(Process, <<"emitWarning">>), Process, [
        <<"Using AES-GCM authentication tags of less than 128 bits without specifying the authTagLength option "
          "when initializing decryption is deprecated.">>, <<"DeprecationWarning">>, <<"DEP0182">>]).

%% setAAD(aad, plaintextLength)
set_aad(This, Args) ->
    State = state(This),
    #{cipher := Cipher, live := Live, started := Started} = State,
    AAD = buoy_crypto:bytes(buoy_node:arg(1, Args)),
    case Live andalso is_aead(Cipher) of
        false -> false;
        true when Started -> false;
        true ->
            PlainLen = buoy_node:arg(2, Args),
            State1 = case Cipher of
                #{mode := ccm} ->
                    (is_integer(PlainLen) andalso PlainLen >= 0) orelse
                        buoy_crypto:fail({code, 'TypeError', <<"ERR_MISSING_ARGS">>,
                                          <<"options.plaintextLength required for CCM mode with AAD">>}),
                    PlainLen =< ccm_max(byte_size(maps:get(iv, State))) orelse
                        buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_MESSAGELEN">>),
                    State#{plaintext_len := PlainLen};
                _ -> State
            end,
            save(This, State1#{aad := [maps:get(aad, State1), AAD]}),
            true
    end.

%%% getCipherInfo

%% getCipherInfo(nameOrNid, keyLength, ivLength)
cipher_info(_, Args) ->
    [Id, KeyLen, IVLen | _] = Args ++ [undefined, undefined, undefined],
    Found = case buoy_crypto:is_string(Id) of
        true -> lookup(buoy_crypto:string(Id));
        false -> lookup_nid(Id)
    end,
    case Found of
        error -> undefined;
        {ok, Cipher} -> cipher_info(Cipher, KeyLen, IVLen)
    end.

cipher_info(#{name := Name, nid := Nid, mode := Mode, key := Key, iv := IV, block := Block} = Cipher, KeyLen, IVLen) ->
    KeyOk = KeyLen =:= undefined orelse KeyLen =:= key_length(Cipher),
    IVOk = IVLen =:= undefined orelse case Mode of
        ccm -> IVLen >= 7 andalso IVLen =< 13;
        gcm -> true;
        ocb -> IVLen >= 1 andalso IVLen =< 15;
        _ -> IVLen =:= IV
    end,
    case KeyOk andalso IVOk of
        false -> undefined;
        true ->
            IVOut = case IVLen of
                undefined -> IV;
                _ -> IVLen
            end,
            KeyOut = case KeyLen of
                undefined -> Key;
                _ -> KeyLen
            end,
            Fields = [{<<"mode">>, atom_to_binary(Mode)}, {<<"name">>, Name}, {<<"nid">>, Nid},
                      {<<"keyLength">>, KeyOut}] ++
                     [{<<"blockSize">>, Block} || Block =/= 0] ++
                     [{<<"ivLength">>, IVOut} || IVOut =/= 0],
            buoy_node:object(null, Fields)
    end.

%%% RSA

%% publicEncrypt and the others: (key, format, type, passphrase, buffer,
%% padding, oaepHash, oaepLabel)
public_key_cipher(Which, Operation, Args) ->
    {{_, K}, Rest} = buoy_crypto_keys:from_args(Args, Which),
    [Buffer, Padding, OaepHash, OaepLabel | _] = Rest ++ [undefined, undefined, undefined, undefined],
    Md = case buoy_crypto:is_string(OaepHash) of
        true ->
            case buoy_crypto_hash:digest(OaepHash) of
                {ok, #{name := M}} -> M;
                error -> buoy_crypto:fail_code(<<"ERR_OSSL_EVP_INVALID_DIGEST">>)
            end;
        false -> sha
    end,
    Label = case OaepLabel of
        undefined -> <<>>;
        _ -> buoy_crypto:bytes(OaepLabel)
    end,
    Out = rsa_crypt(K, Operation, buoy_crypto:bytes(Buffer), buoy_crypto:to_uint32(Padding), {Md, Label}),
    buoy_crypto:buffer(Out).

%% The RSA operation of ncrypto's Cipher::encrypt, decrypt, sign, and
%% recover on K, with the padding Padding and OAEP's digest and label.
-spec rsa_crypt(map(), encrypt | decrypt | sign | recover, binary(), integer(), {atom(), binary()}) -> binary().
rsa_crypt(#{kind := Kind} = K, Operation, Data, Padding, {Md, Label}) ->
    Kind =:= rsa_pss andalso buoy_crypto:fail({openssl, prov_operation_not_supported_for_this_keytype}),
    Kind =:= rsa orelse buoy_crypto:fail({openssl, operation_not_supported_for_this_keytype}),
    Opts = case Padding of
        ?RSA_PKCS1_PADDING -> [{rsa_padding, rsa_pkcs1_padding}];
        ?RSA_NO_PADDING -> [{rsa_padding, rsa_no_padding}];
        ?RSA_PKCS1_OAEP_PADDING ->
            [{rsa_padding, rsa_pkcs1_oaep_padding}, {rsa_oaep_md, Md}, {rsa_mgf1_md, Md}] ++
                [{rsa_oaep_label, Label} || Label =/= <<>>];
        ?RSA_X931_PADDING -> [{rsa_padding, rsa_x931_padding}];
        _ -> buoy_crypto:fail({openssl, illegal_padding})
    end,
    (Padding =:= ?RSA_PKCS1_OAEP_PADDING andalso (Operation =:= sign orelse Operation =:= recover)) andalso
        buoy_crypto:fail({openssl, illegal_padding}),
    Public = [maps:get(e, K), maps:get(n, K)],
    try
        case Operation of
            encrypt -> crypto:public_encrypt(rsa, Data, Public, Opts);
            recover -> crypto:public_decrypt(rsa, Data, Public, Opts);
            decrypt -> crypto:private_decrypt(rsa, Data, private_rsa(K), Opts);
            sign -> crypto:private_encrypt(rsa, Data, private_rsa(K), Opts)
        end
    catch
        error:{error, _, Text} -> rsa_failure(Operation, Padding, Data, K, Text);
        error:{notsup, _, _} -> buoy_crypto:fail({openssl, illegal_padding});
        error:{badarg, _, Text} -> rsa_failure(Operation, Padding, Data, K, Text)
    end.

private_rsa(#{e := E, n := N, d := D, p := P, q := Q, dp := DP, dq := DQ, qi := QI}) -> [E, N, D, P, Q, DP, DQ, QI];
private_rsa(_) -> buoy_crypto:fail({openssl, operation_not_supported_for_this_keytype}).

rsa_failure(_, ?RSA_PKCS1_OAEP_PADDING, _, _, _) -> buoy_crypto:fail({openssl, oaep_decoding_error});
rsa_failure(Operation, _, Data, #{n := N}, _) when (Operation =:= encrypt orelse Operation =:= sign),
                                                   byte_size(Data) * 8 > 0 ->
    case byte_size(Data) > (bit_length(N) + 7) div 8 - 11 of
        true -> buoy_crypto:fail({openssl, data_too_large_for_key_size});
        false -> buoy_crypto:fail({message, <<"RSA operation failed">>})
    end;
rsa_failure(_, _, _, _, Text) ->
    buoy_crypto:fail({message, unicode:characters_to_binary(Text)}).

bit_length(0) -> 0;
bit_length(N) -> bit_length(N bsr 1) + 1.

%%% WebCrypto jobs

%% new AESCipherJob(mode, cipherMode, key, data, variant, ...): CTR with
%% (counter, length), CBC with (iv), KW, and GCM and OCB with (iv,
%% tagLength, additionalData).
aes_job([CipherMode, KeyHandle, Data, Variant | Rest]) ->
    Key = buoy_crypto_keys:secret_bytes(KeyHandle),
    In = buoy_crypto:bytes(Data),
    Encrypt = CipherMode =:= ?ENCRYPT,
    {Mode, Bits} = aes_variant(Variant),
    Work = case Mode of
        ctr ->
            [CounterV, LengthV | _] = Rest,
            Counter = buoy_crypto:bytes(CounterV),
            (byte_size(Counter) =:= 16 andalso LengthV > 0 andalso LengthV =< 128) orelse
                buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_COUNTER">>),
            fun() -> aes_ctr(Bits, Key, Counter, LengthV, In) end;
        cbc ->
            IV = buoy_crypto:bytes(hd(Rest)),
            fun() -> aes_cbc(Bits, Key, IV, In, Encrypt) end;
        kw ->
            fun() -> aes_kw(Bits, Key, In, Encrypt) end;
        _ ->
            %% lib/internal/crypto/aes.js passes the tag length in bytes.
            [IVV, TagLen, AADV | _] = Rest ++ [undefined, undefined, undefined],
            IV = buoy_crypto:bytes(IVV),
            (is_integer(TagLen) andalso TagLen >= 0 andalso TagLen =< 16) orelse
                buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_TAG_LENGTH">>),
            AAD = case buoy_crypto:is_buffer_source(AADV) of
                true -> buoy_crypto:bytes(AADV);
                false -> <<>>
            end,
            fun() -> aes_aead(Mode, Bits, Key, IV, TagLen, AAD, In, Encrypt) end
    end,
    {fun() -> {ok, Work()} end, fun buoy_crypto:array_buffer/1}.

aes_variant(V) ->
    Modes = {ctr, cbc, gcm, kw, ocb},
    {element(V div 3 + 1, Modes), 128 + (V rem 3) * 64}.

failed() -> buoy_crypto:fail({message, <<"Cipher job failed">>}).

aes_ctr(Bits, Key, Block, Length, In) ->
    Atom = aes(Bits, <<"ctr">>),
    <<Prefix:(128 - Length), Counter:Length>> = Block,
    Blocks = (byte_size(In) + 15) div 16,
    Blocks =< 1 bsl Length orelse failed(),
    Remaining = (1 bsl Length) - Counter,
    case Remaining >= Blocks of
        true -> crypto:crypto_one_time(Atom, Key, Block, In, true);
        false ->
            Split = Remaining * 16,
            <<First:Split/binary, Second/binary>> = In,
            <<(crypto:crypto_one_time(Atom, Key, Block, First, true))/binary,
              (crypto:crypto_one_time(Atom, Key, <<Prefix:(128 - Length), 0:Length>>, Second, true))/binary>>
    end.

aes_cbc(Bits, Key, IV, In, Encrypt) ->
    byte_size(IV) =:= 16 orelse failed(),
    try crypto:crypto_one_time(aes(Bits, <<"cbc">>), Key, IV, In, [{encrypt, Encrypt}, {padding, pkcs_padding}])
    catch
        error:_ -> failed()
    end.

aes_kw(Bits, Key, In, true) ->
    (byte_size(In) rem 8 =:= 0 andalso byte_size(In) >= 16) orelse failed(),
    buoy_crypto_modes:aes_wrap(aes_ecb(Bits), Key, <<16#A6A6A6A6A6A6A6A6:64>>, In);
aes_kw(Bits, Key, In, false) ->
    (byte_size(In) rem 8 =:= 0 andalso byte_size(In) >= 24) orelse failed(),
    case buoy_crypto_modes:aes_unwrap(aes_ecb(Bits), Key, <<16#A6A6A6A6A6A6A6A6:64>>, In) of
        {ok, Plain} -> Plain;
        error -> failed()
    end.

aes_aead(Mode, Bits, Key, IV, TagLen, AAD, In, Encrypt) ->
    IV =/= <<>> orelse failed(),
    case Encrypt of
        true ->
            {Out, Tag} = aead_encrypt(Mode, Bits, Key, IV, TagLen, AAD, In),
            <<Out/binary, Tag/binary>>;
        false ->
            byte_size(In) >= TagLen orelse failed(),
            Size = byte_size(In) - TagLen,
            <<Ct:Size/binary, Tag/binary>> = In,
            aead_decrypt(Mode, Bits, Key, IV, Tag, AAD, Ct)
    end.

aead_encrypt(gcm, Bits, Key, IV, TagLen, AAD, In) ->
    is_gcm_tag_length(TagLen) orelse failed(),
    crypto:crypto_one_time_aead(aes(Bits, <<"gcm">>), Key, IV, In, AAD, TagLen, true);
aead_encrypt(ocb, Bits, Key, IV, TagLen, AAD, In) ->
    (byte_size(IV) =< 15 andalso TagLen >= 1 andalso TagLen =< 16) orelse failed(),
    buoy_crypto_modes:ocb(aes_ecb(Bits), Key, IV, AAD, In, {encrypt, TagLen}).

aead_decrypt(gcm, Bits, Key, IV, Tag, AAD, Ct) ->
    is_gcm_tag_length(byte_size(Tag)) orelse failed(),
    case crypto:crypto_one_time_aead(aes(Bits, <<"gcm">>), Key, IV, Ct, AAD, Tag, false) of
        error -> failed();
        Plain -> Plain
    end;
aead_decrypt(ocb, Bits, Key, IV, Tag, AAD, Ct) ->
    (byte_size(IV) =< 15 andalso byte_size(Tag) >= 1) orelse failed(),
    case buoy_crypto_modes:ocb(aes_ecb(Bits), Key, IV, AAD, Ct, {decrypt, byte_size(Tag)}) of
        {Plain, Tag} -> Plain;
        _ -> failed()
    end.

%% new ChaCha20Poly1305CipherJob(mode, cipherMode, key, data, iv, additionalData)
chacha_job([CipherMode, KeyHandle, Data, IVV | Rest]) ->
    Key = buoy_crypto_keys:secret_bytes(KeyHandle),
    In = buoy_crypto:bytes(Data),
    IV = buoy_crypto:bytes(IVV),
    AAD = case Rest of
        [A | _] when A =/= undefined -> buoy_crypto:bytes(A);
        _ -> <<>>
    end,
    Work = case CipherMode =:= ?ENCRYPT of
        true -> fun() ->
            {Out, Tag} = crypto:crypto_one_time_aead(chacha20_poly1305, Key, IV, In, AAD, 16, true),
            <<Out/binary, Tag/binary>>
        end;
        false -> fun() ->
            byte_size(In) >= 16 orelse failed(),
            Size = byte_size(In) - 16,
            <<Ct:Size/binary, Tag:16/binary>> = In,
            case crypto:crypto_one_time_aead(chacha20_poly1305, Key, IV, Ct, AAD, Tag, false) of
                error -> failed();
                Plain -> Plain
            end
        end
    end,
    {fun() -> {ok, Work()} end, fun buoy_crypto:array_buffer/1}.

%% new RSACipherJob(mode, cipherMode, key, data, variant, hash, label)
rsa_job([CipherMode, KeyHandle, Data, _Variant | Rest]) ->
    {_, K} = buoy_crypto_keys:key_data(KeyHandle),
    In = buoy_crypto:bytes(Data),
    [Hash, LabelV | _] = Rest ++ [undefined, undefined],
    Md = case buoy_crypto_hash:digest(Hash) of
        {ok, #{name := M}} -> M;
        error -> buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_DIGEST">>)
    end,
    Label = case buoy_crypto:is_buffer_source(LabelV) of
        true -> buoy_crypto:bytes(LabelV);
        false -> <<>>
    end,
    Operation = case CipherMode =:= ?ENCRYPT of
        true -> encrypt;
        false -> decrypt
    end,
    {fun() -> {ok, rsa_crypt(K, Operation, In, ?RSA_PKCS1_OAEP_PADDING, {Md, Label})} end,
     fun buoy_crypto:array_buffer/1}.

%% The TLS cipher suites of a default SSL_CTX, as Node 25.9.0 lists them.
ssl_ciphers() ->
    [<<"TLS_AES_256_GCM_SHA384">>, <<"TLS_CHACHA20_POLY1305_SHA256">>, <<"TLS_AES_128_GCM_SHA256">>,
     <<"ECDHE-ECDSA-AES256-GCM-SHA384">>, <<"ECDHE-RSA-AES256-GCM-SHA384">>, <<"DHE-RSA-AES256-GCM-SHA384">>,
     <<"ECDHE-ECDSA-CHACHA20-POLY1305">>, <<"ECDHE-RSA-CHACHA20-POLY1305">>, <<"DHE-RSA-CHACHA20-POLY1305">>,
     <<"ECDHE-ECDSA-AES128-GCM-SHA256">>, <<"ECDHE-RSA-AES128-GCM-SHA256">>, <<"DHE-RSA-AES128-GCM-SHA256">>,
     <<"ECDHE-ECDSA-AES256-SHA384">>, <<"ECDHE-RSA-AES256-SHA384">>, <<"DHE-RSA-AES256-SHA256">>,
     <<"ECDHE-ECDSA-AES128-SHA256">>, <<"ECDHE-RSA-AES128-SHA256">>, <<"DHE-RSA-AES128-SHA256">>,
     <<"ECDHE-ECDSA-AES256-SHA">>, <<"ECDHE-RSA-AES256-SHA">>, <<"DHE-RSA-AES256-SHA">>,
     <<"ECDHE-ECDSA-AES128-SHA">>, <<"ECDHE-RSA-AES128-SHA">>, <<"DHE-RSA-AES128-SHA">>,
     <<"RSA-PSK-AES256-GCM-SHA384">>, <<"DHE-PSK-AES256-GCM-SHA384">>, <<"RSA-PSK-CHACHA20-POLY1305">>,
     <<"DHE-PSK-CHACHA20-POLY1305">>, <<"ECDHE-PSK-CHACHA20-POLY1305">>, <<"AES256-GCM-SHA384">>,
     <<"PSK-AES256-GCM-SHA384">>, <<"PSK-CHACHA20-POLY1305">>, <<"RSA-PSK-AES128-GCM-SHA256">>,
     <<"DHE-PSK-AES128-GCM-SHA256">>, <<"AES128-GCM-SHA256">>, <<"PSK-AES128-GCM-SHA256">>,
     <<"AES256-SHA256">>, <<"AES128-SHA256">>, <<"ECDHE-PSK-AES256-CBC-SHA384">>, <<"ECDHE-PSK-AES256-CBC-SHA">>,
     <<"SRP-RSA-AES-256-CBC-SHA">>, <<"SRP-AES-256-CBC-SHA">>, <<"RSA-PSK-AES256-CBC-SHA384">>,
     <<"DHE-PSK-AES256-CBC-SHA384">>, <<"RSA-PSK-AES256-CBC-SHA">>, <<"DHE-PSK-AES256-CBC-SHA">>,
     <<"AES256-SHA">>, <<"PSK-AES256-CBC-SHA384">>, <<"PSK-AES256-CBC-SHA">>, <<"ECDHE-PSK-AES128-CBC-SHA256">>,
     <<"ECDHE-PSK-AES128-CBC-SHA">>, <<"SRP-RSA-AES-128-CBC-SHA">>, <<"SRP-AES-128-CBC-SHA">>,
     <<"RSA-PSK-AES128-CBC-SHA256">>, <<"DHE-PSK-AES128-CBC-SHA256">>, <<"RSA-PSK-AES128-CBC-SHA">>,
     <<"DHE-PSK-AES128-CBC-SHA">>, <<"AES128-SHA">>, <<"PSK-AES128-CBC-SHA256">>, <<"PSK-AES128-CBC-SHA">>,
     <<"tls_aes_256_gcm_sha384">>, <<"tls_chacha20_poly1305_sha256">>, <<"tls_aes_128_gcm_sha256">>,
     <<"tls_aes_128_ccm_8_sha256">>, <<"tls_aes_128_ccm_sha256">>].
