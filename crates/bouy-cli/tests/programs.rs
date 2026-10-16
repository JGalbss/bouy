//! End-to-end programs: `bouy run` compiles each program in `tests/programs/` from
//! TypeScript and runs it on one VM. Each test checks stdout, stderr, and the exit status.
//! A program that measures time prints a fixed line when the bound holds, and the measured
//! times when it does not.

use std::fmt::Write as _;
use std::path::Path;
use std::process::Command;

struct Outcome<'a> {
    stdout: &'a str,
    stderr: &'a str,
    status: i32,
}

/// `bouy run tests/programs/<program>`, from the repository root, so that diagnostics print
/// the path relative to it.
fn bouy(program: &str) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_bouy"));
    command
        .current_dir(Path::new(env!("CARGO_MANIFEST_DIR")).join("../.."))
        .arg("run")
        .arg(Path::new("tests/programs").join(program));
    command
}

fn check(command: &mut Command, expected: &Outcome) {
    let output = command.output().expect("bouy runs");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let report = format!("{command:?}\n--- stdout:\n{stdout}--- stderr:\n{stderr}");
    assert_eq!(stdout, expected.stdout, "stdout of {report}");
    assert_eq!(stderr, expected.stderr, "stderr of {report}");
    assert_eq!(
        output.status.code(),
        Some(expected.status),
        "exit status of {report}"
    );
}

/// Like `check`, for a program that runs on the VM: it skips with a notice when Erlang is
/// not installed.
fn check_on_vm(command: &mut Command, expected: &Outcome) {
    let installed = Command::new("erl")
        .args(["-noshell", "-eval", "halt()."])
        .output()
        .is_ok();
    if !installed {
        eprintln!("skipping {command:?}: erl is not installed");
        return;
    }
    check(command, expected);
}

#[test]
fn greeter_answers_two_calls() {
    check_on_vm(
        &mut bouy("hello.ts"),
        &Outcome {
            stdout: "Hello, world!\nHello, BEAM!\n",
            stderr: "",
            status: 0,
        },
    );
}

#[test]
fn actors_of_one_class_keep_separate_state() {
    check_on_vm(
        &mut bouy("state-isolation.ts"),
        &Outcome {
            stdout: "first: 4, second: 2\n[ 'a', 'b' ] [ 'a' ]\n",
            stderr: "",
            status: 0,
        },
    );
}

#[test]
fn a_crash_restarts_only_the_failed_actor() {
    check_on_vm(
        &mut bouy("fault-isolation.ts"),
        &Outcome {
            stdout: "Account alice failed in deposit: Error: negative deposit\n\
                     ActorFailed\n\
                     bob still answers: 15\n\
                     alice restarted with a fresh balance: 1\n\
                     alice: running, restarts 1\n\
                     bob: running, restarts 0\n",
            stderr: "bouy: Account alice crashed: Error: negative deposit\n",
            status: 0,
        },
    );
}

#[test]
fn casts_and_a_call_arrive_in_order() {
    check_on_vm(
        &mut bouy("ordering.ts"),
        &Outcome {
            stdout: "1000 entries\nin order: true\n",
            stderr: "",
            status: 0,
        },
    );
}

#[test]
fn one_for_all_restarts_every_child() {
    check_on_vm(
        &mut bouy("supervise-one-for-all.ts"),
        &Outcome {
            stdout: "ActorFailed: Worker reader failed in fail: Error: lost the connection\n\
                     reader: 1\n\
                     writer: 1\n\
                     Worker reader: running, restarts 1\n\
                     Worker writer: running, restarts 1\n",
            stderr: "bouy: Worker reader crashed: Error: lost the connection\n",
            status: 0,
        },
    );
}

#[test]
fn a_full_mailbox_rejects_a_cast() {
    check_on_vm(
        &mut bouy("mailbox-reject.ts"),
        &Outcome {
            stdout: "MailboxFull: Slow slow has a full mailbox\n\
                     accepted before the mailbox filled: true\n\
                     after the mailbox drains: pong\n",
            stderr: "",
            status: 0,
        },
    );
}

#[test]
fn a_call_cycle_throws_instead_of_a_deadlock() {
    check_on_vm(
        &mut bouy("call-cycle.ts"),
        &Outcome {
            stdout: "CallCycle: Client client is busy with a call that waits on this call. \
                     Use cast() or pass the data in the first call.\n\
                     the client still answers: hello\n",
            stderr: "",
            status: 0,
        },
    );
}

#[test]
fn stop_ends_a_turn_and_with_timeout_cancels() {
    check_on_vm(
        &mut bouy("stop-and-timeout.ts"),
        &Outcome {
            stdout: "the waiting caller got ActorStopped: Worker worker is stopped\n\
                     stop returned\n\
                     stop ended the turn early\n\
                     a later call got ActorStopped\n\
                     status: stopped\n\
                     CallTimedOut: the call did not finish within 100 ms\n\
                     withTimeout returns a value in time: fast\n",
            stderr: "",
            status: 0,
        },
    );
}

#[test]
fn promise_all_runs_actor_calls_in_parallel() {
    check_on_vm(
        &mut bouy("parallel-calls.ts"),
        &Outcome {
            stdout: "[ 300, 300, 300, 300 ]\n\
                     the calls ran in parallel\n\
                     [ 300, 300 ]\n\
                     the pair ran in parallel\n",
            stderr: "",
            status: 0,
        },
    );
}

/// One scheduler thread, so only preemption lets the echo actor answer while another
/// actor spins.
#[test]
fn a_spinning_actor_does_not_delay_replies() {
    check_on_vm(
        bouy("fairness.ts").env("ERL_FLAGS", "+S 1"),
        &Outcome {
            stdout: "every reply was fast\n50 replies arrived during the spin\n",
            stderr: "",
            status: 0,
        },
    );
}

#[test]
fn ten_thousand_actors_answer() {
    check_on_vm(
        &mut bouy("load.ts"),
        &Outcome {
            stdout: "10000 actors answered; the sum is 49995000\n\
                     in parallel: 10000 answers, last 9999\n",
            stderr: "",
            status: 0,
        },
    );
}

#[test]
fn all_settled_and_race_run_over_items_map() {
    check_on_vm(
        &mut bouy("partial-failure.ts"),
        &Outcome {
            stdout: "a.example is up\n\
                     Checker #2 failed in check: Error: cannot reach down.example\n\
                     c.example is up\n\
                     the fastest mirror: fast.example is up\n",
            stderr: "bouy: Checker #2 crashed: Error: cannot reach down.example\n",
            status: 0,
        },
    );
}

#[test]
fn a_ref_typed_binding_calls_a_method_named_like_a_mutator() {
    check_on_vm(
        &mut bouy("ref-fan-out.ts"),
        &Outcome {
            stdout: "[ 1, 1, 1 ]\n[ 2, 1 ]\ntrue 2\n",
            stderr: "",
            status: 0,
        },
    );
}

#[test]
fn an_uncaught_actor_failure_exits_with_status_1() {
    check_on_vm(
        &mut bouy("uncaught-actor-failure.ts"),
        &Outcome {
            stdout: "before the call\n",
            stderr: "bouy: Worker worker crashed: RangeError: out of range\n\
                     Uncaught ActorFailed: Worker worker failed in fail: RangeError: out of range\n",
            status: 1,
        },
    );
}

#[test]
fn program_arguments_reach_process_argv() {
    check_on_vm(
        bouy("arguments.ts").args(["one", "--two", "three four"]),
        &Outcome {
            stdout: "[ 'one', '--two', 'three four' ]\n",
            stderr: "",
            status: 0,
        },
    );
}

#[test]
fn a_missing_file_exits_with_status_2() {
    check(
        &mut bouy("missing.ts"),
        &Outcome {
            stdout: "",
            stderr: "bouy: cannot find the file tests/programs/missing.ts\n",
            status: 2,
        },
    );
}

#[test]
fn diagnostics_stop_the_program_before_the_vm_starts() {
    let cases: [(&str, &[&str]); 7] = [
        (
            "bouy200-redeclared.ts",
            &["1:7: BOUY200: Identifier `total` has already been declared"],
        ),
        (
            "bouy201-unknown-package.ts",
            &[
                "1:23: BOUY201: cannot import \"lodash\": import a relative module (./file.ts) or \
               one of the libraries bouy, effect, ai, and @ai-sdk/openai",
            ],
        ),
        (
            "bouy202-module-let.ts",
            &[
                "3:1: BOUY202: a module-level `let` is shared mutable state; use `const`, or \
                 keep the state in a function or an actor",
                "7:5: BOUY202: module-level `requests` cannot change after initialization; keep \
                 changing state in a function or an actor",
            ],
        ),
        (
            "bouy203-new-actor.ts",
            &["10:17: BOUY203: `new Counter` creates an actor; use \
               `spawn(Counter, { args: [...] })` from \"bouy\""],
        ),
        (
            "bouy205-closure-rebinds.ts",
            &[
                "7:7: BOUY205: a closure cannot change `sum`, which belongs to an enclosing \
               function; return the new value from the closure instead",
            ],
        ),
        (
            "bouy206-then-chain.ts",
            &["11:3: BOUY206: `.then()` chains are not supported; use `await` and try/catch"],
        ),
        (
            "bouy207-set-timeout.ts",
            &[
                "10:1: BOUY207: `setTimeout` is not available in Bouy; read process.env.NAME or \
               process.argv, and use sleep or schedule from \"bouy\" for timers",
            ],
        ),
    ];
    for (program, diagnostics) in cases {
        let path = format!("diagnostics/{program}");
        let mut stderr = String::new();
        for diagnostic in diagnostics {
            let _ = writeln!(stderr, "tests/programs/{path}:{diagnostic}");
        }
        check(
            &mut bouy(&path),
            &Outcome {
                stdout: "",
                stderr: &stderr,
                status: 2,
            },
        );
    }
}
