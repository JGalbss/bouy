//! The summary of the runs: the median and the range of each metric, the memory per
//! actor, and the Markdown table that the harness prints.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt::Write;

use serde::{Deserialize, Serialize};

use crate::results::{Outcome, Results, Run, Suite};

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Spread {
    pub median: f64,
    pub min: f64,
    pub max: f64,
}

/// The median, minimum, and maximum of `values`, or `None` when there are none.
pub fn spread(values: &[f64]) -> Option<Spread> {
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let middle = sorted.len() / 2;
    let median = match sorted.len() % 2 {
        1 => sorted[middle],
        _ => (sorted.get(middle.checked_sub(1)?)? + sorted[middle]) / 2.0,
    };
    Some(Spread {
        median,
        min: *sorted.first()?,
        max: *sorted.last()?,
    })
}

/// Each numeric field of the JSON lines of the measured runs, with `wall_ms` and
/// `peak_rss_mib`, which the harness measures from outside.
pub fn summarize(runs: &[Run]) -> BTreeMap<String, Spread> {
    let mut samples: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    for run in runs {
        let Outcome::Measured {
            wall_ms,
            peak_rss_kib,
            result,
        } = &run.outcome
        else {
            continue;
        };
        let fields = result
            .iter()
            .filter_map(|(key, value)| Some((key.clone(), value.as_f64()?)));
        let outside = [
            ("wall_ms".to_owned(), *wall_ms),
            ("peak_rss_mib".to_owned(), mib(*peak_rss_kib)),
        ];
        for (metric, value) in fields.chain(outside) {
            samples.entry(metric).or_default().push(value);
        }
    }
    samples
        .into_iter()
        .filter_map(|(metric, values)| Some((metric, spread(&values)?)))
        .collect()
}

/// Adds `rss_per_actor_bytes` to each program whose result counts `actors`: the peak RSS
/// of each run above the median peak RSS of `startup` on the same runtime, per actor.
pub fn add_memory_per_actor(suites: &mut [Suite]) {
    let baselines: HashMap<&str, f64> = suites
        .iter()
        .filter(|suite| suite.name == "startup")
        .flat_map(|suite| &suite.programs)
        .filter_map(|program| Some((program.runtime, program.summary.get("peak_rss_mib")?.median)))
        .collect();
    for program in suites.iter_mut().flat_map(|suite| &mut suite.programs) {
        let Some(baseline) = baselines.get(program.runtime) else {
            continue;
        };
        let per_actor: Vec<f64> = program
            .runs
            .iter()
            .filter_map(|run| match &run.outcome {
                Outcome::Measured {
                    peak_rss_kib,
                    result,
                    ..
                } => {
                    let actors = result
                        .get("actors")?
                        .as_f64()
                        .filter(|&actors| actors > 0.0)?;
                    Some((mib(*peak_rss_kib) - baseline) * 1024.0 * 1024.0 / actors)
                }
                Outcome::Failed { .. } => None,
            })
            .collect();
        if let Some(spread) = spread(&per_actor) {
            program
                .summary
                .insert("rss_per_actor_bytes".to_owned(), spread);
        }
    }
}

/// A Markdown table with one row for each metric of each suite: a cell for each runtime,
/// then the ratio of the Bouy median to the Bun median.
pub fn table(results: &Results) -> String {
    let Results {
        date, host, tools, ..
    } = results;
    let load = results
        .load_1m
        .as_ref()
        .map_or_else(|| "unknown".to_owned(), cell);
    let mut table = format!(
        "Bouy, Node, and Bun on {date}, {name}: {cpu}, {cores} cores, {os}.\n\
         bouy {commit} ({bouy}), OTP {otp}, Node {node}, Bun {bun}. Measured runs per program: \
         {runs}, after one warm-up run. A cell is the median (min–max). Bouy/Bun is the ratio \
         of the medians. 1-minute load average: {load}.\n\n\
         | Suite | Metric | Bouy | Node | Bun | Bouy/Bun |\n| --- | --- | --: | --: | --: | --: |\n",
        name = host.name,
        cpu = host.cpu,
        cores = host.cores,
        os = host.os,
        commit = tools.commit,
        bouy = tools.bouy,
        otp = tools.otp,
        node = tools.node,
        bun = tools.bun,
        runs = results.runs,
    );
    for suite in &results.suites {
        let metrics: BTreeSet<&str> = suite
            .programs
            .iter()
            .flat_map(|program| program.summary.keys().map(String::as_str))
            .collect();
        for metric in metrics {
            let cells: Vec<String> = suite
                .programs
                .iter()
                .map(|program| {
                    program
                        .summary
                        .get(metric)
                        .map_or_else(|| "—".to_owned(), cell)
                })
                .collect();
            let _ = writeln!(
                table,
                "| {} | {metric} | {} | {} |",
                suite.name,
                cells.join(" | "),
                ratio(suite, metric)
            );
        }
        if suite.programs.iter().any(|program| program.failed > 0) {
            let failed: Vec<String> = suite
                .programs
                .iter()
                .map(|program| program.failed.to_string())
                .collect();
            let _ = writeln!(
                table,
                "| {} | failed runs | {} | |",
                suite.name,
                failed.join(" | ")
            );
        }
    }
    table
}

/// The Bouy median over the Bun median of `metric`, or `—` when one is missing or zero.
fn ratio(suite: &Suite, metric: &str) -> String {
    let median = |runtime: &str| {
        suite
            .programs
            .iter()
            .find(|program| program.runtime == runtime)
            .and_then(|program| program.summary.get(metric))
            .map(|spread| spread.median)
    };
    match (median("bouy"), median("bun")) {
        (Some(bouy), Some(bun)) if bun != 0.0 => number(bouy / bun),
        _ => "—".to_owned(),
    }
}

fn mib(kib: u32) -> f64 {
    f64::from(kib) / 1024.0
}

/// `median (min–max)`, or the median alone when the range rounds to one number.
fn cell(spread: &Spread) -> String {
    let (median, min, max) = (
        number(spread.median),
        number(spread.min),
        number(spread.max),
    );
    if min == max {
        median
    } else {
        format!("{median} ({min}–{max})")
    }
}

/// Three significant digits or more, with thousands separators: `1,013,171`, `412`,
/// `10.3`, `3.03`, `0.166`. A whole number has no decimals.
pub fn number(value: f64) -> String {
    let decimals = match value.abs() {
        magnitude if magnitude >= 100.0 || value.fract().abs() < f64::EPSILON => 0,
        magnitude if magnitude >= 10.0 => 1,
        magnitude if magnitude >= 1.0 => 2,
        _ => 3,
    };
    let text = format!("{value:.decimals$}");
    let (integer, fraction) = text.split_at(text.find('.').unwrap_or(text.len()));
    let (sign, digits) = integer
        .strip_prefix('-')
        .map_or(("", integer), |digits| ("-", digits));
    let mut grouped = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(digit);
    }
    format!("{sign}{grouped}{fraction}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn takes_the_median_and_the_range() {
        let odd = spread(&[5.0, 1.0, 3.0]).expect("three values");
        assert_eq!((odd.median, odd.min, odd.max), (3.0, 1.0, 5.0));
        let even = spread(&[4.0, 1.0, 2.0, 3.0]).expect("four values");
        assert_eq!((even.median, even.min, even.max), (2.5, 1.0, 4.0));
        assert!(spread(&[]).is_none());
    }

    #[test]
    fn prints_numbers_for_people() {
        assert_eq!(number(24_409_345.2), "24,409,345");
        assert_eq!(number(-1234.0), "-1,234");
        assert_eq!(number(412.4), "412");
        assert_eq!(number(10.32), "10.3");
        assert_eq!(number(3.034), "3.03");
        assert_eq!(number(0.1662), "0.166");
        assert_eq!(number(0.0), "0");
        assert_eq!(number(27.0), "27");
        let flat = Spread {
            median: 2000.1,
            min: 1999.9,
            max: 2000.2,
        };
        assert_eq!(cell(&flat), "2,000");
        let wide = Spread {
            median: 2.0,
            min: 1.0,
            max: 4.0,
        };
        assert_eq!(cell(&wide), "2 (1–4)");
    }

    #[test]
    fn divides_the_bouy_median_by_the_bun_median() {
        let program = |runtime, median| crate::results::Program {
            runtime,
            failed: 0,
            summary: [(
                "wall_ms".to_owned(),
                Spread {
                    median,
                    min: median,
                    max: median,
                },
            )]
            .into(),
            runs: Vec::new(),
        };
        let mut suite = Suite {
            name: "startup".to_owned(),
            programs: vec![
                program("bouy", 50.0),
                program("node", 70.0),
                program("bun", 100.0),
            ],
        };
        assert_eq!(ratio(&suite, "wall_ms"), "0.500");
        assert_eq!(ratio(&suite, "pings"), "—");
        suite.programs[2] = program("bun", 0.0);
        assert_eq!(ratio(&suite, "wall_ms"), "—");
    }
}
