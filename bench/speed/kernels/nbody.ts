// NBody: the Computer Language Benchmarks Game simulation of the Jovian planets, in float
// math. One iteration advances the system `size` steps of 0.01 and returns the energy.
// Usage: nbody.ts [warmup] [runs] [size]

const PI = Math.PI;
const SOLAR_MASS = 4 * PI * PI;
const DAYS_PER_YEAR = 365.24;

class Body {
  x: number;
  y: number;
  z: number;
  vx: number;
  vy: number;
  vz: number;
  mass: number;

  constructor(x: number, y: number, z: number, vx: number, vy: number, vz: number, mass: number) {
    this.x = x;
    this.y = y;
    this.z = z;
    this.vx = vx;
    this.vy = vy;
    this.vz = vz;
    this.mass = mass;
  }
}

function jupiter(): Body {
  return new Body(
    4.8414314424647209,
    -1.16032004402742839,
    -1.03622044471123109e-1,
    1.66007664274403694e-3 * DAYS_PER_YEAR,
    7.69901118419740425e-3 * DAYS_PER_YEAR,
    -6.90460016972063023e-5 * DAYS_PER_YEAR,
    9.54791938424326609e-4 * SOLAR_MASS,
  );
}

function saturn(): Body {
  return new Body(
    8.34336671824457987,
    4.12479856412430479,
    -4.03523417114321381e-1,
    -2.76742510726862411e-3 * DAYS_PER_YEAR,
    4.99852801234917238e-3 * DAYS_PER_YEAR,
    2.30417297573763929e-5 * DAYS_PER_YEAR,
    2.85885980666130812e-4 * SOLAR_MASS,
  );
}

function uranus(): Body {
  return new Body(
    1.2894369562139131e1,
    -1.51111514016986312e1,
    -2.23307578892655734e-1,
    2.96460137564761618e-3 * DAYS_PER_YEAR,
    2.3784717395948095e-3 * DAYS_PER_YEAR,
    -2.96589568540237556e-5 * DAYS_PER_YEAR,
    4.36624404335156298e-5 * SOLAR_MASS,
  );
}

function neptune(): Body {
  return new Body(
    1.53796971148509165e1,
    -2.59193146099879641e1,
    1.79258772950371181e-1,
    2.68067772490389322e-3 * DAYS_PER_YEAR,
    1.62824170038242295e-3 * DAYS_PER_YEAR,
    -9.5159225451971587e-5 * DAYS_PER_YEAR,
    5.15138902046611451e-5 * SOLAR_MASS,
  );
}

function sun(): Body {
  return new Body(0, 0, 0, 0, 0, 0, SOLAR_MASS);
}

function offsetMomentum(bodies: Body[]): void {
  let px = 0;
  let py = 0;
  let pz = 0;
  for (const body of bodies) {
    px += body.vx * body.mass;
    py += body.vy * body.mass;
    pz += body.vz * body.mass;
  }
  const first = bodies[0];
  if (first === undefined) return;
  first.vx = -px / SOLAR_MASS;
  first.vy = -py / SOLAR_MASS;
  first.vz = -pz / SOLAR_MASS;
}

function advance(bodies: Body[], dt: number): void {
  const count = bodies.length;
  for (let i = 0; i < count; i++) {
    const a = bodies[i];
    for (let j = i + 1; j < count; j++) {
      const b = bodies[j];
      const dx = a.x - b.x;
      const dy = a.y - b.y;
      const dz = a.z - b.z;
      const distance2 = dx * dx + dy * dy + dz * dz;
      const magnitude = dt / (distance2 * Math.sqrt(distance2));
      const massA = a.mass * magnitude;
      const massB = b.mass * magnitude;
      a.vx -= dx * massB;
      a.vy -= dy * massB;
      a.vz -= dz * massB;
      b.vx += dx * massA;
      b.vy += dy * massA;
      b.vz += dz * massA;
    }
  }
  for (const body of bodies) {
    body.x += dt * body.vx;
    body.y += dt * body.vy;
    body.z += dt * body.vz;
  }
}

function energy(bodies: Body[]): number {
  let total = 0;
  const count = bodies.length;
  for (let i = 0; i < count; i++) {
    const a = bodies[i];
    total += 0.5 * a.mass * (a.vx * a.vx + a.vy * a.vy + a.vz * a.vz);
    for (let j = i + 1; j < count; j++) {
      const b = bodies[j];
      const dx = a.x - b.x;
      const dy = a.y - b.y;
      const dz = a.z - b.z;
      total -= (a.mass * b.mass) / Math.sqrt(dx * dx + dy * dy + dz * dz);
    }
  }
  return total;
}

function iteration(size: number): number {
  const bodies = [sun(), jupiter(), saturn(), uranus(), neptune()];
  offsetMomentum(bodies);
  for (let step = 0; step < size; step++) advance(bodies, 0.01);
  return energy(bodies);
}

function bench(name: string, defaultSize: number, work: (size: number) => number): void {
  // The reference engine has neither `process` nor `performance` yet.
  const args = typeof process === "undefined" ? [] : process.argv.slice(2).map(Number);
  const now = typeof performance === "undefined" ? Date.now : () => performance.now();
  const warmup = args[0] ?? 3;
  const runs = args[1] ?? 5;
  const size = args[2] ?? defaultSize;
  const times: number[] = [];
  let check = 0;
  for (let i = 0; i < warmup + runs; i++) {
    const start = now();
    check = work(size);
    const elapsed = now() - start;
    if (i >= warmup) times.push(elapsed);
  }
  times.sort((a, b) => a - b);
  const median = times[Math.floor(times.length / 2)] ?? 0;
  console.log(JSON.stringify({ kernel: name, size, median_ms: median, times_ms: times, check }));
}

bench("nbody", 250000, iteration);
