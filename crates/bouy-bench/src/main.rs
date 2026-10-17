//! `bouy-bench`: runs each suite in `bench/programs/` as a Bouy program and as an
//! equivalent plain Node program, records every run in `bench/results/`, and prints a
//! Markdown table of the medians and ranges. `bouy-bench compare` checks nightly runs
//! against the limits of `bench/thresholds.json`.

mod compare;
mod environment;
mod measure;
mod results;
mod summary;

use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};

use crate::results::{Outcome, Program, Results, Run, Suite};

#[derive(Debug, Parser)]
#[command(
    name = "bouy-bench",
    about = "Run each Bouy benchmark next to an equivalent plain Node program",
    args_conflicts_with_subcommands = true
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
    /// The suites to run, by directory name in `<bench>/programs/`. All suites by default.
    suites: Vec<String>,
    /// The measured runs of each program, after one warm-up run.
    #[arg(long, default_value_t = 5)]
    runs: usize,
    /// The `bouy` CLI to measure.
    #[arg(long, env = "BOUY_BENCH_BOUY", default_value = "bouy")]
    bouy: PathBuf,
    /// The `node` that runs the baseline programs.
    #[arg(long, env = "BOUY_BENCH_NODE", default_value = "node")]
    node: PathBuf,
    /// The directory that holds `programs/`.
    #[arg(long, default_value = concat!(env!("CARGO_MANIFEST_DIR"), "/../../bench"))]
    bench: PathBuf,
    /// The directory for the results file. Defaults to `<bench>/results`.
    #[arg(long)]
    out: Option<PathBuf>,
    /// The host name in the results file name. Defaults to the CPU model.
    #[arg(long)]
    host: Option<String>,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Compare the Bouy medians of nightly runs with the limits. Fails when a metric is
    /// past its limit in the previous and the current run.
    Compare(Compare),
}

#[derive(Debug, Args)]
struct Compare {
    /// The results files of one host in time order: the baseline, the previous run when
    /// it exists, and the current run.
    #[arg(num_args = 2..=3, required = true)]
    files: Vec<PathBuf>,
    /// The limits file.
    #[arg(long, default_value = concat!(env!("CARGO_MANIFEST_DIR"), "/../../bench/thresholds.json"))]
    limits: PathBuf,
}

fn main() -> ExitCode {
    if let Some(code) = measure::child() {
        return code;
    }
    let cli = Cli::parse();
    let (outcome, failure) = match &cli.command {
        Some(Command::Compare(compare)) => (
            compare_runs(compare),
            "a metric is past its limit in two runs in a row",
        ),
        None => (
            bench(&cli),
            "some runs failed; the results file holds their errors",
        ),
    };
    match outcome {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => {
            eprintln!("bouy-bench: {failure}");
            ExitCode::FAILURE
        }
        Err(error) => {
            eprintln!("bouy-bench: {error}");
            ExitCode::FAILURE
        }
    }
}

/// Prints the comparison. Returns whether no metric is past its limit twice.
fn compare_runs(cli: &Compare) -> Result<bool, String> {
    let limits = compare::load_limits(&cli.limits)?;
    let results = cli
        .files
        .iter()
        .map(|file| compare::load_results(file))
        .collect::<Result<Vec<_>, String>>()?;
    let rows = compare::rows(&limits, &results)?;
    println!("{}", compare::report(&results, &rows));
    Ok(rows
        .iter()
        .all(|row| row.verdict != compare::Verdict::PastTwice))
}

/// Runs the suites, writes the results file, and prints the table. Returns whether
/// every run succeeded.
fn bench(cli: &Cli) -> Result<bool, String> {
    let directories = suites(&cli.bench.join("programs"), &cli.suites)?;
    let mut results = Results {
        date: environment::today(),
        host: environment::host(cli.host.clone()),
        tools: environment::tools(&cli.bouy, &cli.node, &cli.bench),
        runs: cli.runs,
        load_1m: None,
        suites: directories
            .iter()
            .map(|directory| bench_suite(cli, directory))
            .collect(),
    };
    summary::add_memory_per_actor(&mut results.suites);
    let loads: Vec<f64> = runs(&results)
        .flat_map(|run| [run.load_before[0], run.load_after[0]])
        .collect();
    results.load_1m = summary::spread(&loads);
    let path = results::write(
        &cli.out.clone().unwrap_or_else(|| cli.bench.join("results")),
        &results,
    )?;
    println!("{}", summary::table(&results));
    eprintln!("bouy-bench: wrote {}", path.display());
    Ok(runs(&results).all(|run| matches!(run.outcome, Outcome::Measured { .. })))
}

/// The suite directories in name order: each holds `bouy.ts` and `node.ts`.
fn suites(programs: &Path, wanted: &[String]) -> Result<Vec<PathBuf>, String> {
    let entries = fs::read_dir(programs)
        .map_err(|error| format!("cannot read {}: {error}", programs.display()))?;
    let mut found: Vec<PathBuf> = entries
        .filter_map(|entry| Some(entry.ok()?.path()))
        .filter(|path| path.join("bouy.ts").is_file() && path.join("node.ts").is_file())
        .collect();
    found.sort();
    if wanted.is_empty() {
        return Ok(found);
    }
    wanted
        .iter()
        .map(|name| {
            found
                .iter()
                .find(|path| path.file_name().is_some_and(|file| file == name.as_str()))
                .cloned()
                .ok_or_else(|| format!("no suite {name} in {}", programs.display()))
        })
        .collect()
}

/// One warm-up run of each program, which compiles the Bouy module and fills the file
/// cache, then the measured runs, alternating between Bouy and Node so that a change in
/// the load of the machine reaches both.
fn bench_suite(cli: &Cli, directory: &Path) -> Suite {
    let name = directory
        .file_name()
        .map_or_else(String::new, |name| name.to_string_lossy().into_owned());
    let commands: [(&'static str, Vec<OsString>); 2] = [
        (
            "bouy",
            vec![
                cli.bouy.clone().into(),
                "run".into(),
                directory.join("bouy.ts").into(),
            ],
        ),
        (
            "node",
            vec![cli.node.clone().into(), directory.join("node.ts").into()],
        ),
    ];
    for (runtime, command) in &commands {
        report(&name, runtime, "warm-up", &run(command));
    }
    let mut runs: [Vec<Run>; 2] = [Vec::new(), Vec::new()];
    for round in 1..=cli.runs {
        for ((runtime, command), runs) in commands.iter().zip(&mut runs) {
            let run = run(command);
            report(&name, runtime, &format!("{round}/{}", cli.runs), &run);
            runs.push(run);
        }
    }
    let programs = commands
        .into_iter()
        .zip(runs)
        .map(|((runtime, _), runs)| Program {
            runtime,
            failed: runs
                .iter()
                .filter(|run| matches!(run.outcome, Outcome::Failed { .. }))
                .count(),
            summary: summary::summarize(&runs),
            runs,
        })
        .collect();
    Suite { name, programs }
}

fn run(command: &[OsString]) -> Run {
    let load_before = environment::load_average();
    let outcome =
        measure::run(command).map_or_else(|error| Outcome::Failed { error }, Outcome::from);
    Run {
        load_before,
        load_after: environment::load_average(),
        outcome,
    }
}

fn report(suite: &str, runtime: &str, round: &str, run: &Run) {
    match &run.outcome {
        Outcome::Measured { wall_ms, .. } => {
            eprintln!("{suite} {runtime} {round}: {wall_ms:.0} ms");
        }
        Outcome::Failed { error } => eprintln!("{suite} {runtime} {round}: failed: {error}"),
    }
}

fn runs(results: &Results) -> impl Iterator<Item = &Run> {
    results
        .suites
        .iter()
        .flat_map(|suite| &suite.programs)
        .flat_map(|program| &program.runs)
}
