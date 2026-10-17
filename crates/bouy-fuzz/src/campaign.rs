//! One trial runs a program on Node and on Bouy and classifies the Bouy run, and one hunt
//! turns a seed into a verdict: a clean run, or a minimized finding.

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::panic::{self, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use bouy_suites::{Facts, Outcome, RunResult, bouy_env, classify};

use crate::generators::Generator;
use crate::minimize::minimize;
use crate::program::Program;

/// The trials that the minimizer may spend on one finding.
const BUDGET: usize = 80;

/// The two programs under comparison.
#[derive(Debug)]
pub struct Tools {
    pub node: PathBuf,
    pub bouy: PathBuf,
    pub deadline: Duration,
}

/// What one program printed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Printed {
    pub stdout: String,
    pub status: Option<i32>,
}

impl Printed {
    fn of(output: &Output) -> Self {
        Self {
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            status: output.status.code(),
        }
    }
}

/// A program run on Node and on Bouy, and the outcome of the Bouy run.
#[derive(Debug, Clone)]
pub struct Trial {
    pub outcome: Outcome,
    pub node: Printed,
    pub bouy: Printed,
    pub diagnostics: Vec<String>,
}

/// What a seed gave.
#[derive(Debug)]
pub enum Verdict {
    /// Node ran past the deadline, so the program has no oracle.
    NoOracle,
    /// Bouy printed what Node printed, or stopped loudly.
    Clean(Outcome),
    /// A silent mismatch or a crash, minimized.
    Found { program: Program, trial: Trial },
}

/// A seed and its verdict, with the diagnostic codes of the statements that the compiler
/// rejected: the coverage gaps.
#[derive(Debug)]
pub struct Hunt {
    pub generator: Generator,
    pub seed: u64,
    pub verdict: Verdict,
    pub gaps: Vec<String>,
}

impl Tools {
    /// Runs `program` on Node, then on Bouy. `None` when Node ran past the deadline or was
    /// killed. `scratch` holds the temporary directories of the two runs.
    pub fn trial(&self, program: &Path, scratch: &Path) -> Option<Trial> {
        let node = self.node(program, scratch)?;
        let result_file = scratch.join("result.json");
        let _ = fs::remove_file(&result_file);
        let mut command = Command::new(&self.bouy);
        bouy_env(&mut command, &temporary(scratch))
            .env("BOUY_RESULT_FILE", &result_file)
            .arg("run")
            .arg(program);
        let run = bouy_suites::run(&mut command, self.deadline);
        let bouy = Printed::of(&run.output);
        let result = RunResult::read(&result_file);
        let facts = Facts::of_run(result.as_ref(), run.timed_out, bouy == node);
        Some(Trial {
            outcome: classify(&facts),
            node,
            bouy,
            diagnostics: result.map(|result| result.diagnostics).unwrap_or_default(),
        })
    }

    /// What Node printed, in the environment of the tests.
    pub fn node(&self, program: &Path, scratch: &Path) -> Option<Printed> {
        let mut command = Command::new(&self.node);
        bouy_env(&mut command, &temporary(scratch)).arg(program);
        let run = bouy_suites::run(&mut command, self.deadline);
        let printed = Printed::of(&run.output);
        (!run.timed_out && printed.status.is_some()).then_some(printed)
    }

    /// Generates the program of `seed`, drops the statements that the compiler rejects,
    /// runs the rest, and minimizes a silent mismatch or a crash. `scratch` is a directory
    /// of this hunt alone.
    pub fn hunt(&self, generator: Generator, seed: u64, scratch: &Path) -> Hunt {
        let path = scratch.join("case.ts");
        let (program, gaps) = compilable(generator.program(seed), &path);
        let hunt = |verdict| Hunt {
            generator,
            seed,
            verdict,
            gaps: gaps.clone(),
        };
        if program.0.is_empty() {
            return hunt(Verdict::Clean(Outcome::Rejected));
        }
        let Some(trial) = self.trial(&path, scratch) else {
            return hunt(Verdict::NoOracle);
        };
        if trial.outcome.rank() < 2 {
            return Hunt {
                gaps: gaps.iter().chain(&trial.diagnostics).cloned().collect(),
                ..hunt(Verdict::Clean(trial.outcome))
            };
        }
        let mut tried: HashMap<String, bool> = HashMap::new();
        let program = minimize(program, |candidate| {
            let source = candidate.source();
            if let Some(known) = tried.get(&source) {
                return *known;
            }
            let reproduces = tried.len() < BUDGET
                && fs::write(&path, &source).is_ok()
                && self
                    .trial(&path, scratch)
                    .is_some_and(|found| found.outcome == trial.outcome);
            tried.insert(source, reproduces);
            reproduces
        });
        let _ = fs::write(&path, program.source());
        let trial = self.trial(&path, scratch).unwrap_or(trial);
        hunt(Verdict::Found { program, trial })
    }
}

/// The program without the statements that the compiler rejects, and the code of each
/// diagnostic. A statement fills one line, so the line of a diagnostic names its statement.
/// One rejected statement then cannot hide a mismatch in the others.
fn compilable(mut program: Program, path: &Path) -> (Program, Vec<String>) {
    let mut gaps = Vec::new();
    while !program.0.is_empty() && fs::write(path, program.source()).is_ok() {
        // A compiler panic is a crash, which the Bouy run reports.
        let Ok(Err(diagnostics)) =
            panic::catch_unwind(AssertUnwindSafe(|| bouy_compiler::compile(path)))
        else {
            break;
        };
        let lines: BTreeSet<usize> = diagnostics.iter().map(|found| found.line).collect();
        gaps.extend(
            diagnostics
                .iter()
                .map(|found| found.code.as_str().to_owned()),
        );
        let before = program.0.len();
        program.0 = program
            .0
            .into_iter()
            .enumerate()
            .filter(|(index, _)| !lines.contains(&(index + 1)))
            .map(|(_, statement)| statement)
            .collect();
        if program.0.len() == before {
            break;
        }
    }
    (program, gaps)
}

/// A new directory under `scratch` for the `TMPDIR` of one run, which the run deletes.
fn temporary(scratch: &Path) -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let directory = scratch.join(format!("tmp-{}", NEXT.fetch_add(1, Ordering::Relaxed)));
    let _ = fs::create_dir_all(&directory);
    directory
}
