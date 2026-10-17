//! Strings and their UTF-16 indices: astral characters, combining marks, case mappings that
//! change the length, and the escapes of the source.

use super::{Random, call, integer, method, number};
use crate::program::Expr;

/// The source of one character or escape of a string literal. A lone surrogate is left out,
/// because the compiler rejects it in a literal.
const PIECES: [&str; 28] = [
    "a",
    "b",
    "x",
    "Z",
    " ",
    "-",
    ",",
    "1",
    "é",
    "\\u00e9",
    "e\\u0301",
    "ß",
    "İ",
    "ﬃ",
    "€",
    "Σ",
    "😀",
    "\\u{1F600}",
    "\\ud83d\\ude00",
    "👍🏽",
    "日本",
    "\\n",
    "\\t",
    "\\\\",
    "\\\"",
    "\\u2028",
    "\\x41",
    "\\u0000",
];

const INDICES: [&str; 10] = ["0", "1", "2", "3", "-1", "-2", "5", "10", "1.5", "-0"];

/// Code units for `String.fromCharCode`, and code points for `String.fromCodePoint`.
const UNITS: [usize; 7] = [65, 233, 0xd83d, 0x0001_f600, 0x2028, 0, 0xffff];
const POINTS: [usize; 6] = [65, 233, 0x0001_f600, 0x0010_ffff, 0xd800, 0];

pub(super) fn statement(random: &mut Random) -> Expr {
    let text = string(random, 2);
    match random.below(12) {
        0..=3 => text,
        4 => Expr::Property(Box::new(text), "length"),
        5 => method(
            text,
            random.pick(&["charCodeAt", "codePointAt", "at", "charAt"]),
            vec![index(random)],
        ),
        6 => Expr::Index(Box::new(text), Box::new(index(random))),
        7 => method(
            text,
            random.pick(&[
                "indexOf",
                "lastIndexOf",
                "includes",
                "startsWith",
                "endsWith",
            ]),
            vec![literal(random, 2)],
        ),
        8 => Expr::Binary(
            random.pick(&["<", "===", ">"]),
            Box::new(text),
            Box::new(string(random, 1)),
        ),
        9 => method(text, "split", vec![literal(random, 2)]),
        10 => call("Array.from", vec![text]),
        _ => Expr::Property(Box::new(call("Array.from", vec![text])), "length"),
    }
}

/// An expression whose value is a string.
fn string(random: &mut Random, depth: usize) -> Expr {
    if depth == 0 || random.chance(35) {
        return literal(random, 6);
    }
    let depth = depth - 1;
    let text = string(random, depth);
    match random.below(10) {
        0 => {
            let mut bounds = vec![index(random)];
            if random.chance(50) {
                bounds.push(index(random));
            }
            method(text, random.pick(&["slice", "substring"]), bounds)
        }
        1 => method(
            text,
            random.pick(&["toUpperCase", "toLowerCase", "trim", "trimStart", "trimEnd"]),
            Vec::new(),
        ),
        2 => method(
            text,
            random.pick(&["padStart", "padEnd"]),
            vec![integer(random.below(8)), literal(random, 2)],
        ),
        3 => method(text, "repeat", vec![integer(random.below(4))]),
        4 => Expr::Binary("+", Box::new(text), Box::new(string(random, depth))),
        5 => method(
            text,
            random.pick(&["replace", "replaceAll"]),
            vec![literal(random, 2), literal(random, 2)],
        ),
        6 => method(
            text,
            "normalize",
            vec![Expr::string(random.pick(&["NFC", "NFD", "NFKC", "NFKD"]))],
        ),
        7 => method(
            method(text, "split", vec![literal(random, 2)]),
            "join",
            vec![literal(random, 2)],
        ),
        8 => call("JSON.stringify", vec![text]),
        _ if random.chance(50) => call("String.fromCharCode", vec![integer(random.pick(&UNITS))]),
        _ => call("String.fromCodePoint", vec![integer(random.pick(&POINTS))]),
    }
}

/// A string literal of up to `longest` pieces.
fn literal(random: &mut Random, longest: usize) -> Expr {
    let length = random.below(longest + 1);
    Expr::String(
        (0..length)
            .map(|_| random.pick(&PIECES).to_owned())
            .collect(),
    )
}

fn index(random: &mut Random) -> Expr {
    if random.chance(10) {
        return Expr::Atom("NaN".to_owned());
    }
    number(random.pick(&INDICES))
}
