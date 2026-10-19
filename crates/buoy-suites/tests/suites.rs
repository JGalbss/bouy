//! The comparison of section 3.3 of docs/design/testing.md, and the test262 runner on a small
//! fake suite, so `pnpm check` covers them with no fetch and no VM.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use buoy_suites::comparison::{Comparison, Move, Origin, compare};
use buoy_suites::expectations::{Entry, Expectations, parse};
use buoy_suites::outcome::Outcome;
use buoy_suites::test262::{self, Options, Selection};

fn file(text: &str) -> Expectations {
    parse(text).expect("the fake file parses")
}

fn ids(text: &str) -> BTreeSet<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

fn moved(id: &str, before: &str, after: &str) -> Move {
    Move {
        id: id.to_owned(),
        before: before.parse().expect("an entry"),
        after: after.parse().expect("an entry"),
    }
}

#[test]
fn a_lost_pass_and_a_new_crash_are_regressions() {
    let base = file("a.js pass\nb.js rejected\nc.js nonstrict=pass,strict=rejected\n");
    let run = file("a.js fail\nb.js crash\nc.js nonstrict=rejected,strict=rejected\n");
    let comparison = compare(
        Origin::Upstream,
        &run,
        &ids("a.js b.js c.js"),
        &run,
        Some(&base),
    );
    assert_eq!(
        comparison.regressions,
        [
            moved("a.js", "pass", "fail"),
            moved("b.js", "rejected", "crash"),
            moved("c.js", "nonstrict=pass,strict=rejected", "rejected"),
        ]
    );
    assert!(comparison.stale.is_empty(), "{comparison:?}");
    assert!(comparison.fails(false));
    assert!(!comparison.fails(true));
}

#[test]
fn loud_to_silent_is_newly_silent_upstream_and_a_regression_in_a_corpus() {
    let base = file("a.js rejected\nb.js late\n");
    let run = file("a.js fail\nb.js timeout\n");
    let tests = ids("a.js b.js");
    let upstream = compare(Origin::Upstream, &run, &tests, &run, Some(&base));
    assert_eq!(
        upstream,
        Comparison {
            newly_silent: vec![
                moved("a.js", "rejected", "fail"),
                moved("b.js", "late", "timeout")
            ],
            ..Comparison::default()
        }
    );
    assert!(!upstream.fails(false));
    let corpus = compare(Origin::Corpus, &run, &tests, &run, Some(&base));
    assert_eq!(corpus.regressions.len(), 2);
    assert!(corpus.newly_silent.is_empty());
}

#[test]
fn a_new_pass_a_missing_line_and_an_orphan_line_are_stale() {
    let pull_request = file("a.js rejected\ngone.js pass\n");
    let run = file("a.js pass\nnew.js rejected\n");
    let comparison = compare(
        Origin::Upstream,
        &run,
        &ids("a.js new.js"),
        &pull_request,
        None,
    );
    assert!(comparison.regressions.is_empty());
    assert_eq!(
        comparison.stale,
        [
            "a.js: the file says rejected, and the run gives pass",
            "gone.js: the line matches no test",
            "new.js: the test has no line; the run gives rejected",
        ]
    );
    assert!(comparison.fails(true));
    let report = comparison.report("update", 1);
    assert!(report.starts_with("3 stale lines:\n  a.js"), "{report}");
    assert!(report.contains("and 2 more"), "{report}");
}

#[test]
fn a_regression_recorded_in_the_pull_request_still_fails_against_the_base() {
    let base = file("a.js pass\n");
    let recorded = file("a.js rejected\n");
    let comparison = compare(
        Origin::Upstream,
        &recorded,
        &ids("a.js"),
        &recorded,
        Some(&base),
    );
    assert_eq!(comparison.regressions, [moved("a.js", "pass", "rejected")]);
    assert!(comparison.stale.is_empty());
}

#[test]
fn the_comment_lists_each_move_against_the_base() {
    let base =
        file("a.js pass\nb.js rejected\nc.js rejected\nd.js nonstrict=rejected,strict=pass\n");
    let run = file("a.js rejected\nb.js fail\nc.js pass\nd.js pass\n");
    let comparison = compare(
        Origin::Upstream,
        &run,
        &ids("a.js b.js c.js d.js"),
        &run,
        Some(&base),
    );
    assert_eq!(
        comparison.new_passes,
        [
            moved("c.js", "rejected", "pass"),
            moved("d.js", "nonstrict=rejected,strict=pass", "pass"),
        ]
    );
    let comment = comparison.comment("### fake", 1);
    assert_eq!(
        comment,
        "### fake\n\
         <details><summary>1 regressions</summary>\n\n\
         - `a.js` rejected (previously pass)\n\n\
         </details>\n\n\
         <details><summary>1 newly silent</summary>\n\n\
         - `b.js` fail (previously rejected)\n\n\
         </details>\n\n\
         <details><summary>2 new passes</summary>\n\n\
         - `c.js` pass (previously rejected)\n\
         - and 1 more; `results.json` in the artifact of the run lists every id\n\n\
         </details>\n\n"
    );
    assert_eq!(
        Comparison::default().comment("### fake", 1),
        "### fake\n0 regressions.\n\n0 newly silent.\n\n0 new passes.\n\n"
    );
}

/// A fake test262 checkout and the directory of its expectation files.
struct FakeSuite {
    root: PathBuf,
}

impl FakeSuite {
    fn new(name: &str) -> Self {
        let root = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("fake-test262-{name}"));
        let _ = fs::remove_dir_all(&root);
        let files = [
            ("checkout/harness/assert.js", "var assert = {};\n"),
            ("checkout/harness/sta.js", "const sta = 1;\n"),
            ("checkout/harness/doneprintHandle.js", "const done = 1;\n"),
            ("checkout/harness/features.yml", "sta.js: [fake-feature]\n"),
            (
                "checkout/test/a/positive.js",
                "/*---\nesid: sec-a\ndescription: x\n---*/\nconst a = 1;\n",
            ),
            (
                "checkout/test/a/parse-negative.js",
                "/*---\ndescription: x\nnegative:\n  phase: parse\n  type: SyntaxError\n---*/\nconst a = ;\n",
            ),
            (
                "checkout/test/a/raw-compiles-not.js",
                "/*---\ndescription: x\nflags: [raw]\n---*/\nvar b = 1;\n",
            ),
            ("checkout/test/a/helper_FIXTURE.js", "export const c = 1;\n"),
            (
                "checkout/test/b/skipped.js",
                "/*---\ndescription: x\nflags: [CanBlockIsFalse]\n---*/\nconst d = 1;\n",
            ),
            (
                "tests/config.json",
                r#"{"commit": "0000000000000000000000000000000000000000", "timeout_ms": 20000,
                   "skip": [{"flag": "CanBlockIsFalse", "reason": "can-block"}]}"#,
            ),
        ];
        for (path, text) in files {
            let path = root.join(path);
            fs::create_dir_all(path.parent().expect("a parent")).expect("writable");
            fs::write(path, text).expect("writable");
        }
        Self { root }
    }

    fn options(&self, update: bool) -> Options {
        Options {
            directory: self.root.join("tests"),
            checkout: Some(self.root.join("checkout")),
            output: self.root.join("output"),
            // No fake test compiles with its harness, so nothing runs.
            buoy: self.root.join("no-buoy"),
            compiler: PathBuf::from(env!("CARGO_BIN_EXE_buoy-suites")),
            selection: Selection::All,
            filter: None,
            base: None,
            update,
            jobs: 2,
        }
    }

    fn expectations(&self) -> String {
        fs::read_to_string(self.root.join("tests/expectations.txt")).unwrap_or_default()
    }
}

#[test]
fn the_fake_suite_gets_its_compile_outcomes_and_its_blockers() {
    let suite = FakeSuite::new("outcomes");
    fs::write(
        suite.root.join("tests/expectations.txt"),
        "a/positive.js pass\na/removed.js rejected\n",
    )
    .expect("writable");
    let report = test262::run(&suite.options(false)).expect("the fake suite runs");
    let entry = |id: &str| report.run.get(id).cloned();
    assert_eq!(entry("a/positive.js"), Some(Entry::Same(Outcome::Rejected)));
    assert_eq!(
        entry("a/parse-negative.js"),
        Some(Entry::Same(Outcome::Pass))
    );
    assert_eq!(
        entry("a/raw-compiles-not.js"),
        Some(Entry::Same(Outcome::Rejected))
    );
    assert_eq!(entry("b/skipped.js"), Some(Entry::Same(Outcome::Skip)));
    assert_eq!(report.run.len(), 4, "the _FIXTURE.js file is no test");
    assert_eq!(
        report.comparison.regressions,
        [moved("a/positive.js", "pass", "rejected")]
    );
    assert_eq!(
        report.comparison.stale,
        [
            "a/parse-negative.js: the test has no line; the run gives pass",
            "a/positive.js: the file says pass, and the run gives rejected",
            "a/raw-compiles-not.js: the test has no line; the run gives rejected",
            "a/removed.js: the line matches no test",
            "b/skipped.js: the test has no line; the run gives skip",
        ]
    );
    let rows: Vec<(&str, usize, usize)> = report
        .summary
        .blockers
        .iter()
        .map(|row| (row.blocker.as_str(), row.files, row.only))
        .collect();
    assert_eq!(rows, [("BUOY202", 1, 1), ("harness/assert.js", 1, 1)]);
    assert_eq!(report.summary.outcomes.get(Outcome::Rejected), 2);
    assert_eq!(report.executions, 7, "each mode of each file counts");
}

#[test]
fn an_update_writes_a_file_that_the_next_run_matches() {
    let suite = FakeSuite::new("update");
    test262::run(&suite.options(true)).expect("the update runs");
    assert_eq!(
        suite.expectations(),
        "# Generated by `buoy-suites test262 --update`. Do not edit. Change config.json instead.\n\
         # test262 0000000000000000000000000000000000000000\n\
         a/parse-negative.js pass\n\
         a/positive.js rejected\n\
         a/raw-compiles-not.js rejected\n\
         b/skipped.js skip\n"
    );
    let summary = fs::read_to_string(suite.root.join("tests/summary.json")).expect("written");
    assert!(summary.contains("\"fake-feature\""), "{summary}");
    let report = test262::run(&suite.options(false)).expect("the second run");
    assert_eq!(report.comparison, Comparison::default());
    let mut filtered = suite.options(true);
    filtered.filter = Some("a/".to_owned());
    assert!(test262::run(&filtered).is_err(), "an update runs every id");
}

/// `buoy-suites test262 --update` writes `expectations.txt` and `summary.json` together, so a
/// hand edit of one file shows here with no fetch.
#[test]
fn the_committed_test262_files_agree() {
    let directory = buoy_suites::repository().join("tests/test262");
    let read = |name: &str| {
        fs::read_to_string(directory.join(name))
            .unwrap_or_else(|error| panic!("tests/test262/{name}: {error}"))
    };
    let config: serde_json::Value = serde_json::from_str(&read("config.json")).expect("JSON");
    let summary: serde_json::Value = serde_json::from_str(&read("summary.json")).expect("JSON");
    let text = read("expectations.txt");
    let entries = parse(&text).expect("the expectation file parses");
    assert!(
        text.lines().any(
            |line| Some(line.strip_prefix("# test262 ").unwrap_or_default())
                == config["commit"].as_str()
        ),
        "the expectation file names another commit than config.json"
    );
    assert_eq!(summary["version"], config["commit"]);
    assert_eq!(summary["total"].as_u64(), Some(entries.len() as u64));
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

/// A run that times out stops the processes that it started, which would keep its pipes
/// open: the wait ends at the deadline, not when the last of them exits.
#[test]
fn a_timed_out_run_stops_the_processes_that_it_started() {
    let started = std::time::Instant::now();
    let mut command = std::process::Command::new("sh");
    command.args(["-c", "sleep 30 & sleep 30"]);
    let run = buoy_suites::run(&mut command, std::time::Duration::from_secs(1));
    assert!(run.timed_out);
    assert!(
        started.elapsed() < std::time::Duration::from_secs(15),
        "the run waited {:?}",
        started.elapsed()
    );
}

/// A VM starts each child process in a session of its own (`erl_child_setup` calls setsid),
/// out of the group of the run. When the VM exits, such a child loses its parent, and the
/// run still stops it.
#[test]
fn a_run_stops_the_child_processes_of_a_vm_when_the_vm_exits() {
    let directory = std::env::temp_dir().join(format!("buoy-suites-orphan-{}", std::process::id()));
    fs::create_dir_all(&directory).expect("the directory");
    let pid_file = directory.join("pid");
    let mut command = std::process::Command::new("erl");
    command.args([
        "-noshell",
        "-eval",
        &format!(
            "Port = open_port({{spawn_executable, \"/bin/sleep\"}}, [{{args, [\"30\"]}}]), \
             {{os_pid, Pid}} = erlang:port_info(Port, os_pid), \
             ok = file:write_file(\"{}\", integer_to_list(Pid)), \
             timer:sleep(1000), halt().",
            pid_file.display()
        ),
    ]);
    let run = buoy_suites::run(&mut command, std::time::Duration::from_secs(20));
    let pid = fs::read_to_string(&pid_file).expect("the VM wrote the pid of its child");
    let _ = fs::remove_dir_all(&directory);
    let alive = (0..20).all(|_| {
        std::thread::sleep(std::time::Duration::from_millis(100));
        is_running(&pid)
    });
    if alive {
        let _ = std::process::Command::new("kill")
            .args(["-9", &pid])
            .status();
    }
    assert!(!run.timed_out);
    assert!(!alive, "the child {pid} of the VM still runs");
}

/// Whether `pid` names a process that has not exited.
fn is_running(pid: &str) -> bool {
    std::process::Command::new("ps")
        .args(["-o", "stat=", "-p", pid])
        .output()
        .is_ok_and(|output| {
            let stat = String::from_utf8_lossy(&output.stdout);
            !stat.trim().is_empty() && !stat.trim_start().starts_with('Z')
        })
}

/// A program that exits and leaves a process behind, which holds its pipes open and outlives
/// its parent, ends the run at its exit, with the output that it wrote.
#[test]
fn a_run_ends_when_the_program_exits_and_its_leftovers_die() {
    let started = std::time::Instant::now();
    let mut command = std::process::Command::new("sh");
    command.args(["-c", "sleep 30 & echo done"]);
    let run = buoy_suites::run(&mut command, std::time::Duration::from_secs(20));
    assert!(!run.timed_out);
    assert!(run.output.status.success());
    assert_eq!(String::from_utf8_lossy(&run.output.stdout), "done\n");
    assert!(
        started.elapsed() < std::time::Duration::from_secs(10),
        "the run waited {:?}",
        started.elapsed()
    );
}
