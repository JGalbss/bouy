//! End-to-end programs: `buoy run` compiles each program in `tests/programs/` from
//! TypeScript and runs it on one VM. Each test checks stdout, stderr, and the exit status.
//! A program that measures time prints a fixed line when the bound holds, and the measured
//! times when it does not.

mod common;

use std::fmt::Write as _;
use std::path::Path;
use std::process::Command;

struct Outcome<'a> {
    stdout: &'a str,
    stderr: &'a str,
    status: i32,
}

/// `buoy run tests/programs/<program>`, from the repository root, so that diagnostics print
/// the path relative to it.
fn buoy(program: &str) -> Command {
    let mut command = common::buoy();
    command
        .current_dir(common::repository())
        .arg("run")
        .arg(Path::new("tests/programs").join(program));
    command
}

fn check(command: &mut Command, expected: &Outcome) {
    let deadline = common::deadline();
    let common::Run { output, timed_out } = common::run(command, deadline);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let report = format!("{command:?}\n--- stdout:\n{stdout}--- stderr:\n{stderr}");
    assert!(
        !timed_out,
        "ran past the deadline of {deadline:?}: {report}"
    );
    assert_eq!(stdout, expected.stdout, "stdout of {report}");
    assert_eq!(stderr, expected.stderr, "stderr of {report}");
    assert_eq!(
        output.status.code(),
        Some(expected.status),
        "exit status of {report}"
    );
}

/// Like `check`, for a program that runs on the VM.
fn check_on_vm(command: &mut Command, expected: &Outcome) {
    if common::vm_available() {
        check(command, expected);
    }
}

#[test]
fn greeter_answers_two_calls() {
    check_on_vm(
        &mut buoy("hello.ts"),
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
        &mut buoy("state-isolation.ts"),
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
        &mut buoy("fault-isolation.ts"),
        &Outcome {
            stdout: "Account alice failed in deposit: Error: negative deposit\n\
                     ActorFailed\n\
                     bob still answers: 15\n\
                     alice restarted with a fresh balance: 1\n\
                     alice: running, restarts 1\n\
                     bob: running, restarts 0\n",
            stderr: "buoy: Account alice crashed: Error: negative deposit\n",
            status: 0,
        },
    );
}

#[test]
fn an_actor_runs_the_effect_that_a_method_returns() {
    check_on_vm(
        &mut buoy("effect-actor.ts"),
        &Outcome {
            stdout: "withdrew 30, left 70\n\
                     typed failure at the caller: InsufficientFunds, balance 70\n\
                     the state stays: balance 70, refusals 1\n\
                     a defect crashes the actor: ActorFailed\n\
                     after the restart: balance 100, refusals 0\n\
                     main: running, restarts 1\n",
            stderr: "buoy: Wallet main crashed: Error: corrupt ledger\n",
            status: 0,
        },
    );
}

#[test]
fn casts_and_a_call_arrive_in_order() {
    check_on_vm(
        &mut buoy("ordering.ts"),
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
        &mut buoy("supervise-one-for-all.ts"),
        &Outcome {
            stdout: "ActorFailed: Worker reader failed in fail: Error: lost the connection\n\
                     reader: 1\n\
                     writer: 1\n\
                     Worker reader: running, restarts 1\n\
                     Worker writer: running, restarts 1\n",
            stderr: "buoy: Worker reader crashed: Error: lost the connection\n",
            status: 0,
        },
    );
}

#[test]
fn a_full_mailbox_rejects_a_cast() {
    check_on_vm(
        &mut buoy("mailbox-reject.ts"),
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
        &mut buoy("call-cycle.ts"),
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
fn turns_that_wait_on_each_other_at_once_do_not_deadlock() {
    check_on_vm(
        &mut buoy("wait-cycles.ts"),
        &Outcome {
            stdout: "crossing calls end: true\n\
                     crossing backpressure casts end\n\
                     a call that waits on a restart that waits on it: CallCycle\n\
                     the restart then completes: pong 42\n\
                     stop returns before the restart constructor ends: true\n\
                     a spawn after the stop works\n",
            stderr: "buoy: Worker #6 crashed: Error: boom\n\
                     buoy: Parent #8 crashed: Error: parent boom\n",
            status: 0,
        },
    );
}

#[test]
fn concurrent_senders_cannot_pass_the_capacity() {
    check_on_vm(
        &mut buoy("mailbox-bounds.ts"),
        &Outcome {
            stdout: "reject: accepted 5, MailboxFull 45\n\
                     backpressure: the mailbox stayed within capacity plus blocked senders: true\n",
            stderr: "",
            status: 0,
        },
    );
}

#[test]
fn schedules_cancel_skip_and_end_with_their_actor() {
    check_on_vm(
        &mut buoy("schedules.ts"),
        &Outcome {
            stdout: "a 60-day timer: plans 2, restarts 0\n\
                     withTimeout beyond 2^32 ms: fast\n\
                     ticks after cancelSchedule returned: 0\n\
                     [Schedule]\n\
                     a full mailbox skips ticks: mailbox 1, ticks 1\n\
                     a timer from Promise.all ends with its actor: 0 ticks\n",
            stderr: "buoy: Owner #5 crashed: Error: owner boom\n",
            status: 0,
        },
    );
}

#[test]
fn actors_end_cleanly_and_keep_their_labels() {
    check_on_vm(
        &mut buoy("actor-lifecycle.ts"),
        &Outcome {
            stdout: "running leaves after 3 restarts: 1\n\
                     status during the restart constructor: restarting\n\
                     ActorStopped | Doomed doomed is stopped\n\
                     TypeError: spawn() needs an actor class\n\
                     fast\n\
                     [ 'late' ]\n\
                     integral floats as options: pong pong\n\
                     Cell ready\n\
                     [ 'cast threw ActorStopped', 'stopped' ]\n\
                     stopped actors kept: 1000\n",
            stderr: "buoy: Team team crashed: Error: team boom\n\
                     buoy: Team team crashed: Error: team boom\n\
                     buoy: Team team crashed: Error: team boom\n\
                     buoy: SlowStart slow crashed: Error: slow boom\n\
                     buoy: Doomed doomed crashed: Error: constructor failed after registering\n",
            status: 0,
        },
    );
}

/// Top-level code traps no exits, so its finished workers leave no messages to scan.
#[test]
fn top_level_promise_all_stays_fast() {
    check_on_vm(
        &mut buoy("top-level-workers.ts"),
        &Outcome {
            stdout: "top-level Promise.all stays fast\n",
            stderr: "",
            status: 0,
        },
    );
}

#[test]
fn stop_ends_a_turn_and_with_timeout_cancels() {
    check_on_vm(
        &mut buoy("stop-and-timeout.ts"),
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
        &mut buoy("parallel-calls.ts"),
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
        buoy("fairness.ts").env("ERL_FLAGS", "+S 1"),
        &Outcome {
            stdout: "every reply was fast\n50 replies arrived during the spin\n",
            stderr: "",
            status: 0,
        },
    );
}

/// The kernel of the program is an island of the native tier, which runs it as machine
/// code in slices of 200 us (contract section 17.11).
#[test]
fn a_native_kernel_does_not_delay_replies() {
    let mut command = common::buoy();
    command
        .current_dir(common::repository())
        .args(["run", "--semantics", "reference"])
        .arg(Path::new("tests/programs").join("native-fairness.ts"))
        .env("ERL_FLAGS", "+S 1")
        .env("BUOY_JIT_TRACE", "1");
    check_on_vm(
        &mut command,
        &Outcome {
            stdout: "1596680831\n1141913883\nevery reply was fast\n\
                     50 replies arrived during the kernel\n",
            stderr: "buoy jit: kernel is an island\n\
                     buoy jit: buoy@programs@native_fairness_ts 0 native\n\
                     buoy jit: buoy@programs@native_fairness_ts 0 native\n",
            status: 0,
        },
    );
}

/// The heaps of native runs count toward `BUOY_MAX_MEMORY`: 8 actors that hold about
/// 60 MB each in runs of the native tier stop a VM with a limit of 256 MB (contract
/// section 17.11).
#[test]
fn native_heaps_count_toward_the_memory_limit() {
    let mut command = common::buoy();
    command
        .current_dir(common::repository())
        .args(["run", "--semantics", "reference"])
        .arg(Path::new("tests/programs").join("native-memory-limit.ts"))
        .env("BUOY_MAX_MEMORY", "256M");
    check_on_vm(
        &mut command,
        &Outcome {
            stdout: "",
            stderr: "buoy: the program used more than 256 MiB of memory and was stopped; \
                     set BUOY_MAX_MEMORY to change the limit\n",
            status: 1,
        },
    );
}

#[test]
fn ten_thousand_actors_answer() {
    check_on_vm(
        &mut buoy("load.ts"),
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
        &mut buoy("partial-failure.ts"),
        &Outcome {
            stdout: "a.example is up\n\
                     Checker #2 failed in check: Error: cannot reach down.example\n\
                     c.example is up\n\
                     the fastest mirror: fast.example is up\n",
            stderr: "buoy: Checker #2 crashed: Error: cannot reach down.example\n",
            status: 0,
        },
    );
}

#[test]
fn a_ref_typed_binding_calls_a_method_named_like_a_mutator() {
    check_on_vm(
        &mut buoy("ref-fan-out.ts"),
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
        &mut buoy("uncaught-actor-failure.ts"),
        &Outcome {
            stdout: "before the call\n",
            stderr: "buoy: Worker worker crashed: RangeError: out of range\n\
                     Uncaught ActorFailed: Worker worker failed in fail: RangeError: out of range\n",
            status: 1,
        },
    );
}

#[test]
fn a_program_past_the_memory_limit_stops_with_status_1() {
    check_on_vm(
        buoy("memory-limit.ts").env("BUOY_MAX_MEMORY", "128M"),
        &Outcome {
            stdout: "",
            stderr: "buoy: the program used more than 128 MiB of memory and was stopped; \
                     set BUOY_MAX_MEMORY to change the limit\n",
            status: 1,
        },
    );
}

#[test]
fn an_actor_past_max_memory_restarts_and_spares_the_others() {
    check_on_vm(
        &mut buoy("actor-memory-limit.ts"),
        &Outcome {
            stdout: "ActorOutOfMemory: Hoarder hoarder used more than its memory limit of \
                     16777216 bytes\n\
                     the counter still answers: 2\n\
                     the hoarder restarted empty: 0\n\
                     hoarder: running, restarts 1\n\
                     counter: running, restarts 0\n",
            stderr: "buoy: Hoarder hoarder crashed: ActorOutOfMemory: Hoarder hoarder used more \
                     than its memory limit of 16777216 bytes\n",
            status: 0,
        },
    );
}

#[test]
fn a_turn_past_turn_timeout_ends_and_the_actor_restarts() {
    check_on_vm(
        &mut buoy("actor-turn-timeout.ts"),
        &Outcome {
            stdout: "ActorTimedOut: Looper looper did not finish spin within 50 ms\n\
                     the loop ended within a second: true\n\
                     the counter still answers: 2\n\
                     the looper restarted fresh: 0\n\
                     round 1: ActorTimedOut\n\
                     round 2: ActorTimedOut\n\
                     past the budget: ActorStopped\n\
                     looper: running, restarts 1\n\
                     counter: running, restarts 0\n\
                     worker: stopped, restarts 1\n",
            stderr: "buoy: Looper looper crashed: ActorTimedOut: Looper looper did not finish \
                     spin within 50 ms\n\
                     buoy: Looper worker crashed: ActorTimedOut: Looper worker did not finish \
                     spin within 20 ms\n\
                     buoy: Looper worker crashed: ActorTimedOut: Looper worker did not finish \
                     spin within 20 ms\n",
            status: 0,
        },
    );
}

#[test]
fn a_batch_of_calls_keeps_the_semantics_of_parallel_calls() {
    check_on_vm(
        &mut buoy("batch-calls.ts"),
        &Outcome {
            stdout: "[ 0, 1, 2, 3 ]\n\
                     1000 calls answered\n\
                     [ 250, 251, 252, 253 ]\n\
                     [ 253, 20 ]\n\
                     ActorFailed in failFirst\n\
                     [ 0, 253, 252, 253 ]\n\
                     CallCycle\n\
                     a,b\n",
            stderr: "buoy: Counter #1 crashed: Error: boom\n",
            status: 0,
        },
    );
}

#[test]
fn program_arguments_reach_process_argv() {
    check_on_vm(
        buoy("arguments.ts").args(["one", "--two", "three four"]),
        &Outcome {
            stdout: "[ 'one', '--two', 'three four' ]\n",
            stderr: "",
            status: 0,
        },
    );
}

/// `buoy run` passes each argument after the entry as it is, as `node` does: `--help`, `-h`,
/// `--`, and invalid UTF-8, where each invalid sequence becomes one U+FFFD.
#[cfg(unix)]
#[test]
fn every_argument_after_the_entry_reaches_the_program() {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;
    check_on_vm(
        buoy("arguments.ts").args([
            OsStr::new("--help"),
            OsStr::new("--"),
            OsStr::new("-h"),
            OsStr::from_bytes(b"a\xffb"),
            OsStr::from_bytes(b"c\xe2\x82d"),
        ]),
        &Outcome {
            stdout: "[ '--help', '--', '-h', 'a\u{FFFD}b', 'c\u{FFFD}d' ]\n",
            stderr: "",
            status: 0,
        },
    );
}

#[test]
fn actor_state_survives_finally_and_methods_work_as_values() {
    check_on_vm(
        &mut buoy("actor-values.ts"),
        &Outcome {
            stdout: "3 after 1 runs\n\
                     4 after 2 runs\n\
                     2,3 function hi bo 5 5\n\
                     dark a,b\n\
                     1 2\n\
                     {\"owner\":\"ann\"} owner false 4\n\
                     label:5\n\
                     missing 404\n\
                     1,3\n",
            stderr: "",
            status: 0,
        },
    );
}

#[test]
fn modules_re_export_and_export_defaults() {
    check_on_vm(
        &mut buoy("modules/main.ts"),
        &Outcome {
            stdout: "20 20 true\n10 8 10 6\n",
            stderr: "",
            status: 0,
        },
    );
}

/// The CLI becomes the VM, so SIGTERM ends the program as it ends Node: by the signal, with
/// nothing more on stdout, and with no VM left behind.
#[cfg(unix)]
#[test]
fn sigterm_ends_the_program() {
    use std::io::{BufRead, BufReader, Read};
    use std::os::unix::process::ExitStatusExt;
    if !common::vm_available() {
        return;
    }
    let mut child = buoy("sleeper.ts")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("buoy runs");
    let mut stdout = BufReader::new(child.stdout.take().expect("stdout is piped"));
    let mut first = String::new();
    stdout.read_line(&mut first).expect("the program prints");
    assert_eq!(first, "start\n");
    let killed = Command::new("kill")
        .args(["-TERM", &child.id().to_string()])
        .status()
        .expect("kill runs");
    assert!(killed.success());
    let status = child.wait().expect("the program ends");
    let mut rest = String::new();
    stdout.read_to_string(&mut rest).expect("stdout reads");
    assert_eq!(status.signal(), Some(15), "{status:?}");
    assert_eq!(rest, "");
}

/// A SIGTERM that comes while the VM boots ends the program by the signal, as it ends Node.
/// The shell sends it to itself with SIGTERM blocked before it execs the CLI, so it waits
/// through the whole boot, where ERTS dropped one that came before its signal server ran.
#[cfg(unix)]
#[test]
fn sigterm_during_the_boot_ends_the_program() {
    use nix::sys::signal::{SigSet, SigmaskHow, Signal, pthread_sigmask};
    use std::os::unix::process::ExitStatusExt;
    if !common::vm_available() {
        return;
    }
    let mut command = Command::new("/bin/sh");
    common::buoy_env(&mut command)
        .current_dir(common::repository())
        .args(["-c", "kill -TERM $$ && exec \"$@\"", "sh"])
        .arg(common::buoy_binary())
        .args(["run", "tests/programs/sleeper.ts"]);
    let mut mask = SigSet::empty();
    pthread_sigmask(
        SigmaskHow::SIG_BLOCK,
        Some(&SigSet::from(Signal::SIGTERM)),
        Some(&mut mask),
    )
    .expect("SIGTERM blocks");
    let common::Run { output, timed_out } = common::run(&mut command, common::deadline());
    pthread_sigmask(SigmaskHow::SIG_SETMASK, Some(&mask), None).expect("the mask restores");
    assert!(!timed_out, "the program ignored the SIGTERM of its boot");
    assert_eq!(output.status.signal(), Some(15), "{:?}", output.status);
    assert_eq!(String::from_utf8_lossy(&output.stdout), "");
}

/// A program sees the `PATH` of its caller, as a Node program does, also when the VM starts
/// through erlexec, which puts the directories of the OTP release first on `PATH`.
#[test]
fn the_program_sees_the_path_of_its_caller() {
    if !common::vm_available() {
        return;
    }
    let mut command = common::buoy();
    command
        .args(["-p", "process.env.PATH"])
        .env("ERL_AFLAGS", "+S 2:2");
    let path = command
        .get_envs()
        .find_map(|(name, value)| (name == "PATH").then_some(value).flatten())
        .map(|path| path.to_string_lossy().into_owned())
        .expect("buoy_env sets PATH");
    let common::Run { output, timed_out } = common::run(&mut command, common::deadline());
    assert!(!timed_out);
    assert_eq!(String::from_utf8_lossy(&output.stdout), format!("{path}\n"));
    assert!(output.status.success(), "{:?}", output.status);
}

/// The node form hides the variables that the CLI and the start of the VM set from
/// `process.env` and from the environment of a child process, as Node has none of them.
#[test]
fn the_node_form_hides_the_variables_of_the_cli() {
    if !common::vm_available() {
        return;
    }
    let names = [
        "ERL_CRASH_DUMP_SECONDS",
        "BUOY_COMPILER",
        "ROOTDIR",
        "BINDIR",
        "EMU",
        "PROGNAME",
    ];
    let mut command = common::buoy();
    for name in names {
        command.env_remove(name);
    }
    command.args([
        "-e",
        &format!(
            "const names = {names:?};
             const child = require('child_process').execFileSync('/usr/bin/env').toString();
             console.log(names.filter((name) => name in process.env ||
               Object.keys(process.env).includes(name) || child.includes(`${{name}}=`)));"
        ),
    ]);
    let common::Run { output, timed_out } = common::run(&mut command, common::deadline());
    assert!(!timed_out);
    assert_eq!(String::from_utf8_lossy(&output.stdout), "[]\n");
    assert!(output.status.success(), "{:?}", output.status);
}

/// A reader that closes stdout early ends the program, as `node app.ts | head -1` does.
#[test]
fn a_closed_stdout_ends_the_program() {
    use std::io::{BufRead, BufReader};
    use std::time::{Duration, Instant};
    if !common::vm_available() {
        return;
    }
    let mut child = buoy("closed-stdout.ts")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("buoy runs");
    let mut stdout = BufReader::new(child.stdout.take().expect("stdout is piped"));
    let mut first = String::new();
    stdout.read_line(&mut first).expect("the program prints");
    assert_eq!(first, "line 0\n");
    drop(stdout);
    let deadline = Instant::now() + Duration::from_secs(120);
    let status = loop {
        if let Some(status) = child.try_wait().expect("the status reads") {
            break status;
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            panic!("the program kept running after its stdout closed");
        }
        std::thread::sleep(Duration::from_millis(100));
    };
    assert_eq!(status.code(), Some(0));
}

/// `ERL_AFLAGS` starts the VM through `erlexec`, which puts its directories first on `PATH`,
/// so a child `buoy` found another `erl` and built a second runtime.
#[test]
fn the_program_sees_the_environment_of_the_cli() {
    let path = std::env::var_os("PATH").unwrap_or_default();
    let mut command = buoy("host-environment.ts");
    for name in [
        "ROOTDIR",
        "BINDIR",
        "EMU",
        "PROGNAME",
        "ERL_ROOTDIR",
        "ERL_CRASH_DUMP_SECONDS",
        "BUOY_COMPILER",
    ] {
        command.env_remove(name);
    }
    check_on_vm(
        command
            .env("ERL_AFLAGS", "+S 2:2")
            .env("PATH", &path)
            .env("EXPECTED_PATH", &path),
        &Outcome {
            stdout: "0\ntrue\n",
            stderr: "",
            status: 0,
        },
    );
}

#[test]
fn a_runtime_directory_without_the_runtime_fails_before_the_vm_starts() {
    let empty = std::env::temp_dir().join(format!("buoy-empty-runtime-{}", std::process::id()));
    std::fs::create_dir_all(&empty).expect("the temporary directory is writable");
    check(
        buoy("hello.ts").env("BUOY_RUNTIME", &empty),
        &Outcome {
            stdout: "",
            stderr: &format!(
                "buoy: BUOY_RUNTIME={} holds no buoy_main.beam\n",
                empty.display()
            ),
            status: 1,
        },
    );
    let _ = std::fs::remove_dir_all(&empty);
}

/// A runtime build that fails, here because `erlc` is missing, leaves no private build
/// directory in the cache.
#[test]
fn a_failed_runtime_build_leaves_nothing_behind() {
    let cache = std::env::temp_dir().join(format!("buoy-cache-{}", std::process::id()));
    std::fs::create_dir_all(&cache).expect("the temporary directory is writable");
    let output = buoy("hello.ts")
        .env("XDG_CACHE_HOME", &cache)
        .env("PATH", "/nonexistent")
        .env_remove("BUOY_RUNTIME")
        .env_remove("BUOY_ERL")
        .output()
        .expect("buoy runs");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.starts_with("buoy: cannot run erlc"), "{stderr}");
    assert_eq!(output.status.code(), Some(1));
    let left: Vec<_> = std::fs::read_dir(cache.join("buoy"))
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .map(|entry| entry.path())
                .collect()
        })
        .unwrap_or_default();
    assert!(left.is_empty(), "{left:?}");
    let _ = std::fs::remove_dir_all(&cache);
}

/// An error that writes the build names the path and the cause.
#[cfg(unix)]
#[test]
fn a_build_that_cannot_be_written_names_the_path() {
    use std::os::unix::fs::PermissionsExt;
    let project = std::env::temp_dir().join(format!("buoy-read-only-{}", std::process::id()));
    std::fs::create_dir_all(&project).expect("the temporary directory is writable");
    std::fs::write(project.join("package.json"), "{}").expect("the project is writable");
    std::fs::write(project.join("app.ts"), "console.log(1);\n").expect("the project is writable");
    let build = project
        .canonicalize()
        .expect("the project exists")
        .join(".buoy/build/src");
    std::fs::set_permissions(&project, std::fs::Permissions::from_mode(0o555))
        .expect("the permissions change");
    let output = common::buoy()
        .arg("run")
        .arg(project.join("app.ts"))
        .output()
        .expect("buoy runs");
    std::fs::set_permissions(&project, std::fs::Permissions::from_mode(0o755))
        .expect("the permissions change");
    let _ = std::fs::remove_dir_all(&project);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.starts_with(&format!(
            "buoy: cannot write the build in {}: ",
            build.display()
        )),
        "{stderr}"
    );
    assert_eq!(output.status.code(), Some(1));
}

#[test]
fn a_missing_file_exits_with_status_2() {
    check(
        &mut buoy("missing.ts"),
        &Outcome {
            stdout: "",
            stderr: "buoy: cannot find the file tests/programs/missing.ts\n",
            status: 2,
        },
    );
}

#[test]
fn diagnostics_stop_the_program_before_the_vm_starts() {
    let cases: [(&str, &[&str]); 7] = [
        (
            "buoy200-redeclared.ts",
            &["1:7: BUOY200: Identifier 'total' has already been declared"],
        ),
        (
            "buoy201-unknown-package.ts",
            &[
                "1:23: BUOY201: cannot import \"lodash\": import a relative module (./file.ts) or \
               one of the libraries buoy, effect, ai, and @ai-sdk/openai",
            ],
        ),
        (
            "buoy202-module-let.ts",
            &[
                "3:1: BUOY202: a module-level `let` is shared mutable state; use `const`, or \
                 keep the state in a function or an actor",
                "7:5: BUOY202: module-level `requests` cannot change after initialization; keep \
                 changing state in a function or an actor",
            ],
        ),
        (
            "buoy203-new-actor.ts",
            &["10:17: BUOY203: `new Counter` creates an actor; use \
               `spawn(Counter, { args: [...] })` from \"buoy\""],
        ),
        (
            "buoy205-closure-rebinds.ts",
            &[
                "7:7: BUOY205: a closure cannot change `sum`, which belongs to an enclosing \
               function; return the new value from the closure instead",
            ],
        ),
        (
            "buoy206-then-chain.ts",
            &["11:3: BUOY206: `.then()` chains are not supported; use `await` and try/catch"],
        ),
        (
            "buoy207-set-timeout.ts",
            &[
                "10:1: BUOY207: `setTimeout` is not available in Buoy; use sleep or schedule \
               from \"buoy\" for timers",
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
            &mut buoy(&path),
            &Outcome {
                stdout: "",
                stderr: &stderr,
                status: 2,
            },
        );
    }
}

#[test]
fn the_node_form_reports_code_that_does_not_parse_as_a_syntax_error() {
    let path = "tests/programs/diagnostics/buoy200-redeclared.ts";
    let mut command = common::buoy();
    command.current_dir(common::repository()).arg(path);
    let place = common::repository()
        .join(path)
        .canonicalize()
        .expect("the program exists");
    let version = include_str!("../../../.node-version").trim();
    // Node's report of the SyntaxError that the loader throws: the place and line, the
    // source line, a caret under the column, the error, and the version.
    check(
        &mut command,
        &Outcome {
            stdout: "",
            stderr: &format!(
                "{}:1\nconst total = 1;\n      ^\n\n\
                 SyntaxError: Identifier 'total' has already been declared\n\nNode.js v{version}\n",
                place.display()
            ),
            status: 1,
        },
    );
}
