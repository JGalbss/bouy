%% KEMEncapsulateJob and KEMDecapsulateJob of internalBinding('crypto')
%% (src/crypto/crypto_kem.cc): the KEMs of OpenSSL 3.5 behind
%% EVP_PKEY_encapsulate. ML-KEM runs on OTP's crypto; RSASVE (NIST SP
%% 800-56B) and DHKEM (RFC 9180) for EC and X25519 or X448 keys run here.
-module(buoy_crypto_kem).

-export([members/0]).

%% Functions that only throw.
-dialyzer({no_return, [failed/1]}).

-spec members() -> [{binary(), term()}].
members() ->
    [{<<"KEMEncapsulateJob">>, buoy_crypto_job:class(<<"KEMEncapsulateJob">>, fun encapsulate_job/1)},
     {<<"KEMDecapsulateJob">>, buoy_crypto_job:class(<<"KEMDecapsulateJob">>, fun decapsulate_job/2)}].

%% new KEMEncapsulateJob(mode, key, format, type, passphrase)
encapsulate_job(Args) ->
    {{_, K}, _} = buoy_crypto_keys:from_args(Args, public),
    {fun() -> {ok, encapsulate(buoy_crypto_pkey:public(K))} end,
     fun({Secret, Ciphertext}) -> buoy_heap:new_array([buoy_crypto:buffer(Secret), buoy_crypto:buffer(Ciphertext)]) end}.

%% new KEMDecapsulateJob(mode, key, format, type, passphrase, ciphertext)
%% Only a sync job throws the error of the failed decapsulation; an async
%% one reports that deriving the bits failed (DeriveBitsJob).
decapsulate_job(Args, Mode) ->
    {{_, K}, [Ciphertext | _]} = buoy_crypto_keys:from_args(Args, private),
    Bytes = buoy_crypto:bytes(Ciphertext),
    Work = fun() -> {ok, decapsulate(K, Bytes)} end,
    {case Mode of
         sync -> Work;
         async -> fun() -> deriving_bits(Work) end
     end, fun buoy_crypto:buffer/1}.

deriving_bits(Work) ->
    try Work()
    catch
        error:{crypto_failure, {code, _, <<"ERR_CRYPTO_OPERATION_FAILED">>, _}} ->
            {error, {message, <<"Deriving bits failed">>}}
    end.

failed(Operation) ->
    buoy_crypto:fail_code(<<"ERR_CRYPTO_OPERATION_FAILED">>, <<"Failed to perform ", Operation/binary>>).

%% {SharedSecret, Ciphertext} for the public key K.
encapsulate(#{kind := Kind, pub := Pub}) when Kind =:= ml_kem_512; Kind =:= ml_kem_768; Kind =:= ml_kem_1024 ->
    crypto:encapsulate_key(buoy_crypto_pqc:otp_type(Kind), Pub);
encapsulate(#{kind := rsa, n := N, e := E}) ->
    Size = byte_size(binary:encode_unsigned(N)),
    Z = 2 + buoy_crypto:rand_below(N - 3),
    {<<Z:(Size * 8)>>, <<(buoy_crypto:mod_pow(Z, E, N)):(Size * 8)>>};
encapsulate(K) ->
    {Suite, _, _} = suite(K, <<"encapsulation">>),
    #{pub := PubR} = K,
    {Enc, Dh} = ephemeral_dh(K),
    {extract_and_expand(Suite, Dh, <<Enc/binary, (serialize(K, PubR))/binary>>), Enc}.

decapsulate(#{kind := Kind, priv := Priv}, Ciphertext) when Kind =:= ml_kem_512; Kind =:= ml_kem_768;
                                                              Kind =:= ml_kem_1024 ->
    try crypto:decapsulate_key(buoy_crypto_pqc:otp_type(Kind), Priv, Ciphertext)
    catch
        error:_ -> failed(<<"decapsulation">>)
    end;
decapsulate(#{kind := rsa, n := N, d := D}, Ciphertext) ->
    Size = byte_size(binary:encode_unsigned(N)),
    byte_size(Ciphertext) =:= Size orelse failed(<<"decapsulation">>),
    C = binary:decode_unsigned(Ciphertext),
    (C > 1 andalso C < N - 1) orelse failed(<<"decapsulation">>),
    <<(buoy_crypto:mod_pow(C, D, N)):(Size * 8)>>;
decapsulate(K, Enc) ->
    {Suite, _, _} = suite(K, <<"decapsulation">>),
    Dh = try buoy_crypto_dh:derive(K, peer(K, Enc))
    catch
        error:_ -> failed(<<"decapsulation">>)
    end,
    extract_and_expand(Suite, dh_bytes(K, Dh), <<Enc/binary, (serialize(K, maps:get(pub, K)))/binary>>).

%% The KEM id of RFC 9180 and its HKDF digest and secret length.
suite(#{kind := ec, curve := prime256v1}, _) -> {16#0010, sha256, 32};
suite(#{kind := ec, curve := secp384r1}, _) -> {16#0011, sha384, 48};
suite(#{kind := ec, curve := secp521r1}, _) -> {16#0012, sha512, 64};
suite(#{kind := x25519}, _) -> {16#0020, sha256, 32};
suite(#{kind := x448}, _) -> {16#0021, sha512, 64};
suite(_, Operation) -> failed(Operation).

ephemeral_dh(#{kind := ec, curve := Curve} = K) ->
    {Pub, Priv} = crypto:generate_key(ecdh, Curve),
    Ephemeral = #{kind => ec, curve => Curve, pub => Pub, priv => binary:decode_unsigned(Priv)},
    {Pub, buoy_crypto_dh:derive(Ephemeral, K)};
ephemeral_dh(#{kind := Kind} = K) ->
    {Pub, Priv} = crypto:generate_key(eddh, Kind),
    {Pub, buoy_crypto_dh:derive(#{kind => Kind, pub => Pub, priv => Priv}, K)}.

peer(#{kind := ec, curve := Curve}, Enc) -> #{kind => ec, curve => Curve, pub => Enc};
peer(#{kind := Kind}, Enc) -> #{kind => Kind, pub => Enc}.

dh_bytes(_, Dh) -> Dh.

serialize(#{kind := ec, curve := Curve}, Pub) ->
    {ok, XY} = buoy_crypto_pkey:decode_point(Curve, Pub),
    buoy_crypto_pkey:encode_point(Curve, XY, uncompressed);
serialize(_, Pub) -> Pub.

%% ExtractAndExpand of DHKEM.
extract_and_expand(KemId, Dh, Context) ->
    {_, Md, Length} = lists:keyfind(KemId, 1, [{16#0010, sha256, 32}, {16#0011, sha384, 48}, {16#0012, sha512, 64},
                                               {16#0020, sha256, 32}, {16#0021, sha512, 64}]),
    SuiteId = <<"KEM", KemId:16>>,
    Prk = crypto:mac(hmac, Md, <<>>, <<"HPKE-v1", SuiteId/binary, "eae_prk", Dh/binary>>),
    expand(Md, Prk, <<Length:16, "HPKE-v1", SuiteId/binary, "shared_secret", Context/binary>>, Length).

expand(Md, Prk, Info, Length) ->
    expand(Md, Prk, Info, Length, 1, <<>>, <<>>).

expand(_, _, _, Length, _, _, Acc) when byte_size(Acc) >= Length -> binary:part(Acc, 0, Length);
expand(Md, Prk, Info, Length, I, Prev, Acc) ->
    T = crypto:mac(hmac, Md, Prk, <<Prev/binary, Info/binary, I>>),
    expand(Md, Prk, Info, Length, I + 1, T, <<Acc/binary, T/binary>>).

