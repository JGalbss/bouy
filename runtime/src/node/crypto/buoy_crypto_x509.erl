%% X509Certificate and parseX509 of internalBinding('crypto')
%% (src/crypto/crypto_x509.cc and ncrypto's X509View): the fields of a
%% certificate as OpenSSL prints them, its checks of names and keys, and
%% the legacy object of tls.getPeerCertificate; and the SPKAC functions
%% of crypto_spkac.cc under crypto.Certificate.
-module(buoy_crypto_x509).

-export([members/0, certificate/1, decode/1, from_clone/1, holds_private_key/2]).

-define(SAN, {2,5,29,17}).
-define(AIA, {1,3,6,1,5,5,7,1,1}).
-define(EKU, {2,5,29,37}).
-define(BASIC, {2,5,29,19}).
-define(KEY_USAGE, {2,5,29,15}).
-define(SKID, {2,5,29,14}).
-define(AKID, {2,5,29,35}).
-define(EMAIL, {1,2,840,113549,1,9,1}).
-define(CN, {2,5,4,3}).

%% X509_CHECK_FLAG_* of the checks of names.
-define(ALWAYS_CHECK_SUBJECT, 1).
-define(NO_WILDCARDS, 2).
-define(NO_PARTIAL_WILDCARDS, 4).
-define(MULTI_LABEL_WILDCARDS, 8).
-define(SINGLE_LABEL_SUBDOMAINS, 16).
-define(NEVER_CHECK_SUBJECT, 32).

-spec members() -> [{binary(), term()}].
members() ->
    F = fun buoy_crypto:fn/3,
    [{<<"parseX509">>, F(<<"parseX509">>, 1, fun parse/2)},
     {<<"certVerifySpkac">>, F(<<"certVerifySpkac">>, 1, fun(_, Args) -> spkac(Args, fun verify_spkac/1) end)},
     {<<"certExportPublicKey">>, F(<<"certExportPublicKey">>, 1, fun(_, Args) -> spkac(Args, fun spkac_key/1) end)},
     {<<"certExportChallenge">>, F(<<"certExportChallenge">>, 1, fun(_, Args) -> spkac(Args, fun spkac_challenge/1) end)}].

%%% SPKAC

%% A function of a SignedPublicKeyAndChallenge in base64: an empty input
%% gives an empty string, and one that does not decode false or an empty
%% string.
spkac(Args, Fun) ->
    case buoy_crypto:bytes(buoy_node:arg(1, Args)) of
        <<>> -> <<>>;
        Bytes ->
            Decoded = try
                {ok, {seq, [{seq, [Spki, {tag, 16#16, Challenge}]} = Signed, {seq, [{oid, Oid} | _]}, {bits, Sig}]}} =
                    buoy_crypto_der:decode(base64:decode(string:trim(Bytes))),
                {ok, #{spki => buoy_crypto_der:encode(Spki), challenge => Challenge, sig_oid => Oid, signature => Sig,
                       tbs => buoy_crypto_der:encode(Signed)}}
            catch
                error:_ -> error
            end,
            Fun(Decoded)
    end.

verify_spkac({ok, S}) ->
    try verify_signature(S, public_key(S))
    catch
        error:{crypto_failure, _} -> false
    end;
verify_spkac(error) -> false.

spkac_key({ok, S}) ->
    try buoy_crypto:buffer(buoy_crypto_pkey:write_public(public_key(S), 1, 2))
    catch
        error:{crypto_failure, _} -> <<>>
    end;
spkac_key(error) -> <<>>.

spkac_challenge({ok, #{challenge := Challenge}}) -> buoy_crypto:buffer(Challenge);
spkac_challenge(error) -> <<>>.

%%% The certificate

%% The parts of a certificate that its methods read.
-spec decode(binary()) -> {ok, map()} | error.
decode(Der) ->
    try
        {ok, {seq, [{seq, Tbs0}, {seq, [{oid, SigOid} | SigParams]}, {bits, Signature}]}} = buoy_crypto_der:decode(Der),
        Tbs = case Tbs0 of
            [{ctx, 0, [{int, V}]} | Rest] -> [{version, V} | Rest];
            Rest -> [{version, 0} | Rest]
        end,
        [{version, Version}, {int, Serial}, _Alg, {seq, Issuer}, {seq, [NotBefore, NotAfter]}, {seq, Subject},
         Spki | Optional] = Tbs,
        Extensions = case [E || {ctx, 3, [{seq, E}]} <- Optional] of
            [E] -> [extension(X) || X <- E];
            [] -> []
        end,
        {ok, #{der => Der, version => Version, serial => Serial, issuer => Issuer, subject => Subject,
               not_before => time(NotBefore), not_after => time(NotAfter),
               spki => buoy_crypto_der:encode(Spki), extensions => Extensions,
               tbs => tbs_bytes(Der), sig_oid => SigOid, sig_params => SigParams, signature => Signature}}
    catch
        error:_ -> error
    end.

extension({seq, [{oid, Oid}, {bool, Critical}, {octets, Value}]}) -> {Oid, Critical, Value};
extension({seq, [{oid, Oid}, {octets, Value}]}) -> {Oid, false, Value}.

%% The DER of the TBSCertificate, as its signature covers it.
tbs_bytes(Der) ->
    <<16#30, Rest0/binary>> = Der,
    Rest = skip_length(Rest0),
    {ok, _, After} = buoy_crypto_der:decode_all(Rest),
    binary:part(Rest, 0, byte_size(Rest) - byte_size(After)).

skip_length(<<0:1, _:7, Rest/binary>>) -> Rest;
skip_length(<<1:1, N:7, Rest/binary>>) -> binary:part(Rest, N, byte_size(Rest) - N).

%% A Time as {{Y, M, D}, {H, Mi, S}, Fraction}.
time({tag, 16#17, <<YY:2/binary, Rest/binary>>}) ->
    Y = binary_to_integer(YY),
    time_fields(case Y >= 50 of true -> 1900 + Y; false -> 2000 + Y end, Rest);
time({tag, 16#18, <<YYYY:4/binary, Rest/binary>>}) ->
    time_fields(binary_to_integer(YYYY), Rest).

time_fields(Y, <<M:2/binary, D:2/binary, H:2/binary, Mi:2/binary, S:2/binary, Rest/binary>>) ->
    Fraction = case Rest of
        <<".", F/binary>> -> hd(binary:split(F, <<"Z">>));
        _ -> <<>>
    end,
    {{Y, binary_to_integer(M), binary_to_integer(D)},
     {binary_to_integer(H), binary_to_integer(Mi), binary_to_integer(S)}, Fraction}.

%% parseX509(buffer): PEM, or else DER (X509Pointer::Parse).
parse(_, Args) ->
    Bytes = buoy_crypto:bytes(buoy_node:arg(1, Args)),
    Der = case buoy_crypto_der:pem_decode(Bytes, <<"CERTIFICATE">>) of
        {ok, D, _} -> D;
        error ->
            case buoy_crypto_der:pem_decode(Bytes, <<"TRUSTED CERTIFICATE">>) of
                {ok, D, _} -> D;
                error -> Bytes
            end
    end,
    case decode(Der) of
        {ok, Cert} -> handle(Cert);
        error -> buoy_crypto:fail({openssl, pem_no_start_line})
    end.

%% An X509Certificate handle of the DER certificate Der.
-spec certificate(binary()) -> term().
certificate(Der) ->
    {ok, Cert} = decode(Der),
    handle(Cert).

%% A handle clones for messaging with its certificate, as
%% X509Certificate::CloneForMessaging does.
handle(Cert) ->
    Class = class(),
    Handle = buoy_heap:construct(Class, [], Class),
    buoy_crypto:put_state(Handle, {x509, Cert}),
    buoy_binding_messaging:set_cloneable(Handle, ?MODULE, Cert),
    Handle.

-spec from_clone(map()) -> term().
from_clone(Cert) -> handle(Cert).

class() ->
    Key = {?MODULE, class, erlang:get('$buoy_realm')},
    case erlang:get(Key) of
        undefined ->
            G = fun(F) -> fun(This, _) -> F(cert(This)) end end,
            Class = buoy_crypto:class(<<"X509Certificate">>, fun(_, _) -> undefined end, [
                {<<"subject">>, 0, G(fun(C) -> js(print_name(maps:get(subject, C), multiline)) end)},
                {<<"subjectAltName">>, 0, G(fun(C) -> js(subject_alt_name(C)) end)},
                {<<"issuer">>, 0, G(fun(C) -> js(print_name(maps:get(issuer, C), multiline)) end)},
                {<<"infoAccess">>, 0, G(fun(C) -> js(info_access(C)) end)},
                {<<"validFrom">>, 0, G(fun(C) -> print_time(maps:get(not_before, C)) end)},
                {<<"validTo">>, 0, G(fun(C) -> print_time(maps:get(not_after, C)) end)},
                {<<"validFromDate">>, 0, G(fun(C) -> date(maps:get(not_before, C)) end)},
                {<<"validToDate">>, 0, G(fun(C) -> date(maps:get(not_after, C)) end)},
                {<<"fingerprint">>, 0, G(fun(C) -> fingerprint(sha, C) end)},
                {<<"fingerprint256">>, 0, G(fun(C) -> fingerprint(sha256, C) end)},
                {<<"fingerprint512">>, 0, G(fun(C) -> fingerprint(sha512, C) end)},
                {<<"keyUsage">>, 0, G(fun key_usage/1)},
                {<<"serialNumber">>, 0, G(fun(C) -> serial(maps:get(serial, C)) end)},
                {<<"signatureAlgorithm">>, 0, G(fun(C) -> signature_name(maps:get(sig_oid, C)) end)},
                {<<"signatureAlgorithmOid">>, 0, G(fun(C) -> oid_text(maps:get(sig_oid, C)) end)},
                {<<"pem">>, 0, G(fun(C) -> buoy_crypto_der:pem_encode(<<"CERTIFICATE">>, maps:get(der, C)) end)},
                {<<"raw">>, 0, G(fun(C) -> buoy_crypto:buffer(maps:get(der, C)) end)},
                {<<"publicKey">>, 0, G(fun(C) -> buoy_crypto_keys:handle({public, public_key(C)}) end)},
                {<<"checkCA">>, 0, G(fun is_ca/1)},
                {<<"checkHost">>, 0, fun check_host/2},
                {<<"checkEmail">>, 0, fun check_email/2},
                {<<"checkIP">>, 0, fun check_ip/2},
                {<<"checkIssued">>, 0, fun(This, Args) -> is_issued_by(cert(This), cert(buoy_node:arg(1, Args))) end},
                {<<"checkPrivateKey">>, 0, fun check_private_key/2},
                {<<"verify">>, 0, fun verify/2},
                {<<"toLegacy">>, 0, G(fun to_legacy/1)},
                {<<"getIssuerCert">>, 0, fun(_, _) -> undefined end}]),
            erlang:put(Key, Class),
            Class;
        Class -> Class
    end.

cert(This) -> buoy_crypto:state(This, x509).

%% The JavaScript string of UTF-8 text.
js(undefined) -> undefined;
js(Text) -> buoy_node_encoding:decode_utf8(Text).

%% X509_get_pubkey: a subject key that does not parse is an EVP decode error.
public_key(#{spki := Spki}) ->
    try buoy_crypto_pkey:parse_public_der(Spki, 2)
    catch error:{crypto_failure, _} -> buoy_crypto:fail({openssl, decode_error})
    end.

ext(#{extensions := Exts}, Oid) ->
    case lists:keyfind(Oid, 1, Exts) of
        {_, _, Value} ->
            case buoy_crypto_der:decode(Value) of
                {ok, V} -> {ok, V};
                error -> error
            end;
        false -> none
    end.

%%% Names

%% X509_NAME_print_ex with Node's multiline flags, or the RFC 2253 flags
%% of a directory name in a subject alternative name.
print_name(Rdns, multiline) ->
    iolist_to_binary(lists:join($\n, [rdn(R, <<" + ">>, multiline) || {set, R} <- Rdns]));
print_name(Rdns, rfc2253) ->
    iolist_to_binary(lists:join($,, [rdn(R, <<"+">>, rfc2253) || {set, R} <- lists:reverse(Rdns)])).

rdn(Attributes, Sep, Style) ->
    lists:join(Sep, [attribute(Oid, Value, Style) || {seq, [{oid, Oid}, Value]} <- Attributes]).

attribute(Oid, Value, Style) ->
    case {short_name(Oid), Style} of
        {undefined, rfc2253} -> [oid_text(Oid), "=#", binary:encode_hex(buoy_crypto_der:encode(Value))];
        {undefined, _} -> [oid_text(Oid), $=, escape(utf8(Value), Style)];
        {Name, _} -> [Name, $=, escape(utf8(Value), Style)]
    end.

%% The UTF-8 bytes of a string of a name (ASN1_STRING_to_UTF8).
utf8({tag, 16#0C, B}) -> B;
utf8({tag, 16#1E, B}) -> unicode:characters_to_binary(B, {utf16, big});
utf8({tag, 16#1C, B}) -> unicode:characters_to_binary(B, {utf32, big});
utf8({tag, _, B}) -> unicode:characters_to_binary(B, latin1);
utf8(_) -> <<>>.

%% The escapes of do_esc_char with ASN1_STRFLGS_ESC_2253, and
%% ASN1_STRFLGS_ESC_CTRL in the multiline style.
escape(Bytes, Style) ->
    Last = byte_size(Bytes) - 1,
    [esc(B, I =:= 0, I =:= Last, Style) || {I, B} <- lists:zip(lists:seq(0, Last), binary_to_list(Bytes))].

esc(B, _, _, _) when B > 16#7F -> B;
esc(B, _, _, _) when B =:= $,; B =:= $+; B =:= $"; B =:= $\\; B =:= $<; B =:= $>; B =:= $; -> [$\\, B];
esc(B, true, _, _) when B =:= $#; B =:= $\s -> [$\\, B];
esc($\s, _, true, _) -> [$\\, $\s];
esc(B, _, _, multiline) when B < 16#20; B =:= 16#7F -> io_lib:format("\\~2.16.0B", [B]);
esc(B, _, _, _) -> B.

short_name(Oid) ->
    case lists:keyfind(Oid, 1, name_attributes()) of
        {_, Name} -> Name;
        false -> undefined
    end.

name_attributes() ->
    [{{2,5,4,3}, <<"CN">>}, {{2,5,4,6}, <<"C">>}, {{2,5,4,7}, <<"L">>}, {{2,5,4,8}, <<"ST">>},
     {{2,5,4,10}, <<"O">>}, {{2,5,4,11}, <<"OU">>}, {{2,5,4,4}, <<"SN">>}, {{2,5,4,42}, <<"GN">>},
     {{2,5,4,5}, <<"serialNumber">>}, {{2,5,4,12}, <<"title">>}, {{2,5,4,43}, <<"initials">>},
     {{2,5,4,44}, <<"generationQualifier">>}, {{2,5,4,46}, <<"dnQualifier">>}, {{2,5,4,65}, <<"pseudonym">>},
     {{2,5,4,9}, <<"street">>}, {{2,5,4,17}, <<"postalCode">>}, {{2,5,4,15}, <<"businessCategory">>},
     {{2,5,4,13}, <<"description">>}, {{2,5,4,41}, <<"name">>}, {{2,5,4,45}, <<"x500UniqueIdentifier">>},
     {{2,5,4,97}, <<"organizationIdentifier">>}, {{2,5,4,16}, <<"postalAddress">>},
     {{2,5,4,18}, <<"postOfficeBox">>}, {{2,5,4,20}, <<"telephoneNumber">>},
     {{1,2,840,113549,1,9,1}, <<"emailAddress">>}, {{1,2,840,113549,1,9,2}, <<"unstructuredName">>},
     {{0,9,2342,19200300,100,1,25}, <<"DC">>}, {{0,9,2342,19200300,100,1,1}, <<"UID">>},
     {{1,3,6,1,4,1,311,60,2,1,1}, <<"jurisdictionL">>}, {{1,3,6,1,4,1,311,60,2,1,2}, <<"jurisdictionST">>},
     {{1,3,6,1,4,1,311,60,2,1,3}, <<"jurisdictionC">>}].

%% OBJ_obj2txt with numbers.
oid_text(Oid) -> iolist_to_binary(lists:join($., [integer_to_binary(N) || N <- tuple_to_list(Oid)])).

%%% Extensions

%% subjectAltName (SafeX509SubjectAltNamePrint), or undefined.
subject_alt_name(C) ->
    case ext(C, ?SAN) of
        {ok, {seq, Names}} -> iolist_to_binary(lists:join(<<", ">>, [general_name(N) || N <- Names]));
        _ -> undefined
    end.

%% infoAccess (SafeX509InfoAccessPrint), or undefined.
info_access(C) ->
    case ext(C, ?AIA) of
        {ok, {seq, Descs}} ->
            iolist_to_binary(lists:join($\n, [[access_method(M), " - ", general_name(L)]
                                              || {seq, [{oid, M}, L]} <- Descs]));
        _ -> undefined
    end.

access_method({1,3,6,1,5,5,7,48,1}) -> <<"OCSP">>;
access_method({1,3,6,1,5,5,7,48,2}) -> <<"CA Issuers">>;
access_method({1,3,6,1,5,5,7,48,3}) -> <<"AD Time Stamping">>;
access_method({1,3,6,1,5,5,7,48,5}) -> <<"CA Repository">>;
access_method(Oid) -> oid_text(Oid).

%% PrintGeneralName of ncrypto.
general_name({ctx_prim, 2, Name}) -> ["DNS:", alt_name(Name, ascii, undefined)];
general_name({ctx_prim, 1, Name}) -> ["email:", alt_name(Name, ascii, undefined)];
general_name({ctx_prim, 6, Name}) -> ["URI:", alt_name(Name, ascii, undefined)];
general_name({ctx, 4, [{seq, Rdns}]}) -> ["DirName:", alt_name(print_name(Rdns, rfc2253), utf8, undefined)];
general_name({ctx_prim, 7, <<A, B, C, D>>}) -> io_lib:format("IP Address:~B.~B.~B.~B", [A, B, C, D]);
general_name({ctx_prim, 7, <<_:16/binary>> = Ip}) ->
    ["IP Address:", lists:join($:, [integer_to_binary(W, 16) || <<W:16>> <= Ip])];
general_name({ctx_prim, 7, Ip}) -> io_lib:format("IP Address:<invalid length=~B>", [byte_size(Ip)]);
general_name({ctx_prim, 8, Oid}) ->
    {ok, {oid, O}} = buoy_crypto_der:decode(<<6, (byte_size(Oid)), Oid/binary>>),
    ["Registered ID:", oid_text(O)];
general_name({ctx, 0, [{oid, Type}, {ctx, 0, [Value]}]}) -> ["othername:", other_name(Type, Value)];
general_name({ctx, 3, _}) -> "X400Name:<unsupported>";
general_name({ctx, 5, _}) -> "EdiPartyName:<unsupported>";
general_name(_) -> "othername:<unsupported>".

other_name({1,3,6,1,5,5,7,8,9}, {tag, 16#0C, V}) -> alt_name(V, utf8, <<"SmtpUTF8Mailbox">>);
other_name({1,3,6,1,5,5,7,8,5}, {tag, 16#0C, V}) -> alt_name(V, utf8, <<"XmppAddr">>);
other_name({1,3,6,1,5,5,7,8,7}, {tag, 16#16, V}) -> alt_name(V, ascii, <<"SRVName">>);
other_name({1,3,6,1,4,1,311,20,2,3}, {tag, 16#0C, V}) -> alt_name(V, utf8, <<"UPN">>);
other_name({1,3,6,1,5,5,7,8,8}, {tag, 16#0C, V}) -> alt_name(V, utf8, <<"NAIRealm">>);
other_name(_, _) -> "<unsupported>".

%% PrintAltName: a safe name as it is, and else a JSON string.
alt_name(Name, Option, Prefix) ->
    case is_safe(Name, Option) of
        true -> [[[Prefix, $:] || Prefix =/= undefined], Name];
        false -> [$", [[Prefix, $:] || Prefix =/= undefined], [json_char(C, Option) || <<C>> <= Name], $"]
    end.

is_safe(Name, Option) ->
    lists:all(fun(C) -> safe_char(C, Option) end, binary_to_list(Name)).

safe_char(C, _) when C =:= $"; C =:= $\\; C =:= $,; C =:= $' -> false;
safe_char(C, utf8) -> C >= $\s andalso C =/= 16#7F;
safe_char(C, ascii) -> C >= $\s andalso C =< $~.

json_char($\\, _) -> "\\\\";
json_char($", _) -> "\\\"";
json_char(C, _) when C >= $\s, C =/= $,, C =< $~ -> C;
json_char(C, utf8) when C >= 16#80 -> C;
json_char(C, _) -> io_lib:format("\\u00~2.16.0b", [C]).

%% keyUsage: the OIDs of the extended key usage, or undefined.
key_usage(C) ->
    case ext(C, ?EKU) of
        {ok, {seq, Oids}} -> buoy_heap:new_array([oid_text(O) || {oid, O} <- Oids]);
        _ -> undefined
    end.

%% X509_check_ca(cert) == 1: basicConstraints says CA, and keyUsage, when
%% present, allows signing certificates.
is_ca(C) ->
    BasicCa = case ext(C, ?BASIC) of
        {ok, {seq, [{bool, true} | _]}} -> true;
        _ -> false
    end,
    BasicCa andalso allows_cert_sign(C).

allows_cert_sign(C) ->
    case ext(C, ?KEY_USAGE) of
        {ok, Bits} -> key_usage_bit(Bits, 5);
        _ -> true
    end.

key_usage_bit({bits, Bytes}, N) -> key_usage_bit({bits, 0, Bytes}, N);
key_usage_bit({bits, _, Bytes}, N) ->
    bit_size(Bytes) > N andalso begin
        <<_:N, B:1, _/bitstring>> = Bytes,
        B =:= 1
    end.

%%% Fields

%% ASN1_TIME_print: "Sep  3 21:40:37 2022 GMT".
print_time({{Y, M, D}, {H, Mi, S}, Fraction}) ->
    Months = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"},
    Frac = case Fraction of
        <<>> -> "";
        _ -> [$., Fraction]
    end,
    iolist_to_binary(io_lib:format("~s ~2B ~2..0B:~2..0B:~2..0B~s ~B GMT",
                                   [element(M, Months), D, H, Mi, S, Frac, Y])).

date({Day, Time, _}) ->
    Seconds = calendar:datetime_to_gregorian_seconds({Day, Time}) - 62167219200,
    Date = buoy_node:global_get(<<"Date">>),
    buoy_heap:construct(Date, [Seconds * 1000], Date).

fingerprint(Md, #{der := Der}) ->
    iolist_to_binary(lists:join($:, [io_lib:format("~2.16.0B", [B]) || <<B>> <= crypto:hash(Md, Der)])).

%% BN_bn2hex of the serial number, in upper case.
serial(0) -> <<"0">>;
serial(N) when N < 0 -> <<"-", (serial(-N))/binary>>;
serial(N) -> binary:encode_hex(binary:encode_unsigned(N)).

signature_name(Oid) ->
    case lists:keyfind(Oid, 1, signature_algorithms()) of
        {_, Name, _} -> Name;
        false -> undefined
    end.

%% The signature algorithms: OBJ_nid2ln, and the digest and the key kind
%% that verify them.
signature_algorithms() ->
    [{{1,2,840,113549,1,1,4}, <<"md5WithRSAEncryption">>, {md5, rsa}},
     {{1,2,840,113549,1,1,5}, <<"sha1WithRSAEncryption">>, {sha, rsa}},
     {{1,2,840,113549,1,1,14}, <<"sha224WithRSAEncryption">>, {sha224, rsa}},
     {{1,2,840,113549,1,1,11}, <<"sha256WithRSAEncryption">>, {sha256, rsa}},
     {{1,2,840,113549,1,1,12}, <<"sha384WithRSAEncryption">>, {sha384, rsa}},
     {{1,2,840,113549,1,1,13}, <<"sha512WithRSAEncryption">>, {sha512, rsa}},
     {{1,2,840,113549,1,1,10}, <<"rsassaPss">>, pss},
     {{1,2,840,10045,4,1}, <<"ecdsa-with-SHA1">>, {sha, ec}},
     {{1,2,840,10045,4,3,1}, <<"ecdsa-with-SHA224">>, {sha224, ec}},
     {{1,2,840,10045,4,3,2}, <<"ecdsa-with-SHA256">>, {sha256, ec}},
     {{1,2,840,10045,4,3,3}, <<"ecdsa-with-SHA384">>, {sha384, ec}},
     {{1,2,840,10045,4,3,4}, <<"ecdsa-with-SHA512">>, {sha512, ec}},
     {{1,2,840,10040,4,3}, <<"dsaWithSHA1">>, {sha, dsa}},
     {{2,16,840,1,101,3,4,3,1}, <<"dsa_with_SHA224">>, {sha224, dsa}},
     {{2,16,840,1,101,3,4,3,2}, <<"dsa_with_SHA256">>, {sha256, dsa}},
     {{1,3,101,112}, <<"ED25519">>, {none, ed25519}},
     {{1,3,101,113}, <<"ED448">>, {none, ed448}},
     {{2,16,840,1,101,3,4,3,17}, <<"ML-DSA-44">>, {none, ml_dsa_44}},
     {{2,16,840,1,101,3,4,3,18}, <<"ML-DSA-65">>, {none, ml_dsa_65}},
     {{2,16,840,1,101,3,4,3,19}, <<"ML-DSA-87">>, {none, ml_dsa_87}}].

%%% Checks

%% verify(publicKey): X509_verify, the signature of the certificate under
%% the key.
verify(This, Args) ->
    {_, K} = buoy_crypto_keys:key_data(buoy_node:arg(1, Args)),
    verify_signature(cert(This), buoy_crypto_pkey:public(K)).

%% Whether the signature of a signed structure verifies under Public.
verify_signature(#{sig_oid := Oid, tbs := Tbs, signature := Sig}, Public) ->
    case lists:keyfind(Oid, 1, signature_algorithms()) of
        {_, _, {none, _}} -> buoy_crypto_sig:verify(Public, undefined, Tbs, Sig, undefined, undefined);
        {_, _, {Md, _}} ->
            {ok, M} = buoy_crypto_hash:digest(atom_to_binary(Md)),
            try buoy_crypto_sig:verify(Public, M, Tbs, Sig, undefined, undefined)
            catch
                error:{crypto_failure, _} -> false
            end;
        _ -> false
    end.

%% checkPrivateKey(privateKey): X509_check_private_key.
check_private_key(This, Args) ->
    {private, K} = buoy_crypto_keys:key_data(buoy_node:arg(1, Args)),
    same_key(public_key(cert(This)), buoy_crypto_pkey:public(K)).

%% Whether the certificate of the DER Der holds the public key of the
%% private key K (a key of buoy_crypto_pkey), as X509_check_private_key.
-spec holds_private_key(binary(), term()) -> boolean().
holds_private_key(Der, K) ->
    case decode(Der) of
        {ok, Cert} -> same_key(public_key(Cert), buoy_crypto_pkey:public(K));
        error -> false
    end.

same_key(#{kind := ec, curve := C, pub := A}, #{kind := ec, curve := C, pub := B}) ->
    buoy_crypto_pkey:decode_point(C, A) =:= buoy_crypto_pkey:decode_point(C, B);
same_key(A, B) -> maps:without([explicit, x942], A) =:= maps:without([explicit, x942], B).

%% X509_check_issued(issuer, cert) == X509_V_OK.
is_issued_by(Cert, Issuer) ->
    same_name(maps:get(issuer, Cert), maps:get(subject, Issuer)) andalso key_ids_match(Cert, Issuer)
        andalso allows_cert_sign(Issuer).

key_ids_match(Cert, Issuer) ->
    case {ext(Cert, ?AKID), ext(Issuer, ?SKID)} of
        {{ok, {seq, Fields}}, {ok, {octets, Skid}}} ->
            case [Id || {ctx_prim, 0, Id} <- Fields] of
                [Id] -> Id =:= Skid;
                [] -> true
            end;
        _ -> true
    end.

%% X509_NAME_cmp compares the canonical encodings of the names.
same_name(A, B) -> canonical(A) =:= canonical(B).

canonical(Rdns) ->
    [[{Oid, string:casefold(string:trim(utf8(V)))} || {seq, [{oid, Oid}, V]} <- R] || {set, R} <- Rdns].

%% checkHost(name, flags): the name of the certificate that matched, or
%% undefined.
check_host(This, Args) ->
    C = cert(This),
    Host = buoy_crypto:string(buoy_node:arg(1, Args)),
    Flags = buoy_node:arg(2, Args),
    valid_host(Host) orelse buoy_crypto:fail_code(<<"ERR_INVALID_ARG_VALUE">>, <<"Invalid name">>),
    Dns = [N || {ctx_prim, 2, N} <- san(C)],
    Candidates = case subject_checked(Dns, Flags) of
        true -> Dns ++ [utf8(V) || V <- subject_values(C, ?CN)];
        false -> Dns
    end,
    case [N || N <- Candidates, host_matches(string:lowercase(N), string:lowercase(Host), Flags)] of
        [Match | _] -> js(Match);
        [] -> undefined
    end.

valid_host(<<>>) -> false;
valid_host(Host) -> binary:match(Host, <<0>>) =:= nomatch.

subject_checked(Sans, Flags) ->
    Flags band ?NEVER_CHECK_SUBJECT =:= 0 andalso (Sans =:= [] orelse Flags band ?ALWAYS_CHECK_SUBJECT =/= 0).

san(C) ->
    case ext(C, ?SAN) of
        {ok, {seq, Names}} -> Names;
        _ -> []
    end.

subject_values(#{subject := Rdns}, Oid) -> [V || {set, R} <- Rdns, {seq, [{oid, O}, V]} <- R, O =:= Oid].

%% equal_wildcard of OpenSSL's v3_utl.c.
host_matches(Pattern, Host, Flags) ->
    Pattern =:= Host orelse
        (Flags band ?NO_WILDCARDS =:= 0 andalso wildcard_matches(Pattern, Host, Flags)) orelse
        (binary:first(Host) =:= $. andalso subdomain_matches(Pattern, Host, Flags)).

subdomain_matches(Pattern, Domain, Flags) ->
    Labels = fun(B) -> length(binary:split(B, <<".">>, [global])) end,
    byte_size(Pattern) > byte_size(Domain) andalso
        binary:part(Pattern, byte_size(Pattern) - byte_size(Domain), byte_size(Domain)) =:= Domain andalso
        (Flags band ?SINGLE_LABEL_SUBDOMAINS =:= 0 orelse Labels(Pattern) =:= Labels(Domain)).

wildcard_matches(Pattern, Host, Flags) ->
    case binary:split(Pattern, <<".">>) of
        [First, Rest] when Rest =/= <<>> ->
            case binary:split(First, <<"*">>, [global]) of
                [Prefix, Suffix] ->
                    Partial = Prefix =/= <<>> orelse Suffix =/= <<>>,
                    Ok = (not Partial orelse Flags band ?NO_PARTIAL_WILDCARDS =:= 0)
                        andalso length(binary:split(Rest, <<".">>, [global])) >= 2
                        andalso not (Partial andalso binary:match(Prefix, <<"xn--">>) =:= {0, 4}),
                    Ok andalso match_label(Prefix, Suffix, Rest, Host, Flags);
                _ -> false
            end;
        _ -> false
    end.

match_label(Prefix, Suffix, Rest, Host, Flags) ->
    case binary:split(Host, <<".">>) of
        [Label, HostRest] when Flags band ?MULTI_LABEL_WILDCARDS =:= 0 ->
            HostRest =:= Rest andalso byte_size(Label) >= byte_size(Prefix) + byte_size(Suffix)
                andalso binary:part(Label, 0, byte_size(Prefix)) =:= Prefix
                andalso binary:part(Label, byte_size(Label) - byte_size(Suffix), byte_size(Suffix)) =:= Suffix
                andalso Label =/= <<>>;
        [_, _] ->
            Tail = <<".", Rest/binary>>,
            byte_size(Host) > byte_size(Tail) andalso
                binary:part(Host, byte_size(Host) - byte_size(Tail), byte_size(Tail)) =:= Tail;
        _ -> false
    end.

%% checkEmail(email, flags)
check_email(This, Args) ->
    C = cert(This),
    Email = buoy_node:arg(1, Args),
    Text = buoy_crypto:string(Email),
    binary:match(Text, <<"@">>) =/= nomatch orelse buoy_crypto:fail_code(<<"ERR_INVALID_ARG_VALUE">>, <<"Invalid name">>),
    Flags = buoy_node:arg(2, Args),
    Sans = [N || {ctx_prim, 1, N} <- san(C)],
    Candidates = case subject_checked(Sans, Flags) of
        true -> Sans ++ [utf8(V) || V <- subject_values(C, ?EMAIL)];
        false -> Sans
    end,
    case lists:any(fun(N) -> same_email(N, Text) end, Candidates) of
        true -> Email;
        false -> undefined
    end.

same_email(A, B) ->
    case {binary:split(A, <<"@">>), binary:split(B, <<"@">>)} of
        {[L, DA], [L, DB]} -> string:lowercase(DA) =:= string:lowercase(DB);
        _ -> false
    end.

%% checkIP(ip, flags): the iPAddress entries only.
check_ip(This, Args) ->
    Ip = buoy_node:arg(1, Args),
    Bytes = case inet:parse_strict_address(binary_to_list(buoy_crypto:string(Ip))) of
        {ok, {A, B, C, D}} -> <<A, B, C, D>>;
        {ok, Words} -> << <<W:16>> || W <- tuple_to_list(Words) >>;
        {error, _} -> buoy_crypto:fail_code(<<"ERR_INVALID_ARG_VALUE">>, <<"Invalid IP">>)
    end,
    case lists:member(Bytes, [N || {ctx_prim, 7, N} <- san(cert(This))]) of
        true -> Ip;
        false -> undefined
    end.

%%% toLegacy

%% The object of X509ToObject, for tls.getPeerCertificate.
to_legacy(C) ->
    K = public_key(C),
    Base = [{<<"subject">>, name_object(maps:get(subject, C))}, {<<"issuer">>, name_object(maps:get(issuer, C))},
            {<<"subjectaltname">>, js(subject_alt_name(C))}, {<<"infoAccess">>, js(info_access(C))},
            {<<"ca">>, is_ca(C)}] ++ key_fields(K) ++
           [{<<"valid_from">>, print_time(maps:get(not_before, C))}, {<<"valid_to">>, print_time(maps:get(not_after, C))},
            {<<"fingerprint">>, fingerprint(sha, C)}, {<<"fingerprint256">>, fingerprint(sha256, C)},
            {<<"fingerprint512">>, fingerprint(sha512, C)}, {<<"ext_key_usage">>, key_usage(C)},
            {<<"serialNumber">>, serial(maps:get(serial, C))}, {<<"raw">>, buoy_crypto:buffer(maps:get(der, C))}] ++
           curve_fields(K),
    buoy_node:object([{Key, V} || {Key, V} <- Base, V =/= undefined]).

key_fields(#{kind := Kind, n := N, e := E}) when Kind =:= rsa; Kind =:= rsa_pss ->
    [{<<"modulus">>, binary:encode_hex(binary:encode_unsigned(N))},
     {<<"exponent">>, <<"0x", (string:lowercase(integer_to_binary(E, 16)))/binary>>},
     {<<"pubkey">>, buoy_crypto:buffer(buoy_crypto_der:encode({seq, [{seq, [{oid, {1,2,840,113549,1,1,1}}, null]},
                                                                      {bits, buoy_crypto_der:encode({seq, [{int, N}, {int, E}]})}]}))},
     {<<"bits">>, bit_length(N)}];
key_fields(#{kind := ec, curve := Curve, pub := Pub}) ->
    [{<<"pubkey">>, buoy_crypto:buffer(Pub)}, {<<"bits">>, buoy_crypto_pkey:curve_bits(Curve)}];
key_fields(_) -> [].

curve_fields(#{kind := ec, curve := Curve}) ->
    Nist = case Curve of
        prime256v1 -> <<"P-256">>;
        secp384r1 -> <<"P-384">>;
        secp521r1 -> <<"P-521">>;
        secp224r1 -> <<"P-224">>;
        prime192v1 -> <<"P-192">>;
        _ -> undefined
    end,
    [{<<"asn1Curve">>, buoy_crypto_pkey:curve_name(Curve)}, {<<"nistCurve">>, Nist}];
curve_fields(_) -> [].

%% GetX509NameObject: one property for each attribute, and an array for
%% an attribute that repeats.
name_object(Rdns) ->
    Pairs = [{name_key(Oid), js(utf8(V))} || {set, R} <- Rdns, {seq, [{oid, Oid}, V]} <- R],
    Keys = lists:usort([K || {K, _} <- Pairs]),
    Ordered = [K || K <- lists:usort(fun(A, B) -> first_index(A, Pairs) =< first_index(B, Pairs) end, Keys)],
    buoy_node:object(null, [{K, case [V || {K2, V} <- Pairs, K2 =:= K] of
                                     [One] -> One;
                                     Many -> buoy_heap:new_array(Many)
                                 end} || K <- Ordered]).

first_index(K, Pairs) -> length(lists:takewhile(fun({K2, _}) -> K2 =/= K end, Pairs)).

name_key(Oid) ->
    case short_name(Oid) of
        undefined -> oid_text(Oid);
        Name -> Name
    end.

bit_length(0) -> 0;
bit_length(N) -> bit_length(N bsr 1) + 1.
