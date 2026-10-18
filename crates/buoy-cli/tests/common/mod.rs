//! The harness of the Rust tests that run programs (section 8 of docs/design/testing.md), and
//! the corpora whose expected output Node recorded. Next to each `<name>.ts` of a corpus in
//! `tests/`, `<name>.stdout` holds what Node printed, and `<name>.status` holds the exit
//! status when it is not 0. `scripts/freeze-expectations.sh` records them, so the tests never
//! run node.
//!
//! - `BUOY_BIN`: the `buoy` under test. The default is the binary of this build.
//! - `BUOY_TEST_FILTER`: runs only the corpus programs whose path contains the value.
//! - `BUOY_TEST_TIMEOUT`: the deadline of one run in ms. The default is 20 s.

#![allow(dead_code, reason = "each test binary uses a part of this module")]

use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{self, Command};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use buoy_suites::Outcome;
pub use buoy_suites::{Run, line_diff, repository, run};

const DEADLINE: Duration = Duration::from_secs(20);

/// The `buoy` under test, in the environment of `buoy_env`.
pub fn buoy() -> Command {
    let mut command = Command::new(buoy_binary());
    buoy_env(&mut command);
    command
}

/// The `buoy` binary under test: `BUOY_BIN`, which starts at the repository root when it is
/// relative, or the binary of this build.
pub fn buoy_binary() -> PathBuf {
    env::var_os("BUOY_BIN")
        .filter(|value| !value.is_empty())
        .map_or_else(
            || PathBuf::from(env!("CARGO_BIN_EXE_buoy")),
            |value| repository().join(value),
        )
}

/// The environment of every test run, with a fresh `TMPDIR` (`buoy_suites::buoy_env`).
pub fn buoy_env(command: &mut Command) -> &mut Command {
    buoy_suites::buoy_env(command, &fresh_directory())
}

/// A new empty directory under the target directory. `run` deletes it.
fn fresh_directory() -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let directory = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!(
        "run-{}-{}",
        process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&directory).expect("the target directory is writable");
    directory
}

/// The deadline of one run: `BUOY_TEST_TIMEOUT` ms, or 20 s.
pub fn deadline() -> Duration {
    env::var("BUOY_TEST_TIMEOUT").map_or(DEADLINE, |ms| {
        Duration::from_millis(
            ms.parse()
                .unwrap_or_else(|error| panic!("BUOY_TEST_TIMEOUT={ms}: {error}")),
        )
    })
}

/// Whether the VM tests can run: erl is on `PATH`, or `BUOY_SKIP_VM_TESTS` opts out.
pub fn vm_available() -> bool {
    static INSTALLED: OnceLock<bool> = OnceLock::new();
    let installed = *INSTALLED.get_or_init(|| {
        Command::new("erl")
            .args(["-noshell", "-eval", "halt()."])
            .output()
            .is_ok()
    });
    assert!(
        installed || env::var_os("BUOY_SKIP_VM_TESTS").is_some(),
        "erl is not installed; set BUOY_SKIP_VM_TESTS=1 to skip the VM tests"
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

/// Runs each program of `tests/<corpus>` that has a recorded stdout and matches
/// `BUOY_TEST_FILTER` with `buoy run`, after `configure` adds environment variables or `run`
/// options to the command, and fails with
/// the lines that differ.
pub fn assert_matches(corpus: &str, configure: impl Fn(&mut Command) + Sync) {
    let filter = env::var("BUOY_TEST_FILTER").unwrap_or_default();
    let programs: Vec<PathBuf> = files(corpus, "ts")
        .into_iter()
        .filter(|program| program.with_extension("stdout").is_file())
        .filter(|program| format!("tests/{corpus}/{}", name(program)).contains(&filter))
        .collect();
    let deadline = deadline();
    let check = |program: &Path| {
        let mut command = buoy();
        command.arg("run");
        configure(&mut command);
        command.arg(program);
        compare(program, &mut command, deadline)
    };
    let mut failures: Vec<String> = map_parallel(&programs, |program| check(program))
        .into_iter()
        .flatten()
        .collect();
    failures.sort();
    assert!(
        failures.is_empty(),
        "{} of {} programs differ from the recorded node output:\n{}",
        failures.len(),
        programs.len(),
        failures.join("\n")
    );
}

/// `work` of each item, `buoy_suites::default_jobs` at a time, in the order of the items.
pub fn map_parallel<T: Sync, R: Send>(items: &[T], work: impl Fn(&T) -> R + Sync) -> Vec<R> {
    buoy_suites::parallel(items, buoy_suites::default_jobs(), work)
}

fn files(corpus: &str, extension: &str) -> Vec<PathBuf> {
    let directory = repository().join("tests").join(corpus);
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

/// The recorded stdout and exit status of `program`, or of the stem `<dir>/<name>` of
/// `<name>.stdout` and `<name>.status`.
pub fn expected(program: &Path) -> (String, i32) {
    buoy_suites::recorded_output(&program.with_extension("stdout"))
        .unwrap_or_else(|error| panic!("{error}"))
}

/// The difference between `command` and the recorded output, or `None` when they agree.
/// A run past `deadline` differs.
pub fn compare(program: &Path, command: &mut Command, deadline: Duration) -> Option<String> {
    let (stdout, status) = expected(program);
    let Run { output, timed_out } = run(command, deadline);
    let actual_stdout = String::from_utf8_lossy(&output.stdout);
    if !timed_out && actual_stdout == stdout && output.status.code() == Some(status) {
        return None;
    }
    let buoy = if timed_out {
        format!("buoy ran past the deadline of {deadline:?} and was killed")
    } else {
        format!("buoy exited {:?}", output.status.code())
    };
    let mut report = format!("--- {}: node exited {status}, {buoy}\n", name(program));
    report.push_str(&line_diff(&stdout, &actual_stdout));
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !stderr.trim().is_empty() {
        report.push_str("buoy stderr:\n");
        report.push_str(&stderr);
    }
    let _ = writeln!(report, "rerun: {command:?}");
    Some(report)
}

/// The outcome of the `buoy run` that `command` starts (section 3.1), against the output
/// recorded for `recorded`, a program or the stem of its `.stdout` file, and a report of
/// the run for a failure message. `classify` reads the facts of `BUOY_RESULT_FILE`.
pub fn classify_run(recorded: &Path, command: &mut Command) -> (Outcome, String) {
    let directory = fresh_directory();
    let checked = buoy_suites::check_recorded(
        command,
        &name(recorded),
        &recorded.with_extension("stdout"),
        &directory.join("result.json"),
        deadline(),
    );
    let _ = fs::remove_dir_all(&directory);
    let checked = checked.unwrap_or_else(|error| panic!("{error}"));
    (checked.outcome, checked.report)
}

/// Points `command` at the fake model server of `runtime/test/buoy_fake_openai.erl`
/// (`buoy_suites::fake_server`).
pub fn use_fake_openai(command: &mut Command) -> &mut Command {
    buoy_suites::fake_server::point(command).unwrap_or_else(|error| panic!("{error}"))
}
