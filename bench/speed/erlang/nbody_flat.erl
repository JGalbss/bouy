-module(nbody_flat).

%% NBody at the ceiling of BEAM for float code. The array has a constant length of 5 and
%% never escapes, and no code writes a mass, so the compiler can replace the five objects
%% with 30 float variables, fold the masses into constants, and unroll both loops. One
%% step is one function body, and the JIT keeps its floats in float registers. But
%% math:sqrt is an external call, so each of the 10 calls of a step boxes the floats that
%% live across it, and the 30 arguments of the tail call are boxed too: 2 words each.
%% The body of step/31 is unrolled mechanically: each pair (i, j) of nbody.ts in order,
%% with the same operations, so the energy matches Node and Bun bit for bit.

-export([main/1, iteration/1]).

-define(PI, 3.141592653589793).
-define(SOLAR_MASS, (4 * ?PI * ?PI)).
-define(DAYS_PER_YEAR, 365.24).
-define(DT, 0.01).
-define(M1, (9.54791938424326609e-4 * ?SOLAR_MASS)).
-define(M2, (2.85885980666130812e-4 * ?SOLAR_MASS)).
-define(M3, (4.36624404335156298e-5 * ?SOLAR_MASS)).
-define(M4, (5.15138902046611451e-5 * ?SOLAR_MASS)).

-spec main([string()]) -> no_return().
main(Args) ->
    speed_harness:bench(<<"nbody">>, 250000, fun iteration/1, Args).

iteration(Steps) ->
    Bodies = nbody_bodies(),
    {X0, Y0, Z0, Vx0, Vy0, Vz0, X1, Y1, Z1, Vx1, Vy1, Vz1, X2, Y2, Z2, Vx2, Vy2, Vz2, X3, Y3, Z3, Vx3, Vy3, Vz3, X4, Y4, Z4, Vx4, Vy4, Vz4} = Bodies,
    step(Steps, X0, Y0, Z0, Vx0, Vy0, Vz0, X1, Y1, Z1, Vx1, Vy1, Vz1, X2, Y2, Z2, Vx2, Vy2, Vz2, X3, Y3, Z3, Vx3, Vy3, Vz3, X4, Y4, Z4, Vx4, Vy4, Vz4).

%% The start of nbody.ts after offsetMomentum, with the sun's velocity first.
nbody_bodies() ->
    Vx1 = 1.66007664274403694e-3 * ?DAYS_PER_YEAR,
    Vy1 = 7.69901118419740425e-3 * ?DAYS_PER_YEAR,
    Vz1 = -6.90460016972063023e-5 * ?DAYS_PER_YEAR,
    Vx2 = -2.76742510726862411e-3 * ?DAYS_PER_YEAR,
    Vy2 = 4.99852801234917238e-3 * ?DAYS_PER_YEAR,
    Vz2 = 2.30417297573763929e-5 * ?DAYS_PER_YEAR,
    Vx3 = 2.96460137564761618e-3 * ?DAYS_PER_YEAR,
    Vy3 = 2.3784717395948095e-3 * ?DAYS_PER_YEAR,
    Vz3 = -2.96589568540237556e-5 * ?DAYS_PER_YEAR,
    Vx4 = 2.68067772490389322e-3 * ?DAYS_PER_YEAR,
    Vy4 = 1.62824170038242295e-3 * ?DAYS_PER_YEAR,
    Vz4 = -9.5159225451971587e-5 * ?DAYS_PER_YEAR,
    Px = 0.0 * ?SOLAR_MASS + Vx1 * ?M1 + Vx2 * ?M2 + Vx3 * ?M3 + Vx4 * ?M4,
    Py = 0.0 * ?SOLAR_MASS + Vy1 * ?M1 + Vy2 * ?M2 + Vy3 * ?M3 + Vy4 * ?M4,
    Pz = 0.0 * ?SOLAR_MASS + Vz1 * ?M1 + Vz2 * ?M2 + Vz3 * ?M3 + Vz4 * ?M4,
    {0.0, 0.0, 0.0, -Px / ?SOLAR_MASS, -Py / ?SOLAR_MASS, -Pz / ?SOLAR_MASS,
        4.8414314424647209, -1.16032004402742839, -1.03622044471123109e-1, Vx1, Vy1, Vz1,
        8.34336671824457987, 4.12479856412430479, -4.03523417114321381e-1, Vx2, Vy2, Vz2,
        1.2894369562139131e1, -1.51111514016986312e1, -2.23307578892655734e-1, Vx3, Vy3, Vz3,
        1.53796971148509165e1, -2.59193146099879641e1, 1.79258772950371181e-1, Vx4, Vy4, Vz4}.

step(Steps, X0, Y0, Z0, Vx0, Vy0, Vz0, X1, Y1, Z1, Vx1, Vy1, Vz1, X2, Y2, Z2, Vx2, Vy2, Vz2, X3, Y3, Z3, Vx3, Vy3, Vz3, X4, Y4, Z4, Vx4, Vy4, Vz4) when Steps > 0, is_float(X0), is_float(Y0), is_float(Z0), is_float(Vx0), is_float(Vy0), is_float(Vz0), is_float(X1), is_float(Y1), is_float(Z1), is_float(Vx1), is_float(Vy1), is_float(Vz1), is_float(X2), is_float(Y2), is_float(Z2), is_float(Vx2), is_float(Vy2), is_float(Vz2), is_float(X3), is_float(Y3), is_float(Z3), is_float(Vx3), is_float(Vy3), is_float(Vz3), is_float(X4), is_float(Y4), is_float(Z4), is_float(Vx4), is_float(Vy4), is_float(Vz4) ->
    Dx1 = X0 - X1,
    Dy1 = Y0 - Y1,
    Dz1 = Z0 - Z1,
    D1 = Dx1 * Dx1 + Dy1 * Dy1 + Dz1 * Dz1,
    Mag1 = ?DT / (D1 * math:sqrt(D1)),
    Ma1 = ?SOLAR_MASS * Mag1,
    Mb1 = ?M1 * Mag1,
    Vx0_1 = Vx0 - Dx1 * Mb1,
    Vx1_1 = Vx1 + Dx1 * Ma1,
    Vy0_1 = Vy0 - Dy1 * Mb1,
    Vy1_1 = Vy1 + Dy1 * Ma1,
    Vz0_1 = Vz0 - Dz1 * Mb1,
    Vz1_1 = Vz1 + Dz1 * Ma1,
    Dx2 = X0 - X2,
    Dy2 = Y0 - Y2,
    Dz2 = Z0 - Z2,
    D2 = Dx2 * Dx2 + Dy2 * Dy2 + Dz2 * Dz2,
    Mag2 = ?DT / (D2 * math:sqrt(D2)),
    Ma2 = ?SOLAR_MASS * Mag2,
    Mb2 = ?M2 * Mag2,
    Vx0_2 = Vx0_1 - Dx2 * Mb2,
    Vx2_2 = Vx2 + Dx2 * Ma2,
    Vy0_2 = Vy0_1 - Dy2 * Mb2,
    Vy2_2 = Vy2 + Dy2 * Ma2,
    Vz0_2 = Vz0_1 - Dz2 * Mb2,
    Vz2_2 = Vz2 + Dz2 * Ma2,
    Dx3 = X0 - X3,
    Dy3 = Y0 - Y3,
    Dz3 = Z0 - Z3,
    D3 = Dx3 * Dx3 + Dy3 * Dy3 + Dz3 * Dz3,
    Mag3 = ?DT / (D3 * math:sqrt(D3)),
    Ma3 = ?SOLAR_MASS * Mag3,
    Mb3 = ?M3 * Mag3,
    Vx0_3 = Vx0_2 - Dx3 * Mb3,
    Vx3_3 = Vx3 + Dx3 * Ma3,
    Vy0_3 = Vy0_2 - Dy3 * Mb3,
    Vy3_3 = Vy3 + Dy3 * Ma3,
    Vz0_3 = Vz0_2 - Dz3 * Mb3,
    Vz3_3 = Vz3 + Dz3 * Ma3,
    Dx4 = X0 - X4,
    Dy4 = Y0 - Y4,
    Dz4 = Z0 - Z4,
    D4 = Dx4 * Dx4 + Dy4 * Dy4 + Dz4 * Dz4,
    Mag4 = ?DT / (D4 * math:sqrt(D4)),
    Ma4 = ?SOLAR_MASS * Mag4,
    Mb4 = ?M4 * Mag4,
    Vx0_4 = Vx0_3 - Dx4 * Mb4,
    Vx4_4 = Vx4 + Dx4 * Ma4,
    Vy0_4 = Vy0_3 - Dy4 * Mb4,
    Vy4_4 = Vy4 + Dy4 * Ma4,
    Vz0_4 = Vz0_3 - Dz4 * Mb4,
    Vz4_4 = Vz4 + Dz4 * Ma4,
    Dx5 = X1 - X2,
    Dy5 = Y1 - Y2,
    Dz5 = Z1 - Z2,
    D5 = Dx5 * Dx5 + Dy5 * Dy5 + Dz5 * Dz5,
    Mag5 = ?DT / (D5 * math:sqrt(D5)),
    Ma5 = ?M1 * Mag5,
    Mb5 = ?M2 * Mag5,
    Vx1_5 = Vx1_1 - Dx5 * Mb5,
    Vx2_5 = Vx2_2 + Dx5 * Ma5,
    Vy1_5 = Vy1_1 - Dy5 * Mb5,
    Vy2_5 = Vy2_2 + Dy5 * Ma5,
    Vz1_5 = Vz1_1 - Dz5 * Mb5,
    Vz2_5 = Vz2_2 + Dz5 * Ma5,
    Dx6 = X1 - X3,
    Dy6 = Y1 - Y3,
    Dz6 = Z1 - Z3,
    D6 = Dx6 * Dx6 + Dy6 * Dy6 + Dz6 * Dz6,
    Mag6 = ?DT / (D6 * math:sqrt(D6)),
    Ma6 = ?M1 * Mag6,
    Mb6 = ?M3 * Mag6,
    Vx1_6 = Vx1_5 - Dx6 * Mb6,
    Vx3_6 = Vx3_3 + Dx6 * Ma6,
    Vy1_6 = Vy1_5 - Dy6 * Mb6,
    Vy3_6 = Vy3_3 + Dy6 * Ma6,
    Vz1_6 = Vz1_5 - Dz6 * Mb6,
    Vz3_6 = Vz3_3 + Dz6 * Ma6,
    Dx7 = X1 - X4,
    Dy7 = Y1 - Y4,
    Dz7 = Z1 - Z4,
    D7 = Dx7 * Dx7 + Dy7 * Dy7 + Dz7 * Dz7,
    Mag7 = ?DT / (D7 * math:sqrt(D7)),
    Ma7 = ?M1 * Mag7,
    Mb7 = ?M4 * Mag7,
    Vx1_7 = Vx1_6 - Dx7 * Mb7,
    Vx4_7 = Vx4_4 + Dx7 * Ma7,
    Vy1_7 = Vy1_6 - Dy7 * Mb7,
    Vy4_7 = Vy4_4 + Dy7 * Ma7,
    Vz1_7 = Vz1_6 - Dz7 * Mb7,
    Vz4_7 = Vz4_4 + Dz7 * Ma7,
    Dx8 = X2 - X3,
    Dy8 = Y2 - Y3,
    Dz8 = Z2 - Z3,
    D8 = Dx8 * Dx8 + Dy8 * Dy8 + Dz8 * Dz8,
    Mag8 = ?DT / (D8 * math:sqrt(D8)),
    Ma8 = ?M2 * Mag8,
    Mb8 = ?M3 * Mag8,
    Vx2_8 = Vx2_5 - Dx8 * Mb8,
    Vx3_8 = Vx3_6 + Dx8 * Ma8,
    Vy2_8 = Vy2_5 - Dy8 * Mb8,
    Vy3_8 = Vy3_6 + Dy8 * Ma8,
    Vz2_8 = Vz2_5 - Dz8 * Mb8,
    Vz3_8 = Vz3_6 + Dz8 * Ma8,
    Dx9 = X2 - X4,
    Dy9 = Y2 - Y4,
    Dz9 = Z2 - Z4,
    D9 = Dx9 * Dx9 + Dy9 * Dy9 + Dz9 * Dz9,
    Mag9 = ?DT / (D9 * math:sqrt(D9)),
    Ma9 = ?M2 * Mag9,
    Mb9 = ?M4 * Mag9,
    Vx2_9 = Vx2_8 - Dx9 * Mb9,
    Vx4_9 = Vx4_7 + Dx9 * Ma9,
    Vy2_9 = Vy2_8 - Dy9 * Mb9,
    Vy4_9 = Vy4_7 + Dy9 * Ma9,
    Vz2_9 = Vz2_8 - Dz9 * Mb9,
    Vz4_9 = Vz4_7 + Dz9 * Ma9,
    Dx10 = X3 - X4,
    Dy10 = Y3 - Y4,
    Dz10 = Z3 - Z4,
    D10 = Dx10 * Dx10 + Dy10 * Dy10 + Dz10 * Dz10,
    Mag10 = ?DT / (D10 * math:sqrt(D10)),
    Ma10 = ?M3 * Mag10,
    Mb10 = ?M4 * Mag10,
    Vx3_10 = Vx3_8 - Dx10 * Mb10,
    Vx4_10 = Vx4_9 + Dx10 * Ma10,
    Vy3_10 = Vy3_8 - Dy10 * Mb10,
    Vy4_10 = Vy4_9 + Dy10 * Ma10,
    Vz3_10 = Vz3_8 - Dz10 * Mb10,
    Vz4_10 = Vz4_9 + Dz10 * Ma10,
    X0n = X0 + ?DT * Vx0_4,
    Y0n = Y0 + ?DT * Vy0_4,
    Z0n = Z0 + ?DT * Vz0_4,
    X1n = X1 + ?DT * Vx1_7,
    Y1n = Y1 + ?DT * Vy1_7,
    Z1n = Z1 + ?DT * Vz1_7,
    X2n = X2 + ?DT * Vx2_9,
    Y2n = Y2 + ?DT * Vy2_9,
    Z2n = Z2 + ?DT * Vz2_9,
    X3n = X3 + ?DT * Vx3_10,
    Y3n = Y3 + ?DT * Vy3_10,
    Z3n = Z3 + ?DT * Vz3_10,
    X4n = X4 + ?DT * Vx4_10,
    Y4n = Y4 + ?DT * Vy4_10,
    Z4n = Z4 + ?DT * Vz4_10,
    step(Steps - 1, X0n, Y0n, Z0n, Vx0_4, Vy0_4, Vz0_4, X1n, Y1n, Z1n, Vx1_7, Vy1_7, Vz1_7, X2n, Y2n, Z2n, Vx2_9, Vy2_9, Vz2_9, X3n, Y3n, Z3n, Vx3_10, Vy3_10, Vz3_10, X4n, Y4n, Z4n, Vx4_10, Vy4_10, Vz4_10);
step(0, X0, Y0, Z0, Vx0, Vy0, Vz0, X1, Y1, Z1, Vx1, Vy1, Vz1, X2, Y2, Z2, Vx2, Vy2, Vz2, X3, Y3, Z3, Vx3, Vy3, Vz3, X4, Y4, Z4, Vx4, Vy4, Vz4) ->
    energy({X0, Y0, Z0, Vx0, Vy0, Vz0, X1, Y1, Z1, Vx1, Vy1, Vz1, X2, Y2, Z2, Vx2, Vy2, Vz2, X3, Y3, Z3, Vx3, Vy3, Vz3, X4, Y4, Z4, Vx4, Vy4, Vz4}).

energy({X0, Y0, Z0, Vx0, Vy0, Vz0, X1, Y1, Z1, Vx1, Vy1, Vz1, X2, Y2, Z2, Vx2, Vy2, Vz2, X3, Y3, Z3, Vx3, Vy3, Vz3, X4, Y4, Z4, Vx4, Vy4, Vz4}) ->
    Bodies = [
        {X0, Y0, Z0, Vx0, Vy0, Vz0, ?SOLAR_MASS},
        {X1, Y1, Z1, Vx1, Vy1, Vz1, ?M1},
        {X2, Y2, Z2, Vx2, Vy2, Vz2, ?M2},
        {X3, Y3, Z3, Vx3, Vy3, Vz3, ?M3},
        {X4, Y4, Z4, Vx4, Vy4, Vz4, ?M4}
    ],
    energy(Bodies, 0.0).

energy([], Total) ->
    Total;
energy([{X, Y, Z, Vx, Vy, Vz, M} | Rest], Total) ->
    Kinetic = Total + 0.5 * M * (Vx * Vx + Vy * Vy + Vz * Vz),
    energy(
        Rest,
        lists:foldl(
            fun({X2, Y2, Z2, _, _, _, M2}, Sum) ->
                Dx = X - X2,
                Dy = Y - Y2,
                Dz = Z - Z2,
                Sum - (M * M2) / math:sqrt(Dx * Dx + Dy * Dy + Dz * Dz)
            end,
            Kinetic,
            Rest
        )
    ).
