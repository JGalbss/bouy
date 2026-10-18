//! The generators of section 5.10 of docs/design/testing.md. Each one writes a program of
//! independent statements from a seed, so the seed of a case replays its program.

mod json;
mod number;
mod string;

use clap::ValueEnum;

use crate::program::{Expr, Program};

/// The statements of a generated program. Few statements keep the minimizer short, and
/// enough of them make most programs run something that Buoy compiles.
const STATEMENTS: usize = 6;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, ValueEnum)]
pub enum Generator {
    /// Number formatting, parsing, and coercion.
    Number,
    /// Strings and their UTF-16 indices.
    String,
    /// JSON text and values, and their round trips.
    Json,
}

impl Generator {
    pub const ALL: [Self; 3] = [Self::Number, Self::String, Self::Json];

    /// The name of the directory of its cases, `tests/fuzz/<name>`.
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::Number => "number",
            Self::String => "string",
            Self::Json => "json",
        }
    }

    #[must_use]
    pub fn program(self, seed: u64) -> Program {
        let mut random = Random::new(self.name(), seed);
        Program(
            (0..STATEMENTS)
                .map(|_| match self {
                    Self::Number => number::statement(&mut random),
                    Self::String => string::statement(&mut random),
                    Self::Json => json::statement(&mut random),
                })
                .collect(),
        )
    }
}

/// The splitmix64 generator: small, and the same on every platform.
#[derive(Debug)]
struct Random(u64);

impl Random {
    fn new(name: &str, seed: u64) -> Self {
        Self(
            name.bytes()
                .fold(seed, |state, byte| state.rotate_left(8) ^ u64::from(byte)),
        )
    }

    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut mixed = self.0;
        mixed = (mixed ^ (mixed >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        mixed = (mixed ^ (mixed >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        mixed ^ (mixed >> 31)
    }

    /// A number in `0..bound`.
    fn below(&mut self, bound: usize) -> usize {
        let bound = u64::try_from(bound).unwrap_or(u64::MAX).max(1);
        usize::try_from(self.next() % bound).unwrap_or(0)
    }

    fn chance(&mut self, percent: usize) -> bool {
        self.below(100) < percent
    }

    fn pick<T: Copy>(&mut self, items: &[T]) -> T {
        items[self.below(items.len())]
    }

    /// `count` decimal digits.
    fn digits(&mut self, count: usize) -> String {
        (0..count)
            .map(|_| char::from(b'0' + u8::try_from(self.below(10)).unwrap_or(0)))
            .collect()
    }
}

/// The number literal of a whole number.
fn integer(value: usize) -> Expr {
    Expr::Number(value.to_string())
}

fn number(text: &str) -> Expr {
    Expr::Number(text.to_owned())
}

fn call(callee: &'static str, arguments: Vec<Expr>) -> Expr {
    Expr::Call(callee, arguments)
}

fn method(receiver: Expr, name: &'static str, arguments: Vec<Expr>) -> Expr {
    Expr::Method(Box::new(receiver), name, arguments)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_seed_replays_its_program() {
        for generator in Generator::ALL {
            let first = generator.program(7).source();
            assert_eq!(first, generator.program(7).source());
            assert_ne!(first, generator.program(8).source());
            assert_eq!(first.lines().count(), STATEMENTS, "{first}");
        }
    }

    #[test]
    fn the_generators_differ_for_one_seed() {
        assert_ne!(
            Generator::Number.program(1).source(),
            Generator::String.program(1).source()
        );
    }
}
