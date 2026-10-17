//! The corpora whose expected output Node recorded. Next to each `<name>.ts` of a corpus
//! in `tests/`, `<name>.stdout` holds what Node printed, and `<name>.status` holds the exit
//! status when it is not 0. `scripts/freeze-expectations.sh` records them, so the tests
//! never run node.

use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;

const WORKERS: usize = 4;

/// Whether the VM tests can run: erl is on `PATH`, or `BOUY_SKIP_VM_TESTS` opts out.
pub fn vm_available() -> bool {
    let installed = Command::new("erl")
        .args(["-noshell", "-eval", "halt()."])
        .output()
        .is_ok();
    assert!(
        installed || std::env::var_os("BOUY_SKIP_VM_TESTS").is_some(),
        "erl is not installed; set BOUY_SKIP_VM_TESTS=1 to skip the VM tests"
    );
    installed
}

/// Fails when `tests/<corpus>` holds fewer than `minimum` programs, a program has no
/// recorded stdout, or a recorded output has no program.
pub fn assert_recorded(corpus: &str, minimum: usize) {
    let programs = files(corpus, "ts");
    assert!(
        programs.len() >= minimum,
        "tests/{corpus} has {} programs",
        programs.len()
    );
    let missing: Vec<String> = programs
        .iter()
        .filter(|program| !program.with_extension("stdout").is_file())
        .map(|program| name(program))
        .collect();
    assert!(
        missing.is_empty(),
        "run scripts/freeze-expectations.sh tests/{corpus}; these programs have no .stdout file: {}",
        missing.join(", ")
    );
    let orphans: Vec<String> = files(corpus, "stdout")
        .into_iter()
        .chain(files(corpus, "status"))
        .filter(|recorded| !recorded.with_extension("ts").is_file())
        .map(|recorded| name(&recorded))
        .collect();
    assert!(
        orphans.is_empty(),
        "these recorded outputs have no program: {}",
        orphans.join(", ")
    );
}

/// Runs each program of `tests/<corpus>` that has a recorded stdout with `bouy run`, after
/// `configure` adds environment variables or `run` options to the command, and fails with
/// the lines that differ.
pub fn assert_matches(corpus: &str, configure: impl Fn(&mut Command) + Sync) {
    let programs: Vec<PathBuf> = files(corpus, "ts")
        .into_iter()
        .filter(|program| program.with_extension("stdout").is_file())
        .collect();
    let check = |program: &Path| {
        let mut command = Command::new(env!("CARGO_BIN_EXE_bouy"));
        command.arg("run");
        configure(&mut command);
        command.arg(program);
        compare(program, &mut command)
    };
    // The first run builds the runtime cache, so it runs alone.
    let mut failures: Vec<String> = programs
        .first()
        .and_then(|first| check(first))
        .into_iter()
        .collect();
    let next = AtomicUsize::new(1);
    let found = Mutex::new(Vec::new());
    thread::scope(|scope| {
        for _ in 0..WORKERS {
            scope.spawn(|| {
                while let Some(program) = programs.get(next.fetch_add(1, Ordering::Relaxed)) {
                    if let Some(report) = check(program) {
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
        "{} of {} programs differ from the recorded node output:\n{}",
        failures.len(),
        programs.len(),
        failures.join("\n")
    );
}

fn files(corpus: &str, extension: &str) -> Vec<PathBuf> {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests")
        .join(corpus);
    let mut files: Vec<PathBuf> = fs::read_dir(&directory)
        .unwrap_or_else(|error| panic!("tests/{corpus}: {error}"))
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|found| found == extension))
        .collect();
    files.sort();
    files
}

fn name(path: &Path) -> String {
    path.file_name()
        .map_or_else(String::new, |name| name.to_string_lossy().into_owned())
}

/// The recorded stdout and exit status of `program`.
fn expected(program: &Path) -> (String, i32) {
    let stdout = fs::read_to_string(program.with_extension("stdout"))
        .unwrap_or_else(|error| panic!("{}: no recorded stdout: {error}", name(program)));
    let status = fs::read_to_string(program.with_extension("status")).map_or(0, |text| {
        text.trim()
            .parse()
            .unwrap_or_else(|error| panic!("{}: a bad status file: {error}", name(program)))
    });
    (stdout, status)
}

/// The difference between `command` and the recorded output, or `None` when they agree.
fn compare(program: &Path, command: &mut Command) -> Option<String> {
    let (stdout, status) = expected(program);
    let actual = command
        .output()
        .unwrap_or_else(|error| panic!("cannot run bouy: {error}"));
    let actual_stdout = String::from_utf8_lossy(&actual.stdout);
    if actual_stdout == stdout && actual.status.code() == Some(status) {
        return None;
    }
    let mut report = format!(
        "--- {}: node exited {status}, bouy exited {:?}\n",
        name(program),
        actual.status.code()
    );
    report.push_str(&line_diff(&stdout, &actual_stdout));
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
