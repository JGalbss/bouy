//! `buoy-suites`: runs an upstream test suite, compares the run with the expectation files
//! of section 3 of docs/design/testing.md, and writes the results.

use std::env;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use buoy_suites::comparison::Selection;
use buoy_suites::test262;
use buoy_suites::{compat, node, node_bindings, node_surface, packages, summary};
use clap::{Args, Parser, Subcommand, ValueEnum};

/// The lines of each list of the report. `results.json` holds every id.
const REPORT_LINES: usize = 50;

#[derive(Debug, Parser)]
#[command(
    name = "buoy-suites",
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
    /// Node's own tests, vendored in tests/node/test at the tag of .node-version.
    Node(Upstream),
    /// The API surface of tests/node/surface.json, probed on Buoy.
    NodeSurface(Surface),
    /// Read Node's src/ at the tag of .node-version and write tests/node/bindings.json and
    /// `runtime/src/node/buoy_node_manifest.erl`.
    NodeBindings,
    /// The top npm packages of tests/ecosystem, which scripts/ecosystem.sh generates and
    /// installs, run in the node form of the CLI.
    Ecosystem(Packages),
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
    /// The `buoy` binary under test. Defaults to the `buoy` next to this binary.
    #[arg(long, env = "BUOY_BIN")]
    buoy: Option<PathBuf>,
    /// The worker threads. Defaults to the number of cores, at most 8.
    #[arg(long)]
    jobs: Option<usize>,
}

#[derive(Debug, Args)]
struct Packages {
    /// Rewrite each expectation file and the summary.json of the tier from a run of every
    /// program.
    #[arg(long)]
    update: bool,
    /// Run only the programs whose path contains this text.
    #[arg(long)]
    filter: Option<String>,
    /// The `buoy` binary under test. Defaults to the `buoy` next to this binary.
    #[arg(long, env = "BUOY_BIN")]
    buoy: Option<PathBuf>,
    /// The worker threads. Defaults to the number of cores, at most 8.
    #[arg(long)]
    jobs: Option<usize>,
    /// The seconds that one run may take. Defaults to 20, and to 120 for the ecosystem, whose
    /// first run of a package compiles all of it.
    #[arg(long)]
    deadline: Option<u64>,
}

#[derive(Debug, Args)]
struct Surface {
    /// Rewrite tests/node/surface/expectations.txt and summary.json from a run of every group.
    #[arg(long)]
    update: bool,
    /// Run only the groups whose name contains this text, such as `node:fs`.
    #[arg(long)]
    filter: Option<String>,
    /// The expectation file of the base commit, for the regressions of section 3.3.
    #[arg(long)]
    base: Option<PathBuf>,
    /// Report regressions without failing, as the `accept-regression` label asks.
    #[arg(long)]
    accept_regressions: bool,
    /// The `buoy` binary under test. Defaults to the `buoy` next to this binary.
    #[arg(long, env = "BUOY_BIN")]
    buoy: Option<PathBuf>,
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
        Suite::Packages(arguments) => run_packages(arguments, false),
        Suite::Ecosystem(arguments) => run_packages(arguments, true),
        Suite::Node(upstream) => run_node(upstream),
        Suite::NodeSurface(arguments) => run_node_surface(arguments),
        Suite::NodeBindings => write_node_bindings(),
        Suite::Test262 { upstream, checkout } => run_test262(upstream, checkout),
    }
}

fn run_test262(upstream: Upstream, checkout: Option<PathBuf>) -> ExitCode {
    let compiler = match env::current_exe() {
        Ok(compiler) => compiler,
        Err(error) => {
            eprintln!("buoy-suites: cannot find this binary: {error}");
            return ExitCode::from(2);
        }
    };
    let Some(buoy) = buoy_under_test(upstream.buoy) else {
        return ExitCode::from(2);
    };
    let options = test262::Options {
        directory: buoy_suites::repository().join("tests/test262"),
        checkout,
        output: target().join("suites/test262"),
        buoy,
        compiler,
        selection: upstream.select.into(),
        filter: upstream.filter,
        base: upstream.base,
        update: upstream.update,
        jobs: upstream.jobs.unwrap_or_else(buoy_suites::default_jobs),
    };
    let report = match test262::run(&options) {
        Ok(report) => report,
        Err(error) => {
            eprintln!("buoy-suites: {error}");
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
    let Some(buoy) = buoy_under_test(upstream.buoy) else {
        return ExitCode::from(2);
    };
    let options = node::Options {
        directory: buoy_suites::repository().join("tests/node"),
        output: target().join("suites/node"),
        buoy,
        selection: upstream.select.into(),
        filter: upstream.filter,
        base: upstream.base,
        update: upstream.update,
        jobs: upstream.jobs.unwrap_or_else(buoy_suites::default_jobs),
    };
    let report = match node::run(&options) {
        Ok(report) => report,
        Err(error) => {
            eprintln!("buoy-suites: {error}");
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

fn run_node_surface(arguments: Surface) -> ExitCode {
    let Some(buoy) = buoy_under_test(arguments.buoy) else {
        return ExitCode::from(2);
    };
    let options = node_surface::Options {
        directory: buoy_suites::repository().join("tests/node"),
        output: target().join("suites/node-surface"),
        buoy,
        filter: arguments.filter,
        base: arguments.base,
        update: arguments.update,
        jobs: arguments.jobs.unwrap_or_else(buoy_suites::default_jobs),
        deadline: Duration::from_secs(20),
    };
    let report = match node_surface::run(&options) {
        Ok(report) => report,
        Err(error) => {
            eprintln!("buoy-suites: {error}");
            return ExitCode::from(2);
        }
    };
    print!("{}", report.text());
    println!("wrote {}", options.output.display());
    if options.update {
        println!("updated {}", options.directory.join("surface").display());
        return ExitCode::SUCCESS;
    }
    if report.comparison.fails(arguments.accept_regressions) {
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

fn write_node_bindings() -> ExitCode {
    let manifest = match node_bindings::update(&buoy_suites::repository()) {
        Ok(manifest) => manifest,
        Err(error) => {
            eprintln!("buoy-suites: {error}");
            return ExitCode::from(2);
        }
    };
    let members: usize = manifest
        .bindings
        .values()
        .map(|binding| binding.members.len())
        .sum();
    println!(
        "Node {} ({}): {} bindings, {members} members",
        manifest.node,
        compat::short(&manifest.commit),
        manifest.bindings.len()
    );
    println!(
        "wrote {} and {}",
        node_bindings::MANIFEST,
        node_bindings::ERLANG
    );
    ExitCode::SUCCESS
}

fn write_compat(check: bool) -> ExitCode {
    let differ = match compat::update(&buoy_suites::repository(), check) {
        Ok(differ) => differ,
        Err(error) => {
            eprintln!("buoy-suites: {error}");
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
            "buoy-suites: {file} differs from the summaries; run `{}`",
            compat::COMMAND
        );
    }
    ExitCode::FAILURE
}

/// The `buoy` under test: the given binary, or the `buoy` next to this binary. Prints why
/// when it is not a file.
fn buoy_under_test(buoy: Option<PathBuf>) -> Option<PathBuf> {
    let buoy = buoy.or_else(|| Some(env::current_exe().ok()?.with_file_name("buoy")))?;
    if buoy.is_file() {
        return Some(buoy);
    }
    eprintln!(
        "buoy-suites: {} is not a file; build it with `cargo build --release -p buoy-cli`, or set BUOY_BIN",
        buoy.display()
    );
    None
}

fn run_packages(arguments: Packages, ecosystem: bool) -> ExitCode {
    let Packages {
        update,
        filter,
        buoy,
        jobs,
        deadline,
    } = arguments;
    let Some(buoy) = buoy_under_test(buoy) else {
        return ExitCode::from(2);
    };
    let tier = if ecosystem { "ecosystem" } else { "packages" };
    let options = packages::Options {
        root: buoy_suites::repository(),
        output: target().join("suites").join(tier),
        buoy,
        filter,
        update,
        jobs: jobs.unwrap_or_else(buoy_suites::default_jobs),
        deadline: Duration::from_secs(deadline.unwrap_or(if ecosystem { 120 } else { 20 })),
    };
    let run = if ecosystem {
        packages::run_ecosystem
    } else {
        packages::run
    };
    let report = match run(&options) {
        Ok(report) => report,
        Err(error) => {
            eprintln!("buoy-suites: {error}");
            return ExitCode::from(2);
        }
    };
    print!("{}", report.text());
    println!("wrote {}", options.output.display());
    if update {
        println!("updated the expectation files and tests/{tier}/summary.json");
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
        .map_or_else(|| buoy_suites::repository().join("target"), PathBuf::from)
}
