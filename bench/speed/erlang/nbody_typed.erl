-module(nbody_typed).

%% NBody as a typed compilation: whole-program analysis proves that every field of Body
%% holds a float, so the literals are floats and the guards let the BEAM compiler use its
%% float registers inside a function. The five bodies never escape `iteration`, so escape
%% analysis turns the array of mutable objects into a list of immutable tuples that each
%% step rebuilds. BEAM still boxes each float that it stores in a tuple: 2 words each.

-export([main/1]).

-define(PI, 3.141592653589793).
-define(SOLAR_MASS, (4 * ?PI * ?PI)).
-define(DAYS_PER_YEAR, 365.24).

-spec main([string()]) -> no_return().
main(Args) ->
    speed_harness:bench(<<"nbody">>, 250000, fun iteration/1, Args).

bodies() ->
    [
        {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, ?SOLAR_MASS},
        {4.8414314424647209, -1.16032004402742839, -1.03622044471123109e-1,
            1.66007664274403694e-3 * ?DAYS_PER_YEAR, 7.69901118419740425e-3 * ?DAYS_PER_YEAR,
            -6.90460016972063023e-5 * ?DAYS_PER_YEAR, 9.54791938424326609e-4 * ?SOLAR_MASS},
        {8.34336671824457987, 4.12479856412430479, -4.03523417114321381e-1,
            -2.76742510726862411e-3 * ?DAYS_PER_YEAR, 4.99852801234917238e-3 * ?DAYS_PER_YEAR,
            2.30417297573763929e-5 * ?DAYS_PER_YEAR, 2.85885980666130812e-4 * ?SOLAR_MASS},
        {1.2894369562139131e1, -1.51111514016986312e1, -2.23307578892655734e-1,
            2.96460137564761618e-3 * ?DAYS_PER_YEAR, 2.3784717395948095e-3 * ?DAYS_PER_YEAR,
            -2.96589568540237556e-5 * ?DAYS_PER_YEAR, 4.36624404335156298e-5 * ?SOLAR_MASS},
        {1.53796971148509165e1, -2.59193146099879641e1, 1.79258772950371181e-1,
            2.68067772490389322e-3 * ?DAYS_PER_YEAR, 1.62824170038242295e-3 * ?DAYS_PER_YEAR,
            -9.5159225451971587e-5 * ?DAYS_PER_YEAR, 5.15138902046611451e-5 * ?SOLAR_MASS}
    ].

iteration(Size) ->
    Bodies = advance_steps(Size, offset_momentum(bodies())),
    energy(Bodies, 0.0).

offset_momentum([{X, Y, Z, _, _, _, M} | _] = Bodies) ->
    {Px, Py, Pz} = lists:foldl(
        fun({_, _, _, Vx, Vy, Vz, Mass}, {Px, Py, Pz}) ->
            {Px + Vx * Mass, Py + Vy * Mass, Pz + Vz * Mass}
        end,
        {0.0, 0.0, 0.0},
        Bodies
    ),
    [{X, Y, Z, -Px / ?SOLAR_MASS, -Py / ?SOLAR_MASS, -Pz / ?SOLAR_MASS, M} | tl(Bodies)].

advance_steps(0, Bodies) -> Bodies;
advance_steps(N, Bodies) -> advance_steps(N - 1, advance(Bodies, 0.01)).

advance(Bodies, Dt) -> [move(Body, Dt) || Body <- velocities(Bodies, Dt)].

move({X, Y, Z, Vx, Vy, Vz, M}, Dt) when is_float(X), is_float(Vx), is_float(Dt) ->
    {X + Dt * Vx, Y + Dt * Vy, Z + Dt * Vz, Vx, Vy, Vz, M}.

velocities([], _Dt) -> [];
velocities([A | Rest], Dt) ->
    {A1, Rest1} = pull(A, Rest, Dt, []),
    [A1 | velocities(Rest1, Dt)].

pull(A, [], _Dt, Done) ->
    {A, lists:reverse(Done)};
pull({X, Y, Z, Vx, Vy, Vz, M}, [{X2, Y2, Z2, Vx2, Vy2, Vz2, M2} | Rest], Dt, Done) when
    is_float(X), is_float(Y), is_float(Z), is_float(Vx), is_float(Vy), is_float(Vz),
    is_float(M), is_float(X2), is_float(Y2), is_float(Z2), is_float(Vx2), is_float(Vy2),
    is_float(Vz2), is_float(M2), is_float(Dt)
->
    Dx = X - X2,
    Dy = Y - Y2,
    Dz = Z - Z2,
    Distance2 = Dx * Dx + Dy * Dy + Dz * Dz,
    Magnitude = Dt / (Distance2 * math:sqrt(Distance2)),
    MassA = M * Magnitude,
    MassB = M2 * Magnitude,
    pull(
        {X, Y, Z, Vx - Dx * MassB, Vy - Dy * MassB, Vz - Dz * MassB, M},
        Rest,
        Dt,
        [{X2, Y2, Z2, Vx2 + Dx * MassA, Vy2 + Dy * MassA, Vz2 + Dz * MassA, M2} | Done]
    ).

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
