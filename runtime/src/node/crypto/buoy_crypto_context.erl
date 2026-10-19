%% SecureContext of internalBinding('crypto') (src/crypto/crypto_context.cc):
%% the settings of TLS connections that tls.createSecureContext gathers,
%% kept as the options of OTP's ssl. tls_wrap reads them with options/2
%% when a connection starts. Keys and certificates are PEM, as OpenSSL
%% reads them, and an error is the one that OpenSSL gives.
-module(buoy_crypto_context).

-export([members/0, options/2, is_context/1, ssl_error/3, ssl_error_value/3, version_atom/1, ticket_keys/1]).
-export([set_client_cert_engine/2]).

-include_lib("public_key/include/public_key.hrl").

-define(TLS1, 16#301).
-define(TLS1_1, 16#302).
-define(TLS1_2, 16#303).
-define(TLS1_3, 16#304).

-spec members() -> [{binary(), term()}].
members() ->
    A = fun buoy_node:arg/2,
    Set = fun(Key, Value) -> fun(This, Args) -> update(This, fun(S) -> S#{Key => Value(Args)} end), undefined end end,
    Class = buoy_crypto:class(<<"SecureContext">>, fun(This, _) -> buoy_crypto:put_state(This, {secure_context, initial()}) end, [
        {<<"init">>, 3, fun(This, Args) -> init(This, A(1, Args), A(2, Args), A(3, Args)) end},
        {<<"setOptions">>, 1, Set(options, fun(Args) -> buoy_crypto:to_uint32(A(1, Args)) end)},
        {<<"setKey">>, 2, fun(This, Args) -> set_key(This, A(1, Args), A(2, Args)) end},
        {<<"setCert">>, 1, fun(This, Args) -> set_cert(This, A(1, Args)) end},
        {<<"addCACert">>, 1, fun(This, Args) -> add_ca(This, A(1, Args)) end},
        {<<"addCRL">>, 1, fun(This, Args) -> add_crl(This, A(1, Args)) end},
        %% GetOrCreateRootCertStore loads the store, and NODE_EXTRA_CA_CERTS, now.
        {<<"addRootCerts">>, 0, Set(roots, fun(_) -> is_list(roots()) end)},
        {<<"setCipherSuites">>, 1, fun(This, Args) -> set_suites(This, buoy_crypto:string(A(1, Args))) end},
        {<<"setCiphers">>, 1, fun(This, Args) -> set_ciphers(This, buoy_crypto:string(A(1, Args))) end},
        {<<"setSigalgs">>, 1, Set(sigalgs, fun(Args) -> buoy_crypto:string(A(1, Args)) end)},
        {<<"setECDHCurve">>, 1, fun(This, Args) -> set_curve(This, buoy_crypto:string(A(1, Args))) end},
        {<<"setDHParam">>, 1, fun(This, Args) -> set_dh(This, A(1, Args)) end},
        {<<"setMinProto">>, 1, Set(min, fun(Args) -> trunc(buoy_ref:to_number(A(1, Args))) end)},
        {<<"setMaxProto">>, 1, Set(max, fun(Args) -> trunc(buoy_ref:to_number(A(1, Args))) end)},
        {<<"getMinProto">>, 0, fun(This, _) -> maps:get(min, state(This)) end},
        {<<"getMaxProto">>, 0, fun(This, _) -> maps:get(max, state(This)) end},
        {<<"setSessionIdContext">>, 1, Set(session_id_context, fun(Args) -> buoy_crypto:string(A(1, Args)) end)},
        {<<"setSessionTimeout">>, 1, Set(session_timeout, fun(Args) -> trunc(buoy_ref:to_number(A(1, Args))) end)},
        {<<"setTicketKeys">>, 1, Set(ticket_keys, fun(Args) -> buoy_crypto:bytes(A(1, Args)) end)},
        {<<"getTicketKeys">>, 0, fun(This, _) -> buoy_crypto:buffer(maps:get(ticket_keys, state(This))) end},
        {<<"setAllowPartialTrustChain">>, 0, Set(partial_chain, fun(_) -> true end)},
        {<<"loadPKCS12">>, 2, fun(This, Args) -> load_pkcs12(This, A(1, Args), A(2, Args)) end},
        {<<"setClientCertEngine">>, 1, fun ?MODULE:set_client_cert_engine/2},
        {<<"getCertificate">>, 0, fun(This, _) -> certificate(This, leaf) end},
        {<<"getIssuer">>, 0, fun(This, _) -> certificate(This, issuer) end},
        {<<"close">>, 0, fun(_, _) -> undefined end}]),
    %% _external: the SSL_CTX of a SecureContext as an External; another
    %% receiver is an Illegal invocation.
    buoy_heap:define(buoy_heap:get(Class, <<"prototype">>), <<"_external">>,
                     #{get => buoy_node:fn(<<"get _external">>, 0, fun(This, _) -> _ = state(This), buoy_node:object([]) end),
                       enumerable => true, configurable => false}),
    [{<<"SecureContext">>, Class}].

%% No engine loads: ENGINE_by_id fails as OpenSSL 3 fails for an engine that
%% it cannot find, after it tried to load the engine as a shared library.
-spec set_client_cert_engine(term(), list()) -> no_return().
set_client_cert_engine(_This, _Args) ->
    Dso = <<"error:12800067:DSO support routines::could not load the shared library">>,
    NotFound = <<"error:13000084:engine routines::dso not found">>,
    E = buoy_heap:error_object('Error', Dso, <<"Error: ", Dso/binary>>),
    buoy_heap:set(E, <<"opensslErrorStack">>, buoy_heap:new_array(
        [NotFound, Dso, Dso, <<"error:13000074:engine routines::no such engine">>, NotFound, Dso])),
    erlang:error({'$throw', E}).

initial() ->
    #{min => ?TLS1_2, max => ?TLS1_3, options => 0, chains => [], keys => [], cas => none, roots => false, crls => [],
      ciphers => <<>>, suites => <<>>, sigalgs => none, curves => auto, dh => none, session_id_context => <<>>,
      session_timeout => 300, ticket_keys => crypto:strong_rand_bytes(48), partial_chain => false}.

state(This) -> buoy_crypto:state(This, secure_context).

update(This, Fun) -> buoy_crypto:put_state(This, {secure_context, Fun(state(This))}).

-spec ticket_keys(term()) -> binary().
ticket_keys(Context) -> maps:get(ticket_keys, state(Context)).

-spec is_context(term()) -> boolean().
is_context(V) ->
    buoy_heap:is_object(V) andalso buoy_heap:private_find(V, {'#', buoy_crypto, secure_context}) =/= error.

fail(Code, Message) -> buoy_crypto:fail({code, 'Error', Code, Message}).

%% init(secureProtocol, minVersion, maxVersion): a secureProtocol method
%% such as 'TLSv1_2_method' pins the version, as SSL_CTX_new does.
init(This, Protocol, Min, Max) ->
    {Lo, Hi} = case Protocol of
        undefined -> {trunc(buoy_ref:to_number(Min)), trunc(buoy_ref:to_number(Max))};
        _ -> method(buoy_crypto:string(Protocol))
    end,
    update(This, fun(S) -> S#{min := Lo, max := Hi} end),
    undefined.

method(Name) ->
    Base = hd(binary:split(Name, [<<"_server_method">>, <<"_client_method">>, <<"_method">>])),
    case Base of
        <<"TLS">> -> {?TLS1, ?TLS1_3};
        <<"SSLv23">> -> {?TLS1, ?TLS1_3};
        <<"TLSv1">> -> {?TLS1, ?TLS1};
        <<"TLSv1_1">> -> {?TLS1_1, ?TLS1_1};
        <<"TLSv1_2">> -> {?TLS1_2, ?TLS1_2};
        <<"SSLv2">> -> fail(<<"ERR_TLS_INVALID_PROTOCOL_METHOD">>, <<"SSLv2 methods disabled">>);
        <<"SSLv3">> -> fail(<<"ERR_TLS_INVALID_PROTOCOL_METHOD">>, <<"SSLv3 methods disabled">>);
        _ -> fail(<<"ERR_TLS_INVALID_PROTOCOL_METHOD">>, <<"Unknown method: ", Name/binary>>)
    end.

-spec version_atom(integer()) -> atom().
version_atom(?TLS1) -> tlsv1;
version_atom(?TLS1_1) -> 'tlsv1.1';
version_atom(?TLS1_2) -> 'tlsv1.2';
version_atom(_) -> 'tlsv1.3'.

%%% Keys and certificates

pem(V) -> buoy_crypto:data(V, undefined).

%% setKey(key, passphrase): the first private key of the PEM text.
set_key(This, Key, Passphrase) ->
    Pass = case Passphrase of
        undefined -> none;
        null -> none;
        P -> binary_to_list(buoy_crypto:data(P, undefined))
    end,
    Entries = [E || {Type, _, _} = E <- public_key:pem_decode(pem(Key)),
                    lists:member(Type, ['RSAPrivateKey', 'DSAPrivateKey', 'ECPrivateKey', 'PrivateKeyInfo',
                                        'EncryptedPrivateKeyInfo'])],
    case Entries of
        [] -> buoy_crypto:throw_openssl(decoder_unsupported);
        [Entry | _] ->
            Decoded = decode_key(Entry, Pass),
            %% SSL_CTX_use_PrivateKey checks the key against the certificate
            %% of its algorithm's slot.
            case [Leaf || [Leaf | _] <- maps:get(chains, state(This)), matches(Leaf, Decoded)] of
                [] -> ok;
                Leaves ->
                    key_matches(lists:last(Leaves), Decoded) orelse
                        erlang:error({'$throw', ssl_error_value(16#74, <<"key values mismatch">>, x509)})
            end,
            update(This, fun(S) -> S#{keys := maps:get(keys, S) ++ [Decoded]} end)
    end,
    undefined.

%% Whether the private key Key holds the public key of the certificate.
key_matches(Cert, {Type, Der}) ->
    try
        Private = public_key:der_decode(Type, Der),
        #'OTPCertificate'{tbsCertificate = #'OTPTBSCertificate'{subjectPublicKeyInfo = Spki}} = public_key:pkix_decode_cert(Cert, otp),
        #'OTPSubjectPublicKeyInfo'{subjectPublicKey = Public} = Spki,
        case {Private, Public} of
            {#'RSAPrivateKey'{modulus = N, publicExponent = E}, #'RSAPublicKey'{modulus = N, publicExponent = E}} -> true;
            {#'RSAPrivateKey'{}, _} -> false;
            {#'ECPrivateKey'{publicKey = Point}, #'ECPoint'{point = Point}} -> true;
            {#'ECPrivateKey'{}, _} -> false;
            _ -> true
        end
    catch
        _:_ -> true
    end.

%% The key option of ssl: {Type, Der} of a key that is not encrypted.
decode_key({Type, Der, not_encrypted}, _) when Type =/= 'EncryptedPrivateKeyInfo' ->
    {Type, Der};
decode_key(_, none) ->
    %% SecureContext's password callback gives an empty passphrase.
    buoy_crypto:throw_openssl(bad_decrypt);
decode_key(Entry, Pass) ->
    try public_key:pem_entry_decode(Entry, Pass) of
        Record -> {element(1, Record), public_key:der_encode(element(1, Record), Record)}
    catch
        _:_ -> buoy_crypto:throw_openssl(bad_decrypt)
    end.

%% setCert(cert): a chain, its leaf first.
set_cert(This, Cert) ->
    case certificates(Cert) of
        [] ->
            buoy_crypto:throw_openssl(pem_no_start_line);
        [Leaf | _] = Chain ->
            strong_enough(Leaf, security_level(maps:get(ciphers, state(This)))) orelse
                erlang:error({'$throw', ssl_error_value(16#18F, <<"ee key too small">>, ssl)}),
            update(This, fun(S) -> S#{chains := maps:get(chains, S) ++ [Chain]} end)
    end,
    undefined.

%% The security level of a cipher list's @SECLEVEL=n, or OpenSSL 3's
%% default 2, which getOpenSSLSecLevelCrypto reports.
security_level(Ciphers) ->
    case re:run(Ciphers, <<"@SECLEVEL=([0-5])">>, [{capture, all_but_first, binary}]) of
        {match, [Level]} -> binary_to_integer(Level);
        nomatch -> 2
    end.

%% SSL_CTX_use_certificate refuses a leaf whose key is below the level:
%% 80, 112, 128, 192, or 256 bits of security, the RSA or DSA modulus and
%% the EC field sizes of SSL_CTX_set_security_level(3).
strong_enough(_Leaf, 0) ->
    true;
strong_enough(Leaf, Level) ->
    {Modulus, Field} = lists:nth(Level, [{1024, 160}, {2048, 224}, {3072, 256}, {7680, 384}, {15360, 512}]),
    try public_key:pkix_decode_cert(Leaf, otp) of
        #'OTPCertificate'{tbsCertificate = #'OTPTBSCertificate'{subjectPublicKeyInfo = Spki}} ->
            case Spki#'OTPSubjectPublicKeyInfo'.subjectPublicKey of
                #'RSAPublicKey'{modulus = N} -> bit_length(N) >= Modulus;
                #'ECPoint'{point = <<4, Coordinates/binary>>} -> byte_size(Coordinates) * 4 >= Field;
                _ -> true
            end
    catch
        _:_ -> true
    end.

bit_length(N) -> length(integer_to_list(N, 2)).

%% The certificates of a PEM text, as PEM_read_bio_X509_AUX reads them:
%% under CERTIFICATE, X509 CERTIFICATE, and TRUSTED CERTIFICATE, whose
%% DER ends with trust settings after the certificate.
certificates(V) ->
    Pem = binary:replace(pem(V), [<<"TRUSTED CERTIFICATE">>, <<"X509 CERTIFICATE">>], <<"CERTIFICATE">>, [global]),
    [first_element(Der) || {'Certificate', Der, _} <- public_key:pem_decode(Pem)].

first_element(<<16#30, 0:1, Length:7, _/binary>> = Der) -> binary:part(Der, 0, min(2 + Length, byte_size(Der)));
first_element(<<16#30, 1:1, N:7, Rest/binary>> = Der) when byte_size(Rest) >= N ->
    <<Length:N/unit:8, _/binary>> = Rest,
    binary:part(Der, 0, min(2 + N + Length, byte_size(Der)));
first_element(Der) -> Der.

%% loadPKCS12(pfx, passphrase): the key and its certificate, with the other
%% certificates of the PFX as its chain and as trusted CAs, as
%% SecureContext::LoadPKCS12 does. Its errors are plain, with OpenSSL's text.
load_pkcs12(This, Pfx, Passphrase) ->
    Pass = case Passphrase of
        undefined -> none;
        P -> buoy_crypto:bytes(P)
    end,
    case buoy_crypto_pkcs12:parse(buoy_crypto:bytes(Pfx), Pass) of
        {ok, Key, Leaf, Extra} ->
            update(This, fun(#{chains := Chains, keys := Keys, cas := Cas} = S) ->
                Trusted = case Cas of none -> roots() ++ Extra; _ -> Cas ++ Extra end,
                S#{chains := Chains ++ [[Leaf | Extra]], keys := Keys ++ [Key], cas := Trusted}
            end);
        {error, unsupported} ->
            fail(<<"ERR_CRYPTO_UNSUPPORTED_OPERATION">>, <<"Unsupported PKCS12 PFX data">>);
        {error, Reason} ->
            erlang:error({'$throw', buoy_heap:error_object('Error', Reason, <<"Error: ", Reason/binary>>)})
    end,
    undefined.

%% addCACert after addRootCerts adds to a copy of the root store, as
%% GetCertStoreOwnedByThisSecureContext does, so the roots stay trusted.
add_ca(This, Cert) ->
    Ders = certificates(Cert),
    update(This, fun(S) -> S#{cas := owned_cas(S) ++ Ders} end),
    undefined.

owned_cas(#{cas := none, roots := true}) -> roots();
owned_cas(#{cas := none}) -> [];
owned_cas(#{cas := Cas}) -> Cas.

add_crl(This, Crl) ->
    case [Der || {'CertificateList', Der, _} <- public_key:pem_decode(pem(Crl))] of
        [] -> buoy_crypto:throw_openssl(pem_no_start_line);
        Ders -> update(This, fun(S) -> S#{crls := maps:get(crls, S) ++ Ders} end)
    end,
    undefined.

%% getCertificate() and getIssuer(): the DER of the leaf, or of its issuer
%% in the chain, or null.
certificate(This, Which) ->
    case {Which, maps:get(chains, state(This))} of
        {leaf, [[Leaf | _] | _]} -> buoy_crypto:buffer(Leaf);
        {issuer, [[_, Issuer | _] | _]} -> buoy_crypto:buffer(Issuer);
        _ -> null
    end.

%%% Ciphers and groups

%% setCiphers(list): the TLS 1.2 suites of an OpenSSL cipher list. A list
%% with no known suite fails, as SSL_CTX_set_cipher_list does.
set_ciphers(This, List) ->
    case List =:= <<>> orelse suites(List, 'tlsv1.2') =/= [] of
        true -> update(This, fun(S) -> S#{ciphers := List} end);
        false -> erlang:error({'$throw', ssl_error_value(16#B9, <<"no cipher match">>, ssl)})
    end,
    undefined.

%% setCipherSuites(list): TLS 1.3 suites, each one known, as
%% SSL_CTX_set_ciphersuites requires.
set_suites(This, List) ->
    Names = binary:split(List, <<":">>, [global, trim_all]),
    Known = [N || N <- Names, [C || #{key_exchange := any} = C <- suites(N, 'tlsv1.3')] =/= []],
    case List =:= <<>> orelse length(Known) =:= length(Names) of
        true -> update(This, fun(S) -> S#{suites := List} end);
        false -> erlang:error({'$throw', ssl_error_value(16#B9, <<"no cipher match">>, ssl)})
    end,
    undefined.

%% The suites of an OpenSSL cipher string, as SSL_CTX_set_cipher_list reads
%% it: names and aliases joined with +, each one added, or removed with -,
%% banned with !, or moved to the end with +; @ directives such as
%% @SECLEVEL=0 have no meaning for ssl. An unknown word selects nothing.
suites(List, Version) ->
    Universe = universe(Version),
    Words = [hd(binary:split(W, <<"@">>)) || W <- binary:split(List, [<<":">>, <<",">>, <<" ">>], [global, trim_all])],
    {Selected, _Banned} = lists:foldl(fun(Word, Acc) -> cipher_word(Word, Universe, Acc) end, {[], []}, Words),
    Selected.

universe(Version) ->
    Key = {?MODULE, universe, Version},
    case persistent_term:get(Key, none) of
        none ->
            All = lists:usort(ssl:cipher_suites(all, Version) ++ ssl:cipher_suites(exclusive, Version))
                ++ ssl:cipher_suites(anonymous, Version),
            %% The order of ssl's defaults first, as OpenSSL orders by strength.
            Default = ssl:cipher_suites(default, Version),
            U = Default ++ [C || C <- dedup(All), not lists:member(C, Default)],
            persistent_term:put(Key, U),
            U;
        U -> U
    end.

dedup(List) -> dedup(List, #{}).
dedup([H | T], Seen) when is_map_key(H, Seen) -> dedup(T, Seen);
dedup([H | T], Seen) -> [H | dedup(T, Seen#{H => true})];
dedup([], _) -> [].

cipher_word(<<>>, _, Acc) -> Acc;
cipher_word(<<"!", Word/binary>>, U, {Selected, Banned}) ->
    Match = matching(Word, U),
    {[C || C <- Selected, not lists:member(C, Match)], Banned ++ Match};
cipher_word(<<"-", Word/binary>>, U, {Selected, Banned}) ->
    Match = matching(Word, U),
    {[C || C <- Selected, not lists:member(C, Match)], Banned};
cipher_word(<<"+", Word/binary>>, U, {Selected, Banned}) ->
    Match = matching(Word, U),
    {[C || C <- Selected, not lists:member(C, Match)] ++ [C || C <- Selected, lists:member(C, Match)], Banned};
cipher_word(Word, U, {Selected, Banned}) ->
    Added = [C || C <- matching(Word, U), not lists:member(C, Selected), not lists:member(C, Banned)],
    {Selected ++ Added, Banned}.

%% The suites of Universe that each part of A+B matches. ssl lists no NULL
%% cipher, so a name that matches none of them may still name one of
%% OpenSSL's table. str_to_suite also parses names that no suite has, such
%% as DHE-RSA-AES256-SHA384, which only a real suite's code passes.
matching(Word, Universe) ->
    Parts = binary:split(Word, <<"+">>, [global, trim_all]),
    case lists:foldl(fun(Part, Acc) -> [C || C <- Acc, matches_part(Part, C)] end, Universe, Parts) of
        [] when length(Parts) =:= 1 -> named_suite(Word);
        Match -> Match
    end.

named_suite(Name) ->
    case cipher_alias(Name) of
        {ok, _} -> [];
        error ->
            try ssl:str_to_suite(binary_to_list(Name)) of
                #{cipher := null} = Suite -> _ = ssl_cipher_format:suite_map_to_bin(Suite), [Suite];
                _ -> []
            catch
                _:_ -> []
            end
    end.

%% A name matches as OpenSSL compares it, case and all: its OpenSSL or
%% IANA name.
matches_part(Part, Suite) ->
    case cipher_alias(Part) of
        {ok, Test} -> Test(Suite);
        error ->
            Name = binary_to_list(Part),
            (try ssl:suite_to_openssl_str(Suite) catch _:_ -> none end) =:= Name
                orelse (try ssl:suite_to_str(Suite) catch _:_ -> none end) =:= Name
    end.

kex(#{key_exchange := K}) -> K.
cipher_of(#{cipher := C}) -> C.
mac(#{mac := M}) -> M.

is_anon(S) -> lists:member(kex(S), [dh_anon, ecdh_anon, psk, dhe_psk, ecdhe_psk, rsa_psk, srp_anon]).
is_null(S) -> cipher_of(S) =:= null.
is_aes(S) -> lists:member(cipher_of(S), [aes_128_cbc, aes_256_cbc, aes_128_gcm, aes_256_gcm, aes_128_ccm, aes_256_ccm,
                                         aes_128_ccm_8, aes_256_ccm_8]).

cipher_alias(<<"ALL">>) -> {ok, fun(S) -> not is_null(S) end};
cipher_alias(<<"DEFAULT">>) -> {ok, fun(S) -> not is_null(S) andalso not is_anon(S) end};
cipher_alias(<<"COMPLEMENTOFDEFAULT">>) -> {ok, fun(S) -> is_anon(S) andalso not is_null(S) end};
cipher_alias(<<"COMPLEMENTOFALL">>) -> {ok, fun is_null/1};
cipher_alias(<<"HIGH">>) -> {ok, fun(S) -> is_aes(S) orelse cipher_of(S) =:= chacha20_poly1305 end};
cipher_alias(<<"MEDIUM">>) -> {ok, fun(S) -> lists:member(cipher_of(S), [rc4_128, seed_cbc]) end};
cipher_alias(<<"LOW">>) -> {ok, fun(S) -> lists:member(cipher_of(S), [des_cbc]) end};
cipher_alias(<<"EXPORT">>) -> {ok, fun(_) -> false end};
cipher_alias(<<"aNULL">>) -> {ok, fun(S) -> lists:member(kex(S), [dh_anon, ecdh_anon]) end};
cipher_alias(<<"eNULL">>) -> {ok, fun is_null/1};
cipher_alias(<<"NULL">>) -> {ok, fun is_null/1};
cipher_alias(<<"RSA">>) -> {ok, fun(S) -> kex(S) =:= rsa end};
cipher_alias(<<"kRSA">>) -> {ok, fun(S) -> kex(S) =:= rsa end};
cipher_alias(<<"aRSA">>) -> {ok, fun(S) -> lists:member(kex(S), [rsa, dhe_rsa, ecdhe_rsa, srp_rsa]) end};
cipher_alias(<<"ECDSA">>) -> {ok, fun(S) -> lists:member(kex(S), [ecdhe_ecdsa, ecdh_ecdsa]) end};
cipher_alias(<<"aECDSA">>) -> {ok, fun(S) -> lists:member(kex(S), [ecdhe_ecdsa, ecdh_ecdsa]) end};
cipher_alias(<<"DSS">>) -> {ok, fun(S) -> kex(S) =:= dhe_dss end};
cipher_alias(<<"aDSS">>) -> {ok, fun(S) -> kex(S) =:= dhe_dss end};
cipher_alias(E) when E =:= <<"ECDHE">>; E =:= <<"EECDH">>; E =:= <<"kECDHE">>; E =:= <<"kEECDH">> ->
    {ok, fun(S) -> lists:member(kex(S), [ecdhe_rsa, ecdhe_ecdsa, ecdhe_psk]) end};
cipher_alias(D) when D =:= <<"DHE">>; D =:= <<"EDH">>; D =:= <<"kDHE">>; D =:= <<"kEDH">> ->
    {ok, fun(S) -> lists:member(kex(S), [dhe_rsa, dhe_dss, dhe_psk]) end};
cipher_alias(<<"AECDH">>) -> {ok, fun(S) -> kex(S) =:= ecdh_anon end};
cipher_alias(<<"ADH">>) -> {ok, fun(S) -> kex(S) =:= dh_anon end};
cipher_alias(<<"PSK">>) -> {ok, fun(S) -> lists:member(kex(S), [psk, dhe_psk, ecdhe_psk, rsa_psk]) end};
cipher_alias(<<"kPSK">>) -> {ok, fun(S) -> kex(S) =:= psk end};
cipher_alias(<<"SRP">>) -> {ok, fun(S) -> lists:member(kex(S), [srp_anon, srp_rsa, srp_dss]) end};
cipher_alias(<<"AES">>) -> {ok, fun is_aes/1};
cipher_alias(<<"AESGCM">>) -> {ok, fun(S) -> lists:member(cipher_of(S), [aes_128_gcm, aes_256_gcm]) end};
cipher_alias(<<"AESCCM">>) -> {ok, fun(S) -> lists:member(cipher_of(S), [aes_128_ccm, aes_256_ccm, aes_128_ccm_8, aes_256_ccm_8]) end};
cipher_alias(<<"AES128">>) -> {ok, fun(S) -> lists:member(cipher_of(S), [aes_128_cbc, aes_128_gcm, aes_128_ccm, aes_128_ccm_8]) end};
cipher_alias(<<"AES256">>) -> {ok, fun(S) -> lists:member(cipher_of(S), [aes_256_cbc, aes_256_gcm, aes_256_ccm, aes_256_ccm_8]) end};
cipher_alias(<<"CHACHA20">>) -> {ok, fun(S) -> cipher_of(S) =:= chacha20_poly1305 end};
cipher_alias(<<"3DES">>) -> {ok, fun(S) -> cipher_of(S) =:= '3des_ede_cbc' end};
cipher_alias(<<"DES">>) -> {ok, fun(S) -> cipher_of(S) =:= des_cbc end};
cipher_alias(<<"RC4">>) -> {ok, fun(S) -> cipher_of(S) =:= rc4_128 end};
cipher_alias(<<"CAMELLIA">>) -> {ok, fun(_) -> false end};
cipher_alias(<<"IDEA">>) -> {ok, fun(_) -> false end};
cipher_alias(<<"SEED">>) -> {ok, fun(S) -> cipher_of(S) =:= seed_cbc end};
cipher_alias(<<"MD5">>) -> {ok, fun(S) -> mac(S) =:= md5 end};
cipher_alias(Sha) when Sha =:= <<"SHA">>; Sha =:= <<"SHA1">> -> {ok, fun(S) -> mac(S) =:= sha end};
cipher_alias(<<"SHA256">>) -> {ok, fun(S) -> mac(S) =:= sha256 orelse maps:get(prf, S) =:= sha256 end};
cipher_alias(<<"SHA384">>) -> {ok, fun(S) -> mac(S) =:= sha384 orelse maps:get(prf, S) =:= sha384 end};
cipher_alias(<<"TLSv1.2">>) -> {ok, fun(S) -> mac(S) =:= aead orelse lists:member(maps:get(prf, S), [sha256, sha384]) end};
cipher_alias(V) when V =:= <<"TLSv1">>; V =:= <<"SSLv3">>; V =:= <<"TLSv1.0">> -> {ok, fun(S) -> maps:get(prf, S) =:= default_prf end};
cipher_alias(_) -> error.

%% setECDHCurve(curve): 'auto', or a list such as 'P-256:X25519'.
set_curve(This, <<"auto">>) ->
    update(This, fun(S) -> S#{curves := auto} end),
    undefined;
set_curve(This, List) ->
    Curves = [curve(N) || N <- binary:split(List, <<":">>, [global, trim_all])],
    case lists:member(unknown, Curves) orelse Curves =:= [] of
        true -> fail(<<"ERR_CRYPTO_OPERATION_FAILED">>, <<"Failed to set ECDH curve">>);
        false -> update(This, fun(S) -> S#{curves := Curves} end)
    end,
    undefined.

%% A group of an OpenSSL curve list: its NIST, SECG, or X9.62 name, as
%% SSL_CTX_set1_curves_list reads it, among the groups that ssl knows.
curve(Name) ->
    Atom = case string:lowercase(Name) of
        <<"p-256">> -> secp256r1;
        <<"prime256v1">> -> secp256r1;
        <<"p-384">> -> secp384r1;
        <<"p-521">> -> secp521r1;
        <<"p-224">> -> secp224r1;
        <<"p-192">> -> secp192r1;
        <<"prime192v1">> -> secp192r1;
        Lower -> Lower
    end,
    case [E || E <- ssl:eccs(), E =:= Atom orelse string:lowercase(atom_to_binary(E)) =:= Atom] of
        [Group | _] -> Group;
        [] -> unknown
    end.

%% setDHParam(dh): 'auto' (true) or PEM parameters; small ones warn.
set_dh(This, true) ->
    update(This, fun(S) -> S#{dh := auto} end),
    undefined;
set_dh(This, Dh) ->
    case [Der || {'DHParameter', Der, _} <- public_key:pem_decode(pem(Dh))] of
        [] ->
            buoy_crypto:throw_openssl(pem_no_start_line);
        [Der | _] ->
            update(This, fun(S) -> S#{dh := Der} end),
            {'DHParameter', P, _, _} = public_key:der_decode('DHParameter', Der),
            Bits = bit_size(binary:encode_unsigned(P)),
            case Bits < 2048 of
                true -> buoy_node:string(["DH parameter is less than 2048 bits"]);
                false -> undefined
            end
    end.

%%% The options of ssl

%% The ssl options of a connection with the context Context. Role is
%% client or server.
-spec options(term(), client | server) -> [term()].
options(Context, Role) ->
    S = state(Context),
    #{min := Min, max := Max, options := Flags} = S,
    %% secureOptions: SSL_OP_NO_TLSv1 to SSL_OP_NO_TLSv1_3 drop versions.
    Dropped = [V || {V, Bit} <- [{?TLS1, 16#04000000}, {?TLS1 + 1, 16#10000000}, {?TLS1_2, 16#08000000}, {?TLS1_3, 16#20000000}],
                    Flags band Bit =/= 0],
    Versions = [version_atom(V) || V <- lists:seq(min(Max, ?TLS1_3), max(Min, ?TLS1), -1), V >= ?TLS1,
                                   not lists:member(V, Dropped)],
    CertsKeys = pairs(maps:get(chains, S), maps:get(keys, S)),
    Ciphers = case {maps:get(ciphers, S), maps:get(suites, S)} of
        {<<>>, <<>>} -> [];
        {List, Suites} ->
            Twelve = case List of <<>> -> []; _ -> suites(List, 'tlsv1.2') end,
            %% ssl's lists for TLS 1.3 hold the TLS 1.2 suites too; the
            %% TLS 1.3 ones agree on no key exchange (any).
            Thirteen = [C || #{key_exchange := any} = C <- case Suites of
                                                               <<>> -> ssl:cipher_suites(default, 'tlsv1.3');
                                                               _ -> suites(Suites, 'tlsv1.3')
                                                           end],
            [{ciphers, Thirteen ++ Twelve}]
    end,
    %% A server with no certificate can only offer anonymous suites, which
    %% ssl requires to start; a client that offers none of them meets no
    %% shared cipher, as with OpenSSL.
    NoCert = Role =:= server andalso CertsKeys =:= [],
    Anonymous = [{ciphers, ssl:cipher_suites(anonymous, 'tlsv1.2')} || NoCert],
    [{versions, case NoCert of true -> Versions -- ['tlsv1.3']; false -> Versions end}]
        ++ Anonymous
        ++ [{certs_keys, CertsKeys} || CertsKeys =/= []]
        ++ [{cacerts, cacerts(S)}]
        ++ [C || C <- Ciphers, not NoCert]
        ++ [{eccs, Curves} || Curves <- [maps:get(curves, S)], Curves =/= auto]
        ++ [{dh, Dh} || Dh <- [maps:get(dh, S)], is_binary(Dh), Role =:= server]
        ++ [{partial_chain, fun(Chain) -> partial(Chain, cacerts(S)) end} || maps:get(partial_chain, S)]
        %% OpenSSL names only the ca option's certificates in a certificate
        %% request (SSL_CTX_add_client_CA), never the root store; ssl's
        %% clients send no certificate outside the names.
        ++ [{certificate_authorities, false} || Role =:= server, maps:get(cas, S) =:= none]
        %% SSL_OP_CIPHER_SERVER_PREFERENCE, which honorCipherOrder sets.
        ++ [{honor_cipher_order, true} || Role =:= server, Flags band 16#400000 =/= 0].

%% Each certificate chain with the key of its algorithm.
pairs(Chains, Keys) ->
    lists:filtermap(fun([Leaf | _] = Chain) ->
        case [K || K <- Keys, matches(Leaf, K)] ++ Keys of
            [Key | _] -> {true, #{cert => Chain, key => Key}};
            [] -> false
        end
    end, Chains).

matches(Cert, Key) ->
    try cert_algorithm(Cert) =:= key_algorithm(Key) catch _:_ -> false end.

cert_algorithm(Cert) ->
    #'OTPCertificate'{tbsCertificate = #'OTPTBSCertificate'{subjectPublicKeyInfo = Spki}} = public_key:pkix_decode_cert(Cert, otp),
    #'OTPSubjectPublicKeyInfo'{algorithm = #'PublicKeyAlgorithm'{algorithm = Algorithm}} = Spki,
    Algorithm.

%% A PKCS #8 key decodes to the record of its algorithm.
key_algorithm({Type, Der}) ->
    case public_key:der_decode(Type, Der) of
        #'RSAPrivateKey'{} -> {1,2,840,113549,1,1,1};
        #'ECPrivateKey'{} -> {1,2,840,10045,2,1};
        #'DSAPrivateKey'{} -> {1,2,840,10040,4,1};
        _ -> none
    end.

cacerts(#{cas := none, roots := true}) -> roots();
cacerts(#{cas := none}) -> roots();
cacerts(#{cas := Cas}) -> Cas.

%% Node's root store (NewRootCertStore): the store that
%% tls.setDefaultCACertificates set, or the bundled roots, with the system
%% store under --use-system-ca and NODE_EXTRA_CA_CERTS. Parsed once per VM.
roots() ->
    case buoy_crypto_roots:user_roots() of
        none ->
            case persistent_term:get({?MODULE, roots}, none) of
                none ->
                    Bundled = [Der || Pem <- buoy_crypto_root_certs:pems(), {'Certificate', Der, _} <- public_key:pem_decode(Pem)],
                    Ders = Bundled ++ buoy_crypto_roots:default_extras(),
                    persistent_term:put({?MODULE, roots}, Ders),
                    Ders;
                Ders -> Ders
            end;
        User -> User
    end.

%% allowPartialTrustChain: an intermediate in the store anchors the chain.
partial(Chain, Cas) ->
    case [C || C <- Chain, lists:member(C, Cas)] of
        [Anchor | _] -> {trusted_ca, Anchor};
        [] -> unknown_ca
    end.

%% The error of OpenSSL for the reason Number of Lib, with its library,
%% reason, and code, as Decorate sets them: ERR_SSL_NO_CIPHER_MATCH.
-spec ssl_error_value(integer(), binary(), ssl | x509) -> term().
ssl_error_value(Number, Text, Lib) ->
    Message = ssl_error(Number, Text, Lib),
    {LibName, Prefix} = case Lib of
        ssl -> {<<"SSL routines">>, <<"SSL_">>};
        x509 -> {<<"x509 certificate routines">>, <<"OSSL_X509_">>}
    end,
    E = buoy_heap:error_object('Error', Message, <<"Error: ", Message/binary>>),
    Code = <<"ERR_", Prefix/binary, (string:uppercase(binary:replace(Text, <<" ">>, <<"_">>, [global])))/binary>>,
    [buoy_heap:set(E, K, V) || {K, V} <- [{<<"library">>, LibName}, {<<"reason">>, Text}, {<<"code">>, Code}]],
    E.

%% The text of an error of OpenSSL's SSL library (20) or another one.
-spec ssl_error(integer(), binary(), ssl | x509) -> binary().
ssl_error(Number, Text, Lib) ->
    {LibNumber, LibName} = case Lib of
        ssl -> {20, <<"SSL routines">>};
        x509 -> {11, <<"x509 certificate routines">>}
    end,
    iolist_to_binary(io_lib:format("error:~8.16.0B:~s::~s", [(LibNumber bsl 23) bor Number, LibName, Text])).
