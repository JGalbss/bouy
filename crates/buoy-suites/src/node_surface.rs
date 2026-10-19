//! The API surface of Node (section 5.7.1 of docs/design/testing.md).
//! `scripts/node-surface.sh` records each entry of the pinned Node in `tests/node/surface.json`.
//! This runner writes one program for each group of entries, a module such as `node:fs` or a
//! global such as `Buffer`. The program calls `probe` of `tests/node/surface.ts` with the
//! value of the group, and the runner compares each shape that it prints with the manifest:
//! an entry passes when it exists with the same `typeof` and `length`. An entry of
//! `tests/node/never.txt` takes the outcome `never`. The expectation file and the summary in
//! `tests/node/surface` hold the documented entries, deprecated ones included, so the
//! dashboard shows the documented entries present over all documented entries of each group.

use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use serde::Deserialize;

use crate::buoy_env;
use crate::comparison::{self, Comparison, Origin};
use crate::expectations::{self, Entry, Expectations, PLATFORM};
use crate::outcome::{Facts, Outcome, RunResult, classify};
use crate::summary::{self, Counts, Destination, Results, Summary, TestResult};

/// The name of the suite in `summary.json`, `results.json`, and the comment.
pub const SUITE: &str = "node-surface";

/// The reviewed `never` list, relative to the repository root.
pub const NEVER: &str = "tests/node/never.txt";

/// The command that rewrites the expectation file and the summary.
pub const UPDATE: &str = "cargo build --release -p buoy-cli && cargo run --release -p buoy-suites -- node-surface --update";

/// The names of the `CommonJS` module scope. Their program is a `CommonJS` module.
const MODULE_SCOPE: [&str; 5] = ["__dirname", "__filename", "exports", "module", "require"];

/// The lines of each list of the report, and the failure reports that it prints in full.
const REPORT_LINES: usize = 50;
const REPORTED_RUNS: usize = 10;

#[derive(Debug)]
pub struct Options {
    /// `tests/node`: `surface.json`, `surface.ts`, `never.txt`, and `surface/` with the
    /// expectation file and the summary.
    pub directory: PathBuf,
    /// `target/suites/node-surface`: the programs, the regenerated files, `results.json`,
    /// and `comment.md`.
    pub output: PathBuf,
    /// The `buoy` binary under test.
    pub buoy: PathBuf,
    /// Runs only the groups whose name contains this text.
    pub filter: Option<String>,
    /// The expectation file of the base commit.
    pub base: Option<PathBuf>,
    /// Rewrites the expectation file and the summary. An update runs every group, so it
    /// takes no filter.
    pub update: bool,
    pub jobs: usize,
    /// The deadline of one program.
    pub deadline: Duration,
}

/// `tests/node/surface.json`.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    node: String,
    host: String,
    docs: String,
    entries: BTreeMap<String, Recorded>,
}

/// What Node recorded for one entry: its `typeof`, `accessor` for an accessor, the length of
/// a function, and whether Node's documentation names it.
#[derive(Debug, Deserialize)]
struct Recorded(String, Option<u64>, Docs);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Docs {
    Documented,
    Deprecated,
    Undocumented,
}

impl Recorded {
    /// The line that `probe` prints after the name.
    fn shape(&self) -> String {
        match self.1 {
            Some(length) => format!("{} {length}", self.0),
            None => self.0.clone(),
        }
    }

    fn is_documented(&self) -> bool {
        self.2 != Docs::Undocumented
    }
}

/// What one run found.
#[derive(Debug)]
pub struct Report {
    pub node: String,
    pub comparison: Comparison,
    /// The entry of each documented entry that ran.
    pub run: Expectations,
    pub summary: Summary,
    pub durations_ms: BTreeMap<String, u128>,
    /// The failure reports of the programs of the entries whose outcome differs from their
    /// line.
    reports: Vec<String>,
}

impl Report {
    /// The report: the entries that ran, the findings of section 3.3, the first failure
    /// reports, the documented entries present in each group, the outcomes, the blockers,
    /// and the durations.
    #[must_use]
    pub fn text(&self) -> String {
        let mut text = format!(
            "{SUITE} {}: {} of {} documented entries ran\n",
            self.node,
            self.run.len(),
            self.summary.total
        );
        text.push_str(&self.comparison.report(UPDATE, REPORT_LINES));
        for report in self.reports.iter().take(REPORTED_RUNS) {
            text.push_str(report);
        }
        text.push_str("documented entries present in each group:\n");
        for (group, counts) in self.summary.groups.get("module").into_iter().flatten() {
            let _ = writeln!(
                text,
                "  {group} {} of {}",
                counts.get(Outcome::Pass),
                counts.total()
            );
        }
        text.push_str(&summary::run_report(&self.summary, &self.durations_ms));
        text
    }
}

/// The program of one group and what its run printed.
#[derive(Debug)]
struct Execution {
    outcome: Outcome,
    blockers: Vec<String>,
    /// The shape that the program printed for each name.
    shapes: BTreeMap<String, String>,
    report: String,
}

/// The entries of one run: the documented ones by name, the blockers of each rejected one,
/// the result of every entry, and the groups where an entry moved from its line.
struct Probed<'a> {
    run: Expectations,
    blocked: Vec<Vec<String>>,
    results: BTreeMap<String, TestResult>,
    changed: BTreeSet<&'a str>,
}

/// Probes the entries of the manifest on Buoy and compares the run with the expectation file.
pub fn run(options: &Options) -> Result<Report, String> {
    // An update with --filter rewrites the lines of the groups that ran and keeps the
    // others.
    let mut durations_ms = BTreeMap::new();
    let started = Instant::now();
    let (manifest, never) = load(&options.directory)?;
    let selected = select(&manifest, options.filter.as_deref());
    let (programs, files) = write_programs(options, &selected)?;
    durations_ms.insert("load".to_owned(), started.elapsed().as_millis());

    let started = Instant::now();
    let jobs: Vec<(usize, &String)> = files.iter().enumerate().collect();
    let executions = crate::parallel(&jobs, options.jobs, |(index, file)| {
        execute(options, &programs, *index, file)
    })
    .into_iter()
    .collect::<Result<Vec<_>, _>>()?;
    durations_ms.insert("execute".to_owned(), started.elapsed().as_millis());

    // A line whose outcome differs by platform names each one, as a line of Node's tests
    // does, and a run compares with the outcome of its own.
    let recorded = expectations::read(&options.directory.join("surface/expectations.txt"))?;
    let expected = expectations::on_platform(&recorded, PLATFORM);
    let probed = judge(&manifest, &never, &selected, &executions, &expected);
    let ids: BTreeSet<String> = manifest
        .entries
        .iter()
        .filter(|(_, recorded)| recorded.is_documented())
        .map(|(name, _)| name.clone())
        .collect();
    let base = match &options.base {
        Some(path) if path.is_file() => Some(expectations::on_platform(
            &expectations::read(path)?,
            PLATFORM,
        )),
        _ => None,
    };
    let comparison = comparison::compare(
        Origin::Upstream,
        &probed.run,
        &ids,
        &expected,
        base.as_ref(),
    );
    let reports = selected
        .iter()
        .zip(&executions)
        .filter(|((group, _), _)| !options.update && probed.changed.contains(group))
        .map(|(_, execution)| execution.report.clone())
        .collect();
    let mut entries: Expectations = recorded
        .into_iter()
        .filter(|(id, _)| ids.contains(id))
        .collect();
    for (id, run) in &probed.run {
        let entry = match (entries.get(id), run) {
            (Some(line), Entry::Same(outcome)) => {
                line.with_platform(PLATFORM, *outcome, options.update)
            }
            _ => run.clone(),
        };
        entries.insert(id.clone(), entry);
    }
    let summary = Summary {
        suite: SUITE.to_owned(),
        version: manifest.node.clone(),
        updated: String::new(),
        total: ids.len(),
        outcomes: Counts::every(entries.values()),
        groups: summary_groups(&manifest, &entries),
        blockers: summary::blockers(&probed.blocked),
    }
    .updated_since(&options.directory.join("surface/summary.json"));
    let comment = comparison.comment(
        &summary.comment_heading(base.as_ref(), probed.run.len()),
        50,
    );
    let results = Results {
        date: crate::date(),
        host: format!("{}-{}", env::consts::OS, env::consts::ARCH),
        tools: crate::tools(&options.buoy, (SUITE, &manifest.node)),
        durations_ms: durations_ms.clone(),
        tests: probed.results,
    };
    let header = [
        "Generated by `buoy-suites node-surface --update`. Do not edit. Run scripts/node-surface.sh for a new manifest.".to_owned(),
        format!(
            "node {} on {}, documentation {}",
            manifest.node, manifest.host, manifest.docs
        ),
    ];
    Destination {
        directory: &options.directory.join("surface"),
        output: &options.output,
        every_id: options.filter.is_none(),
        update: options.update,
    }
    .write(&header, &entries, &summary, &results, &comment)?;
    Ok(Report {
        node: manifest.node.clone(),
        comparison,
        run: probed.run,
        summary,
        durations_ms,
        reports,
    })
}

/// The manifest of `directory` and its `never` list, each line of which names an entry.
fn load(directory: &Path) -> Result<(Manifest, BTreeMap<String, String>), String> {
    let path = directory.join("surface.json");
    let text = fs::read_to_string(&path).map_err(|error| format!("{}: {error}", path.display()))?;
    let manifest: Manifest =
        serde_json::from_str(&text).map_err(|error| format!("{}: {error}", path.display()))?;
    let never = never(directory)?;
    if let Some(name) = never
        .keys()
        .find(|name| !manifest.entries.contains_key(*name))
    {
        return Err(format!("{NEVER}: `{name}` is no entry of surface.json"));
    }
    Ok((manifest, never))
}

/// The groups whose name contains `filter`, each with the names of its entries.
fn select<'a>(manifest: &'a Manifest, filter: Option<&str>) -> Vec<(&'a str, Vec<&'a str>)> {
    let mut groups: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for name in manifest.entries.keys() {
        groups.entry(group_of(name)).or_default().push(name);
    }
    groups
        .into_iter()
        .filter(|(group, _)| filter.is_none_or(|filter| group.contains(filter)))
        .collect()
}

/// Writes `surface.ts` and the program of each group to the `programs` directory of the
/// output, and returns the directory and the file of each group.
fn write_programs(
    options: &Options,
    selected: &[(&str, Vec<&str>)],
) -> Result<(PathBuf, Vec<String>), String> {
    let programs = options.output.join("programs");
    let _ = fs::remove_dir_all(&programs);
    crate::write(
        &programs.join("surface.ts"),
        &fs::read_to_string(options.directory.join("surface.ts"))
            .map_err(|error| format!("tests/node/surface.ts: {error}"))?,
    )?;
    let mut files = Vec::with_capacity(selected.len());
    for (index, (group, names)) in selected.iter().enumerate() {
        let (extension, source) = program(group, names)?;
        let file = format!("{index:03}-{}.{extension}", file_stem(group));
        crate::write(&programs.join(&file), &source)?;
        files.push(file);
    }
    Ok((programs, files))
}

/// The outcome of each entry of the groups that ran.
fn judge<'a>(
    manifest: &Manifest,
    never: &BTreeMap<String, String>,
    selected: &[(&'a str, Vec<&str>)],
    executions: &[Execution],
    expected: &Expectations,
) -> Probed<'a> {
    let mut probed = Probed {
        run: Expectations::new(),
        blocked: Vec::new(),
        results: BTreeMap::new(),
        changed: BTreeSet::new(),
    };
    for ((group, names), execution) in selected.iter().zip(executions) {
        for name in names {
            let recorded = &manifest.entries[*name];
            let printed = execution.shapes.get(*name);
            let outcome = if never.contains_key(*name) {
                Outcome::Never
            } else {
                outcome_of(
                    &recorded.shape(),
                    printed.map(String::as_str),
                    execution.outcome,
                )
            };
            let detail = match printed {
                Some(shape) if outcome == Outcome::Fail => {
                    format!("node: {}, buoy: {shape}", recorded.shape())
                }
                _ => String::new(),
            };
            probed.results.insert(
                (*name).to_owned(),
                TestResult {
                    outcome: outcome.to_string(),
                    time_ms: BTreeMap::new(),
                    detail,
                },
            );
            if !recorded.is_documented() {
                continue;
            }
            if matches!(outcome, Outcome::Rejected | Outcome::Late) {
                probed.blocked.push(execution.blockers.clone());
            }
            if expected.get(*name) != Some(&Entry::Same(outcome)) {
                probed.changed.insert(group);
            }
            probed.run.insert((*name).to_owned(), Entry::Same(outcome));
        }
    }
    probed
}

/// The reviewed entries of `never.txt` in `directory`, each with its reason. A line is
/// `<entry> <reason>`, and a line that starts with `#` is a comment.
pub fn never(directory: &Path) -> Result<BTreeMap<String, String>, String> {
    let path = directory.join("never.txt");
    let text = fs::read_to_string(&path).map_err(|error| format!("{}: {error}", path.display()))?;
    let mut never = BTreeMap::new();
    for line in text.lines() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (name, reason) = line.split_once(' ').unwrap_or((line, ""));
        if reason.trim().is_empty() {
            return Err(format!(
                "{}: `{line}` is not `<entry> <reason>`",
                path.display()
            ));
        }
        if never
            .insert(name.to_owned(), reason.trim().to_owned())
            .is_some()
        {
            return Err(format!("{}: `{name}` has a second line", path.display()));
        }
    }
    Ok(never)
}

/// The group of an entry: its name up to the first key, such as `node:fs` or `Buffer`.
fn group_of(name: &str) -> &str {
    name.find(['.', '[']).map_or(name, |end| &name[..end])
}

/// The keys of an entry after its group, each as a JavaScript expression: `.<key>` gives a
/// string, and `["<key>"]` and `[Symbol.<name>]` give the text in the brackets.
fn keys(name: &str) -> Result<Vec<String>, String> {
    let mut rest = &name[group_of(name).len()..];
    let mut keys = Vec::new();
    while !rest.is_empty() {
        if let Some(after) = rest.strip_prefix('[') {
            let (key, tail) = after
                .split_once(']')
                .ok_or_else(|| format!("`{name}` has an unclosed `[`"))?;
            keys.push(key.to_owned());
            rest = tail;
        } else if let Some(after) = rest.strip_prefix('.') {
            let end = after.find(['.', '[']).unwrap_or(after.len());
            keys.push(format!("\"{}\"", &after[..end]));
            rest = &after[end..];
        } else {
            return Err(format!("`{name}` is not `<group>` and its keys"));
        }
    }
    Ok(keys)
}

/// The file extension and the source of the program of `group`: an ES module that imports
/// the module or reads the global, or a `CommonJS` module for a name of its scope.
fn program(group: &str, names: &[&str]) -> Result<(&'static str, String), String> {
    let mut entries = String::new();
    for name in names {
        let name_literal = serde_json::to_string(name).map_err(|error| error.to_string())?;
        let keys = keys(name)?;
        let _ = writeln!(
            entries,
            "  [{}],",
            std::iter::once(name_literal)
                .chain(keys)
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    let generated = "// Generated by `buoy-suites node-surface` from tests/node/surface.json.";
    if MODULE_SCOPE.contains(&group) {
        return Ok((
            "cjs",
            format!(
                "{generated}\nconst {{ probe }} = require(\"./surface.ts\");\n\nprobe({group}, [\n{entries}]);\n"
            ),
        ));
    }
    let (import, root) = match group.strip_prefix("node:") {
        Some(_) => (
            format!("import root from \"{group}\";\n"),
            "root".to_owned(),
        ),
        None => (String::new(), format!("globalThis.{group}")),
    };
    Ok((
        "ts",
        format!(
            "{generated}\nimport {{ probe }} from \"./surface.ts\";\n{import}\nprobe({root}, [\n{entries}]);\n"
        ),
    ))
}

/// A file name for a group, which a case-insensitive file system keeps apart from the other
/// groups by the index before it.
fn file_stem(group: &str) -> String {
    group.replace([':', '/'], "-")
}

/// The outcome of an entry: a pass when the program printed the shape that Node recorded, a
/// failure when it printed another shape or ran and printed none, and otherwise the outcome
/// of the program.
fn outcome_of(recorded: &str, printed: Option<&str>, program: Outcome) -> Outcome {
    match printed {
        Some(shape) if shape == recorded => Outcome::Pass,
        Some(_) => Outcome::Fail,
        None if program == Outcome::Pass => Outcome::Fail,
        None => program,
    }
}

/// The name and the shape of each line that `probe` printed. The shape is the last word,
/// or `function <length>`.
fn shapes(stdout: &str) -> BTreeMap<String, String> {
    stdout
        .lines()
        .filter_map(|line| {
            let (head, last) = line.rsplit_once(' ')?;
            match head.rsplit_once(' ') {
                Some((name, "function")) if last.parse::<u64>().is_ok() => {
                    Some((name.to_owned(), format!("function {last}")))
                }
                _ => Some((head.to_owned(), last.to_owned())),
            }
        })
        .collect()
}

/// Runs the program `file` of `programs` with `buoy run`.
fn execute(
    options: &Options,
    programs: &Path,
    index: usize,
    file: &str,
) -> Result<Execution, String> {
    let directory = programs.join(format!("run-{index}"));
    let temporary = directory.join("tmp");
    fs::create_dir_all(&temporary).map_err(|error| format!("{}: {error}", temporary.display()))?;
    let result_file = directory.join("result.json");
    let mut command = Command::new(&options.buoy);
    buoy_env(&mut command, &temporary)
        .current_dir(programs)
        .env("BUOY_RESULT_FILE", &result_file)
        .arg("run")
        .args(crate::node::ENGINE)
        .arg(file);
    let finished = crate::run(&mut command, options.deadline);
    let result = RunResult::read(&result_file);
    let _ = fs::remove_dir_all(&directory);
    let outcome = classify(&Facts::of_run(
        result.as_ref(),
        finished.timed_out,
        !finished.timed_out && finished.output.status.success(),
    ));
    let blockers = result
        .map(|result| result.blockers(outcome))
        .unwrap_or_default();
    let stdout = String::from_utf8_lossy(&finished.output.stdout);
    let stderr = String::from_utf8_lossy(&finished.output.stderr);
    let stderr: Vec<&str> = stderr.lines().take(20).collect();
    let report = format!(
        "--- {file}: {outcome}, exit status {:?}\n--- stderr:\n{}\nrerun: {command:?}\n",
        finished.output.status.code(),
        stderr.join("\n"),
    );
    Ok(Execution {
        outcome,
        blockers,
        shapes: shapes(&stdout),
        report,
    })
}

/// The groups of the summary: `module`, the documented entries of each group, and `docs`,
/// the documented and the deprecated entries.
fn summary_groups(
    manifest: &Manifest,
    entries: &Expectations,
) -> BTreeMap<String, BTreeMap<String, Counts>> {
    let mut groups: BTreeMap<String, BTreeMap<String, Counts>> = BTreeMap::new();
    for (name, entry) in entries {
        let Some(recorded) = manifest.entries.get(name) else {
            continue;
        };
        let docs = match recorded.2 {
            Docs::Deprecated => "deprecated",
            _ => "documented",
        };
        for (kind, group) in [("module", group_of(name)), ("docs", docs)] {
            groups
                .entry(kind.to_owned())
                .or_default()
                .entry(group.to_owned())
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
    fn a_name_splits_into_its_group_and_keys() {
        assert_eq!(group_of("node:fs/promises.readFile"), "node:fs/promises");
        assert_eq!(group_of("URL[Symbol.toStringTag]"), "URL");
        assert_eq!(group_of("__dirname"), "__dirname");
        assert_eq!(
            keys(r#"require.extensions[".js"]"#),
            Ok(vec![r#""extensions""#.to_owned(), r#"".js""#.to_owned()])
        );
        assert_eq!(
            keys("URL.prototype[Symbol.iterator].length"),
            Ok(vec![
                r#""prototype""#.to_owned(),
                "Symbol.iterator".to_owned(),
                r#""length""#.to_owned()
            ])
        );
        assert_eq!(keys("Buffer"), Ok(Vec::new()));
        assert!(keys("Buffer[Symbol.iterator").is_err());
    }

    #[test]
    fn a_program_probes_each_entry_of_its_group() {
        let (extension, source) =
            program("node:fs", &["node:fs", "node:fs.readFile"]).expect("generates");
        assert_eq!(extension, "ts");
        assert!(
            source.contains("import root from \"node:fs\";\n"),
            "{source}"
        );
        assert!(
            source.contains(
                "probe(root, [\n  [\"node:fs\"],\n  [\"node:fs.readFile\", \"readFile\"],\n]);\n"
            ),
            "{source}"
        );
        let (extension, source) = program("Buffer", &["Buffer.from"]).expect("generates");
        assert_eq!(extension, "ts");
        assert!(source.contains("probe(globalThis.Buffer, ["), "{source}");
        let (extension, source) = program("require", &["require"]).expect("generates");
        assert_eq!(extension, "cjs");
        assert!(source.contains("require(\"./surface.ts\")"), "{source}");
    }

    #[test]
    fn printed_shapes_decide_each_entry() {
        let shapes =
            shapes("Buffer function 2\nBuffer.poolSize number\nURL.prototype.href missing\n");
        assert_eq!(shapes["Buffer"], "function 2");
        assert_eq!(shapes["Buffer.poolSize"], "number");
        assert_eq!(
            outcome_of("function 2", Some(&shapes["Buffer"]), Outcome::Pass),
            Outcome::Pass
        );
        assert_eq!(
            outcome_of(
                "accessor",
                Some(&shapes["URL.prototype.href"]),
                Outcome::Pass
            ),
            Outcome::Fail
        );
        assert_eq!(outcome_of("number", None, Outcome::Pass), Outcome::Fail);
        assert_eq!(
            outcome_of("number", None, Outcome::Rejected),
            Outcome::Rejected
        );
    }

    #[test]
    fn the_committed_never_list_names_entries_of_the_manifest() {
        let directory = crate::repository().join("tests/node");
        let never = never(&directory).expect("never.txt reads");
        let manifest = fs::read_to_string(directory.join("surface.json")).expect("reads");
        let manifest: Manifest = serde_json::from_str(&manifest).expect("parses");
        for name in never.keys() {
            assert!(manifest.entries.contains_key(name), "{name}");
        }
        let pinned = fs::read_to_string(crate::repository().join(".node-version"))
            .expect(".node-version reads");
        assert_eq!(manifest.node, format!("v{}", pinned.trim()));
    }
}
