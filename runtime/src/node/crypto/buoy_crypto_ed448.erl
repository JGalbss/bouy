%% Ed448 signatures with a context string (RFC 8032, section 5.2). OTP's
%% crypto signs Ed448 only with the empty context, which OpenSSL 3.2 lets
%% a signature set, so a non-empty context runs here, on the curve in
%% projective coordinates over Erlang integers.
-module(buoy_crypto_ed448).

-export([sign/3, verify/4]).

-define(P, ((1 bsl 448) - (1 bsl 224) - 1)).
-define(L, ((1 bsl 446) - 13818066809895115352007386748515426880336692474882178609894547503885)).
-define(D, -39081).
-define(BX, 224580040295924300187604334099896036246789641632564134246125461686950415467406032909029192869357953282578032075146446173674602635247710).
-define(BY, 298819210078481492676017930443930673437544040154080242095928241372331506189835876003536878655418784733982303233503462500531545062832660).

%% The signature of Message under the 57-byte private key Priv, with the
%% context Context.
-spec sign(binary(), binary(), binary()) -> binary().
sign(Priv, Message, Context) ->
    <<Secret:57/binary, Prefix:57/binary>> = shake(Priv),
    S = clamp(Secret),
    A = encode(multiply(S, base())),
    Dom = dom4(Context),
    R = little(shake(<<Dom/binary, Prefix/binary, Message/binary>>)) rem ?L,
    REnc = encode(multiply(R, base())),
    K = little(shake(<<Dom/binary, REnc/binary, A/binary, Message/binary>>)) rem ?L,
    <<REnc/binary, ((R + K * S) rem ?L):456/little>>.

%% Whether Signature signs Message under the public key Pub with Context.
-spec verify(binary(), binary(), binary(), binary()) -> boolean().
verify(Pub, Message, <<REnc:57/binary, S:456/little>>, Context) when S < ?L ->
    case {decode(REnc), decode(Pub)} of
        {{ok, R}, {ok, A}} ->
            K = little(shake(<<(dom4(Context))/binary, REnc/binary, Pub/binary, Message/binary>>)) rem ?L,
            equal(times4(multiply(S, base())), times4(add(R, multiply(K, A))));
        _ -> false
    end;
verify(_, _, _, _) -> false.

dom4(Context) -> <<"SigEd448", 0, (byte_size(Context)), Context/binary>>.

shake(Data) -> crypto:hash_final_xof(crypto:hash_update(crypto:hash_init(shake256), Data), 114 * 8).

little(Bytes) -> binary:decode_unsigned(Bytes, little).

%% The scalar of the first half of the hash of a private key.
clamp(Secret) ->
    <<First, Middle:55/binary, _>> = Secret,
    little(<<(First band 16#FC), Middle/binary, 0>>) bor (1 bsl 447).

%%% The curve x^2 + y^2 = 1 + d x^2 y^2 in projective coordinates {X, Y, Z}

base() -> {?BX, ?BY, 1}.

m(X) -> ((X rem ?P) + ?P) rem ?P.

add({X1, Y1, Z1}, {X2, Y2, Z2}) ->
    A = m(Z1 * Z2),
    B = m(A * A),
    C = m(X1 * X2),
    D = m(Y1 * Y2),
    E = m(?D * m(C * D)),
    F = m(B - E),
    G = m(B + E),
    H = m((X1 + Y1) * (X2 + Y2)),
    {m(A * m(F * (H - C - D))), m(A * m(G * (D - C))), m(F * G)}.

double({X1, Y1, Z1}) ->
    B = m((X1 + Y1) * (X1 + Y1)),
    C = m(X1 * X1),
    D = m(Y1 * Y1),
    E = m(C + D),
    H = m(Z1 * Z1),
    J = m(E - 2 * H),
    {m((B - E) * J), m(E * (C - D)), m(E * J)}.

multiply(N, Point) -> multiply(N, Point, {0, 1, 1}).

multiply(0, _, Acc) -> Acc;
multiply(N, Point, Acc) ->
    Next = case N band 1 of
        1 -> add(Acc, Point);
        0 -> Acc
    end,
    multiply(N bsr 1, double(Point), Next).

times4(Point) -> double(double(Point)).

equal({X1, Y1, Z1}, {X2, Y2, Z2}) ->
    m(X1 * Z2) =:= m(X2 * Z1) andalso m(Y1 * Z2) =:= m(Y2 * Z1).

pow(B, E) -> binary:decode_unsigned(crypto:mod_pow(B, E, ?P)).

encode({X, Y, Z}) ->
    Inverse = pow(Z, ?P - 2),
    XA = m(X * Inverse),
    YA = m(Y * Inverse),
    <<(YA bor ((XA band 1) bsl 455)):456/little>>.

%% The point of an encoding (RFC 8032, section 5.2.3).
decode(<<Value:456/little>>) ->
    Y = Value band ((1 bsl 455) - 1),
    Sign = Value bsr 455,
    U = m(Y * Y - 1),
    V = m(?D * Y * Y - 1),
    X = m(pow(U, 3) * V * pow(m(pow(U, 5) * pow(V, 3)), (?P - 3) div 4)),
    case Y < ?P andalso m(V * X * X) =:= U andalso not (X =:= 0 andalso Sign =:= 1) of
        true when X band 1 =:= Sign -> {ok, {X, Y, 1}};
        true -> {ok, {?P - X, Y, 1}};
        false -> error
    end.
