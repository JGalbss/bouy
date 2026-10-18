//! `buoy-bench`: runs each suite in `bench/programs/` as a Buoy program and as an
//! equivalent plain Node program on Node and on Bun, and the isolated program of the suite,
//! when it has one, on Node and on Bun. It records every run in `bench/results/` and prints
//! a Markdown table of the medians and ranges.
//! `buoy-bench compare` checks nightly runs against the limits of `bench/thresholds.json`.

mod compare;
mod environment;
mod measure;
mod results;
mod summary;

use std::ffi::{OsStr, OsString};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};

use crate::results::{Outcome, Program, Results, Run, Suite};

#[derive(Debug, Parser)]
#[command(
    name = "buoy-bench",
    about = "Run each Buoy benchmark next to equivalent plain Node programs, on Node and on Bun",
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
    /// The `buoy` CLI to measure.
    #[arg(long, env = "BUOY_BENCH_BUOY", default_value = "buoy")]
    buoy: PathBuf,
    /// The `node` that runs the baseline programs.
    #[arg(long, env = "BUOY_BENCH_NODE", default_value = "node")]
    node: PathBuf,
    /// The `bun` that runs the baseline programs, or `bun.ts` where a suite has one.
    #[arg(long, env = "BUOY_BENCH_BUN", default_value = "bun")]
    bun: PathBuf,
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
    /// Compare the Buoy medians of nightly runs with the limits. Fails when a metric is
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
            eprintln!("buoy-bench: {failure}");
            ExitCode::FAILURE
        }
        Err(error) => {
            eprintln!("buoy-bench: {error}");
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
        tools: environment::tools(&cli.buoy, &cli.node, &cli.bun, &cli.bench),
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
    eprintln!("buoy-bench: wrote {}", path.display());
    Ok(runs(&results).all(|run| matches!(run.outcome, Outcome::Measured { .. })))
}

/// The suite directories in name order: each holds `buoy.ts` and `node.ts`.
fn suites(programs: &Path, wanted: &[String]) -> Result<Vec<PathBuf>, String> {
    let entries = fs::read_dir(programs)
        .map_err(|error| format!("cannot read {}: {error}", programs.display()))?;
    let mut found: Vec<PathBuf> = entries
        .filter_map(|entry| Some(entry.ok()?.path()))
        .filter(|path| path.join("buoy.ts").is_file() && path.join("node.ts").is_file())
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

/// The memory limits of every run (AGENTS.md). The Buoy VM halts past
/// `BUOY_MAX_MEMORY`, Node caps its heap, and Bun, which has no heap limit, stays under
/// the RSS ceiling of `measure`, which applies to every program.
const BUOY_MAX_MEMORY: (&str, &str) = ("BUOY_MAX_MEMORY", "1G");
const NODE_HEAP_LIMIT: &str = "--max-old-space-size=512";
/// The suites whose Node program limits the heap of each worker thread with
/// `resourceLimits`. A process-wide `--max-old-space-size` overrides those limits, so
/// these programs run without it, under their own limits and the RSS ceiling.
const NODE_WORKER_LIMITS: [&str; 1] = ["memory-leak"];

/// How the harness starts the program of one runtime.
#[derive(Debug)]
struct Start {
    runtime: &'static str,
    command: Vec<OsString>,
    env: Option<(&'static str, &'static str)>,
}

/// One warm-up run of each program, which compiles the Buoy module and fills the file
/// cache, then the measured runs, alternating between the programs so that a change in
/// the load of the machine reaches all of them.
fn bench_suite(cli: &Cli, directory: &Path) -> Suite {
    let name = directory
        .file_name()
        .map_or_else(String::new, |name| name.to_string_lossy().into_owned());
    let bun_program = Some(directory.join("bun.ts"))
        .filter(|program| program.is_file())
        .unwrap_or_else(|| directory.join("node.ts"));
    let node = |program: &Path| {
        if NODE_WORKER_LIMITS.contains(&name.as_str()) {
            arguments(&cli.node, &[program.as_os_str()])
        } else {
            arguments(
                &cli.node,
                &[OsStr::new(NODE_HEAP_LIMIT), program.as_os_str()],
            )
        }
    };
    let bun = |program: &Path| arguments(&cli.bun, &[OsStr::new("run"), program.as_os_str()]);
    let mut starts = vec![
        Start {
            runtime: "buoy",
            command: arguments(
                &cli.buoy,
                &[OsStr::new("run"), directory.join("buoy.ts").as_os_str()],
            ),
            env: Some(BUOY_MAX_MEMORY),
        },
        Start {
            runtime: "node",
            command: node(&directory.join("node.ts")),
            env: None,
        },
        Start {
            runtime: "bun",
            command: bun(&bun_program),
            env: None,
        },
    ];
    let isolated = directory.join("isolated.ts");
    if isolated.is_file() {
        starts.extend([
            Start {
                runtime: "node-isolated",
                command: node(&isolated),
                env: None,
            },
            Start {
                runtime: "bun-isolated",
                command: bun(&isolated),
                env: None,
            },
        ]);
    }
    for start in &starts {
        report(&name, start.runtime, "warm-up", &run(start));
    }
    let mut runs: Vec<Vec<Run>> = starts.iter().map(|_| Vec::new()).collect();
    for round in 1..=cli.runs {
        for (start, runs) in starts.iter().zip(&mut runs) {
            let run = run(start);
            report(&name, start.runtime, &format!("{round}/{}", cli.runs), &run);
            runs.push(run);
        }
    }
    let programs = starts
        .into_iter()
        .zip(runs)
        .map(|(Start { runtime, .. }, runs)| Program {
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

fn arguments(program: &Path, rest: &[&OsStr]) -> Vec<OsString> {
    std::iter::once(program.as_os_str())
        .chain(rest.iter().copied())
        .map(OsStr::to_os_string)
        .collect()
}

fn run(start: &Start) -> Run {
    let load_before = environment::load_average();
    let outcome = measure::run(&start.command, start.env)
        .map_or_else(|error| Outcome::Failed { error }, Outcome::from);
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
