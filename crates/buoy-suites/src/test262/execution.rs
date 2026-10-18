//! One execution of one test in one mode: the compile outcome of section 5.5 and, until
//! the batch runner of phase 8, the run through `buoy run`.

use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{self, Command};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use super::catalog::{Harness, HarnessFile, Mode, Test};
use super::compile::{Compile, Compilers, Found, Kind};
use super::frontmatter::{Negative, Phase};
use super::{Config, Options};
use crate::buoy_env;
use crate::expectations::Entry;
use crate::outcome::{Facts, Outcome, RunResult, classify};
use crate::summary::{self, TestResult};

/// The codes of `diagnostics`, sorted, each once.
fn codes(diagnostics: &[Found]) -> Vec<String> {
    let codes: BTreeSet<&str> = diagnostics
        .iter()
        .map(|diagnostic| diagnostic.code.as_str())
        .collect();
    codes.into_iter().map(str::to_owned).collect()
}

/// What the executions of one test share.
#[derive(Debug)]
pub(super) struct Context {
    checkout: PathBuf,
    compilers: Compilers,
    harness: Harness,
    /// A directory for the programs of the strict mode and of the runs.
    pub(super) scratch: PathBuf,
    buoy: PathBuf,
    timeout: Duration,
    next: AtomicUsize,
}

/// Numbers the runs of this process, so each run has its own scratch directory.
static RUNS: AtomicUsize = AtomicUsize::new(0);

impl Context {
    pub(super) fn new(
        checkout: PathBuf,
        compilers: Compilers,
        harness: Harness,
        options: &Options,
        config: &Config,
    ) -> Self {
        let scratch = env::temp_dir().join(format!(
            "buoy-test262-{}-{}",
            process::id(),
            RUNS.fetch_add(1, Ordering::Relaxed)
        ));
        Self {
            checkout,
            compilers,
            harness,
            scratch,
            buoy: options.buoy.clone(),
            timeout: Duration::from_millis(config.timeout_ms),
            next: AtomicUsize::new(0),
        }
    }

    /// A new empty directory in the scratch directory.
    fn fresh_directory(&self) -> PathBuf {
        let directory = self
            .scratch
            .join(self.next.fetch_add(1, Ordering::Relaxed).to_string());
        let _ = fs::create_dir_all(&directory);
        directory
    }
}

/// The outcome of one test and what the report and the summary need from its run.
#[derive(Debug)]
pub(super) struct Record {
    pub(super) entry: Entry,
    time_ms: BTreeMap<String, u128>,
    detail: String,
    /// The diagnostic codes, the late rejections, and the harness files that kept the test
    /// from passing.
    pub(super) blockers: Vec<String>,
}

impl Record {
    pub(super) fn into_result(self) -> TestResult {
        TestResult {
            outcome: self.entry.to_string(),
            time_ms: self.time_ms,
            detail: summary::detail(&self.detail),
        }
    }
}

pub(super) fn record(test: &Test, config: &Config, context: &Context) -> Record {
    if let Some(skip) = config.skip.iter().find(|skip| skip.applies(test)) {
        return Record {
            entry: Entry::Same(Outcome::Skip),
            time_ms: BTreeMap::new(),
            detail: skip.reason.clone(),
            blockers: Vec::new(),
        };
    }
    let mut outcomes = BTreeMap::new();
    let mut time_ms = BTreeMap::new();
    let mut details = Vec::new();
    let mut blockers = BTreeSet::new();
    for mode in &test.modes {
        let started = Instant::now();
        let execution = execute(test, *mode, context);
        let outcome = classify(&execution.facts);
        time_ms.insert(mode.name().to_owned(), started.elapsed().as_millis());
        outcomes.insert(mode.name().to_owned(), outcome);
        if outcome != Outcome::Pass {
            blockers.extend(execution.blockers);
            details.push(match test.modes.len() {
                1 => execution.detail,
                _ => format!("{}: {}", mode.name(), execution.detail),
            });
        }
    }
    Record {
        entry: Entry::of_modes(outcomes),
        time_ms,
        detail: details.join("; "),
        blockers: blockers.into_iter().collect(),
    }
}

/// The facts of one execution, what blocked it, and a detail for `results.json`.
#[derive(Debug, Default)]
struct Execution {
    facts: Facts,
    blockers: Vec<String>,
    detail: String,
}

impl Execution {
    fn bug(detail: String) -> Self {
        Self {
            facts: Facts {
                bug: Some(detail.clone()),
                ..Facts::default()
            },
            detail,
            ..Self::default()
        }
    }

    fn rejected(codes: Vec<String>, blockers: Vec<String>) -> Self {
        Self {
            detail: blockers.join(" "),
            facts: Facts {
                diagnostics: codes,
                ..Facts::default()
            },
            blockers,
        }
    }
}

fn execute(test: &Test, mode: Mode, context: &Context) -> Execution {
    let source = match fs::read_to_string(&test.path) {
        Ok(source) => source,
        Err(error) => return Execution::bug(format!("cannot read the test: {error}")),
    };
    let (compiled, compiled_path) = match mode {
        Mode::Strict => {
            let directory = context.fresh_directory();
            let path = directory.join(test.path.file_name().unwrap_or_default());
            if let Err(error) = fs::write(&path, format!("\"use strict\";\n{source}")) {
                return Execution::bug(format!("cannot write the strict program: {error}"));
            }
            let compiled = context.compilers.compile(&path, &directory, false);
            let canonical = path.canonicalize().unwrap_or(path);
            let _ = fs::remove_dir_all(&directory);
            (compiled, canonical)
        }
        Mode::NonStrict | Mode::Module => {
            let compiled =
                context
                    .compilers
                    .compile(&test.path, &context.checkout, mode == Mode::Module);
            let canonical = test
                .path
                .canonicalize()
                .unwrap_or_else(|_| test.path.clone());
            (compiled, canonical)
        }
    };
    if let Some(negative) = &test.frontmatter.negative
        && negative.phase != Phase::Runtime
    {
        return early(negative, &compiled, &compiled_path);
    }
    let harness: Vec<(&str, &HarnessFile)> = test
        .includes
        .iter()
        .filter_map(|name| Some((name.as_str(), context.harness.files.get(name)?)))
        .collect();
    let panicked = std::iter::once(("the test", &compiled))
        .chain(harness.iter().map(|(name, file)| (*name, &file.compiled)))
        .find_map(|(name, compiled)| match compiled {
            Compile::Bug(message) => Some(format!("{name}: {message}")),
            _ => None,
        });
    if let Some(message) = panicked {
        return Execution::bug(message);
    }
    let mut all_codes = BTreeSet::new();
    let mut blockers = Vec::new();
    if let Compile::Diagnostics(diagnostics) = &compiled {
        all_codes.extend(codes(diagnostics));
        blockers.extend(codes(diagnostics));
    }
    for (name, file) in &harness {
        if let Compile::Diagnostics(diagnostics) = &file.compiled {
            all_codes.extend(codes(diagnostics));
            blockers.push(format!("harness/{name}"));
        }
    }
    if !all_codes.is_empty() {
        return Execution::rejected(all_codes.into_iter().collect(), blockers);
    }
    run_program(test, mode, &source, &harness, context)
}

/// A parse-phase test passes when the compiler reports BUOY200 for the test file, and a
/// resolution-phase test passes on the error for a missing export. Any other code is
/// `rejected` and never a pass.
fn early(negative: &Negative, compiled: &Compile, path: &Path) -> Execution {
    let expected = match negative.phase {
        Phase::Parse => Kind::Syntax,
        Phase::Resolution | Phase::Runtime => Kind::MissingExport,
    };
    match compiled {
        Compile::Bug(message) => Execution::bug(message.clone()),
        Compile::Diagnostics(diagnostics)
            if diagnostics.iter().any(|diagnostic| {
                diagnostic.kind == expected
                    && (negative.phase == Phase::Resolution || diagnostic.path == path)
            }) =>
        {
            Execution {
                facts: Facts {
                    passed: true,
                    ..Facts::default()
                },
                ..Execution::default()
            }
        }
        Compile::Diagnostics(diagnostics) => {
            Execution::rejected(codes(diagnostics), codes(diagnostics))
        }
        Compile::Clean => Execution {
            detail: format!(
                "compiled with no diagnostic; test262 expects a {} in the {:?} phase",
                negative.error, negative.phase
            ),
            ..Execution::default()
        },
    }
}

/// Runs a test that compiled, with its harness files, through `buoy run`.
///
/// shortcut: the program is one file, the harness files and then the test, and a script
/// runs as a `.cjs` file, the sloppy goal that `buoy run` has, while section 5.5 runs each
/// harness file as its own script in the realm of the test. So no run gives
/// `harness_error` yet. The batch runner of phase 8 replaces this.
fn run_program(
    test: &Test,
    mode: Mode,
    source: &str,
    harness: &[(&str, &HarnessFile)],
    context: &Context,
) -> Execution {
    let mut contents = String::new();
    if mode == Mode::Strict {
        contents.push_str("\"use strict\";\n");
    }
    for (_, file) in harness {
        contents.push_str(&file.source);
        contents.push('\n');
    }
    contents.push_str(source);
    let directory = context.fresh_directory();
    let stem = test
        .path
        .file_stem()
        .map_or_else(String::new, |stem| stem.to_string_lossy().into_owned());
    // A module stays next to the test, so its imports of `_FIXTURE.js` files resolve.
    let program = match mode {
        Mode::Module => test
            .path
            .with_file_name(format!(".{stem}.buoy-{}.mjs", process::id())),
        Mode::NonStrict | Mode::Strict => directory.join(format!("{stem}.cjs")),
    };
    if let Err(error) = fs::write(&program, contents) {
        return Execution::bug(format!("cannot write {}: {error}", program.display()));
    }
    let result_file = directory.join("result.json");
    let temporary = directory.join("tmp");
    let _ = fs::create_dir_all(&temporary);
    let mut command = Command::new(&context.buoy);
    buoy_env(&mut command, &temporary)
        .env("BUOY_RESULT_FILE", &result_file)
        .arg("run")
        .arg(&program);
    let run = crate::run(&mut command, context.timeout);
    let result = RunResult::read(&result_file);
    let _ = fs::remove_file(&program);
    let _ = fs::remove_dir_all(&directory);
    let stdout = String::from_utf8_lossy(&run.output.stdout);
    let uncaught = result.as_ref().and_then(|result| result.uncaught.as_ref());
    let passed = match &test.frontmatter.negative {
        Some(negative) => uncaught.and_then(|error| error.name.as_deref()) == Some(&negative.error),
        None if test.frontmatter.has_flag("async") => stdout
            .lines()
            .any(|line| line == "Test262:AsyncTestComplete"),
        None => result.as_ref().is_some_and(|result| result.status == 0),
    };
    let detail = match (&result, run.timed_out) {
        (_, true) => format!("ran past the deadline of {:?}", context.timeout),
        (None, false) => format!(
            "exited {:?} with no result: {}",
            run.output.status.code(),
            String::from_utf8_lossy(&run.output.stderr).trim()
        ),
        (Some(result), false) => format!(
            "exited {}{}{}",
            result.status,
            uncaught.map_or_else(String::new, |error| format!(
                "; uncaught {}: {}",
                error.name.as_deref().unwrap_or("value"),
                error.message.as_deref().unwrap_or_default()
            )),
            result
                .erlang
                .as_ref()
                .map_or_else(String::new, |reason| format!("; {reason}"))
        ),
    };
    let late = uncaught
        .filter(|error| error.code.as_deref() == Some("ERR_BUOY_UNSUPPORTED"))
        .and_then(|error| error.message.clone());
    Execution {
        facts: Facts::of_run(result.as_ref(), run.timed_out, passed),
        blockers: late.into_iter().collect(),
        detail,
    }
}
