-module(buoy_crypto_tests).

-include_lib("eunit/include/eunit.hrl").

hex(Text) -> binary:decode_hex(Text).

%% RFC 9106, sections 5.1 to 5.3.
argon2_test_() ->
    P = binary:copy(<<1>>, 32),
    S = binary:copy(<<2>>, 16),
    K = binary:copy(<<3>>, 8),
    X = binary:copy(<<4>>, 12),
    [?_assertEqual(hex(Tag), buoy_crypto_argon2:argon2(Type, P, S, K, X, 4, 32, 32, 3))
     || {Type, Tag} <- [{0, <<"512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb">>},
                        {1, <<"c814d9d1dc7f37aa13f0d77f2494bda1c8de6b016dd388d29952a4c4672b6ce8">>},
                        {2, <<"0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659">>}]].

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
