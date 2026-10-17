# Benchmarks: Bouy and plain Node

Each suite is one program pair in `programs/<suite>/`. `bouy.ts` is a Bouy program that uses the `bouy` actor API. `node.ts` is the closest plain Node program, with actors from `programs/node-actor.ts`: objects with an unbounded mailbox queue that run one message at a time and answer calls with promises. No Node program uses `worker_threads`, and the comment at the top of each `node.ts` says so. Node is the baseline. The product never runs on Node.

`crates/bouy-bench` runs the pairs and writes `results/<YYYY-MM-DD>-<host>.json`. Every number that a document quotes must come from a file in `results/`.

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
| `--out <DIR>`        | `bench/results`             | The directory for the results file.                                   |
| `--host <NAME>`      | the CPU model as a slug     | The host part of the results file name.                               |
| `BOUY_ERL` (env var) | `erl` on `PATH`             | The `erl` that `bouy` runs and whose OTP release the file records.    |

Build the CLI from the same tree as the programs. The results file records `git describe --dirty` of the tree, not of the binary.

## Method

1. The harness runs each program once to warm up. This compiles the Bouy module, fills the runtime cache in `~/.cache/bouy`, and fills the file cache.
2. Then it runs the Bouy program and the Node program in turns, N times each, so that a change in the load of the machine reaches both.
3. Each run is a fresh process. The harness starts it under a copy of itself, which waits for that one child, so `getrusage(RUSAGE_CHILDREN)` gives the peak RSS of the program alone. That copy also measures the wall time from the start of the process to its exit.
4. A program prints one JSON line last. A run fails when the exit status is not 0 or the last line is not a JSON object. A program checks its own answers, such as the count of casts that the actor took, and exits with status 1 when one is wrong.
5. The harness records the 1, 5, and 15 minute load averages before and after each run, the host, and the versions of Bouy, OTP, and Node.

## Suites

| Suite             | Work in both programs                                                                                         | Metrics                                                       |
| ----------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `startup`         | Print one line.                                                                                               | `wall_ms`, `peak_rss_mib`                                     |
| `spawn`           | Start 100,000 actors that each hold a number, and keep their refs.                                            | `per_actor_us`, `rss_per_actor_bytes`                         |
| `call-latency`    | 100,000 sequential calls to one actor.                                                                        | `mean_us`, `max_ms`, `p50_us`, `p99_us`                       |
| `cast-throughput` | 1,000,000 casts to one actor, then one call that waits for them.                                              | `casts_per_s`                                                 |
| `fan-out`         | 10 rounds of 10,000 parallel calls over 1,000 actors with `Promise.all`.                                      | `calls_per_s`, `max_round_ms`                                 |
| `fairness`        | 8 actors run CPU-bound loops for 2 s. Meanwhile the main code pings another actor and sleeps 1 ms, in a loop. | `pings`, `p50_ms`, `p99_ms`, `max_ms` of the ping round trips |
| `crash-recovery`  | 1,000 times: an actor throws, restarts, and answers the next call.                                            | `recovery_us`, `max_recovery_ms`, `cycle_us`                  |
| `compute`         | `fib(27)` by naive recursion in one actor, 20 calls.                                                          | `fib_ms`                                                      |
| `payload`         | 100,000 casts of one object of about 1 KB of JSON, then one call that waits for them.                         | `messages_per_s`, `payload_bytes`                             |

Every suite also has `wall_ms` and `peak_rss_mib`, which the harness measures from outside the program.

## Read the results

- A table cell is the median of the runs, with the minimum and the maximum in parentheses. A cell without a range rounds to the same value in every run. `—` means that the program does not report the metric.
- Both programs of `call-latency`, `fairness`, and `crash-recovery` time each operation with `performance.now()`. The Bouy clock counts whole microseconds, so a Bouy sample is a multiple of 0.001 ms, and the Bouy `call-latency` program keeps its samples in a histogram of whole microseconds.
- `rss_per_actor_bytes` is the peak RSS of each `spawn` run, less the median peak RSS of `startup` on the same runtime, divided by the actor count. It exists only when the same session ran `startup`. It includes everything that an actor costs: for Bouy, the process, its row in the actor table, and its mailbox counter.
- The Bouy mailbox holds 1024 messages by default and applies backpressure: a cast to a full mailbox waits. The Node queue is unbounded. Compare `peak_rss_mib` as well as the rate in `cast-throughput` and `payload`.
- Bouy copies a message into the heap of the receiving actor. Node passes a reference. `payload` shows the cost of that copy.
- In `fairness`, one Node event loop runs every actor, so the first CPU-bound loop blocks every ping until the 2 s end. `pings` counts the pings that the window allowed.
- A shared or loaded machine changes the numbers. Check the load averages in the results file before you compare two files.
