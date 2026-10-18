//! The migration fixture (section 5.12 of docs/design/testing.md). `tests/migration/before`
//! is a Node-style agent app, and Buoy must run it unchanged. The test runs it with
//! `buoy run` against the fake server and fails when the outcome differs from its line
//! in `tests/migration/expectations.txt`. The outcome is `pass` when stdout and the exit
//! status equal `before/expected.stdout`, which `scripts/freeze-expectations.sh
//! tests/migration` records with Node. The tests never run node. `classify` of
//! `buoy-suites` reads the facts that the run writes to `BUOY_RESULT_FILE`.

mod common;

use std::fs;

const PROGRAM: &str = "before/src/main.ts";

#[test]
fn the_fixture_has_the_outcome_that_its_expectation_line_records() {
    if !common::vm_available() {
        return;
    }
    let recorded = recorded_outcome();
    let mut command = common::buoy();
    command
        .current_dir(common::repository())
        .arg("run")
        .arg(format!("tests/migration/{PROGRAM}"));
    common::use_fake_openai(&mut command);
    let (outcome, report) = common::classify_run(
        &common::repository().join("tests/migration/before/expected"),
        &mut command,
    );
    assert!(
        outcome.as_str() == recorded,
        "tests/migration/{PROGRAM} gives `{outcome}`, and tests/migration/expectations.txt \
         records `{recorded}`. When the change is intended, write `{PROGRAM} {outcome}` there.\n\
         {report}"
    );
}

/// The outcome of the one line of `tests/migration/expectations.txt`.
fn recorded_outcome() -> String {
    let text = fs::read_to_string(common::repository().join("tests/migration/expectations.txt"))
        .expect("tests/migration/expectations.txt exists");
    let lines: Vec<&str> = text
        .lines()
        .filter(|line| !line.starts_with('#') && !line.trim().is_empty())
        .collect();
    let [line] = lines.as_slice() else {
        panic!("tests/migration/expectations.txt must hold one line, for {PROGRAM}: {lines:?}");
    };
    let (id, outcome) = line
        .rsplit_once(' ')
        .unwrap_or_else(|| panic!("`{line}` is not `<id> <outcome>`"));
    assert_eq!(
        id, PROGRAM,
        "tests/migration/expectations.txt names another program"
    );
    outcome.to_owned()
}
