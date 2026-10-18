//! The `ai` and `@ai-sdk/openai` subset (contract section 14) against the fake server of
//! `runtime/test/buoy_fake_openai.erl`. Each program in `tests/equivalence/ai/` runs with
//! `buoy run`, and its stdout and exit status must equal the Node output that
//! `scripts/freeze-expectations.sh tests/equivalence/ai` recorded against the same server.
//! The tests never run node. `tests/programs/ai-agents.ts` covers what only Buoy has: tools
//! that call actors.

mod common;

#[test]
fn every_program_has_recorded_output() {
    common::assert_recorded("equivalence/ai", 7);
}

#[test]
fn programs_print_what_node_printed() {
    if common::vm_available() {
        common::assert_matches("equivalence/ai", |command| {
            common::use_fake_openai(command);
        });
    }
}

#[test]
fn tools_call_actors() {
    if !common::vm_available() {
        return;
    }
    let mut command = common::buoy();
    command
        .current_dir(common::repository())
        .args(["run", "tests/programs/ai-agents.ts"]);
    common::use_fake_openai(&mut command);
    let output = common::run(&mut command, common::deadline()).output;
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
        stderr, "buoy: Ledger #1 crashed: Error: empty entry\n",
        "stderr of {report}"
    );
    assert_eq!(output.status.code(), Some(0), "exit status of {report}");
}
