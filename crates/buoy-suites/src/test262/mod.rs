//! test262 (section 5.5 of docs/design/testing.md): the fetch at the commit of
//! `tests/test262/config.json`, the frontmatter, the modes, the compile outcomes, the
//! groups, and the blockers table. An execution that compiles runs through `buoy run`
//! until the batch runner of phase 8.

mod catalog;
mod compile;
mod execution;
mod frontmatter;

use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::Deserialize;

use self::catalog::{Harness, NIGHTLY_ONLY, Test, groups, load_tests};
use self::compile::Compilers;
pub use self::compile::serve as serve_compiles;
use self::execution::{Context, Record, record};
use crate::SKIP_REASONS;
pub use crate::comparison::Selection;
use crate::comparison::{self, Comparison, Origin};
use crate::expectations::{self, Entry, Expectations};
use crate::summary::{self, Counts, Destination, Results, Summary};

/// The command that rewrites the expectation file and the summary.
pub const UPDATE: &str =
    "cargo build --release -p buoy-cli && cargo run --release -p buoy-suites -- test262 --update";

#[derive(Debug)]
pub struct Options {
    /// `tests/test262`: `config.json`, `expectations.txt`, and `summary.json`.
    pub directory: PathBuf,
    /// A test262 checkout to use in place of the cache.
    pub checkout: Option<PathBuf>,
    /// `target/suites/test262`: the regenerated files and `results.json`.
    pub output: PathBuf,
    /// The `buoy` binary under test.
    pub buoy: PathBuf,
    /// The `buoy-suites` binary, whose `compile-worker` command compiles each test.
    pub compiler: PathBuf,
    pub selection: Selection,
    /// Runs only the ids that contain this text.
    pub filter: Option<String>,
    /// The expectation file of the base commit.
    pub base: Option<PathBuf>,
    /// Rewrites `expectations.txt` and `summary.json` in `directory`. An update runs every
    /// id, so it takes no filter and no selection.
    pub update: bool,
    pub jobs: usize,
}

/// What one run found.
#[derive(Debug)]
pub struct Report {
    pub commit: String,
    pub comparison: Comparison,
    /// The entry of each id that ran.
    pub run: Expectations,
    pub executions: usize,
    pub summary: Summary,
    pub durations_ms: BTreeMap<String, u128>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    commit: String,
    timeout_ms: u64,
    #[serde(default)]
    skip: Vec<Skip>,
}

/// One skip of section 3.5: the tests under `path`, with `feature`, or with `flag`.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Skip {
    path: Option<String>,
    feature: Option<String>,
    flag: Option<String>,
    reason: String,
}

impl Skip {
    fn applies(&self, test: &Test) -> bool {
        self.path
            .as_ref()
            .is_some_and(|path| test.id.starts_with(path.as_str()))
            || self
                .feature
                .as_ref()
                .is_some_and(|feature| test.features.contains(feature))
            || self
                .flag
                .as_ref()
                .is_some_and(|flag| test.frontmatter.has_flag(flag))
    }
}

/// Reads `config.json` of `directory`. Each skip names one selector and a reason code of
/// section 3.5.
fn load_config(directory: &Path) -> Result<Config, String> {
    let path = directory.join("config.json");
    let failed = |error: String| format!("{}: {error}", path.display());
    let text = fs::read_to_string(&path).map_err(|error| failed(error.to_string()))?;
    let config: Config = serde_json::from_str(&text).map_err(|error| failed(error.to_string()))?;
    for skip in &config.skip {
        let selectors = [&skip.path, &skip.feature, &skip.flag]
            .iter()
            .filter(|selector| selector.is_some())
            .count();
        if selectors != 1 {
            return Err(failed(format!(
                "the skip {skip:?} must name one of path, feature, and flag"
            )));
        }
        if !SKIP_REASONS.contains(&skip.reason.as_str()) {
            return Err(failed(format!(
                "the skip reason `{}` is not one of {SKIP_REASONS:?}",
                skip.reason
            )));
        }
    }
    Ok(config)
}

/// Runs test262 and compares the run with the expectation files.
pub fn run(options: &Options) -> Result<Report, String> {
    if options.update && (options.filter.is_some() || options.selection != Selection::All) {
        return Err("--update runs every id, so it takes no --filter and no --select".to_owned());
    }
    let config = load_config(&options.directory)?;
    let mut durations_ms = BTreeMap::new();
    let mut timed = |phase: &str, started: Instant| {
        durations_ms.insert(phase.to_owned(), started.elapsed().as_millis());
    };

    let started = Instant::now();
    let checkout = match &options.checkout {
        Some(checkout) => checkout.clone(),
        None => fetch(&config.commit)?,
    };
    timed("fetch", started);

    let started = Instant::now();
    let compilers = Compilers::new(
        options.compiler.clone(),
        Duration::from_millis(config.timeout_ms),
    );
    let harness = Harness::load(&checkout, &compilers)?;
    let tests = load_tests(&checkout, &harness, options.jobs)?;
    timed("load", started);

    let expected = expectations::read(&options.directory.join("expectations.txt"))?;
    let base = match &options.base {
        Some(path) if path.is_file() => Some(expectations::read(path)?),
        _ => None,
    };
    let selected: Vec<&Test> = tests
        .iter()
        .filter(|test| is_selected(test, options, expected.get(&test.id)))
        .collect();

    let started = Instant::now();
    let context = Context::new(checkout, compilers, harness, options, &config);
    let records = crate::parallel(&selected, options.jobs, |test| {
        record(test, &config, &context)
    });
    let _ = fs::remove_dir_all(&context.scratch);
    timed("execute", started);

    let run: Expectations = selected
        .iter()
        .zip(&records)
        .map(|(test, record)| (test.id.clone(), record.entry.clone()))
        .collect();
    let ids: BTreeSet<String> = tests.iter().map(|test| test.id.clone()).collect();
    let comparison = comparison::compare(Origin::Upstream, &run, &ids, &expected, base.as_ref());
    let mut entries: Expectations = expected
        .into_iter()
        .filter(|(id, _)| ids.contains(id))
        .collect();
    entries.extend(run.clone());
    let summary = summarize(&config.commit, &tests, &entries, &records)
        .updated_since(&options.directory.join("summary.json"));
    let comment = comparison.comment(&summary.comment_heading(base.as_ref(), run.len()), 50);
    let results = Results {
        date: crate::date(),
        host: format!("{}-{}", env::consts::OS, env::consts::ARCH),
        tools: crate::tools(&options.buoy, ("test262", &config.commit)),
        durations_ms: durations_ms.clone(),
        tests: selected
            .iter()
            .zip(records)
            .map(|(test, record)| (test.id.clone(), record.into_result()))
            .collect(),
    };
    let header = [
        "Generated by `buoy-suites test262 --update`. Do not edit. Change config.json instead."
            .to_owned(),
        format!("test262 {}", config.commit),
    ];
    Destination {
        directory: &options.directory,
        output: &options.output,
        every_id: options.selection == Selection::All && options.filter.is_none(),
        update: options.update,
    }
    .write(&header, &entries, &summary, &results, &comment)?;
    Ok(Report {
        commit: config.commit,
        comparison,
        run,
        executions: selected.iter().map(|test| test.modes.len()).sum(),
        summary,
        durations_ms,
    })
}

fn summarize(commit: &str, tests: &[Test], entries: &Expectations, records: &[Record]) -> Summary {
    let blocked: Vec<Vec<String>> = records
        .iter()
        .filter(|record| !record.blockers.is_empty())
        .map(|record| record.blockers.clone())
        .collect();
    Summary {
        suite: "test262".to_owned(),
        version: commit.to_owned(),
        updated: String::new(),
        total: tests.len(),
        outcomes: Counts::every(entries.values()),
        groups: groups(tests, entries),
        blockers: summary::blockers(&blocked),
    }
}

fn is_selected(test: &Test, options: &Options, expected: Option<&Entry>) -> bool {
    if options
        .filter
        .as_ref()
        .is_some_and(|filter| !test.id.contains(filter.as_str()))
    {
        return false;
    }
    match options.selection {
        Selection::All => true,
        Selection::PullRequest => {
            !NIGHTLY_ONLY
                .iter()
                .any(|prefix| test.id.starts_with(prefix))
                && options.selection.includes(&test.id, expected)
        }
    }
}

/// The test262 checkout at `commit`, in `$XDG_CACHE_HOME/buoy/test262-<commit>`.
fn fetch(commit: &str) -> Result<PathBuf, String> {
    let (checkout, head) = crate::cached_checkout(
        &format!("test262-{commit}"),
        "https://github.com/tc39/test262.git",
        commit,
        &[],
    )?;
    if head == commit {
        return Ok(checkout);
    }
    Err(format!(
        "{}: the checkout is at {head}, not {commit}",
        checkout.display()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_committed_config_names_a_reason_for_each_skip() {
        let config = load_config(&crate::repository().join("tests/test262")).expect("loads");
        assert_eq!(config.commit.len(), 40, "the commit is a full SHA");
    }
}
