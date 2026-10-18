//! The comparison of section 3.3 of docs/design/testing.md: the run against the expectation
//! file of the pull request and the file of the base commit.

use std::collections::BTreeSet;
use std::fmt::Write as _;

use crate::expectations::{Entry, Expectations};
use crate::outcome::Outcome;

/// Where the tests of a suite come from. A move from loud to silent is a regression in a
/// Buoy corpus, whose programs were written for the behavior that they check. In an
/// upstream suite it usually shows an old gap.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Origin {
    Upstream,
    Corpus,
}

/// One id whose outcome moved.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Move {
    pub id: String,
    pub before: Entry,
    pub after: Entry,
}

/// The findings of section 3.3, each list sorted by id.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Comparison {
    pub regressions: Vec<Move>,
    pub newly_silent: Vec<Move>,
    /// The ids that pass in a mode where they did not pass before.
    pub new_passes: Vec<Move>,
    /// Each line of the pull request's file that the run contradicts, matches no test, or
    /// is missing.
    pub stale: Vec<String>,
}

/// Compares `run`, the entries of the ids that ran, with the file of the pull request and,
/// when there is one, the file of the base commit. `tests` holds every id of the suite,
/// so a line that matches no test and a test with no line show as stale.
#[must_use]
pub fn compare(
    origin: Origin,
    run: &Expectations,
    tests: &BTreeSet<String>,
    pull_request: &Expectations,
    base: Option<&Expectations>,
) -> Comparison {
    let mut comparison = Comparison::default();
    for (id, after) in run {
        let before = base.unwrap_or(pull_request).get(id);
        if let Some(before) = before {
            let moved = || Move {
                id: id.clone(),
                before: before.clone(),
                after: after.clone(),
            };
            let pairs = before.moves(after);
            if pairs
                .iter()
                .any(|(before, after)| regresses(origin, *before, *after))
            {
                comparison.regressions.push(moved());
            } else if origin == Origin::Upstream
                && pairs
                    .iter()
                    .any(|(before, after)| before.rank() == 1 && after.rank() == 2)
            {
                comparison.newly_silent.push(moved());
            } else if pairs
                .iter()
                .any(|(before, after)| *before != Outcome::Pass && *after == Outcome::Pass)
            {
                comparison.new_passes.push(moved());
            }
        }
        match pull_request.get(id) {
            Some(expected) if expected == after => {}
            Some(expected) => comparison.stale.push(format!(
                "{id}: the file says {expected}, and the run gives {after}"
            )),
            None if tests.contains(id) => comparison
                .stale
                .push(format!("{id}: the test has no line; the run gives {after}")),
            None => {}
        }
    }
    comparison.stale.extend(
        pull_request
            .keys()
            .filter(|id| !tests.contains(*id))
            .map(|id| format!("{id}: the line matches no test")),
    );
    comparison.stale.sort();
    comparison
}

fn regresses(origin: Origin, before: Outcome, after: Outcome) -> bool {
    (before == Outcome::Pass && after != Outcome::Pass)
        || (after == Outcome::Crash && before != Outcome::Crash)
        || (origin == Origin::Corpus && before.rank() == 1 && after.rank() == 2)
}

impl Comparison {
    /// Whether CI fails: a regression that no `accept-regression` label accepts, or a stale
    /// line.
    #[must_use]
    pub fn fails(&self, accept_regressions: bool) -> bool {
        (!self.regressions.is_empty() && !accept_regressions) || !self.stale.is_empty()
    }

    /// The report: the regressions, the newly silent ids, then the stale lines, each list
    /// cut at `limit` lines.
    #[must_use]
    pub fn report(&self, update: &str, limit: usize) -> String {
        let mut report = String::new();
        let moves = |moves: &[Move]| -> Vec<String> {
            moves
                .iter()
                .map(|found| format!("{} {} (previously {})", found.id, found.after, found.before))
                .collect()
        };
        section(&mut report, "regressions", &moves(&self.regressions), limit);
        section(
            &mut report,
            "newly silent",
            &moves(&self.newly_silent),
            limit,
        );
        section(&mut report, "stale lines", &self.stale, limit);
        if !self.stale.is_empty() {
            let _ = writeln!(report, "To record this run, run `{update}`.");
        }
        report
    }

    /// The section of one suite in the pull request comment of section 6: `heading`, then
    /// the regressions, the newly silent ids, and the new passes, each in a collapsed list
    /// cut at `limit` lines, then the count of stale lines.
    #[must_use]
    pub fn comment(&self, heading: &str, limit: usize) -> String {
        let mut comment = format!("{heading}\n");
        for (title, moves) in [
            ("regressions", &self.regressions),
            ("newly silent", &self.newly_silent),
            ("new passes", &self.new_passes),
        ] {
            if moves.is_empty() {
                let _ = writeln!(comment, "0 {title}.\n");
                continue;
            }
            let _ = writeln!(
                comment,
                "<details><summary>{} {title}</summary>\n",
                moves.len()
            );
            for found in moves.iter().take(limit) {
                let _ = writeln!(
                    comment,
                    "- `{}` {} (previously {})",
                    found.id, found.after, found.before
                );
            }
            if moves.len() > limit {
                let _ = writeln!(
                    comment,
                    "- and {} more; `results.json` in the artifact of the run lists every id",
                    moves.len() - limit
                );
            }
            comment.push_str("\n</details>\n\n");
        }
        if !self.stale.is_empty() {
            let _ = writeln!(
                comment,
                "{} stale lines: the job fails until the expectation file records this run.\n",
                self.stale.len()
            );
        }
        comment
    }
}

fn section(report: &mut String, title: &str, lines: &[String], limit: usize) {
    if lines.is_empty() {
        return;
    }
    let _ = writeln!(report, "{} {title}:", lines.len());
    for line in lines.iter().take(limit) {
        let _ = writeln!(report, "  {line}");
    }
    if lines.len() > limit {
        let _ = writeln!(
            report,
            "  and {} more; results.json lists every id",
            lines.len() - limit
        );
    }
}

/// Which ids a run of an upstream suite executes (section 3.7).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Selection {
    /// Every id, as the nightly job runs them.
    All,
    /// The ids that the file expects to pass in some mode, the fixed 10% sample, and the
    /// ids with no line. test262 also leaves out its nightly-only directories.
    PullRequest,
}

impl Selection {
    /// Whether the selection runs `id`, whose line in the expectation file is `expected`.
    #[must_use]
    pub fn includes(self, id: &str, expected: Option<&Entry>) -> bool {
        match self {
            Self::All => true,
            Self::PullRequest => {
                expected.is_none_or(|entry| entry.passes_in_a_mode() || is_sampled(id))
            }
        }
    }
}

/// Whether `id` belongs to the fixed sample of section 3.7: the ids whose 32-bit FNV-1a
/// hash of their UTF-8 bytes, modulo 100, is below 10.
#[must_use]
pub fn is_sampled(id: &str) -> bool {
    fnv1a(id) % 100 < 10
}

fn fnv1a(text: &str) -> u32 {
    text.bytes().fold(0x811c_9dc5, |hash, byte| {
        (hash ^ u32::from(byte)).wrapping_mul(0x0100_0193)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hash_is_fnv1a() {
        assert_eq!(fnv1a(""), 0x811c_9dc5);
        assert_eq!(fnv1a("a"), 0xe40c_292c);
        assert_eq!(fnv1a("foobar"), 0xbf9c_f968);
    }
}
