%% PKCS #12 (RFC 7292), the PFX files of SecureContext.loadPKCS12 in
%% src/crypto/crypto_context.cc: d2i_PKCS12_bio, then PKCS12_parse, which
%% checks the MAC, decrypts the bags, and takes the first private key and
%% the certificate that holds its public key. The other certificates are
%% the extra ones. A file may be BER, as Windows writes it.
-module(buoy_crypto_pkcs12).

-export([parse/2]).

-define(DATA, {1,2,840,113549,1,7,1}).
-define(ENCRYPTED_DATA, {1,2,840,113549,1,7,6}).
-define(KEY_BAG, {1,2,840,113549,1,12,10,1,1}).
-define(SHROUDED_KEY_BAG, {1,2,840,113549,1,12,10,1,2}).
-define(CERT_BAG, {1,2,840,113549,1,12,10,1,3}).
-define(SAFE_CONTENTS_BAG, {1,2,840,113549,1,12,10,1,6}).
-define(X509_CERTIFICATE, {1,2,840,113549,1,9,22,1}).
-define(PBMAC1, {1,2,840,113549,1,5,14}).
-define(PBKDF2, {1,2,840,113549,1,5,12}).

-type parsed() :: #{key := {'PrivateKeyInfo', binary()}, cert := binary(), extra := [binary()]}.

%% The private key, as the PrivateKeyInfo DER that ssl takes, its
%% certificate, and the extra certificates of the PFX Pfx under Passphrase,
%% which is null when the caller gives none. A failure throws what
%% LoadPKCS12 throws: the reason of the first OpenSSL error, Node's error
%% for unsupported algorithms, or an error that names the missing part.
-spec parse(binary(), binary() | null) -> parsed().
parse(Pfx, Passphrase) ->
    {AuthSafe, Mac} = read(Pfx),
    Password = verify_mac(AuthSafe, Mac, Passphrase),
    Bags = lists:append([bags(Info, Password) || Info <- sequence(AuthSafe)]),
    Keys = [Key || {key, Key} <- Bags],
    Certs = [Cert || {cert, Cert} <- Bags],
    Key = case Keys of
        [] -> operation_failed(<<"Unable to load private key from PFX data">>);
        [K | _] -> K
    end,
    case lists:partition(fun(Cert) -> holds_key(Cert, Key) end, Certs) of
        {[Cert | Others], Rest} -> #{key => {'PrivateKeyInfo', Key}, cert => Cert, extra => Others ++ Rest};
        {[], _} -> operation_failed(<<"Unable to load certificate from PFX data">>)
    end.

%%% Reading

%% The content of the authSafe, and the MacData, as d2i_PKCS12_bio reads a
%% PFX: the whole object first, as asn1_d2i_read_bio does, then its parts.
read(Pfx) ->
    Der = case ber_to_der(Pfx) of
        {ok, D} -> D;
        truncated -> reason(<<"not enough data">>)
    end,
    case buoy_crypto_der:decode(Der) of
        {ok, {seq, [{int, 3}, {seq, [{oid, ?DATA}, {ctx, 0, [{octets, AuthSafe}]}]} | Mac]}} -> {AuthSafe, Mac};
        _ -> reason(<<"wrong tag">>)
    end.

%% The values of a SEQUENCE OF in Der.
sequence(Der) ->
    case buoy_crypto_der:decode(Der) of
        {ok, {seq, Values}} -> Values;
        _ -> reason(<<"wrong tag">>)
    end.

%% The bags of a ContentInfo of the authSafe: data holds SafeContents, and
%% encryptedData holds them under the password. PKCS12_parse skips others.
bags({seq, [{oid, ?DATA}, {ctx, 0, [{octets, Contents}]}]}, Password) ->
    safe_bags(Contents, Password);
bags({seq, [{oid, ?ENCRYPTED_DATA}, {ctx, 0, [{seq, [{int, _}, {seq, [{oid, ?DATA}, Algorithm | Content]} | _]}]}]},
     Password) ->
    %% A BER encryptedContent may be constructed, of OCTET STRING parts.
    Encrypted = case Content of
        [{ctx_prim, 0, Bytes}] -> Bytes;
        [{ctx, 0, Parts}] -> iolist_to_binary([Bytes || {octets, Bytes} <- Parts]);
        [] -> <<>>
    end,
    safe_bags(decrypt(Algorithm, Encrypted, Password), Password);
bags(_, _) ->
    [].

safe_bags(Der, Password) ->
    lists:append([bag(Bag, Password) || Bag <- sequence(Der)]).

bag({seq, [{oid, ?KEY_BAG}, {ctx, 0, [Info]} | _]}, _) ->
    [{key, buoy_crypto_der:encode(Info)}];
bag({seq, [{oid, ?SHROUDED_KEY_BAG}, {ctx, 0, [{seq, [Algorithm, {octets, Encrypted}]}]} | _]}, Password) ->
    [{key, decrypt(Algorithm, Encrypted, Password)}];
bag({seq, [{oid, ?CERT_BAG}, {ctx, 0, [{seq, [{oid, ?X509_CERTIFICATE}, {ctx, 0, [{octets, Cert}]}]}]} | _]}, _) ->
    [{cert, Cert}];
bag({seq, [{oid, ?SAFE_CONTENTS_BAG}, {ctx, 0, [{seq, Bags}]} | _]}, Password) ->
    lists:append([bag(B, Password) || B <- Bags]);
bag(_, _) ->
    [].

decrypt(Algorithm, Data, Password) ->
    try buoy_crypto_pkey:pbe_decrypt(Algorithm, Data, Password)
    catch
        error:{crypto_failure, {openssl, unsupported}} -> unsupported();
        error:{crypto_failure, {openssl, _}} -> reason(<<"bad decrypt">>)
    end.

%% Whether the certificate Cert holds the public key of the PrivateKeyInfo
%% Key, as X509_check_private_key decides.
holds_key(Cert, Key) ->
    try buoy_crypto_x509:holds_private_key(Cert, buoy_crypto_pkey:parse_private(Key, 0, 1, undefined))
    catch error:{crypto_failure, _} -> false
    end.

%%% The MAC

%% The password that the MAC verifies with, as PKCS12_parse finds it: the
%% passphrase, or with none, no password and then the empty one. A PFX
%% without MacData takes the passphrase as it is.
verify_mac(_, [], Passphrase) ->
    Passphrase;
verify_mac(AuthSafe, [{seq, [{seq, [{seq, [{oid, Oid} | Params]}, {octets, Digest}]}, {octets, Salt} | Rest]}],
           Passphrase) ->
    Iterations = case Rest of
        [{int, I}] -> I;
        [] -> 1
    end,
    Candidates = case Passphrase of
        null -> [null, <<>>];
        <<>> -> [null, <<>>];
        _ -> [Passphrase]
    end,
    Matches = [P || P <- Candidates, mac(Oid, Params, P, Salt, Iterations, AuthSafe) =:= Digest],
    case Matches of
        [Password | _] -> Password;
        [] -> reason(<<"mac verify failure">>)
    end;
verify_mac(_, _, _) ->
    reason(<<"wrong tag">>).

%% The MAC of AuthSafe: an HMAC with the key of the PKCS #12 derivation, or
%% PBMAC1 of RFC 9579, whose key comes from PBKDF2 over the UTF-8 password.
mac(?PBMAC1, [{seq, [{seq, [{oid, ?PBKDF2}, {seq, [{octets, Salt}, {int, Iter}, {int, Length} | Prf]}]},
                     {seq, [{oid, HmacOid} | _]}]}], Password, _, _, AuthSafe) ->
    Md = md(hmac_digest(HmacOid)),
    PrfMd = case Prf of
        [{seq, [{oid, PrfOid} | _]}] -> md(hmac_digest(PrfOid));
        [] -> md(<<"sha1">>)
    end,
    Key = buoy_crypto_kdf:pbkdf2(PrfMd, utf8_password(Password), Salt, Iter, Length),
    buoy_crypto_hash:hmac(Md, Key, AuthSafe);
mac(Oid, _, Password, Salt, Iterations, AuthSafe) ->
    #{size := Size} = Md = md(digest_name(Oid)),
    Key = buoy_crypto_kdf:pkcs12(Md, 3, buoy_crypto_pkey:bmp_password(Password), Salt, Iterations, Size),
    buoy_crypto_hash:hmac(Md, Key, AuthSafe).

utf8_password(null) -> <<>>;
utf8_password(Password) -> Password.

md(Name) ->
    case buoy_crypto_hash:digest(Name) of
        {ok, Md} -> Md;
        error -> unsupported()
    end.

digest_name({1,3,14,3,2,26}) -> <<"sha1">>;
digest_name({1,2,840,113549,2,5}) -> <<"md5">>;
digest_name({2,16,840,1,101,3,4,2,4}) -> <<"sha224">>;
digest_name({2,16,840,1,101,3,4,2,1}) -> <<"sha256">>;
digest_name({2,16,840,1,101,3,4,2,2}) -> <<"sha384">>;
digest_name({2,16,840,1,101,3,4,2,3}) -> <<"sha512">>;
digest_name(_) -> unsupported().

hmac_digest({1,2,840,113549,2,7}) -> <<"sha1">>;
hmac_digest({1,2,840,113549,2,8}) -> <<"sha224">>;
hmac_digest({1,2,840,113549,2,9}) -> <<"sha256">>;
hmac_digest({1,2,840,113549,2,10}) -> <<"sha384">>;
hmac_digest({1,2,840,113549,2,11}) -> <<"sha512">>;
hmac_digest(_) -> unsupported().

%%% BER

%% The DER of the BER object at the start of Ber: definite lengths of the
%% shortest form, and constructed strings joined into one, so the DER
%% decoder reads it. An object longer than its bytes is truncated.
ber_to_der(Ber) ->
    try ber(Ber) of
        {Der, _} -> {ok, Der}
    catch
        error:_ -> truncated
    end.

ber(<<Tag, Rest0/binary>>) ->
    {Content, Rest} = case Rest0 of
        <<16#80, Inner/binary>> when Tag band 16#20 =/= 0 -> indefinite(Inner, []);
        _ ->
            {Length, Rest1} = ber_length(Rest0),
            <<C:Length/binary, R/binary>> = Rest1,
            {children(Tag, C), R}
    end,
    {tlv(Tag, Content), Rest}.

%% The children of a constructed object, joined for a constructed string.
children(Tag, C) when Tag band 16#20 =/= 0 -> join(Tag, all(C, []));
children(_, C) -> C.

all(<<>>, Acc) -> lists:reverse(Acc);
all(Bin, Acc) ->
    {Der, Rest} = ber(Bin),
    all(Rest, [Der | Acc]).

indefinite(<<0, 0, Rest/binary>>, Acc) -> {lists:reverse(Acc), Rest};
indefinite(Bin, Acc) ->
    {Der, Rest} = ber(Bin),
    indefinite(Rest, [Der | Acc]).

%% A constructed BIT STRING or OCTET STRING (0x23, 0x24) becomes primitive.
join(Tag, Children) when Tag =:= 16#23; Tag =:= 16#24 -> iolist_to_binary([content_of(C) || C <- Children]);
join(_, Children) -> iolist_to_binary(Children).

content_of(Der) ->
    {ok, Value, <<>>} = buoy_crypto_der:decode_all(Der),
    case Value of
        {octets, Bytes} -> Bytes;
        {bits, Bytes} -> Bytes
    end.

tlv(Tag, Content) when is_list(Content) -> tlv(Tag, join(Tag, Content));
tlv(Tag, Content) ->
    Primitive = case Tag of
        16#23 -> 16#03;
        16#24 -> 16#04;
        _ -> Tag
    end,
    <<Primitive, (der_length(byte_size(Content)))/binary, Content/binary>>.

ber_length(<<0:1, Length:7, Rest/binary>>) -> {Length, Rest};
ber_length(<<1:1, N:7, Rest/binary>>) when N >= 1, N =< 8 ->
    <<Length:(N * 8), Tail/binary>> = Rest,
    {Length, Tail}.

der_length(Length) when Length < 128 -> <<Length>>;
der_length(Length) ->
    Bytes = binary:encode_unsigned(Length),
    <<1:1, (byte_size(Bytes)):7, Bytes/binary>>.

%%% Errors

-spec reason(binary()) -> no_return().
reason(Text) -> buoy_crypto:fail({message, Text}).

-spec unsupported() -> no_return().
unsupported() ->
    buoy_crypto:fail({code, 'Error', <<"ERR_CRYPTO_UNSUPPORTED_OPERATION">>, <<"Unsupported PKCS12 PFX data">>}).

-spec operation_failed(binary()) -> no_return().
operation_failed(Message) ->
    buoy_crypto:fail({code, 'Error', <<"ERR_CRYPTO_OPERATION_FAILED">>, Message}).
