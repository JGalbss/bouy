%% PKCS #12 (RFC 7292), as OpenSSL's PKCS12_parse reads a PFX for
%% SecureContext's loadPKCS12: the MAC check, the bags of the
%% authenticated safe, encrypted with pbeWithSHA1And3-KeyTripleDES-CBC or
%% PBES2 (PBKDF2 with AES or 3DES), and the private key with its
%% certificate. OpenSSL 3 drops RC2 and RC4 to its legacy provider, so
%% they are unsupported here too.
-module(buoy_crypto_pkcs12).

-export([parse/2]).

-define(DATA, {1,2,840,113549,1,7,1}).
-define(ENCRYPTED_DATA, {1,2,840,113549,1,7,6}).
-define(KEY_BAG, {1,2,840,113549,1,12,10,1,1}).
-define(SHROUDED_KEY_BAG, {1,2,840,113549,1,12,10,1,2}).
-define(CERT_BAG, {1,2,840,113549,1,12,10,1,3}).
-define(X509_CERTIFICATE, {1,2,840,113549,1,9,22,1}).
-define(LOCAL_KEY_ID, {1,2,840,113549,1,9,21}).
-define(PBE_SHA1_3DES, {1,2,840,113549,1,12,1,3}).
-define(PBES2, {1,2,840,113549,1,5,13}).
-define(PBKDF2, {1,2,840,113549,1,5,12}).

-type key() :: {'PrivateKeyInfo', binary()}.

%% parse(Pfx, Password): the private key, the certificate that matches it,
%% and the other certificates, or the reason that OpenSSL gives. Password
%% none is a missing passphrase, which tries no password and then "".
-spec parse(binary(), binary() | none) ->
    {ok, key(), binary(), [binary()]} | {error, unsupported | binary()}.
parse(Pfx, Password) ->
    try
        {16#30, Body, _} = tlv(Pfx),
        [{2, _Version}, {16#30, AuthSafe} | Mac] = items(Body),
        Octets = data_content(AuthSafe),
        Pass = verify_mac(Octets, Mac, Password),
        Bags = lists:append([safe_bags(Info, Pass) || {16#30, Info} <- sequence_of(Octets)]),
        select(Bags)
    catch
        throw:{pkcs12, Reason} -> {error, Reason};
        error:_ -> {error, <<"decode error">>}
    end.

%% The key, the certificate whose localKeyId is the key's, else the first,
%% and the rest, as PKCS12_parse returns them.
select(Bags) ->
    Keys = [{Id, Key} || {key, Id, Key} <- Bags],
    Certs = [{Id, Der} || {cert, Id, Der} <- Bags],
    case {Keys, Certs} of
        {[], _} -> {error, <<"Unable to load private key from PFX data">>};
        {_, []} -> {error, <<"Unable to load certificate from PFX data">>};
        {[{KeyId, Key} | _], _} ->
            Leaf = case [Der || {Id, Der} <- Certs, Id =/= none, Id =:= KeyId] of
                [Match | _] -> Match;
                [] -> element(2, hd(Certs))
            end,
            {ok, Key, Leaf, [Der || {_, Der} <- Certs, Der =/= Leaf]}
    end.

%%% MAC

%% The password whose MAC matches: PKCS12_parse tries no password and then
%% "" when none is given.
verify_mac(_Octets, [], Password) ->
    Password;
verify_mac(Octets, [{16#30, MacData}], none) ->
    case lists:dropwhile(fun(P) -> not mac_matches(Octets, MacData, P) end, [none, <<>>]) of
        [Pass | _] -> Pass;
        [] -> throw({pkcs12, <<"mac verify failure">>})
    end;
verify_mac(Octets, [{16#30, MacData}], Password) ->
    mac_matches(Octets, MacData, Password) orelse throw({pkcs12, <<"mac verify failure">>}),
    Password.

mac_matches(Octets, MacData, Password) ->
    [{16#30, DigestInfo}, {4, Salt} | Rest] = items(MacData),
    [{16#30, Algorithm}, {4, Digest}] = items(DigestInfo),
    Hash = hash(oid(Algorithm)),
    Iterations = case Rest of [{2, N}] -> binary:decode_unsigned(N); [] -> 1 end,
    Key = kdf(Hash, bmp(Password), Salt, 3, Iterations, hash_size(Hash)),
    crypto:mac(hmac, Hash, Key, Octets) =:= Digest.

%%% Bags

safe_bags(Info, Pass) ->
    [{6, Type}, {16#A0, Explicit}] = items(Info),
    Contents = case decode_oid(Type) of
        ?DATA ->
            {4, Octets, _} = tlv(Explicit),
            Octets;
        ?ENCRYPTED_DATA ->
            {16#30, Encrypted, _} = tlv(Explicit),
            [{2, _}, {16#30, ContentInfo} | _] = items(Encrypted),
            [{6, _}, {16#30, Algorithm}, {16#80, Ciphertext}] = items(ContentInfo),
            decrypt(Algorithm, Ciphertext, Pass);
        _ ->
            throw({pkcs12, unsupported})
    end,
    lists:filtermap(fun({16#30, Bag}) -> bag(items(Bag), Pass) end, sequence_of(Contents)).

bag([{6, Type}, {16#A0, Explicit} | Attributes], Pass) ->
    Id = local_key_id(Attributes),
    {16#30, Value, _} = tlv(Explicit),
    case decode_oid(Type) of
        ?KEY_BAG ->
            {true, {key, Id, {'PrivateKeyInfo', sequence(Value)}}};
        ?SHROUDED_KEY_BAG ->
            [{16#30, Algorithm}, {4, Ciphertext}] = items(Value),
            {true, {key, Id, {'PrivateKeyInfo', decrypt(Algorithm, Ciphertext, Pass)}}};
        ?CERT_BAG ->
            [{6, CertType}, {16#A0, CertExplicit}] = items(Value),
            {4, Der, _} = tlv(CertExplicit),
            decode_oid(CertType) =:= ?X509_CERTIFICATE andalso {true, {cert, Id, Der}};
        _ ->
            false
    end.

local_key_id([{16#31, Set}]) ->
    Ids = [V || {16#30, Attribute} <- items(Set),
                [{6, Type}, {16#31, Values}] <- [items(Attribute)],
                decode_oid(Type) =:= ?LOCAL_KEY_ID,
                {4, V} <- items(Values)],
    case Ids of [Id | _] -> Id; [] -> none end;
local_key_id(_) ->
    none.

sequence(Value) -> <<16#30, (length_bytes(byte_size(Value)))/binary, Value/binary>>.

length_bytes(N) when N < 128 -> <<N>>;
length_bytes(N) -> Bytes = binary:encode_unsigned(N), <<(16#80 bor byte_size(Bytes)), Bytes/binary>>.

%%% Encryption

decrypt(Algorithm, Ciphertext, Pass) ->
    [{6, Oid} | Params] = items(Algorithm),
    {Cipher, Key, Iv} = case {decode_oid(Oid), Params} of
        {?PBE_SHA1_3DES, [{16#30, P}]} ->
            [{4, Salt}, {2, Iter}] = items(P),
            Iterations = binary:decode_unsigned(Iter),
            {des_ede3_cbc, kdf(sha, bmp(Pass), Salt, 1, Iterations, 24), kdf(sha, bmp(Pass), Salt, 2, Iterations, 8)};
        {?PBES2, [{16#30, P}]} ->
            pbes2(items(P), Pass);
        _ ->
            throw({pkcs12, unsupported})
    end,
    unpad(crypto:crypto_one_time(Cipher, Key, Iv, Ciphertext, false)).

pbes2([{16#30, Kdf}, {16#30, Scheme}], Pass) ->
    [{6, KdfOid}, {16#30, KdfParams}] = items(Kdf),
    decode_oid(KdfOid) =:= ?PBKDF2 orelse throw({pkcs12, unsupported}),
    [{6, SchemeOid} | SchemeParams] = items(Scheme),
    {Cipher, KeySize} = case decode_oid(SchemeOid) of
        {2,16,840,1,101,3,4,1,2} -> {aes_128_cbc, 16};
        {2,16,840,1,101,3,4,1,22} -> {aes_192_cbc, 24};
        {2,16,840,1,101,3,4,1,42} -> {aes_256_cbc, 32};
        {1,2,840,113549,3,7} -> {des_ede3_cbc, 24};
        _ -> throw({pkcs12, unsupported})
    end,
    [{4, Iv}] = SchemeParams,
    [{4, Salt}, {2, Iter} | Rest] = items(KdfParams),
    Prf = case [A || {16#30, A} <- Rest] of
        [PrfAlgorithm] -> hmac_hash(oid(PrfAlgorithm));
        [] -> sha
    end,
    Raw = case Pass of none -> <<>>; _ -> Pass end,
    {Cipher, crypto:pbkdf2_hmac(Prf, Raw, Salt, binary:decode_unsigned(Iter), KeySize), Iv}.

unpad(<<>>) -> throw({pkcs12, <<"bad decrypt">>});
unpad(Plain) ->
    N = binary:last(Plain),
    (N >= 1 andalso N =< 16 andalso N =< byte_size(Plain)) orelse throw({pkcs12, <<"bad decrypt">>}),
    binary:part(Plain, 0, byte_size(Plain) - N).

%% The key derivation of RFC 7292 appendix B.2: ID 1 makes a key, 2 an IV,
%% and 3 a MAC key.
kdf(Hash, Password, Salt, Id, Iterations, Length) ->
    Block = block_size(Hash),
    I = <<(fill(Salt, Block))/binary, (fill(Password, Block))/binary>>,
    kdf_blocks(Hash, binary:copy(<<Id>>, Block), I, Iterations, Block, Length, <<>>).

kdf_blocks(_Hash, _D, _I, _Iterations, _Block, Length, Acc) when byte_size(Acc) >= Length ->
    binary:part(Acc, 0, Length);
kdf_blocks(Hash, D, I, Iterations, Block, Length, Acc) ->
    A = repeat_hash(Hash, crypto:hash(Hash, <<D/binary, I/binary>>), Iterations - 1),
    B = binary:decode_unsigned(fill(A, Block)) + 1,
    Mask = (1 bsl (Block * 8)) - 1,
    Next = << <<((binary:decode_unsigned(Ij) + B) band Mask):Block/unit:8>> || <<Ij:Block/binary>> <= I >>,
    kdf_blocks(Hash, D, Next, Iterations, Block, Length, <<Acc/binary, A/binary>>).

repeat_hash(_Hash, Digest, 0) -> Digest;
repeat_hash(Hash, Digest, N) -> repeat_hash(Hash, crypto:hash(Hash, Digest), N - 1).

%% The bytes repeated to a whole number of blocks.
fill(<<>>, _Block) -> <<>>;
fill(Bytes, Block) ->
    Length = Block * ((byte_size(Bytes) + Block - 1) div Block),
    binary:part(binary:copy(Bytes, Length div byte_size(Bytes) + 1), 0, Length).

%% A password as a NUL-terminated BMPString; no password is empty.
bmp(none) -> <<>>;
bmp(Password) -> <<(unicode:characters_to_binary(Password, utf8, {utf16, big}))/binary, 0, 0>>.

hash({1,3,14,3,2,26}) -> sha;
hash({2,16,840,1,101,3,4,2,4}) -> sha224;
hash({2,16,840,1,101,3,4,2,1}) -> sha256;
hash({2,16,840,1,101,3,4,2,2}) -> sha384;
hash({2,16,840,1,101,3,4,2,3}) -> sha512;
hash(_) -> throw({pkcs12, unsupported}).

hmac_hash({1,2,840,113549,2,7}) -> sha;
hmac_hash({1,2,840,113549,2,8}) -> sha224;
hmac_hash({1,2,840,113549,2,9}) -> sha256;
hmac_hash({1,2,840,113549,2,10}) -> sha384;
hmac_hash({1,2,840,113549,2,11}) -> sha512;
hmac_hash(_) -> throw({pkcs12, unsupported}).

hash_size(Hash) -> byte_size(crypto:hash(Hash, <<>>)).

block_size(Hash) when Hash =:= sha384; Hash =:= sha512 -> 128;
block_size(_) -> 64.

%%% DER

%% The content octets of a ContentInfo of type data.
data_content(Info) ->
    [{6, Type}, {16#A0, Explicit}] = items(Info),
    decode_oid(Type) =:= ?DATA orelse throw({pkcs12, unsupported}),
    {4, Octets, _} = tlv(Explicit),
    Octets.

%% The OID of an AlgorithmIdentifier.
oid(Algorithm) ->
    [{6, Oid} | _] = items(Algorithm),
    decode_oid(Oid).

decode_oid(<<First, Rest/binary>>) ->
    list_to_tuple([First div 40, First rem 40 | arcs(Rest, 0)]).

arcs(<<>>, _) -> [];
arcs(<<1:1, B:7, Rest/binary>>, Acc) -> arcs(Rest, (Acc bsl 7) bor B);
arcs(<<0:1, B:7, Rest/binary>>, Acc) -> [(Acc bsl 7) bor B | arcs(Rest, 0)].

%% The elements of a DER SEQUENCE OF.
sequence_of(Der) ->
    {16#30, Body, _} = tlv(Der),
    items(Body).

items(<<>>) -> [];
items(Bin) ->
    {Tag, Value, Rest} = tlv(Bin),
    [{Tag, Value} | items(Rest)].

%% One element: its tag byte, its value, and the bytes after it.
tlv(<<Tag, 0:1, Length:7, Rest/binary>>) -> split(Tag, Length, Rest);
tlv(<<Tag, 1:1, N:7, Rest/binary>>) when N > 0, N =< 4, byte_size(Rest) >= N ->
    <<Length:N/unit:8, Value/binary>> = Rest,
    split(Tag, Length, Value);
tlv(_) -> throw({pkcs12, <<"not enough data">>}).

split(Tag, Length, Rest) when byte_size(Rest) >= Length ->
    <<Value:Length/binary, After/binary>> = Rest,
    {Tag, Value, After};
split(_, _, _) -> throw({pkcs12, <<"not enough data">>}).
