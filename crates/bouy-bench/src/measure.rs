//! Runs one program in a child process and measures its wall time and peak RSS.
//!
//! `getrusage(RUSAGE_CHILDREN)` reports the largest peak RSS among all the children that
//! a process has waited for, so the harness cannot read the peak of each program itself.
//! Instead it starts itself again as `bouy-bench --measure <program> [args...]`. That
//! process waits for one child, the program, and prints a JSON report of it.
//!
//! That process also kills a program whose RSS passes `RSS_CEILING_KIB`. Bun has no heap
//! limit, and macOS enforces no `ulimit` on memory, so the ceiling is the one limit that
//! keeps every program from exhausting the machine.

use std::env;
use std::ffi::{OsStr, OsString};
use std::fmt::Write as _;
use std::process::{Command, ExitCode, Stdio};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

use nix::sys::resource::{UsageWho, getrusage};
use nix::sys::signal::{Signal, kill};
use nix::unistd::Pid;
use serde::{Deserialize, Serialize};

const MEASURE: &str = "--measure";

/// The largest RSS of a program, 1 GiB.
const RSS_CEILING_KIB: u64 = 1024 * 1024;
const RSS_POLL: Duration = Duration::from_millis(200);

/// The units of `ru_maxrss` in one KiB: it counts bytes on macOS and KiB on Linux.
const MAXRSS_PER_KIB: i64 = if cfg!(target_os = "macos") { 1024 } else { 1 };

/// One finished run of a program.
#[derive(Debug, Serialize, Deserialize)]
pub struct Process {
    pub wall_ms: f64,
    pub peak_rss_kib: u32,
    /// The exit status, or `None` when a signal ended the program.
    pub status: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

/// Runs `command` once under a fresh `bouy-bench --measure` process, with the variable
/// `env` set when it is given.
pub fn run(command: &[OsString], env: Option<(&str, &str)>) -> Result<Process, String> {
    let harness = env::current_exe().map_err(|error| format!("cannot find bouy-bench: {error}"))?;
    let output = Command::new(harness)
        .arg(MEASURE)
        .args(command)
        .envs(env)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("cannot start bouy-bench --measure: {error}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_owned());
    }
    serde_json::from_slice(&output.stdout)
        .map_err(|error| format!("bouy-bench --measure printed no report: {error}"))
}

/// The child mode: when the arguments start with `--measure`, runs the program that
/// follows, prints its report, and returns the exit code of this process.
pub fn child() -> Option<ExitCode> {
    let mut arguments = env::args_os().skip(1);
    if arguments.next()? != MEASURE {
        return None;
    }
    let program = arguments.next()?;
    Some(match measure(&program, arguments) {
        Ok(report) => {
            println!("{report}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    })
}

fn measure(program: &OsStr, arguments: impl Iterator<Item = OsString>) -> Result<String, String> {
    let started = Instant::now();
    let child = Command::new(program)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("cannot start {}: {error}", program.display()))?;
    let (exited, exit) = mpsc::channel::<()>();
    let pid = child.id();
    let watchdog = thread::spawn(move || watch_rss(pid, &exit));
    let output = child
        .wait_with_output()
        .map_err(|error| format!("cannot wait for {}: {error}", program.display()))?;
    let wall_ms = started.elapsed().as_secs_f64() * 1000.0;
    drop(exited);
    let killed_at = watchdog.join().unwrap_or(None);
    let usage = getrusage(UsageWho::RUSAGE_CHILDREN)
        .map_err(|error| format!("getrusage failed: {error}"))?;
    let mut stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    if let Some(kib) = killed_at {
        let _ = writeln!(
            stderr,
            "bouy-bench: killed the program at {} MiB of RSS, past the ceiling of {} MiB",
            kib / 1024,
            RSS_CEILING_KIB / 1024
        );
    }
    let process = Process {
        wall_ms,
        peak_rss_kib: u32::try_from(usage.max_rss() / MAXRSS_PER_KIB).unwrap_or(u32::MAX),
        status: output.status.code(),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr,
    };
    serde_json::to_string(&process).map_err(|error| error.to_string())
}

/// Reads the RSS of process `pid` until `exit` closes, and kills the process past the
/// ceiling. Returns the RSS in KiB at the kill.
fn watch_rss(pid: u32, exit: &mpsc::Receiver<()>) -> Option<u64> {
    let target = Pid::from_raw(i32::try_from(pid).ok()?);
    while let Err(RecvTimeoutError::Timeout) = exit.recv_timeout(RSS_POLL) {
        let kib = resident_kib(pid)?;
        if kib > RSS_CEILING_KIB {
            kill(target, Signal::SIGKILL).ok()?;
            return Some(kib);
        }
    }
    None
}

/// The RSS of process `pid` in KiB, from `ps`, or `None` once the process has ended.
fn resident_kib(pid: u32) -> Option<u64> {
    let output = Command::new("ps")
        .args(["-o", "rss=", "-p", &pid.to_string()])
        .output()
        .ok()?;
    String::from_utf8_lossy(&output.stdout).trim().parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_the_output_status_and_memory_of_one_program() {
        let script = ["-c", "echo '{\"calls\":3}'; echo oops >&2; exit 3"].map(OsString::from);
        let report = measure(OsStr::new("sh"), script.into_iter()).expect("sh runs");
        let process: Process = serde_json::from_str(&report).expect("a JSON report");
        assert_eq!(process.status, Some(3));
        assert_eq!(process.stdout, "{\"calls\":3}\n");
        assert_eq!(process.stderr, "oops\n");
        assert!(process.peak_rss_kib > 0);
        assert!(process.wall_ms > 0.0);
    }

    #[test]
    fn reads_the_rss_of_a_live_process_only() {
        let rss = resident_kib(std::process::id()).expect("this process runs");
        assert!(rss > 0);
        assert_eq!(resident_kib(u32::MAX >> 1), None);
    }
}
