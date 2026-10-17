//! The ecosystem tier (section 5.8 of docs/design/testing.md): the resolution cases of
//! `tests/npm`, the package programs of `tests/packages`, and the AI-stack scenarios of
//! `tests/equivalence/<area>`. The test runs each program with the `bouy` of this build
//! through `bouy_suites::packages`, the runner of `bouy-suites packages`, and fails on a
//! regression or a stale line of an expectation file (section 3.3). Node recorded the
//! output of each program, and the tests never run node.

mod common;

use std::env;
use std::path::Path;

use bouy_suites::packages::{self, Options};

#[test]
fn each_program_has_the_outcome_of_its_expectation_line() {
    if !common::vm_available() {
        return;
    }
    let options = Options {
        root: common::repository(),
        output: Path::new(env!("CARGO_TARGET_TMPDIR")).join("suites/packages"),
        bouy: common::bouy_binary(),
        filter: env::var("BOUY_TEST_FILTER")
            .ok()
            .filter(|filter| !filter.is_empty()),
        update: false,
        jobs: bouy_suites::default_jobs(),
        deadline: common::deadline(),
    };
    let report = packages::run(&options).unwrap_or_else(|error| panic!("{error}"));
    assert!(!report.fails(), "{}", report.text());
}
