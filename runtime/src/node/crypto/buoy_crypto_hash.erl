%% Hash, Hmac, and the digests of internalBinding('crypto')
%% (src/crypto/crypto_hash.cc and crypto_hmac.cc) on OTP's crypto: the
%% classes under createHash and createHmac, crypto.hash, getHashes, and the
%% jobs of subtle.digest and of HMAC keys.
-module(buoy_crypto_hash).

-export([members/0, digest/1, digest_names/0, hash/2, hmac/3, init/1, update/2, final/3]).

%% A function that only throws is a named fun, for dialyzer (node-builtins.md).
-dialyzer({no_return, [invalid_digest/1]}).

-type md() :: #{name := atom() | md5_sha1, size := non_neg_integer(), xof := boolean()}.
-export_type([md/0]).

-define(SIGN, 0).

-spec members() -> [{binary(), term()}].
members() ->
    [{<<"Hash">>, buoy_crypto:class(<<"Hash">>, fun init_hash/2, [
        {<<"update">>, 2, fun update_hash/2},
        {<<"digest">>, 1, fun digest_hash/2}])},
     {<<"getHashes">>, buoy_node:fn(<<"getHashes">>, 0, fun(_, _) -> buoy_heap:new_array(digest_names()) end)},
     {<<"getCachedAliases">>, buoy_node:fn(<<"getCachedAliases">>, 0, fun(_, _) -> buoy_node:object(null, []) end)},
     {<<"oneShotDigest">>, buoy_node:fn(<<"oneShotDigest">>, 7, fun one_shot_digest/2)},
     {<<"HashJob">>, buoy_crypto_job:class(<<"HashJob">>, fun hash_job/1)},
     {<<"Hmac">>, buoy_crypto:class(<<"Hmac">>, fun(_, _) -> undefined end, [
        {<<"init">>, 2, fun init_hmac/2},
        {<<"update">>, 2, fun update_hmac/2},
        {<<"digest">>, 1, fun digest_hmac/2}])},
     {<<"HmacJob">>, buoy_crypto_job:class(<<"HmacJob">>, fun hmac_job/1)}].

%%% The digests

%% The digest of an OpenSSL name, as EVP_get_digestbyname finds it: the
%% names and aliases of the default provider, in any case.
-spec digest(term()) -> {ok, md()} | error.
digest(Name) ->
    case buoy_crypto:is_string(Name) andalso lookup(name(buoy_crypto:string(Name))) of
        {Atom, Size} -> {ok, #{name => Atom, size => Size, xof => false}};
        {Atom, Size, xof} -> {ok, #{name => Atom, size => Size, xof => true}};
        _ -> error
    end.

%% ncrypto's getDigestByName keeps the legacy DSA names of SHA-1, exactly
%% as written; OpenSSL matches every other name in any case.
name(<<"dss1">>) -> <<"sha1">>;
name(<<"DSS1">>) -> <<"sha1">>;
name(Name) -> string:lowercase(Name).

lookup(Name) ->
    case lists:keyfind(Name, 1, aliases()) of
        {_, Canonical} -> lookup(Canonical);
        false -> canonical(Name)
    end.

canonical(<<"md5">>) -> {md5, 16};
canonical(<<"sha1">>) -> {sha, 20};
canonical(<<"sha224">>) -> {sha224, 28};
canonical(<<"sha256">>) -> {sha256, 32};
canonical(<<"sha384">>) -> {sha384, 48};
canonical(<<"sha512">>) -> {sha512, 64};
canonical(<<"sha512-224">>) -> {sha512_224, 28};
canonical(<<"sha512-256">>) -> {sha512_256, 32};
canonical(<<"sha3-224">>) -> {sha3_224, 28};
canonical(<<"sha3-256">>) -> {sha3_256, 32};
canonical(<<"sha3-384">>) -> {sha3_384, 48};
canonical(<<"sha3-512">>) -> {sha3_512, 64};
canonical(<<"shake128">>) -> {shake128, 16, xof};
canonical(<<"shake256">>) -> {shake256, 32, xof};
canonical(<<"ripemd160">>) -> {ripemd160, 20};
canonical(<<"blake2b512">>) -> {blake2b, 64};
canonical(<<"blake2s256">>) -> {blake2s, 32};
canonical(<<"sm3">>) -> {sm3, 32};
canonical(<<"md5-sha1">>) -> {md5_sha1, 36};
canonical(_) -> error.

%% The other names of each digest, in lower case (OpenSSL's objects.txt and
%% the names of its default provider).
aliases() ->
    [{<<"rsa-md5">>, <<"md5">>}, {<<"md5withrsaencryption">>, <<"md5">>}, {<<"ssl3-md5">>, <<"md5">>},
     {<<"sha-1">>, <<"sha1">>}, {<<"rsa-sha1">>, <<"sha1">>}, {<<"rsa-sha1-2">>, <<"sha1">>},
     {<<"sha1withrsaencryption">>, <<"sha1">>}, {<<"ssl3-sha1">>, <<"sha1">>},
     {<<"sha-224">>, <<"sha224">>}, {<<"sha2-224">>, <<"sha224">>}, {<<"rsa-sha224">>, <<"sha224">>},
     {<<"sha224withrsaencryption">>, <<"sha224">>},
     {<<"sha-256">>, <<"sha256">>}, {<<"sha2-256">>, <<"sha256">>}, {<<"rsa-sha256">>, <<"sha256">>},
     {<<"sha256withrsaencryption">>, <<"sha256">>},
     {<<"sha-384">>, <<"sha384">>}, {<<"sha2-384">>, <<"sha384">>}, {<<"rsa-sha384">>, <<"sha384">>},
     {<<"sha384withrsaencryption">>, <<"sha384">>},
     {<<"sha-512">>, <<"sha512">>}, {<<"sha2-512">>, <<"sha512">>}, {<<"rsa-sha512">>, <<"sha512">>},
     {<<"sha512withrsaencryption">>, <<"sha512">>},
     {<<"sha-512/224">>, <<"sha512-224">>}, {<<"sha2-512/224">>, <<"sha512-224">>},
     {<<"sha512/224">>, <<"sha512-224">>}, {<<"rsa-sha512/224">>, <<"sha512-224">>},
     {<<"sha512-224withrsaencryption">>, <<"sha512-224">>},
     {<<"sha-512/256">>, <<"sha512-256">>}, {<<"sha2-512/256">>, <<"sha512-256">>},
     {<<"sha512/256">>, <<"sha512-256">>}, {<<"rsa-sha512/256">>, <<"sha512-256">>},
     {<<"sha512-256withrsaencryption">>, <<"sha512-256">>},
     {<<"rsa-sha3-224">>, <<"sha3-224">>}, {<<"id-rsassa-pkcs1-v1_5-with-sha3-224">>, <<"sha3-224">>},
     {<<"rsa-sha3-256">>, <<"sha3-256">>}, {<<"id-rsassa-pkcs1-v1_5-with-sha3-256">>, <<"sha3-256">>},
     {<<"rsa-sha3-384">>, <<"sha3-384">>}, {<<"id-rsassa-pkcs1-v1_5-with-sha3-384">>, <<"sha3-384">>},
     {<<"rsa-sha3-512">>, <<"sha3-512">>}, {<<"id-rsassa-pkcs1-v1_5-with-sha3-512">>, <<"sha3-512">>},
     {<<"shake-128">>, <<"shake128">>}, {<<"shake-256">>, <<"shake256">>},
     {<<"ripemd">>, <<"ripemd160">>}, {<<"rmd160">>, <<"ripemd160">>}, {<<"ripemd-160">>, <<"ripemd160">>},
     {<<"rsa-ripemd160">>, <<"ripemd160">>}, {<<"ripemd160withrsa">>, <<"ripemd160">>},
     {<<"blake2b-512">>, <<"blake2b512">>}, {<<"blake2s-256">>, <<"blake2s256">>},
     {<<"rsa-sm3">>, <<"sm3">>}, {<<"sm3withrsaencryption">>, <<"sm3">>}].

%% getHashes(): the names that EVP_MD_do_all_sorted lists, as Node 25.9.0
%% reports them.
-spec digest_names() -> [binary()].
digest_names() ->
    [<<"RSA-MD5">>, <<"RSA-RIPEMD160">>, <<"RSA-SHA1">>, <<"RSA-SHA1-2">>, <<"RSA-SHA224">>,
     <<"RSA-SHA256">>, <<"RSA-SHA3-224">>, <<"RSA-SHA3-256">>, <<"RSA-SHA3-384">>, <<"RSA-SHA3-512">>,
     <<"RSA-SHA384">>, <<"RSA-SHA512">>, <<"RSA-SHA512/224">>, <<"RSA-SHA512/256">>, <<"RSA-SM3">>,
     <<"blake2b512">>, <<"blake2s256">>, <<"id-rsassa-pkcs1-v1_5-with-sha3-224">>,
     <<"id-rsassa-pkcs1-v1_5-with-sha3-256">>, <<"id-rsassa-pkcs1-v1_5-with-sha3-384">>,
     <<"id-rsassa-pkcs1-v1_5-with-sha3-512">>, <<"md5">>, <<"md5-sha1">>, <<"md5WithRSAEncryption">>,
     <<"ripemd">>, <<"ripemd160">>, <<"ripemd160WithRSA">>, <<"rmd160">>, <<"sha1">>,
     <<"sha1WithRSAEncryption">>, <<"sha224">>, <<"sha224WithRSAEncryption">>, <<"sha256">>,
     <<"sha256WithRSAEncryption">>, <<"sha3-224">>, <<"sha3-256">>, <<"sha3-384">>, <<"sha3-512">>,
     <<"sha384">>, <<"sha384WithRSAEncryption">>, <<"sha512">>, <<"sha512-224">>,
     <<"sha512-224WithRSAEncryption">>, <<"sha512-256">>, <<"sha512-256WithRSAEncryption">>,
     <<"sha512WithRSAEncryption">>, <<"shake128">>, <<"shake256">>, <<"sm3">>,
     <<"sm3WithRSAEncryption">>, <<"ssl3-md5">>, <<"ssl3-sha1">>].

%% The digest of Data with Md, Length bytes long.
-spec hash(md(), binary()) -> binary().
hash(Md, Data) -> final(update(init(Md), Data), Md, maps:get(size, Md)).

-spec init(md()) -> term().
init(#{name := md5_sha1}) -> {crypto:hash_init(md5), crypto:hash_init(sha)};
init(#{name := Name}) -> crypto:hash_init(Name).

-spec update(term(), iodata()) -> term().
update({Md5, Sha}, Data) -> {crypto:hash_update(Md5, Data), crypto:hash_update(Sha, Data)};
update(State, Data) -> crypto:hash_update(State, Data).

-spec final(term(), md(), non_neg_integer()) -> binary().
final(_, _, 0) -> <<>>;
final({Md5, Sha}, _, _) -> <<(crypto:hash_final(Md5))/binary, (crypto:hash_final(Sha))/binary>>;
final(State, #{xof := true}, Length) -> crypto:hash_final_xof(State, Length * 8);
final(State, _, _) -> crypto:hash_final(State).

%% The HMAC of Data under Key with Md.
-spec hmac(md(), binary(), binary()) -> binary().
hmac(#{name := md5_sha1} = Md, Key, Data) -> hmac_generic(Md, Key, Data);
hmac(#{name := Name}, Key, Data) -> crypto:mac(hmac, Name, Key, Data).

%% A streaming HMAC: OTP's context, or the data so far for md5-sha1.
hmac_init(#{name := md5_sha1} = Md, Key) -> {generic, Md, Key, []};
hmac_init(#{name := Name}, Key) -> {otp, crypto:mac_init(hmac, Name, Key)}.

hmac_update({generic, Md, Key, Acc}, Data) -> {generic, Md, Key, [Acc, Data]};
hmac_update({otp, State}, Data) -> {otp, crypto:mac_update(State, Data)};
hmac_update(done, _) -> done.

hmac_final({generic, Md, Key, Acc}) -> hmac_generic(Md, Key, iolist_to_binary(Acc));
hmac_final({otp, State}) -> crypto:mac_final(State);
hmac_final(done) -> <<>>.

%% RFC 2104 over a digest that OTP's HMAC does not take.
hmac_generic(Md, Key, Data) ->
    Block = 64,
    K = case byte_size(Key) > Block of
        true -> hash(Md, Key);
        false -> Key
    end,
    Padded = <<K/binary, 0:((Block - byte_size(K)) * 8)>>,
    Inner = hash(Md, <<(crypto:exor(Padded, binary:copy(<<16#36>>, Block)))/binary, Data/binary>>),
    hash(Md, <<(crypto:exor(Padded, binary:copy(<<16#5C>>, Block)))/binary, Inner/binary>>).

%%% Hash

%% new Hash(algorithm or hash, xofLen, algorithmId, cache)
init_hash(This, Args) ->
    Source = buoy_node:arg(1, Args),
    XofLength = buoy_node:arg(2, Args),
    {Md, State} = case buoy_heap:is_object(Source) of
        true ->
            #{md := M, state := S} = buoy_crypto:state(Source, hash),
            {M, S};
        false ->
            case digest(Source) of
                {ok, M} -> {M, init(M)};
                error -> buoy_crypto:throw_error(<<"Digest method not supported">>)
            end
    end,
    Length = output_length(Md, XofLength),
    buoy_crypto:put_state(This, {hash, #{md => Md, state => State, length => Length, digest => none}}).

%% HashInit: a length other than the digest's needs an XOF.
output_length(#{size := Size}, undefined) -> Size;
output_length(#{size := Size, xof := Xof}, Value) ->
    case buoy_crypto:to_uint32(Value) of
        Size -> Size;
        Length when Xof -> Length;
        _ -> buoy_crypto:throw_openssl(not_xof_or_invalid_length)
    end.

update_hash(This, Args) ->
    #{state := State} = S = buoy_crypto:state(This, hash),
    Data = buoy_crypto:data(buoy_node:arg(1, Args), buoy_node:arg(2, Args)),
    buoy_crypto:put_state(This, {hash, S#{state := update(State, Data)}}),
    true.

%% The digest stays, because Hash._flush and Hash.digest both read it.
digest_hash(This, Args) ->
    #{md := Md, state := State, length := Length, digest := Cached} = S = buoy_crypto:state(This, hash),
    Digest = case Cached of
        none -> final(State, Md, Length);
        _ -> Cached
    end,
    buoy_crypto:put_state(This, {hash, S#{digest := Digest}}),
    buoy_crypto:encode_output(Digest, buoy_node:arg(1, Args), buffer).

%% oneShotDigest(algorithm, algorithmId, algorithmCache, input,
%% outputEncoding, outputEncodingId, outputLength)
one_shot_digest(_, Args) ->
    [Algorithm, _Id, _Cache, Input, Encoding, EncodingId, OutputLength | _] = Args ++ lists:duplicate(7, undefined),
    Name = buoy_crypto:string(Algorithm),
    Md = case digest(Algorithm) of
        {ok, M} -> M;
        error -> buoy_crypto:throw_error(<<"Digest method ", Name/binary, " is not supported">>)
    end,
    Length = case {Md, OutputLength} of
        {#{size := Size}, undefined} -> Size;
        {#{xof := true}, _} -> buoy_crypto:to_uint32(OutputLength);
        {#{size := Size}, _} ->
            case buoy_crypto:to_uint32(OutputLength) of
                Size -> Size;
                Other -> buoy_crypto:throw_error(iolist_to_binary(io_lib:format(
                    "Output length ~B is invalid for ~s, which does not support XOF", [Other, Name])))
            end
    end,
    Digest = final(update(init(Md), buoy_crypto:data(Input, <<"utf8">>)), Md, Length),
    Enc = case is_integer(EncodingId) of
        true -> buoy_node_encoding:from_enum(EncodingId);
        false -> buoy_crypto:encoding(Encoding, hex)
    end,
    buoy_crypto:encode(Digest, Enc).

%% new HashJob(mode, algorithm, data, length): length counts bits.
hash_job([Algorithm, Data | Rest]) ->
    Md = case digest(Algorithm) of
        {ok, M} -> M;
        error -> invalid_digest(Algorithm)
    end,
    #{size := Size, xof := Xof} = Md,
    Length = case Rest of
        [Bits | _] when is_integer(Bits), Bits >= 0 ->
            case Bits div 8 of
                Size -> Size;
                L when Xof -> L;
                _ -> buoy_node:throw_code('Error', <<"ERR_CRYPTO_INVALID_DIGEST">>, <<"Digest method not supported">>)
            end;
        _ -> Size
    end,
    Bytes = buoy_crypto:bytes(Data),
    {fun() -> {ok, final(update(init(Md), Bytes), Md, Length)} end, fun buoy_crypto:array_buffer/1}.

-spec invalid_digest(term()) -> no_return().
invalid_digest(Name) ->
    buoy_node:throw_code('TypeError', <<"ERR_CRYPTO_INVALID_DIGEST">>,
                         <<"Invalid digest: ", (buoy_crypto:string(Name))/binary>>).

%%% Hmac

%% hmac.init(hash, key): the key is a secret KeyObjectHandle or bytes.
init_hmac(This, Args) ->
    Md = case digest(buoy_node:arg(1, Args)) of
        {ok, M} -> M;
        error -> invalid_digest(buoy_node:arg(1, Args))
    end,
    Key = buoy_crypto_keys:secret_bytes(buoy_node:arg(2, Args)),
    buoy_crypto:put_state(This, {hmac, hmac_init(Md, Key)}),
    undefined.

update_hmac(This, Args) ->
    Data = buoy_crypto:data(buoy_node:arg(1, Args), buoy_node:arg(2, Args)),
    buoy_crypto:put_state(This, {hmac, hmac_update(buoy_crypto:state(This, hmac), Data)}),
    true.

%% A second digest gives empty bytes, as the context is gone (HmacDigest).
digest_hmac(This, Args) ->
    Mac = hmac_final(buoy_crypto:state(This, hmac)),
    buoy_crypto:put_state(This, {hmac, done}),
    buoy_crypto:encode_output(Mac, buoy_node:arg(1, Args), buffer).

%% new HmacJob(mode, signMode, hash, keyHandle, data, signature)
hmac_job([Mode, Algorithm, KeyHandle, Data | Rest]) ->
    Md = case digest(Algorithm) of
        {ok, M} -> M;
        error -> invalid_digest(Algorithm)
    end,
    Key = buoy_crypto_keys:secret_bytes(KeyHandle),
    Bytes = buoy_crypto:bytes(Data),
    Work = fun() -> {ok, hmac(Md, Key, Bytes)} end,
    case Mode of
        ?SIGN -> {Work, fun buoy_crypto:array_buffer/1};
        _ ->
            Signature = buoy_crypto:bytes(hd(Rest)),
            {Work, fun(Mac) -> byte_size(Mac) > 0 andalso buoy_crypto:equal_bytes(Mac, Signature) end}
    end.
