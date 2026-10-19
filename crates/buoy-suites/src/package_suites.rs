//! The package suites of section 5.8 d of docs/design/testing.md: the own test suites of the
//! most downloaded npm packages, each run one test file at a time under Buoy.
//!
//! `scripts/package-suites.sh` writes `sources.json`, the repository and commit of each
//! ranked package at the version of `tests/ecosystem`, clones each one into the cache, and
//! installs their dev dependencies from `pnpm-lock.yaml`. `buoy-suites package-suites --plan`
//! reads each checkout and writes `lookup.json`, the command line of each test file (see
//! `plan`). `scripts/freeze-expectations.sh tests/package-suites` runs each file three times
//! on Node and writes `node.txt`. A file that passes each Node run is a test of the tier, and
//! the run classifies `buoy <the same command line>` from the checkout: it passes when the
//! runner exits with status 0, as on Node.

pub mod plan;

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::buoy_env;
use crate::comparison::{self, Comparison, Origin};
use crate::expectations::{self, Entry, Expectations};
use crate::outcome::{Facts, Outcome, RunResult, classify};
use crate::summary::{self, Counts, Results, Summary, TestResult};

/// The directory of the tier under the repository root.
pub const DIRECTORY: &str = "tests/package-suites";

/// The command that rewrites the expectation file and the summary.
pub const UPDATE: &str = "cargo build --release -p buoy-cli && cargo run --release -p buoy-suites -- package-suites --update";

/// The lines of each list of the report, and the failure reports that it prints in full.
const REPORT_LINES: usize = 50;
const REPORTED_RUNS: usize = 10;

#[derive(Debug)]
pub struct Options {
    /// The repository root.
    pub root: PathBuf,
    /// The directory of the checkouts, which `scripts/package-suites.sh install` writes.
    pub checkouts: PathBuf,
    /// Where the run writes `results.json` and the regenerated files.
    pub output: PathBuf,
    /// The `buoy` binary under test.
    pub buoy: PathBuf,
    /// Runs only the test files whose id, `<package>/<file>`, contains this text.
    pub filter: Option<String>,
    pub update: bool,
    pub jobs: usize,
    pub deadline: Duration,
}

/// `sources.json`: each ranked package that the script considered, with its source or the
/// reason that it has none.
#[derive(Debug, Deserialize)]
struct Sources {
    packages: Vec<Source>,
}

#[derive(Debug, Clone, Deserialize)]
struct Source {
    rank: usize,
    name: String,
    version: String,
    repository: Option<String>,
    commit: Option<String>,
    excluded: Option<String>,
}

/// `lookup.json`: each package with the runs of its test files, or the reason that it has
/// none.
#[derive(Debug, Serialize, Deserialize)]
struct Lookup {
    generated_by: String,
    packages: Vec<Suite>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Suite {
    rank: usize,
    name: String,
    version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    commit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    excluded: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    runs: Vec<plan::Run>,
}

/// Writes `lookup.json` from `sources.json` and the checkouts under `checkouts`.
///
/// # Errors
///
/// When a file cannot be read or written.
pub fn write_plan(root: &Path, checkouts: &Path) -> Result<(usize, usize), String> {
    let file = format!("{DIRECTORY}/sources.json");
    let text = fs::read_to_string(root.join(&file)).map_err(|error| format!("{file}: {error}"))?;
    let sources: Sources =
        serde_json::from_str(&text).map_err(|error| format!("{file}: {error}"))?;
    let packages: Vec<Suite> = sources
        .packages
        .into_iter()
        .map(|source| {
            let planned = match &source.excluded {
                Some(reason) => Err(reason.clone()),
                None => plan::derive(&checkouts.join(&source.name)),
            };
            let (runs, excluded) = match planned {
                Ok(runs) => (runs, None),
                Err(reason) => (Vec::new(), Some(reason)),
            };
            Suite {
                rank: source.rank,
                name: source.name,
                version: source.version,
                repository: source.repository,
                commit: source.commit,
                excluded,
                runs,
            }
        })
        .collect();
    let planned = packages
        .iter()
        .filter(|suite| !suite.runs.is_empty())
        .count();
    let files = packages.iter().map(|suite| suite.runs.len()).sum();
    let lookup = Lookup {
        generated_by: "buoy-suites package-suites --plan".to_owned(),
        packages,
    };
    crate::write(
        &root.join(DIRECTORY).join("lookup.json"),
        &crate::json(&lookup)?,
    )?;
    Ok((planned, files))
}

/// What one run of the tier found.
#[derive(Debug)]
pub struct Report {
    pub tests: usize,
    pub run: Expectations,
    pub comparison: Comparison,
    reports: Vec<String>,
    pub summary: Option<Summary>,
}

impl Report {
    #[must_use]
    pub fn fails(&self) -> bool {
        self.comparison.fails(false)
    }

    #[must_use]
    pub fn text(&self) -> String {
        let mut text = format!(
            "{DIRECTORY}: {} of {} test files ran\n",
            self.run.len(),
            self.tests
        );
        text.push_str(&self.comparison.report(UPDATE, REPORT_LINES));
        for report in self.reports.iter().take(REPORTED_RUNS) {
            text.push_str(report);
        }
        if let Some(summary) = &self.summary {
            let outcomes: Vec<String> = Outcome::ALL
                .iter()
                .map(|outcome| format!("{outcome} {}", summary.outcomes.get(*outcome)))
                .collect();
            let _ = writeln!(text, "{} summary: {}", summary.suite, outcomes.join(", "));
        }
        text
    }
}

/// One test of the tier: a test file that passes on Node, its package, and its run.
#[derive(Debug)]
struct Test {
    id: String,
    package: String,
    run: plan::Run,
}

/// The outcome of one run of a test file under Buoy.
#[derive(Debug)]
struct Execution {
    outcome: Outcome,
    blockers: Vec<String>,
    report: String,
    time_ms: u128,
}

/// Runs the test files that pass on Node and compares the run with `expectations.txt`.
///
/// # Errors
///
/// When a file of the tier cannot be read or written, or a checkout is missing.
pub fn run(options: &Options) -> Result<Report, String> {
    if options.update && options.filter.is_some() {
        return Err("--update runs every test file, so it takes no --filter".to_owned());
    }
    let started = Instant::now();
    let directory = options.root.join(DIRECTORY);
    let lookup = read_lookup(&directory)?;
    let node = read_node(&directory.join("node.txt"))?;
    let tests: Vec<Test> = lookup
        .packages
        .iter()
        .flat_map(|suite| {
            suite.runs.iter().map(|run| Test {
                id: format!("{}/{}", suite.name, run.file),
                package: suite.name.clone(),
                run: run.clone(),
            })
        })
        .filter(|test| node.get(&test.id).map(String::as_str) == Some("pass"))
        .collect();
    let ids: BTreeSet<String> = tests.iter().map(|test| test.id.clone()).collect();
    let selected: Vec<&Test> = tests
        .iter()
        .filter(|test| {
            options
                .filter
                .as_ref()
                .is_none_or(|filter| test.id.contains(filter.as_str()))
        })
        .collect();
    if let Some(missing) = selected
        .iter()
        .find(|test| !options.checkouts.join(&test.package).is_dir())
    {
        return Err(format!(
            "{} is missing; run scripts/package-suites.sh install",
            options.checkouts.join(&missing.package).display()
        ));
    }
    let scratch = options.output.join("scratch");
    let executions = crate::parallel(&selected, options.jobs, |test| {
        execute(options, test, &scratch)
    });
    let _ = fs::remove_dir_all(&scratch);
    let path = directory.join("expectations.txt");
    let expected = if path.is_file() {
        expectations::read(&path)?
    } else {
        Expectations::new()
    };
    let run: Expectations = selected
        .iter()
        .zip(&executions)
        .map(|(test, execution)| (test.id.clone(), Entry::Same(execution.outcome)))
        .collect();
    let comparison = comparison::compare(Origin::Upstream, &run, &ids, &expected, None);
    let mut entries: Expectations = expected
        .iter()
        .filter(|(id, _)| ids.contains(*id))
        .map(|(id, entry)| (id.clone(), entry.clone()))
        .collect();
    entries.extend(run.clone());
    let header = [format!(
        "Generated by `buoy-suites package-suites --update`. Do not edit. {} test files of {DIRECTORY}.",
        ids.len()
    )];
    let file = expectations::write(&header, &entries);
    crate::write(&options.output.join("expectations.txt"), &file)?;
    if options.update {
        crate::write(&path, &file)?;
    }
    let summary = options
        .filter
        .is_none()
        .then(|| summarize(&options.root, &lookup, &tests, &entries, &executions))
        .transpose()?;
    if let Some(summary) = &summary {
        let text = crate::json(summary)?;
        crate::write(&options.output.join("summary.json"), &text)?;
        if options.update {
            crate::write(&directory.join("summary.json"), &text)?;
        }
    }
    let reports = selected
        .iter()
        .zip(&executions)
        .filter(|(test, execution)| {
            !options.update && expected.get(&test.id) != Some(&Entry::Same(execution.outcome))
        })
        .map(|(_, execution)| execution.report.clone())
        .collect();
    write_results(options, started, &selected, &executions)?;
    Ok(Report {
        tests: ids.len(),
        run,
        comparison,
        reports,
        summary,
    })
}

/// `results.json`: the outcome, the time, and the report of each test file that ran.
fn write_results(
    options: &Options,
    started: Instant,
    selected: &[&Test],
    executions: &[Execution],
) -> Result<(), String> {
    let results = Results {
        date: crate::date(),
        host: format!("{}-{}", std::env::consts::OS, std::env::consts::ARCH),
        tools: crate::tools(&options.buoy, ("oracle", &node_version(&options.root)?)),
        durations_ms: BTreeMap::from([("run".to_owned(), started.elapsed().as_millis())]),
        tests: selected
            .iter()
            .zip(executions)
            .map(|(test, execution)| {
                let result = TestResult {
                    outcome: execution.outcome.to_string(),
                    time_ms: BTreeMap::from([("run".to_owned(), execution.time_ms)]),
                    detail: summary::detail(&execution.report),
                };
                (test.id.clone(), result)
            })
            .collect(),
    };
    crate::write(
        &options.output.join("results.json"),
        &crate::json(&results)?,
    )
}

fn read_lookup(directory: &Path) -> Result<Lookup, String> {
    let file = directory.join("lookup.json");
    let text = fs::read_to_string(&file).map_err(|error| format!("{}: {error}", file.display()))?;
    serde_json::from_str(&text).map_err(|error| format!("{}: {error}", file.display()))
}

/// `node.txt`, which the freeze script writes: each test file with the outcome of its Node
/// runs, `pass`, `fail`, `timeout`, or `flaky` when the runs differ.
fn read_node(path: &Path) -> Result<BTreeMap<String, String>, String> {
    let text = fs::read_to_string(path).map_err(|error| format!("{}: {error}", path.display()))?;
    Ok(text
        .lines()
        .filter(|line| !line.starts_with('#'))
        .filter_map(|line| {
            let (id, outcome) = line.rsplit_once(' ')?;
            Some((id.to_owned(), outcome.to_owned()))
        })
        .collect())
}

/// Runs one test file with `buoy` in its node form from the checkout, and classifies the
/// run: it passes when the runner exits with status 0.
fn execute(options: &Options, test: &Test, scratch: &Path) -> Execution {
    let directory = scratch.join(test.id.replace('/', "+"));
    let temporary = directory.join("tmp");
    let _ = fs::create_dir_all(&temporary);
    let result_file = directory.join("result.json");
    let mut command = Command::new(&options.buoy);
    buoy_env(&mut command, &temporary)
        .current_dir(options.checkouts.join(&test.package))
        .args(&test.run.argv)
        .env("BUOY_RESULT_FILE", &result_file);
    let started = Instant::now();
    let finished = crate::run(&mut command, options.deadline);
    let time_ms = started.elapsed().as_millis();
    let result = RunResult::read(&result_file);
    let _ = fs::remove_dir_all(&directory);
    let passed = finished.output.status.code() == Some(0);
    let outcome = classify(&Facts::of_run(result.as_ref(), finished.timed_out, passed));
    let tail = |bytes: &[u8]| {
        let lossy = String::from_utf8_lossy(bytes);
        let lines: Vec<&str> = lossy.lines().collect();
        lines[lines.len().saturating_sub(40)..].join("\n")
    };
    let report = format!(
        "--- {}: {outcome}, exit status {:?}, node exited 0\n--- stdout:\n{}\n--- stderr:\n{}\nrerun: (cd {} && buoy {})\n",
        test.id,
        finished.output.status.code(),
        tail(&finished.output.stdout),
        tail(&finished.output.stderr),
        options.checkouts.join(&test.package).display(),
        test.run.argv.join(" "),
    );
    Execution {
        outcome,
        blockers: result
            .map(|result| result.blockers(outcome))
            .unwrap_or_default(),
        report,
        time_ms,
    }
}

/// The summary: the outcome of each test file, the counts of each package, and the packages
/// with no test file, by the kind of their reason.
fn summarize(
    root: &Path,
    lookup: &Lookup,
    tests: &[Test],
    entries: &Expectations,
    executions: &[Execution],
) -> Result<Summary, String> {
    let mut groups: BTreeMap<String, BTreeMap<String, Counts>> = BTreeMap::new();
    for test in tests {
        if let Some(entry) = entries.get(&test.id) {
            groups
                .entry("package".to_owned())
                .or_default()
                .entry(test.package.clone())
                .or_default()
                .add(entry);
        }
    }
    let tested: BTreeSet<&String> = tests.iter().map(|test| &test.package).collect();
    for suite in &lookup.packages {
        if tested.contains(&suite.name) {
            continue;
        }
        let reason = suite
            .excluded
            .as_deref()
            .unwrap_or("Node passes no test file");
        let kind = reason.split(':').next().unwrap_or(reason);
        groups
            .entry("excluded package".to_owned())
            .or_default()
            .entry(kind.to_owned())
            .or_default()
            .add(&Entry::Same(Outcome::Skip));
    }
    let blocked: Vec<Vec<String>> = executions
        .iter()
        .filter(|execution| !execution.blockers.is_empty())
        .map(|execution| execution.blockers.clone())
        .collect();
    let path = root.join(DIRECTORY).join("summary.json");
    Ok(Summary {
        suite: "package-suites".to_owned(),
        version: node_version(root)?,
        updated: String::new(),
        total: entries.len(),
        outcomes: Counts::every(entries.values()),
        groups,
        blockers: summary::blockers(&blocked),
    }
    .updated_since(&path))
}

fn node_version(root: &Path) -> Result<String, String> {
    fs::read_to_string(root.join(".node-version"))
        .map(|text| format!("Node {}", text.trim()))
        .map_err(|error| format!(".node-version: {error}"))
}
