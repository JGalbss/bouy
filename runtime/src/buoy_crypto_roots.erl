%% The certificate stores of internalBinding('crypto') (the root store
%% functions of src/crypto/crypto_context.cc): Node's bundled roots, the
%% system store that OTP's public_key reads, NODE_EXTRA_CA_CERTS, and the
%% store that tls.setDefaultCACertificates sets.
-module(buoy_crypto_roots).

-export([members/0, user_roots/0]).

-spec members() -> [{binary(), term()}].
members() ->
    F = fun buoy_crypto:fn/3,
    [{<<"getBundledRootCertificates">>, F(<<"getBundledRootCertificates">>, 0,
                                         fun(_, _) -> buoy_heap:new_array(buoy_crypto_root_certs:pems()) end)},
     {<<"getSystemCACertificates">>, F(<<"getSystemCACertificates">>, 0,
                                      fun(_, _) -> buoy_heap:new_array([pem(D) || D <- system()]) end)},
     {<<"getExtraCACertificates">>, F(<<"getExtraCACertificates">>, 0,
                                     fun(_, _) -> buoy_heap:new_array([pem(D) || D <- extra()]) end)},
     {<<"resetRootCertStore">>, F(<<"resetRootCertStore">>, 1, fun reset/2)},
     {<<"getUserRootCertificates">>, F(<<"getUserRootCertificates">>, 0,
                                      fun(_, _) -> buoy_heap:new_array([pem(D) || D <- user_list()]) end)},
     %% The stores load on first use, so there is nothing to start early.
     {<<"startLoadingCertificatesOffThread">>, F(<<"startLoadingCertificatesOffThread">>, 0, fun(_, _) -> undefined end)}].

%% PEM_write_bio_X509.
pem(Der) -> buoy_crypto_der:pem_encode(<<"CERTIFICATE">>, Der).

%% The DER certificates of the trust store of the system.
system() ->
    try [Der || {cert, Der, _} <- public_key:cacerts_get()]
    catch
        error:_ -> []
    end.

%% The certificates of the file that NODE_EXTRA_CA_CERTS names.
extra() ->
    case os:getenv("NODE_EXTRA_CA_CERTS") of
        false -> [];
        "" -> [];
        Path ->
            case file:read_file(Path) of
                {ok, Text} -> [Der || {<<"CERTIFICATE">>, Der, _} <- buoy_crypto_der:pem_blocks(Text)];
                {error, _} -> []
            end
    end.

%% resetRootCertStore(certs): the store of the PEM texts certs, strings or
%% buffers, once each, as an X509_STORE holds them. An empty array empties
%% the store; texts with no PEM block fail, and a block that is no
%% certificate fails as PEM_read_bio_X509 does. A failure keeps the old store.
reset(_, Args) ->
    Texts = [buoy_crypto:data(P, undefined) || P <- buoy_heap:array_items(buoy_node:arg(1, Args))],
    Ders = [certificate(Der) || T <- Texts, {<<"CERTIFICATE">>, Der, _} <- buoy_crypto_der:pem_blocks(T)],
    Texts =/= [] andalso Ders =:= [] andalso
        buoy_crypto:fail_code(<<"ERR_CRYPTO_OPERATION_FAILED">>, <<"No valid certificates found in the provided array">>),
    erlang:put({?MODULE, user}, lists:uniq(Ders)),
    undefined.

certificate(Der) ->
    try public_key:pkix_decode_cert(Der, plain) of
        _ -> Der
    catch
        _:_ -> buoy_crypto:throw_openssl(pem_asn1_lib)
    end.

user_list() ->
    case user_roots() of
        none -> [];
        Ders -> Ders
    end.

%% The certificates that resetRootCertStore set, or none before a reset.
-spec user_roots() -> [binary()] | none.
user_roots() ->
    case erlang:get({?MODULE, user}) of
        undefined -> none;
        Ders -> Ders
    end.
