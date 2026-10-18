//! The compatibility dashboard of section 6 of docs/design/testing.md: `docs/COMPAT.md` and
//! `docs/compat.json`, generated from the committed summaries of the upstream suites, the
//! `never` list of `tests/node/never.txt`, and the program counts of Buoy's own corpora.
//! Nobody edits the two files by hand.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::fs;
use std::path::Path;

use serde::Serialize;

use crate::expectations::{self, Entry};
use crate::node_surface;
use crate::outcome::Outcome;
use crate::summary::{Blocker, Counts, Summary};

/// The command that writes the two files.
pub const COMMAND: &str = "pnpm compat";

/// The two files, relative to the repository root.
pub const FILES: [&str; 2] = ["docs/COMPAT.md", "docs/compat.json"];

/// The sections of the page for the upstream suites: the title, the suite, the directory of
/// its `summary.json` and `expectations.txt` under `tests`, and the phase of testing.md
/// section 11 that builds it.
const SECTIONS: [(&str, &str, &str, u8); 5] = [
    ("Language", "test262", "test262", 1),
    ("Node", "node", "node", 4),
    ("Node API surface", node_surface::SUITE, "node/surface", 4),
    ("Web", "wpt", "wpt", 10),
    ("Packages", "packages", "packages", 3),
];

/// The group kinds that the outcome table of a suite shows as rows. Each other kind gets a
/// table, in the order of `TABLES` and then by name.
const ROWS: [&str; 2] = ["kind", "subset"];
const TABLES: [&str; 3] = ["edition", "feature", "directory"];

/// A table with more rows than this is collapsed.
const OPEN_ROWS: usize = 20;

/// The group kind whose groups are single programs, `<package>/<file>`, as in
/// `tests/packages/summary.json`. The page shows it as one row per package and one column per
/// program file.
const PROGRAMS: &str = "program";

/// The test of the ecosystem corpora.
const ECOSYSTEM: &str = "crates/buoy-cli/tests/ecosystem.rs";

/// Buoy's own corpora (tiers 3, 8a, 8c, 9, 10, and 12 of section 5), in the order of the
/// page: the name, where its count comes from, and its test. Tier 4, `tests/unit`, joins
/// when it exists. The Packages section shows tier 8b.
fn corpora_of(root: &Path) -> Result<Vec<(String, Source, &'static str)>, String> {
    let mut corpora = vec![
        (
            "conformance".to_owned(),
            Source::Programs("tests/conformance"),
            "crates/buoy-cli/tests/conformance.rs",
        ),
        (
            "equivalence/effect".to_owned(),
            Source::Programs("tests/equivalence/effect"),
            "crates/buoy-cli/tests/equivalence.rs",
        ),
        (
            "equivalence/ai".to_owned(),
            Source::Programs("tests/equivalence/ai"),
            "crates/buoy-cli/tests/ai.rs",
        ),
        (
            "programs".to_owned(),
            Source::Tests,
            "crates/buoy-cli/tests/programs.rs",
        ),
        (
            "npm".to_owned(),
            Source::Expectations("tests/npm/expectations.txt".to_owned()),
            ECOSYSTEM,
        ),
    ];
    corpora.extend(
        crate::packages::scenario_areas(root)?
            .into_iter()
            .map(|area| {
                (
                    format!("equivalence/{area}"),
                    Source::Expectations(format!("tests/equivalence/{area}/expectations.txt")),
                    ECOSYSTEM,
                )
            }),
    );
    corpora.extend([
        (
            "fuzz".to_owned(),
            Source::Expectations("tests/fuzz/expectations.txt".to_owned()),
            "crates/buoy-cli/tests/fuzz.rs",
        ),
        (
            "migration".to_owned(),
            Source::Expectations("tests/migration/expectations.txt".to_owned()),
            "crates/buoy-cli/tests/migration.rs",
        ),
    ]);
    Ok(corpora)
}

/// Where the count of a corpus comes from.
#[derive(Debug, Clone)]
enum Source {
    /// Each `.ts` program of the directory prints what Node printed, or its test fails.
    Programs(&'static str),
    /// Each `#[test]` of the test file checks the contract.
    Tests,
    /// The expectation file holds the outcome of each program, and the test fails on
    /// another outcome.
    Expectations(String),
}

impl Source {
    fn rule(&self) -> String {
        match self {
            Self::Programs(_) => "each program prints what Node printed".to_owned(),
            Self::Tests => "each test checks the contract".to_owned(),
            Self::Expectations(file) => format!("each program has the outcome of `{file}`"),
        }
    }
}

/// One tier of `docs/compat.json`. Every tier has this shape.
#[derive(Debug, Serialize)]
struct TierRow {
    tier: String,
    suite: String,
    suite_version: Option<String>,
    /// The commit of the last update of an upstream suite. `pnpm check` runs the corpora on
    /// each commit, so they have none.
    updated: Option<String>,
    /// The file that holds the evidence: the expectation file or the Rust test.
    test: String,
    total: usize,
    outcomes: Counts,
    groups: BTreeMap<String, BTreeMap<String, Counts>>,
    blockers: Vec<Blocker>,
    /// The reviewed `never` entries of a suite that has a never list, each with its reason.
    #[serde(skip_serializing_if = "Option::is_none")]
    never: Option<BTreeMap<String, String>>,
    /// The rule of a corpus, which the test enforces.
    #[serde(skip)]
    rule: String,
}

#[derive(Debug, Serialize)]
struct Dashboard<'a> {
    tiers: &'a [TierRow],
}

/// Writes the two files under `root`, or with `check`, writes nothing. Returns the files
/// whose contents differ from what the summaries give.
pub fn update(root: &Path, check: bool) -> Result<Vec<&'static str>, String> {
    let mut tiers = upstream(root)?;
    tiers.extend(corpora(root)?);
    let json = serde_json::to_string_pretty(&Dashboard { tiers: &tiers })
        .map_err(|error| error.to_string())?
        + "\n";
    let mut differ = Vec::new();
    for (file, contents) in FILES.into_iter().zip([page(&tiers), json]) {
        let path = root.join(file);
        if fs::read_to_string(&path).is_ok_and(|current| current == contents) {
            continue;
        }
        differ.push(file);
        if !check {
            fs::write(&path, contents).map_err(|error| format!("{file}: {error}"))?;
        }
    }
    Ok(differ)
}

/// The tiers of the `tests/<suite>/summary.json` files, in the order of `SECTIONS`. A
/// summary of a suite that `SECTIONS` lacks stops the run, so no suite misses the page.
fn upstream(root: &Path) -> Result<Vec<TierRow>, String> {
    let directories =
        fs::read_dir(root.join("tests")).map_err(|error| format!("tests: {error}"))?;
    for directory in directories.filter_map(Result::ok) {
        let suite = directory.file_name().to_string_lossy().into_owned();
        if directory.path().join("summary.json").is_file()
            && !SECTIONS.iter().any(|(_, _, known, _)| *known == suite)
        {
            return Err(format!(
                "tests/{suite}/summary.json: add the suite to SECTIONS in crates/buoy-suites/src/compat.rs"
            ));
        }
    }
    let mut tiers = Vec::new();
    for (title, suite, directory, _) in SECTIONS {
        let file = format!("tests/{directory}/summary.json");
        let Ok(text) = fs::read_to_string(root.join(&file)) else {
            continue;
        };
        let summary: Summary =
            serde_json::from_str(&text).map_err(|error| format!("{file}: {error}"))?;
        tiers.push(TierRow {
            tier: title.to_lowercase(),
            suite: summary.suite,
            suite_version: Some(short(&summary.version).to_owned()),
            updated: Some(short(&summary.updated).to_owned()),
            test: format!("tests/{directory}/expectations.txt"),
            total: summary.total,
            outcomes: summary.outcomes.with_zeros(),
            groups: summary.groups,
            blockers: summary.blockers,
            never: (suite == node_surface::SUITE)
                .then(|| node_surface::never(&root.join("tests/node")))
                .transpose()?,
            rule: String::new(),
        });
    }
    Ok(tiers)
}

/// The tiers of Buoy's own corpora.
fn corpora(root: &Path) -> Result<Vec<TierRow>, String> {
    let read = |file: &str| {
        fs::read_to_string(root.join(file)).map_err(|error| format!("{file}: {error}"))
    };
    let node = read(".node-version")?;
    let passing =
        |count: usize| Counts::every(std::iter::repeat_n(&Entry::Same(Outcome::Pass), count));
    corpora_of(root)?
        .into_iter()
        .map(|(suite, source, test)| {
            let (outcomes, version) = match &source {
                Source::Programs(directory) => {
                    let programs = fs::read_dir(root.join(directory))
                        .map_err(|error| format!("{directory}: {error}"))?
                        .filter_map(Result::ok)
                        .filter(|entry| entry.path().extension().is_some_and(|found| found == "ts"))
                        .count();
                    (passing(programs), Some(format!("Node {}", node.trim())))
                }
                Source::Tests => {
                    let tests = read(test)?
                        .lines()
                        .filter(|line| line.trim() == "#[test]")
                        .count();
                    (passing(tests), None)
                }
                Source::Expectations(file) => {
                    let entries = expectations::parse(&read(file)?)
                        .map_err(|error| format!("{file}: {error}"))?;
                    (Counts::every(entries.values()), None)
                }
            };
            Ok(TierRow {
                tier: "corpora".to_owned(),
                suite,
                suite_version: version,
                updated: None,
                test: test.to_owned(),
                total: outcomes.total(),
                outcomes,
                groups: BTreeMap::new(),
                blockers: Vec::new(),
                never: None,
                rule: source.rule(),
            })
        })
        .collect()
}

fn page(tiers: &[TierRow]) -> String {
    let mut page = format!(
        "<!-- Generated by `buoy-suites compat`. Do not edit. Run `{COMMAND}`. -->\n\n\
         # Compatibility\n\n\
         The pass rate of each test tier that exists today. `buoy-suites compat` writes this \
         page and `docs/compat.json` from the committed summaries of the upstream suites, \
         `tests/node/never.txt`, and the Buoy corpora, and `pnpm check` fails when either file \
         differs from them. \
         [docs/design/testing.md](design/testing.md) defines the tiers and the outcomes. The \
         denominator of a rate is every test, skips included. A silent failure is `fail`, \
         `timeout`, or `harness_error`: the program ran and gave a wrong result.\n\n\
         ## Tiers\n\n"
    );
    let rows: Vec<Vec<String>> = tiers
        .iter()
        .map(|tier| {
            let silent = [Outcome::Fail, Outcome::Timeout, Outcome::HarnessError]
                .into_iter()
                .map(|outcome| tier.outcomes.get(outcome))
                .sum();
            vec![
                tier.tier.clone(),
                tier.suite.clone(),
                tier.suite_version.clone().unwrap_or_default(),
                thousands(tier.outcomes.get(Outcome::Pass)),
                thousands(tier.total),
                rate(tier.outcomes.get(Outcome::Pass), tier.total),
                thousands(silent),
                thousands(tier.outcomes.get(Outcome::Crash)),
                tier.updated.clone().unwrap_or_default(),
                format!("`{}`", tier.test),
            ]
        })
        .collect();
    table(
        &mut page,
        &[
            "Tier", "Suite", "Version", "Pass", "Total", "Rate", "Silent", "Crash", "Updated",
            "Test",
        ],
        &rows,
    );
    page.push_str("The corpora have no update commit: `pnpm check` runs them on each commit.\n\n");
    for (title, suite, _, phase) in SECTIONS {
        let _ = writeln!(page, "## {title}\n");
        match tiers.iter().find(|tier| tier.suite == suite) {
            Some(tier) => suite_section(&mut page, tier),
            None => {
                let _ = writeln!(
                    page,
                    "Not measured yet. Phase {phase} of section 11 of [testing.md](design/testing.md) builds this suite.\n"
                );
            }
        }
    }
    corpora_section(&mut page, tiers);
    page.truncate(page.trim_end().len());
    page.push('\n');
    page
}

fn suite_section(page: &mut String, tier: &TierRow) {
    let _ = writeln!(
        page,
        "{} at {}, updated at {}. Evidence: `{}`.\n\n### Outcomes\n",
        tier.suite,
        tier.suite_version.as_deref().unwrap_or_default(),
        tier.updated.as_deref().unwrap_or_default(),
        tier.test
    );
    let mut rows = vec![("every test".to_owned(), &tier.outcomes)];
    for kind in ROWS {
        for (group, counts) in tier.groups.get(kind).into_iter().flatten() {
            rows.push((format!("{kind}: {group}"), counts));
        }
    }
    outcome_table(page, "Tests", &rows);
    let mut kinds: Vec<&String> = tier
        .groups
        .keys()
        .filter(|kind| !ROWS.contains(&kind.as_str()))
        .collect();
    kinds.sort_by_key(|kind| TABLES.iter().position(|known| known == kind));
    for kind in kinds {
        let mut rows: Vec<(String, &Counts)> = tier.groups[kind]
            .iter()
            .map(|(group, counts)| (group.clone(), counts))
            .collect();
        rows.sort_by_key(|(group, _)| edition_order(group));
        if kind == PROGRAMS {
            page.push_str("### By package\n\n");
            program_table(page, &tier.groups[kind]);
            continue;
        }
        let _ = writeln!(page, "### By {kind}\n");
        outcome_table(page, kind, &rows);
    }
    let _ = writeln!(
        page,
        "### Blockers\n\nA blocker is a diagnostic code, a built-in that throws a late rejection, \
         or a harness file that does not compile. The table counts the tests that each one \
         blocks and the tests where it is the only blocker, and it sorts by the second count.\n"
    );
    let rows: Vec<Vec<String>> = tier
        .blockers
        .iter()
        .map(|row| {
            vec![
                format!("`{}`", row.blocker),
                thousands(row.files),
                thousands(row.only),
            ]
        })
        .collect();
    table(page, &["Blocker", "Tests blocked", "Only blocker"], &rows);
    if let Some(never) = &tier.never {
        never_section(page, never);
    }
}

/// The reviewed `never` list of a suite, one line per id with its reason.
fn never_section(page: &mut String, never: &BTreeMap<String, String>) {
    let _ = writeln!(
        page,
        "### Never\n\nThe entries of `{}` that Buoy will never have, each approved by a reviewer.\n",
        node_surface::NEVER
    );
    if never.is_empty() {
        page.push_str("No entry is on the list.\n\n");
        return;
    }
    for (id, reason) in never {
        let _ = writeln!(page, "- `{id}`: {reason}");
    }
    page.push('\n');
}

fn corpora_section(page: &mut String, tiers: &[TierRow]) {
    page.push_str(
        "## Buoy corpora\n\nThe test of each corpus fails when a program breaks its rule, so \
         these counts hold on every commit that passes `pnpm check`.\n\n",
    );
    let rows: Vec<Vec<String>> = tiers
        .iter()
        .filter(|tier| tier.tier == "corpora")
        .map(|tier| {
            let outcomes: Vec<String> = Outcome::ALL
                .into_iter()
                .filter(|outcome| tier.outcomes.get(*outcome) > 0)
                .map(|outcome| format!("{outcome} {}", thousands(tier.outcomes.get(outcome))))
                .collect();
            vec![
                tier.suite.clone(),
                thousands(tier.total),
                outcomes.join(", "),
                tier.rule.clone(),
                format!("`{}`", tier.test),
            ]
        })
        .collect();
    table(
        page,
        &["Corpus", "Programs", "Outcomes", "Rule", "Test"],
        &rows,
    );
    page.push_str(
        "The `fuzz` row counts the open fuzz cases: a case that is not `pass` is open. \
         `tests/unit` and `tests/divergence` do not exist yet, so the page has no `buoy test` \
         row and no open count of the divergence register.\n",
    );
}

/// A table of the outcomes of each row, collapsed when it has more than `OPEN_ROWS` rows.
fn outcome_table(page: &mut String, first: &str, rows: &[(String, &Counts)]) {
    let mut header = vec![first, "Total", "Pass", "Rate"];
    header.extend(Outcome::ALL[1..].iter().map(|outcome| outcome.as_str()));
    let rows: Vec<Vec<String>> = rows
        .iter()
        .map(|(name, counts)| {
            let mut row = vec![
                name.clone(),
                thousands(counts.total()),
                thousands(counts.get(Outcome::Pass)),
                rate(counts.get(Outcome::Pass), counts.total()),
            ];
            row.extend(
                Outcome::ALL[1..]
                    .iter()
                    .map(|outcome| thousands(counts.get(*outcome))),
            );
            row
        })
        .collect();
    collapsible(page, &header, &rows);
}

/// One row per package and one column per program file, with the outcome of each program.
fn program_table(page: &mut String, programs: &BTreeMap<String, Counts>) {
    let mut files: Vec<&str> = Vec::new();
    let mut packages: BTreeMap<&str, BTreeMap<&str, Outcome>> = BTreeMap::new();
    for (id, counts) in programs {
        let (package, file) = id.rsplit_once('/').unwrap_or(("", id));
        let outcome = Outcome::ALL
            .into_iter()
            .find(|outcome| counts.get(*outcome) > 0)
            .unwrap_or(Outcome::Skip);
        if !files.contains(&file) {
            files.push(file);
        }
        packages.entry(package).or_default().insert(file, outcome);
    }
    files.sort_unstable();
    let mut header = vec!["Package"];
    header.extend(&files);
    let rows: Vec<Vec<String>> = packages
        .iter()
        .map(|(package, outcomes)| {
            let mut row = vec![format!("`{package}`")];
            row.extend(files.iter().map(|file| {
                outcomes
                    .get(file)
                    .map_or_else(String::new, ToString::to_string)
            }));
            row
        })
        .collect();
    collapsible(page, &header, &rows);
}

/// A table, collapsed when it has more than `OPEN_ROWS` rows.
fn collapsible(page: &mut String, header: &[&str], rows: &[Vec<String>]) {
    if rows.len() <= OPEN_ROWS {
        table(page, header, rows);
        return;
    }
    let _ = writeln!(page, "<details><summary>{} groups</summary>\n", rows.len());
    table(page, header, rows);
    page.push_str("</details>\n\n");
}

fn table(page: &mut String, header: &[&str], rows: &[Vec<String>]) {
    let _ = writeln!(page, "| {} |", header.join(" | "));
    let _ = writeln!(page, "|{}", " --- |".repeat(header.len()));
    for row in rows {
        let cells: Vec<String> = row.iter().map(|cell| cell.replace('|', "\\|")).collect();
        let _ = writeln!(page, "| {} |", cells.join(" | "));
    }
    page.push('\n');
}

/// The sort key that puts `es5` before `es10` and every other name after them, by name.
fn edition_order(group: &str) -> (u32, String) {
    let number = group
        .strip_prefix("es")
        .and_then(|number| number.parse().ok())
        .unwrap_or(u32::MAX);
    (number, group.to_owned())
}

/// `count` with a comma between each group of three digits.
#[must_use]
pub fn thousands(count: usize) -> String {
    let digits = count.to_string();
    let mut text = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            text.push(',');
        }
        text.push(digit);
    }
    text
}

/// `part` of `total` as a percentage with one decimal, rounded half up.
fn rate(part: usize, total: usize) -> String {
    if total == 0 {
        return "-".to_owned();
    }
    let tenths = (part * 1000 + total / 2) / total;
    format!("{}.{}%", tenths / 10, tenths % 10)
}

/// The first 7 characters of a commit SHA. Any other version stays whole.
#[must_use]
pub fn short(version: &str) -> &str {
    if version.len() == 40 && version.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return &version[..7];
    }
    version
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_read_as_the_page_writes_them() {
        assert_eq!(thousands(0), "0");
        assert_eq!(thousands(999), "999");
        assert_eq!(thousands(53_616), "53,616");
        assert_eq!(thousands(1_234_567), "1,234,567");
        assert_eq!(rate(4_320, 53_616), "8.1%");
        assert_eq!(rate(1, 2_000), "0.1%");
        assert_eq!(rate(72, 72), "100.0%");
        assert_eq!(rate(0, 0), "-");
        assert_eq!(short("d53ebc8b1931d9f1541e43d59650776e4b766248"), "d53ebc8");
        assert_eq!(short("v26.10.1"), "v26.10.1");
    }

    #[test]
    fn editions_sort_by_number() {
        let mut groups = ["esnext", "es10", "es5", "es6", "unknown"];
        groups.sort_by_key(|group| edition_order(group));
        assert_eq!(groups, ["es5", "es6", "es10", "esnext", "unknown"]);
    }
}
