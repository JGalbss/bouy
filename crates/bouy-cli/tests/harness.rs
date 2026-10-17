//! Tests of the harness in `common/mod.rs` that every program test relies on: the deadline,
//! the `node` shim, and the facts that `bouy run` writes to `BOUY_RESULT_FILE`.

mod common;

use std::fs;
use std::path::Path;
use std::process::Command;
use std::time::Duration;

#[test]
fn an_endless_loop_fails_at_the_deadline() {
    if !common::vm_available() {
        return;
    }
    let project = Path::new(env!("CARGO_TARGET_TMPDIR")).join("endless-loop");
    fs::create_dir_all(&project).expect("the target directory is writable");
    fs::write(project.join("package.json"), "{}\n").expect("the project is writable");
    fs::write(project.join("endless.ts"), "for (;;) {}\n").expect("the project is writable");
    fs::write(project.join("endless.stdout"), "").expect("the project is writable");
    let program = project.join("endless.ts");
    let mut command = common::bouy();
    command.arg("run").arg(&program);
    let report = common::compare(&program, &mut command, Duration::from_secs(2));
    let _ = fs::remove_dir_all(&project);
    let report = report.expect("an endless loop differs from the recorded output");
    assert!(
        report.contains("endless.ts: node exited 0, bouy ran past the deadline of 2s"),
        "{report}"
    );
}

#[test]
fn a_test_that_starts_node_fails_with_the_shim_message() {
    let mut command = Command::new("node");
    common::bouy_env(&mut command).arg("--version");
    let output = common::run(&mut command, common::deadline()).output;
    assert_eq!(
        String::from_utf8_lossy(&output.stderr),
        "a test tried to run node\n"
    );
    assert_eq!(output.stdout, b"");
    assert_eq!(output.status.code(), Some(1));
}

#[test]
fn the_result_file_holds_the_facts_of_a_run() {
    if !common::vm_available() {
        return;
    }
    let project = Path::new(env!("CARGO_TARGET_TMPDIR")).join("result-file");
    fs::create_dir_all(&project).expect("the target directory is writable");
    fs::write(project.join("package.json"), "{}\n").expect("the project is writable");
    let cases = [
        ("ends.ts", "console.log(1);\n", 0, None, &[][..]),
        (
            "throws.ts",
            "throw new TypeError(\"boom\");\n",
            1,
            Some("TypeError"),
            &[],
        ),
        ("rejected.ts", "var count = 1;\n", 2, None, &["BOUY202"]),
    ];
    for (name, source, status, uncaught, diagnostics) in cases {
        let program = project.join(name);
        let result_file = project.join(format!("{name}.json"));
        fs::write(&program, source).expect("the project is writable");
        let _ = fs::remove_file(&result_file);
        let mut command = common::bouy();
        command
            .env("BOUY_RESULT_FILE", &result_file)
            .arg("run")
            .arg(&program);
        let run = common::run(&mut command, common::deadline());
        let result = bouy_suites::RunResult::read(&result_file)
            .unwrap_or_else(|| panic!("{name} wrote no result: {run:?}"));
        assert_eq!(result.status, status, "{name}");
        assert_eq!(
            result.uncaught.and_then(|error| error.name).as_deref(),
            uncaught,
            "{name}"
        );
        assert_eq!(result.diagnostics, diagnostics, "{name}");
        assert_eq!(result.erlang, None, "{name}");
    }
    let _ = fs::remove_dir_all(&project);
}
