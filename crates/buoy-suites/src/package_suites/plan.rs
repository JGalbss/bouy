//! The plan of a package suite: the test files of a checkout and the command line that runs
//! each one alone, derived from the `test` script of its `package.json` as npm runs it. The
//! plan names no package. It reads the script, follows `npm run` and `run-s`, drops the
//! wrappers `nyc`, `c8`, `cross-env`, and `npx`, and keeps each command that starts node or
//! a test runner that it knows: mocha, ava, tape, tap, jest, vitest, or uvu. Each runner
//! finds its files as its own defaults or the arguments of the script say. A command that
//! is no test runner, such as a linter, adds nothing, and a script that runs no known
//! runner gives the reason that the package has no plan.
//!
//! A runner bin runs as `<bin file> <options> <file>`, and node runs as `<node options>
//! <file>`, so the same command line runs under node for the oracle and under Buoy.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One test file of a package and the command line that runs it from the checkout.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Run {
    /// The path of the test file under the checkout, with `/`.
    pub file: String,
    /// The arguments of `node`, or of `buoy` in its node form.
    pub argv: Vec<String>,
}

/// The test runners that the plan knows, by the package that ships the bin.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Runner {
    Mocha,
    Ava,
    Tape,
    Tap,
    Jest,
    Vitest,
    Uvu,
}

impl Runner {
    fn of_package(name: &str) -> Option<Self> {
        Some(match name {
            "mocha" => Self::Mocha,
            "ava" => Self::Ava,
            "tape" => Self::Tape,
            "tap" => Self::Tap,
            "jest" | "jest-cli" => Self::Jest,
            "vitest" => Self::Vitest,
            "uvu" => Self::Uvu,
            _ => return None,
        })
    }

    /// The options of the runner that take the next argument as their value.
    fn value_options(self) -> &'static [&'static str] {
        match self {
            Self::Mocha => &MOCHA_VALUE_OPTIONS,
            Self::Ava => &AVA_VALUE_OPTIONS,
            Self::Tape | Self::Uvu => &TAPE_VALUE_OPTIONS,
            Self::Tap => &TAP_VALUE_OPTIONS,
            Self::Jest => &JEST_VALUE_OPTIONS,
            Self::Vitest => &VITEST_VALUE_OPTIONS,
        }
    }
}

// The options of each runner that take the next argument as their value.
const MOCHA_VALUE_OPTIONS: [&str; 33] = [
    "-R",
    "--reporter",
    "-O",
    "--reporter-option",
    "--reporter-options",
    "-u",
    "--ui",
    "-r",
    "--require",
    "-t",
    "--timeout",
    "--timeouts",
    "-s",
    "--slow",
    "-g",
    "--grep",
    "-f",
    "--fgrep",
    "--extension",
    "--file",
    "--ignore",
    "--exclude",
    "--config",
    "--package",
    "--global",
    "--globals",
    "-j",
    "--jobs",
    "--retries",
    "-n",
    "--node-option",
    "--spec",
    "--opts",
];
const AVA_VALUE_OPTIONS: [&str; 8] = [
    "-m",
    "--match",
    "-T",
    "--timeout",
    "-c",
    "--concurrency",
    "--node-arguments",
    "--config",
];
const TAPE_VALUE_OPTIONS: [&str; 4] = ["-r", "--require", "-i", "--ignore"];
const TAP_VALUE_OPTIONS: [&str; 27] = [
    "-t",
    "--timeout",
    "-R",
    "--reporter",
    "-j",
    "--jobs",
    "--coverage-map",
    "--nyc-arg",
    "--node-arg",
    "--test-arg",
    "--test-regex",
    "--test-ignore",
    "-o",
    "--output-file",
    "--output-dir",
    "-g",
    "--grep",
    "-T",
    "--test-env",
    "--save",
    "--plugin",
    "--include",
    "--exclude",
    "--before",
    "--after",
    "-C",
    "--config",
];
const JEST_VALUE_OPTIONS: [&str; 18] = [
    "--env",
    "--config",
    "-c",
    "--testTimeout",
    "--reporters",
    "--testNamePattern",
    "-t",
    "--testPathPattern",
    "--testPathIgnorePatterns",
    "--rootDir",
    "--roots",
    "--selectProjects",
    "--maxWorkers",
    "-w",
    "--coverageReporters",
    "--testEnvironment",
    "--setupFiles",
    "--setupFilesAfterEnv",
];
const VITEST_VALUE_OPTIONS: [&str; 13] = [
    "--project",
    "--config",
    "-c",
    "--root",
    "-r",
    "--dir",
    "--environment",
    "--pool",
    "--reporter",
    "-t",
    "--testNamePattern",
    "--exclude",
    "--coverage.provider",
];

/// One command of the script that runs tests.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Command {
    /// `node <options> <script> <args>`, or `node <options> --test <patterns>`.
    Node {
        options: Vec<String>,
        rest: Vec<String>,
    },
    /// A runner bin: the path of its file under the checkout, the options, and the
    /// positional arguments, which name files, directories, or globs.
    Bin {
        runner: Runner,
        entry: String,
        options: Vec<String>,
        positional: Vec<String>,
    },
}

/// What the plan reads of a checkout: its `package.json`, the bins of its dependencies,
/// and its files.
#[derive(Debug)]
struct Checkout {
    root: PathBuf,
    manifest: Value,
    /// The bins of the direct dependencies: bin name, the package, and the path of the bin
    /// file under the checkout.
    bins: BTreeMap<String, (String, String)>,
    /// Every file outside `node_modules` and `.git`, with `/`.
    files: Vec<String>,
}

/// The node options that take the next argument as their value, which a script uses.
const NODE_VALUE_OPTIONS: [&str; 10] = [
    "-r",
    "--require",
    "--import",
    "--loader",
    "--experimental-loader",
    "--test-reporter",
    "--test-reporter-destination",
    "--test-name-pattern",
    "--test-concurrency",
    "--conditions",
];

/// The script commands that run another script of the package.
const SCRIPT_RUNNERS: [&str; 3] = ["npm", "pnpm", "yarn"];

/// The wrappers that run the command after their own options.
const WRAPPERS: [&str; 2] = ["nyc", "c8"];

/// The depth of nested `npm run` that the plan follows.
const DEPTH: usize = 6;

/// The extensions of the test files of node's own runner, of Node 25 with type stripping.
const NODE_TEST_EXTENSIONS: [&str; 6] = ["js", "cjs", "mjs", "ts", "cts", "mts"];

/// The runs of the checkout at `checkout`, or why it has none.
///
/// # Errors
///
/// When the checkout has no `package.json`, no `test` script, or a script that runs no test
/// runner that the plan knows, or when the runners find no file.
pub fn derive(checkout: &Path) -> Result<Vec<Run>, String> {
    let text = fs::read_to_string(checkout.join("package.json"))
        .map_err(|error| format!("no package.json: {error}"))?;
    let manifest: Value =
        serde_json::from_str(&text).map_err(|error| format!("package.json: {error}"))?;
    let read = Checkout {
        root: checkout.to_path_buf(),
        bins: bins(checkout, &manifest),
        files: files_below(checkout, ""),
        manifest,
    };
    let script = read
        .manifest
        .pointer("/scripts/test")
        .and_then(Value::as_str)
        .ok_or("no test script")?;
    let mut commands = Vec::new();
    read.commands(script, 0, &mut commands);
    if commands.is_empty() {
        return Err(format!(
            "the test script runs no test runner that the plan knows: {script}"
        ));
    }
    let mut runs: Vec<Run> = Vec::new();
    let mut seen = BTreeSet::new();
    for command in &commands {
        for run in read.runs(command, checkout) {
            if seen.insert(run.file.clone()) {
                runs.push(run);
            }
        }
    }
    if runs.is_empty() {
        return Err(format!("the test runners find no file: {script}"));
    }
    runs.sort_by(|a, b| a.file.cmp(&b.file));
    Ok(runs)
}

impl Checkout {
    /// The test commands of `script`, in order.
    fn commands(&self, script: &str, depth: usize, found: &mut Vec<Command>) {
        if depth > DEPTH {
            return;
        }
        for words in segments(script) {
            self.command(&words, depth, found);
        }
    }

    /// The test commands of one simple command of a script.
    fn command(&self, words: &[String], depth: usize, found: &mut Vec<Command>) {
        let words: Vec<&str> = words
            .iter()
            .map(String::as_str)
            .skip_while(|word| is_assignment(word))
            .collect();
        let Some((&first, rest)) = words.split_first() else {
            return;
        };
        let owned = |words: &[&str]| words.iter().map(|word| (*word).to_owned()).collect();
        match first {
            "cross-env" | "env" => {
                let rest: Vec<String> = owned(rest);
                self.command(&rest, depth, found);
            }
            "npx" => {
                let rest: Vec<&str> = rest
                    .iter()
                    .copied()
                    .skip_while(|word| word.starts_with('-'))
                    .collect();
                self.command(&owned(&rest), depth, found);
            }
            _ if WRAPPERS.contains(&first) => {
                let start = rest.iter().position(|word| {
                    *word == "node"
                        || SCRIPT_RUNNERS.contains(word)
                        || self.bins.contains_key(*word)
                });
                if let Some(start) = start {
                    self.command(&owned(&rest[start..]), depth, found);
                }
            }
            _ if SCRIPT_RUNNERS.contains(&first) => {
                for name in script_names(rest) {
                    if let Some(script) = self.script(&name) {
                        self.commands(&script, depth + 1, found);
                    }
                }
            }
            "run-s" | "run-p" | "npm-run-all" => {
                for pattern in rest.iter().filter(|word| !word.starts_with('-')) {
                    for script in self.scripts_matching(pattern) {
                        self.commands(&script, depth + 1, found);
                    }
                }
            }
            "node" => found.extend(node_command(rest)),
            _ => {
                let Some((package, entry)) = self.bins.get(first) else {
                    return;
                };
                let Some(runner) = Runner::of_package(package) else {
                    return;
                };
                let (options, positional) = split_arguments(rest, runner.value_options());
                found.push(Command::Bin {
                    runner,
                    entry: entry.clone(),
                    options,
                    positional,
                });
            }
        }
    }

    fn script(&self, name: &str) -> Option<String> {
        let scripts = self.manifest.get("scripts")?;
        let name = match name {
            "t" | "tst" => "test",
            other => other,
        };
        Some(scripts.get(name)?.as_str()?.to_owned())
    }

    /// The scripts whose names match `pattern` of `run-s`, where `*` matches within one
    /// `:` part and `**` matches any text.
    fn scripts_matching(&self, pattern: &str) -> Vec<String> {
        let Some(scripts) = self.manifest.get("scripts").and_then(Value::as_object) else {
            return Vec::new();
        };
        let matcher = Glob::new(&pattern.replace(':', "/"));
        scripts
            .iter()
            .filter(|(name, _)| matcher.matches(&name.replace(':', "/")))
            .filter_map(|(_, script)| script.as_str().map(str::to_owned))
            .collect()
    }

    /// The runs of one command: one for each file that it finds.
    fn runs(&self, command: &Command, checkout: &Path) -> Vec<Run> {
        match command {
            Command::Node { options, rest } => {
                if options.iter().any(|option| option == "--test") {
                    let files = if rest.is_empty() {
                        self.files_where(is_node_test_default)
                    } else {
                        self.expand(rest)
                    };
                    return files
                        .into_iter()
                        .map(|file| Run {
                            argv: [options.clone(), vec![file.clone()]].concat(),
                            file,
                        })
                        .collect();
                }
                let Some((script, arguments)) = rest.split_first() else {
                    return Vec::new();
                };
                // A script that the test script runs to build or to set up is no test file.
                let script = script.trim_start_matches("./").to_owned();
                if !checkout.join(&script).is_file() || !script.to_lowercase().contains("test") {
                    return Vec::new();
                }
                vec![Run {
                    argv: [options.clone(), vec![script.clone()], arguments.to_vec()].concat(),
                    file: script,
                }]
            }
            Command::Bin {
                runner,
                entry,
                options,
                positional,
            } => self.bin_runs(*runner, entry, options, positional),
        }
    }

    fn bin_runs(
        &self,
        runner: Runner,
        entry: &str,
        options: &[String],
        positional: &[String],
    ) -> Vec<Run> {
        let run = |file: String, before: &[String], after: &[String]| Run {
            argv: [
                vec![entry.to_owned()],
                before.to_vec(),
                options.to_vec(),
                vec![file.clone()],
                after.to_vec(),
            ]
            .concat(),
            file,
        };
        match runner {
            Runner::Uvu => self.uvu_runs(entry, options, positional),
            Runner::Vitest => {
                // `vitest run <filters>`: the positional words after the command filter the
                // default files by their path.
                let (command, filters) = match positional.split_first() {
                    Some((first, rest)) if ["run", "watch", "dev"].contains(&first.as_str()) => {
                        (vec!["run".to_owned()], rest)
                    }
                    _ => (vec!["run".to_owned()], positional),
                };
                self.files_where(is_vitest_default)
                    .into_iter()
                    .filter(|file| {
                        filters.is_empty()
                            || filters
                                .iter()
                                .any(|filter| file.contains(filter.trim_start_matches("./")))
                    })
                    .map(|file| run(file, &command, &[]))
                    .collect()
            }
            Runner::Jest => {
                let files = if positional.is_empty() {
                    self.files_where(is_jest_default)
                } else {
                    self.expand(positional)
                };
                files.into_iter().map(|file| run(file, &[], &[])).collect()
            }
            Runner::Mocha => self
                .mocha_files(options, positional)
                .into_iter()
                .map(|file| run(file, &[], &[]))
                .collect(),
            Runner::Ava => {
                let files = if positional.is_empty() {
                    self.ava_files()
                } else {
                    self.expand(positional)
                };
                files.into_iter().map(|file| run(file, &[], &[])).collect()
            }
            Runner::Tap => {
                // `tap run <files>` of tap 18 and later is `tap <files>`.
                let positional = match positional.split_first() {
                    Some((first, rest)) if first == "run" => rest,
                    _ => positional,
                };
                let files = if positional.is_empty() {
                    self.files_where(|file| {
                        is_tap_default(file)
                            && !file.split('/').any(|part| {
                                [".tap", ".nyc_output", "tap-snapshots"].contains(&part)
                            })
                    })
                } else {
                    self.expand(positional)
                };
                files.into_iter().map(|file| run(file, &[], &[])).collect()
            }
            Runner::Tape => self
                .expand(positional)
                .into_iter()
                .map(|file| run(file, &[], &[]))
                .collect(),
        }
    }

    /// The files of mocha: the positional specs, or the `spec` of its configuration, or
    /// `./test/*.{js,cjs,mjs}`. A directory gives its files with the extensions, and its
    /// subdirectories too with `--recursive`.
    fn mocha_files(&self, options: &[String], positional: &[String]) -> Vec<String> {
        let mut specs = positional.to_vec();
        if specs.is_empty() {
            specs = self.mocha_config_spec();
        }
        if specs.is_empty() {
            specs.push("test".to_owned());
        }
        let recursive = options.iter().any(|option| option == "--recursive");
        let mut extensions: Vec<String> = vec!["js".to_owned(), "cjs".to_owned(), "mjs".to_owned()];
        let mut words = options.iter();
        while let Some(option) = words.next() {
            if option == "--extension" {
                extensions.extend(
                    words
                        .next()
                        .map(|value| value.trim_start_matches('.').to_owned()),
                );
            } else if let Some(value) = option.strip_prefix("--extension=") {
                extensions.push(value.trim_start_matches('.').to_owned());
            }
        }
        let mut found = Vec::new();
        for spec in specs {
            let spec = spec.trim_start_matches("./").trim_end_matches('/');
            if self.files.iter().any(|file| file == spec) {
                found.push(spec.to_owned());
                continue;
            }
            let prefix = format!("{spec}/");
            let in_directory: Vec<String> = self
                .files
                .iter()
                .filter(|file| {
                    file.strip_prefix(&prefix).is_some_and(|below| {
                        (recursive || !below.contains('/'))
                            && extensions
                                .iter()
                                .any(|extension| has_extension(below, extension))
                    })
                })
                .cloned()
                .collect();
            if !in_directory.is_empty() {
                found.extend(in_directory);
                continue;
            }
            let globbed = self.expand(&[spec.to_owned()]);
            if !globbed.is_empty() {
                found.extend(globbed);
                continue;
            }
            // Mocha tries a spec that names no file with each extension, so `test` can
            // name `test.js`.
            found.extend(
                extensions
                    .iter()
                    .map(|extension| format!("{spec}.{extension}"))
                    .filter(|file| self.files.contains(file)),
            );
        }
        found.sort();
        found.dedup();
        found
    }

    /// The `spec` of `package.json` `mocha`, `.mocharc.json`, `.mocharc.jsonc`, or
    /// `.mocharc.yml`. A configuration in JavaScript gives none.
    fn mocha_config_spec(&self) -> Vec<String> {
        let strings = |value: &Value| match value {
            Value::String(text) => vec![text.clone()],
            Value::Array(items) => items
                .iter()
                .filter_map(|item| item.as_str().map(str::to_owned))
                .collect(),
            _ => Vec::new(),
        };
        if let Some(spec) = self.manifest.pointer("/mocha/spec") {
            return strings(spec);
        }
        self.config_spec_of_files()
            .map(|spec| strings(&spec))
            .unwrap_or_default()
    }

    fn config_spec_of_files(&self) -> Option<Value> {
        let root = &self.root;
        for name in [".mocharc.json", ".mocharc.jsonc"] {
            if let Ok(text) = fs::read_to_string(root.join(name)) {
                let text: String = text
                    .lines()
                    .filter(|line| !line.trim_start().starts_with("//"))
                    .collect::<Vec<_>>()
                    .join("\n");
                return serde_json::from_str::<Value>(&text)
                    .ok()?
                    .get("spec")
                    .cloned();
            }
        }
        for name in [".mocharc.yml", ".mocharc.yaml"] {
            if let Ok(text) = fs::read_to_string(root.join(name)) {
                return yaml_list(&text, "spec");
            }
        }
        None
    }

    /// The files of ava: `ava.files` of `package.json`, or its defaults. Files and
    /// directories that start with `_`, and the helper and fixture directories, are not
    /// test files.
    fn ava_files(&self) -> Vec<String> {
        let patterns: Vec<String> = self
            .manifest
            .pointer("/ava/files")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default();
        let base = if patterns.is_empty() {
            self.files_where(is_ava_default)
        } else {
            self.expand(&patterns)
        };
        base.into_iter()
            .filter(|file| !is_ava_helper(file))
            .collect()
    }

    /// The runs of uvu: `uvu <dir> <pattern>` finds the files under `dir` that match its
    /// default pattern, apart from the `-i` patterns. Each file runs as `uvu <dir> <its
    /// path>`, which uvu reads as a pattern.
    fn uvu_runs(&self, entry: &str, options: &[String], positional: &[String]) -> Vec<Run> {
        let directory = positional.first().map_or(String::new(), |dir| {
            dir.trim_start_matches("./")
                .trim_end_matches('/')
                .to_owned()
        });
        let mut ignored = Vec::new();
        let mut words = options.iter();
        while let Some(option) = words.next() {
            if option == "-i" || option == "--ignore" {
                ignored.extend(words.next().cloned());
            }
        }
        let prefix = if directory.is_empty() || directory == "." {
            String::new()
        } else {
            format!("{directory}/")
        };
        // With a directory, uvu runs each `\w+.<extension>` file below it.
        let named = if prefix.is_empty() {
            is_tap_default
        } else {
            is_uvu_file
        };
        self.files
            .iter()
            .filter_map(|file| {
                let below = file.strip_prefix(&prefix)?;
                let applies = named(below)
                    && !ignored
                        .iter()
                        .any(|pattern| below.contains(pattern.as_str()));
                applies.then(|| Run {
                    argv: [
                        vec![entry.to_owned(), directory.clone(), escape_pattern(below)],
                        options.to_vec(),
                    ]
                    .concat(),
                    file: file.clone(),
                })
            })
            .collect()
    }

    fn files_where(&self, test: fn(&str) -> bool) -> Vec<String> {
        self.files
            .iter()
            .filter(|file| test(file))
            .cloned()
            .collect()
    }

    /// The files that the paths, directories, and globs of `patterns` name. A pattern that
    /// starts with `!` removes the files that it matches.
    fn expand(&self, patterns: &[String]) -> Vec<String> {
        let mut found = BTreeSet::new();
        for pattern in patterns.iter().filter(|pattern| !pattern.starts_with('!')) {
            let pattern = pattern.trim_start_matches("./").trim_end_matches('/');
            let prefix = format!("{pattern}/");
            let glob = Glob::new(pattern);
            for file in &self.files {
                if file == pattern || glob.matches(file) || is_script_below(file, &prefix) {
                    found.insert(file.clone());
                }
            }
        }
        for pattern in patterns
            .iter()
            .filter_map(|pattern| pattern.strip_prefix('!'))
        {
            let glob = Glob::new(pattern.trim_start_matches("./"));
            found.retain(|file| !glob.matches(file));
        }
        found.into_iter().collect()
    }
}

/// Whether `file` is a JavaScript or TypeScript file below the directory `prefix`.
fn is_script_below(file: &str, prefix: &str) -> bool {
    file.starts_with(prefix)
        && ["js", "cjs", "mjs", "ts", "cts", "mts", "jsx", "tsx"]
            .iter()
            .any(|extension| has_extension(file, extension))
}

/// A uvu pattern, a regular expression, that matches only `path`.
fn escape_pattern(path: &str) -> String {
    let mut pattern = String::from("^");
    for character in path.chars() {
        if "\\^$.|?*+()[]{}/".contains(character) {
            pattern.push('\\');
        }
        pattern.push(character);
    }
    pattern.push('$');
    pattern
}

/// The node command of `node <rest>`: its options before the script, then the script and
/// its arguments, or the patterns of `--test`.
fn node_command(rest: &[&str]) -> Option<Command> {
    let mut options = Vec::new();
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        if !word.starts_with('-') {
            let remaining: Vec<String> = std::iter::once(*word)
                .chain(words.copied())
                .map(str::to_owned)
                .collect();
            return Some(Command::Node {
                options,
                rest: remaining,
            });
        }
        options.push((*word).to_owned());
        if NODE_VALUE_OPTIONS.contains(word) {
            options.extend(words.next().map(|value| (*value).to_owned()));
        }
    }
    options
        .iter()
        .any(|option| option == "--test")
        .then_some(Command::Node {
            options,
            rest: Vec::new(),
        })
}

/// The script names of `npm run <name>`, `npm test`, `pnpm <name>`, or `yarn <name>`.
fn script_names(rest: &[&str]) -> Vec<String> {
    let words: Vec<&str> = rest
        .iter()
        .copied()
        .filter(|word| !word.starts_with('-'))
        .collect();
    match words.as_slice() {
        ["run" | "run-script" | "rum" | "urn", name, ..] => vec![(*name).to_owned()],
        ["test" | "t" | "tst", ..] => vec!["test".to_owned()],
        [name, ..] if !["install", "exec", "audit", "-w"].contains(name) => {
            vec![(*name).to_owned()]
        }
        _ => Vec::new(),
    }
}

/// Splits the arguments of a runner into its options, with their values, and the
/// positional words.
fn split_arguments(words: &[&str], value_options: &[&str]) -> (Vec<String>, Vec<String>) {
    let mut options = Vec::new();
    let mut positional = Vec::new();
    let mut words = words.iter();
    while let Some(word) = words.next() {
        if word.starts_with('-') && *word != "-" {
            options.push((*word).to_owned());
            if value_options.contains(word) {
                options.extend(words.next().map(|value| (*value).to_owned()));
            }
        } else {
            positional.push((*word).to_owned());
        }
    }
    (options, positional)
}

fn is_assignment(word: &str) -> bool {
    word.split_once('=').is_some_and(|(name, _)| {
        !name.is_empty()
            && name
                .chars()
                .all(|character| character.is_ascii_alphanumeric() || character == '_')
    })
}

/// The simple commands of a script, as words with the quotes removed. A pipeline keeps only
/// its first command, which runs the tests; the others read its output.
fn segments(script: &str) -> Vec<Vec<String>> {
    let mut commands = Vec::new();
    let mut words: Vec<String> = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut piped = false;
    let mut characters = script.chars().peekable();
    let mut end = |words: &mut Vec<String>, piped: bool| {
        if !piped && !words.is_empty() {
            commands.push(std::mem::take(words));
        }
        words.clear();
    };
    while let Some(character) = characters.next() {
        match character {
            '\'' | '"' => {
                in_word = true;
                for quoted in characters.by_ref() {
                    if quoted == character {
                        break;
                    }
                    word.push(quoted);
                }
            }
            '\\' => {
                in_word = true;
                word.extend(characters.next());
            }
            ' ' | '\t' | '\n' => {
                if in_word {
                    words.push(std::mem::take(&mut word));
                    in_word = false;
                }
            }
            '&' | '|' | ';' => {
                if in_word {
                    words.push(std::mem::take(&mut word));
                    in_word = false;
                }
                let doubled = characters.peek() == Some(&character);
                if doubled {
                    characters.next();
                }
                end(&mut words, piped);
                piped = character == '|' && !doubled;
            }
            other => {
                in_word = true;
                word.push(other);
            }
        }
    }
    if in_word {
        words.push(word);
    }
    end(&mut words, piped);
    commands
}

/// The bins of the direct dependencies of the checkout: each bin name with its package and
/// the path of its file under the checkout.
fn bins(checkout: &Path, manifest: &Value) -> BTreeMap<String, (String, String)> {
    let mut found = BTreeMap::new();
    let names: BTreeSet<&String> = ["dependencies", "devDependencies"]
        .iter()
        .filter_map(|field| manifest.get(*field)?.as_object())
        .flat_map(|dependencies| dependencies.keys())
        .collect();
    for name in names {
        let directory = format!("node_modules/{name}");
        let Ok(text) = fs::read_to_string(checkout.join(&directory).join("package.json")) else {
            continue;
        };
        let Ok(dependency) = serde_json::from_str::<Value>(&text) else {
            continue;
        };
        let base = name.rsplit('/').next().unwrap_or(name);
        let entries: Vec<(String, String)> = match dependency.get("bin") {
            Some(Value::String(path)) => vec![(base.to_owned(), path.clone())],
            Some(Value::Object(map)) => map
                .iter()
                .filter_map(|(bin, path)| Some((bin.clone(), path.as_str()?.to_owned())))
                .collect(),
            _ => Vec::new(),
        };
        for (bin, path) in entries {
            let path = format!("{directory}/{}", path.trim_start_matches("./"));
            found.entry(bin).or_insert_with(|| (name.clone(), path));
        }
    }
    found
}

/// The files below `relative` of `root`, outside `node_modules`, `.git`, and the build
/// directories of Buoy, as paths with `/`, sorted.
fn files_below(root: &Path, relative: &str) -> Vec<String> {
    let Ok(entries) = fs::read_dir(root.join(relative)) else {
        return Vec::new();
    };
    let mut found = Vec::new();
    for entry in entries.filter_map(Result::ok) {
        let name = entry.file_name().to_string_lossy().into_owned();
        if [".git", "node_modules", ".buoy"].contains(&name.as_str()) {
            continue;
        }
        let child = if relative.is_empty() {
            name
        } else {
            format!("{relative}/{name}")
        };
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if kind.is_dir() {
            found.extend(files_below(root, &child));
        } else if kind.is_file() {
            found.push(child);
        }
    }
    found.sort();
    found
}

fn has_extension(file: &str, extension: &str) -> bool {
    file.rsplit_once('.')
        .is_some_and(|(stem, found)| !stem.is_empty() && found == extension)
}

/// The extension of `file` and the path before it.
fn split_extension(file: &str) -> Option<(&str, &str)> {
    let name_start = file.rfind('/').map_or(0, |slash| slash + 1);
    let dot = file[name_start..].rfind('.')? + name_start;
    (dot > name_start).then(|| (&file[..dot], &file[dot + 1..]))
}

/// Whether the last `.` part of `name`, after a part of its own, is one of `parts`, as
/// `a.test` ends with `test`.
fn ends_with_part(name: &str, parts: &[&str]) -> bool {
    name.rsplit_once('.')
        .is_some_and(|(before, last)| !before.is_empty() && parts.contains(&last))
}

fn components(file: &str) -> impl Iterator<Item = &str> {
    let directories = file.rsplit_once('/').map_or("", |(directory, _)| directory);
    directories.split('/').filter(|part| !part.is_empty())
}

/// The default pattern of tap and of uvu,
/// `((\/|^)(tests?|__tests?__)\/.*|\.(tests?|spec)|^\/?tests?)\.([mc]js|[jt]sx?)$`.
fn is_tap_default(file: &str) -> bool {
    let Some((stem, extension)) = split_extension(file) else {
        return false;
    };
    if !["mjs", "cjs", "js", "jsx", "ts", "tsx"].contains(&extension) {
        return false;
    }
    let test_directory =
        components(file).any(|part| ["test", "tests", "__test__", "__tests__"].contains(&part));
    test_directory
        || ends_with_part(stem, &["test", "tests", "spec"])
        || ["test", "tests"].contains(&stem)
}

/// A file of `uvu <dir>`: `(((?:[^\/]*(?:\/|$))*)[\\\/])?\w+\.([mc]js|[jt]sx?)$`.
fn is_uvu_file(file: &str) -> bool {
    split_extension(file).is_some_and(|(stem, extension)| {
        ["mjs", "cjs", "js", "jsx", "ts", "tsx"].contains(&extension)
            && stem.rsplit('/').next().is_some_and(|name| {
                name.chars()
                    .all(|character| character.is_alphanumeric() || character == '_')
            })
    })
}

/// The defaults of jest, `**/__tests__/**/*.[jt]s?(x)` and `**/?(*.)+(spec|test).[jt]s?(x)`.
fn is_jest_default(file: &str) -> bool {
    let Some((stem, extension)) = split_extension(file) else {
        return false;
    };
    if !["js", "jsx", "ts", "tsx"].contains(&extension) {
        return false;
    }
    let name = stem.rsplit('/').next().unwrap_or(stem);
    components(file).any(|part| part == "__tests__")
        || ["test", "spec"].contains(&name)
        || ends_with_part(name, &["test", "spec"])
}

/// The default of vitest, `**/*.{test,spec}.?(c|m)[jt]s?(x)`.
fn is_vitest_default(file: &str) -> bool {
    let Some((stem, extension)) = split_extension(file) else {
        return false;
    };
    ["js", "cjs", "mjs", "ts", "cts", "mts", "jsx", "tsx"].contains(&extension)
        && ends_with_part(stem, &["test", "spec"])
}

/// The defaults of ava: `test.js`, `src/test.js`, `source/test.js`, `**/test-*.js`,
/// `**/*.spec.js`, `**/*.test.js`, `**/test/**/*.js`, `**/tests/**/*.js`, and
/// `**/__tests__/**/*.js`, with the extensions `js`, `cjs`, and `mjs`.
fn is_ava_default(file: &str) -> bool {
    let Some((stem, extension)) = split_extension(file) else {
        return false;
    };
    if !["js", "cjs", "mjs"].contains(&extension) {
        return false;
    }
    let name = stem.rsplit('/').next().unwrap_or(stem);
    ["test", "src/test", "source/test"].contains(&stem)
        || name.starts_with("test-")
        || ends_with_part(name, &["spec", "test"])
        || components(file).any(|part| ["test", "tests", "__tests__"].contains(&part))
}

/// The files that ava never runs as tests: a name that starts with `_`, and the helper and
/// fixture directories of a test directory.
fn is_ava_helper(file: &str) -> bool {
    file.split('/').any(|part| {
        part.starts_with('_') && part != "__tests__"
            || [
                "helper",
                "helpers",
                "fixture",
                "fixtures",
                "__helper__",
                "__helpers__",
                "__fixture__",
                "__fixtures__",
            ]
            .contains(&part)
    })
}

/// The defaults of `node --test`: `**/*.test.<ext>`, `**/*-test.<ext>`, `**/*_test.<ext>`,
/// `**/test-*.<ext>`, `**/test.<ext>`, and `**/test/**/*.<ext>`.
fn is_node_test_default(file: &str) -> bool {
    let Some((stem, extension)) = split_extension(file) else {
        return false;
    };
    if !NODE_TEST_EXTENSIONS.contains(&extension) {
        return false;
    }
    let name = stem.rsplit('/').next().unwrap_or(stem);
    name == "test"
        || name.starts_with("test-")
        || [".test", "-test", "_test"]
            .iter()
            .any(|suffix| name.ends_with(suffix))
        || components(file).any(|part| part == "test")
}

/// The list or the single value of `key` at the top of a YAML file, as JSON.
fn yaml_list(text: &str, key: &str) -> Option<Value> {
    let mut lines = text.lines();
    let prefix = format!("{key}:");
    lines.by_ref().find(|line| line.starts_with(&prefix))?;
    let inline = text
        .lines()
        .find(|line| line.starts_with(&prefix))?
        .trim_start_matches(&prefix)
        .trim()
        .trim_matches(|character| character == '\'' || character == '"')
        .to_owned();
    if !inline.is_empty() {
        return Some(Value::String(inline));
    }
    let items: Vec<Value> = lines
        .map_while(|line| line.trim_start().strip_prefix("- "))
        .map(|item| Value::String(item.trim().trim_matches(['\'', '"']).to_owned()))
        .collect();
    Some(Value::Array(items))
}

/// A glob with `**`, `*`, `?`, `[...]`, and `{a,b}`, matched against a path with `/`.
#[derive(Debug)]
struct Glob {
    alternatives: Vec<Vec<String>>,
}

impl Glob {
    fn new(pattern: &str) -> Self {
        Self {
            alternatives: expand_braces(pattern)
                .into_iter()
                .map(|alternative| alternative.split('/').map(str::to_owned).collect())
                .collect(),
        }
    }

    fn matches(&self, path: &str) -> bool {
        let parts: Vec<&str> = path.split('/').collect();
        self.alternatives
            .iter()
            .any(|pattern| matches_parts(pattern, &parts))
    }
}

fn expand_braces(pattern: &str) -> Vec<String> {
    let Some(open) = pattern.find('{') else {
        return vec![pattern.to_owned()];
    };
    let mut depth = 0;
    let mut close = None;
    for (index, character) in pattern[open..].char_indices() {
        match character {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    close = Some(open + index);
                    break;
                }
            }
            _ => {}
        }
    }
    let Some(close) = close else {
        return vec![pattern.to_owned()];
    };
    let (head, inner, tail) = (
        &pattern[..open],
        &pattern[open + 1..close],
        &pattern[close + 1..],
    );
    let mut options = Vec::new();
    let mut depth = 0;
    let mut start = 0;
    for (index, character) in inner.char_indices() {
        match character {
            '{' => depth += 1,
            '}' => depth -= 1,
            ',' if depth == 0 => {
                options.push(&inner[start..index]);
                start = index + 1;
            }
            _ => {}
        }
    }
    options.push(&inner[start..]);
    options
        .into_iter()
        .flat_map(|option| expand_braces(&format!("{head}{option}{tail}")))
        .collect()
}

fn matches_parts(pattern: &[String], parts: &[&str]) -> bool {
    match pattern.split_first() {
        None => parts.is_empty(),
        Some((first, rest)) if first == "**" => {
            (0..=parts.len()).any(|skip| matches_parts(rest, &parts[skip..]))
        }
        Some((first, rest)) => parts.split_first().is_some_and(|(part, others)| {
            matches_part(first.as_bytes(), part.as_bytes()) && matches_parts(rest, others)
        }),
    }
}

fn matches_part(pattern: &[u8], text: &[u8]) -> bool {
    match pattern.split_first() {
        None => text.is_empty(),
        Some((b'*', rest)) => (0..=text.len()).any(|skip| matches_part(rest, &text[skip..])),
        Some((b'?', rest)) => !text.is_empty() && matches_part(rest, &text[1..]),
        Some((b'[', rest)) => {
            let Some(close) = rest.iter().position(|byte| *byte == b']') else {
                return text.first() == Some(&b'[') && matches_part(rest, &text[1..]);
            };
            let (class, after) = (&rest[..close], &rest[close + 1..]);
            let Some((character, others)) = text.split_first() else {
                return false;
            };
            let (negated, class) = match class.split_first() {
                Some((b'!' | b'^', class)) => (true, class),
                _ => (false, class),
            };
            let mut inside = false;
            let mut index = 0;
            while index < class.len() {
                if index + 2 < class.len() && class[index + 1] == b'-' {
                    inside |= (class[index]..=class[index + 2]).contains(character);
                    index += 3;
                } else {
                    inside |= class[index] == *character;
                    index += 1;
                }
            }
            inside != negated && matches_part(after, others)
        }
        Some((byte, rest)) => text.first() == Some(byte) && matches_part(rest, &text[1..]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(script: &str) -> Vec<Vec<String>> {
        segments(script)
    }

    #[test]
    fn a_script_splits_into_its_commands() {
        assert_eq!(
            words("xo && nyc ava 'test/**/*.js' ; tsd"),
            vec![
                vec!["xo".to_owned()],
                vec![
                    "nyc".to_owned(),
                    "ava".to_owned(),
                    "test/**/*.js".to_owned()
                ],
                vec!["tsd".to_owned()],
            ]
        );
        assert_eq!(
            words("nyc --silent node test.js | tap -c -"),
            vec![vec![
                "nyc".to_owned(),
                "--silent".to_owned(),
                "node".to_owned(),
                "test.js".to_owned()
            ]]
        );
    }

    #[test]
    fn globs_match_as_the_runners_match_them() {
        let glob = Glob::new("test/**/*.{js,cjs}");
        assert!(glob.matches("test/a.js"));
        assert!(glob.matches("test/x/y/a.cjs"));
        assert!(!glob.matches("test/a.ts"));
        assert!(!glob.matches("lib/a.js"));
        assert!(Glob::new("test/[a-c]*.js").matches("test/b1.js"));
        assert!(!Glob::new("test/[!a-c]*.js").matches("test/b1.js"));
        assert!(Glob::new("test:*").matches("test:unit"));
    }

    #[test]
    fn the_defaults_of_the_runners_find_their_files() {
        assert!(is_tap_default("test/index.js"));
        assert!(is_tap_default("lib/a.test.ts"));
        assert!(!is_tap_default("lib/a.js"));
        assert!(is_jest_default("src/__tests__/a.ts"));
        assert!(is_jest_default("index.test.js"));
        assert!(!is_jest_default("test/a.js"));
        assert!(is_vitest_default("test/a.spec.mts"));
        assert!(is_ava_default("test.js"));
        assert!(is_ava_default("test/foo.js"));
        assert!(is_ava_helper("test/helpers/a.js"));
        assert!(is_ava_helper("test/_util.js"));
        assert!(is_node_test_default("tests/a.test.mjs"));
        assert!(is_node_test_default("test/a.ts"));
        assert!(!is_node_test_default("lib/a.js"));
    }

    #[test]
    fn node_and_runner_arguments_split_into_options_and_files() {
        assert_eq!(
            node_command(&["--test", "--test-reporter", "spec"]),
            Some(Command::Node {
                options: vec![
                    "--test".to_owned(),
                    "--test-reporter".to_owned(),
                    "spec".to_owned()
                ],
                rest: Vec::new(),
            })
        );
        let (options, positional) = split_arguments(
            &["--reporter", "spec", "--check-leaks", "test/"],
            Runner::Mocha.value_options(),
        );
        assert_eq!(options, ["--reporter", "spec", "--check-leaks"]);
        assert_eq!(positional, ["test/"]);
        assert_eq!(
            script_names(&["run", "--silent", "tests-only"]),
            ["tests-only"]
        );
        assert_eq!(escape_pattern("a/b.js"), "^a\\/b\\.js$");
    }
}
