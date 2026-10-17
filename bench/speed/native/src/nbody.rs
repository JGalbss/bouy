//! NBody with the same operations in the same order as `bench/speed/kernels/nbody.ts`, so
//! the energy matches Node and Bun bit for bit.

use std::f64::consts::PI;

const SOLAR_MASS: f64 = 4.0 * PI * PI;
const DAYS_PER_YEAR: f64 = 365.24;
const FIELDS: usize = 7;
const BODIES: usize = 5;

#[derive(Clone, Copy)]
struct Body {
    x: f64,
    y: f64,
    z: f64,
    vx: f64,
    vy: f64,
    vz: f64,
    mass: f64,
}

pub struct System {
    bodies: [Body; BODIES],
}

#[allow(clippy::unreadable_literal, clippy::excessive_precision)]
const START: [Body; BODIES] = [
    Body {
        x: 0.0,
        y: 0.0,
        z: 0.0,
        vx: 0.0,
        vy: 0.0,
        vz: 0.0,
        mass: SOLAR_MASS,
    },
    Body {
        x: 4.84143144246472090e+00,
        y: -1.16032004402742839e+00,
        z: -1.03622044471123109e-01,
        vx: 1.66007664274403694e-03 * DAYS_PER_YEAR,
        vy: 7.69901118419740425e-03 * DAYS_PER_YEAR,
        vz: -6.90460016972063023e-05 * DAYS_PER_YEAR,
        mass: 9.54791938424326609e-04 * SOLAR_MASS,
    },
    Body {
        x: 8.34336671824457987e+00,
        y: 4.12479856412430479e+00,
        z: -4.03523417114321381e-01,
        vx: -2.76742510726862411e-03 * DAYS_PER_YEAR,
        vy: 4.99852801234917238e-03 * DAYS_PER_YEAR,
        vz: 2.30417297573763929e-05 * DAYS_PER_YEAR,
        mass: 2.85885980666130812e-04 * SOLAR_MASS,
    },
    Body {
        x: 1.28943695621391310e+01,
        y: -1.51111514016986312e+01,
        z: -2.23307578892655734e-01,
        vx: 2.96460137564761618e-03 * DAYS_PER_YEAR,
        vy: 2.37847173959480950e-03 * DAYS_PER_YEAR,
        vz: -2.96589568540237556e-05 * DAYS_PER_YEAR,
        mass: 4.36624404335156298e-05 * SOLAR_MASS,
    },
    Body {
        x: 1.53796971148509165e+01,
        y: -2.59193146099879641e+01,
        z: 1.79258772950371181e-01,
        vx: 2.68067772490389322e-03 * DAYS_PER_YEAR,
        vy: 1.62824170038242295e-03 * DAYS_PER_YEAR,
        vz: -9.51592254519715870e-05 * DAYS_PER_YEAR,
        mass: 5.15138902046611451e-05 * SOLAR_MASS,
    },
];

impl System {
    pub fn new() -> Self {
        let mut bodies = START;
        let (mut px, mut py, mut pz) = (0.0, 0.0, 0.0);
        for body in &bodies {
            px += body.vx * body.mass;
            py += body.vy * body.mass;
            pz += body.vz * body.mass;
        }
        bodies[0].vx = -px / SOLAR_MASS;
        bodies[0].vy = -py / SOLAR_MASS;
        bodies[0].vz = -pz / SOLAR_MASS;
        Self { bodies }
    }

    pub fn advance(&mut self, dt: f64) {
        let bodies = &mut self.bodies;
        for i in 0..BODIES {
            let (left, right) = bodies.split_at_mut(i + 1);
            let a = &mut left[i];
            for b in right.iter_mut() {
                let dx = a.x - b.x;
                let dy = a.y - b.y;
                let dz = a.z - b.z;
                let distance2 = dx * dx + dy * dy + dz * dz;
                let magnitude = dt / (distance2 * distance2.sqrt());
                let mass_a = a.mass * magnitude;
                let mass_b = b.mass * magnitude;
                a.vx -= dx * mass_b;
                a.vy -= dy * mass_b;
                a.vz -= dz * mass_b;
                b.vx += dx * mass_a;
                b.vy += dy * mass_a;
                b.vz += dz * mass_a;
            }
        }
        for body in bodies.iter_mut() {
            body.x += dt * body.vx;
            body.y += dt * body.vy;
            body.z += dt * body.vz;
        }
    }

    pub fn energy(&self) -> f64 {
        let mut total = 0.0;
        for (i, a) in self.bodies.iter().enumerate() {
            total += 0.5 * a.mass * (a.vx * a.vx + a.vy * a.vy + a.vz * a.vz);
            for b in &self.bodies[i + 1..] {
                let dx = a.x - b.x;
                let dy = a.y - b.y;
                let dz = a.z - b.z;
                total -= (a.mass * b.mass) / (dx * dx + dy * dy + dz * dz).sqrt();
            }
        }
        total
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        self.bodies
            .iter()
            .flat_map(|b| [b.x, b.y, b.z, b.vx, b.vy, b.vz, b.mass])
            .flat_map(f64::to_ne_bytes)
            .collect()
    }

    pub fn from_bytes(bytes: &[u8]) -> Option<Self> {
        let (chunks, []) = bytes.as_chunks::<8>() else {
            return None;
        };
        if chunks.len() != BODIES * FIELDS {
            return None;
        }
        let mut values = chunks.iter().map(|chunk| f64::from_ne_bytes(*chunk));
        let mut next = || values.next().unwrap_or_default();
        let bodies = [(); BODIES].map(|()| Body {
            x: next(),
            y: next(),
            z: next(),
            vx: next(),
            vy: next(),
            vz: next(),
            mass: next(),
        });
        Some(Self { bodies })
    }
}
