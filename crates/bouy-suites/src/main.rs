//! `bouy-suites`: runs an upstream test suite, compares the run with the expectation files
//! of section 3 of docs/design/testing.md, and writes the results.

use std::env;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use bouy_suites::comparison::Selection;
use bouy_suites::test262;
use bouy_suites::{compat, node, packages, summary};
use clap::{Args, Parser, Subcommand, ValueEnum};

/// The lines of each list of the report. `results.json` holds every id.
const REPORT_LINES: usize = 50;

#[derive(Debug, Parser)]
#[command(
    name = "bouy-suites",
    about = "Run an upstream test suite and compare it with its expectation file"
)]
struct Cli {
    #[command(subcommand)]
    suite: Suite,
}

#[derive(Debug, Subcommand)]
enum Suite {
    /// test262 at the commit of tests/test262/config.json, fetched into the cache.
    Test262 {
        #[command(flatten)]
        upstream: Upstream,
        /// A test262 checkout to use in place of the cache.
        #[arg(long)]
        checkout: Option<PathBuf>,
    },
    /// Node's own tests, vendored in tests/node/suite at the tag of .node-version.
    Node(Upstream),
    /// The ecosystem tier: tests/npm, tests/packages, and the areas of tests/equivalence
    /// that have an expectation file.
    Packages(Packages),
    /// Write docs/COMPAT.md and docs/compat.json from the committed summaries.
    Compat {
        /// Write nothing, and fail when a file differs from what the summaries give.
        #[arg(long)]
        check: bool,
    },
    /// Compile the programs that the runner asks for, one JSON request per line of stdin.
    #[command(hide = true)]
    CompileWorker,
}

/// The options of an upstream suite: a pull request runs `--select pr --base <file>`, the
/// nightly job runs every id, and `--filter` runs a few ids.
#[derive(Debug, Args)]
struct Upstream {
    /// Rewrite the expectation file and summary.json of the suite from a run of every id.
    #[arg(long)]
    update: bool,
    /// The ids to run: every id, or the selection of a pull request (section 3.7).
    #[arg(long, value_enum, default_value_t = Select::All)]
    select: Select,
    /// The expectation file of the base commit, for the regressions of section 3.3.
    #[arg(long)]
    base: Option<PathBuf>,
    /// Report regressions without failing, as the `accept-regression` label asks.
    #[arg(long)]
    accept_regressions: bool,
    /// Run only the ids that contain this text.
    #[arg(long)]
    filter: Option<String>,
    /// The `bouy` binary under test. Defaults to the `bouy` next to this binary.
    #[arg(long, env = "BOUY_BIN")]
    bouy: Option<PathBuf>,
    /// The worker threads. Defaults to the number of cores, at most 8.
    #[arg(long)]
    jobs: Option<usize>,
}

#[derive(Debug, Args)]
struct Packages {
    /// Rewrite each expectation file and tests/packages/summary.json from a run of every
    /// program.
    #[arg(long)]
    update: bool,
    /// Run only the programs whose path contains this text.
    #[arg(long)]
    filter: Option<String>,
    /// The `bouy` binary under test. Defaults to the `bouy` next to this binary.
    #[arg(long, env = "BOUY_BIN")]
    bouy: Option<PathBuf>,
    /// The worker threads. Defaults to the number of cores, at most 8.
    #[arg(long)]
    jobs: Option<usize>,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum Select {
    All,
    Pr,
}

impl From<Select> for Selection {
    fn from(select: Select) -> Self {
        match select {
            Select::All => Self::All,
            Select::Pr => Self::PullRequest,
        }
    }
}

fn main() -> ExitCode {
    match Cli::parse().suite {
        Suite::CompileWorker => {
            test262::serve_compiles();
            ExitCode::SUCCESS
        }
        Suite::Compat { check } => write_compat(check),
        Suite::Packages(arguments) => run_packages(arguments),
        Suite::Node(upstream) => run_node(upstream),
        Suite::Test262 { upstream, checkout } => run_test262(upstream, checkout),
    }
}

fn run_test262(upstream: Upstream, checkout: Option<PathBuf>) -> ExitCode {
    let compiler = match env::current_exe() {
        Ok(compiler) => compiler,
        Err(error) => {
            eprintln!("bouy-suites: cannot find this binary: {error}");
            return ExitCode::from(2);
        }
    };
    let Some(bouy) = bouy_under_test(upstream.bouy) else {
        return ExitCode::from(2);
    };
    let options = test262::Options {
        directory: bouy_suites::repository().join("tests/test262"),
        checkout,
        output: target().join("suites/test262"),
        bouy,
        compiler,
        selection: upstream.select.into(),
        filter: upstream.filter,
        base: upstream.base,
        update: upstream.update,
        jobs: upstream.jobs.unwrap_or_else(bouy_suites::default_jobs),
    };
    let report = match test262::run(&options) {
        Ok(report) => report,
        Err(error) => {
            eprintln!("bouy-suites: {error}");
            return ExitCode::from(2);
        }
    };
    let short = report.commit.get(..7).unwrap_or(&report.commit);
    println!(
        "test262 {short}: {} ids ran, {} executions, {} of {} files",
        report.run.len(),
        report.executions,
        report.run.len(),
        report.summary.total
    );
    print!(
        "{}",
        report.comparison.report(test262::UPDATE, REPORT_LINES)
    );
    print!(
        "{}",
        summary::run_report(&report.summary, &report.durations_ms)
    );
    println!("wrote {}", options.output.display());
    if options.update {
        println!("updated {}", options.directory.display());
        return ExitCode::SUCCESS;
    }
    if report.comparison.fails(upstream.accept_regressions) {
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

fn run_node(upstream: Upstream) -> ExitCode {
    let Some(bouy) = bouy_under_test(upstream.bouy) else {
        return ExitCode::from(2);
    };
    let options = node::Options {
        directory: bouy_suites::repository().join("tests/node"),
        output: target().join("suites/node"),
        bouy,
        selection: upstream.select.into(),
        filter: upstream.filter,
        base: upstream.base,
        update: upstream.update,
        jobs: upstream.jobs.unwrap_or_else(bouy_suites::default_jobs),
    };
    let report = match node::run(&options) {
        Ok(report) => report,
        Err(error) => {
            eprintln!("bouy-suites: {error}");
            return ExitCode::from(2);
        }
    };
    print!("{}", report.text());
    println!("wrote {}", options.output.display());
    if options.update {
        println!("updated {}", options.directory.display());
        return ExitCode::SUCCESS;
    }
    if report.comparison.fails(upstream.accept_regressions) {
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

fn write_compat(check: bool) -> ExitCode {
    let differ = match compat::update(&bouy_suites::repository(), check) {
        Ok(differ) => differ,
        Err(error) => {
            eprintln!("bouy-suites: {error}");
            return ExitCode::from(2);
        }
    };
    if !check {
        for file in differ {
            println!("wrote {file}");
        }
        return ExitCode::SUCCESS;
    }
    if differ.is_empty() {
        return ExitCode::SUCCESS;
    }
    for file in differ {
        eprintln!(
            "bouy-suites: {file} differs from the summaries; run `{}`",
            compat::COMMAND
        );
    }
    ExitCode::FAILURE
}

/// The `bouy` under test: the given binary, or the `bouy` next to this binary. Prints why
/// when it is not a file.
fn bouy_under_test(bouy: Option<PathBuf>) -> Option<PathBuf> {
    let bouy = bouy.or_else(|| Some(env::current_exe().ok()?.with_file_name("bouy")))?;
    if bouy.is_file() {
        return Some(bouy);
    }
    eprintln!(
        "bouy-suites: {} is not a file; build it with `cargo build --release -p bouy-cli`, or set BOUY_BIN",
        bouy.display()
    );
    None
}

fn run_packages(arguments: Packages) -> ExitCode {
    let Packages {
        update,
        filter,
        bouy,
        jobs,
    } = arguments;
    let Some(bouy) = bouy_under_test(bouy) else {
        return ExitCode::from(2);
    };
    let options = packages::Options {
        root: bouy_suites::repository(),
        output: target().join("suites/packages"),
        bouy,
        filter,
        update,
        jobs: jobs.unwrap_or_else(bouy_suites::default_jobs),
        deadline: Duration::from_secs(20),
    };
    let report = match packages::run(&options) {
        Ok(report) => report,
        Err(error) => {
            eprintln!("bouy-suites: {error}");
            return ExitCode::from(2);
        }
    };
    print!("{}", report.text());
    println!("wrote {}", options.output.display());
    if update {
        println!("updated the expectation files and tests/packages/summary.json");
        return ExitCode::SUCCESS;
    }
    if report.fails() {
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

/// The cargo target directory.
fn target() -> PathBuf {
    env::var_os("CARGO_TARGET_DIR")
        .map_or_else(|| bouy_suites::repository().join("target"), PathBuf::from)
}
