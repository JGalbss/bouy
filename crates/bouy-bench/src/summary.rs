//! The summary of the runs: the median and the range of each metric, the memory per
//! actor, and the Markdown table that the harness prints.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt::Write;

use serde::{Deserialize, Serialize};

use crate::results::{Outcome, Program, Results, Run, Suite};

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

/// The runtimes in the order of the table columns.
const RUNTIMES: [&str; 5] = ["bouy", "node", "bun", "node-isolated", "bun-isolated"];

/// Adds `rss_per_actor_bytes` to each program whose result counts `actors`: the peak RSS
/// of each run above the median peak RSS of `startup` on the same runtime, per actor.
/// `startup` has no isolated program, so an isolated program takes the baseline of its
/// plain runtime.
pub fn add_memory_per_actor(suites: &mut [Suite]) {
    let baselines: HashMap<&str, f64> = suites
        .iter()
        .filter(|suite| suite.name == "startup")
        .flat_map(|suite| &suite.programs)
        .filter_map(|program| Some((program.runtime, program.summary.get("peak_rss_mib")?.median)))
        .collect();
    for program in suites.iter_mut().flat_map(|suite| &mut suite.programs) {
        let runtime = program.runtime.trim_end_matches("-isolated");
        let Some(baseline) = baselines.get(runtime) else {
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
/// then the ratios of the Bouy median to the Bun medians of the same-thread and the
/// isolated programs. A suite without a program of a runtime has `—` in its column.
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
         {runs}, after one warm-up run. A cell is the median (min–max). Bouy/Bun and Bouy/Bun \
         isolated are the ratios of the Bouy median to the Bun median of the same-thread and \
         the isolated program. 1-minute load average: {load}.\n\n\
         | Suite | Metric | Bouy | Node | Bun | Node isolated | Bun isolated | Bouy/Bun | \
         Bouy/Bun isolated |\n| --- | --- | --: | --: | --: | --: | --: | --: | --: |\n",
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
            let cells: Vec<String> = RUNTIMES
                .iter()
                .map(|runtime| {
                    program(suite, runtime)
                        .and_then(|program| program.summary.get(metric))
                        .map_or_else(|| "—".to_owned(), cell)
                })
                .collect();
            let _ = writeln!(
                table,
                "| {} | {metric} | {} | {} | {} |",
                suite.name,
                cells.join(" | "),
                ratio(suite, metric, "bun"),
                ratio(suite, metric, "bun-isolated")
            );
        }
        if suite.programs.iter().any(|program| program.failed > 0) {
            let failed: Vec<String> = RUNTIMES
                .iter()
                .map(|runtime| {
                    program(suite, runtime)
                        .map_or_else(|| "—".to_owned(), |program| program.failed.to_string())
                })
                .collect();
            let _ = writeln!(
                table,
                "| {} | failed runs | {} | | |",
                suite.name,
                failed.join(" | ")
            );
        }
    }
    table
}

fn program<'suite>(suite: &'suite Suite, runtime: &str) -> Option<&'suite Program> {
    suite
        .programs
        .iter()
        .find(|program| program.runtime == runtime)
}

/// The Bouy median over the median of `metric` on `baseline`, or `—` when one is missing
/// or zero.
fn ratio(suite: &Suite, metric: &str, baseline: &str) -> String {
    let median = |runtime: &str| {
        program(suite, runtime)
            .and_then(|program| program.summary.get(metric))
            .map(|spread| spread.median)
    };
    match (median("bouy"), median(baseline)) {
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

    fn flat(median: f64) -> Spread {
        Spread {
            median,
            min: median,
            max: median,
        }
    }

    fn program(runtime: &'static str, metric: &str, median: f64) -> Program {
        Program {
            runtime,
            failed: 0,
            summary: [(metric.to_owned(), flat(median))].into(),
            runs: Vec::new(),
        }
    }

    #[test]
    fn divides_the_bouy_median_by_the_bun_median() {
        let mut suite = Suite {
            name: "startup".to_owned(),
            programs: vec![
                program("bouy", "wall_ms", 50.0),
                program("node", "wall_ms", 70.0),
                program("bun", "wall_ms", 100.0),
                program("node-isolated", "wall_ms", 150.0),
                program("bun-isolated", "wall_ms", 200.0),
            ],
        };
        assert_eq!(ratio(&suite, "wall_ms", "bun"), "0.500");
        assert_eq!(ratio(&suite, "wall_ms", "bun-isolated"), "0.250");
        assert_eq!(ratio(&suite, "pings", "bun"), "—");
        suite.programs[2] = program("bun", "wall_ms", 0.0);
        assert_eq!(ratio(&suite, "wall_ms", "bun"), "—");
        suite.programs.truncate(3);
        assert_eq!(ratio(&suite, "wall_ms", "bun-isolated"), "—");
    }

    #[test]
    fn keeps_the_columns_of_a_suite_without_isolated_programs() {
        let mut spawn = Suite {
            name: "spawn".to_owned(),
            programs: ["bouy", "node", "bun", "node-isolated", "bun-isolated"]
                .map(|runtime| program(runtime, "per_actor_us", 2.0))
                .into(),
        };
        spawn.programs[4].failed = 1;
        let startup = Suite {
            name: "startup".to_owned(),
            programs: ["bouy", "node", "bun"]
                .map(|runtime| program(runtime, "wall_ms", 4.0))
                .into(),
        };
        let results = Results {
            date: "2026-10-17".to_owned(),
            host: crate::environment::Host {
                name: "host".to_owned(),
                cpu: "cpu".to_owned(),
                cores: 1,
                os: "os".to_owned(),
            },
            tools: crate::environment::Tools {
                commit: "abc".to_owned(),
                bouy: "bouy".to_owned(),
                otp: "otp".to_owned(),
                node: "node".to_owned(),
                bun: "bun".to_owned(),
            },
            runs: 1,
            load_1m: None,
            suites: vec![spawn, startup],
        };
        let table = table(&results);
        let rows: Vec<&str> = table.lines().filter(|line| line.starts_with('|')).collect();
        assert_eq!(
            rows,
            [
                "| Suite | Metric | Bouy | Node | Bun | Node isolated | Bun isolated | Bouy/Bun | \
                 Bouy/Bun isolated |",
                "| --- | --- | --: | --: | --: | --: | --: | --: | --: |",
                "| spawn | per_actor_us | 2 | 2 | 2 | 2 | 2 | 1 | 1 |",
                "| spawn | failed runs | 0 | 0 | 0 | 0 | 1 | | |",
                "| startup | wall_ms | 4 | 4 | 4 | — | — | 1 | — |",
            ]
        );
    }

    #[test]
    fn takes_the_startup_baseline_of_the_plain_runtime_for_an_isolated_program() {
        let run = |peak_rss_mib: u32, actors: u32| Run {
            load_before: [0.0; 3],
            load_after: [0.0; 3],
            outcome: Outcome::Measured {
                wall_ms: 1.0,
                peak_rss_kib: peak_rss_mib * 1024,
                result: [("actors".to_owned(), actors.into())].into_iter().collect(),
            },
        };
        let mut suites = [
            Suite {
                name: "startup".to_owned(),
                programs: vec![program("node", "peak_rss_mib", 80.0)],
            },
            Suite {
                name: "spawn".to_owned(),
                programs: vec![
                    Program {
                        runs: vec![run(180, 100_000)],
                        ..program("node", "actors", 100_000.0)
                    },
                    Program {
                        runs: vec![run(112, 32)],
                        ..program("node-isolated", "actors", 32.0)
                    },
                    Program {
                        runs: vec![run(112, 32)],
                        ..program("bun-isolated", "actors", 32.0)
                    },
                ],
            },
        ];
        add_memory_per_actor(&mut suites);
        let per_actor = |index: usize| {
            suites[1].programs[index]
                .summary
                .get("rss_per_actor_bytes")
                .map(|spread| spread.median)
        };
        assert_eq!(per_actor(0), Some(100.0 * 1024.0 * 1024.0 / 100_000.0));
        assert_eq!(per_actor(1), Some(1024.0 * 1024.0));
        assert_eq!(per_actor(2), None);
    }
}
