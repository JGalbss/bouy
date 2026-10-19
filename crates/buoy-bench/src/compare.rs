//! The nightly comparison of section 5.11 of docs/design/testing.md. The Buoy medians of
//! the previous and the current nightly runs are each compared with the run before them,
//! the baseline, with the limits of `bench/thresholds.json`. Both runs need the same
//! baseline: compared night to night, a lasting slowdown is past its limit once only.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::fs;
use std::path::Path;

use serde::Deserialize;

use crate::summary::{Spread, number};

/// For each suite and metric of the Buoy program, the largest allowed change of the
/// median, as the ratio of the new median to the baseline median. A limit above 1 is a
/// ceiling, for a metric where less is better, such as `wall_ms`. A limit below 1 is a
/// floor, for a metric where more is better, such as `casts_per_s`.
pub type Limits = BTreeMap<String, BTreeMap<String, f64>>;

/// The part of a results file that the comparison reads.
#[derive(Debug, Deserialize)]
pub struct Recorded {
    #[serde(skip)]
    file: String,
    host: RecordedHost,
    suites: Vec<RecordedSuite>,
}

#[derive(Debug, Deserialize)]
struct RecordedHost {
    name: String,
}

#[derive(Debug, Deserialize)]
struct RecordedSuite {
    name: String,
    programs: Vec<RecordedProgram>,
}

#[derive(Debug, Deserialize)]
struct RecordedProgram {
    runtime: Runtime,
    summary: BTreeMap<String, Spread>,
}

#[derive(Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "kebab-case")]
enum Runtime {
    Buoy,
    Node,
    Bun,
    NodeIsolated,
    BunIsolated,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Within,
    /// The current median is past the limit, and the previous one is not: a warning,
    /// because a hosted runner is noisy.
    PastOnce,
    /// The previous and the current medians are both past the limit: a failure.
    PastTwice,
}

#[derive(Debug)]
pub struct Row {
    suite: String,
    metric: String,
    limit: f64,
    baseline: f64,
    /// The median of the previous run when it exists, then of the current run.
    medians: Vec<f64>,
    pub verdict: Verdict,
}

pub fn load_limits(path: &Path) -> Result<Limits, String> {
    let text = fs::read_to_string(path)
        .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
    let limits: Limits = serde_json::from_str(&text)
        .map_err(|error| format!("{} is not a limits file: {error}", path.display()))?;
    let invalid = limits.iter().find_map(|(suite, metrics)| {
        metrics
            .iter()
            .find(|&(_, &limit)| {
                !(limit > 0.0 && limit.is_finite() && (limit - 1.0).abs() > f64::EPSILON)
            })
            .map(|(metric, limit)| format!("{suite} {metric}: {limit}"))
    });
    match invalid {
        Some(entry) => Err(format!(
            "{}: a limit is a ratio above 0 and other than 1, not {entry}",
            path.display()
        )),
        None => Ok(limits),
    }
}

pub fn load_results(path: &Path) -> Result<Recorded, String> {
    let text = fs::read_to_string(path)
        .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
    let mut recorded: Recorded = serde_json::from_str(&text)
        .map_err(|error| format!("{} is not a results file: {error}", path.display()))?;
    recorded.file = path.display().to_string();
    Ok(recorded)
}

impl Recorded {
    fn median(&self, suite: &str, metric: &str) -> Result<f64, String> {
        self.suites
            .iter()
            .filter(|found| found.name == suite)
            .flat_map(|found| &found.programs)
            .find(|program| program.runtime == Runtime::Buoy)
            .and_then(|program| program.summary.get(metric))
            .map(|spread| spread.median)
            .ok_or_else(|| {
                format!(
                    "{} has no Buoy median of {suite} {metric}, which the limits name",
                    self.file
                )
            })
    }
}

/// One row for each limit. `results` holds the baseline, then the previous run when it
/// exists, then the current run, all from one host.
pub fn rows(limits: &Limits, results: &[Recorded]) -> Result<Vec<Row>, String> {
    let [baseline, runs @ ..] = results else {
        return Err("no results to compare".to_owned());
    };
    if let Some(other) = runs.iter().find(|run| run.host.name != baseline.host.name) {
        return Err(format!(
            "{} comes from the host {} and {} from {}; compare the runs of one host",
            baseline.file, baseline.host.name, other.file, other.host.name
        ));
    }
    let mut rows = Vec::new();
    for (suite, metrics) in limits {
        for (metric, &limit) in metrics {
            let base = baseline.median(suite, metric)?;
            if base <= 0.0 {
                return Err(format!(
                    "{}: the median of {suite} {metric} is {base}, so no ratio exists",
                    baseline.file
                ));
            }
            let medians = runs
                .iter()
                .map(|run| run.median(suite, metric))
                .collect::<Result<Vec<f64>, String>>()?;
            let past: Vec<bool> = medians
                .iter()
                .map(|median| is_past(limit, median / base))
                .collect();
            let verdict = match past.as_slice() {
                [.., true, true] => Verdict::PastTwice,
                [.., true] => Verdict::PastOnce,
                _ => Verdict::Within,
            };
            rows.push(Row {
                suite: suite.clone(),
                metric: metric.clone(),
                limit,
                baseline: base,
                medians,
                verdict,
            });
        }
    }
    Ok(rows)
}

fn is_past(limit: f64, ratio: f64) -> bool {
    if limit > 1.0 {
        ratio > limit
    } else {
        ratio < limit
    }
}

/// A Markdown report: a table with one row for each limit, then the counts.
pub fn report(results: &[Recorded], rows: &[Row]) -> String {
    let labels = ["Previous", "Current"];
    let labels = &labels[labels.len().saturating_sub(results.len().saturating_sub(1))..];
    let files: Vec<&str> = results.iter().map(|run| run.file.as_str()).collect();
    let mut report = format!(
        "Buoy medians of {}. A cell after the baseline is the median and its ratio to the \
         baseline median.\n\n| Suite | Metric | Limit | Baseline | {} | Result |\n\
         | --- | --- | --: | --: | {}--- |\n",
        files.join(", then "),
        labels.join(" | "),
        "--: | ".repeat(labels.len()),
    );
    for row in rows {
        let cells: Vec<String> = row
            .medians
            .iter()
            .map(|median| format!("{} ({:.2})", number(*median), median / row.baseline))
            .collect();
        let result = match row.verdict {
            Verdict::Within => "within",
            Verdict::PastOnce => "past once: a warning",
            Verdict::PastTwice => "past twice: a failure",
        };
        let _ = writeln!(
            report,
            "| {} | {} | {} | {} | {} | {result} |",
            row.suite,
            row.metric,
            row.limit,
            number(row.baseline),
            cells.join(" | ")
        );
    }
    let count = |verdict| rows.iter().filter(|row| row.verdict == verdict).count();
    let _ = write!(
        report,
        "\n{} limits: {} within, {} past once, {} past in two runs in a row.",
        rows.len(),
        count(Verdict::Within),
        count(Verdict::PastOnce),
        count(Verdict::PastTwice),
    );
    report
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    fn bench() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../bench")
    }

    /// A results file of `host` with one Buoy median for each `(suite, metric, median)`.
    fn recorded(host: &str, medians: &[(&str, &str, f64)]) -> Recorded {
        let suites: Vec<serde_json::Value> = medians
            .iter()
            .map(|(suite, metric, median)| {
                let spread =
                    |median| serde_json::json!({ "median": median, "min": 0, "max": median });
                serde_json::json!({
                    "name": suite,
                    "programs": [
                        { "runtime": "buoy", "summary": { *metric: spread(*median) } },
                        { "runtime": "node", "summary": { *metric: spread(1.0e9) } },
                        { "runtime": "bun", "summary": { *metric: spread(1.0e9) } },
                        { "runtime": "node-isolated", "summary": { *metric: spread(1.0e9) } },
                        { "runtime": "bun-isolated", "summary": { *metric: spread(1.0e9) } },
                    ],
                })
            })
            .collect();
        let json = serde_json::json!({ "host": { "name": host }, "suites": suites });
        let mut recorded: Recorded = serde_json::from_value(json).expect("a results file");
        recorded.file = format!("{host}.json");
        recorded
    }

    fn verdict(limit: f64, medians: &[f64]) -> Verdict {
        let limits: Limits =
            [("startup".to_owned(), [("wall_ms".to_owned(), limit)].into())].into();
        let results: Vec<Recorded> = medians
            .iter()
            .map(|&median| recorded("host", &[("startup", "wall_ms", median)]))
            .collect();
        let rows = rows(&limits, &results).expect("comparable results");
        rows[0].verdict
    }

    #[test]
    fn fails_a_metric_past_its_limit_in_two_runs_in_a_row() {
        assert_eq!(verdict(1.3, &[100.0, 140.0, 140.0]), Verdict::PastTwice);
        assert_eq!(verdict(1.3, &[100.0, 100.0, 140.0]), Verdict::PastOnce);
        assert_eq!(verdict(1.3, &[100.0, 140.0, 100.0]), Verdict::Within);
        assert_eq!(verdict(1.3, &[100.0, 140.0]), Verdict::PastOnce);
        assert_eq!(verdict(1.3, &[100.0, 130.0]), Verdict::Within);
        assert_eq!(verdict(0.8, &[100.0, 70.0, 75.0]), Verdict::PastTwice);
        assert_eq!(verdict(0.8, &[100.0, 140.0, 120.0]), Verdict::Within);
    }

    #[test]
    fn refuses_results_that_cannot_be_compared() {
        let limits: Limits = [("startup".to_owned(), [("wall_ms".to_owned(), 1.3)].into())].into();
        let one = recorded("one", &[("startup", "wall_ms", 100.0)]);
        let two = recorded("two", &[("startup", "wall_ms", 100.0)]);
        let error = rows(&limits, &[one, two]).expect_err("two hosts");
        assert!(error.contains("compare the runs of one host"), "{error}");
        let stale = recorded("one", &[("startup", "peak_rss_mib", 100.0)]);
        let error = rows(&limits, &[stale]).expect_err("no median");
        assert!(
            error.contains("no Buoy median of startup wall_ms"),
            "{error}"
        );
    }

    /// Each suite in `bench/programs` has limits, and each limit names a Buoy metric of the
    /// latest committed results file that runs every suite. A run of a few suites, which
    /// `--suites` records, names no metric of the others.
    #[test]
    fn the_committed_limits_match_the_suites_and_the_results() {
        let limits = load_limits(&bench().join("thresholds.json")).expect("the committed limits");
        let mut suites: Vec<String> = fs::read_dir(bench().join("programs"))
            .expect("bench/programs")
            .filter_map(|entry| Some(entry.ok()?.path()))
            .filter(|path| path.join("buoy.ts").is_file())
            .filter_map(|path| Some(path.file_name()?.to_string_lossy().into_owned()))
            .collect();
        suites.sort();
        assert_eq!(limits.keys().cloned().collect::<Vec<_>>(), suites);
        let mut files: Vec<PathBuf> = fs::read_dir(bench().join("results"))
            .expect("bench/results")
            .filter_map(|entry| Some(entry.ok()?.path()))
            .collect();
        files.sort();
        let latest = files
            .iter()
            .rev()
            .map(|file| load_results(file).expect("a results file"))
            .find(|recorded| {
                suites
                    .iter()
                    .all(|suite| recorded.suites.iter().any(|found| &found.name == suite))
            })
            .expect("a committed results file of every suite");
        let results = [latest];
        let rows = rows(&limits, &results).expect("each limit names a metric");
        assert_eq!(
            rows.len(),
            limits.values().map(BTreeMap::len).sum::<usize>()
        );
    }
}
