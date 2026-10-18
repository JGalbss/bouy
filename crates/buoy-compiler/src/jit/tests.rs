//! Which functions become islands.

use std::path::Path;

use oxc::span::SourceType;

use super::plan;
use crate::parse::with_program;

/// The names of the functions of `source` that start islands.
fn islands(source: &str) -> Vec<String> {
    with_program(
        Path::new("t.ts"),
        source,
        SourceType::ts(),
        |_, semantic| {
            let found = plan(semantic);
            let mut names: Vec<String> = found
                .entries
                .keys()
                .map(|offset| {
                    let before = &source[..*offset as usize];
                    let start = before.rfind("function ").map_or(0, |at| at + 9);
                    before[start..]
                        .split('(')
                        .next()
                        .unwrap_or_default()
                        .to_owned()
                })
                .collect();
            names.sort();
            names
        },
    )
    .expect("the source parses")
}

#[test]
fn the_speed_kernels_have_islands() {
    let nbody = include_str!("../../../../bench/speed/kernels/nbody.ts");
    assert_eq!(islands(nbody), ["iteration"]);
    let richards = include_str!("../../../../bench/speed/kernels/richards.ts");
    assert_eq!(islands(richards), ["iteration", "runRichards"]);
}

#[test]
fn a_loop_over_numbers_is_an_island() {
    let source = "
        const K = 3;
        function sum(n: number): number {
            let total = 0;
            for (let i = 0; i < n; i++) total += i * K;
            return total;
        }
    ";
    assert_eq!(islands(source), ["sum"]);
}

#[test]
fn code_with_effects_outside_is_not_an_island() {
    let source = "
        let count = 0;
        function bump(n: number): number {
            for (let i = 0; i < n; i++) count++;
            return count;
        }
        function log(n: number): void {
            for (let i = 0; i < n; i++) console.log(i);
        }
        function text(n: number): number {
            let s = '';
            for (let i = 0; i < n; i++) s += 'x';
            return s.length;
        }
        function leaf(a: number, b: number): number {
            return a + b;
        }
    ";
    assert!(islands(source).is_empty());
}

#[test]
fn a_class_that_lets_this_escape_early_is_not_an_island() {
    let source = "
        class Node {
            next: Node | null;
            value: number;
            constructor(value: number) {
                register(this);
                this.next = null;
                this.value = value;
            }
        }
        function register(node: Node): void {}
        function total(n: number): number {
            let sum = 0;
            for (let i = 0; i < n; i++) sum += new Node(i).value;
            return sum;
        }
    ";
    assert!(islands(source).is_empty());
}
