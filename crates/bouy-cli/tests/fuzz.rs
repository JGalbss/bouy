//! The fuzz replay (section 5.10 of docs/design/testing.md). Each case of
//! `tests/fuzz/<generator>/<seed>.ts` is a minimized program on which Bouy and Node differed
//! when the campaign of `crates/bouy-fuzz` found it, with the Node output next to it. The
//! test runs each case with `bouy run`, classifies the run, and fails on a regression or a
//! stale line of `tests/fuzz/expectations.txt` (section 3.3), so the outcome of a case can
//! only improve. It writes the lines of its run to `target/suites/fuzz/expectations.txt`.

mod common;

use std::collections::BTreeSet;
use std::env;
use std::fs;
use std::path::Path;

use bouy_suites::comparison::{Origin, compare};
use bouy_suites::expectations::{self, Entry, Expectations};

const UPDATE: &str = "cp target/suites/fuzz/expectations.txt tests/fuzz/expectations.txt";

#[test]
fn every_case_has_recorded_output() {
    for generator in generators() {
        common::assert_recorded(&format!("fuzz/{generator}"), 1);
    }
}

#[test]
fn each_case_has_the_outcome_of_its_expectation_line() {
    if !common::vm_available() {
        return;
    }
    let corpus = common::repository().join("tests/fuzz");
    let text = fs::read_to_string(corpus.join("expectations.txt"))
        .expect("tests/fuzz/expectations.txt exists");
    let recorded = expectations::parse(&text).expect("tests/fuzz/expectations.txt parses");
    let cases: BTreeSet<String> = generators()
        .iter()
        .flat_map(|generator| {
            fs::read_dir(corpus.join(generator))
                .expect("a generator directory reads")
                .filter_map(Result::ok)
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|found| found == "ts"))
                .filter_map(|path| {
                    Some(format!(
                        "{generator}/{}",
                        path.file_name()?.to_string_lossy()
                    ))
                })
                .collect::<Vec<_>>()
        })
        .collect();
    let filter = env::var("BOUY_TEST_FILTER").unwrap_or_default();
    let selected: Vec<&String> = cases
        .iter()
        .filter(|id| format!("tests/fuzz/{id}").contains(&filter))
        .collect();
    let runs = common::map_parallel(&selected, |id| {
        let program = corpus.join(id);
        let mut command = common::bouy();
        command.arg("run").arg(&program);
        common::classify_run(&program, &mut command)
    });
    let run: Expectations = selected
        .iter()
        .zip(&runs)
        .map(|(id, (outcome, _))| ((*id).clone(), Entry::Same(*outcome)))
        .collect();
    let comparison = compare(Origin::Corpus, &run, &cases, &recorded, None);
    write_run(&text, &recorded, &cases, &run);
    let reports: Vec<&str> = selected
        .iter()
        .zip(&runs)
        .filter(|(id, (outcome, _))| recorded.get(**id) != Some(&Entry::Same(*outcome)))
        .map(|(_, (_, report))| report.as_str())
        .collect();
    assert!(
        !comparison.fails(false),
        "{}{}",
        comparison.report(UPDATE, 50),
        reports.join("")
    );
}

/// The generator directories of `tests/fuzz`.
fn generators() -> Vec<String> {
    let mut generators: Vec<String> = fs::read_dir(common::repository().join("tests/fuzz"))
        .expect("tests/fuzz reads")
        .filter_map(Result::ok)
        .filter(|entry| entry.path().is_dir())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    generators.sort();
    generators
}

/// Writes the expectation file of this run, with the header of the recorded file: the run's
/// line for each case that ran, and the recorded line for each other case.
fn write_run(text: &str, recorded: &Expectations, cases: &BTreeSet<String>, run: &Expectations) {
    let header: Vec<String> = text
        .lines()
        .filter_map(|line| line.strip_prefix("# "))
        .map(str::to_owned)
        .collect();
    let mut lines = recorded.clone();
    lines.retain(|id, _| cases.contains(id));
    lines.extend(run.clone());
    let directory = Path::new(env!("CARGO_TARGET_TMPDIR"))
        .parent()
        .expect("the temporary directory is in the target directory")
        .join("suites/fuzz");
    fs::create_dir_all(&directory).expect("the target directory is writable");
    fs::write(
        directory.join("expectations.txt"),
        expectations::write(&header, &lines),
    )
    .expect("the target directory is writable");
}
