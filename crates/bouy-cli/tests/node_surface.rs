//! The Node API surface (section 5.7.1 of docs/design/testing.md). The test probes each entry
//! of `tests/node/surface.json` with the `bouy` of this build through
//! `bouy_suites::node_surface`, the runner of `bouy-suites node-surface`, and fails on a
//! regression or a stale line of `tests/node/surface/expectations.txt` (section 3.3). Node
//! recorded each entry, and the test never runs node.

mod common;

use std::env;
use std::path::Path;

use bouy_suites::node_surface::{self, Options};

#[test]
fn each_documented_entry_has_the_outcome_of_its_expectation_line() {
    if !common::vm_available() {
        return;
    }
    let options = Options {
        directory: common::repository().join("tests/node"),
        output: Path::new(env!("CARGO_TARGET_TMPDIR")).join("suites/node-surface"),
        bouy: common::bouy_binary(),
        filter: env::var("BOUY_TEST_FILTER")
            .ok()
            .filter(|filter| !filter.is_empty()),
        base: None,
        update: false,
        jobs: bouy_suites::default_jobs(),
        deadline: common::deadline(),
    };
    let report = node_surface::run(&options).unwrap_or_else(|error| panic!("{error}"));
    assert!(!report.comparison.fails(false), "{}", report.text());
}
