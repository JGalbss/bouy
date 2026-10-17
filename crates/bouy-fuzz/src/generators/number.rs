//! Numbers: formatting, parsing, and coercion. BEAM differs most from V8 here: integers
//! past 2^53, `-0`, the shortest text of a double, rounding, and `ToInt32`.

use super::{Random, call, integer, method, number};
use crate::program::Expr;

const LITERALS: [&str; 42] = [
    "0",
    "-0",
    "1",
    "-1",
    "0.1",
    "0.2",
    "0.3",
    "0.5",
    "1.5",
    "2.5",
    "-2.5",
    "3",
    "7",
    "10",
    "100",
    "255",
    "1e21",
    "1e-7",
    "1e-6",
    "123.456",
    "9007199254740991",
    "9007199254740992",
    "9007199254740993",
    "-9007199254740993",
    "4294967295",
    "4294967296",
    "2147483647",
    "2147483648",
    "-2147483649",
    "5e-324",
    "1.7976931348623157e308",
    "0.000001234",
    "1234567890123456789",
    "0x10",
    "0b101",
    "0o17",
    "1e300",
    "2e-7",
    "0.1e1",
    "1.005",
    "4.35",
    "1.45",
];

const ATOMS: [&str; 10] = [
    "NaN",
    "Infinity",
    "-Infinity",
    "Number.MAX_SAFE_INTEGER",
    "Number.MIN_SAFE_INTEGER",
    "Number.EPSILON",
    "Number.MAX_VALUE",
    "Number.MIN_VALUE",
    "Math.PI",
    "Math.E",
];

/// Texts for the parsers and for coercion.
const TEXTS: [&str; 24] = [
    "",
    " ",
    "12",
    "  12  ",
    "-0",
    "0x1f",
    "1e3",
    "1.5e2",
    "Infinity",
    "-Infinity",
    "abc",
    "12px",
    "0b11",
    ".5",
    "5.",
    "+5",
    "\t7\n",
    "1_000",
    "00012",
    "-0x10",
    "3.14abc",
    "9007199254740993",
    "1e1000",
    "0.0000001",
];

const ARITHMETIC: [&str; 6] = ["+", "-", "*", "/", "%", "**"];
const BITWISE: [&str; 6] = ["|", "&", "^", "<<", ">>", ">>>"];
const COMPARISONS: [&str; 5] = ["===", "==", "<", "<=", "!="];
const MATH: [&str; 9] = [
    "Math.floor",
    "Math.ceil",
    "Math.round",
    "Math.trunc",
    "Math.sign",
    "Math.abs",
    "Math.sqrt",
    "Math.fround",
    "Math.clz32",
];
const PREDICATES: [&str; 5] = [
    "Number.isInteger",
    "Number.isSafeInteger",
    "Number.isFinite",
    "isNaN",
    "isFinite",
];
const RADIXES: [usize; 7] = [0, 2, 8, 10, 16, 36, 37];

pub(super) fn statement(random: &mut Random) -> Expr {
    let value = numeric(random, 3);
    match random.below(12) {
        0..=3 => value,
        4..=7 => formatted(random, value),
        8 => call(random.pick(&PREDICATES), vec![value]),
        9 => call("Object.is", vec![value, number("-0")]),
        10 => Expr::Binary(
            random.pick(&COMPARISONS),
            Box::new(value),
            Box::new(numeric(random, 1)),
        ),
        _ => Expr::Binary(
            "===",
            Box::new(call("Number", vec![call("String", vec![value.clone()])])),
            Box::new(value),
        ),
    }
}

/// A string made from a number.
fn formatted(random: &mut Random, value: Expr) -> Expr {
    match random.below(6) {
        0 => method(value, "toFixed", vec![integer(random.below(21))]),
        1 => method(value, "toPrecision", vec![integer(1 + random.below(21))]),
        2 => method(value, "toExponential", vec![integer(random.below(21))]),
        3 => method(value, "toString", vec![integer(2 + random.below(35))]),
        4 => method(value, "toString", Vec::new()),
        _ => call("String", vec![value]),
    }
}

/// An expression whose value is a number.
fn numeric(random: &mut Random, depth: usize) -> Expr {
    if depth == 0 || random.chance(30) {
        return leaf(random);
    }
    let depth = depth - 1;
    match random.below(8) {
        0 => Expr::Unary(
            random.pick(&["-", "~", "+"]),
            Box::new(numeric(random, depth)),
        ),
        1 | 2 => Expr::Binary(
            random.pick(&ARITHMETIC),
            Box::new(numeric(random, depth)),
            Box::new(numeric(random, depth)),
        ),
        3 => Expr::Binary(
            random.pick(&BITWISE),
            Box::new(numeric(random, depth)),
            Box::new(numeric(random, depth)),
        ),
        4 => call(random.pick(&MATH), vec![numeric(random, depth)]),
        5 => call(
            random.pick(&["Math.max", "Math.min", "Math.pow"]),
            vec![numeric(random, depth), numeric(random, depth)],
        ),
        6 => parsed(random),
        _ => {
            let value = numeric(random, depth);
            call("Number", vec![formatted(random, value)])
        }
    }
}

/// A number parsed from text.
fn parsed(random: &mut Random) -> Expr {
    let text = Expr::string(random.pick(&TEXTS));
    match random.below(5) {
        0 => call("Number", vec![text]),
        1 => call("parseFloat", vec![text]),
        2 => call("parseInt", vec![text]),
        3 => call("parseInt", vec![text, integer(random.pick(&RADIXES))]),
        _ => Expr::Unary("+", Box::new(text)),
    }
}

fn leaf(random: &mut Random) -> Expr {
    let sign = if random.chance(30) { "-" } else { "" };
    match random.below(10) {
        0..=4 => number(random.pick(&LITERALS)),
        5 => Expr::Atom(random.pick(&ATOMS).to_owned()),
        6 => Expr::Number(format!("{sign}{}", random.below(1000))),
        7 => {
            let length = 15 + random.below(8);
            Expr::Number(format!(
                "{sign}{}{}",
                1 + random.below(9),
                random.digits(length)
            ))
        }
        8 => {
            let (whole, fraction) = (1 + random.below(4), 1 + random.below(6));
            let whole = random.digits(whole).trim_start_matches('0').to_owned();
            Expr::Number(format!(
                "{sign}{}.{}",
                if whole.is_empty() { "0" } else { &whole },
                random.digits(fraction)
            ))
        }
        _ => {
            let exponent = random.below(330);
            let direction = if random.chance(50) { "-" } else { "" };
            let (lead, fraction) = (1 + random.below(9), 1 + random.below(3));
            let fraction = random.digits(fraction);
            Expr::Number(format!("{sign}{lead}.{fraction}e{direction}{exponent}"))
        }
    }
}
