//! The files of section 3.6 of docs/design/testing.md: `summary.json`, which the repository
//! commits and the dashboard reads, and `results.json`, the details of one run.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::fs;
use std::path::Path;
use std::process::Command;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::expectations::{self, Entry, Expectations};
use crate::outcome::Outcome;

/// `tests/<suite>/summary.json`: the counts of each outcome for the suite and for each
/// group, and the blockers table of section 6.
#[derive(Debug, Serialize, Deserialize)]
pub struct Summary {
    pub suite: String,
    pub version: String,
    /// The commit that `HEAD` named when the counts last changed. A file cannot name the
    /// commit that holds it, so this is the commit that the update started from.
    #[serde(default)]
    pub updated: String,
    pub total: usize,
    pub outcomes: Counts,
    /// The counts of each group, by kind of group and then by group. A count of 0 is left
    /// out.
    pub groups: BTreeMap<String, BTreeMap<String, Counts>>,
    pub blockers: Vec<Blocker>,
}

impl Summary {
    /// The top of the section of the suite in the pull request comment of section 6: the
    /// passing files with the pull request and on the base, and the files that this run
    /// executed.
    #[must_use]
    pub fn comment_heading(&self, base: Option<&Expectations>, ran: usize) -> String {
        let count = crate::compat::thousands;
        let on_base = base.map_or_else(String::new, |base| {
            let passing = base
                .values()
                .filter(|entry| entry.outcome() == Outcome::Pass)
                .count();
            format!(", and {} on the base", count(passing))
        });
        format!(
            "### {} {}\n\n{} of {} files pass with this pull request{on_base}. This run executed {} files.\n",
            self.suite,
            crate::compat::short(&self.version),
            count(self.outcomes.get(Outcome::Pass)),
            count(self.total),
            count(ran),
        )
    }

    /// Keeps the `updated` commit of the summary at `path` when the two summaries differ in
    /// nothing else, so an update that changes no count changes no file. Otherwise
    /// `updated` is the commit of `HEAD`.
    #[must_use]
    pub fn updated_since(mut self, path: &Path) -> Self {
        let previous: Option<serde_json::Value> = fs::read_to_string(path)
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok());
        previous
            .as_ref()
            .and_then(|previous| previous.get("updated")?.as_str())
            .unwrap_or_default()
            .clone_into(&mut self.updated);
        if self.updated.is_empty() || serde_json::to_value(&self).ok() != previous {
            self.updated = head();
        }
        self
    }
}

/// The end of the report of an upstream suite: the count of each outcome, the first
/// blockers, and the duration of each phase.
#[must_use]
pub fn run_report(summary: &Summary, durations_ms: &BTreeMap<String, u128>) -> String {
    let outcomes: Vec<String> = Outcome::ALL
        .iter()
        .map(|outcome| format!("{outcome} {}", summary.outcomes.get(*outcome)))
        .collect();
    let mut text = format!(
        "outcomes of every file: {}\nblockers (files blocked, files with no other blocker):\n",
        outcomes.join(", ")
    );
    for blocker in summary.blockers.iter().take(10) {
        let _ = writeln!(
            text,
            "  {} {} {}",
            blocker.blocker, blocker.files, blocker.only
        );
    }
    let durations: Vec<String> = durations_ms
        .iter()
        .map(|(phase, ms)| format!("{phase} {ms} ms"))
        .collect();
    let _ = writeln!(text, "durations: {}", durations.join(", "));
    text
}

/// Where the run of an upstream suite writes its files.
pub(crate) struct Destination<'a> {
    /// `tests/<suite>`, whose expectation file and summary an update rewrites.
    pub directory: &'a Path,
    /// `target/suites/<suite>`.
    pub output: &'a Path,
    /// Every id ran, so the summary covers the whole suite.
    pub every_id: bool,
    pub update: bool,
}

impl Destination<'_> {
    /// Writes the regenerated expectation file, `results.json`, and `comment.md` to the
    /// output directory, the summary after a run of every id, and, for an update, the
    /// expectation file and the summary of the suite.
    pub(crate) fn write(
        &self,
        header: &[String],
        entries: &Expectations,
        summary: &Summary,
        results: &Results,
        comment: &str,
    ) -> Result<(), String> {
        let file = expectations::write(header, entries);
        let summary = crate::json(summary)?;
        crate::write(&self.output.join("expectations.txt"), &file)?;
        crate::write(&self.output.join("results.json"), &crate::json(results)?)?;
        crate::write(&self.output.join("comment.md"), comment)?;
        if self.every_id {
            crate::write(&self.output.join("summary.json"), &summary)?;
        }
        if self.update {
            crate::write(&self.directory.join("expectations.txt"), &file)?;
            crate::write(&self.directory.join("summary.json"), &summary)?;
        }
        Ok(())
    }
}

/// The commit of `HEAD` in the repository, or `unknown` outside a git checkout.
fn head() -> String {
    Command::new("git")
        .arg("-C")
        .arg(crate::repository())
        .args(["rev-parse", "HEAD"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map_or_else(
            || "unknown".to_owned(),
            |output| String::from_utf8_lossy(&output.stdout).trim().to_owned(),
        )
}

/// The number of tests of each outcome.
#[derive(Debug, Clone, Default)]
pub struct Counts {
    counts: BTreeMap<Outcome, usize>,
    keep_zeros: bool,
}

impl Counts {
    /// The counts of `entries`, with a 0 for each outcome that no entry has.
    pub fn every<'a>(entries: impl IntoIterator<Item = &'a Entry>) -> Self {
        let mut counts = Self {
            keep_zeros: true,
            ..Self::default()
        };
        for entry in entries {
            counts.add(entry);
        }
        counts
    }

    pub fn add(&mut self, entry: &Entry) {
        *self.counts.entry(entry.outcome()).or_insert(0) += 1;
    }

    #[must_use]
    pub fn get(&self, outcome: Outcome) -> usize {
        self.counts.get(&outcome).copied().unwrap_or(0)
    }

    #[must_use]
    pub fn total(&self) -> usize {
        self.counts.values().sum()
    }

    /// The counts, written with a 0 for each outcome that no test has.
    #[must_use]
    pub fn with_zeros(self) -> Self {
        Self {
            keep_zeros: true,
            ..self
        }
    }
}

impl<'de> Deserialize<'de> for Counts {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(Self {
            counts: BTreeMap::deserialize(deserializer)?,
            keep_zeros: false,
        })
    }
}

impl Serialize for Counts {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_map(
            Outcome::ALL
                .into_iter()
                .map(|outcome| (outcome.as_str(), self.get(outcome)))
                .filter(|(_, count)| self.keep_zeros || *count > 0),
        )
    }
}

/// One row of the blockers table: a diagnostic code, a built-in that throws a late
/// rejection, or a harness file that does not compile. `files` counts the tests that it
/// blocks, and `only` the tests where it is the only blocker.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Blocker {
    pub blocker: String,
    pub files: usize,
    pub only: usize,
}

/// The blockers table of the sets of blockers of each blocked test, sorted by `only`, then
/// by `files`, then by name.
#[must_use]
pub fn blockers<'a>(blocked: impl IntoIterator<Item = &'a Vec<String>>) -> Vec<Blocker> {
    let mut table: BTreeMap<&str, Blocker> = BTreeMap::new();
    for set in blocked {
        for name in set {
            let row = table.entry(name).or_insert_with(|| Blocker {
                blocker: name.clone(),
                files: 0,
                only: 0,
            });
            row.files += 1;
            row.only += usize::from(set.len() == 1);
        }
    }
    let mut rows: Vec<Blocker> = table.into_values().collect();
    rows.sort_by(|a, b| (b.only, b.files, &a.blocker).cmp(&(a.only, a.files, &b.blocker)));
    rows
}

/// `target/suites/<suite>/results.json`: the facts of one run, for the CI artifact.
#[derive(Debug, Serialize)]
pub struct Results {
    pub date: String,
    pub host: String,
    pub tools: BTreeMap<String, String>,
    pub durations_ms: BTreeMap<String, u128>,
    pub tests: BTreeMap<String, TestResult>,
}

/// The result of one id: its outcome, its time in each mode, and a detail of at most
/// `DETAIL_BYTES`.
#[derive(Debug, Serialize)]
pub struct TestResult {
    pub outcome: String,
    pub time_ms: BTreeMap<String, u128>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub detail: String,
}

pub const DETAIL_BYTES: usize = 500;

/// `text` cut to at most `DETAIL_BYTES`, at a character boundary.
#[must_use]
pub fn detail(text: &str) -> String {
    let end = (0..=text.len().min(DETAIL_BYTES))
        .rev()
        .find(|index| text.is_char_boundary(*index))
        .unwrap_or(0);
    text[..end].to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_only_blocker_ranks_first() {
        let blocked = [
            vec!["BUOY206".to_owned(), "harness/assert.js".to_owned()],
            vec!["harness/assert.js".to_owned()],
            vec!["BUOY206".to_owned(), "harness/assert.js".to_owned()],
        ];
        assert_eq!(
            blockers(&blocked),
            [
                Blocker {
                    blocker: "harness/assert.js".to_owned(),
                    files: 3,
                    only: 1
                },
                Blocker {
                    blocker: "BUOY206".to_owned(),
                    files: 2,
                    only: 0
                },
            ]
        );
    }

    #[test]
    fn counts_keep_zeros_only_for_the_suite() {
        let entries = [Entry::Same(Outcome::Pass)];
        let every = serde_json::to_string(&Counts::every(&entries)).expect("serializes");
        assert!(every.starts_with(r#"{"pass":1,"rejected":0,"#), "{every}");
        let mut group = Counts::default();
        group.add(&entries[0]);
        assert_eq!(
            serde_json::to_string(&group).expect("serializes"),
            r#"{"pass":1}"#
        );
    }

    #[test]
    fn a_detail_stops_at_a_character_boundary() {
        let text = "é".repeat(400);
        assert_eq!(detail(&text).len(), DETAIL_BYTES);
        assert_eq!(detail("short"), "short");
    }
}
