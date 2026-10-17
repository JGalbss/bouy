# Benchmarks: Bouy, Node, and Bun

Each suite is one program pair in `programs/<suite>/`. `bouy.ts` is a Bouy program that uses the `bouy` actor API. `node.ts` is the closest plain Node program, with actors from `programs/node-actor.ts`: objects with an unbounded mailbox queue that run one message at a time and answer calls with promises. The harness runs `node.ts` on Node and with `bun run` on Bun. A suite that needs a different Bun program holds a `bun.ts`, and its header says why. No suite has one yet. Node and Bun are the baselines, and Bun is the bar of [goal.md](../docs/goal.md) requirement 11. The product never runs on Node or Bun.

The speed suites use no `worker_threads`. The recovery suites protect the Node program as a competent Node developer would, and the comment at the top of each `node.ts` names the protections. Two of them run the agents on worker threads, with `programs/node-shards.ts`.

`crates/bouy-bench` runs the programs and writes `results/<YYYY-MM-DD>-<host>.json`. Every number that a document quotes must come from a file in `results/`.

## Run

```sh
export PATH="$HOME/.cargo/bin:$PATH"
cargo build --release -p bouy-cli
cargo run --release -p bouy-bench -- --bouy target/release/bouy
pnpm format
```

`pnpm format` formats the new results file, so that `pnpm check` passes.

| Option               | Default                     | Meaning                                                               |
| -------------------- | --------------------------- | --------------------------------------------------------------------- |
| `[SUITES]...`        | every directory in programs | The suites to run, such as `spawn fairness`.                          |
| `--runs <N>`         | `5`                         | The measured runs of each program. One warm-up run comes first.       |
| `--bouy <PATH>`      | `bouy` on `PATH`            | The `bouy` CLI to measure. The env var `BOUY_BENCH_BOUY` sets it too. |
| `--node <PATH>`      | `node` on `PATH`            | The Node baseline. The env var `BOUY_BENCH_NODE` sets it too.         |
| `--bun <PATH>`       | `bun` on `PATH`             | The Bun baseline. The env var `BOUY_BENCH_BUN` sets it too.           |
| `--out <DIR>`        | `bench/results`             | The directory for the results file.                                   |
| `--host <NAME>`      | the CPU model as a slug     | The host part of the results file name.                               |
| `BOUY_ERL` (env var) | `erl` on `PATH`             | The `erl` that `bouy` runs and whose OTP release the file records.    |

Build the CLI from the same tree as the programs. The results file records `git describe --dirty` of the tree, not of the binary.

## Memory

Each run has a memory limit, so a fault in a program cannot exhaust the machine:

- The harness sets `BOUY_MAX_MEMORY=1G` for each Bouy VM.
- Each Node program runs with `--max-old-space-size=512`, except `memory-leak`. A process-wide `--max-old-space-size` overrides the `resourceLimits` of every worker thread, so the `memory-leak` program runs without it, under the limits of its workers.
- Bun has no heap limit: it has no `--max-old-space-size`, it ignores the `resourceLimits` of a worker thread, and macOS refuses a `ulimit -v` or `ulimit -d`. So the measuring process reads the RSS of each program every 200 ms and kills a program past 1 GiB. The ceiling applies to every runtime, and a killed run fails with a line that names the ceiling.
- The harness runs one program at a time.

## Limits

`thresholds.json` holds the limits of the nightly job, which [docs/design/testing.md](../docs/design/testing.md) section 5.11 describes. For each suite and Bouy metric, a limit is the largest allowed ratio of a new median to the baseline median. A limit above 1 is the ceiling of a metric where less is better, such as `wall_ms`. A limit below 1 is the floor of a metric where more is better, such as `casts_per_s`. The limits leave room for a loaded machine. The `wall_ms` ceilings are wide, because `wall_ms` includes the start of the VM, which grows the most with the load. The limits are not results, so no document may quote them.

```sh
target/release/bouy-bench compare <baseline.json> [<previous.json>] <current.json>
```

The command prints a Markdown table with each median and its ratio to the baseline median. It exits with 1 when a metric is past its limit in the previous run and in the current run. A metric past its limit in the current run only is a warning. The files must come from one host.

## Method

1. The harness runs each program once to warm up. This compiles the Bouy module, fills the runtime cache in `~/.cache/bouy`, and fills the file cache.
2. Then it runs the Bouy program, the Node program, and the Bun program in turns, N times each, so that a change in the load of the machine reaches all three.
3. Each run is a fresh process. The harness starts it under a copy of itself, which waits for that one child, so `getrusage(RUSAGE_CHILDREN)` gives the peak RSS of the program alone. That copy also measures the wall time from the start of the process to its exit.
4. A program prints one JSON line last. A run fails when the exit status is not 0 or the last line is not a JSON object. A program checks its own answers, such as the count of casts that the actor took, and exits with status 1 when one is wrong.
5. The harness records the 1, 5, and 15 minute load averages before and after each run, the host, and the versions of Bouy, OTP, Node, and Bun.

## Suites

| Suite             | Work in both programs                                                                                         | Metrics                                                                                                                                |
| ----------------- | ------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `startup`         | Print one line.                                                                                               | `wall_ms`, `peak_rss_mib`                                                                                                              |
| `spawn`           | Start 100,000 actors that each hold a number, and keep their refs.                                            | `per_actor_us`, `rss_per_actor_bytes`                                                                                                  |
| `call-latency`    | 100,000 sequential calls to one actor.                                                                        | `mean_us`, `max_ms`, `p50_us`, `p99_us`                                                                                                |
| `cast-throughput` | 1,000,000 casts to one actor, then one call that waits for them.                                              | `casts_per_s`                                                                                                                          |
| `fan-out`         | 10 rounds of 10,000 parallel calls over 1,000 actors with `Promise.all`.                                      | `calls_per_s`, `max_round_ms`                                                                                                          |
| `fairness`        | 8 actors run CPU-bound loops for 2 s. Meanwhile the main code pings another actor and sleeps 1 ms, in a loop. | `pings`, `p50_ms`, `p99_ms`, `max_ms` of the ping round trips                                                                          |
| `crash-recovery`  | 1,000 times: an actor throws, restarts, and answers the next call.                                            | `recovery_us`, `max_recovery_ms`, `cycle_us`                                                                                           |
| `compute`         | `fib(27)` by naive recursion in one actor, 20 calls.                                                          | `fib_ms`                                                                                                                               |
| `payload`         | 100,000 casts of one object of about 1 KB of JSON, then one call that waits for them.                         | `messages_per_s`, `payload_bytes`                                                                                                      |
| `crash-isolation` | 100 agents answer pings. Agent 0 throws inside an async callback.                                             | `agents_answering`, `pings`, `failed_requests`, `recovery_ms`                                                                          |
| `runaway-loop`    | 100 agents answer pings. Agent 0 enters a loop that never ends.                                               | `pings`, `failed_requests`, `p50_ms`, `p99_ms`, `max_ms`, `stopped_ms`, `recovered_ms`                                                 |
| `memory-leak`     | 100 agents answer pings. Agent 0 leaks 1 MiB each millisecond past a limit of 64 MiB.                         | `pings`, `failed_requests`, `agents_lost`, `p50_ms`, `p99_ms`, `max_ms`, `killed_ms`, `recovery_ms`, `leaker_restarts`, `process_lost` |
| `stuck-call`      | 100 agents make 1,000 tool calls with a timeout of 20 ms. The tool never returns.                             | `timed_out`, `calls_ms`, `zombie_ticks`, `zombies`, `leftover_kib`                                                                     |

Every suite also has `wall_ms` and `peak_rss_mib`, which the harness measures from outside the program.

## Recovery suites

`crash-recovery` and the four suites after `payload` measure recovery: a fault in one agent, and what happens to that agent and to the others. The other suites measure speed. The Node program has the agents, the fault, and the measurements of the Bouy program, apart from the differences that each item names.

- `crash-isolation`: the Bouy agent throws in a callback of `Promise.all`, so its turn fails, and the keeper restarts it. The Node agent throws in a `setTimeout` callback, outside the promise of its call. `process.on("uncaughtException")` keeps the process alive, but the call never settles, so the mailbox of the agent stops. Each Node call has a timeout of 100 ms, and a call that times out makes a supervisor replace the agent. `agents_answering` counts the agents that answered the first round of pings after the fault, and `recovery_ms` is the time from the fault until agent 0 answers again.
- `runaway-loop`: the BEAM scheduler preempts the Bouy loop, so the other agents keep their turns. A supervisor pings agent 0 with `withTimeout(100, ...)`, calls `stop()`, and spawns a fresh agent. The Node program runs the agents on 4 worker threads of 25 agents. The loop stops its worker and the 24 other agents of that worker, until a call timeout of 100 ms makes the supervisor `terminate()` the worker and start a new one. The ping metrics cover the 99 other agents, and a failed ping counts with its time until it failed. `stopped_ms` is the time until the loop stopped, and `recovered_ms` the time until a fresh agent 0 answered.
- `memory-leak`: the Bouy agent has `maxMemory: "64M"`, so the VM kills it past 64 MiB, and the keeper restarts it. Each Node worker has a 64 MiB heap limit in `resourceLimits`: the limit ends the worker of agent 0, and the 24 other agents of that worker fail their calls until the pool starts it again. Bun ignores `resourceLimits`, so the heap of the whole process grows. When the RSS passes 512 MiB, the program stops, as a container memory limit would stop it, and reports `process_lost: 1` with every agent lost. `agents_lost` counts the other agents that failed a ping. `killed_ms` is the time until the limit stopped the leak, and `recovery_ms` the time from then until agent 0 answered.
- `stuck-call`: the tool holds a buffer of 64 KiB and reports to a ledger every 50 ms. The Bouy agent runs the tool under `withTimeout(20, ...)`, which kills the process of the tool. The Node agent races the tool against `AbortSignal.timeout(20)` and passes the signal to it, but the tool ignores the signal, as many third-party clients do. `zombies` counts the abandoned tools that still reported in the 500 ms after the last call, `zombie_ticks` counts their reports, and `leftover_kib` is the memory that their buffers hold.

## Read the results

- A table cell is the median of the runs, with the minimum and the maximum in parentheses. A cell without a range rounds to the same value in every run. `—` means that the program does not report the metric.
- `Bouy/Bun` is the Bouy median divided by the Bun median. For a time, a latency, a memory size, or a count of failures, a ratio below 1 favors Bouy. For a rate or a count of answers, such as `casts_per_s` or `pings`, a ratio above 1 favors Bouy. `—` means that a median is missing or the Bun median is 0.
- Both programs of `call-latency`, `fairness`, and `crash-recovery` time each operation with `performance.now()`. The Bouy clock counts whole microseconds, so a Bouy sample is a multiple of 0.001 ms, and the Bouy `call-latency` program keeps its samples in a histogram of whole microseconds.
- `rss_per_actor_bytes` is the peak RSS of each `spawn` run, less the median peak RSS of `startup` on the same runtime, divided by the actor count. It exists only when the same session ran `startup`. It includes everything that an actor costs: for Bouy, the process, its row in the actor table, and its mailbox counter.
- The Bouy mailbox holds 1024 messages by default and applies backpressure: a cast to a full mailbox waits. The Node queue is unbounded. Compare `peak_rss_mib` as well as the rate in `cast-throughput` and `payload`.
- Bouy copies a message into the heap of the receiving actor. Node passes a reference. `payload` shows the cost of that copy.
- In `fairness`, one Node event loop runs every actor, so the first CPU-bound loop blocks every ping until the 2 s end. `pings` counts the pings that the window allowed.
- In the recovery suites, the Node and Bun times of a recovery depend on the call timeout of 100 ms, which the program chooses. A longer timeout makes them slower. The Bouy recoveries need no timeout, except the `withTimeout` that detects the loop in `runaway-loop`.
- A shared or loaded machine changes the numbers. Check the load averages in the results file before you compare two files.
