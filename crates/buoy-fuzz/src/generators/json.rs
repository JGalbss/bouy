//! JSON: `JSON.stringify` of values with every kind of key and number, `JSON.parse` of
//! text with every escape, the round trips, and how `console.log` prints the result.

use super::{Random, call, number};
use crate::program::Expr;

/// The keys of an object, among them the integer keys that come first in V8's order.
const KEYS: [&str; 21] = [
    "a",
    "b",
    "z",
    "id",
    "0",
    "1",
    "2",
    "10",
    "-1",
    "01",
    "1.5",
    "4294967294",
    "4294967295",
    "",
    " ",
    "é",
    "😀",
    "constructor",
    "toString",
    "length",
    "__proto__",
];

/// Number literals that JSON and JavaScript both accept.
const NUMBERS: [&str; 18] = [
    "0",
    "-0",
    "1",
    "-1",
    "0.1",
    "1.5",
    "2.50",
    "100",
    "1e21",
    "1E2",
    "1e-7",
    "-0.0",
    "123456789012345678901234567890",
    "5e-324",
    "1e400",
    "9007199254740993",
    "0.000001",
    "1.7976931348623157e308",
];

/// The source of one character or escape that JSON and JavaScript both accept.
const PIECES: [&str; 21] = [
    "a",
    "b",
    " ",
    "é",
    "😀",
    "日",
    "<",
    "\\n",
    "\\t",
    "\\\"",
    "\\\\",
    "\\/",
    "\\b",
    "\\f",
    "\\r",
    "\\u00e9",
    "\\u2028",
    "\\ud83d\\ude00",
    "\\u0000",
    "\\u001f",
    "\\u007f",
];

/// Values that JavaScript has and JSON does not.
const SCRIPT_ONLY: [&str; 5] = ["undefined", "NaN", "Infinity", "-Infinity", "new Date(0)"];

const INDENTS: [&str; 8] = ["0", "1", "2", "4", "10", "11", "-1", "1.5"];

pub(super) fn statement(random: &mut Random) -> Expr {
    match random.below(10) {
        0 | 1 => call("JSON.stringify", vec![value(random, 3, true)]),
        2 => call(
            "JSON.stringify",
            vec![
                value(random, 3, true),
                Expr::Atom("null".to_owned()),
                indent(random),
            ],
        ),
        3 => call("JSON.stringify", vec![parse(value(random, 3, false))]),
        4 => call(
            "JSON.stringify",
            vec![
                parse(value(random, 3, false)),
                Expr::Atom("null".to_owned()),
                number("2"),
            ],
        ),
        5 => parse(value(random, 3, false)),
        6 => value(random, 3, true),
        7 => call("Object.keys", vec![parse(object(random, 2, false))]),
        _ => {
            let value = value(random, 3, true);
            let once = call("JSON.stringify", vec![value]);
            let twice = call(
                "JSON.stringify",
                vec![call("JSON.parse", vec![once.clone()])],
            );
            Expr::Binary("===", Box::new(twice), Box::new(once))
        }
    }
}

/// `JSON.parse` of the JSON text of `value`.
fn parse(value: Expr) -> Expr {
    call("JSON.parse", vec![Expr::Text(Box::new(value))])
}

/// A JSON value, or with `script`, a JavaScript value that may hold what JSON lacks.
fn value(random: &mut Random, depth: usize, script: bool) -> Expr {
    if depth == 0 || random.chance(40) {
        return leaf(random, script);
    }
    if random.chance(50) {
        let length = random.below(5);
        return Expr::Array(
            (0..length)
                .map(|_| value(random, depth - 1, script))
                .collect(),
        );
    }
    object(random, depth, script)
}

fn object(random: &mut Random, depth: usize, script: bool) -> Expr {
    let length = random.below(5);
    Expr::Object(
        (0..length)
            .map(|_| {
                let key = format!("\"{}\"", random.pick(&KEYS));
                (key, value(random, depth.saturating_sub(1), script))
            })
            .collect(),
    )
}

fn leaf(random: &mut Random, script: bool) -> Expr {
    if script && random.chance(15) {
        return Expr::Atom(random.pick(&SCRIPT_ONLY).to_owned());
    }
    match random.below(4) {
        0 => number(random.pick(&NUMBERS)),
        1 => {
            let length = random.below(5);
            Expr::String(
                (0..length)
                    .map(|_| random.pick(&PIECES).to_owned())
                    .collect(),
            )
        }
        2 => Expr::Atom(random.pick(&["true", "false"]).to_owned()),
        _ => Expr::Atom("null".to_owned()),
    }
}

fn indent(random: &mut Random) -> Expr {
    if random.chance(30) {
        return Expr::string(random.pick(&["\t", "--", "abcdefghijkl", ""]));
    }
    number(random.pick(&INDENTS))
}
