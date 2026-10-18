%% The `Math` namespace. Each function takes the argument list.
%%
%% The transcendental functions are ports of the fdlibm code in V8
%% (src/base/ieee754.cc), so results match Node to the last bit. Node on
%% arm64 is compiled with clang, which fuses `a * b + c` inside one
%% expression into a single rounding (fused multiply-add); the ports call
%% fma/3 at exactly those places. The Erlang math module rounds differently
%% in about one call out of a hundred.
-module(buoy_math).

-compile({no_auto_import, [abs/1, ceil/1, floor/1, max/1, min/1, round/1, trunc/1]}).

-export(['$member'/1]).
-export([abs/1, acos/1, acosh/1, asin/1, asinh/1, atan/1, atan2/1, atanh/1, cbrt/1, ceil/1, clz32/1]).
-export([cos/1, cosh/1, exp/1, expm1/1, floor/1, fround/1, hypot/1, imul/1, log/1, log10/1, log1p/1]).
-export([log2/1, max/1, min/1, pow/1, random/1, round/1, sign/1, sin/1, sinh/1, sqrt/1, tan/1]).
-export([tanh/1, trunc/1]).

-define(FUNCTIONS, [
    <<"abs">>, <<"acos">>, <<"acosh">>, <<"asin">>, <<"asinh">>, <<"atan">>, <<"atan2">>, <<"atanh">>,
    <<"cbrt">>, <<"ceil">>, <<"clz32">>, <<"cos">>, <<"cosh">>, <<"exp">>, <<"expm1">>, <<"floor">>,
    <<"fround">>, <<"hypot">>, <<"imul">>, <<"log">>, <<"log10">>, <<"log1p">>, <<"log2">>, <<"max">>,
    <<"min">>, <<"pow">>, <<"random">>, <<"round">>, <<"sign">>, <<"sin">>, <<"sinh">>, <<"sqrt">>,
    <<"tan">>, <<"tanh">>, <<"trunc">>
]).
-define(SAFE, 9007199254740992).

-type js_number() :: buoy_rt:js_number().
-type double() :: float() | 'NaN' | 'Infinity' | '-Infinity'.

%%% fdlibm constants

-define(LN2_HI, 6.93147180369123816490e-01).
-define(LN2_LO, 1.90821492927058770002e-10).
-define(INVLN2, 1.44269504088896338700e+00).
-define(P1, 1.66666666666666019037e-01).
-define(P2, -2.77777777770155933842e-03).
-define(P3, 6.61375632143793436117e-05).
-define(P4, -1.65339022054652515390e-06).
-define(P5, 4.13813679705723846039e-08).
-define(Q1, -3.33333333333331316428e-02).
-define(Q2, 1.58730158725481460165e-03).
-define(Q3, -7.93650757867487942473e-05).
-define(Q4, 4.00821782732936239552e-06).
-define(Q5, -2.01099218183624371326e-07).
-define(LG1, 6.666666666666735130e-01).
-define(LG2, 3.999999999940941908e-01).
-define(LG3, 2.857142874366239149e-01).
-define(LG4, 2.222219843214978396e-01).
-define(LG5, 1.818357216161805012e-01).
-define(LG6, 1.531383769920937332e-01).
-define(LG7, 1.479819860511658591e-01).
-define(IVLN2HI, 1.44269504072144627571e+00).
-define(IVLN2LO, 1.67517131648865118353e-10).
-define(IVLN10, 4.34294481903251816668e-01).
-define(LOG10_2HI, 3.01029995663611771306e-01).
-define(LOG10_2LO, 3.69423907715893078616e-13).
-define(LP1, 6.666666666666735130e-01).
-define(LP2, 3.999999999940941908e-01).
-define(LP3, 2.857142874366239149e-01).
-define(LP4, 2.222219843214978396e-01).
-define(LP5, 1.818357216161805012e-01).
-define(LP6, 1.531383769920937332e-01).
-define(LP7, 1.479819860511658591e-01).
-define(S1, -1.66666666666666324348e-01).
-define(S2, 8.33333333332248946124e-03).
-define(S3, -1.98412698298579493134e-04).
-define(S4, 2.75573137070700676789e-06).
-define(S5, -2.50507602534068634195e-08).
-define(S6, 1.58969099521155010221e-10).
-define(C1, 4.16666666666666019037e-02).
-define(C2, -1.38888888888741095749e-03).
-define(C3, 2.48015872894767294178e-05).
-define(C4, -2.75573143513906633035e-07).
-define(C5, 2.08757232129817482790e-09).
-define(C6, -1.13596475577881948265e-11).
-define(T, {
    3.33333333333334091986e-01, 1.33333333333201242699e-01, 5.39682539762260521377e-02,
    2.18694882948595424599e-02, 8.86323982359930005737e-03, 3.59207910759131235356e-03,
    1.45620945432529025516e-03, 5.88041240820264096874e-04, 2.46463134818469906812e-04,
    7.81794442939557092300e-05, 7.14072491382608190305e-05, -1.85586374855275456654e-05,
    2.59073051863633712884e-05
}).
-define(PIO4, 7.85398163397448278999e-01).
-define(PIO4LO, 3.06161699786838301793e-17).
-define(INVPIO2, 6.36619772367581382433e-01).
-define(PIO2_1, 1.57079632673412561417e+00).
-define(PIO2_1T, 6.07710050650619224932e-11).
-define(PIO2_2, 6.07710050630396597660e-11).
-define(PIO2_2T, 2.02226624879595063154e-21).
-define(PIO2_3, 2.02226624871116645580e-21).
-define(PIO2_3T, 8.47842766036889956997e-32).
-define(NPIO2_HW, {
    16#3FF921FB, 16#400921FB, 16#4012D97C, 16#401921FB, 16#401F6A7A, 16#4022D97C, 16#4025FDBB, 16#402921FB,
    16#402C463A, 16#402F6A7A, 16#4031475C, 16#4032D97C, 16#40346B9C, 16#4035FDBB, 16#40378FDB, 16#403921FB,
    16#403AB41B, 16#403C463A, 16#403DD85A, 16#403F6A7A, 16#40407E4C, 16#4041475C, 16#4042106C, 16#4042D97C,
    16#4043A28C, 16#40446B9C, 16#404534AC, 16#4045FDBB, 16#4046C6CB, 16#40478FDB, 16#404858EB, 16#404921FB
}).
-define(PIO2_HI, 1.57079632679489655800e+00).
-define(PIO2_LO, 6.12323399573676603587e-17).
-define(PIO4_HI, 7.85398163397448278999e-01).
-define(PI, 3.1415926535897931160e+00).
-define(PS0, 1.66666666666666657415e-01).
-define(PS1, -3.25565818622400915405e-01).
-define(PS2, 2.01212532134862925881e-01).
-define(PS3, -4.00555345006794114027e-02).
-define(PS4, 7.91534994289814532176e-04).
-define(PS5, 3.47933107596021167570e-05).
-define(QS1, -2.40339491173441421878e+00).
-define(QS2, 2.02094576023350569471e+00).
-define(QS3, -6.88283971605453293030e-01).
-define(QS4, 7.70381505559019352791e-02).
-define(ATANHI, {4.63647609000806093515e-01, 7.85398163397448278999e-01, 9.82793723247329054082e-01, 1.57079632679489655800e+00}).
-define(ATANLO, {2.26987774529616870924e-17, 3.06161699786838301793e-17, 1.39033110312309984516e-17, 6.12323399573676603587e-17}).
-define(ATANHI3, 1.57079632679489655800e+00).
-define(ATANLO3, 6.12323399573676603587e-17).
-define(AT, {
    3.33333333333329318027e-01, -1.99999999998764832476e-01, 1.42857142725034663711e-01,
    -1.11111104054623557880e-01, 9.09088713343650656196e-02, -7.69187620504482999495e-02,
    6.66107313738753120669e-02, -5.83357013379057348645e-02, 4.97687799461593236017e-02,
    -3.65315727442169155270e-02, 1.62858201153657823623e-02
}).
-define(PI_O_2, 1.5707963267948965580e+00).
-define(PI_O_4, 7.8539816339744827900e-01).
-define(PI_LO, 1.2246467991473531772e-16).
-define(LN2, 6.93147180559945286227e-01).

-spec '$member'(binary()) -> term().
'$member'(<<"PI">>) -> 3.141592653589793;
'$member'(<<"E">>) -> 2.718281828459045;
'$member'(<<"LN2">>) -> 0.6931471805599453;
'$member'(<<"LN10">>) -> 2.302585092994046;
'$member'(<<"LOG2E">>) -> 1.4426950408889634;
'$member'(<<"LOG10E">>) -> 0.4342944819032518;
'$member'(<<"SQRT2">>) -> 1.4142135623730951;
'$member'(<<"SQRT1_2">>) -> 0.7071067811865476;
'$member'(Name) -> buoy_rt:member_function(?MODULE, Name, ?FUNCTIONS).

%%% Rounding: an integral result within the safe range is an integer,
%%% except negative zero, which stays the float -0.0 as in JavaScript.

-spec floor(list()) -> js_number().
floor(Args) -> integral(fun math:floor/1, number(Args)).

-spec ceil(list()) -> js_number().
ceil(Args) -> integral(fun math:ceil/1, number(Args)).

-spec trunc(list()) -> js_number().
trunc(Args) -> integral(fun toward_zero/1, number(Args)).

%% Halves round toward +Infinity. `x - floor(x)` is exact, so 0.49999999999999994
%% rounds down where `floor(x + 0.5)` would round up.
-spec round(list()) -> js_number().
round(Args) -> integral(fun half_up/1, number(Args)).

half_up(F) when F < 0, F >= -0.5 ->
    -0.0;
half_up(F) ->
    Floor = math:floor(F),
    case F - Floor >= 0.5 of
        true -> Floor + 1.0;
        false -> Floor
    end.

toward_zero(F) when F < 0 -> math:ceil(F);
toward_zero(F) -> math:floor(F).

integral(_Round, N) when is_integer(N); is_atom(N) -> N;
integral(Round, F) -> safe_integer(Round(F)).

safe_integer(F) when F == 0 -> integer_zero(F);
safe_integer(F) when erlang:abs(F) =< ?SAFE -> erlang:trunc(F);
safe_integer(F) -> F.

integer_zero(Zero) ->
    case is_negative_zero(Zero) of
        true -> -0.0;
        false -> 0
    end.

is_negative_zero(F) -> is_float(F) andalso F == 0 andalso <<F/float>> =/= <<0.0/float>>.

%%% Sign and magnitude

-spec abs(list()) -> js_number().
abs(Args) ->
    case number(Args) of
        '-Infinity' -> 'Infinity';
        N when is_number(N) -> erlang:abs(N);
        N -> N
    end.

-spec sign(list()) -> js_number().
sign(Args) ->
    case number(Args) of
        'NaN' -> 'NaN';
        'Infinity' -> 1;
        '-Infinity' -> -1;
        N when N > 0 -> 1;
        N when N < 0 -> -1;
        Zero -> Zero
    end.

-spec max(list()) -> js_number().
max(Args) -> extreme(fun max_beats/2, '-Infinity', numbers(Args)).

-spec min(list()) -> js_number().
min(Args) -> extreme(fun min_beats/2, 'Infinity', numbers(Args)).

%% +0 is larger than -0 for max and min.
max_beats(N, Best) when N == 0, Best == 0 -> is_negative_zero(Best) andalso not is_negative_zero(N);
max_beats(N, Best) -> buoy_rt:gt(N, Best).

min_beats(N, Best) when N == 0, Best == 0 -> is_negative_zero(N) andalso not is_negative_zero(Best);
min_beats(N, Best) -> buoy_rt:lt(N, Best).

extreme(Beats, Initial, Numbers) ->
    case lists:member('NaN', Numbers) of
        true -> 'NaN';
        false -> lists:foldl(fun(N, Best) -> pick(Beats(N, Best), N, Best) end, Initial, Numbers)
    end.

pick(true, N, _Best) -> N;
pick(false, _N, Best) -> Best.

-spec pow(list()) -> js_number().
pow(Args) -> buoy_rt:power(buoy_rt:arg(1, Args), buoy_rt:arg(2, Args)).

-spec random(list()) -> float().
random(_Args) -> rand:uniform().

-spec sqrt(list()) -> js_number().
sqrt(Args) ->
    case double(Args) of
        X when is_float(X), X >= 0 -> math:sqrt(X);
        X when is_float(X) -> 'NaN';
        'Infinity' -> 'Infinity';
        _ -> 'NaN'
    end.

%% V8's algorithm: scale by the largest magnitude, then a Kahan sum. V8
%% writes it in Torque, so no multiply-add is fused here.
-spec hypot(list()) -> js_number().
hypot(Args) ->
    Numbers = numbers(Args),
    Infinite = lists:any(fun(N) -> N =:= 'Infinity' orelse N =:= '-Infinity' end, Numbers),
    NaN = lists:member('NaN', Numbers),
    if
        Infinite -> 'Infinity';
        NaN -> 'NaN';
        true -> scaled_hypot([erlang:abs(float(N)) || N <- Numbers])
    end.

scaled_hypot(Magnitudes) ->
    case lists:max([0.0 | Magnitudes]) of
        Max when Max == 0 ->
            0;
        Max ->
            {Sum, _} = lists:foldl(fun(M, Acc) -> kahan_add(M / Max, Acc) end, {0.0, 0.0}, Magnitudes),
            math:sqrt(Sum) * Max
    end.

kahan_add(N, {Sum, Compensation}) ->
    Summand = N * N - Compensation,
    Preliminary = Sum + Summand,
    {Preliminary, (Preliminary - Sum) - Summand}.

%% Rounds to the nearest 32-bit float.
-spec fround(list()) -> js_number().
fround(Args) ->
    case number(Args) of
        N when is_atom(N) -> N;
        N when erlang:abs(N) > 3.5e38 -> buoy_rt:signed_infinity(N);
        N -> single(<<(float(N)):32/float>>, N)
    end.

%% A double just under the float32 maximum can still round up to infinity.
single(<<F:32/float>>, _N) -> F;
single(_Infinity, N) -> buoy_rt:signed_infinity(N).

-spec clz32(list()) -> 0..32.
clz32(Args) ->
    case buoy_rt:to_uint32(buoy_rt:arg(1, Args)) of
        0 -> 32;
        U -> 32 - length(integer_to_list(U, 2))
    end.

-spec imul(list()) -> integer().
imul(Args) ->
    buoy_rt:to_int32(buoy_rt:to_int32(buoy_rt:arg(1, Args)) * buoy_rt:to_int32(buoy_rt:arg(2, Args))).

%%% Transcendental functions: special values first, then the fdlibm port.

-spec sin(list()) -> js_number().
sin(Args) -> finite_only(fun sin_finite/1, double(Args)).

-spec cos(list()) -> js_number().
cos(Args) -> finite_only(fun cos_finite/1, double(Args)).

-spec tan(list()) -> js_number().
tan(Args) -> finite_only(fun tan_finite/1, double(Args)).

finite_only(F, X) when is_float(X) -> F(X);
finite_only(_F, _X) -> 'NaN'.

-spec exp(list()) -> js_number().
exp(Args) ->
    case double(Args) of
        X when is_float(X) -> exp_finite(X);
        '-Infinity' -> 0;
        Special -> Special
    end.

-spec expm1(list()) -> js_number().
expm1(Args) ->
    case double(Args) of
        X when is_float(X) -> expm1_finite(X);
        '-Infinity' -> -1;
        Special -> Special
    end.

-spec log(list()) -> js_number().
log(Args) -> logarithm(fun log_finite/1, double(Args)).

-spec log2(list()) -> js_number().
log2(Args) -> logarithm(fun log2_finite/1, double(Args)).

-spec log10(list()) -> js_number().
log10(Args) -> logarithm(fun log10_finite/1, double(Args)).

logarithm(F, X) when is_float(X), X > 0 -> F(X);
logarithm(_F, X) when is_float(X), X == 0 -> '-Infinity';
logarithm(_F, 'Infinity') -> 'Infinity';
logarithm(_F, _X) -> 'NaN'.

-spec log1p(list()) -> js_number().
log1p(Args) ->
    case double(Args) of
        X when is_float(X), X > -1 -> log1p_finite(X);
        X when is_float(X), X == -1 -> '-Infinity';
        'Infinity' -> 'Infinity';
        _ -> 'NaN'
    end.

-spec cbrt(list()) -> js_number().
cbrt(Args) ->
    case double(Args) of
        X when is_float(X), X == 0 -> X;
        X when is_float(X) -> cbrt_finite(X);
        Special -> Special
    end.

-spec asin(list()) -> js_number().
asin(Args) ->
    case double(Args) of
        X when is_float(X), erlang:abs(X) < 1 -> asin_finite(X);
        X when is_float(X), erlang:abs(X) == 1 -> fma(X, ?PIO2_HI, X * ?PIO2_LO);
        _ -> 'NaN'
    end.

-spec acos(list()) -> js_number().
acos(Args) ->
    case double(Args) of
        X when is_float(X), erlang:abs(X) < 1 -> acos_finite(X);
        X when is_float(X), X == 1 -> 0.0;
        X when is_float(X), X == -1 -> fma(2.0, ?PIO2_LO, ?PI);
        _ -> 'NaN'
    end.

-spec atan(list()) -> js_number().
atan(Args) ->
    case double(Args) of
        X when is_float(X) -> atan_finite(X);
        'Infinity' -> ?ATANHI3 + ?ATANLO3;
        '-Infinity' -> -?ATANHI3 - ?ATANLO3;
        'NaN' -> 'NaN'
    end.

-spec atan2(list()) -> js_number().
atan2(Args) ->
    atan2(double(Args), double(tl_args(Args))).

tl_args([_ | Rest]) -> Rest;
tl_args([]) -> [].

-spec sinh(list()) -> js_number().
sinh(Args) ->
    case double(Args) of
        X when is_float(X) -> sinh_finite(X);
        Special -> Special
    end.

-spec cosh(list()) -> js_number().
cosh(Args) ->
    case double(Args) of
        X when is_float(X) -> cosh_finite(X);
        'NaN' -> 'NaN';
        _ -> 'Infinity'
    end.

-spec tanh(list()) -> js_number().
tanh(Args) ->
    case double(Args) of
        X when is_float(X) -> tanh_finite(X);
        'Infinity' -> 1;
        '-Infinity' -> -1;
        'NaN' -> 'NaN'
    end.

-spec asinh(list()) -> js_number().
asinh(Args) ->
    case double(Args) of
        X when is_float(X) -> asinh_finite(X);
        Special -> Special
    end.

-spec acosh(list()) -> js_number().
acosh(Args) ->
    case double(Args) of
        X when is_float(X), X >= 1 -> acosh_finite(X);
        'Infinity' -> 'Infinity';
        _ -> 'NaN'
    end.

-spec atanh(list()) -> js_number().
atanh(Args) ->
    case double(Args) of
        X when is_float(X), erlang:abs(X) < 1 -> atanh_finite(X);
        X when is_float(X), X == 1 -> 'Infinity';
        X when is_float(X), X == -1 -> '-Infinity';
        _ -> 'NaN'
    end.

%%% Arguments

number(Args) -> buoy_rt:to_number(buoy_rt:arg(1, Args)).

numbers(Args) -> [buoy_rt:to_number(Arg) || Arg <- Args].

%% The first argument as a double: an integer beyond the double range
%% becomes an infinity.
-spec double(list()) -> double().
double(Args) ->
    case number(Args) of
        I when is_integer(I) ->
            try float(I) of
                F -> F
            catch
                error:badarg -> buoy_rt:signed_infinity(I)
            end;
        N ->
            N
    end.

%%% Doubles as words, as fdlibm reads them

high(X) ->
    <<H:32, _:32>> = <<X/float>>,
    H.

signed_high(X) ->
    <<H:32/signed, _:32>> = <<X/float>>,
    H.

low(X) ->
    <<_:32, L:32>> = <<X/float>>,
    L.

from_words(High, Low) ->
    <<X/float>> = <<High:32, Low:32>>,
    X.

with_low_zero(X) ->
    from_words(high(X), 0).

%% Y * 2^K.
scale(Y, K) when K >= -1021, K =< 1023 -> Y * from_words(16#3ff00000 + (K bsl 20), 0);
scale(Y, 1024) -> Y * 2.0 * 8.98846567431158e307;
scale(Y, K) -> Y * from_words(16#3ff00000 + ((K + 1000) bsl 20), 0) * 9.33263618503218878990e-302.

%%% Fused multiply-add

%% round(A * B + C) with one rounding. Dekker's product and Knuth's sum
%% give the exact error terms in doubles; when the last sum is not exact,
%% or the operands are near the ends of the double range, the exact
%% integer path decides.
fma(A, B, C) when erlang:abs(A) < 1.0e290, erlang:abs(B) < 1.0e290 ->
    P = A * B,
    case erlang:abs(P) > 1.0e-280 orelse P == 0 of
        true -> fma_double(A, B, C, P);
        false -> fma_exact(A, B, C)
    end;
fma(A, B, C) ->
    fma_exact(A, B, C).

fma_double(A, B, C, P) ->
    {Ah, Al} = split(A),
    {Bh, Bl} = split(B),
    E = (((Ah * Bh - P) + Ah * Bl) + Al * Bh) + Al * Bl,
    S = P + C,
    Bv = S - P,
    T = (P - (S - Bv)) + (C - Bv),
    U = T + E,
    Uv = U - T,
    case (T - (U - Uv)) + (E - Uv) == 0 of
        true -> S + U;
        false -> fma_exact(A, B, C)
    end.

split(A) ->
    C = 134217729.0 * A,
    High = C - (C - A),
    {High, A - High}.

fma_exact(A, B, C) ->
    {Ma, Ea} = parts(A),
    {Mb, Eb} = parts(B),
    {Mc, Ec} = parts(C),
    Ep = Ea + Eb,
    E = min(Ep, Ec),
    case ((Ma * Mb) bsl (Ep - E)) + (Mc bsl (Ec - E)) of
        0 -> A * B + C;
        N -> round_dyadic(N, E)
    end.

%% A finite double as Mantissa * 2^Exponent.
parts(X) ->
    <<Sign:1, Exponent:11, Fraction:52>> = <<X/float>>,
    {M, E} =
        case Exponent of
            0 -> {Fraction, -1074};
            _ -> {Fraction bor (1 bsl 52), Exponent - 1075}
        end,
    case Sign of
        0 -> {M, E};
        1 -> {-M, E}
    end.

%% The double nearest to N * 2^E, ties to even.
round_dyadic(N, E) when N < 0 ->
    -round_dyadic(-N, E);
round_dyadic(N, E) ->
    Shift = max(bit_length(N) - 53, -1074 - E),
    case Shift > 0 of
        true -> to_double(round_shift(N, Shift), E + Shift);
        false -> to_double(N bsl -Shift, E + Shift)
    end.

round_shift(N, Shift) ->
    Quotient = N bsr Shift,
    Remainder = N - (Quotient bsl Shift),
    Half = 1 bsl (Shift - 1),
    if
        Remainder > Half -> Quotient + 1;
        Remainder < Half -> Quotient;
        Quotient band 1 =:= 1 -> Quotient + 1;
        true -> Quotient
    end.

to_double(M, E) when M >= 1 bsl 53 ->
    to_double(M bsr 1, E + 1);
to_double(M, E) when M >= 1 bsl 52 ->
    <<X/float>> = <<0:1, (E + 1075):11, (M - (1 bsl 52)):52>>,
    X;
to_double(M, -1074) ->
    <<X/float>> = <<0:1, 0:11, M:52>>,
    X.

bit_length(N) -> bit_length(N, 0).

bit_length(0, Length) -> Length;
bit_length(N, Length) when N >= 1 bsl 64 -> bit_length(N bsr 64, Length + 64);
bit_length(N, Length) -> bit_length(N bsr 1, Length + 1).

%%% exp and expm1 (e_exp.c, s_expm1.c)

%% V8 returns E for exp(1), where the reduction would miss the last bit.
exp_finite(X) when X == 1.0 ->
    2.718281828459045;
exp_finite(X) ->
    Hx = high(X) band 16#7fffffff,
    if
        X > 7.09782712893383973096e+02 -> 'Infinity';
        X < -7.45133219101941108420e+02 -> 0.0;
        Hx > 16#3fd62e42 ->
            {Hi, Lo, K} = reduce_ln2(X, Hx),
            exp_reduced(Hi - Lo, Hi, Lo, K);
        Hx < 16#3e300000 -> 1.0 + X;
        true -> exp_reduced(X, 0.0, 0.0, 0)
    end.

%% x = K * ln2 + (Hi - Lo).
reduce_ln2(X, Hx) when Hx < 16#3FF0A2B2, X > 0 ->
    {X - ?LN2_HI, ?LN2_LO, 1};
reduce_ln2(X, Hx) when Hx < 16#3FF0A2B2 ->
    {X + ?LN2_HI, -?LN2_LO, -1};
reduce_ln2(X, _Hx) ->
    Half =
        case X > 0 of
            true -> 0.5;
            false -> -0.5
        end,
    K = erlang:trunc(fma(?INVLN2, X, Half)),
    T = float(K),
    {fma(-T, ?LN2_HI, X), T * ?LN2_LO, K}.

exp_reduced(X, Hi, Lo, K) ->
    T = X * X,
    C = fma(-T, fma(T, fma(T, fma(T, fma(T, ?P5, ?P4), ?P3), ?P2), ?P1), X),
    case K of
        0 -> 1.0 - ((X * C) / (C - 2.0) - X);
        _ -> scale(1.0 - ((Lo - (X * C) / (2.0 - C)) - Hi), K)
    end.

expm1_finite(X) ->
    Hx = high(X) band 16#7fffffff,
    if
        Hx >= 16#4043687A, X < 0 -> -1.0;
        X > 7.09782712893383973096e+02 -> 'Infinity';
        Hx > 16#3fd62e42 ->
            {Hi, Lo, K} = reduce_ln2(X, Hx),
            Reduced = Hi - Lo,
            expm1_reduced(Reduced, (Hi - Reduced) - Lo, K);
        Hx < 16#3c900000 -> X;
        true -> expm1_reduced(X, 0.0, 0)
    end.

expm1_reduced(X, C, K) ->
    Hfx = 0.5 * X,
    Hxs = X * Hfx,
    R1 = fma(Hxs, fma(Hxs, fma(Hxs, fma(Hxs, fma(Hxs, ?Q5, ?Q4), ?Q3), ?Q2), ?Q1), 1.0),
    T = fma(-R1, Hfx, 3.0),
    E = Hxs * ((R1 - T) / fma(-X, T, 6.0)),
    case K of
        0 -> X - fma(X, E, -Hxs);
        _ -> expm1_scaled(X, fma(X, E - C, -C) - Hxs, K)
    end.

expm1_scaled(X, E, -1) -> fma(0.5, X - E, -0.5);
expm1_scaled(X, E, 1) when X < -0.25 -> -2.0 * (E - (X + 0.5));
expm1_scaled(X, E, 1) -> fma(2.0, X - E, 1.0);
expm1_scaled(X, E, K) when K =< -2; K > 56 -> scale(1.0 - (E - X), K) - 1.0;
expm1_scaled(X, E, K) when K < 20 -> scale(from_words(16#3ff00000 - (16#200000 bsr K), 0) - (E - X), K);
expm1_scaled(X, E, K) -> scale((X - (E + from_words((16#3ff - K) bsl 20, 0))) + 1.0, K).

%%% Logarithms (e_log.c, e_log2.c, e_log10.c, s_log1p.c)

%% {F, K, Hx}: x = 2^K * (1 + F), with 1 + F in [sqrt(2)/2, sqrt(2)].
normalize(X0) ->
    {X, K0} =
        case high(X0) < 16#00100000 of
            true -> {X0 * 18014398509481984.0, -54};
            false -> {X0, 0}
        end,
    Hx = high(X) band 16#000fffff,
    I = (Hx + 16#95f64) band 16#100000,
    Normal = from_words(Hx bor (I bxor 16#3ff00000), low(X)),
    {Normal - 1.0, K0 + (high(X) bsr 20) - 1023 + (I bsr 20), Hx}.

log_finite(X) ->
    {F, K, Hx} = normalize(X),
    Dk = float(K),
    case (16#000fffff band (2 + Hx)) < 3 of
        true -> log_near_one(F, K, Dk);
        false -> log_series(F, K, Dk, Hx)
    end.

log_near_one(F, 0, _Dk) when F == 0 ->
    0.0;
log_near_one(F, _K, Dk) when F == 0 ->
    fma(Dk, ?LN2_HI, Dk * ?LN2_LO);
log_near_one(F, K, Dk) ->
    R = F * F * fma(-0.33333333333333333, F, 0.5),
    case K of
        0 -> F - R;
        _ -> fma(Dk, ?LN2_HI, -((R - Dk * ?LN2_LO) - F))
    end.

log_series(F, K, Dk, Hx) ->
    S = F / (2.0 + F),
    Z = S * S,
    W = Z * Z,
    T1 = W * fma(W, fma(W, ?LG6, ?LG4), ?LG2),
    T2 = Z * fma(W, fma(W, fma(W, ?LG7, ?LG5), ?LG3), ?LG1),
    R = T2 + T1,
    case ((Hx - 16#6147a) bor (16#6b851 - Hx)) > 0 of
        true ->
            Hfsq = 0.5 * F * F,
            case K of
                0 -> F - fma(-S, Hfsq + R, Hfsq);
                _ -> fma(Dk, ?LN2_HI, -((Hfsq - fma(S, Hfsq + R, Dk * ?LN2_LO)) - F))
            end;
        false ->
            case K of
                0 -> fma(-S, F - R, F);
                _ -> fma(Dk, ?LN2_HI, -(fma(S, F - R, -(Dk * ?LN2_LO)) - F))
            end
    end.

log2_finite(X) ->
    {F, K, _Hx} = normalize(X),
    Y = float(K),
    Hfsq = 0.5 * F * F,
    Hi = with_low_zero(F - Hfsq),
    Lo = ((F - Hi) - Hfsq) + log1p_kernel(F),
    ValHi = Hi * ?IVLN2HI,
    ValLo = fma(Lo + Hi, ?IVLN2LO, Lo * ?IVLN2HI),
    W = Y + ValHi,
    (ValLo + ((Y - W) + ValHi)) + W.

%% k_log1p from k_log.h: log(1 + f) - f + f * f / 2.
log1p_kernel(F) ->
    S = F / (2.0 + F),
    Z = S * S,
    W = Z * Z,
    T1 = W * fma(W, fma(W, ?LG6, ?LG4), ?LG2),
    T2 = Z * fma(W, fma(W, fma(W, ?LG7, ?LG5), ?LG3), ?LG1),
    S * (0.5 * F * F + (T2 + T1)).

log10_finite(X0) ->
    {X, K0} =
        case high(X0) < 16#00100000 of
            true -> {X0 * 18014398509481984.0, -54};
            false -> {X0, 0}
        end,
    K = K0 + (high(X) bsr 20) - 1023,
    I =
        case K < 0 of
            true -> 1;
            false -> 0
        end,
    Y = float(K + I),
    Mantissa = from_words((high(X) band 16#000fffff) bor ((16#3ff - I) bsl 20), low(X)),
    fma(Y, ?LOG10_2HI, fma(Y, ?LOG10_2LO, ?IVLN10 * log_finite(Mantissa))).

%% x > -1.
log1p_finite(X) ->
    Hx = signed_high(X),
    Ax = Hx band 16#7fffffff,
    if
        Hx < 16#3FDA827A, Ax < 16#3c900000 -> X;
        Hx < 16#3FDA827A, Ax < 16#3e200000 -> fma(-(X * X), 0.5, X);
        Hx < 16#3FDA827A, Hx > 0; Hx < 16#3FDA827A, Hx =< -1076707644 -> log1p_reduced(X, 0, 0.0, 1);
        true -> log1p_scaled(X, Hx)
    end.

log1p_scaled(X, Hx) ->
    {U0, C} =
        case Hx < 16#43400000 of
            true ->
                Sum = 1.0 + X,
                Correction =
                    case (high(Sum) bsr 20) - 1023 > 0 of
                        true -> 1.0 - (Sum - X);
                        false -> X - (Sum - 1.0)
                    end,
                {Sum, Correction / Sum};
            false ->
                {X, 0.0}
        end,
    K0 = (high(U0) bsr 20) - 1023,
    Hu0 = high(U0) band 16#000fffff,
    case Hu0 < 16#6a09e of
        true -> log1p_reduced(from_words(Hu0 bor 16#3ff00000, low(U0)) - 1.0, K0, C, Hu0);
        false -> log1p_reduced(from_words(Hu0 bor 16#3fe00000, low(U0)) - 1.0, K0 + 1, C, (16#00100000 - Hu0) bsr 2)
    end.

log1p_reduced(F, K, C, Hu) ->
    Hfsq = 0.5 * F * F,
    Dk = float(K),
    if
        Hu == 0, F == 0, K == 0 ->
            0.0;
        Hu == 0, F == 0 ->
            fma(Dk, ?LN2_HI, fma(Dk, ?LN2_LO, C));
        Hu == 0 ->
            R = Hfsq * fma(-0.66666666666666666, F, 1.0),
            case K of
                0 -> F - R;
                _ -> fma(Dk, ?LN2_HI, -((R - fma(Dk, ?LN2_LO, C)) - F))
            end;
        true ->
            S = F / (2.0 + F),
            Z = S * S,
            R = Z * fma(Z, fma(Z, fma(Z, fma(Z, fma(Z, fma(Z, ?LP7, ?LP6), ?LP5), ?LP4), ?LP3), ?LP2), ?LP1),
            case K of
                0 -> F - fma(-S, Hfsq + R, Hfsq);
                _ -> fma(Dk, ?LN2_HI, -((Hfsq - fma(S, Hfsq + R, fma(Dk, ?LN2_LO, C))) - F))
            end
    end.

%%% Cube root (FreeBSD s_cbrt.c)

cbrt_finite(X) ->
    <<Sign:1, _:63>> = <<X/float>>,
    Hx = high(X) band 16#7fffffff,
    Estimate =
        case Hx < 16#00100000 of
            true ->
                Scaled = from_words(16#43500000, 0) * X,
                from_words((Sign bsl 31) bor ((high(Scaled) band 16#7fffffff) div 3 + 696219795), 0);
            false ->
                from_words((Sign bsl 31) bor (Hx div 3 + 715094163), 0)
        end,
    R = (Estimate * Estimate) * (Estimate / X),
    Polynomial = fma(
        (R * R) * R,
        fma(R, 0.145996192886612446982, -0.758397934778766047437),
        fma(R, fma(R, 1.621429720105354466140, -1.88497979543377169875), 1.87595182427177009643)
    ),
    <<Bits:64>> = <<(Estimate * Polynomial)/float>>,
    <<T/float>> = <<((Bits + 16#80000000) band 16#ffffffffc0000000):64>>,
    Quotient = X / (T * T),
    fma(T, (Quotient - T) / ((T + T) + Quotient), T).

%%% sin, cos, tan (s_sin.c, s_cos.c, s_tan.c and their kernels)

%% |x| <= pi/4 needs no reduction.
is_small(X) -> (high(X) band 16#7fffffff) =< 16#3fe921fb.

sin_finite(X) ->
    case is_small(X) of
        true ->
            kernel_sin(X, 0.0, 0);
        false ->
            {N, Y0, Y1} = rem_pio2(X),
            quadrant_sin(N band 3, Y0, Y1)
    end.

quadrant_sin(0, Y0, Y1) -> kernel_sin(Y0, Y1, 1);
quadrant_sin(1, Y0, Y1) -> kernel_cos(Y0, Y1);
quadrant_sin(2, Y0, Y1) -> -kernel_sin(Y0, Y1, 1);
quadrant_sin(3, Y0, Y1) -> -kernel_cos(Y0, Y1).

cos_finite(X) ->
    case is_small(X) of
        true ->
            kernel_cos(X, 0.0);
        false ->
            {N, Y0, Y1} = rem_pio2(X),
            quadrant_sin((N + 1) band 3, Y0, Y1)
    end.

tan_finite(X) ->
    case is_small(X) of
        true ->
            kernel_tan(X, 0.0, 1);
        false ->
            {N, Y0, Y1} = rem_pio2(X),
            kernel_tan(Y0, Y1, 1 - ((N band 1) bsl 1))
    end.

kernel_sin(X, Y, Iy) ->
    case (high(X) band 16#7fffffff) < 16#3e400000 andalso erlang:trunc(X) == 0 of
        true ->
            X;
        false ->
            Z = X * X,
            V = Z * X,
            R = fma(Z, fma(Z, fma(Z, fma(Z, ?S6, ?S5), ?S4), ?S3), ?S2),
            case Iy of
                0 -> fma(V, fma(Z, R, ?S1), X);
                _ -> X - fma(-V, ?S1, fma(Z, fma(0.5, Y, -(V * R)), -Y))
            end
    end.

kernel_cos(X, Y) ->
    Ix = high(X) band 16#7fffffff,
    case Ix < 16#3e400000 andalso erlang:trunc(X) == 0 of
        true ->
            1.0;
        false ->
            Z = X * X,
            R = Z * fma(Z, fma(Z, fma(Z, fma(Z, fma(Z, ?C6, ?C5), ?C4), ?C3), ?C2), ?C1),
            case Ix < 16#3FD33333 of
                true ->
                    1.0 - fma(0.5, Z, -fma(Z, R, -(X * Y)));
                false ->
                    Qx =
                        case Ix > 16#3fe90000 of
                            true -> 0.28125;
                            false -> from_words(Ix - 16#00200000, 0)
                        end,
                    (1.0 - Qx) - (fma(0.5, Z, -Qx) - fma(Z, R, -(X * Y)))
            end
    end.

tan_term(I) -> element(I + 1, ?T).

kernel_tan(X0, Y0, Iy) ->
    Hx = signed_high(X0),
    Ix = Hx band 16#7fffffff,
    case Ix < 16#3e300000 andalso erlang:trunc(X0) == 0 of
        true when Iy == 1 -> X0;
        true -> tan_reciprocal(X0, Y0, X0 + Y0);
        false when Ix >= 16#3FE59428 -> tan_polynomial(near_pio4(X0, Y0, Hx), 0.0, Iy, Hx, true);
        false -> tan_polynomial(X0, Y0, Iy, Hx, false)
    end.

%% pi/4 - |x|, for |x| >= 0.6744.
near_pio4(X, Y, Hx) when Hx < 0 -> (?PIO4 + X) + (?PIO4LO + Y);
near_pio4(X, Y, _Hx) -> (?PIO4 - X) + (?PIO4LO - Y).

tan_polynomial(X, Y, Iy, Hx, Large) ->
    Z = X * X,
    W = Z * Z,
    R0 = fma(W, fma(W, fma(W, fma(W, fma(W, tan_term(11), tan_term(9)), tan_term(7)), tan_term(5)), tan_term(3)), tan_term(1)),
    V = Z * fma(W, fma(W, fma(W, fma(W, fma(W, tan_term(12), tan_term(10)), tan_term(8)), tan_term(6)), tan_term(4)), tan_term(2)),
    S = Z * X,
    R = fma(tan_term(0), S, fma(Z, fma(S, R0 + V, Y), Y)),
    Sum = X + R,
    case {Large, Iy} of
        {true, _} ->
            Vf = float(Iy),
            float(1 - ((Hx bsr 30) band 2)) * (Vf - 2.0 * (X - (Sum * Sum / (Sum + Vf) - R)));
        {false, 1} ->
            Sum;
        {false, _} ->
            tan_reciprocal(X, R, Sum)
    end.

%% -1 / (x + r), computed carefully: w = x + r.
tan_reciprocal(X, R, W) ->
    Z = with_low_zero(W),
    V = R - (Z - X),
    A = -1.0 / W,
    T = with_low_zero(A),
    fma(A, fma(T, V, fma(T, Z, 1.0)), T).

%% {N, Y0, Y1}: x = N * pi/2 + Y0 + Y1 (e_rem_pio2.c), for |x| > pi/4.
rem_pio2(X) ->
    Hx = signed_high(X),
    Ix = Hx band 16#7fffffff,
    if
        Ix < 16#4002d97c, Hx > 0 -> near_pio2(X - ?PIO2_1, Ix, 1);
        Ix < 16#4002d97c -> near_pio2(X + ?PIO2_1, Ix, -1);
        Ix =< 16#413921fb -> medium(X, Hx, Ix);
        true -> large(X)
    end.

%% |x| < 3pi/4, one multiple of pi/2 away.
near_pio2(Z, 16#3ff921fb, Sign) ->
    Z2 = Z - Sign * ?PIO2_2,
    Y0 = Z2 - Sign * ?PIO2_2T,
    {Sign, Y0, (Z2 - Y0) - Sign * ?PIO2_2T};
near_pio2(Z, _Ix, Sign) ->
    Y0 = Z - Sign * ?PIO2_1T,
    {Sign, Y0, (Z - Y0) - Sign * ?PIO2_1T}.

%% |x| <= 2^19 * pi/2: Cody-Waite reduction in up to three steps.
medium(X, Hx, Ix) ->
    T = erlang:abs(X),
    N = erlang:trunc(fma(T, ?INVPIO2, 0.5)),
    Fn = float(N),
    R = fma(-Fn, ?PIO2_1, T),
    W = Fn * ?PIO2_1T,
    {R1, W1, Y0} =
        case N < 32 andalso Ix =/= element(N, ?NPIO2_HW) of
            true -> {R, W, R - W};
            false -> medium_steps(R, W, Fn, Ix bsr 20)
        end,
    Y1 = (R1 - Y0) - W1,
    case Hx < 0 of
        true -> {-N, -Y0, -Y1};
        false -> {N, Y0, Y1}
    end.

medium_steps(R, W, Fn, J) ->
    Y = R - W,
    case J - ((high(Y) bsr 20) band 16#7ff) > 16 of
        false ->
            {R, W, Y};
        true ->
            {R2, W2} = medium_step(R, Fn, ?PIO2_2, ?PIO2_2T),
            Y2 = R2 - W2,
            case J - ((high(Y2) bsr 20) band 16#7ff) > 49 of
                false ->
                    {R2, W2, Y2};
                true ->
                    {R3, W3} = medium_step(R2, Fn, ?PIO2_3, ?PIO2_3T),
                    {R3, W3, R3 - W3}
            end
    end.

medium_step(T, Fn, Pio2, Pio2T) ->
    W = Fn * Pio2,
    R = T - W,
    {R, fma(Fn, Pio2T, -((T - R) - W))}.

%% |x| > 2^19 * pi/2: exact reduction with the 1584 bits of 2/pi that
%% fdlibm uses, then Y0 and Y1 rounded from the exact remainder.
large(X) ->
    {M, E} = parts(erlang:abs(X)),
    Shift = 1584 - E,
    Product = M * two_over_pi(),
    Whole = Product bsr Shift,
    Fraction0 = Product - (Whole bsl Shift),
    {N, Fraction} =
        case Fraction0 >= 1 bsl (Shift - 1) of
            true -> {Whole + 1, Fraction0 - (1 bsl Shift)};
            false -> {Whole, Fraction0}
        end,
    %% pi/2 = PiHalf / 2^260.
    PiHalf = 16#1921FB54442D18469898CC51701B839A252049C1114CF98E804177D4C76273644A,
    Remainder = Fraction * PiHalf,
    Exponent = -(Shift + 260),
    Y0 = round_dyadic(Remainder, Exponent),
    Y1 =
        case Remainder - exact_integer(Y0, -Exponent) of
            0 -> 0.0;
            Rest -> round_dyadic(Rest, Exponent)
        end,
    case X < 0 of
        true -> {-(N band 7), -Y0, -Y1};
        false -> {N band 7, Y0, Y1}
    end.

two_over_pi() ->
    Chunks = [
        16#A2F983, 16#6E4E44, 16#1529FC, 16#2757D1, 16#F534DD, 16#C0DB62, 16#95993C, 16#439041, 16#FE5163,
        16#ABDEBB, 16#C561B7, 16#246E3A, 16#424DD2, 16#E00649, 16#2EEA09, 16#D1921C, 16#FE1DEB, 16#1CB129,
        16#A73EE8, 16#8235F5, 16#2EBB44, 16#84E99C, 16#7026B4, 16#5F7E41, 16#3991D6, 16#398353, 16#39F49C,
        16#845F8B, 16#BDF928, 16#3B1FF8, 16#97FFDE, 16#05980F, 16#EF2F11, 16#8B5A0A, 16#6D1F6D, 16#367ECF,
        16#27CB09, 16#B74F46, 16#3F669E, 16#5FEA2D, 16#7527BA, 16#C7EBE5, 16#F17B3D, 16#0739F7, 16#8A5292,
        16#EA6BFB, 16#5FB11F, 16#8D5D08, 16#560330, 16#46FC7B, 16#6BABF0, 16#CFBC20, 16#9AF436, 16#1DA9E3,
        16#91615E, 16#E61B08, 16#659985, 16#5F14A0, 16#68408D, 16#FFD880, 16#4D7327, 16#310606, 16#1556CA,
        16#73A8C9, 16#60E27B, 16#C08C6B
    ],
    lists:foldl(fun(Chunk, Acc) -> (Acc bsl 24) bor Chunk end, 0, Chunks).

%% Y * 2^Shift as an integer.
exact_integer(Y, Shift) ->
    {M, E} = parts(Y),
    case E + Shift >= 0 of
        true -> M bsl (E + Shift);
        false -> M bsr -(E + Shift)
    end.

%%% Inverse trigonometric functions (e_asin.c, e_acos.c, s_atan.c, e_atan2.c)

%% R(t) = p(t) / q(t), the rational approximation that asin and acos share.
arc_ratio(T) ->
    P = T * fma(T, fma(T, fma(T, fma(T, fma(T, ?PS5, ?PS4), ?PS3), ?PS2), ?PS1), ?PS0),
    Q = fma(T, fma(T, fma(T, fma(T, ?QS4, ?QS3), ?QS2), ?QS1), 1.0),
    P / Q.

%% |x| < 1.
asin_finite(X) ->
    Ix = high(X) band 16#7fffffff,
    if
        Ix < 16#3e400000 -> X;
        Ix < 16#3fe00000 -> fma(X, arc_ratio(X * X), X);
        X > 0 -> asin_upper(erlang:abs(X), Ix);
        true -> -asin_upper(erlang:abs(X), Ix)
    end.

asin_upper(A, Ix) ->
    T = (1.0 - A) * 0.5,
    Ratio = arc_ratio(T),
    S = math:sqrt(T),
    case Ix >= 16#3FEF3333 of
        true ->
            ?PIO2_HI - fma(2.0, fma(S, Ratio, S), -?PIO2_LO);
        false ->
            W = with_low_zero(S),
            C = fma(-W, W, T) / (S + W),
            P = fma(2.0 * S, Ratio, -fma(-2.0, C, ?PIO2_LO)),
            Q = fma(-2.0, W, ?PIO4_HI),
            ?PIO4_HI - (P - Q)
    end.

%% |x| < 1.
acos_finite(X) ->
    Ix = high(X) band 16#7fffffff,
    if
        Ix =< 16#3c600000 ->
            ?PIO2_HI + ?PIO2_LO;
        Ix < 16#3fe00000 ->
            ?PIO2_HI - (X - fma(-X, arc_ratio(X * X), ?PIO2_LO));
        X < 0 ->
            Z = (1.0 + X) * 0.5,
            S = math:sqrt(Z),
            W = fma(arc_ratio(Z), S, -?PIO2_LO),
            fma(-2.0, S + W, ?PI);
        true ->
            Z = (1.0 - X) * 0.5,
            S = math:sqrt(Z),
            Df = with_low_zero(S),
            C = fma(-Df, Df, Z) / (S + Df),
            2.0 * (Df + fma(arc_ratio(Z), S, C))
    end.

atan_term(I) -> element(I + 1, ?AT).

atan_finite(X) ->
    Hx = signed_high(X),
    Ix = Hx band 16#7fffffff,
    A = erlang:abs(X),
    if
        Ix >= 16#44100000, Hx > 0 -> ?ATANHI3 + ?ATANLO3;
        Ix >= 16#44100000 -> -?ATANHI3 - ?ATANLO3;
        Ix < 16#3e200000 -> X;
        Ix < 16#3fdc0000 -> atan_series(X, -1, Hx);
        Ix < 16#3fe60000 -> atan_series(fma(2.0, A, -1.0) / (2.0 + A), 0, Hx);
        Ix < 16#3ff30000 -> atan_series((A - 1.0) / (A + 1.0), 1, Hx);
        Ix < 16#40038000 -> atan_series((A - 1.5) / fma(1.5, A, 1.0), 2, Hx);
        true -> atan_series(-1.0 / A, 3, Hx)
    end.

atan_series(X, Id, Hx) ->
    Z = X * X,
    W = Z * Z,
    S1 = Z * fma(W, fma(W, fma(W, fma(W, fma(W, atan_term(10), atan_term(8)), atan_term(6)), atan_term(4)), atan_term(2)), atan_term(0)),
    S2 = W * fma(W, fma(W, fma(W, fma(W, atan_term(9), atan_term(7)), atan_term(5)), atan_term(3)), atan_term(1)),
    case Id of
        -1 ->
            fma(-X, S1 + S2, X);
        _ ->
            Z2 = element(Id + 1, ?ATANHI) - (fma(X, S1 + S2, -element(Id + 1, ?ATANLO)) - X),
            case Hx < 0 of
                true -> -Z2;
                false -> Z2
            end
    end.

atan2('NaN', _) -> 'NaN';
atan2(_, 'NaN') -> 'NaN';
atan2(Y, X) when X == 1.0 -> atan([Y]);
atan2(Y, X) -> atan2_signed(Y, X, quadrant(Y, X)).

%% 2 * sign(x) + sign(y), from the sign bits, so -0 counts as negative.
quadrant(Y, X) -> sign_bit(Y) bor (sign_bit(X) bsl 1).

sign_bit('-Infinity') -> 1;
sign_bit('Infinity') -> 0;
sign_bit(F) ->
    <<S:1, _:63>> = <<F/float>>,
    S.

atan2_signed(Y, _X, M) when is_float(Y), Y == 0, M < 2 -> Y;
atan2_signed(Y, _X, 2) when is_float(Y), Y == 0 -> ?PI;
atan2_signed(Y, _X, 3) when is_float(Y), Y == 0 -> -?PI;
atan2_signed(Y, X, M) when is_float(X), X == 0 -> atan2_axis(Y, M);
atan2_signed(Y, X, M) when is_atom(X), is_atom(Y) -> element(M + 1, {?PI_O_4, -?PI_O_4, 3.0 * ?PI_O_4, -3.0 * ?PI_O_4});
atan2_signed(_Y, X, M) when is_atom(X) -> element(M + 1, {0.0, -0.0, ?PI, -?PI});
atan2_signed(Y, _X, M) when is_atom(Y) -> atan2_axis(Y, M);
atan2_signed(Y, X, M) -> atan2_finite(Y, X, M).

atan2_axis(_Y, M) when M band 1 =:= 1 -> -?PI_O_2;
atan2_axis(_Y, _M) -> ?PI_O_2.

%% FreeBSD's version: past |y/x| > 2^60 the result is +-pi/2 whatever
%% the sign of x.
atan2_finite(Y, X, M) ->
    case ((high(Y) band 16#7fffffff) - (high(X) band 16#7fffffff)) bsr 20 of
        K when K > 60 -> atan2_quadrant(fma(0.5, ?PI_LO, ?PI_O_2), M band 1);
        K when X < 0, K < -60 -> atan2_quadrant(0.0, M);
        _ -> atan2_quadrant(atan_finite(erlang:abs(Y / X)), M)
    end.

atan2_quadrant(Z, M) ->
    case M of
        0 -> Z;
        1 -> -Z;
        2 -> ?PI - (Z - ?PI_LO);
        3 -> (Z - ?PI_LO) - ?PI
    end.

%%% Hyperbolic functions (V8's sinh, cosh, tanh; e_asinh.c, e_acosh.c, e_atanh.c)

sinh_finite(X) ->
    H =
        case X < 0 of
            true -> -0.5;
            false -> 0.5
        end,
    A = erlang:abs(X),
    if
        A < 3.725290298461914e-9 -> X;
        A < 1 -> T = expm1_finite(A), H * fma(2.0, T, -(T * T / (T + 1.0)));
        A < 22 -> T = expm1_finite(A), H * (T + T / (T + 1.0));
        A < 709.7822265625 -> H * exp_finite(A);
        A =< 710.4758600739439 -> W = exp_finite(0.5 * A), (H * W) * W;
        X > 0 -> 'Infinity';
        true -> '-Infinity'
    end.

cosh_finite(X) ->
    Ix = high(X) band 16#7fffffff,
    A = erlang:abs(X),
    if
        Ix < 16#3c800000 -> 1.0 + expm1_finite(A);
        Ix < 16#3fd62e43 -> T = expm1_finite(A), W = 1.0 + T, 1.0 + (T * T) / (W + W);
        Ix < 16#40360000 -> T = exp_finite(A), fma(0.5, T, 0.5 / T);
        Ix < 16#40862e42 -> 0.5 * exp_finite(A);
        A =< 710.4758600739439 -> W = exp_finite(0.5 * A), (0.5 * W) * W;
        true -> 'Infinity'
    end.

tanh_finite(X) ->
    Ix = high(X) band 16#7fffffff,
    A = erlang:abs(X),
    Z =
        if
            Ix >= 16#40360000 -> 1.0;
            Ix < 16#3e300000 -> A;
            Ix >= 16#3ff00000 -> 1.0 - 2.0 / (expm1_finite(2.0 * A) + 2.0);
            true -> T = expm1_finite(-2.0 * A), -T / (T + 2.0)
        end,
    case X < 0 orelse sign_bit(X) =:= 1 of
        true -> -Z;
        false -> Z
    end.

asinh_finite(X) ->
    Ix = high(X) band 16#7fffffff,
    A = erlang:abs(X),
    W =
        if
            Ix < 16#3e300000 -> A;
            Ix > 16#41b00000 -> log_finite(A) + ?LN2;
            Ix > 16#40000000 -> log_finite(fma(2.0, A, 1.0 / (math:sqrt(fma(X, X, 1.0)) + A)));
            true -> T = X * X, log1p_finite(A + T / (1.0 + math:sqrt(1.0 + T)))
        end,
    case sign_bit(X) of
        1 -> -W;
        0 -> W
    end.

%% x >= 1.
acosh_finite(X) ->
    Hx = high(X),
    if
        Hx >= 16#41b00000 -> log_finite(X) + ?LN2;
        X == 1 -> 0.0;
        Hx > 16#40000000 -> log_finite(fma(2.0, X, -(1.0 / (X + math:sqrt(X * X - 1.0)))));
        true -> T = X - 1.0, log1p_finite(T + math:sqrt(fma(2.0, T, T * T)))
    end.

%% |x| < 1.
atanh_finite(X) ->
    Ix = high(X) band 16#7fffffff,
    A = erlang:abs(X),
    T =
        if
            Ix < 16#3e300000 -> A;
            Ix < 16#3fe00000 -> Twice = A + A, 0.5 * log1p_finite(Twice + Twice * A / (1.0 - A));
            true -> 0.5 * log1p_finite((A + A) / (1.0 - A))
        end,
    case sign_bit(X) of
        1 -> -T;
        0 -> T
    end.
