//! The results file: every run of every program, the summary of the runs, and the facts
//! that the numbers depend on.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{Map, Value};

use crate::environment::{Host, Tools};
use crate::measure::Process;
use crate::summary::Spread;

#[derive(Debug, Serialize)]
pub struct Results {
    pub date: String,
    pub host: Host,
    pub tools: Tools,
    /// The measured runs of each program, after one warm-up run.
    pub runs: usize,
    /// The 1-minute load average before and after every measured run.
    pub load_1m: Option<Spread>,
    pub suites: Vec<Suite>,
}

#[derive(Debug, Serialize)]
pub struct Suite {
    pub name: String,
    /// The Buoy program, then the Node program on Node, then on Bun, then the isolated
    /// program on Node and on Bun when the suite has one.
    pub programs: Vec<Program>,
}

#[derive(Debug, Serialize)]
pub struct Program {
    /// `buoy` runs `programs/<suite>/buoy.ts`, `node` runs `programs/<suite>/node.ts`,
    /// `bun` runs `programs/<suite>/bun.ts`, or `node.ts` when the suite has no `bun.ts`,
    /// and `node-isolated` and `bun-isolated` run `programs/<suite>/isolated.ts`.
    pub runtime: &'static str,
    pub failed: usize,
    /// The median, minimum, and maximum of each metric over the measured runs.
    pub summary: BTreeMap<String, Spread>,
    pub runs: Vec<Run>,
}

#[derive(Debug, Serialize)]
pub struct Run {
    pub load_before: [f64; 3],
    pub load_after: [f64; 3],
    #[serde(flatten)]
    pub outcome: Outcome,
}

#[derive(Debug, Serialize)]
#[serde(tag = "outcome", rename_all = "snake_case")]
pub enum Outcome {
    /// The program exited with status 0 and printed a JSON object as its last line.
    Measured {
        wall_ms: f64,
        peak_rss_kib: u32,
        result: Map<String, Value>,
    },
    Failed {
        error: String,
    },
}

impl From<Process> for Outcome {
    fn from(process: Process) -> Self {
        let line = process
            .stdout
            .lines()
            .rev()
            .find(|line| !line.trim().is_empty())
            .unwrap_or_default();
        match (
            process.status,
            serde_json::from_str::<Map<String, Value>>(line),
        ) {
            (Some(0), Ok(result)) => Self::Measured {
                wall_ms: process.wall_ms,
                peak_rss_kib: process.peak_rss_kib,
                result,
            },
            (Some(0), Err(error)) => failed(&process, &format!("no JSON line ({error})")),
            (Some(status), _) => failed(&process, &format!("exit status {status}")),
            (None, _) => failed(&process, "ended by a signal"),
        }
    }
}

/// A failure with the reason and the last lines of stderr.
fn failed(process: &Process, reason: &str) -> Outcome {
    let lines: Vec<&str> = process.stderr.lines().collect();
    let tail = lines[lines.len().saturating_sub(5)..].join("\n");
    Outcome::Failed {
        error: format!("{reason}: {tail}"),
    }
}

/// Writes `<date>-<host>.json` in `directory`, or `<date>-<host>-<n>.json` when an
/// earlier run of the day holds that name, so a file that a document cites never changes.
pub fn write(directory: &Path, results: &Results) -> Result<PathBuf, String> {
    let fail = |error: &dyn std::fmt::Display| format!("cannot write the results: {error}");
    fs::create_dir_all(directory).map_err(|error| fail(&error))?;
    let stem = format!("{}-{}", results.date, results.host.name);
    let path = (1..=999)
        .map(|n| match n {
            1 => directory.join(format!("{stem}.json")),
            _ => directory.join(format!("{stem}-{n}.json")),
        })
        .find(|path| !path.exists())
        .ok_or_else(|| fail(&"999 results files of the day exist"))?;
    let json = serde_json::to_string_pretty(results).map_err(|error| fail(&error))?;
    fs::write(&path, json + "\n").map_err(|error| fail(&error))?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(status: Option<i32>, stdout: &str) -> Process {
        Process {
            wall_ms: 12.5,
            peak_rss_kib: 2048,
            status,
            stdout: stdout.to_owned(),
            stderr: "first\nbuoy: Worker #1 crashed: Error: boom\n".to_owned(),
        }
    }

    #[test]
    fn measures_a_run_that_prints_a_json_line_last() {
        let outcome = Outcome::from(process(Some(0), "warming up\n{\"calls\":3}\n\n"));
        let Outcome::Measured { result, .. } = outcome else {
            panic!("expected a measured run, got {outcome:?}");
        };
        assert_eq!(result.get("calls"), Some(&Value::from(3)));
    }

    #[test]
    fn fails_a_run_without_status_zero_or_json() {
        for (status, stdout, reason) in [
            (Some(1), "{\"calls\":3}", "exit status 1"),
            (Some(0), "done", "no JSON line"),
            (None, "", "ended by a signal"),
        ] {
            let Outcome::Failed { error } = Outcome::from(process(status, stdout)) else {
                panic!("expected a failed run for {stdout:?}");
            };
            assert!(error.starts_with(reason), "{error}");
            assert!(error.ends_with("crashed: Error: boom"), "{error}");
        }
    }
}
