//! The runner of the upstream test suites of docs/design/testing.md: the outcomes and
//! `classify` of section 3.1, the expectation files of section 3.2, the comparison of
//! section 3.3, the summaries of section 3.6, the selection of section 3.7, the test262
//! runner of section 5.5, the Node runner of section 5.7, the Node API surface of section
//! 5.7.1, the ecosystem tier of section 5.8, and the dashboard of section 6.
//! `tests/rules.rs` checks the rules of the test layout of section 7.

pub mod comparison;
pub mod compat;
pub mod expectations;
pub mod fake_server;
pub mod node;
pub mod node_surface;
pub mod outcome;
pub mod packages;
pub mod summary;
pub mod test262;

use std::collections::BTreeMap;
use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, PoisonError, mpsc};
use std::thread;
use std::time::{Duration, Instant};

pub use outcome::{Facts, Outcome, RunResult, classify};

/// The reason codes of a skip (section 3.5). A new code needs review.
pub const SKIP_REASONS: [&str; 7] = [
    "needs-dom",
    "can-block",
    "v8-flag",
    "node-internals",
    "native-addon",
    "node-inspector",
    "node-permission-model",
];

/// The host variables that a run keeps: the home directory, the cache of the runtime, and
/// the Erlang that `buoy` uses.
const KEPT: [&str; 4] = ["HOME", "XDG_CACHE_HOME", "BUOY_ERL", "BUOY_RUNTIME"];

#[must_use]
pub fn repository() -> PathBuf {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    root.canonicalize().unwrap_or(root)
}

/// The memory limit of each test VM (`BUOY_MAX_MEMORY` of `buoy_guard`). A program of a
/// test needs far less, and `MAX_JOBS` VMs at once stay under 8 GiB.
const TEST_MEMORY: &str = "1G";

/// The most VMs that a runner starts at once by default.
const MAX_JOBS: usize = 8;

/// The default number of workers of a runner: the cores, at most `MAX_JOBS`.
#[must_use]
pub fn default_jobs() -> usize {
    thread::available_parallelism().map_or(4, |cores| cores.get().min(MAX_JOBS))
}

/// The environment of every test run (section 8), which the freeze script copies: the host
/// variables except `KEPT` are gone, the time zone, locale, and color are fixed, `TMPDIR`
/// is `temporary`, and the `node` shim of `tests/shim` comes first on `PATH`, so a run
/// that starts node fails. The VM halts past `TEST_MEMORY`; only the VM reads that variable,
/// so the freeze script leaves it out.
pub fn buoy_env<'a>(command: &'a mut Command, temporary: &Path) -> &'a mut Command {
    warm(command.get_program());
    let mut path = repository().join("tests/shim").into_os_string();
    path.push(":");
    path.push(env::var_os("PATH").unwrap_or_default());
    command
        .env_clear()
        .envs(
            KEPT.iter()
                .filter_map(|name| Some((name, env::var_os(name)?))),
        )
        .env("PATH", path)
        .env("TZ", "Etc/UTC")
        .env("LANG", "C.UTF-8")
        .env("NO_COLOR", "1")
        .env("CI", "1")
        .env("TMPDIR", temporary)
        .env("BUOY_MAX_MEMORY", TEST_MEMORY)
}

/// Builds the runtime cache of the `buoy` at `program` once per process, before the first
/// run: the first `buoy run` on a machine compiles the runtime, Node's lib included, which
/// takes longer than the deadline of one run. A binary without `buoy runtime`, such as one
/// built from an older commit, builds it on its first run instead.
fn warm(program: &std::ffi::OsStr) {
    static WARMED: std::sync::OnceLock<()> = std::sync::OnceLock::new();
    WARMED.get_or_init(|| {
        let _ = Command::new(program)
            .arg("runtime")
            .env("BUOY_MAX_MEMORY", TEST_MEMORY)
            .stdin(Stdio::null())
            .output();
    });
}

/// What a run printed, and whether it ran past its deadline.
#[derive(Debug)]
pub struct Run {
    pub output: Output,
    pub timed_out: bool,
}

/// Runs `command` with no stdin, kills it when it runs past `deadline`, and deletes its
/// `TMPDIR`. The CLI replaces itself with the VM, so the kill reaches the VM.
///
/// # Panics
///
/// When the command cannot start, or the wait for it fails.
pub fn run(command: &mut Command, deadline: Duration) -> Run {
    let child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap_or_else(|error| panic!("cannot run {command:?}: {error}"));
    let pid = child.id();
    let (finished, waited) = mpsc::channel();
    thread::spawn(move || finished.send(child.wait_with_output()));
    let (output, timed_out) = if let Ok(output) = waited.recv_timeout(deadline) {
        (output, false)
    } else {
        // The processes that the program started would keep its pipes open, and the
        // wait alive: they end first, before they lose their parent.
        let mut doomed = descendants(pid);
        doomed.push(pid);
        let _ = Command::new("kill")
            .arg("-KILL")
            .args(doomed.iter().map(u32::to_string))
            .stderr(Stdio::null())
            .status();
        (waited.recv().expect("the waiting thread sends"), true)
    };
    if let Some((_, Some(directory))) = command.get_envs().find(|(name, _)| *name == "TMPDIR") {
        let _ = fs::remove_dir_all(directory);
    }
    Run {
        output: output.unwrap_or_else(|error| panic!("cannot wait for {command:?}: {error}")),
        timed_out,
    }
}

/// The processes under `pid`, from `ps`.
fn descendants(pid: u32) -> Vec<u32> {
    let Ok(output) = Command::new("ps").args(["-A", "-o", "pid=,ppid="]).output() else {
        return Vec::new();
    };
    let pairs: Vec<(u32, u32)> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace().map(str::parse::<u32>);
            Some((fields.next()?.ok()?, fields.next()?.ok()?))
        })
        .collect();
    let mut found = Vec::new();
    let mut frontier = vec![pid];
    while let Some(parent) = frontier.pop() {
        for &(child, _) in pairs.iter().filter(|(_, ppid)| *ppid == parent) {
            found.push(child);
            frontier.push(child);
        }
    }
    found
}

/// The lines that differ, as `-` (node) and `+` (buoy).
#[must_use]
pub fn line_diff(expected: &str, actual: &str) -> String {
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

/// The stdout that Node recorded in `stdout_file`, and the exit status in the `.status` file
/// next to it, or 0 when there is no status file.
///
/// # Errors
///
/// When `stdout_file` cannot be read, or the status file holds no number.
pub fn recorded_output(stdout_file: &Path) -> Result<(String, i32), String> {
    let stdout = fs::read_to_string(stdout_file)
        .map_err(|error| format!("{}: {error}", stdout_file.display()))?;
    let status_file = stdout_file.with_extension("status");
    let status = match fs::read_to_string(&status_file) {
        Ok(text) => text
            .trim()
            .parse()
            .map_err(|error| format!("{}: {error}", status_file.display()))?,
        Err(_) => 0,
    };
    Ok((stdout, status))
}

/// A `buoy run` classified against the output that Node recorded for its program.
#[derive(Debug)]
pub struct Checked {
    pub outcome: Outcome,
    /// The facts that the run wrote to `BUOY_RESULT_FILE`.
    pub result: Option<RunResult>,
    /// The outcome, the lines that differ, stderr, and the command that reproduces the run.
    pub report: String,
    pub time_ms: u128,
}

/// Runs `command`, a `buoy run` of the program `label`, kills it past `deadline`, and
/// classifies it (section 3.1) against the output that Node recorded in `stdout_file`. The
/// run writes its facts to `result_file`.
///
/// # Errors
///
/// When the recorded output cannot be read.
pub fn check_recorded(
    command: &mut Command,
    label: &str,
    stdout_file: &Path,
    result_file: &Path,
    deadline: Duration,
) -> Result<Checked, String> {
    let (expected_stdout, expected_status) = recorded_output(stdout_file)?;
    command.env("BUOY_RESULT_FILE", result_file);
    let started = Instant::now();
    let Run { output, timed_out } = run(command, deadline);
    let time_ms = started.elapsed().as_millis();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let passed = *stdout == *expected_stdout && output.status.code() == Some(expected_status);
    let result = RunResult::read(result_file);
    let outcome = classify(&Facts::of_run(result.as_ref(), timed_out, passed));
    let report = format!(
        "--- {label}: {outcome}, exit status {:?}, node exited {expected_status}\n\
         --- stdout, `-` for node and `+` for buoy:\n{}--- stderr:\n{}rerun: {command:?}\n",
        output.status.code(),
        line_diff(&expected_stdout, &stdout),
        String::from_utf8_lossy(&output.stderr),
    );
    Ok(Checked {
        outcome,
        result,
        report,
        time_ms,
    })
}

/// Maps `items` with `jobs` worker threads and keeps the order of `items`. The first item
/// runs alone, because the first `buoy run` on a machine builds the runtime cache.
pub fn parallel<T: Sync, R: Send>(
    items: &[T],
    jobs: usize,
    map: impl Fn(&T) -> R + Sync,
) -> Vec<R> {
    let Some((first, rest)) = items.split_first() else {
        return Vec::new();
    };
    let first = map(first);
    let next = AtomicUsize::new(0);
    let results: Mutex<Vec<(usize, R)>> = Mutex::new(Vec::with_capacity(rest.len()));
    thread::scope(|scope| {
        for _ in 0..jobs.max(1) {
            scope.spawn(|| {
                loop {
                    let index = next.fetch_add(1, Ordering::Relaxed);
                    let Some(item) = rest.get(index) else {
                        break;
                    };
                    let result = map(item);
                    results
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .push((index, result));
                }
            });
        }
    });
    let mut results = results.into_inner().unwrap_or_else(PoisonError::into_inner);
    results.sort_by_key(|(index, _)| *index);
    std::iter::once(first)
        .chain(results.into_iter().map(|(_, result)| result))
        .collect()
}

pub(crate) fn write(path: &Path, contents: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| format!("{}: {error}", parent.display()))?;
    }
    fs::write(path, contents).map_err(|error| format!("{}: {error}", path.display()))
}

pub(crate) fn json(value: &impl serde::Serialize) -> Result<String, String> {
    serde_json::to_string_pretty(value)
        .map(|text| text + "\n")
        .map_err(|error| error.to_string())
}

pub(crate) fn date() -> String {
    Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
        .unwrap_or_default()
}

/// The versions of the tools of a run: `buoy`, OTP, and the source of the suite.
pub(crate) fn tools(buoy: &Path, (suite, version): (&str, &str)) -> BTreeMap<String, String> {
    let output = |command: &mut Command| {
        command
            .output()
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
            .unwrap_or_default()
    };
    BTreeMap::from([
        (
            "buoy".to_owned(),
            output(Command::new(buoy).arg("--version")),
        ),
        (
            "otp".to_owned(),
            output(Command::new("erl").args([
                "-noshell",
                "-eval",
                "io:put_chars(erlang:system_info(otp_release)), halt().",
            ])),
        ),
        (suite.to_owned(), version.to_owned()),
    ])
}
