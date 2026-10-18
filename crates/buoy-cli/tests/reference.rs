//! The reference-semantics prototype: each program in `tests/reference/` runs with
//! `buoy run --semantics reference`, and its stdout and exit status must equal the Node
//! output that `scripts/freeze-expectations.sh` recorded next to it.

mod common;

#[test]
fn every_program_has_recorded_output() {
    common::assert_recorded("reference", 25);
}

#[test]
fn programs_print_what_node_printed() {
    if common::vm_available() {
        common::assert_matches("reference", |command| {
            command.args(["--semantics", "reference"]);
        });
    }
}

/// A module that does not compile, other than the entry, throws when the program loads
/// it, as Node throws a `SyntaxError`, and `buoy check` reports it.
#[test]
fn a_dependency_that_does_not_compile_throws_when_it_loads() {
    let dir = std::env::temp_dir().join(format!("buoy-broken-dependency-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("a scratch directory");
    std::fs::write(dir.join("package.json"), "{\"type\":\"module\"}").expect("package.json");
    std::fs::write(
        dir.join("main.js"),
        "import { x } from \"./bad.js\";\nconsole.log(x);\n",
    )
    .expect("main.js");
    std::fs::write(dir.join("bad.js"), "export const x = ;\n").expect("bad.js");
    let buoy = |command: &str| {
        std::process::Command::new(env!("CARGO_BIN_EXE_buoy"))
            .args([command, "--semantics", "reference"])
            .arg(dir.join("main.js"))
            .output()
            .expect("buoy runs")
    };
    let check = buoy("check");
    assert_eq!(check.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&check.stderr).contains("bad.js:1:18: BUOY200"));
    if common::vm_available() {
        let run = buoy("run");
        assert_eq!(run.status.code(), Some(1));
        assert!(run.stdout.is_empty());
        assert!(String::from_utf8_lossy(&run.stderr).contains("Uncaught SyntaxError"));
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// The islands of `island-objects.ts` read and write module variables that hold objects
/// and strings, and the run of each is native (contract section 17.10). Only the last
/// call, whose global holds a field of another type, goes to the Erlang tier.
#[test]
fn islands_that_share_objects_run_natively() {
    if !common::vm_available() {
        return;
    }
    let output = common::buoy()
        .current_dir(common::repository())
        .args(["run", "--semantics", "reference"])
        .arg(std::path::Path::new("tests/reference").join("island-objects.ts"))
        .env("BUOY_JIT_TRACE", "1")
        .output()
        .expect("buoy runs");
    assert_eq!(output.status.code(), Some(0));
    let stderr = String::from_utf8_lossy(&output.stderr);
    let outcomes: Vec<&str> = stderr
        .lines()
        .filter(|line| line.starts_with("buoy jit: buoy@"))
        .filter_map(|line| line.rsplit(' ').next())
        .collect();
    let mut expected = vec!["native"; 6];
    expected.push("badtype");
    assert_eq!(outcomes, expected, "{stderr}");
}
