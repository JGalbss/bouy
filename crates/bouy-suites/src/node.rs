//! Node's own tests (section 5.7 of docs/design/testing.md): the files of `parallel`,
//! `es-module`, and `sequential` that `scripts/vendor-node-tests.sh` copied into
//! `tests/node/suite` at the tag of `.node-version`. Each file runs in its own `bouy` OS
//! process, because these files use `process.exit`, signals, stdio, and child processes. A
//! file passes when it exits with 0 within the deadline. `config.json` skips the files that
//! can never apply to Bouy (section 3.5), by path or by a flag of the `// Flags:` line.

use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use serde::Deserialize;

use crate::comparison::{self, Comparison, Origin, Selection};
use crate::expectations::{self, Entry, Expectations};
use crate::outcome::{Facts, Outcome, RunResult, classify};
use crate::summary::{self, Counts, Destination, Results, Summary, TestResult};
use crate::{SKIP_REASONS, bouy_env};

/// The name of the suite in `summary.json`, `results.json`, and the comment.
const SUITE: &str = "node";

/// The command that rewrites the expectation file and the summary.
pub const UPDATE: &str =
    "cargo build --release -p bouy-cli && cargo run --release -p bouy-suites -- node --update";

/// The directories of test files. `sequential` runs one file at a time.
const DIRECTORIES: [&str; 3] = ["parallel", "es-module", "sequential"];
const SEQUENTIAL: &str = "sequential/";

/// The flags of a file that tests a private internal or a V8 engine detail. These files
/// form the `internals` group of section 5.7.1, apart from the headline.
const INTERNALS: [&str; 2] = ["--expose-internals", "--allow-natives-syntax"];

/// The entry files of `test/common`, for a `CommonJS` file and for an ES module.
const COMMON: [&str; 2] = ["common/index.js", "common/index.mjs"];

/// The built-in modules that name a group. A file belongs to the module whose name, with
/// `-` for `_`, follows `test-` in its name, as `test-child-process-fork.js` belongs to
/// `child_process`. The longest name wins.
const MODULES: [&str; 46] = [
    "assert",
    "async_hooks",
    "buffer",
    "child_process",
    "cluster",
    "console",
    "constants",
    "crypto",
    "dgram",
    "diagnostics_channel",
    "dns",
    "domain",
    "events",
    "fs",
    "http",
    "http2",
    "https",
    "inspector",
    "module",
    "net",
    "os",
    "path",
    "perf_hooks",
    "process",
    "punycode",
    "querystring",
    "quic",
    "readline",
    "repl",
    "sea",
    "sqlite",
    "stream",
    "string_decoder",
    "sys",
    "test",
    "timers",
    "tls",
    "trace_events",
    "tty",
    "url",
    "util",
    "v8",
    "vm",
    "wasi",
    "worker_threads",
    "zlib",
];

/// The other words of a file name that name a module.
const ALIASES: [(&str, &str); 25] = [
    ("async-local-storage", "async_hooks"),
    ("async-wrap", "async_hooks"),
    ("cjs", "module"),
    ("debugger", "inspector"),
    ("esm", "module"),
    ("event-emitter", "events"),
    ("eventtarget", "events"),
    ("next-tick", "process"),
    ("performance", "perf_hooks"),
    ("readable", "stream"),
    ("require", "module"),
    ("runner", "test"),
    ("stderr", "process"),
    ("stdin", "process"),
    ("stdio", "process"),
    ("stdout", "process"),
    ("stream2", "stream"),
    ("stream3", "stream"),
    ("timer", "timers"),
    ("webcrypto", "crypto"),
    ("webstream", "stream"),
    ("webstreams", "stream"),
    ("whatwg-readablestream", "stream"),
    ("whatwg-url", "url"),
    ("worker", "worker_threads"),
];

/// The lines of each list of the report, and the failure reports that it prints in full.
const REPORT_LINES: usize = 50;
const REPORTED_RUNS: usize = 10;
/// The lines of stderr that a failure report keeps.
const STDERR_LINES: usize = 20;

#[derive(Debug)]
pub struct Options {
    /// `tests/node`: `config.json`, `suite/`, `expectations.txt`, and `summary.json`.
    pub directory: PathBuf,
    /// `target/suites/node`: the regenerated files, `results.json`, and `comment.md`.
    pub output: PathBuf,
    /// The `bouy` binary under test.
    pub bouy: PathBuf,
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
    pub tag: String,
    pub comparison: Comparison,
    /// The entry of each id that ran.
    pub run: Expectations,
    pub summary: Summary,
    pub durations_ms: BTreeMap<String, u128>,
    /// The failure reports of the files whose outcome differs from their line.
    reports: Vec<String>,
}

impl Report {
    /// The report: the files that ran, the findings of section 3.3, the first failure
    /// reports, the outcomes, the blockers, and the durations.
    #[must_use]
    pub fn text(&self) -> String {
        let mut text = format!(
            "{SUITE} {}: {} of {} files ran\n",
            self.tag,
            self.run.len(),
            self.summary.total
        );
        text.push_str(&self.comparison.report(UPDATE, REPORT_LINES));
        for report in self.reports.iter().take(REPORTED_RUNS) {
            text.push_str(report);
        }
        text.push_str(&summary::run_report(&self.summary, &self.durations_ms));
        text
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    tag: String,
    commit: String,
    timeout_ms: u64,
    #[serde(default)]
    skip: Vec<Skip>,
}

/// One skip of section 3.5: the files under `path`, or the files whose `// Flags:` line
/// holds `flag`.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Skip {
    path: Option<String>,
    flag: Option<String>,
    reason: String,
}

impl Skip {
    fn applies(&self, id: &str, flags: &[String]) -> bool {
        self.path
            .as_ref()
            .is_some_and(|path| id.starts_with(path.as_str()))
            || self.flag.as_ref().is_some_and(|flag| flags.contains(flag))
    }
}

/// Reads `config.json` of `directory`. Each skip names one selector and a reason code of
/// section 3.5, and a flag is written as the runner reads it: `-` for `_`, with no value.
fn load_config(directory: &Path) -> Result<Config, String> {
    let path = directory.join("config.json");
    let failed = |error: String| format!("{}: {error}", path.display());
    let text = fs::read_to_string(&path).map_err(|error| failed(error.to_string()))?;
    let config: Config = serde_json::from_str(&text).map_err(|error| failed(error.to_string()))?;
    for skip in &config.skip {
        if skip.path.is_some() == skip.flag.is_some() {
            return Err(failed(format!(
                "the skip {skip:?} must name one of path and flag"
            )));
        }
        if !SKIP_REASONS.contains(&skip.reason.as_str()) {
            return Err(failed(format!(
                "the skip reason `{}` is not one of {SKIP_REASONS:?}",
                skip.reason
            )));
        }
        if let Some(flag) = &skip.flag
            && Some(flag.clone()) != flag_name(flag)
        {
            return Err(failed(format!(
                "write the flag `{flag}` as `--<name>`, with `-` for `_` and no value"
            )));
        }
    }
    Ok(config)
}

/// One test file.
#[derive(Debug)]
struct Test {
    /// The path under `test/`, such as `parallel/test-fs-read.js`.
    id: String,
    /// The flags of the `// Flags:` line, as `flag_name` writes them.
    flags: Vec<String>,
    /// The variables of the `// Env:` line.
    env: Vec<(String, String)>,
    /// The reason code of the skip of `config.json` that applies.
    skip: Option<String>,
    /// The entry file of `test/common` that the test loads.
    common: Option<&'static str>,
}

/// The test files of the suite, in the order of `DIRECTORIES` and then by name. Node's
/// `test/testpy` takes each file of these directories whose name matches
/// `^test-.*\.m?js$`.
fn load_tests(suite: &Path, config: &Config) -> Result<Vec<Test>, String> {
    let mut tests = Vec::new();
    for directory in DIRECTORIES {
        let path = suite.join(directory);
        let mut names: Vec<String> = fs::read_dir(&path)
            .map_err(|error| format!("{}: {error}", path.display()))?
            .filter_map(Result::ok)
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| {
                name.starts_with("test-")
                    && Path::new(name)
                        .extension()
                        .is_some_and(|extension| extension == "js" || extension == "mjs")
            })
            .collect();
        names.sort();
        for name in names {
            let id = format!("{directory}/{name}");
            let bytes = fs::read(path.join(&name)).map_err(|error| format!("{id}: {error}"))?;
            tests.push(test_of(id, &String::from_utf8_lossy(&bytes), config)?);
        }
    }
    Ok(tests)
}

fn test_of(id: String, source: &str, config: &Config) -> Result<Test, String> {
    let flags: Vec<String> = header(source, "Flags")
        .unwrap_or_default()
        .split_whitespace()
        .filter_map(flag_name)
        .collect();
    let env = header(source, "Env")
        .unwrap_or_default()
        .split_whitespace()
        .map(|pair| {
            pair.split_once('=')
                .map(|(name, value)| (name.to_owned(), value.to_owned()))
                .ok_or_else(|| format!("{id}: `{pair}` of the `// Env:` line is not NAME=value"))
        })
        .collect::<Result<_, _>>()?;
    let skip = config
        .skip
        .iter()
        .find(|skip| skip.applies(&id, &flags))
        .map(|skip| skip.reason.clone());
    let common = if Path::new(&id)
        .extension()
        .is_some_and(|extension| extension == "mjs")
    {
        source
            .contains("'../common/index.mjs'")
            .then_some(COMMON[1])
    } else {
        source.contains("require('../common')").then_some(COMMON[0])
    };
    Ok(Test {
        id,
        flags,
        env,
        skip,
        common,
    })
}

/// The text of the first `// <key>:` line of `source`, after the colon: the
/// `FLAGS_PATTERN` and `ENV_PATTERN` of Node's `test/testpy`, `//\s+<key>:(.*)`.
fn header<'a>(source: &'a str, key: &str) -> Option<&'a str> {
    (0..source.len())
        .filter_map(|index| source.get(index..)?.strip_prefix("//"))
        .find_map(|after| {
            let rest = after.trim_start();
            if rest.len() == after.len() {
                return None;
            }
            let value = rest.strip_prefix(key)?.strip_prefix(':')?;
            value.lines().next()
        })
}

/// The name of a flag as config.json writes it: `-` for `_`, with no `=value`. Node reads
/// both spellings. A word that is no flag, such as the value after `--require`, gives
/// `None`.
fn flag_name(word: &str) -> Option<String> {
    let name = word.split('=').next().unwrap_or(word);
    name.starts_with("--").then(|| name.replace('_', "-"))
}

/// The group of `module` of a file (section 5.7): the built-in module of its name, or
/// `module` for the files of `es-module`, or `other`.
fn module_of(id: &str) -> String {
    let (directory, file) = id.split_once('/').unwrap_or(("", id));
    if directory == "es-module" {
        return "module".to_owned();
    }
    let name = file.strip_prefix("test-").unwrap_or(file);
    MODULES
        .iter()
        .map(|module| (module.replace('_', "-"), *module))
        .chain(
            ALIASES
                .iter()
                .map(|(prefix, module)| ((*prefix).to_owned(), *module)),
        )
        .filter(|(prefix, _)| {
            name.strip_prefix(prefix.as_str())
                .is_some_and(|rest| rest.starts_with(['-', '.']))
        })
        .max_by_key(|(prefix, _)| prefix.len())
        .map_or_else(|| "other".to_owned(), |(_, module)| module.to_owned())
}

/// What the executions share.
struct Context<'a> {
    options: &'a Options,
    suite: PathBuf,
    scratch: PathBuf,
    deadline: Duration,
    /// The entry files of `test/common` that `bouy check` rejects.
    rejected_common: Vec<&'static str>,
}

/// The facts of one file.
#[derive(Debug)]
struct Execution {
    outcome: Outcome,
    blockers: Vec<String>,
    report: String,
    time_ms: u128,
}

/// The flags of `bouy run` and `bouy check` for Node's tests and the surface probe: the
/// JavaScript engine with reference semantics, which runs Node's own `lib/` for the
/// built-in modules (docs/design/node-builtins.md).
pub const ENGINE: [&str; 2] = ["--semantics", "reference"];

/// Runs Node's tests and compares the run with the expectation files.
pub fn run(options: &Options) -> Result<Report, String> {
    // An update with --filter rewrites the lines of the ids that ran and keeps the others,
    // so a change to one module can record its files without a run of the whole suite.
    if options.update && options.selection != Selection::All {
        return Err("--update takes no --select".to_owned());
    }
    let config = load_config(&options.directory)?;
    let mut durations_ms = BTreeMap::new();

    let started = Instant::now();
    let tests = load_tests(&options.directory.join("suite"), &config)?;
    durations_ms.insert("load".to_owned(), started.elapsed().as_millis());

    let expected = expectations::read(&options.directory.join("expectations.txt"))?;
    let base = match &options.base {
        Some(path) if path.is_file() => Some(expectations::read(path)?),
        _ => None,
    };
    let started = Instant::now();
    let ran = execute_selected(options, &config, &tests, &expected)?;
    durations_ms.insert("execute".to_owned(), started.elapsed().as_millis());

    let run: Expectations = ran
        .iter()
        .map(|(test, execution)| (test.id.clone(), Entry::Same(execution.outcome)))
        .collect();
    let ids: BTreeSet<String> = tests.iter().map(|test| test.id.clone()).collect();
    let comparison = comparison::compare(Origin::Upstream, &run, &ids, &expected, base.as_ref());
    let reports = ran
        .iter()
        .filter(|(test, execution)| {
            !options.update && expected.get(&test.id) != Some(&Entry::Same(execution.outcome))
        })
        .map(|(_, execution)| execution.report.clone())
        .collect();
    let mut entries: Expectations = expected
        .into_iter()
        .filter(|(id, _)| ids.contains(id))
        .collect();
    entries.extend(run.clone());
    let blocked: Vec<&Vec<String>> = ran
        .iter()
        .map(|(_, execution)| &execution.blockers)
        .filter(|blockers| !blockers.is_empty())
        .collect();
    let summary = Summary {
        suite: SUITE.to_owned(),
        version: config.tag.clone(),
        updated: String::new(),
        total: tests.len(),
        outcomes: Counts::every(entries.values()),
        groups: groups(&tests, &entries),
        blockers: summary::blockers(blocked),
    }
    .updated_since(&options.directory.join("summary.json"));
    let comment = comparison.comment(&summary.comment_heading(base.as_ref(), run.len()), 50);
    let results = Results {
        date: crate::date(),
        host: format!("{}-{}", env::consts::OS, env::consts::ARCH),
        tools: crate::tools(&options.bouy, (SUITE, &config.tag)),
        durations_ms: durations_ms.clone(),
        tests: ran
            .into_iter()
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
    let header = [
        "Generated by `bouy-suites node --update`. Do not edit. Change config.json instead."
            .to_owned(),
        format!("{SUITE} {} {}", config.tag, config.commit),
    ];
    Destination {
        directory: &options.directory,
        output: &options.output,
        every_id: options.selection == Selection::All && options.filter.is_none(),
        update: options.update,
    }
    .write(&header, &entries, &summary, &results, &comment)?;
    Ok(Report {
        tag: config.tag,
        comparison,
        run,
        summary,
        durations_ms,
        reports,
    })
}

/// Runs the selected files, with the files of `sequential` one at a time after the others,
/// and returns each with its execution.
fn execute_selected<'a>(
    options: &Options,
    config: &Config,
    tests: &'a [Test],
    expected: &Expectations,
) -> Result<Vec<(&'a Test, Execution)>, String> {
    let (sequential, concurrent): (Vec<_>, Vec<_>) = tests
        .iter()
        .enumerate()
        .filter(|(_, test)| is_selected(test, options, expected.get(&test.id)))
        .partition(|(_, test)| test.id.starts_with(SEQUENTIAL));
    let suite = options.directory.join("suite");
    let scratch = options.output.join("scratch");
    let context = Context {
        options,
        rejected_common: rejected_common(options, &suite, &scratch)?,
        suite,
        scratch,
        deadline: Duration::from_millis(config.timeout_ms),
    };
    let execute = |&(serial, test): &(usize, &'a Test)| {
        execute(test, serial, &context).map(|execution| (test, execution))
    };
    let mut ran = crate::parallel(&concurrent, options.jobs, execute);
    ran.extend(crate::parallel(&sequential, 1, execute));
    let _ = fs::remove_dir_all(&context.scratch);
    ran.into_iter().collect()
}

/// A skip costs no run, so every selection takes the skipped files, and a change to the
/// skips of config.json shows on a pull request.
fn is_selected(test: &Test, options: &Options, expected: Option<&Entry>) -> bool {
    options
        .filter
        .as_ref()
        .is_none_or(|filter| test.id.contains(filter.as_str()))
        && (test.skip.is_some() || options.selection.includes(&test.id, expected))
}

/// The entry files of `test/common` that `bouy check` rejects. Each one is a blocker of the
/// rejected files that load it, as a harness file of test262 is.
fn rejected_common(
    options: &Options,
    suite: &Path,
    scratch: &Path,
) -> Result<Vec<&'static str>, String> {
    let mut rejected = Vec::new();
    for (index, file) in COMMON.into_iter().enumerate() {
        let temporary = scratch.join(format!("common-{index}"));
        fs::create_dir_all(&temporary)
            .map_err(|error| format!("{}: {error}", temporary.display()))?;
        let mut command = Command::new(&options.bouy);
        bouy_env(&mut command, &temporary)
            .current_dir(suite)
            .arg("check")
            .args(ENGINE)
            .arg(file);
        if !crate::run(&mut command, Duration::from_secs(60))
            .output
            .status
            .success()
        {
            rejected.push(file);
        }
    }
    Ok(rejected)
}

/// Runs one file with `bouy run` from the suite directory, or skips it.
fn execute(test: &Test, serial: usize, context: &Context) -> Result<Execution, String> {
    if let Some(reason) = &test.skip {
        return Ok(Execution {
            outcome: Outcome::Skip,
            blockers: Vec::new(),
            report: format!("--- {}: skip, {reason}\n", test.id),
            time_ms: 0,
        });
    }
    let directory = context.scratch.join(serial.to_string());
    let temporary = directory.join("tmp");
    fs::create_dir_all(&temporary).map_err(|error| format!("{}: {error}", temporary.display()))?;
    let result_file = directory.join("result.json");
    let mut command = Command::new(&context.options.bouy);
    // test/common/tmpdir.js makes its directory under NODE_TEST_DIR, so a run never writes
    // into the vendored tree.
    bouy_env(&mut command, &temporary)
        .current_dir(&context.suite)
        .env("BOUY_RESULT_FILE", &result_file)
        .env("NODE_TEST_KNOWN_GLOBALS", "0")
        .env("NODE_SKIP_FLAG_CHECK", "1")
        .env("TEST_SERIAL_ID", serial.to_string())
        .env("NODE_TEST_DIR", &temporary)
        .envs(test.env.iter().map(|(name, value)| (name, value)))
        .arg("run")
        .args(ENGINE)
        .arg(&test.id);
    let started = Instant::now();
    let finished = crate::run(&mut command, context.deadline);
    let time_ms = started.elapsed().as_millis();
    let passed = !finished.timed_out && finished.output.status.success();
    let result = RunResult::read(&result_file);
    let _ = fs::remove_dir_all(&directory);
    let outcome = classify(&Facts::of_run(result.as_ref(), finished.timed_out, passed));
    let mut blockers = result
        .map(|result| result.blockers(outcome))
        .unwrap_or_default();
    if outcome == Outcome::Rejected
        && let Some(common) = test.common
        && context.rejected_common.contains(&common)
    {
        blockers.push(common.to_owned());
    }
    let stderr = String::from_utf8_lossy(&finished.output.stderr);
    let stderr: Vec<&str> = stderr.lines().take(STDERR_LINES).collect();
    let report = format!(
        "--- {}: {outcome}, exit status {:?}\n--- stderr:\n{}\nrerun: {command:?}\n",
        test.id,
        finished.output.status.code(),
        stderr.join("\n"),
    );
    Ok(Execution {
        outcome,
        blockers,
        report,
        time_ms,
    })
}

/// The groups of section 5.7 and 5.7.1: `kind` (`public` or `internals`), `directory`,
/// `module`, and the skips by reason.
fn groups(tests: &[Test], entries: &Expectations) -> BTreeMap<String, BTreeMap<String, Counts>> {
    let mut groups: BTreeMap<String, BTreeMap<String, Counts>> = BTreeMap::new();
    for test in tests {
        let Some(entry) = entries.get(&test.id) else {
            continue;
        };
        let kind = if test
            .flags
            .iter()
            .any(|flag| INTERNALS.contains(&flag.as_str()))
        {
            "internals"
        } else {
            "public"
        };
        let directory = test.id.split('/').next().unwrap_or_default();
        let module = module_of(&test.id);
        let mut names = vec![
            ("kind", kind),
            ("directory", directory),
            ("module", &module),
        ];
        if let Some(reason) = &test.skip {
            names.push(("skip reason", reason));
        }
        for (group, name) in names {
            groups
                .entry(group.to_owned())
                .or_default()
                .entry(name.to_owned())
                .or_default()
                .add(entry);
        }
    }
    groups
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_header_lines_follow_node_test_py() {
        let source = "'use strict';\n// Flags: --expose_gc --require ./a.js\n// Env: A=1 B=2\n";
        assert_eq!(
            header(source, "Flags"),
            Some(" --expose_gc --require ./a.js")
        );
        assert_eq!(header(source, "Env"), Some(" A=1 B=2"));
        assert_eq!(
            header("//Flags: --x\n", "Flags"),
            None,
            "`\\s+` needs a space"
        );
        assert_eq!(header("/* Flags: --x */\n", "Flags"), None);
        let config = Config {
            tag: String::new(),
            commit: String::new(),
            timeout_ms: 1,
            skip: vec![Skip {
                path: None,
                flag: Some("--expose-gc".to_owned()),
                reason: "v8-flag".to_owned(),
            }],
        };
        let test = test_of("parallel/test-a.js".to_owned(), source, &config).expect("parses");
        assert_eq!(test.flags, ["--expose-gc", "--require"]);
        assert_eq!(test.env.len(), 2);
        assert_eq!(test.skip.as_deref(), Some("v8-flag"));
        assert!(test_of("parallel/test-b.js".to_owned(), "// Env: A\n", &config).is_err());
    }

    #[test]
    fn a_file_belongs_to_the_module_of_its_name() {
        for (id, module) in [
            ("parallel/test-child-process-fork.js", "child_process"),
            ("parallel/test-http2-client.js", "http2"),
            ("parallel/test-http-agent.js", "http"),
            ("parallel/test-fs.js", "fs"),
            ("parallel/test-event-emitter-once.js", "events"),
            ("parallel/test-whatwg-url-custom-parsing.js", "url"),
            ("parallel/test-worker-message-port.js", "worker_threads"),
            ("es-module/test-esm-loader.mjs", "module"),
            ("sequential/test-fsx.js", "other"),
        ] {
            assert_eq!(module_of(id), module, "{id}");
        }
    }

    #[test]
    fn the_committed_config_names_a_reason_for_each_skip() {
        let config = load_config(&crate::repository().join("tests/node")).expect("loads");
        assert_eq!(config.commit.len(), 40, "the commit is a full SHA");
        let pinned = fs::read_to_string(crate::repository().join(".node-version"))
            .expect(".node-version reads");
        assert_eq!(config.tag, format!("v{}", pinned.trim()));
    }
}
