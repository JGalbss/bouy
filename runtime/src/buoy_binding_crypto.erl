%% internalBinding('crypto') (src/node_crypto.cc): the members that each part
%% of src/crypto/ registers, on OTP's crypto and public_key. Each part is a
%% module buoy_crypto_<part>, after crypto_<part>.cc; the members that no
%% part implements yet throw ERR_BUOY_NOT_IMPLEMENTED.
-module(buoy_binding_crypto).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    Members = constants() ++ util()
        ++ buoy_crypto_hash:members()
        ++ buoy_crypto_random:members()
        ++ buoy_crypto_kdf:members()
        ++ buoy_crypto_keys:members()
        ++ buoy_crypto_cipher:members(),
    Names = [Name || {Name, _} <- Members],
    Missing = [{Name, missing(Name)} || Name <- node_members(), not lists:member(Name, Names)],
    buoy_node:object(Members ++ Missing).

%% A member that Buoy does not implement yet: a class or a function.
missing(<<C, _/binary>> = Name) when C >= $A, C =< $Z -> buoy_node:missing_constructor(<<"crypto">>, Name, 0);
missing(Name) -> buoy_node:not_implemented(<<"crypto">>, Name).

%% crypto_util.cc and crypto_timing.cc.
util() ->
    F = fun buoy_crypto:fn/3,
    [{<<"timingSafeEqual">>, F(<<"timingSafeEqual">>, 2, fun(_, Args) ->
        buoy_crypto:equal_bytes(buoy_crypto:bytes(buoy_node:arg(1, Args)), buoy_crypto:bytes(buoy_node:arg(2, Args)))
     end)},
     %% OTP's crypto loads no engine, so no engine name is known (SetEngine).
     {<<"setEngine">>, F(<<"setEngine">>, 2, fun(_, _) -> false end)},
     {<<"getFipsCrypto">>, F(<<"getFipsCrypto">>, 0, fun(_, _) -> fips() end)},
     {<<"setFipsCrypto">>, F(<<"setFipsCrypto">>, 1, fun(_, Args) -> set_fips(buoy_ref:truthy(buoy_node:arg(1, Args))) end)},
     {<<"testFipsCrypto">>, F(<<"testFipsCrypto">>, 0, fun(_, _) -> crypto:info_fips() =/= not_supported end)},
     {<<"getOpenSSLSecLevelCrypto">>, F(<<"getOpenSSLSecLevelCrypto">>, 0, fun(_, _) -> 2 end)}].

fips() ->
    case crypto:info_fips() of
        enabled -> 1;
        _ -> 0
    end.

%% OTP sets FIPS mode at boot (the fips_mode parameter), so a program can only
%% ask for the mode that it has.
set_fips(Enable) ->
    case Enable =:= (fips() =:= 1) of
        true -> undefined;
        false -> buoy_crypto:throw_openssl(unsupported)
    end.

%% The constants of the binding of Node 25.9.0, in its order.
constants() ->
    [{<<"kKeyVariantAES_CTR_128">>, 0}, {<<"kKeyVariantAES_CTR_192">>, 1}, {<<"kKeyVariantAES_CTR_256">>, 2},
     {<<"kKeyVariantAES_CBC_128">>, 3}, {<<"kKeyVariantAES_CBC_192">>, 4}, {<<"kKeyVariantAES_CBC_256">>, 5},
     {<<"kKeyVariantAES_GCM_128">>, 6}, {<<"kKeyVariantAES_GCM_192">>, 7}, {<<"kKeyVariantAES_GCM_256">>, 8},
     {<<"kKeyVariantAES_KW_128">>, 9}, {<<"kKeyVariantAES_KW_192">>, 10}, {<<"kKeyVariantAES_KW_256">>, 11},
     {<<"kKeyVariantAES_OCB_128">>, 12}, {<<"kKeyVariantAES_OCB_192">>, 13}, {<<"kKeyVariantAES_OCB_256">>, 14},
     {<<"kWebCryptoCipherEncrypt">>, 0}, {<<"kWebCryptoCipherDecrypt">>, 1},
     {<<"OPENSSL_EC_NAMED_CURVE">>, 1}, {<<"OPENSSL_EC_EXPLICIT_CURVE">>, 0},
     {<<"kWebCryptoKeyFormatRaw">>, 0}, {<<"kWebCryptoKeyFormatPKCS8">>, 1},
     {<<"kWebCryptoKeyFormatSPKI">>, 2}, {<<"kWebCryptoKeyFormatJWK">>, 3},
     {<<"EVP_PKEY_ED25519">>, 1087}, {<<"EVP_PKEY_ED448">>, 1088},
     {<<"EVP_PKEY_ML_DSA_44">>, 1457}, {<<"EVP_PKEY_ML_DSA_65">>, 1458}, {<<"EVP_PKEY_ML_DSA_87">>, 1459},
     {<<"EVP_PKEY_ML_KEM_512">>, 1454}, {<<"EVP_PKEY_ML_KEM_768">>, 1455}, {<<"EVP_PKEY_ML_KEM_1024">>, 1456},
     {<<"EVP_PKEY_SLH_DSA_SHA2_128F">>, 1461}, {<<"EVP_PKEY_SLH_DSA_SHA2_128S">>, 1460},
     {<<"EVP_PKEY_SLH_DSA_SHA2_192F">>, 1463}, {<<"EVP_PKEY_SLH_DSA_SHA2_192S">>, 1462},
     {<<"EVP_PKEY_SLH_DSA_SHA2_256F">>, 1465}, {<<"EVP_PKEY_SLH_DSA_SHA2_256S">>, 1464},
     {<<"EVP_PKEY_SLH_DSA_SHAKE_128F">>, 1467}, {<<"EVP_PKEY_SLH_DSA_SHAKE_128S">>, 1466},
     {<<"EVP_PKEY_SLH_DSA_SHAKE_192F">>, 1469}, {<<"EVP_PKEY_SLH_DSA_SHAKE_192S">>, 1468},
     {<<"EVP_PKEY_SLH_DSA_SHAKE_256F">>, 1471}, {<<"EVP_PKEY_SLH_DSA_SHAKE_256S">>, 1470},
     {<<"EVP_PKEY_X25519">>, 1034}, {<<"EVP_PKEY_X448">>, 1035},
     {<<"kKeyEncodingPKCS1">>, 0}, {<<"kKeyEncodingPKCS8">>, 1}, {<<"kKeyEncodingSPKI">>, 2}, {<<"kKeyEncodingSEC1">>, 3},
     {<<"kKeyFormatDER">>, 0}, {<<"kKeyFormatPEM">>, 1}, {<<"kKeyFormatJWK">>, 2},
     {<<"kKeyTypeSecret">>, 0}, {<<"kKeyTypePublic">>, 1}, {<<"kKeyTypePrivate">>, 2},
     {<<"kSigEncDER">>, 0}, {<<"kSigEncP1363">>, 1},
     {<<"kKeyVariantRSA_SSA_PKCS1_v1_5">>, 0}, {<<"kKeyVariantRSA_PSS">>, 1}, {<<"kKeyVariantRSA_OAEP">>, 2},
     {<<"kSignJobModeSign">>, 0}, {<<"kSignJobModeVerify">>, 1},
     {<<"RSA_PKCS1_PSS_PADDING">>, 6}, {<<"kCryptoJobAsync">>, 0}, {<<"kCryptoJobSync">>, 1},
     {<<"X509_CHECK_FLAG_ALWAYS_CHECK_SUBJECT">>, 1}, {<<"X509_CHECK_FLAG_NEVER_CHECK_SUBJECT">>, 32},
     {<<"X509_CHECK_FLAG_NO_WILDCARDS">>, 2}, {<<"X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS">>, 4},
     {<<"X509_CHECK_FLAG_MULTI_LABEL_WILDCARDS">>, 8}, {<<"X509_CHECK_FLAG_SINGLE_LABEL_SUBDOMAINS">>, 16},
     {<<"kTypeArgon2d">>, 0}, {<<"kTypeArgon2i">>, 1}, {<<"kTypeArgon2id">>, 2},
     {<<"kKEMEncapsulate">>, 0}, {<<"kKEMDecapsulate">>, 1}].

%% The functions and classes of Node 25.9.0's binding, in its order.
node_members() ->
    [<<"AESCipherJob">>, <<"ChaCha20Poly1305CipherJob">>, <<"CipherBase">>, <<"getSSLCiphers">>,
     <<"getCiphers">>, <<"publicEncrypt">>, <<"privateDecrypt">>, <<"privateEncrypt">>,
     <<"publicDecrypt">>, <<"getCipherInfo">>, <<"DiffieHellman">>, <<"DiffieHellmanGroup">>,
     <<"DhKeyPairGenJob">>, <<"DHKeyExportJob">>, <<"DHBitsJob">>, <<"DsaKeyPairGenJob">>, <<"ECDH">>,
     <<"ECDHConvertKey">>, <<"getCurves">>, <<"ECDHBitsJob">>, <<"EcKeyPairGenJob">>, <<"ECKeyExportJob">>,
     <<"Hash">>, <<"getHashes">>, <<"getCachedAliases">>, <<"oneShotDigest">>, <<"HashJob">>,
     <<"HKDFJob">>, <<"Hmac">>, <<"HmacJob">>, <<"NidKeyPairGenJob">>, <<"SecretKeyGenJob">>,
     <<"KeyObjectHandle">>, <<"createNativeKeyObjectClass">>, <<"PBKDF2Job">>, <<"RandomBytesJob">>,
     <<"RandomPrimeJob">>, <<"CheckPrimeJob">>, <<"RsaKeyPairGenJob">>, <<"RSAKeyExportJob">>,
     <<"RSACipherJob">>, <<"SecureContext">>, <<"getBundledRootCertificates">>,
     <<"getSystemCACertificates">>, <<"getExtraCACertificates">>, <<"resetRootCertStore">>,
     <<"getUserRootCertificates">>, <<"startLoadingCertificatesOffThread">>, <<"Sign">>, <<"SignJob">>,
     <<"certVerifySpkac">>, <<"certExportPublicKey">>, <<"certExportChallenge">>, <<"timingSafeEqual">>,
     <<"setEngine">>, <<"getFipsCrypto">>, <<"setFipsCrypto">>, <<"testFipsCrypto">>, <<"secureBuffer">>,
     <<"secureHeapUsed">>, <<"getOpenSSLSecLevelCrypto">>, <<"Verify">>, <<"parseX509">>,
     <<"Argon2Job">>, <<"KEMEncapsulateJob">>, <<"KEMDecapsulateJob">>, <<"KmacJob">>, <<"ScryptJob">>,
     <<"TurboShakeJob">>, <<"KangarooTwelveJob">>].
