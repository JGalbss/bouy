//! `bouy-fuzz`: the differential fuzz campaign of section 5.10 of docs/design/testing.md.
//! It generates seeded programs, runs each on Node and on Bouy, and minimizes each silent
//! mismatch and each crash. It writes one case for each shape of a minimized program to
//! `tests/fuzz/<generator>/<seed>.ts`, with the Node output next to it and a line in
//! `tests/fuzz/expectations.txt`. `crates/bouy-cli/tests/fuzz.rs` replays the cases. The
//! campaign is a freeze step, and one of the three places that run node.

mod campaign;
mod generators;
mod minimize;
mod program;

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::{self, ExitCode};
use std::time::Duration;
use std::{env, fs};

use bouy_suites::expectations::{self, Entry};
use clap::{Parser, Subcommand};

use campaign::{Hunt, Printed, Tools, Trial, Verdict};
use generators::Generator;
use program::{Program, shape};

/// The deadline of one run, on Node or on Bouy.
const DEADLINE: Duration = Duration::from_secs(10);

const HEADER: [&str; 3] = [
    "Written by `bouy-fuzz campaign`: one line for each case in tests/fuzz/<generator>/.",
    "crates/bouy-cli/tests/fuzz.rs fails when a case gives another outcome, and writes the",
    "lines of its run to target/suites/fuzz/expectations.txt. docs/design/testing.md 5.10.",
];

#[derive(Debug, Parser)]
#[command(
    name = "bouy-fuzz",
    about = "Compare Bouy with Node on generated programs"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Run the seeds on Node and on Bouy, and write a case for each new mismatch.
    Campaign {
        /// The generators to run. Defaults to every generator.
        #[arg(long, value_enum)]
        generator: Vec<Generator>,
        /// The first seed.
        #[arg(long, default_value_t = 0)]
        from: u64,
        /// The seeds of each generator.
        #[arg(long, default_value_t = 64)]
        count: u64,
        /// The `bouy` binary under test. Defaults to the `bouy` next to this binary.
        #[arg(long, env = "BOUY_BIN")]
        bouy: Option<PathBuf>,
        /// The node of the oracle. It must be the release in `.node-version`.
        #[arg(long, default_value = "node")]
        node: PathBuf,
        /// The seeds that run at the same time. Defaults to the number of cores, at most 8.
        #[arg(long)]
        jobs: Option<usize>,
    },
    /// Print the program that a generator writes for a seed, before minimization.
    Print {
        #[arg(value_enum)]
        generator: Generator,
        seed: u64,
    },
}

fn main() -> ExitCode {
    match Cli::parse().command {
        Commands::Print { generator, seed } => {
            print!("{}", generator.program(seed).source());
            ExitCode::SUCCESS
        }
        Commands::Campaign {
            generator,
            from,
            count,
            bouy,
            node,
            jobs,
        } => match run_campaign(&generator, from..from + count, bouy, &node, jobs) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("bouy-fuzz: {error}");
                ExitCode::from(2)
            }
        },
    }
}

fn run_campaign(
    generators: &[Generator],
    seeds: std::ops::Range<u64>,
    bouy: Option<PathBuf>,
    node: &Path,
    jobs: Option<usize>,
) -> Result<(), String> {
    let repository = bouy_suites::repository();
    let tools = Tools {
        node: pinned_node(node, &repository)?,
        bouy: bouy_binary(bouy)?,
        deadline: DEADLINE,
    };
    let generators = if generators.is_empty() {
        Generator::ALL.to_vec()
    } else {
        generators.to_vec()
    };
    let corpus = repository.join("tests/fuzz");
    let work: Vec<(Generator, u64)> = generators
        .iter()
        .flat_map(|generator| seeds.clone().map(move |seed| (*generator, seed)))
        .filter(|(generator, seed)| !case(&corpus, *generator, *seed).is_file())
        .collect();
    let scratch = env::temp_dir().join(format!("bouy-fuzz-{}", process::id()));
    let jobs = jobs.unwrap_or_else(bouy_suites::default_jobs);
    println!(
        "bouy-fuzz: {} seeds, {jobs} at a time, node {}, bouy {}",
        work.len(),
        tools.node.display(),
        tools.bouy.display()
    );
    let hunts = bouy_suites::parallel(&work, jobs, |(generator, seed)| {
        let directory = scratch.join(format!("{}-{seed}", generator.name()));
        let _ = fs::create_dir_all(&directory);
        let hunt = tools.hunt(*generator, *seed, &directory);
        let _ = fs::remove_dir_all(&directory);
        hunt
    });
    let written = write_cases(&tools, &corpus, &scratch, &hunts)?;
    let _ = fs::remove_dir_all(&scratch);
    print!("{}", report(&hunts, &written));
    Ok(())
}

/// The node at `node` on `PATH`, when it is the release that `.node-version` pins.
fn pinned_node(node: &Path, repository: &Path) -> Result<PathBuf, String> {
    let found = env::var_os("PATH")
        .into_iter()
        .flat_map(|path| env::split_paths(&path).collect::<Vec<_>>())
        .map(|directory| directory.join(node))
        .find(|candidate| candidate.is_file())
        .unwrap_or_else(|| node.to_path_buf());
    let pinned = fs::read_to_string(repository.join(".node-version"))
        .map_err(|error| format!(".node-version: {error}"))?;
    let version = process::Command::new(&found)
        .arg("--version")
        .output()
        .map_err(|error| format!("cannot run {}: {error}", found.display()))?;
    let version = String::from_utf8_lossy(&version.stdout);
    if version.trim() != format!("v{}", pinned.trim()) {
        return Err(format!(
            "node is {}, and .node-version pins v{}; run the pinned release",
            version.trim(),
            pinned.trim()
        ));
    }
    Ok(found)
}

fn bouy_binary(bouy: Option<PathBuf>) -> Result<PathBuf, String> {
    let bouy = match bouy {
        Some(bouy) => bouy,
        None => env::current_exe()
            .map_err(|error| format!("cannot find this binary: {error}"))?
            .with_file_name("bouy"),
    };
    if bouy.is_file() {
        return Ok(bouy);
    }
    Err(format!(
        "{} is not a file; build it with `cargo build --release -p bouy-cli`, or set BOUY_BIN",
        bouy.display()
    ))
}

fn case(corpus: &Path, generator: Generator, seed: u64) -> PathBuf {
    corpus.join(generator.name()).join(format!("{seed}.ts"))
}

/// A case that the campaign wrote, and the seeds whose minimized program had its shape.
#[derive(Debug)]
struct Written {
    id: String,
    source: String,
    trial: Trial,
    seeds: usize,
}

/// Writes one case for each shape of a minimized program that no recorded case has: the
/// program, the output of two Node runs that agree, and its expectation line. A program
/// that no longer mismatches at its place in the corpus is left out.
fn write_cases(
    tools: &Tools,
    corpus: &Path,
    scratch: &Path,
    hunts: &[Hunt],
) -> Result<Vec<Written>, String> {
    let mut shapes: BTreeMap<(Generator, String), Option<usize>> = BTreeMap::new();
    for generator in Generator::ALL {
        for recorded in fs::read_dir(corpus.join(generator.name()))
            .into_iter()
            .flatten()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|found| found == "ts"))
        {
            let source = fs::read_to_string(&recorded).unwrap_or_default();
            shapes.insert((generator, shape(&source)), None);
        }
    }
    let lines_file = corpus.join("expectations.txt");
    let mut lines = match fs::read_to_string(&lines_file) {
        Ok(text) => expectations::parse(&text)?,
        Err(_) => expectations::Expectations::new(),
    };
    let mut written: Vec<Written> = Vec::new();
    for hunt in hunts {
        let Verdict::Found { program, .. } = &hunt.verdict else {
            continue;
        };
        let source = program.source();
        if let Some(known) = shapes.get(&(hunt.generator, shape(&source))) {
            if let Some(index) = known {
                written[*index].seeds += 1;
            }
            continue;
        }
        let Some(trial) = record(tools, corpus, scratch, hunt, program)? else {
            continue;
        };
        shapes.insert((hunt.generator, shape(&source)), Some(written.len()));
        let id = format!("{}/{}.ts", hunt.generator.name(), hunt.seed);
        lines.insert(id.clone(), Entry::Same(trial.outcome));
        written.push(Written {
            id,
            source,
            trial,
            seeds: 1,
        });
    }
    if !written.is_empty() {
        let header: Vec<String> = HEADER.iter().map(|line| (*line).to_owned()).collect();
        fs::write(&lines_file, expectations::write(&header, &lines))
            .map_err(|error| format!("{}: {error}", lines_file.display()))?;
    }
    Ok(written)
}

/// Writes the case of `hunt` and its Node output, and returns the trial at its place in
/// the corpus, or `None` when two Node runs differ or the case no longer mismatches.
fn record(
    tools: &Tools,
    corpus: &Path,
    scratch: &Path,
    hunt: &Hunt,
    program: &Program,
) -> Result<Option<Trial>, String> {
    let path = case(corpus, hunt.generator, hunt.seed);
    let failed = |error: std::io::Error| format!("{}: {error}", path.display());
    fs::create_dir_all(corpus.join(hunt.generator.name())).map_err(failed)?;
    fs::create_dir_all(scratch).map_err(failed)?;
    fs::write(&path, program.source()).map_err(failed)?;
    let first = tools.node(&path, scratch);
    let trial = tools
        .trial(&path, scratch)
        .filter(|trial| Some(&trial.node) == first.as_ref() && trial.outcome.rank() >= 2);
    let Some(trial) = trial else {
        let _ = fs::remove_file(&path);
        eprintln!(
            "bouy-fuzz: {} left out: two node runs differ, or it no longer mismatches in place",
            path.display()
        );
        return Ok(None);
    };
    fs::write(path.with_extension("stdout"), &trial.node.stdout).map_err(failed)?;
    if let Some(status) = trial.node.status.filter(|status| *status != 0) {
        fs::write(path.with_extension("status"), format!("{status}\n")).map_err(failed)?;
    }
    Ok(Some(trial))
}

/// The report: the outcome counts and coverage gaps of each generator, then each new case
/// with the first line where Bouy and Node differ.
fn report(hunts: &[Hunt], written: &[Written]) -> String {
    let mut report = String::new();
    for generator in Generator::ALL {
        let mine: Vec<&Hunt> = hunts
            .iter()
            .filter(|hunt| hunt.generator == generator)
            .collect();
        if mine.is_empty() {
            continue;
        }
        let mut outcomes: BTreeMap<String, usize> = BTreeMap::new();
        let mut gaps: BTreeMap<String, usize> = BTreeMap::new();
        for hunt in &mine {
            let outcome = match &hunt.verdict {
                Verdict::NoOracle => "no oracle".to_owned(),
                Verdict::Clean(outcome) => outcome.to_string(),
                Verdict::Found { trial, .. } => trial.outcome.to_string(),
            };
            *outcomes.entry(outcome).or_insert(0) += 1;
            for gap in &hunt.gaps {
                *gaps.entry(gap.clone()).or_insert(0) += 1;
            }
        }
        let counts = |counts: BTreeMap<String, usize>| -> String {
            counts
                .iter()
                .map(|(name, count)| format!("{name} {count}"))
                .collect::<Vec<_>>()
                .join(", ")
        };
        let _ = writeln!(
            report,
            "{}: {} seeds: {}\n  diagnostics of the dropped statements, by code: {}",
            generator.name(),
            mine.len(),
            counts(outcomes),
            counts(gaps)
        );
    }
    let _ = writeln!(report, "{} new cases in tests/fuzz:", written.len());
    for case in written {
        let _ = write!(
            report,
            "  {} {}, {} seeds: {}",
            case.id, case.trial.outcome, case.seeds, case.source
        );
        report.push_str(&first_difference(&case.trial.node, &case.trial.bouy));
    }
    let known = hunts
        .iter()
        .filter(|hunt| matches!(hunt.verdict, Verdict::Found { .. }))
        .count()
        - written.iter().map(|case| case.seeds).sum::<usize>();
    let _ = writeln!(
        report,
        "{known} findings had the shape of a recorded case, or did not reproduce in place."
    );
    report
}

fn first_difference(node: &Printed, bouy: &Printed) -> String {
    let (expected, actual): (Vec<&str>, Vec<&str>) =
        (node.stdout.lines().collect(), bouy.stdout.lines().collect());
    let line = (0..expected.len().max(actual.len()))
        .find(|index| expected.get(*index) != actual.get(*index));
    let shown = |lines: &[&str]| {
        line.and_then(|index| lines.get(index).copied())
            .unwrap_or("(no line)")
            .to_owned()
    };
    format!(
        "    node: {} (status {:?})\n    bouy: {} (status {:?})\n",
        shown(&expected),
        node.status,
        shown(&actual),
        bouy.status
    )
}
