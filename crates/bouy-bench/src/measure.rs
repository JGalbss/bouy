//! Runs one program in a child process and measures its wall time and peak RSS.
//!
//! `getrusage(RUSAGE_CHILDREN)` reports the largest peak RSS among all the children that
//! a process has waited for, so the harness cannot read the peak of each program itself.
//! Instead it starts itself again as `bouy-bench --measure <program> [args...]`. That
//! process waits for one child, the program, and prints a JSON report of it.

use std::env;
use std::ffi::{OsStr, OsString};
use std::process::{Command, ExitCode, Stdio};
use std::time::Instant;

use nix::sys::resource::{UsageWho, getrusage};
use serde::{Deserialize, Serialize};

const MEASURE: &str = "--measure";

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

/// Runs `command` once under a fresh `bouy-bench --measure` process.
pub fn run(command: &[OsString]) -> Result<Process, String> {
    let harness = env::current_exe().map_err(|error| format!("cannot find bouy-bench: {error}"))?;
    let output = Command::new(harness)
        .arg(MEASURE)
        .args(command)
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
    let output = Command::new(program)
        .args(arguments)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("cannot start {}: {error}", program.display()))?;
    let wall_ms = started.elapsed().as_secs_f64() * 1000.0;
    let usage = getrusage(UsageWho::RUSAGE_CHILDREN)
        .map_err(|error| format!("getrusage failed: {error}"))?;
    let process = Process {
        wall_ms,
        peak_rss_kib: u32::try_from(usage.max_rss() / MAXRSS_PER_KIB).unwrap_or(u32::MAX),
        status: output.status.code(),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    };
    serde_json::to_string(&process).map_err(|error| error.to_string())
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
}
