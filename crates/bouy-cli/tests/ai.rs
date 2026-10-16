//! The `ai` and `@ai-sdk/openai` subset (contract section 14) against the fake server of
//! `runtime/test/bouy_fake_openai.erl`. Each program in `tests/equivalence/ai/` runs with
//! `bouy run`, and its stdout and exit status must equal the Node output that
//! `scripts/freeze-expectations.sh tests/equivalence/ai` recorded against the same server.
//! The tests never run node. `tests/programs/ai-agents.ts` covers what only Bouy has: tools
//! that call actors.

mod common;

use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::OnceLock;

const API_KEY: &str = "sk-fake-key";

fn repository() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// The fake server, started once for the test binary. The child keeps the stdin pipe of the
/// server open, and the server halts when the pipe closes, as this process ends.
struct FakeServer {
    _child: Child,
    base_url: String,
}

fn server() -> &'static FakeServer {
    static SERVER: OnceLock<FakeServer> = OnceLock::new();
    SERVER.get_or_init(|| {
        let build = std::env::temp_dir().join(format!("bouy-fake-openai-{}", std::process::id()));
        fs::create_dir_all(&build).expect("the temporary directory is writable");
        let compiled = Command::new("erlc")
            .arg("-o")
            .arg(&build)
            .arg(repository().join("runtime/test/bouy_fake_openai.erl"))
            .status()
            .expect("erlc runs");
        assert!(
            compiled.success(),
            "the fake OpenAI server does not compile"
        );
        let mut child = Command::new("erl")
            .arg("-noshell")
            .arg("-pa")
            .arg(&build)
            .args(["-eval", "bouy_fake_openai:main()", "-extra", "stdin"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .expect("erl starts the fake OpenAI server");
        let stdout = child.stdout.take().expect("the server has a stdout pipe");
        let mut port = String::new();
        BufReader::new(stdout)
            .read_line(&mut port)
            .expect("the server prints its port");
        let port: u16 = port.trim().parse().expect("the first line is the port");
        // The server has loaded its module once it prints the port.
        let _ = fs::remove_dir_all(&build);
        FakeServer {
            _child: child,
            base_url: format!("http://127.0.0.1:{port}/v1"),
        }
    })
}

/// Points `bouy run` at the fake server.
fn configure(command: &mut Command) {
    command
        .env("OPENAI_BASE_URL", &server().base_url)
        .env("OPENAI_API_KEY", API_KEY);
}

#[test]
fn every_program_has_recorded_output() {
    common::assert_recorded("equivalence/ai", 7);
}

#[test]
fn programs_print_what_node_printed() {
    if common::vm_available() {
        common::assert_matches("equivalence/ai", configure);
    }
}

#[test]
fn tools_call_actors() {
    if !common::vm_available() {
        return;
    }
    let mut command = Command::new(env!("CARGO_BIN_EXE_bouy"));
    command
        .current_dir(repository())
        .args(["run", "tests/programs/ai-agents.ts"]);
    configure(&mut command);
    let output = command
        .output()
        .unwrap_or_else(|error| panic!("cannot run bouy: {error}"));
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let report = format!("--- stdout:\n{stdout}--- stderr:\n{stderr}");
    assert_eq!(
        stdout,
        "ana: Results: record -> ok (2 steps)\n\
         bo: Results: record -> ok (2 steps)\n\
         cy: Results: record -> ok (2 steps)\n\
         [\"ana visits Lima\",\"bo visits Oslo\",\"cy visits Rome\"]\n\
         ana: Results: record -> {\"error\":\"ActorFailed: Ledger #1 failed in record: Error: empty entry\"} (2 steps)\n\
         function Hello! You said: callable openai.chat\n\
         TypeError: streamText is not supported yet: use generateText\n",
        "stdout of {report}"
    );
    assert_eq!(
        stderr, "bouy: Ledger #1 crashed: Error: empty entry\n",
        "stderr of {report}"
    );
    assert_eq!(output.status.code(), Some(0), "exit status of {report}");
}
