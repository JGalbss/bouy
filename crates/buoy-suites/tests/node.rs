//! The Node runner of section 5.7 of docs/design/testing.md on a small fake suite, with a
//! fake `buoy` that answers by the name of each file, so `pnpm check` covers the runner with
//! no VM.

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};

use buoy_suites::comparison::{Comparison, Selection, is_sampled};
use buoy_suites::expectations::{Entry, parse};
use buoy_suites::node::{self, Options};
use buoy_suites::outcome::Outcome;

/// The file is the last argument. Rejects `common/index.mjs` on `check`. On `run`, a file named `*rejected*` is rejected,
/// `*fail*` exits with 1, `*flaky*` fails until the file `FAKE_MARK` exists and makes it,
/// and `*env*` passes only with the variables of the runner and of its `// Env:` line.
const FAKE_BUOY: &str = r#"#!/bin/sh
for file; do :; done
if [ "$1" = check ]; then
    case "$file" in *.mjs) exit 2 ;; esac
    exit 0
fi
case "$file" in
*rejected*) echo '{"status":2,"diagnostics":["BUOY206"]}' >"$BUOY_RESULT_FILE"; exit 2 ;;
*fail*) echo '{"status":1}' >"$BUOY_RESULT_FILE"; exit 1 ;;
*flaky*)
    if [ ! -f "$FAKE_MARK" ]; then
        touch "$FAKE_MARK"; echo '{"status":1}' >"$BUOY_RESULT_FILE"; exit 1
    fi ;;
*env*)
    if [ "$FAKE_ENV" != yes ] || [ -z "$TEST_SERIAL_ID" ] || [ ! -d "$NODE_TEST_DIR" ] ||
        [ "$NODE_SKIP_FLAG_CHECK" != 1 ]; then
        echo '{"status":1}' >"$BUOY_RESULT_FILE"; exit 1
    fi ;;
esac
echo '{"status":0}' >"$BUOY_RESULT_FILE"
"#;

/// A fake `tests/node` directory, here `tests`, and its fake `buoy`.
struct FakeSuite {
    root: PathBuf,
}

impl FakeSuite {
    fn new(name: &str) -> Self {
        let root = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("fake-node-{name}"));
        let _ = fs::remove_dir_all(&root);
        let files = [
            (
                "tests/config.json",
                r#"{"tag": "v0.0.0", "commit": "0000000000000000000000000000000000000000",
                   "timeout_ms": 5000,
                   "skip": [{"flag": "--expose-internals", "reason": "node-internals"},
                            {"path": "parallel/test-inspector", "reason": "node-inspector"}]}"#,
            ),
            ("tests/test/common/index.js", "'use strict';\n"),
            ("tests/test/common/index.mjs", "import './index.js';\n"),
            ("tests/test/parallel/helper.js", "// no test\n"),
            (
                "tests/test/parallel/test-pass.js",
                "'use strict';\nrequire('../common');\n",
            ),
            (
                "tests/test/parallel/test-rejected.js",
                "'use strict';\nrequire('../common');\n",
            ),
            (
                "tests/test/parallel/test-fs-env.js",
                "'use strict';\n// Env: FAKE_ENV=yes\nrequire('../common');\n",
            ),
            (
                "tests/test/parallel/test-internals.js",
                "// Flags: --expose_internals\n'use strict';\n",
            ),
            (
                "tests/test/parallel/test-inspector-port.js",
                "'use strict';\n",
            ),
            (
                "tests/test/es-module/test-esm-rejected.mjs",
                "import '../common/index.mjs';\n",
            ),
            ("tests/test/sequential/test-fail.js", "process.exit(1);\n"),
            ("fake-buoy", FAKE_BUOY),
        ];
        for (path, text) in files {
            let path = root.join(path);
            fs::create_dir_all(path.parent().expect("a parent")).expect("writable");
            fs::write(path, text).expect("writable");
        }
        fs::set_permissions(root.join("fake-buoy"), fs::Permissions::from_mode(0o755))
            .expect("the fake buoy becomes executable");
        Self { root }
    }

    fn options(&self, update: bool) -> Options {
        Options {
            directory: self.root.join("tests"),
            output: self.root.join("output"),
            buoy: self.root.join("fake-buoy"),
            selection: Selection::All,
            filter: None,
            base: None,
            update,
            jobs: 2,
        }
    }

    fn read(&self, name: &str) -> String {
        fs::read_to_string(self.root.join("tests").join(name)).unwrap_or_default()
    }
}

#[test]
fn the_fake_suite_gets_its_outcomes_skips_and_blockers() {
    let suite = FakeSuite::new("outcomes");
    fs::write(
        suite.root.join("tests/expectations.txt"),
        "parallel/test-pass.js pass\nparallel/test-rejected.js pass\nparallel/removed.js fail\n",
    )
    .expect("writable");
    let report = node::run(&suite.options(false)).expect("the fake suite runs");
    let entry = |id: &str| report.run.get(id).cloned();
    for (id, outcome) in [
        ("parallel/test-pass.js", Outcome::Pass),
        ("parallel/test-fs-env.js", Outcome::Pass),
        ("parallel/test-rejected.js", Outcome::Rejected),
        ("parallel/test-internals.js", Outcome::Skip),
        ("parallel/test-inspector-port.js", Outcome::Skip),
        ("es-module/test-esm-rejected.mjs", Outcome::Rejected),
        ("sequential/test-fail.js", Outcome::Fail),
    ] {
        assert_eq!(entry(id), Some(Entry::Same(outcome)), "{id}");
    }
    assert_eq!(report.run.len(), 7, "helper.js is no test");
    assert_eq!(
        report.comparison.regressions.len(),
        1,
        "{:?}",
        report.comparison
    );
    assert_eq!(
        report.comparison.stale.len(),
        7,
        "{:?}",
        report.comparison.stale
    );
    let rows: Vec<(&str, usize, usize)> = report
        .summary
        .blockers
        .iter()
        .map(|row| (row.blocker.as_str(), row.files, row.only))
        .collect();
    assert_eq!(rows, [("BUOY206", 2, 1), ("common/index.mjs", 1, 0)]);
    let count = |group: &str, name: &str, outcome: Outcome| {
        report.summary.groups[group]
            .get(name)
            .map_or(0, |counts| counts.get(outcome))
    };
    assert_eq!(count("kind", "internals", Outcome::Skip), 1);
    assert_eq!(count("kind", "public", Outcome::Pass), 2);
    assert_eq!(count("module", "fs", Outcome::Pass), 1);
    assert_eq!(count("module", "module", Outcome::Rejected), 1);
    assert_eq!(count("skip reason", "node-inspector", Outcome::Skip), 1);
    assert_eq!(count("directory", "sequential", Outcome::Fail), 1);
    let text = report.text();
    assert!(text.contains("sequential/test-fail.js: fail"), "{text}");
    assert!(text.contains("rerun: "), "{text}");
}

#[test]
fn an_update_writes_a_file_that_the_next_run_matches() {
    let suite = FakeSuite::new("update");
    node::run(&suite.options(true)).expect("the update runs");
    assert_eq!(
        suite.read("expectations.txt"),
        "# Generated by `buoy-suites node --update`. Do not edit. Change config.json instead.\n\
         # node v0.0.0 0000000000000000000000000000000000000000\n\
         es-module/test-esm-rejected.mjs rejected\n\
         parallel/test-fs-env.js pass\n\
         parallel/test-inspector-port.js skip\n\
         parallel/test-internals.js skip\n\
         parallel/test-pass.js pass\n\
         parallel/test-rejected.js rejected\n\
         sequential/test-fail.js fail\n"
    );
    assert!(suite.read("summary.json").contains("\"internals\""));
    let report = node::run(&suite.options(false)).expect("the second run");
    assert_eq!(report.comparison, Comparison::default());
    let before = suite.read("expectations.txt");
    let mut filtered = suite.options(true);
    filtered.filter = Some("parallel/".to_owned());
    node::run(&filtered).expect("an update with a filter rewrites the lines of its ids");
    assert_eq!(
        suite.read("expectations.txt"),
        before,
        "it keeps the other lines"
    );
    let mut selected = suite.options(true);
    selected.selection = Selection::PullRequest;
    assert!(
        node::run(&selected).is_err(),
        "an update takes no selection"
    );
}

#[test]
fn a_pull_request_runs_the_passes_the_skips_and_the_sample() {
    let suite = FakeSuite::new("selection");
    node::run(&suite.options(true)).expect("the update runs");
    let mut options = suite.options(false);
    options.selection = Selection::PullRequest;
    let report = node::run(&options).expect("the selection runs");
    for (id, entry) in parse(&suite.read("expectations.txt")).expect("parses") {
        let selected = matches!(entry.outcome(), Outcome::Pass | Outcome::Skip) || is_sampled(&id);
        assert_eq!(report.run.contains_key(&id), selected, "{id}");
    }
    assert_eq!(report.comparison, Comparison::default());
}

/// `buoy-suites node --update` writes `expectations.txt` and `summary.json` together from the
/// files of `tests/node/test`, so a hand edit of one of them shows here with no run.
#[test]
fn the_committed_node_files_agree() {
    let directory = buoy_suites::repository().join("tests/node");
    let read = |name: &str| {
        fs::read_to_string(directory.join(name))
            .unwrap_or_else(|error| panic!("tests/node/{name}: {error}"))
    };
    let config: serde_json::Value = serde_json::from_str(&read("config.json")).expect("JSON");
    let summary: serde_json::Value = serde_json::from_str(&read("summary.json")).expect("JSON");
    let entries = parse(&read("expectations.txt")).expect("the expectation file parses");
    let source = format!(
        "# node {} {}",
        config["tag"].as_str().unwrap_or_default(),
        config["commit"].as_str().unwrap_or_default()
    );
    assert!(
        read("expectations.txt").lines().any(|line| line == source),
        "the expectation file names another tag or commit than config.json"
    );
    assert_eq!(summary["version"], config["tag"]);
    let mut files = 0;
    for name in ["parallel", "es-module", "sequential"] {
        for entry in fs::read_dir(directory.join("test").join(name)).expect("vendored") {
            let file = entry.expect("an entry").file_name();
            let file = file.to_string_lossy();
            let is_test = file.starts_with("test-")
                && Path::new(file.as_ref())
                    .extension()
                    .is_some_and(|extension| extension == "js" || extension == "mjs");
            if is_test {
                files += 1;
                assert!(
                    entries.contains_key(&format!("{name}/{file}")),
                    "{name}/{file}"
                );
            }
        }
    }
    assert_eq!(entries.len(), files, "each test file has one line");
    assert_eq!(summary["total"].as_u64(), Some(files as u64));
    for outcome in Outcome::ALL {
        let count = entries
            .values()
            .filter(|entry| entry.outcome() == outcome)
            .count();
        assert_eq!(
            summary["outcomes"][outcome.as_str()].as_u64(),
            Some(count as u64),
            "{outcome}"
        );
    }
}

/// A line names each platform whose outcome differs, and a run compares with its own. The
/// regenerated file of a run keeps the other platform; an update moves every platform.
#[test]
fn a_line_holds_the_outcome_of_each_platform() {
    let suite = FakeSuite::new("platforms");
    let platform = buoy_suites::expectations::PLATFORM;
    node::run(&suite.options(true)).expect("the update runs");
    let recorded = suite.read("expectations.txt");
    let split = if platform == "linux" {
        "parallel/test-pass.js linux=pass,macos=fail\n"
    } else {
        "parallel/test-pass.js linux=fail,macos=pass\n"
    };
    fs::write(
        suite.root.join("tests/expectations.txt"),
        recorded.replace("parallel/test-pass.js pass\n", split),
    )
    .expect("writable");
    let report = node::run(&suite.options(false)).expect("the run");
    assert_eq!(
        report.comparison,
        Comparison::default(),
        "its own platform passes"
    );
    fs::write(
        suite.root.join("tests/expectations.txt"),
        recorded.replace(
            "parallel/test-pass.js pass\n",
            "parallel/test-pass.js fail\n",
        ),
    )
    .expect("writable");
    let report = node::run(&suite.options(false)).expect("the run");
    assert_eq!(report.comparison.stale.len(), 1);
    let output = fs::read_to_string(suite.root.join("output/expectations.txt")).expect("written");
    assert!(output.contains(split), "{output}");
    node::run(&suite.options(true)).expect("the update runs");
    assert_eq!(suite.read("expectations.txt"), recorded);
}

/// A file whose outcome its line does not expect runs once more, alone, and the rerun
/// decides.
#[test]
fn an_unexpected_outcome_gets_one_rerun() {
    let suite = FakeSuite::new("rerun");
    fs::write(
        suite.root.join("tests/test/parallel/test-flaky.js"),
        "'use strict';\n// Env: FAKE_MARK=../flaky.mark\n",
    )
    .expect("writable");
    node::run(&suite.options(true)).expect("the update runs");
    assert!(
        suite
            .read("expectations.txt")
            .contains("parallel/test-flaky.js pass\n")
    );
    fs::remove_file(suite.root.join("flaky.mark")).expect("the first run made the mark");
    let report = node::run(&suite.options(false)).expect("the run");
    assert_eq!(report.comparison, Comparison::default());
}
