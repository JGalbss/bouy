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
pub mod node_bindings;
pub mod node_surface;
pub mod outcome;
pub mod packages;
pub mod summary;
pub mod test262;

use std::collections::BTreeMap;
use std::env;
use std::fmt::Write as _;
use std::fs;
use std::io::{self, Read};
use std::mem;
use std::os::unix::process::CommandExt as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock, PoisonError, mpsc};
use std::thread;
use std::time::{Duration, Instant};

pub use outcome::{Facts, Outcome, RunResult, classify};

/// The reason codes of a skip (section 3.5). A new code needs review.
pub const SKIP_REASONS: [&str; 8] = [
    "needs-dom",
    "can-block",
    "v8-flag",
    "node-internals",
    "native-addon",
    "node-inspector",
    "node-permission-model",
    "node-behavior",
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

/// The scheduler threads of each test VM, which `erl` reads from `ERL_AFLAGS`: 2 schedulers,
/// 2 dirty CPU and 2 dirty I/O schedulers, and no busy wait. A default VM starts a scheduler
/// and a dirty CPU scheduler for each core and 10 dirty I/O schedulers, which spin before
/// they sleep, so the VMs of several runners at once drove the load average past 500 and
/// made tests miss their deadlines. A user's `buoy run` keeps the defaults.
const TEST_SCHEDULERS: &str = "+S 2:2 +SDcpu 2:2 +SDio 2 +sbwt none +sbwtdcpu none +sbwtdio none";

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
/// that starts node fails. The VM halts past `TEST_MEMORY` and runs `TEST_SCHEDULERS`; only
/// the VM reads those variables, so the freeze script leaves them out.
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
        .env("ERL_AFLAGS", TEST_SCHEDULERS)
}

/// Builds the runtime cache of the `buoy` at `program` once per process, before the first
/// run: the first `buoy run` on a machine compiles the runtime, Node's lib included, which
/// takes longer than the deadline of one run. A binary without `buoy runtime`, such as one
/// built from an older commit, builds it on its first run instead.
fn warm(program: &std::ffi::OsStr) {
    static WARMED: OnceLock<()> = OnceLock::new();
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

/// How long the output of a program that exited may take to arrive.
const OUTPUT_GRACE: Duration = Duration::from_secs(2);

/// Runs `command` with no stdin in its own process group, kills it when it runs past
/// `deadline`, and deletes its `TMPDIR`. The CLI replaces itself with the VM, so the kill
/// reaches the VM.
///
/// The run ends when the program exits, as Bun's runner ends a test, and not when its
/// pipes close: a process that the program left behind can hold them open for good. The
/// processes that the run started die after the exit, those that `Watch` recorded out of
/// the group as well, and the output is what the pipes held up to `OUTPUT_GRACE` later.
///
/// # Panics
///
/// When the command cannot start, or the wait for it fails.
pub fn run(command: &mut Command, deadline: Duration) -> Run {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
        .unwrap_or_else(|error| panic!("cannot run {command:?}: {error}"));
    let watched = Watched::start(child.id());
    let stdout = Drain::start(child.stdout.take());
    let stderr = Drain::start(child.stderr.take());
    let (finished, waited) = mpsc::channel();
    thread::spawn(move || finished.send(child.wait()));
    let (status, timed_out) = if let Ok(status) = waited.recv_timeout(deadline) {
        (status, false)
    } else {
        watched.stop(true);
        (waited.recv().expect("the waiting thread sends"), true)
    };
    watched.stop(false);
    let grace = Instant::now() + OUTPUT_GRACE;
    let output = Output {
        status: status.unwrap_or_else(|error| panic!("cannot wait for {command:?}: {error}")),
        stdout: stdout.take(grace),
        stderr: stderr.take(grace),
    };
    if let Some((_, Some(directory))) = command.get_envs().find(|(name, _)| *name == "TMPDIR") {
        let _ = fs::remove_dir_all(directory);
    }
    Run { output, timed_out }
}

/// Sends `SIGKILL` to the process group `group` and to `pids`.
fn kill(group: u32, pids: &[u32]) {
    let _ = Command::new("kill")
        .args(["-s", "KILL", "--", &format!("-{group}")])
        .args(pids.iter().map(u32::to_string))
        .stderr(Stdio::null())
        .status();
}

/// How long the thread of `Watch` waits between two reads of the process table.
const WATCH_INTERVAL: Duration = Duration::from_millis(100);

/// A process of the table that `ps` prints. `start` tells it from a later process that
/// reuses its pid.
#[derive(Clone, Debug)]
struct Process {
    pid: u32,
    parent: u32,
    group: u32,
    start: String,
}

/// The processes of each run that goes on, by the pid of its program, which one thread
/// records from `ps` every `WATCH_INTERVAL`.
///
/// A process group cannot hold the processes of a run: the VM starts each child process in
/// a session of its own, because `erl_child_setup` calls setsid, and when the VM exits, the
/// child gets init as its parent. The record still names it then. Bun's no-orphans mode
/// (src/io/ParentDeathWatchdog.rs) walks the tree from inside the runtime, with
/// `PR_SET_CHILD_SUBREAPER` on Linux and the `p_puniqueid` of libproc on macOS; the runner has
/// no unsafe code for these calls, and a VM killed at the deadline runs no code, so the
/// runner reads `ps` on both systems.
///
/// shortcut: a process that starts and loses its parent between two reads escapes the
/// record; a subreaper on Linux would close that gap if it shows up.
struct Watch {
    runs: Mutex<BTreeMap<u32, BTreeMap<u32, Process>>>,
    added: Condvar,
}

fn watch() -> &'static Watch {
    static WATCH: OnceLock<Watch> = OnceLock::new();
    WATCH.get_or_init(|| {
        thread::spawn(|| {
            let watch = watch();
            loop {
                drop(
                    watch
                        .added
                        .wait_while(lock(&watch.runs), |runs| runs.is_empty())
                        .unwrap_or_else(PoisonError::into_inner),
                );
                let table = processes();
                for (root, record) in lock(&watch.runs).iter_mut() {
                    for process in tree(&table, Some(*root), record) {
                        record.insert(process.pid, process.clone());
                    }
                }
                thread::sleep(WATCH_INTERVAL);
            }
        });
        Watch {
            runs: Mutex::new(BTreeMap::new()),
            added: Condvar::new(),
        }
    })
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A run in the record of `Watch`, which leaves the record when it drops.
struct Watched(u32);

impl Watched {
    fn start(root: u32) -> Self {
        let watch = watch();
        lock(&watch.runs).insert(root, BTreeMap::new());
        watch.added.notify_one();
        Self(root)
    }

    /// Kills the group of the run and every process of its record that still runs, with
    /// the processes under them. `alive` says that the program still runs, so the tree under
    /// it holds as well. A record with nothing out of the group needs no read of `ps`.
    fn stop(&self, alive: bool) {
        let root = self.0;
        let record = lock(&watch().runs).get(&root).cloned().unwrap_or_default();
        let pids = if alive || record.values().any(|process| process.group != root) {
            let table = processes();
            tree(&table, alive.then_some(root), &record)
                .iter()
                .map(|process| process.pid)
                .collect()
        } else {
            Vec::new()
        };
        kill(root, &pids);
    }
}

impl Drop for Watched {
    fn drop(&mut self) {
        lock(&watch().runs).remove(&self.0);
    }
}

/// The processes of `table` that are `root`, the processes of `record` with the same start,
/// or the children or group members of one of them. The runner and its group are never
/// among them.
fn tree<'t>(
    table: &'t [Process],
    root: Option<u32>,
    record: &BTreeMap<u32, Process>,
) -> Vec<&'t Process> {
    let runner = std::process::id();
    let mut found: Vec<&Process> = table
        .iter()
        .filter(|process| {
            Some(process.pid) == root
                || record
                    .get(&process.pid)
                    .is_some_and(|seen| seen.start == process.start)
        })
        .collect();
    let mut index = 0;
    while let Some(parent) = found.get(index).map(|process| process.pid) {
        index += 1;
        for process in table {
            if (process.parent == parent || process.group == parent)
                && !found.iter().any(|known| known.pid == process.pid)
            {
                found.push(process);
            }
        }
    }
    let group = table
        .iter()
        .find(|process| process.pid == runner)
        .map(|process| process.group);
    found.retain(|process| process.pid != runner && Some(process.group) != group);
    found
}

/// The process table, from `ps`.
fn processes() -> Vec<Process> {
    let Ok(output) = Command::new("ps")
        .args(["-A", "-o", "pid=,ppid=,pgid=,lstart="])
        .stderr(Stdio::null())
        .output()
    else {
        return Vec::new();
    };
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let mut number = || fields.next()?.parse().ok();
            let (pid, parent, group) = (number()?, number()?, number()?);
            Some(Process {
                pid,
                parent,
                group,
                start: fields.collect::<Vec<_>>().join(" "),
            })
        })
        .collect()
}

/// A pipe that a thread reads to its end. The caller takes what has arrived so far.
struct Drain {
    bytes: Arc<Mutex<Vec<u8>>>,
    ended: mpsc::Receiver<()>,
}

impl Drain {
    fn start(pipe: Option<impl Read + Send + 'static>) -> Self {
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let (end, ended) = mpsc::channel();
        if let Some(mut pipe) = pipe {
            let bytes = Arc::clone(&bytes);
            thread::spawn(move || {
                let mut chunk = [0; 8192];
                loop {
                    match pipe.read(&mut chunk) {
                        Ok(0) => break,
                        Ok(read) => bytes
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            .extend_from_slice(&chunk[..read]),
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                        Err(_) => break,
                    }
                }
                let _ = end.send(());
            });
        }
        Self { bytes, ended }
    }

    /// The bytes that arrived by the end of the pipe, or by `until`.
    fn take(self, until: Instant) -> Vec<u8> {
        let _ = self
            .ended
            .recv_timeout(until.saturating_duration_since(Instant::now()));
        mem::take(&mut *self.bytes.lock().unwrap_or_else(PoisonError::into_inner))
    }
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

/// A shallow checkout of `reference`, a commit or a tag, of the git repository at `url`, in
/// `$XDG_CACHE_HOME/buoy/<name>`, with only the paths of `sparse` when it names any. The first
/// use fetches into a partial directory and renames it, so the cache never holds a partial
/// checkout. Returns the checkout and the commit of its `HEAD`.
///
/// # Errors
///
/// When neither `HOME` nor `XDG_CACHE_HOME` is set, or a git command fails.
pub fn cached_checkout(
    name: &str,
    url: &str,
    reference: &str,
    sparse: &[&str],
) -> Result<(PathBuf, String), String> {
    let cache = env::var_os("XDG_CACHE_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache")))
        .ok_or("set HOME or XDG_CACHE_HOME for the cache of the upstream sources")?
        .join("buoy");
    let checkout = cache.join(name);
    let git = |directory: &Path, args: &[&str]| -> Result<String, String> {
        let output = Command::new("git")
            .arg("-C")
            .arg(directory)
            .args(args)
            .output()
            .map_err(|error| format!("cannot run git: {error}"))?;
        if output.status.success() {
            return Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned());
        }
        Err(format!(
            "git {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        ))
    };
    if checkout.is_dir() {
        return Ok((checkout.clone(), git(&checkout, &["rev-parse", "HEAD"])?));
    }
    let partial = cache.join(format!("{name}.partial-{}", std::process::id()));
    fs::create_dir_all(&partial).map_err(|error| format!("{}: {error}", partial.display()))?;
    eprintln!("buoy-suites: fetching {url} at {reference}");
    let mut sparse_args = vec!["sparse-checkout", "set", "--no-cone"];
    sparse_args.extend(sparse);
    let fetched = git(&partial, &["init", "-q"])
        .and_then(|_| git(&partial, &["remote", "add", "origin", url]))
        .and_then(|_| {
            if sparse.is_empty() {
                return Ok(String::new());
            }
            git(&partial, &sparse_args)
        })
        .and_then(|_| {
            let mut fetch = vec!["fetch", "-q", "--depth", "1"];
            if !sparse.is_empty() {
                fetch.push("--filter=blob:none");
            }
            fetch.extend(["origin", reference]);
            git(&partial, &fetch)
        })
        .and_then(|_| {
            git(
                &partial,
                &[
                    "-c",
                    "advice.detachedHead=false",
                    "checkout",
                    "-q",
                    "FETCH_HEAD",
                ],
            )
        })
        .and_then(|_| git(&partial, &["rev-parse", "HEAD"]))
        .and_then(|head| {
            fs::rename(&partial, &checkout)
                .map(|()| head)
                .map_err(|error| format!("{}: {error}", checkout.display()))
        });
    if fetched.is_err() {
        let _ = fs::remove_dir_all(&partial);
    }
    fetched.map(|head| (checkout, head))
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
