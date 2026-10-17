//! A development runner for test262 on the reference engine. It compiles each test with the
//! harness files that its frontmatter names, runs the compiled tests in one VM, each in a
//! realm process of its own (`runtime/test/bouy_test262.erl`), and prints the failures and
//! a table of results per directory.
//!
//! `scripts/test262-dev.sh` fetches test262 at the pinned commit and runs this binary. It
//! is the quick loop of engine work and does not depend on the `bouy-suites` crate.
//!
//! A test runs once: a `noStrict` test as sloppy code, and every other test in strict
//! mode.

#[path = "../runtime.rs"]
mod runtime;

use std::collections::{BTreeMap, HashMap, HashSet};
use std::env;
use std::fmt::Write as _;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{ExitCode, Stdio};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;

use bouy_compiler::{Code, Diagnostic, Semantics};
use clap::Parser;

/// The host functions that test262 expects: `print` for the async tests, and the part of
/// `$262` that the engine can give: the global object, and `detachArrayBuffer` through
/// `ArrayBuffer.prototype.transfer`, which detaches its receiver.
const HOST: &str = "function print(message) { console.log(String(message)); }\n\
var $262 = { global: globalThis, gc: function () {}, detachArrayBuffer: function (buffer) { if (!buffer.detached) buffer.transfer(); } };\n";

/// The VM half of the runner, which the VM compiles when it starts.
const VM_RUNNER: &str = include_str!("../../../../runtime/test/bouy_test262.erl");

#[derive(Debug, Parser)]
#[command(
    name = "test262-dev",
    about = "Runs test262 files under the reference engine"
)]
struct Options {
    /// The test262 checkout.
    #[arg(long)]
    test262: PathBuf,
    /// Tests that run at once.
    #[arg(long)]
    jobs: Option<usize>,
    /// The time each test may take.
    #[arg(long, default_value_t = 10_000)]
    timeout_ms: u64,
    /// Writes the failures to this file instead of stdout.
    #[arg(long)]
    failures: Option<PathBuf>,
    /// Files or directories, relative to the checkout or absolute.
    #[arg(required = true)]
    paths: Vec<PathBuf>,
}

/// The fields of a test's frontmatter that the runner uses.
#[derive(Debug, Default, Clone)]
struct Frontmatter {
    includes: Vec<String>,
    flags: Vec<String>,
    features: Vec<String>,
    negative: Option<Negative>,
}

#[derive(Debug, Default, Clone)]
struct Negative {
    phase: String,
    error: String,
}

#[derive(Debug, Clone)]
enum Outcome {
    Pass,
    Fail(String),
    /// The engine rejected the test at compile time with a Bouy diagnostic.
    Compile(String),
    Timeout,
    Skip(&'static str),
}

/// One test: its path, and the directory it counts under.
struct Test {
    path: PathBuf,
    group: String,
}

/// A test after compilation: decided already, or compiled into Erlang files to run, the
/// entry module first.
enum Prepared {
    Decided(Outcome),
    Compiled {
        meta: Frontmatter,
        erlang: Vec<PathBuf>,
    },
}

/// What the VM reports for one test.
struct Run {
    status: String,
    stdout: String,
    stderr: String,
}

fn main() -> ExitCode {
    let options = Options::parse();
    let tests = match collect(&options) {
        Ok(tests) => tests,
        Err(error) => return fail(&error),
    };
    let scratch = env::temp_dir().join(format!("bouy-test262-{}", std::process::id()));
    let result = run_tests(&options, &scratch, &tests);
    let _ = fs::remove_dir_all(&scratch);
    match result {
        Ok(outcomes) => report(&options, &tests, &outcomes),
        Err(error) => fail(&error),
    }
}

fn fail(message: &str) -> ExitCode {
    eprintln!("test262-dev: {message}");
    ExitCode::from(2)
}

fn run_tests(options: &Options, scratch: &Path, tests: &[Test]) -> Result<Vec<Outcome>, String> {
    for dir in ["src", "erl", "out"] {
        fs::create_dir_all(scratch.join(dir))
            .map_err(|error| format!("cannot write {}: {error}", scratch.display()))?;
    }
    copy_fixtures(&options.test262, scratch, tests)?;
    let jobs = options
        .jobs
        .unwrap_or_else(|| {
            thread::available_parallelism().map_or(4, |cores| (usize::from(cores) / 2).clamp(1, 8))
        })
        .max(1);
    // Every test is on disk before any compiles, since a test may import another.
    let written = parallel(jobs, tests, |_, test| {
        write_program(&options.test262, scratch, &test.path)
    });
    let prepared = parallel(jobs, tests, |index, test| {
        prepare(
            scratch,
            index,
            &options.test262,
            &test.path,
            &written[index],
        )
    });
    let compiled: Vec<(usize, &[PathBuf])> = prepared
        .iter()
        .enumerate()
        .filter_map(|(index, prepared)| match prepared {
            Prepared::Compiled { erlang, .. } => Some((index, erlang.as_slice())),
            Prepared::Decided(_) => None,
        })
        .collect();
    let mut runs = run_vm(options, scratch, jobs, &compiled)?;
    Ok(prepared
        .into_iter()
        .enumerate()
        .map(|(index, prepared)| match prepared {
            Prepared::Decided(outcome) => outcome,
            Prepared::Compiled { meta, .. } => match runs.remove(&index) {
                Some(run) => classify(&meta, &run),
                None => Outcome::Fail("the VM crashed while the test ran".to_owned()),
            },
        })
        .collect())
}

/// Copies the fixtures of each directory of the tests into the scratch tree, where each
/// test is written at its own relative path, so that a test imports its fixtures by the
/// specifiers it names. A `package.json` of `"type": "module"` makes every `.js` file
/// an ES module, as test262 expects.
fn copy_fixtures(test262: &Path, scratch: &Path, tests: &[Test]) -> Result<(), String> {
    let source = scratch.join("src");
    fs::write(source.join("package.json"), "{\"type\":\"module\"}\n")
        .map_err(|error| format!("cannot write the scratch package.json: {error}"))?;
    let dirs: HashSet<&Path> = tests.iter().filter_map(|test| test.path.parent()).collect();
    for dir in dirs {
        let target = source.join(relative(test262, dir));
        fs::create_dir_all(&target)
            .map_err(|error| format!("cannot write {}: {error}", target.display()))?;
        let Ok(entries) = fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.filter_map(Result::ok) {
            let path = entry.path();
            let name = entry.file_name();
            if path.is_file() && name.to_string_lossy().contains("_FIXTURE") {
                fs::copy(&path, target.join(&name))
                    .map_err(|error| format!("cannot copy {}: {error}", path.display()))?;
            }
        }
    }
    Ok(())
}

/// The test files under the paths, sorted, without the fixtures that other tests import.
fn collect(options: &Options) -> Result<Vec<Test>, String> {
    let mut tests = Vec::new();
    for path in &options.paths {
        let absolute = options.test262.join(path);
        if absolute.is_file() {
            let group = relative(&options.test262, absolute.parent().unwrap_or(&absolute));
            tests.push(Test {
                path: absolute,
                group,
            });
            continue;
        }
        let mut files = Vec::new();
        walk(&absolute, &mut files)
            .map_err(|error| format!("cannot read {}: {error}", absolute.display()))?;
        for file in files {
            let below = file.strip_prefix(&absolute).unwrap_or(&file);
            let group = match below.components().next() {
                Some(first) if below.components().count() > 1 => {
                    relative(&options.test262, &absolute.join(first))
                }
                _ => relative(&options.test262, &absolute),
            };
            tests.push(Test { path: file, group });
        }
    }
    tests.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(tests)
}

fn walk(dir: &Path, files: &mut Vec<PathBuf>) -> std::io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.is_dir() {
            walk(&path, files)?;
        } else if path.extension().is_some_and(|extension| extension == "js")
            && !path.to_string_lossy().contains("_FIXTURE")
        {
            files.push(path);
        }
    }
    Ok(())
}

fn relative(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
}

/// Maps `work` over `items` on `jobs` threads, in order.
fn parallel<T: Sync, R: Send>(
    jobs: usize,
    items: &[T],
    work: impl Fn(usize, &T) -> R + Sync,
) -> Vec<R> {
    let next = AtomicUsize::new(0);
    let results: Mutex<Vec<Option<R>>> = Mutex::new(items.iter().map(|_| None).collect());
    thread::scope(|scope| {
        for _ in 0..jobs {
            scope.spawn(|| {
                loop {
                    let index = next.fetch_add(1, Ordering::Relaxed);
                    let Some(item) = items.get(index) else {
                        break;
                    };
                    let result = work(index, item);
                    if let Ok(mut results) = results.lock() {
                        results[index] = Some(result);
                    }
                }
            });
        }
    });
    results
        .into_inner()
        .unwrap_or_default()
        .into_iter()
        .flatten()
        .collect()
}

/// A test written to the scratch tree: its frontmatter and the lines before the test, or
/// its outcome when it does not run.
enum Written {
    Decided(Outcome),
    Program {
        meta: Frontmatter,
        prelude_lines: usize,
    },
}

/// Reads a test and writes its program at its path in the scratch tree.
fn write_program(test262: &Path, scratch: &Path, path: &Path) -> Written {
    let source = match fs::read_to_string(path) {
        Ok(source) => source,
        Err(error) => return Written::Decided(Outcome::Fail(format!("cannot read: {error}"))),
    };
    let meta = frontmatter(&source);
    if let Some(reason) = skip_reason(&meta) {
        return Written::Decided(Outcome::Skip(reason));
    }
    let (program, prelude_lines) = match program(test262, &meta, &source) {
        Ok(program) => program,
        Err(error) => return Written::Decided(Outcome::Fail(error)),
    };
    let file = scratch.join("src").join(relative(test262, path));
    if let Err(error) = fs::write(&file, program) {
        return Written::Decided(Outcome::Fail(format!("cannot write the program: {error}")));
    }
    Written::Program {
        meta,
        prelude_lines,
    }
}

/// Compiles a written test.
fn prepare(
    scratch: &Path,
    index: usize,
    test262: &Path,
    path: &Path,
    written: &Written,
) -> Prepared {
    let (meta, prelude_lines) = match written {
        Written::Decided(outcome) => return Prepared::Decided(outcome.clone()),
        Written::Program {
            meta,
            prelude_lines,
        } => (meta.clone(), *prelude_lines),
    };
    let file = scratch.join("src").join(relative(test262, path));
    let compiled = if meta.has_flag("module") {
        bouy_compiler::compile_with(&file, Semantics::Reference)
    } else {
        bouy_compiler::compile_script(&file)
    };
    let project = match compiled {
        Ok(project) => project,
        Err(diagnostics) => {
            return Prepared::Decided(compile_failure(&meta, &diagnostics, prelude_lines));
        }
    };
    // A module that does not link throws when the program starts, so a test of phase
    // `resolution` runs.
    if let Some(negative) = &meta.negative
        && negative.phase == "parse"
    {
        return Prepared::Decided(Outcome::Fail(format!(
            "expected a {} in phase {}; the test compiled",
            negative.error, negative.phase
        )));
    }
    if project.modules.is_empty() {
        return Prepared::Decided(Outcome::Fail("the compiler made no module".to_owned()));
    }
    let mut erlang = Vec::new();
    for module in &project.modules {
        let file = scratch.join("erl").join(format!("{}.erl", module.name));
        // Tests that share a fixture write the same file: through a rename, so that the
        // VM never reads half of it.
        let staging = file.with_extension(format!("erl.{index}"));
        if let Err(error) =
            fs::write(&staging, &module.erlang).and_then(|()| fs::rename(&staging, &file))
        {
            return Prepared::Decided(Outcome::Fail(format!("cannot write the Erlang: {error}")));
        }
        erlang.push(file);
    }
    Prepared::Compiled { meta, erlang }
}

fn skip_reason(meta: &Frontmatter) -> Option<&'static str> {
    if meta.has_flag("CanBlockIsFalse") {
        return Some("can-block");
    }
    if meta.features.iter().any(|feature| feature == "IsHTMLDDA") {
        return Some("needs-dom");
    }
    None
}

/// The program that runs a test: the strict directive unless the test is `noStrict`, the
/// host functions, the harness, then the test. A `raw` test runs as it is. Returns the program and the count of the
/// lines before the test.
fn program(test262: &Path, meta: &Frontmatter, source: &str) -> Result<(String, usize), String> {
    if meta.has_flag("raw") {
        return Ok((source.to_owned(), 0));
    }
    let mut prelude = if meta.has_flag("noStrict") {
        String::new()
    } else {
        String::from("\"use strict\";\n")
    };
    prelude.push_str(HOST);
    let mut includes = vec!["assert.js".to_owned(), "sta.js".to_owned()];
    if meta.has_flag("async") {
        includes.push("doneprintHandle.js".to_owned());
    }
    for include in &meta.includes {
        if !includes.contains(include) {
            includes.push(include.clone());
        }
    }
    for include in &includes {
        let path = test262.join("harness").join(include);
        let text = fs::read_to_string(&path)
            .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
        prelude.push_str(&text);
        if !text.ends_with('\n') {
            prelude.push('\n');
        }
    }
    if meta.has_flag("async") {
        // asyncHelpers.js looks for $DONE on the global object, where a script's function
        // declarations live; a declaration here is module-level.
        prelude.push_str("globalThis.$DONE = $DONE;\n");
    }
    let lines = prelude.lines().count();
    prelude.push_str(source);
    Ok((prelude, lines))
}

/// The outcome of a test that did not compile: a pass for a parse-time negative test that
/// got a syntax error, else the first diagnostic.
fn compile_failure(
    meta: &Frontmatter,
    diagnostics: &[Diagnostic],
    prelude_lines: usize,
) -> Outcome {
    let syntax = diagnostics.iter().any(|d| d.code == Code::Syntax);
    let first = diagnostics.first().map_or_else(
        || "no diagnostic".to_owned(),
        |d| describe(d, prelude_lines),
    );
    match &meta.negative {
        Some(negative) if negative.phase == "parse" && syntax => Outcome::Pass,
        Some(negative) if negative.phase == "parse" => Outcome::Fail(format!(
            "expected a {} at parse time; {first}",
            negative.error
        )),
        Some(negative) if negative.phase == "resolution" => Outcome::Fail(format!(
            "expected a {} at module resolution; {first}",
            negative.error
        )),
        _ => Outcome::Compile(first),
    }
}

/// A diagnostic with its line in the test, or in the harness before it.
fn describe(diagnostic: &Diagnostic, prelude_lines: usize) -> String {
    let code = diagnostic.code.as_str();
    let message = &diagnostic.message;
    if diagnostic.line > prelude_lines {
        format!(
            "line {}: {code}: {message}",
            diagnostic.line - prelude_lines
        )
    } else {
        format!("harness line {}: {code}: {message}", diagnostic.line)
    }
}

/// Runs the compiled tests in one VM, and starts another for the tests that a VM which
/// crashed did not start, as long as each VM starts a test. Returns the run of each test
/// that finished.
fn run_vm(
    options: &Options,
    scratch: &Path,
    jobs: usize,
    compiled: &[(usize, &[PathBuf])],
) -> Result<HashMap<usize, Run>, String> {
    let runtime = runtime::locate()?;
    let runner = scratch.join("bouy_test262.erl");
    fs::write(&runner, VM_RUNNER).map_err(|error| format!("cannot write the runner: {error}"))?;
    let mut runs = HashMap::new();
    let mut remaining: Vec<(usize, &[PathBuf])> = compiled.to_vec();
    while !remaining.is_empty() {
        let mut manifest = String::new();
        for (index, erlang) in &remaining {
            let files: Vec<String> = erlang
                .iter()
                .map(|file| file.display().to_string())
                .collect();
            let _ = writeln!(
                manifest,
                "{index}\t{}\t{}",
                files.join(","),
                options.timeout_ms
            );
        }
        let manifest_path = scratch.join("manifest");
        fs::write(&manifest_path, manifest)
            .map_err(|error| format!("cannot write the manifest: {error}"))?;
        let started = vm_pass(&runtime, scratch, &runner, &manifest_path, jobs, &mut runs)?;
        if started.is_empty() {
            eprintln!("test262-dev: the VM stopped before it started a test");
            break;
        }
        remaining.retain(|(index, _)| !runs.contains_key(index) && !started.contains(index));
    }
    Ok(runs)
}

/// One VM over the manifest. Returns the tests that started.
fn vm_pass(
    runtime: &runtime::Runtime,
    scratch: &Path,
    runner: &Path,
    manifest: &Path,
    jobs: usize,
    runs: &mut HashMap<usize, Run>,
) -> Result<HashSet<usize>, String> {
    let source = runner.display().to_string();
    let eval = format!(
        "{{ok, M, B}} = compile:file(\"{source}\", [binary, report]), {{module, M}} = code:load_binary(M, \"{source}\", B), bouy_test262:main()."
    );
    let out = scratch.join("out");
    let mut vm = runtime.vm();
    vm.args([
        "+Bd",
        "-noshell",
        "-noinput",
        "-mode",
        "minimal",
        "-boot",
        "no_dot_erlang",
        "-pa",
    ])
    .arg(&runtime.ebin)
    .args(["-eval", &eval, "-extra"])
    .arg(manifest)
    .arg(jobs.to_string())
    .arg(&out)
    .env("ERL_CRASH_DUMP_SECONDS", "0")
    // Each realm may hold 256 MB (bouy_test262.erl); the VM gets that per job plus 1 GB.
    .env("BOUY_MAX_MEMORY", format!("{}M", 1024 + jobs * 256))
    .stdin(Stdio::null())
    .stdout(Stdio::piped())
    .stderr(Stdio::inherit());
    // The `bouy` binary next to this one compiles the code of `eval` and `new Function`.
    if let Some(compiler) = env::current_exe()
        .ok()
        .map(|exe| exe.with_file_name("bouy"))
        .filter(|path| path.is_file())
    {
        vm.env("BOUY_COMPILER", compiler);
    }
    let mut child = vm
        .spawn()
        .map_err(|error| format!("cannot start erl: {error}"))?;
    let mut started = HashSet::new();
    if let Some(stdout) = child.stdout.take() {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let mut words = line.split(' ');
            match (
                words.next(),
                words.next().and_then(|i| i.parse::<usize>().ok()),
            ) {
                (Some("START"), Some(index)) => {
                    started.insert(index);
                }
                (Some("DONE"), Some(index)) => {
                    let base = out.join(index.to_string());
                    runs.insert(
                        index,
                        Run {
                            status: words.next().unwrap_or("1").to_owned(),
                            stdout: fs::read_to_string(base.with_extension("out"))
                                .unwrap_or_default(),
                            stderr: fs::read_to_string(base.with_extension("err"))
                                .unwrap_or_default(),
                        },
                    );
                    if runs.len().is_multiple_of(1000) {
                        eprintln!("test262-dev: {} tests ran", runs.len());
                    }
                }
                _ => {}
            }
        }
    }
    let _ = child.wait();
    Ok(started)
}

fn classify(meta: &Frontmatter, run: &Run) -> Outcome {
    let first = first_error(&run.stderr);
    match run.status.as_str() {
        "timeout" => return Outcome::Timeout,
        "memory" => return Outcome::Fail("the realm grew past 256 MB".to_owned()),
        "compile" => return Outcome::Fail(format!("generated Erlang does not compile: {first}")),
        _ => {}
    }
    if let Some(negative) = &meta.negative {
        if run.status == "1" && run.stderr.contains(&negative.error) {
            return Outcome::Pass;
        }
        return Outcome::Fail(format!(
            "expected a {} at run time; {first}",
            negative.error
        ));
    }
    if run.status != "0" {
        return Outcome::Fail(first);
    }
    if let Some(line) = run
        .stdout
        .lines()
        .find(|line| line.starts_with("Test262:AsyncTestFailure"))
    {
        return Outcome::Fail(line.to_owned());
    }
    if meta.has_flag("async") && !run.stdout.contains("Test262:AsyncTestComplete") {
        return Outcome::Fail("the async test did not call $DONE".to_owned());
    }
    Outcome::Pass
}

/// The first line of stderr. An uncaught object prints over several lines: they stay on one.
fn first_error(stderr: &str) -> String {
    let mut lines = stderr.lines().skip_while(|line| line.trim().is_empty());
    let Some(first) = lines.next() else {
        return "no output".to_owned();
    };
    let mut joined = first.trim_end().to_owned();
    if joined.ends_with('{') {
        for line in lines.take(8) {
            joined.push(' ');
            joined.push_str(line.trim());
        }
    }
    joined
}

impl Frontmatter {
    fn has_flag(&self, flag: &str) -> bool {
        self.flags.iter().any(|f| f == flag)
    }

    fn push(&mut self, key: &str, item: &str) {
        let item = item.split('#').next().unwrap_or_default().trim().to_owned();
        if item.is_empty() {
            return;
        }
        match key {
            "includes" => self.includes.push(item),
            "flags" => self.flags.push(item),
            "features" => self.features.push(item),
            _ => {}
        }
    }
}

/// Reads the YAML frontmatter between `/*---` and `---*/`: the lists `includes`, `flags`,
/// and `features`, inline or as `- item` lines, and the `phase` and `type` of `negative`.
fn frontmatter(source: &str) -> Frontmatter {
    let mut meta = Frontmatter::default();
    let Some(start) = source.find("/*---") else {
        return meta;
    };
    let Some(length) = source[start..].find("---*/") else {
        return meta;
    };
    let mut key = String::new();
    for line in source[start + 5..start + length].lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if !line.starts_with([' ', '\t']) {
            let (name, value) = trimmed.split_once(':').unwrap_or((trimmed, ""));
            name.trim().clone_into(&mut key);
            if key == "negative" {
                meta.negative = Some(Negative::default());
            }
            if let Some(list) = value
                .trim()
                .strip_prefix('[')
                .and_then(|list| list.strip_suffix(']'))
            {
                for item in list.split(',') {
                    meta.push(&key, item);
                }
            }
            continue;
        }
        if let Some(item) = trimmed.strip_prefix("- ") {
            meta.push(&key, item);
            continue;
        }
        if let (Some(negative), Some((field, value))) =
            (meta.negative.as_mut(), trimmed.split_once(':'))
            && key == "negative"
        {
            match field.trim() {
                "phase" => value.trim().clone_into(&mut negative.phase),
                "type" => value.trim().clone_into(&mut negative.error),
                _ => {}
            }
        }
    }
    meta
}

/// The counts of one directory.
#[derive(Debug, Default, Clone, Copy)]
struct Counts {
    tests: usize,
    pass: usize,
    fail: usize,
    compile: usize,
    timeout: usize,
    skip: usize,
}

impl Counts {
    fn add(&mut self, outcome: &Outcome) {
        self.tests += 1;
        match outcome {
            Outcome::Pass => self.pass += 1,
            Outcome::Fail(_) => self.fail += 1,
            Outcome::Compile(_) => self.compile += 1,
            Outcome::Timeout => self.timeout += 1,
            Outcome::Skip(_) => self.skip += 1,
        }
    }

    fn merge(&mut self, other: Self) {
        self.tests += other.tests;
        self.pass += other.pass;
        self.fail += other.fail;
        self.compile += other.compile;
        self.timeout += other.timeout;
        self.skip += other.skip;
    }

    /// The pass rate of the tests that ran, in tenths of a percent.
    fn rate(self) -> String {
        let ran = self.tests - self.skip;
        if ran == 0 {
            return "-".to_owned();
        }
        let tenths = self.pass * 1000 / ran;
        format!("{}.{}%", tenths / 10, tenths % 10)
    }

    fn row(self, name: &str) -> String {
        format!(
            "| {name} | {} | {} | {} | {} | {} | {} | {} |",
            self.tests,
            self.pass,
            self.fail,
            self.compile,
            self.timeout,
            self.skip,
            self.rate()
        )
    }
}

fn report(options: &Options, tests: &[Test], outcomes: &[Outcome]) -> ExitCode {
    let mut failures = String::new();
    let mut groups: BTreeMap<&str, Counts> = BTreeMap::new();
    for (test, outcome) in tests.iter().zip(outcomes) {
        groups.entry(&test.group).or_default().add(outcome);
        let path = relative(&options.test262, &test.path);
        let _ = match outcome {
            Outcome::Fail(reason) => writeln!(failures, "FAIL {path}: {reason}"),
            Outcome::Compile(reason) => writeln!(failures, "COMPILE {path}: {reason}"),
            Outcome::Timeout => writeln!(failures, "TIMEOUT {path}"),
            Outcome::Skip(reason) => writeln!(failures, "SKIP {path}: {reason}"),
            Outcome::Pass => Ok(()),
        };
    }
    match &options.failures {
        Some(file) => {
            if let Err(error) = fs::write(file, &failures) {
                return fail(&format!("cannot write {}: {error}", file.display()));
            }
        }
        None => print!("{failures}"),
    }
    let mut total = Counts::default();
    println!("| Directory | Tests | Pass | Fail | Compile | Timeout | Skip | Pass rate |");
    println!("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |");
    for (group, counts) in &groups {
        println!("{}", counts.row(group));
        total.merge(*counts);
    }
    println!("{}", total.row("**Total**"));
    if total.pass + total.skip == total.tests {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_inline_and_block_lists_and_negative() {
        let source = "/*---\ndescription: |\n  text: here\nincludes: [compareArray.js, propertyHelper.js]\nflags:\n  - onlyStrict # comment\nnegative:\n  phase: parse\n  type: SyntaxError\nfeatures: [Symbol]\n---*/\nx;";
        let meta = frontmatter(source);
        assert_eq!(meta.includes, ["compareArray.js", "propertyHelper.js"]);
        assert_eq!(meta.flags, ["onlyStrict"]);
        assert_eq!(meta.features, ["Symbol"]);
        let negative = meta.negative.unwrap_or_default();
        assert_eq!(
            (negative.phase.as_str(), negative.error.as_str()),
            ("parse", "SyntaxError")
        );
    }

    #[test]
    fn places_a_diagnostic_in_the_test_or_the_harness() {
        let diagnostic = Diagnostic {
            path: PathBuf::from("t1.js"),
            line: 105,
            column: 3,
            code: Code::Unsupported,
            message: "`yield*` is not supported".to_owned(),
        };
        assert_eq!(
            describe(&diagnostic, 100),
            "line 5: BOUY206: `yield*` is not supported"
        );
        assert_eq!(
            describe(&diagnostic, 200),
            "harness line 105: BOUY206: `yield*` is not supported"
        );
    }

    #[test]
    fn decides_negative_tests_by_their_phase() {
        let meta = frontmatter("/*---\nnegative:\n  phase: parse\n  type: SyntaxError\n---*/");
        let diagnostic = |code| Diagnostic {
            path: PathBuf::from("t1.js"),
            line: 1,
            column: 1,
            code,
            message: String::new(),
        };
        assert!(matches!(
            compile_failure(&meta, &[diagnostic(Code::Syntax)], 0),
            Outcome::Pass
        ));
        assert!(matches!(
            compile_failure(&meta, &[diagnostic(Code::Unsupported)], 0),
            Outcome::Fail(_)
        ));
        let runtime = frontmatter("/*---\nnegative:\n  phase: runtime\n  type: TypeError\n---*/");
        let run = |status: &str, stderr: &str| Run {
            status: status.to_owned(),
            stdout: String::new(),
            stderr: stderr.to_owned(),
        };
        assert!(matches!(
            classify(&runtime, &run("1", "Uncaught TypeError: x")),
            Outcome::Pass
        ));
        assert!(matches!(
            classify(&runtime, &run("0", "")),
            Outcome::Fail(_)
        ));
        assert_eq!(
            first_error("Uncaught Test262Error {\n  message: 'x'\n}\n"),
            "Uncaught Test262Error { message: 'x' }"
        );
    }
}
