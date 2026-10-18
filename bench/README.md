# Benchmarks: Buoy, Node, and Bun

Each suite is a set of programs in `programs/<suite>/`. `buoy.ts` is a Buoy program that uses the `buoy` actor API. `node.ts` is the closest plain Node program, with actors from `programs/node-actor.ts`: objects with an unbounded mailbox queue that run one message at a time and answer calls with promises. The actors of `node.ts` share one thread and pass each message by reference. Six suites also hold `isolated.ts`, a plain Node program whose actors run on worker threads and get a copy of each message, as Buoy actors do. The harness runs `node.ts` and `isolated.ts` on Node and with `bun run` on Bun. A suite that needs a different Bun program holds a `bun.ts`, and its header says why. No suite has one yet. Node and Bun are the baselines, and Bun is the bar of [goal.md](../docs/goal.md) requirement 11. The product never runs on Node or Bun.

The `node.ts` programs of the speed suites use no `worker_threads`. The recovery suites protect the Node program as a competent Node developer would, and the comment at the top of each `node.ts` names the protections. Two of them run the agents on worker threads, with `programs/node-shards.ts`.

Each `isolated.ts` runs its actors on worker threads with `programs/node-shards.ts`. `postMessage` copies each call, cast, and reply with the structured clone. The comment at the top of each `isolated.ts` names its isolation:

- `call-latency`, `cast-throughput`, and `payload`: one worker thread hosts the one actor.
- `crash-recovery`: one worker thread hosts the actor. The crash ends the worker, and the pool starts a fresh worker with a fresh state. The start of a worker takes most of each cycle, so the program crashes 100 times, not 1,000 times. The metrics are per crash.
- `spawn`: 100,000 worker threads do not fit in memory, so the program starts 32, one for each actor. An actor counts as started when it has answered one call.
- `fan-out`: a pool of worker threads, one for each core up to 8, hosts the 1,000 actors in shards. The actors of one shard share a thread.

`crates/buoy-bench` runs the programs and writes `results/<YYYY-MM-DD>-<host>.json`. Every number that a document quotes must come from a file in `results/`.

## Run

```sh
export PATH="$HOME/.cargo/bin:$PATH"
cargo build --release -p buoy-cli
cargo run --release -p buoy-bench -- --buoy target/release/buoy
pnpm format
```

`pnpm format` formats the new results file, so that `pnpm check` passes.

| Option               | Default                     | Meaning                                                               |
| -------------------- | --------------------------- | --------------------------------------------------------------------- |
| `[SUITES]...`        | every directory in programs | The suites to run, such as `spawn fairness`.                          |
| `--runs <N>`         | `5`                         | The measured runs of each program. One warm-up run comes first.       |
| `--buoy <PATH>`      | `buoy` on `PATH`            | The `buoy` CLI to measure. The env var `BUOY_BENCH_BUOY` sets it too. |
| `--node <PATH>`      | `node` on `PATH`            | The Node baseline. The env var `BUOY_BENCH_NODE` sets it too.         |
| `--bun <PATH>`       | `bun` on `PATH`             | The Bun baseline. The env var `BUOY_BENCH_BUN` sets it too.           |
| `--out <DIR>`        | `bench/results`             | The directory for the results file.                                   |
| `--host <NAME>`      | the CPU model as a slug     | The host part of the results file name.                               |
| `BUOY_ERL` (env var) | `erl` on `PATH`             | The `erl` that `buoy` runs and whose OTP release the file records.    |

Build the CLI from the same tree as the programs. The results file records `git describe --dirty` of the tree, not of the binary.

## Memory

Each run has a memory limit, so a fault in a program cannot exhaust the machine:

- The harness sets `BUOY_MAX_MEMORY=1G` for each Buoy VM.
- Each Node program, `isolated.ts` included, runs with `--max-old-space-size=512`, except `memory-leak`. A process-wide `--max-old-space-size` overrides the `resourceLimits` of every worker thread, so the `memory-leak` program runs without it, under the limits of its workers.
- Bun has no heap limit: it has no `--max-old-space-size`, it ignores the `resourceLimits` of a worker thread, and macOS refuses a `ulimit -v` or `ulimit -d`. So the measuring process reads the RSS of each program every 200 ms and kills a program past 1 GiB. The ceiling applies to every runtime, and a killed run fails with a line that names the ceiling.
- The harness runs one program at a time.

## Limits

`thresholds.json` holds the limits of the nightly job, which [docs/design/testing.md](../docs/design/testing.md) section 5.11 describes. For each suite and Buoy metric, a limit is the largest allowed ratio of a new median to the baseline median. A limit above 1 is the ceiling of a metric where less is better, such as `wall_ms`. A limit below 1 is the floor of a metric where more is better, such as `casts_per_s`. The limits leave room for a loaded machine. The `wall_ms` ceilings are wide, because `wall_ms` includes the start of the VM, which grows the most with the load. The limits are not results, so no document may quote them.

```sh
target/release/buoy-bench compare <baseline.json> [<previous.json>] <current.json>
```

The command prints a Markdown table with each median and its ratio to the baseline median. It exits with 1 when a metric is past its limit in the previous run and in the current run. A metric past its limit in the current run only is a warning. The files must come from one host.

## Method

1. The harness runs each program once to warm up. This compiles the Buoy module, fills the runtime cache in `~/.cache/buoy`, and fills the file cache.
2. Then it runs the programs in turns, N times each, so that a change in the load of the machine reaches all of them: `buoy.ts` on Buoy, `node.ts` on Node and on Bun, and `isolated.ts` on Node and on Bun when the suite has one.
3. Each run is a fresh process. The harness starts it under a copy of itself, which waits for that one child, so `getrusage(RUSAGE_CHILDREN)` gives the peak RSS of the program alone. That copy also measures the wall time from the start of the process to its exit.
4. A program prints one JSON line last. A run fails when the exit status is not 0 or the last line is not a JSON object. A program checks its own answers, such as the count of casts that the actor took, and exits with status 1 when one is wrong.
5. The harness records the 1, 5, and 15 minute load averages before and after each run, the host, and the versions of Buoy, OTP, Node, and Bun.

## Suites

| Suite             | Work in every program                                                                                         | Metrics                                                                                                                                |
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

`crash-recovery` and the four suites after `payload` measure recovery: a fault in one agent, and what happens to that agent and to the others. The other suites measure speed. The Node program has the agents, the fault, and the measurements of the Buoy program, apart from the differences that each item names.

- `crash-isolation`: the Buoy agent throws in a callback of `Promise.all`, so its turn fails, and the keeper restarts it. The Node agent throws in a `setTimeout` callback, outside the promise of its call. `process.on("uncaughtException")` keeps the process alive, but the call never settles, so the mailbox of the agent stops. Each Node call has a timeout of 100 ms, and a call that times out makes a supervisor replace the agent. `agents_answering` counts the agents that answered the first round of pings after the fault, and `recovery_ms` is the time from the fault until agent 0 answers again.
- `runaway-loop`: the BEAM scheduler preempts the Buoy loop, so the other agents keep their turns. Each Buoy agent has `turnTimeout: 100`: the runtime ends the turn of the loop after 100 ms, the ping that waits behind the loop fails with `ActorStopped`, and the keeper restarts agent 0 with a fresh state. The program has no supervisor code. The Node program runs the agents on 4 worker threads of 25 agents. The loop stops its worker and the 24 other agents of that worker, until a call timeout of 100 ms makes the supervisor `terminate()` the worker and start a new one. The ping metrics cover the 99 other agents, and a failed ping counts with its time until it failed. `stopped_ms` is the time until the loop stopped, and `recovered_ms` the time until a fresh agent 0 answered.
- `memory-leak`: the Buoy agent has `maxMemory: "64M"`, so the VM kills it past 64 MiB, and the keeper restarts it. Each Node worker has a 64 MiB heap limit in `resourceLimits`: the limit ends the worker of agent 0, and the 24 other agents of that worker fail their calls until the pool starts it again. Bun ignores `resourceLimits`, so the heap of the whole process grows. When the RSS passes 512 MiB, the program stops, as a container memory limit would stop it, and reports `process_lost: 1` with every agent lost. `agents_lost` counts the other agents that failed a ping. `killed_ms` is the time until the limit stopped the leak, and `recovery_ms` the time from then until agent 0 answered.
- `stuck-call`: the tool holds a buffer of 64 KiB and reports to a ledger every 50 ms. The Buoy agent runs the tool under `withTimeout(20, ...)`, which kills the process of the tool. The Node agent races the tool against `AbortSignal.timeout(20)` and passes the signal to it, but the tool ignores the signal, as many third-party clients do. `zombies` counts the abandoned tools that still reported in the 500 ms after the last call, `zombie_ticks` counts their reports, and `leftover_kib` is the memory that their buffers hold.

## Read the results

- The columns `Node` and `Bun` run `node.ts`, and the columns `Node isolated` and `Bun isolated` run `isolated.ts`.
- A table cell is the median of the runs, with the minimum and the maximum in parentheses. A cell without a range rounds to the same value in every run. `—` means that the program does not report the metric, or that the suite has no program for that column.
- `Buoy/Bun` is the Buoy median divided by the Bun median of `node.ts`, and `Buoy/Bun isolated` is the Buoy median divided by the Bun median of `isolated.ts`. For a time, a latency, a memory size, or a count of failures, a ratio below 1 favors Buoy. For a rate or a count of answers, such as `casts_per_s` or `pings`, a ratio above 1 favors Buoy. `—` means that a median is missing or the Bun median is 0.
- Every program of `call-latency`, `fairness`, and `crash-recovery` times each operation with `performance.now()`. The Buoy clock counts whole microseconds, so a Buoy sample is a multiple of 0.001 ms, and the Buoy `call-latency` program keeps its samples in a histogram of whole microseconds.
- `rss_per_actor_bytes` is the peak RSS of each `spawn` run, less the median peak RSS of `startup` on the same runtime, divided by the actor count. An `isolated.ts` program takes the `startup` baseline of its plain runtime. It exists only when the same session ran `startup`. It includes everything that an actor costs. For Buoy, that is the process, its row in the actor table, and its mailbox counter. For `isolated.ts`, it is a whole worker thread.
- The `isolated.ts` programs of `spawn` and `crash-recovery` do less work than the other programs of their suites, as their headers say. Compare their per-actor and per-crash metrics, not `wall_ms` or `peak_rss_mib`.
- The Buoy mailbox holds 1024 messages by default and applies backpressure: a cast to a full mailbox waits. The Node queue is unbounded, and so is the message queue of a worker thread. Compare `peak_rss_mib` as well as the rate in `cast-throughput` and `payload`.
- The class of the Buoy `spawn` program has a constructor that only stores its argument, so the compiler marks it pure and `spawn` does not wait for the new process (contract section 9). A constructor with effects waits for the new process and costs more per actor.
- The Buoy `fan-out` program calls one method on each actor ref, so the compiler sends the calls of a round together (`buoy_task:map_call`), one part for each scheduler, with no process for each call. A `Promise.all` over other functions runs each function in its own process.
- Buoy copies a message into the heap of the receiving actor. `node.ts` passes a reference, and `isolated.ts` copies the message with the structured clone. `payload` shows the cost of that copy.
- In `fairness`, one Node event loop runs every actor, so the first CPU-bound loop blocks every ping until the 2 s end. `pings` counts the pings that the window allowed.
- In the recovery suites, the Node and Bun times of a recovery depend on the call timeout of 100 ms, which the program chooses. A longer timeout makes them slower. The Buoy recoveries need no timeout, except the `turnTimeout` that ends the loop in `runaway-loop`.
- A shared or loaded machine changes the numbers. Check the load averages in the results file before you compare two files.
