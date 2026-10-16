//! Differential tests: each program in `tests/conformance/` runs with `node` (the oracle)
//! and with `bouy run`. The two runs must print the same stdout and exit with the same
//! status.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;

const WORKERS: usize = 4;

fn corpus() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance")
}

fn programs() -> Vec<PathBuf> {
    let mut programs: Vec<PathBuf> = std::fs::read_dir(corpus())
        .expect("tests/conformance exists")
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "ts"))
        .collect();
    programs.sort();
    programs
}

fn available(program: &str, flag: &str) -> bool {
    Command::new(program).arg(flag).output().is_ok()
}

fn run(program: &str, args: &[&Path]) -> Output {
    Command::new(program)
        .args(args)
        .output()
        .unwrap_or_else(|error| panic!("cannot run {program}: {error}"))
}

/// The difference between the two runs, or `None` when they agree.
fn compare(path: &Path) -> Option<String> {
    let expected = run("node", &[path]);
    let actual = run(env!("CARGO_BIN_EXE_bouy"), &[Path::new("run"), path]);
    if expected.stdout == actual.stdout && expected.status.code() == actual.status.code() {
        return None;
    }
    let name = path
        .file_name()
        .map_or_else(String::new, |name| name.to_string_lossy().into_owned());
    let mut report = format!(
        "--- {name}: node exited {:?}, bouy exited {:?}\n",
        expected.status.code(),
        actual.status.code()
    );
    report.push_str(&line_diff(
        &String::from_utf8_lossy(&expected.stdout),
        &String::from_utf8_lossy(&actual.stdout),
    ));
    let stderr = String::from_utf8_lossy(&actual.stderr);
    if !stderr.trim().is_empty() {
        report.push_str("bouy stderr:\n");
        report.push_str(&stderr);
    }
    Some(report)
}

/// The lines that differ, as `-` (node) and `+` (bouy).
fn line_diff(expected: &str, actual: &str) -> String {
    let expected: Vec<&str> = expected.lines().collect();
    let actual: Vec<&str> = actual.lines().collect();
    let mut diff = String::new();
    for index in 0..expected.len().max(actual.len()) {
        let (left, right) = (expected.get(index), actual.get(index));
        if left == right {
            continue;
        }
        if let Some(left) = left {
            let _ = writeln!(diff, "  line {}: - {left}", index + 1);
        }
        if let Some(right) = right {
            let _ = writeln!(diff, "  line {}: + {right}", index + 1);
        }
    }
    diff
}

#[test]
fn programs_print_what_node_prints() {
    if !available("node", "--version") {
        eprintln!("skipping the conformance corpus: node is not installed");
        return;
    }
    if !available("erl", "-version") {
        eprintln!("skipping the conformance corpus: erl is not installed");
        return;
    }
    let programs = programs();
    assert!(
        programs.len() >= 45,
        "the corpus has {} programs",
        programs.len()
    );
    // The first run builds the runtime cache, so it runs alone.
    let mut failures: Vec<String> = compare(&programs[0]).into_iter().collect();
    let next = AtomicUsize::new(1);
    let found = Mutex::new(Vec::new());
    thread::scope(|scope| {
        for _ in 0..WORKERS {
            scope.spawn(|| {
                loop {
                    let index = next.fetch_add(1, Ordering::Relaxed);
                    let Some(path) = programs.get(index) else {
                        break;
                    };
                    if let Some(report) = compare(path) {
                        found.lock().expect("no worker panics").push(report);
                    }
                }
            });
        }
    });
    failures.extend(found.into_inner().expect("no worker panics"));
    failures.sort();
    assert!(
        failures.is_empty(),
        "{} of {} programs differ from node:\n{}",
        failures.len(),
        programs.len(),
        failures.join("\n")
    );
}
