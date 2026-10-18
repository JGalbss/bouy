-module(buoy_crypto_tests).

-include_lib("eunit/include/eunit.hrl").

hex(Text) -> binary:decode_hex(Text).

%% RFC 7914, section 12.
scrypt_test_() ->
    [?_assertEqual(hex(<<"77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442"
                         "fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906">>),
                   buoy_crypto_kdf:scrypt(<<>>, <<>>, 16, 1, 1, 64)),
     {timeout, 60, ?_assertEqual(
         hex(<<"fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b373162"
               "2eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640">>),
         buoy_crypto_kdf:scrypt(<<"password">>, <<"NaCl">>, 1024, 8, 16, 64))}].

%% RFC 8032, section 7.4: "1 octet (with context)".
ed448_context_test() ->
    Priv = hex(<<"c4eab05d357007c632f3dbb48489924d552b08fe0c353a0d4a1f00acda2c463a"
                 "fbea67c5e8d2877c5e3bc397a659949ef8021e954e0a12274e">>),
    Pub = hex(<<"43ba28f430cdff456ae531545f7ecd0ac834a55d9358c0372bfa0c6c6798c086"
                "6aea01eb00742802b8438ea4cb82169c235160627b4c3a9480">>),
    Sig = hex(<<"d4f8f6131770dd46f40867d6fd5d5055de43541f8c5e35abbcd001b32a89f7d2"
                "151f7647f11d8ca2ae279fb842d607217fce6e042f6815ea000c85741de5c8da"
                "1144a6a1aba7f96de42505d7a7298524fda538fccbbb754f578c1cad10d54d0d"
                "5428407e85dcbc98a49155c13764e66c3c00">>),
    ?assertEqual(Sig, buoy_crypto_ed448:sign(Priv, <<3>>, <<"foo">>)),
    ?assert(buoy_crypto_ed448:verify(Pub, <<3>>, Sig, <<"foo">>)),
    ?assertNot(buoy_crypto_ed448:verify(Pub, <<3>>, Sig, <<"bar">>)).

%% With the empty context, Ed448 here and in OTP's crypto agree.
ed448_empty_context_test() ->
    {Pub, Priv} = crypto:generate_key(eddsa, ed448),
    Sig = buoy_crypto_ed448:sign(Priv, <<"message">>, <<>>),
    ?assertEqual(crypto:sign(eddsa, none, <<"message">>, [Priv, ed448]), Sig),
    ?assert(buoy_crypto_ed448:verify(Pub, <<"message">>, Sig, <<>>)).

%% ML-DSA signs with a context here, and OTP's crypto verifies the empty one.
ml_dsa_test_() ->
    [{atom_to_list(Kind), {timeout, 60, fun() ->
        #{pub := Pub, priv := Priv} = buoy_crypto_pqc:generate(Kind),
        Plain = buoy_crypto_pqc:ml_dsa_sign(Kind, Priv, <<"message">>, <<>>),
        ?assert(crypto:verify(buoy_crypto_pqc:otp_type(Kind), none, <<"message">>, Plain, Pub)),
        WithContext = buoy_crypto_pqc:ml_dsa_sign(Kind, Priv, <<"message">>, <<"context">>),
        ?assert(buoy_crypto_pqc:ml_dsa_verify(Kind, Pub, <<"message">>, WithContext, <<"context">>)),
        ?assertNot(buoy_crypto_pqc:ml_dsa_verify(Kind, Pub, <<"message">>, WithContext, <<>>)),
        ?assertNot(crypto:verify(buoy_crypto_pqc:otp_type(Kind), none, <<"message">>, WithContext, Pub))
     end}} || Kind <- [ml_dsa_44, ml_dsa_65, ml_dsa_87]].

%% A safe prime of DH_generate_parameters for the generator 2.
safe_prime_test() ->
    P = buoy_crypto_random:generate_prime(512, true, 24, 23),
    ?assertEqual(23, P rem 24),
    ?assertEqual(512, length(integer_to_list(P, 2))),
    ?assert(buoy_crypto_random:is_prime(P, 0)),
    ?assert(buoy_crypto_random:is_prime(P bsr 1, 0)).

%% OpenSSL refuses the low-order X25519 point, whose secret is all zeros.
x25519_low_order_test() ->
    {_, Priv} = crypto:generate_key(eddh, x25519),
    ?assertError({crypto_failure, {openssl, failed_during_derivation}},
                 buoy_crypto_dh:derive(#{kind => x25519, priv => Priv}, #{kind => x25519, pub => <<0:256>>})).

%% The PKCS #12 key derivation (RFC 7292, appendix B.2) with SHA-1, on the
%% vectors of OpenSSL's test of PKCS12_key_gen: the password "smeg".
pkcs12_kdf_test() ->
    {ok, Sha1} = buoy_crypto_hash:digest(<<"sha1">>),
    Smeg = buoy_crypto_pkey:bmp_password(<<"smeg">>),
    ?assertEqual(hex(<<"8aaae6297b6cb04642ab5b077851284eb7128f1a2a7fbca3">>),
                 buoy_crypto_kdf:pkcs12(Sha1, 1, Smeg, hex(<<"0a58cf64530d823f">>), 1, 24)),
    ?assertEqual(hex(<<"79993dfe048d3b76">>), buoy_crypto_kdf:pkcs12(Sha1, 2, Smeg, hex(<<"0a58cf64530d823f">>), 1, 8)),
    ?assertEqual(hex(<<"8d967d88f6caa9d714800ab3d48051d63f73a312">>),
                 buoy_crypto_kdf:pkcs12(Sha1, 3, Smeg, hex(<<"3d83c0e4546ac140">>), 1, 20)).

%% RFC 3713, appendix A, and RFC 5794, appendix A: one block each way.
block_cipher_test_() ->
    Block = fun(Module, Key, Data, Encrypt) -> Module:block(Module:schedule(hex(Key), Encrypt), hex(Data)) end,
    Camellia = <<"0123456789abcdeffedcba9876543210">>,
    Aria = <<"00112233445566778899aabbccddeeff">>,
    [?_assertEqual(hex(Out), Block(Module, Key, Plain, true)) || {Module, Key, Plain, Out} <- [
        {buoy_crypto_camellia, Camellia, Camellia, <<"67673138549669730857065648eabe43">>},
        {buoy_crypto_camellia, <<Camellia/binary, "0011223344556677">>, Camellia, <<"b4993401b3e996f84ee5cee7d79b09b9">>},
        {buoy_crypto_camellia, <<Camellia/binary, "00112233445566778899aabbccddeeff">>, Camellia,
         <<"9acc237dff16d76c20ef7c919e3a7509">>},
        {buoy_crypto_aria, <<"000102030405060708090a0b0c0d0e0f">>, Aria, <<"d718fbd6ab644c739da95f3be6451778">>},
        {buoy_crypto_aria, <<"000102030405060708090a0b0c0d0e0f1011121314151617">>, Aria,
         <<"26449c1805dbe7aa25a468ce263a9e79">>},
        {buoy_crypto_aria, <<"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f">>, Aria,
         <<"f92bd7c79fb72e2f2b8f80c1972d24fc">>}]] ++
    [?_assertEqual(hex(Camellia), Block(buoy_crypto_camellia, Camellia, <<"67673138549669730857065648eabe43">>, false)),
     ?_assertEqual(hex(Aria), Block(buoy_crypto_aria, <<"000102030405060708090a0b0c0d0e0f">>,
                                    <<"d718fbd6ab644c739da95f3be6451778">>, false))].

%% IEEE 1619, vectors 1 and 15: whole blocks, and a stolen last block.
xts_test_() ->
    Key = hex(<<"fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0bfbebdbcbbbab9b8b7b6b5b4b3b2b1b0">>),
    Tweak = <<16#9a, 16#78, 16#56, 16#34, 16#12, 0:88>>,
    Stolen = hex(<<"6c1625db4671522d3d7599601de7ca09ed">>),
    [?_assertEqual(hex(<<"917cf69ebd68b2ec9b9fe9a3eadda692cd43d2f59598ed858c02c2652fbf922e">>),
                   buoy_crypto_modes:xts(aes_128_ecb, <<0:256>>, <<0:128>>, <<0:256>>, true)),
     ?_assertEqual(Stolen, buoy_crypto_modes:xts(aes_128_ecb, Key, Tweak, hex(<<"000102030405060708090a0b0c0d0e0f10">>), true)),
     ?_assertEqual(hex(<<"000102030405060708090a0b0c0d0e0f10">>), buoy_crypto_modes:xts(aes_128_ecb, Key, Tweak, Stolen, false))].

%% The modes that buoy_crypto_modes streams agree with OTP's crypto on AES,
%% across an update that splits a block.
stream_test_() ->
    Key = binary:copy(<<7>>, 16),
    IV = binary:copy(<<9>>, 16),
    Plain = list_to_binary(lists:seq(1, 37)),
    Stream = fun(Mode, Encrypt, Data) ->
        S0 = buoy_crypto_modes:stream_init(Mode, aes_128_ecb, Key, IV, Encrypt, false),
        {A, S1} = buoy_crypto_modes:stream_update(S0, binary:part(Data, 0, 5)),
        {B, S2} = buoy_crypto_modes:stream_update(S1, binary:part(Data, 5, byte_size(Data) - 5)),
        <<A/binary, B/binary, (buoy_crypto_modes:stream_final(S2))/binary>>
    end,
    [?_assertEqual(crypto:crypto_one_time(Otp, Key, IV, Plain, true), Stream(Mode, true, Plain))
     || {Mode, Otp} <- [{cfb, aes_128_cfb128}, {cfb8, aes_128_cfb8}, {ofb, aes_128_ofb}, {ctr, aes_128_ctr}]] ++
    [?_assertEqual(Plain, Stream(cfb1, false, Stream(cfb1, true, Plain)))].
