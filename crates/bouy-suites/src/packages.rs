//! The ecosystem tier of section 5.8 of docs/design/testing.md: the resolution cases of
//! `tests/npm`, the package programs of `tests/packages`, and the AI-stack scenarios of
//! `tests/equivalence/<area>`. `scripts/freeze-expectations.sh` recorded the stdout and the
//! exit status of each program with Node, and the expectation file of each corpus holds the
//! outcome of each program on Bouy. These are Bouy corpora (section 3.3), so a move from a
//! loud outcome to a silent one is a regression. `tests/packages/summary.json` feeds the
//! Packages section of the dashboard.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use crate::comparison::{self, Comparison, Origin};
use crate::expectations::{self, Entry, Expectations};
use crate::outcome::Outcome;
use crate::summary::{self, Counts, Results, Summary, TestResult};
use crate::{bouy_env, fake_server};

/// The command that rewrites the expectation files and the summary.
pub const UPDATE: &str =
    "cargo build --release -p bouy-cli && cargo run --release -p bouy-suites -- packages --update";

/// The areas of `tests/equivalence` whose every program passes, so they have no expectation
/// file: `equivalence.rs` and `ai.rs` check them.
const PASSING_AREAS: [&str; 2] = ["ai", "effect"];

/// The file names of the programs of a directory of `tests/npm` or `tests/packages`, apart
/// from the `main-<variant>.mjs` programs.
const TREE_PROGRAMS: [&str; 4] = ["main.mjs", "main.cjs", "exports.mjs", "exports.cjs"];

/// The lines of each list of the report.
const REPORT_LINES: usize = 50;
/// The failure reports of programs that the report prints in full.
const REPORTED_RUNS: usize = 10;

#[derive(Debug)]
pub struct Options {
    /// The repository root.
    pub root: PathBuf,
    /// Where the run writes `results.json` and the regenerated files.
    pub output: PathBuf,
    /// The `bouy` binary under test.
    pub bouy: PathBuf,
    /// Runs only the programs whose path under the root contains this text.
    pub filter: Option<String>,
    /// Rewrites each expectation file and `tests/packages/summary.json`. An update runs every
    /// program, so it takes no filter.
    pub update: bool,
    pub jobs: usize,
    /// The deadline of one run.
    pub deadline: Duration,
}

/// How a corpus names its programs and their recorded output.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Layout {
    /// A directory for each case or package, which `main.mjs`, `main.cjs`,
    /// `main-<variant>.mjs`, `exports.mjs`, and `exports.cjs` outside `node_modules` run.
    /// The output of a program is `<program>.stdout`.
    Tree,
    /// The `.ts` programs of the directory, apart from the `-fixture.ts` files that a program
    /// starts. The output of `<name>.ts` is `<name>.stdout`, and the programs reach the fake
    /// model server.
    Scenarios,
}

#[derive(Debug, Clone)]
struct Corpus {
    /// The directory under the root, such as `tests/npm`.
    directory: String,
    layout: Layout,
}

/// What one run of the tier found.
#[derive(Debug)]
pub struct Report {
    pub corpora: Vec<CorpusRun>,
    /// The summary of `tests/packages`, after a run of every program.
    pub summary: Option<Summary>,
}

/// The run of one corpus.
#[derive(Debug)]
pub struct CorpusRun {
    pub directory: String,
    pub programs: usize,
    /// The entry of each program that ran.
    pub run: Expectations,
    pub comparison: Comparison,
    /// The failure reports of the programs whose outcome differs from their line.
    reports: Vec<String>,
}

/// The facts of one program run.
#[derive(Debug)]
struct Execution {
    outcome: Outcome,
    blockers: Vec<String>,
    report: String,
    time_ms: u128,
}

impl Report {
    /// Whether CI fails: a regression or a stale line in any corpus.
    #[must_use]
    pub fn fails(&self) -> bool {
        self.corpora
            .iter()
            .any(|corpus| corpus.comparison.fails(false))
    }

    /// The report: for each corpus, the programs that ran, the findings of section 3.3, and
    /// the first failure reports.
    #[must_use]
    pub fn text(&self) -> String {
        let mut text = String::new();
        for corpus in &self.corpora {
            let _ = writeln!(
                text,
                "{}: {} of {} programs ran",
                corpus.directory,
                corpus.run.len(),
                corpus.programs
            );
            text.push_str(&corpus.comparison.report(UPDATE, REPORT_LINES));
            for report in corpus.reports.iter().take(REPORTED_RUNS) {
                text.push_str(report);
            }
        }
        if let Some(summary) = &self.summary {
            let outcomes: Vec<String> = Outcome::ALL
                .iter()
                .map(|outcome| format!("{outcome} {}", summary.outcomes.get(*outcome)))
                .collect();
            let _ = writeln!(text, "tests/packages: {}", outcomes.join(", "));
        }
        text
    }
}

/// Runs the programs of each corpus and compares the run with the expectation files.
///
/// # Errors
///
/// When a program has no recorded output, an output has no program, a file cannot be read
/// or written, or the fake server cannot start.
pub fn run(options: &Options) -> Result<Report, String> {
    if options.update && options.filter.is_some() {
        return Err("--update runs every program, so it takes no --filter".to_owned());
    }
    let started = Instant::now();
    let scratch = options.output.join("scratch");
    let mut report = Report {
        corpora: Vec::new(),
        summary: None,
    };
    let mut results = BTreeMap::new();
    for corpus in corpora_of(&options.root)? {
        let ran = run_corpus(options, &corpus, &scratch)?;
        report.corpora.push(ran.corpus);
        report.summary = report.summary.or(ran.summary);
        results.extend(ran.results);
    }
    let _ = fs::remove_dir_all(&scratch);
    if let Some(summary) = &report.summary {
        let text = crate::json(summary)?;
        crate::write(&options.output.join("summary.json"), &text)?;
        if options.update {
            crate::write(&options.root.join("tests/packages/summary.json"), &text)?;
        }
    }
    let results = Results {
        date: crate::date(),
        host: format!("{}-{}", std::env::consts::OS, std::env::consts::ARCH),
        tools: crate::tools(
            &options.bouy,
            ("oracle", &format!("Node {}", node_version(&options.root)?)),
        ),
        durations_ms: BTreeMap::from([("run".to_owned(), started.elapsed().as_millis())]),
        tests: results,
    };
    crate::write(
        &options.output.join("results.json"),
        &crate::json(&results)?,
    )?;
    Ok(report)
}

/// What the run of one corpus gives: its findings, the summary of `tests/packages` after a
/// run of every program, and the result of each program for `results.json`.
struct Ran {
    corpus: CorpusRun,
    summary: Option<Summary>,
    results: Vec<(String, TestResult)>,
}

/// Runs the selected programs of one corpus, compares the run with its expectation file, and
/// writes the regenerated file to the output, and to the corpus for an update.
fn run_corpus(options: &Options, corpus: &Corpus, scratch: &Path) -> Result<Ran, String> {
    let programs = programs(&options.root, corpus)?;
    let selected: Vec<&String> = programs
        .iter()
        .filter(|id| {
            options
                .filter
                .as_ref()
                .is_none_or(|filter| format!("{}/{id}", corpus.directory).contains(filter.as_str()))
        })
        .collect();
    let executions = crate::parallel(&selected, options.jobs, |id| {
        execute(options, corpus, id, scratch)
    })
    .into_iter()
    .collect::<Result<Vec<_>, String>>()?;
    let path = options
        .root
        .join(&corpus.directory)
        .join("expectations.txt");
    let expected = expectations::read(&path)?;
    let run: Expectations = selected
        .iter()
        .zip(&executions)
        .map(|(id, execution)| ((*id).clone(), Entry::Same(execution.outcome)))
        .collect();
    let comparison = comparison::compare(Origin::Corpus, &run, &programs, &expected, None);
    let mut entries: Expectations = expected
        .iter()
        .filter(|(id, _)| programs.contains(*id))
        .map(|(id, entry)| (id.clone(), entry.clone()))
        .collect();
    entries.extend(run.clone());
    let header = [format!(
        "Generated by `bouy-suites packages --update`. Do not edit. {} programs of {}.",
        programs.len(),
        corpus.directory
    )];
    let file = expectations::write(&header, &entries);
    crate::write(
        &options
            .output
            .join(&corpus.directory)
            .join("expectations.txt"),
        &file,
    )?;
    if options.update {
        crate::write(&path, &file)?;
    }
    let summary = if corpus.directory == "tests/packages" && options.filter.is_none() {
        Some(summarize(&options.root, &programs, &entries, &executions)?)
    } else {
        None
    };
    // An update records each outcome, so it reports no program.
    let reports = selected
        .iter()
        .zip(&executions)
        .filter(|(id, execution)| {
            !options.update && expected.get(**id) != Some(&Entry::Same(execution.outcome))
        })
        .map(|(_, execution)| execution.report.clone())
        .collect();
    let results = selected
        .iter()
        .zip(executions)
        .map(|(id, execution)| {
            let result = TestResult {
                outcome: execution.outcome.to_string(),
                time_ms: BTreeMap::from([("run".to_owned(), execution.time_ms)]),
                detail: summary::detail(&execution.report),
            };
            (format!("{}/{id}", corpus.directory), result)
        })
        .collect();
    Ok(Ran {
        corpus: CorpusRun {
            directory: corpus.directory.clone(),
            programs: programs.len(),
            run,
            comparison,
            reports,
        },
        summary,
        results,
    })
}

/// The corpora of the tier: `tests/npm`, `tests/packages`, and each area of
/// `tests/equivalence` apart from `PASSING_AREAS`.
fn corpora_of(root: &Path) -> Result<Vec<Corpus>, String> {
    let mut corpora = vec![
        Corpus {
            directory: "tests/npm".to_owned(),
            layout: Layout::Tree,
        },
        Corpus {
            directory: "tests/packages".to_owned(),
            layout: Layout::Tree,
        },
    ];
    corpora.extend(scenario_areas(root)?.into_iter().map(|area| Corpus {
        directory: format!("tests/equivalence/{area}"),
        layout: Layout::Scenarios,
    }));
    Ok(corpora)
}

/// The areas of `tests/equivalence` apart from `PASSING_AREAS`, sorted by name. Each one has
/// an expectation file.
///
/// # Errors
///
/// When `tests/equivalence` cannot be read.
pub fn scenario_areas(root: &Path) -> Result<Vec<String>, String> {
    let mut areas: Vec<String> = fs::read_dir(root.join("tests/equivalence"))
        .map_err(|error| format!("tests/equivalence: {error}"))?
        .filter_map(Result::ok)
        .filter(|entry| entry.path().is_dir())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|area| !PASSING_AREAS.contains(&area.as_str()))
        .collect();
    areas.sort();
    Ok(areas)
}

/// The ids of the programs of a corpus: their paths under its directory, with `/`. Each
/// program must have its recorded stdout, and each recorded output its program.
fn programs(root: &Path, corpus: &Corpus) -> Result<BTreeSet<String>, String> {
    let directory = root.join(&corpus.directory);
    let files = match corpus.layout {
        Layout::Tree => files_below(&directory, "")?,
        Layout::Scenarios => fs::read_dir(&directory)
            .map_err(|error| format!("{}: {error}", corpus.directory))?
            .filter_map(Result::ok)
            .filter(|entry| entry.path().is_file())
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect(),
    };
    let programs: BTreeSet<String> = files
        .iter()
        .filter(|file| is_program(corpus.layout, file))
        .cloned()
        .collect();
    let missing: Vec<&String> = programs
        .iter()
        .filter(|id| !recorded(&directory, corpus.layout, id).is_file())
        .collect();
    if !missing.is_empty() {
        return Err(format!(
            "run scripts/freeze-expectations.sh {}; these programs have no recorded stdout: {missing:?}",
            corpus.directory
        ));
    }
    let orphans: Vec<&String> = files
        .iter()
        .filter(|file| {
            let Some(stem) = file
                .strip_suffix(".stdout")
                .or_else(|| file.strip_suffix(".status"))
            else {
                return false;
            };
            match corpus.layout {
                Layout::Tree => !programs.contains(stem),
                Layout::Scenarios => !programs.contains(&format!("{stem}.ts")),
            }
        })
        .collect();
    if !orphans.is_empty() {
        return Err(format!(
            "{}: these recorded outputs have no program: {orphans:?}",
            corpus.directory
        ));
    }
    Ok(programs)
}

fn is_program(layout: Layout, file: &str) -> bool {
    let name = file.rsplit('/').next().unwrap_or(file);
    match layout {
        Layout::Tree => {
            TREE_PROGRAMS.contains(&name)
                || (name.starts_with("main-")
                    && Path::new(name)
                        .extension()
                        .is_some_and(|found| found == "mjs"))
        }
        Layout::Scenarios => {
            Path::new(name)
                .extension()
                .is_some_and(|found| found == "ts")
                && !name.ends_with("-fixture.ts")
        }
    }
}

/// The recorded stdout of the program `id`.
fn recorded(directory: &Path, layout: Layout, id: &str) -> PathBuf {
    match layout {
        Layout::Tree => directory.join(format!("{id}.stdout")),
        Layout::Scenarios => directory.join(id).with_extension("stdout"),
    }
}

/// The files under `directory/relative` outside `node_modules` and build directories, as
/// paths relative to `directory` with `/`.
fn files_below(directory: &Path, relative: &str) -> Result<Vec<String>, String> {
    let path = directory.join(relative);
    let mut found = Vec::new();
    for entry in fs::read_dir(&path)
        .map_err(|error| format!("{}: {error}", path.display()))?
        .filter_map(Result::ok)
    {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name == "node_modules" || name == ".bouy" {
            continue;
        }
        let child = if relative.is_empty() {
            name
        } else {
            format!("{relative}/{name}")
        };
        if entry.path().is_dir() {
            found.extend(files_below(directory, &child)?);
        } else {
            found.push(child);
        }
    }
    Ok(found)
}

/// Runs one program with `bouy run` from the root, as the freeze script runs it with Node,
/// and classifies the run against the recorded output.
fn execute(
    options: &Options,
    corpus: &Corpus,
    id: &str,
    scratch: &Path,
) -> Result<Execution, String> {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let directory = scratch.join(NEXT.fetch_add(1, Ordering::Relaxed).to_string());
    let temporary = directory.join("tmp");
    fs::create_dir_all(&temporary).map_err(|error| format!("{}: {error}", temporary.display()))?;
    let program = format!("{}/{id}", corpus.directory);
    let mut command = Command::new(&options.bouy);
    bouy_env(&mut command, &temporary)
        .current_dir(&options.root)
        .arg("run")
        .arg(&program);
    if corpus.layout == Layout::Scenarios {
        fake_server::point(&mut command)?;
    }
    let checked = crate::check_recorded(
        &mut command,
        &program,
        &recorded(&options.root.join(&corpus.directory), corpus.layout, id),
        &directory.join("result.json"),
        options.deadline,
    );
    let _ = fs::remove_dir_all(&directory);
    let checked = checked?;
    Ok(Execution {
        outcome: checked.outcome,
        blockers: checked
            .result
            .map(|result| result.blockers(checked.outcome))
            .unwrap_or_default(),
        report: checked.report,
        time_ms: checked.time_ms,
    })
}

/// The summary of `tests/packages`: the counts of each outcome, by program file (`kind`) and
/// for each program (`program`), which the Packages section of the dashboard shows as one
/// row per package, and the blockers.
fn summarize(
    root: &Path,
    programs: &BTreeSet<String>,
    entries: &Expectations,
    executions: &[Execution],
) -> Result<Summary, String> {
    let mut groups: BTreeMap<String, BTreeMap<String, Counts>> = BTreeMap::new();
    for (id, entry) in entries {
        let kind = id.rsplit_once('/').map_or(id.as_str(), |(_, file)| file);
        for (group, name) in [("kind", kind), ("program", id)] {
            groups
                .entry(group.to_owned())
                .or_default()
                .entry(name.to_owned())
                .or_default()
                .add(entry);
        }
    }
    let blocked: Vec<Vec<String>> = executions
        .iter()
        .filter(|execution| !execution.blockers.is_empty())
        .map(|execution| execution.blockers.clone())
        .collect();
    let path = root.join("tests/packages/summary.json");
    Ok(Summary {
        suite: "packages".to_owned(),
        version: format!("Node {}", node_version(root)?),
        updated: String::new(),
        total: programs.len(),
        outcomes: Counts::every(entries.values()),
        groups,
        blockers: summary::blockers(&blocked),
    }
    .updated_since(&path))
}

fn node_version(root: &Path) -> Result<String, String> {
    fs::read_to_string(root.join(".node-version"))
        .map(|text| text.trim().to_owned())
        .map_err(|error| format!(".node-version: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn programs_follow_the_names_of_the_freeze_script() {
        for file in [
            "x@1/main.mjs",
            "@a/b@2/exports.cjs",
            "c/main-jitless.mjs",
            "main.cjs",
        ] {
            assert!(is_program(Layout::Tree, file), "{file}");
        }
        for file in [
            "x@1/lib/index.mjs",
            "x@1/main.ts",
            "x@1/main.mjs.stdout",
            "x@1/package.json",
        ] {
            assert!(!is_program(Layout::Tree, file), "{file}");
        }
        assert!(is_program(Layout::Scenarios, "text.ts"));
        assert!(!is_program(Layout::Scenarios, "stdio-server-fixture.ts"));
        assert!(!is_program(Layout::Scenarios, "text.stdout"));
    }
}
