%% The post-quantum keys of the crypto binding (OpenSSL 3.5's ML-DSA,
%% ML-KEM, and SLH-DSA, as ncrypto exposes them) on OTP's crypto: their
%% PKCS#8 forms and their raw forms.
-module(buoy_crypto_pqc).

-export([private_decode/2, private_encode/1, from_raw/3, otp_type/1, generate/1]).

%% The OTP name of a kind.
-spec otp_type(atom()) -> atom().
otp_type(ml_dsa_44) -> mldsa44;
otp_type(ml_dsa_65) -> mldsa65;
otp_type(ml_dsa_87) -> mldsa87;
otp_type(ml_kem_512) -> mlkem512;
otp_type(ml_kem_768) -> mlkem768;
otp_type(ml_kem_1024) -> mlkem1024;
otp_type(Kind) -> Kind.

is_ml_kem(Kind) -> lists:member(Kind, [ml_kem_512, ml_kem_768, ml_kem_1024]).
is_ml_dsa(Kind) -> lists:member(Kind, [ml_dsa_44, ml_dsa_65, ml_dsa_87]).

%% A new key pair of Kind.
-spec generate(atom()) -> map().
generate(Kind) ->
    {Pub, Priv} = crypto:generate_key(otp_type(Kind), []),
    #{kind => Kind, pub => Pub, priv => Priv}.

%% The private key of the inner bytes of a PKCS#8 key: the raw key of
%% SLH-DSA, or the seed, the expanded key, or both of ML-DSA and ML-KEM.
-spec private_decode(atom(), binary()) -> map().
private_decode(Kind, Inner) ->
    case is_ml_kem(Kind) orelse is_ml_dsa(Kind) of
        false -> slh_private(Kind, Inner);
        true ->
            case buoy_crypto_der:decode(Inner) of
                {ok, {seq, [{octets, Seed}, {octets, Expanded}]}} -> expanded(Kind, Expanded, Seed);
                {ok, {octets, Expanded}} -> expanded(Kind, Expanded, undefined);
                {ok, {ctx_prim, 0, Seed}} -> from_seed(Kind, Seed);
                _ -> buoy_crypto:fail({openssl, decoder_unsupported})
            end
    end.

slh_private(Kind, Priv) ->
    Half = byte_size(Priv) div 2,
    #{kind => Kind, priv => Priv, pub => binary:part(Priv, Half, Half)}.

expanded(Kind, Expanded, Seed) ->
    K = #{kind => Kind, priv => Expanded, pub => public_of(Kind, Expanded)},
    case Seed of
        undefined -> K;
        _ -> K#{seed => Seed}
    end.

%% The encapsulation key inside an ML-KEM decapsulation key (FIPS 203,
%% 7.3), or the public key of an ML-DSA key.
public_of(Kind, Expanded) ->
    case is_ml_kem(Kind) of
        true ->
            K = (byte_size(Expanded) - 96) div 768,
            binary:part(Expanded, 384 * K, 384 * K + 32);
        false -> buoy_crypto:fail({openssl, unsupported})
    end.

from_seed(_Kind, _Seed) -> buoy_crypto:fail({openssl, unsupported}).

%% The inner bytes of the PKCS#8 form of K, as OpenSSL writes them.
-spec private_encode(map()) -> binary().
private_encode(#{kind := Kind, priv := Priv} = K) ->
    case is_ml_kem(Kind) orelse is_ml_dsa(Kind) of
        false -> Priv;
        true ->
            case K of
                #{seed := Seed} -> buoy_crypto_der:encode({seq, [{octets, Seed}, {octets, Priv}]});
                _ -> buoy_crypto_der:encode({octets, Priv})
            end
    end.

%% A key of raw bytes: a public key, or the seed of a private key.
-spec from_raw(atom(), binary(), boolean()) -> {ok, term()} | error.
from_raw(Kind, Bytes, false) -> {ok, {public, #{kind => Kind, pub => Bytes}}};
from_raw(Kind, Seed, true) ->
    try {ok, {private, from_seed(Kind, Seed)}}
    catch
        error:{crypto_failure, _} -> error
    end.
