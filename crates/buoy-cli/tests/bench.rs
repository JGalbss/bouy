//! Each benchmark program still compiles (section 5.11 of docs/design/testing.md). The
//! nightly job measures the programs, and this test finds a break on the pull request.

mod common;

use std::fs;
use std::path::Path;

#[test]
fn every_benchmark_program_compiles() {
    let mut programs: Vec<_> = fs::read_dir(common::repository().join("bench/programs"))
        .expect("bench/programs exists")
        .filter_map(|entry| Some(entry.ok()?.path().join("buoy.ts")))
        .filter(|program| program.is_file())
        .collect();
    programs.sort();
    assert!(!programs.is_empty(), "bench/programs holds no buoy.ts");
    let failures: Vec<String> = programs
        .iter()
        .filter_map(|program| check(program))
        .collect();
    assert!(
        failures.is_empty(),
        "{} of {} benchmark programs do not compile:\n{}",
        failures.len(),
        programs.len(),
        failures.join("\n")
    );
}

/// The report of `buoy check <program>`, or `None` when the program compiles.
fn check(program: &Path) -> Option<String> {
    let mut command = common::buoy();
    command
        .current_dir(common::repository())
        .arg("check")
        .arg(program);
    let common::Run { output, timed_out } = common::run(&mut command, common::deadline());
    if output.status.success() && !timed_out {
        return None;
    }
    Some(format!(
        "{command:?} exited {:?}{}:\n{}",
        output.status.code(),
        if timed_out { " past the deadline" } else { "" },
        String::from_utf8_lossy(&output.stderr)
    ))
}
