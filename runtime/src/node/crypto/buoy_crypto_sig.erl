%% Sign, Verify, and SignJob of internalBinding('crypto')
%% (src/crypto/crypto_sig.cc) on OTP's crypto: RSA (PKCS#1 v1.5 and PSS),
%% ECDSA, DSA, EdDSA, ML-DSA, and SLH-DSA signatures.
-module(buoy_crypto_sig).

-export([members/0, verify/6]).

%% Functions that only throw.
-dialyzer({no_return, [md5_sha1_unsupported/0]}).

-define(RSA_PKCS1_PADDING, 1).
-define(RSA_PKCS1_PSS_PADDING, 6).
-define(SIGN, 0).
-define(DER, 0).
-define(P1363, 1).

-spec members() -> [{binary(), term()}].
members() ->
    [{<<"Sign">>, buoy_crypto:class(<<"Sign">>, fun(_, _) -> undefined end, [
        {<<"init">>, 0, fun init/2},
        {<<"update">>, 0, fun update/2},
        {<<"sign">>, 0, fun sign_final/2}])},
     {<<"Verify">>, buoy_crypto:class(<<"Verify">>, fun(_, _) -> undefined end, [
        {<<"init">>, 0, fun init/2},
        {<<"update">>, 0, fun update/2},
        {<<"verify">>, 0, fun verify_final/2}])},
     {<<"SignJob">>, buoy_crypto_job:class(<<"SignJob">>, fun sign_job/1)}].

%%% Sign and Verify

%% init(algorithm): the digest of the signature.
init(This, Args) ->
    Md = case buoy_crypto_hash:digest(buoy_node:arg(1, Args)) of
        {ok, M} -> M;
        error -> buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_DIGEST">>)
    end,
    buoy_crypto:put_state(This, {sign, {Md, buoy_crypto_hash:init(Md)}}),
    undefined.

%% update(data, encoding)
update(This, Args) ->
    {Md, State} = initialised(This),
    Data = buoy_crypto:data(buoy_node:arg(1, Args), buoy_node:arg(2, Args)),
    buoy_crypto:put_state(This, {sign, {Md, buoy_crypto_hash:update(State, Data)}}),
    undefined.

initialised(This) ->
    case buoy_crypto:state(This, sign) of
        done -> buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_STATE">>, <<"Not initialised">>);
        S -> S
    end.

%% The digest so far; the object has no digest after it.
take_digest(This) ->
    {Md, State} = initialised(This),
    buoy_crypto:put_state(This, {sign, done}),
    {Md, buoy_crypto_hash:final(State, Md, maps:get(size, Md))}.

%% sign(key, format, type, passphrase, padding, saltLength, dsaSigEnc)
sign_final(This, Args) ->
    {{_, K}, Rest} = buoy_crypto_keys:from_args(Args, private),
    one_shot_only(K) andalso buoy_crypto:fail_code(<<"ERR_CRYPTO_UNSUPPORTED_OPERATION">>),
    [Padding, Salt, Enc | _] = Rest ++ [undefined, undefined, undefined],
    Encoding = sig_encoding(Enc),
    {Md, Digest} = take_digest(This),
    Sig = sign_digest(K, Md, Digest, padding(K, Padding), salt(Salt)),
    buoy_crypto:buffer(encode_signature(K, Sig, Encoding)).

%% verify(key, format, type, passphrase, signature, padding, saltLength, dsaSigEnc)
verify_final(This, Args) ->
    {{_, K}, Rest} = buoy_crypto_keys:from_args(Args, public),
    one_shot_only(K) andalso buoy_crypto:fail_code(<<"ERR_CRYPTO_UNSUPPORTED_OPERATION">>),
    [SigValue, Padding, Salt, Enc | _] = Rest ++ [undefined, undefined, undefined, undefined],
    Encoding = sig_encoding(Enc),
    Sig = decode_signature(K, buoy_crypto:bytes(SigValue), Encoding, fail),
    {Md, Digest} = take_digest(This),
    verify_digest(K, Md, Digest, Sig, padding(K, Padding), salt(Salt)).

sig_encoding(undefined) -> ?DER;
sig_encoding(E) when E =:= ?DER; E =:= ?P1363 -> E;
sig_encoding(_) -> buoy_crypto:fail_code(<<"ERR_OUT_OF_RANGE">>, <<"invalid signature encoding">>).

%% The keys that sign a message, not a digest (isOneShotVariant).
one_shot_only(#{kind := Kind}) ->
    lists:member(Kind, [ed25519, ed448, ml_dsa_44, ml_dsa_65, ml_dsa_87]) orelse
        lists:prefix("slh_dsa", atom_to_list(Kind)).

padding(#{kind := rsa_pss}, undefined) -> ?RSA_PKCS1_PSS_PADDING;
padding(_, undefined) -> ?RSA_PKCS1_PADDING;
padding(_, P) -> P.

salt(undefined) -> undefined;
salt(S) -> S.

%%% Signatures

%% The signature of Data, a message for a one-shot key (with the context
%% Ctx) and else a message that Md digests, under the private key K.
sign(K, Md0, Data, Padding, Salt, Ctx) ->
    case one_shot_only(K) of
        true -> no_digest(Md0), sign_message(K, Data, Ctx);
        false ->
            Md = default_md(Md0),
            sign_digest(K, Md, buoy_crypto_hash:hash(Md, Data), padding(K, Padding), Salt)
    end.

-spec verify(map(), undefined | buoy_crypto_hash:md(), binary(), binary(), integer() | undefined, integer() | undefined) -> boolean().
verify(K, Md0, Data, Sig, Padding, Salt) -> verify(K, Md0, Data, Sig, Padding, Salt, <<>>).

verify(K, Md0, Data, Sig, Padding, Salt, Ctx) ->
    case one_shot_only(K) of
        true -> no_digest(Md0), verify_message(K, Data, Sig, Ctx);
        false ->
            Md = default_md(Md0),
            verify_digest(K, Md, buoy_crypto_hash:hash(Md, Data), Sig, padding(K, Padding), Salt)
    end.

%% A key that signs the message itself takes no digest (EVP_DigestSignInit).
no_digest(undefined) -> ok;
no_digest(_) -> buoy_crypto:fail({openssl, invalid_digest}).

%% OpenSSL's default digest of a signature without one.
default_md(undefined) ->
    {ok, Md} = buoy_crypto_hash:digest(<<"sha256">>),
    Md;
default_md(Md) -> Md.

%% OTP's crypto signs with the empty context only, so Ed448 and ML-DSA
%% with another context run in Erlang.
sign_message(#{kind := ed448, priv := Priv}, Data, Ctx) when Ctx =/= <<>> ->
    buoy_crypto_ed448:sign(Priv, Data, Ctx);
sign_message(#{kind := Kind, priv := Priv}, Data, Ctx) when Ctx =/= <<>>, Kind =/= ed25519 ->
    case lists:member(Kind, [ml_dsa_44, ml_dsa_65, ml_dsa_87]) of
        true -> buoy_crypto_pqc:ml_dsa_sign(Kind, Priv, Data, Ctx);
        false -> context_not_implemented()
    end;
sign_message(#{kind := Kind, priv := Priv}, Data, _) when Kind =:= ed25519; Kind =:= ed448 ->
    crypto:sign(eddsa, none, Data, [Priv, Kind]);
sign_message(#{kind := Kind} = K, Data, _) ->
    Priv = case K of
        #{seed := Seed} -> {seed, Seed};
        #{priv := P} -> pqc_private(Kind, P)
    end,
    crypto:sign(buoy_crypto_pqc:otp_type(Kind), none, Data, Priv).

%% shortcut: SLH-DSA with a context fails loudly; it needs SLH-DSA in Erlang
%% until OTP's crypto passes a context.
-spec context_not_implemented() -> no_return().
context_not_implemented() ->
    buoy_crypto:fail({code, 'Error', <<"ERR_BUOY_NOT_IMPLEMENTED">>,
                      <<"SLH-DSA with a context string is not implemented on Buoy: OTP's crypto signs with the empty context">>}).

pqc_private(Kind, P) ->
    case lists:member(Kind, [ml_dsa_44, ml_dsa_65, ml_dsa_87]) of
        true -> {expandedkey, P};
        false -> P
    end.

verify_message(#{kind := ed448, pub := Pub}, Data, Sig, Ctx) when Ctx =/= <<>> ->
    buoy_crypto_ed448:verify(Pub, Data, Sig, Ctx);
verify_message(#{kind := Kind, pub := Pub}, Data, Sig, Ctx) when Ctx =/= <<>>, Kind =/= ed25519 ->
    case lists:member(Kind, [ml_dsa_44, ml_dsa_65, ml_dsa_87]) of
        true -> buoy_crypto_pqc:ml_dsa_verify(Kind, Pub, Data, Sig, Ctx);
        false -> context_not_implemented()
    end;
verify_message(#{kind := Kind, pub := Pub}, Data, Sig, _) when Kind =:= ed25519; Kind =:= ed448 ->
    crypto:verify(eddsa, none, Data, Sig, [Pub, Kind]);
verify_message(#{kind := Kind, pub := Pub}, Data, Sig, _) ->
    crypto:verify(buoy_crypto_pqc:otp_type(Kind), none, Data, Sig, Pub).

sign_digest(#{kind := Kind} = K, Md, Digest, Padding, Salt) when Kind =:= rsa; Kind =:= rsa_pss ->
    Opts = rsa_options(K, Md, Padding, sign_salt(K, Md, Padding, Salt)),
    #{size := Size} = Md,
    Bytes = (buoy_crypto:bit_length(maps:get(n, K)) + 7) div 8,
    (Padding =:= ?RSA_PKCS1_PADDING andalso Bytes < Size + 11 + digest_info_size(Md)) andalso
        buoy_crypto:fail({openssl, digest_too_big}),
    try crypto:sign(rsa, otp_md(Md), {digest, Digest}, rsa_private(K), Opts)
    catch
        error:{_, _, _} -> buoy_crypto:fail({openssl, data_too_large_for_key_size})
    end;
sign_digest(#{kind := ec, curve := Curve, priv := D}, Md, Digest, _, _) ->
    Size = (buoy_crypto_pkey:curve_bits(Curve) + 7) div 8,
    crypto:sign(ecdsa, otp_md(Md), {digest, Digest}, [<<D:(Size * 8)>>, Curve]);
sign_digest(#{kind := dsa, p := P, q := Q, g := G, x := X}, Md, Digest, _, _) ->
    crypto:sign(dss, otp_md(Md), {digest, Digest}, [P, Q, G, X]);
sign_digest(_, _, _, _, _) ->
    buoy_crypto:fail({openssl, operation_not_supported_for_this_keytype}).

verify_digest(#{kind := Kind} = K, Md, Digest, Sig, Padding, Salt) when Kind =:= rsa; Kind =:= rsa_pss ->
    %% A key or a padding that rejects the options gives false (VerifyFinal).
    try
        Opts = rsa_options(K, Md, Padding, Salt),
        crypto:verify(rsa, otp_md(Md), {digest, Digest}, Sig, [maps:get(e, K), maps:get(n, K)], Opts)
    catch
        error:{_, _, _} -> false;
        error:{crypto_failure, _} -> false
    end;
verify_digest(#{kind := ec, curve := Curve, pub := Pub}, Md, Digest, Sig, _, _) ->
    try crypto:verify(ecdsa, otp_md(Md), {digest, Digest}, Sig, [Pub, Curve])
    catch
        error:{_, _, _} -> false
    end;
verify_digest(#{kind := dsa, p := P, q := Q, g := G, y := Y}, Md, Digest, Sig, _, _) ->
    try crypto:verify(dss, otp_md(Md), {digest, Digest}, Sig, [P, Q, G, Y])
    catch
        error:{_, _, _} -> false
    end;
verify_digest(_, _, _, _, _, _) ->
    buoy_crypto:fail({openssl, operation_not_supported_for_this_keytype}).

otp_md(#{name := md5_sha1}) -> md5_sha1_unsupported();
otp_md(#{name := Name}) -> Name.

md5_sha1_unsupported() -> buoy_crypto:fail({openssl, invalid_digest}).

%% The bytes that the DigestInfo of Md adds to its digest in PKCS#1 v1.5.
digest_info_size(#{name := md5}) -> 18;
digest_info_size(#{name := sha}) -> 15;
digest_info_size(#{name := ripemd160}) -> 15;
digest_info_size(_) -> 19.

rsa_private(#{e := E, n := N, d := D, p := P, q := Q, dp := DP, dq := DQ, qi := QI}) -> [E, N, D, P, Q, DP, DQ, QI].

%% The options of an RSA signature: the padding, and for PSS the salt and
%% the MGF1 digest, which a restricted RSA-PSS key sets.
%% The salt length of a PSS signature: RSA_PSS_SALTLEN_MAX_SIGN by default,
%% which OTP's crypto does not take, as the length that RSA_padding_add_PKCS1_PSS_mgf1 gives it.
sign_salt(K, #{size := HLen}, ?RSA_PKCS1_PSS_PADDING, Salt) when Salt =:= undefined; Salt =:= -2 ->
    case buoy_crypto_pkey:pss_params(K) of
        undefined ->
            Bits = buoy_crypto:bit_length(maps:get(n, K)),
            EmLen = (Bits + 7) div 8 - case (Bits - 1) band 7 of 0 -> 1; _ -> 0 end,
            EmLen - HLen - 2;
        _ -> Salt
    end;
sign_salt(_, _, _, Salt) -> Salt.

rsa_options(K, Md, ?RSA_PKCS1_PSS_PADDING, Salt) ->
    {Mgf1, KeySalt} = case buoy_crypto_pkey:pss_params(K) of
        #{md := KeyMd, mgf1 := M, salt := S} ->
            %% OpenSSL checks the salt length before the digest.
            is_integer(Salt) andalso Salt >= 0 andalso Salt < S andalso
                buoy_crypto:fail({openssl, pss_saltlen_too_small}),
            {ok, #{name := Allowed}} = buoy_crypto_hash:digest(KeyMd),
            maps:get(name, Md) =:= Allowed orelse buoy_crypto:fail({openssl, digest_not_allowed}),
            {ok, MgfMd} = buoy_crypto_hash:digest(M),
            {otp_md(MgfMd), S};
        undefined -> {otp_md(Md), undefined}
    end,
    SaltOpt = case {Salt, KeySalt} of
        %% RSA_PSS_SALTLEN_AUTO
        {undefined, undefined} -> [{rsa_pss_saltlen, -2}];
        {undefined, _} -> [{rsa_pss_saltlen, KeySalt}];
        _ -> [{rsa_pss_saltlen, Salt}]
    end,
    [{rsa_padding, rsa_pkcs1_pss_padding}, {rsa_mgf1_md, Mgf1}] ++ SaltOpt;
rsa_options(#{kind := rsa_pss}, _, _, _) ->
    buoy_crypto:fail({openssl, illegal_padding});
rsa_options(_, _, ?RSA_PKCS1_PADDING, _) ->
    [{rsa_padding, rsa_pkcs1_padding}];
rsa_options(_, _, _, _) ->
    buoy_crypto:fail({openssl, illegal_padding}).

%%% Signature encodings

%% The size of each of r and s of a DSA or ECDSA signature (getBytesOfRS).
rs_size(#{kind := ec, curve := Curve}) -> {ok, (buoy_crypto_pkey:curve_bits(Curve) + 7) div 8};
rs_size(#{kind := dsa, q := Q}) -> {ok, (buoy_crypto:bit_length(Q) + 7) div 8};
rs_size(_) -> none.

encode_signature(K, Sig, ?P1363) ->
    case rs_size(K) of
        {ok, N} ->
            case buoy_crypto_der:decode(Sig) of
                {ok, {seq, [{int, R}, {int, S}]}} -> <<R:(N * 8), S:(N * 8)>>;
                _ -> Sig
            end;
        none -> Sig
    end;
encode_signature(_, Sig, _) -> Sig.

%% A signature in DER; a P1363 signature of the wrong size fails as OnFail
%% asks: fail throws "Malformed signature", and invalid gives a signature
%% that never verifies.
decode_signature(K, Sig, ?P1363, OnFail) ->
    case rs_size(K) of
        {ok, N} when byte_size(Sig) =:= 2 * N ->
            <<R:(N * 8), S:(N * 8)>> = Sig,
            buoy_crypto_der:encode({seq, [{int, R}, {int, S}]});
        {ok, _} when OnFail =:= fail ->
            buoy_crypto:fail_code(<<"ERR_CRYPTO_OPERATION_FAILED">>, <<"Malformed signature">>);
        {ok, _} -> <<>>;
        none -> Sig
    end;
decode_signature(_, Sig, _, _) -> Sig.

%%% SignJob

%% new SignJob(mode, signMode, key, format, type, passphrase, data,
%% algorithm, saltLength, padding, dsaSigEnc, context, signature)
sign_job([Mode | Args]) ->
    Context = case Mode of
        ?SIGN -> private;
        _ -> public
    end,
    {{_, K}, Rest} = buoy_crypto_keys:from_args(Args, Context),
    [DataV, Alg, Salt, Padding, Enc, Ctx, SigV | _] = Rest ++ lists:duplicate(7, undefined),
    Data = buoy_crypto:bytes(DataV),
    Md = case buoy_crypto:is_string(Alg) of
        true ->
            case buoy_crypto_hash:digest(Alg) of
                {ok, M} -> M;
                error -> buoy_crypto:fail_code(<<"ERR_CRYPTO_INVALID_DIGEST">>,
                                               <<"Invalid digest: ", (buoy_crypto:string(Alg))/binary>>)
            end;
        false -> undefined
    end,
    Encoding = case Enc of
        undefined -> ?DER;
        _ -> sig_encoding(Enc)
    end,
    CtxBytes = context_bytes(Ctx),
    byte_size(CtxBytes) > 255 andalso
        buoy_crypto:fail_code(<<"ERR_OUT_OF_RANGE">>, <<"context string must be at most 255 bytes">>),
    CtxBytes =/= <<>> andalso not supports_context(K) andalso
        buoy_crypto:fail_code(<<"ERR_CRYPTO_OPERATION_FAILED">>, <<"Context parameter is unsupported">>),
    case Mode of
        ?SIGN ->
            {fun() -> {ok, encode_signature(K, sign(K, Md, Data, Padding, Salt, CtxBytes), Encoding)} end,
             fun buoy_crypto:array_buffer/1};
        _ ->
            Sig = decode_signature(K, buoy_crypto:bytes(SigV), Encoding, invalid),
            {fun() -> {ok, Sig =/= <<>> andalso verify(K, Md, Data, Sig, Padding, Salt, CtxBytes)} end,
             fun(Result) -> Result end}
    end.

context_bytes(undefined) -> <<>>;
context_bytes(Ctx) -> buoy_crypto:bytes(Ctx).

%% SupportsContextString: OpenSSL takes a context string from 3.2 on.
supports_context(#{kind := Kind}) ->
    buoy_crypto:has_openssl(3, 2) andalso
        (Kind =:= ed448 orelse lists:member(Kind, [ml_dsa_44, ml_dsa_65, ml_dsa_87]) orelse
         lists:prefix("slh_dsa", atom_to_list(Kind))).
