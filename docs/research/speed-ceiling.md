# Speed ceiling: how fast Bouy can get against Bun

Requirement 11 of [goal.md](../goal.md) says that Bouy must be faster than Bun, through type-directed compilation, native built-ins, a native tier that yields to the BEAM scheduler, and all cores. This note measures how fast each compilation strategy runs eight single-thread kernels, and how fast N copies run on N cores. It compares four tiers with Node and Bun:

1. today's engine;
2. the best typed Erlang that Bouy could emit;
3. native built-ins in Rust;
4. a native tier in Rust that runs in time slices inside the BEAM scheduler.

Every number below comes from [`bench/speed/results/2026-10-17-apple-m5-pro.jsonl`](../../bench/speed/results/2026-10-17-apple-m5-pro.jsonl). [`bench/speed/run.sh`](../../bench/speed/run.sh) wrote it on 2026-10-17: the single-thread rounds between 10:59 and 11:06 EDT, and the preemption and multicore rounds between 11:22 and 11:28 EDT. Each line of the file holds the 1-minute load average before the run. Other agents loaded the machine during the runs, and each section states the range of the load.

## Answer

- **Typed Erlang cannot beat Bun on CPU-bound code.** The best typed Erlang is 1.1 times as slow as Bun on string building and 4 to 13 times as slow on the other seven kernels. It is 2.7 to 45 times as fast as today's engine.
- **The native tier beats Bun on all three kernels where this spike built it.** Rust in a time-sliced NIF is 1.7 times as fast as Bun on Richards, 1.5 times on DeltaBlue, and 2.0 times on NBody.
- **The native tier still yields.** On a VM with one scheduler, a process that pinged during a native kernel of 1.8 to 3.2 seconds got its pong after a median of 0.46 to 0.49 ms. During the control kernel, which does not yield, the pinger waited for the whole kernel: 0.9 to 3.3 s.
- **Native built-ins close the library gaps.** The Rust regular expression built-in runs at Bun's speed (1.01). The Rust JSON built-in is 1.9 times as slow as Bun, against 8.9 times for OTP's `json` module.
- **On 18 cores, the native tier gives 2.4 to 2.8 times the throughput of Bun with 18 worker threads.** Typed Erlang gives 0.07 to 0.13 times Bun's throughput, because each copy runs at its single-thread speed.

So the strategy that gets Bouy past Bun is native code for hot typed functions and for the built-ins, in time slices, on every core. Typed Erlang is the fallback for typed code, and the engine runs everything else.

## Setup

| Item   | Value                                                                                                          |
| ------ | -------------------------------------------------------------------------------------------------------------- |
| Host   | Apple M5 Pro (`Mac17,8`), 18 cores (6 super, 12 performance), 64 GiB, macOS 26.7 (25G229), Darwin 25.6.0       |
| OTP    | Erlang/OTP 29.1.1, ERTS 17.1, BeamAsm JIT, Homebrew build                                                      |
| Bun    | 1.3.14                                                                                                         |
| Node   | 25.9.0 (V8 14.1.146.11-node.25), the release of `.node-version`                                                |
| Rust   | 1.98.0, from `rust-toolchain.toml`. The NIF crate builds with `opt-level = 3`, LTO, and one codegen unit.      |
| Engine | Branch `engine` at `38d7857`, built with `cargo build --release -p bouy-cli`, run with `--semantics reference` |

## How to reproduce

```sh
export PATH="$HOME/.cargo/bin:$PATH"
git worktree add --detach /tmp/engine engine && (cd /tmp/engine && cargo build --release -p bouy-cli)
export SPEED_JS="bun=$(command -v bun) node=/opt/homebrew/bin/node"
export BOUY_ENGINE=/tmp/engine/target/release/bouy
out=bench/speed/results/$(date +%F)-apple-m5-pro.jsonl
bench/speed/run.sh single "$out"
bench/speed/run.sh preempt "$out"
bench/speed/run.sh multicore "$out"
```

`run.sh` compiles the Erlang modules and the NIF crate into `$TMPDIR/bouy-speed-build`. It gives every VM `+hmax` of 4 GiB and runs one VM at a time.

## Method

### Kernels

Each kernel is one TypeScript file in [`bench/speed/kernels`](../../bench/speed/kernels). Each checks its own result, and every tier printed the same check value.

| Kernel    | Work of one unit                                                                                                          | Unit       |
| --------- | ------------------------------------------------------------------------------------------------------------------------- | ---------- |
| richards  | One run of Octane's Richards: an OS kernel simulation of 6 tasks and 8 packets, classes and method calls                  | run        |
| deltablue | One run of Octane's DeltaBlue: `chainTest(100)` and `projectionTest(100)` of the incremental constraint solver            | run        |
| nbody     | One step of the Benchmarks Game NBody: 5 bodies, float math                                                               | step       |
| json      | `JSON.parse` of a 1,006,461-byte document of 2,900 user records, then `JSON.stringify` of the result                      | round trip |
| strings   | Build a CSV text of 100,000 rows with `+=`, then split, `parseInt`, `indexOf`, `slice`, `toUpperCase`, and `join`         | pass       |
| regex     | Four regular expressions over 10,000 log lines: a global match, `matchAll` with groups, a test per line, a global replace | pass       |
| mapset    | 200,000 Map updates on 5,000 string keys, 200,000 Set operations with deletes, 200,000 updates of objects in a Map        | pass       |
| closures  | `filter`, `map`, `reduce`, `some`, a sort with a comparator, a group-by reduce, and curried adders over 100,000 records   | pass       |

### Tiers

| Tier            | What runs                                                                                                                                                                                                                                                                                                                                                                                                         |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Current engine  | The kernel compiled by the engine branch. An object is a record in the process dictionary with a map from property names to values. A property read is `bouy_ref:get(Object, <<"name">>)`: a dictionary read, a map lookup, and a prototype walk on a miss. A method call looks up the name and calls a fun with an argument list. Each operator calls a runtime function that dispatches on the JavaScript type. |
| Typed Erlang    | Hand-written Erlang in [`bench/speed/erlang`](../../bench/speed/erlang) that stands for the best code that Bouy could emit from the types and the whole program. The header of each module lists the facts that it assumes.                                                                                                                                                                                       |
| Native built-in | Rust NIFs for JSON and regular expressions in [`bench/speed/native`](../../bench/speed/native). They run on a dirty CPU scheduler, except the test of one line, which is short.                                                                                                                                                                                                                                   |
| Native tier     | Hand-written Rust in the same crate that stands for what a Cranelift backend would emit from typed code. A NIF runs a chunk of work, reports its time with `enif_consume_timeslice`, and yields with `enif_schedule_nif` after about 0.2 ms of work.                                                                                                                                                              |

The typed Erlang modules apply these techniques:

| Module           | Techniques                                                                                                                                                                                                     |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `richards_heap`  | Each object is a tuple of its known shape in the process dictionary. Slot indexes are known at compile time. Monomorphic calls are direct, and `task.run` dispatches on the class tag.                         |
| `richards_local` | Escape analysis: no object outlives a run, so there is no heap. The scheduler's fields become a record that every call threads through, and the other objects become tuples indexed by reference.              |
| `deltablue_heap` | The object graph is cyclic and mutable, so it stays in the process dictionary as tuples of known shape. Strength becomes an integer, plans and todo lists become a list and a `queue`, and two dead stores go. |
| `nbody_typed`    | All fields are floats, and the bodies never escape, so they become a list of immutable tuples with float guards.                                                                                               |
| `nbody_flat`     | Scalar replacement: the 5 bodies become 30 float variables, the masses become constants, and both loops are unrolled into one function body.                                                                   |
| `json_typed`     | OTP's `json` module. An object decodes to a list of pairs, so the keys keep their order.                                                                                                                       |
| `strings_typed`  | One-byte strings as binaries. `+=` is a binary append, which BEAM does in place. `binary:split`, `binary:match`, and `binary_to_integer`.                                                                      |
| `regex_typed`    | OTP's `re` with the four patterns compiled once.                                                                                                                                                               |
| `mapset_typed`   | Erlang maps. Insertion order is kept for the one Map whose order the program reads, and dropped where nothing can observe it.                                                                                  |
| `closures_typed` | Lists, comprehensions, and `lists:foldl` with the same order of float additions. The group-by accumulator is a map from index to sum.                                                                          |

### Protocol

- Each process runs 3 untimed iterations and then 5 timed ones, and prints the median. One iteration is a fixed number of units: 100 runs of Richards and DeltaBlue, 250,000 NBody steps, 4 JSON round trips, 3 passes of closures, and 1 pass of the rest.
- A round runs every tier of a kernel in turn, each in a fresh process, and then moves to the next kernel. The single-thread mode runs 5 rounds.
- A table cell "Median" is the median over the rounds of each process's median. "Best" is the fastest timed iteration of all rounds. The ratio to Bun uses the medians.
- The engine has no `process.argv` or `performance.now()` yet. `run.sh` gives it a copy of each kernel with 1 warm-up, 3 timed iterations, and fewer units: 2 runs of Richards, 1 run of DeltaBlue, 20,000 NBody steps, and 1 of the rest. Its clock is `Date.now()`, with millisecond resolution. The tables scale its times to the same unit.

## Results per kernel

### Richards

Load average 29 to 45. Time in µs per run.

| Tier                  | Program                             |   Median |     Best | Median ÷ Bun |
| --------------------- | ----------------------------------- | -------: | -------: | -----------: |
| Current engine        | `kernels/richards.ts` on the engine | 12,500.0 | 10,000.0 |       247.09 |
| Typed Erlang, heap    | `richards_heap.erl`                 |  1,583.8 |  1,246.1 |        31.31 |
| Typed Erlang, no heap | `richards_local.erl`                |    675.8 |    567.5 |        13.36 |
| Native tier           | `speed_native:richards/1`           |     30.3 |     27.6 |         0.60 |
| Node 25.9.0           | `kernels/richards.ts`               |     67.3 |     45.3 |         1.33 |
| Bun 1.3.14            | `kernels/richards.ts`               |     50.6 |     44.5 |         1.00 |

The native tier gets past Bun: it is 1.7 times as fast. Richards writes a field in almost every operation, and each write in Erlang rebuilds tuples, so even the version without a heap stays 13 times as slow as Bun.

### DeltaBlue

Load average 29 to 41. Time in µs per run.

| Tier               | Program                              |   Median |     Best | Median ÷ Bun |
| ------------------ | ------------------------------------ | -------: | -------: | -----------: |
| Current engine     | `kernels/deltablue.ts` on the engine | 18,000.0 | 16,000.0 |       167.37 |
| Typed Erlang, heap | `deltablue_heap.erl`                 |    849.0 |    734.1 |         7.89 |
| Native tier        | `speed_native:deltablue/1`           |     69.4 |     64.1 |         0.64 |
| Node 25.9.0        | `kernels/deltablue.ts`               |     89.6 |     75.6 |         0.83 |
| Bun 1.3.14         | `kernels/deltablue.ts`               |    107.5 |     80.8 |         1.00 |

The native tier gets past Bun: it is 1.5 times as fast. The margin is the smallest of the three native kernels: DeltaBlue allocates variables, constraints, and name strings in every run, and the Rust allocates them too.

### NBody

Load average 29 to 42. Time in ns per step.

| Tier                  | Program                          | Median |   Best | Median ÷ Bun |
| --------------------- | -------------------------------- | -----: | -----: | -----------: |
| Current engine        | `kernels/nbody.ts` on the engine | 33,250 | 24,400 |       416.90 |
| Typed Erlang, tuples  | `nbody_typed.erl`                |  1,172 |    939 |        14.70 |
| Typed Erlang, scalars | `nbody_flat.erl`                 |    740 |    499 |         9.28 |
| Native tier           | `speed_native:nbody/1`           |     40 |     28 |         0.50 |
| Node 25.9.0           | `kernels/nbody.ts`               |    428 |    347 |         5.36 |
| Bun 1.3.14            | `kernels/nbody.ts`               |     80 |     62 |         1.00 |

The native tier gets past Bun: it is 2.0 times as fast. This is the kernel where BEAM itself is the limit: even with 30 scalar floats in one function body, the boxing of floats leaves typed Erlang 9.3 times as slow as Bun. This note does not explain why Node is 5.4 times as slow as Bun here.

### JSON

Load average 29 to 45. Time in ms per round trip of the 1 MB document.

| Tier                     | Program                                          | Median |   Best | Median ÷ Bun |
| ------------------------ | ------------------------------------------------ | -----: | -----: | -----------: |
| Current engine           | `kernels/json.ts` on the engine                  | 268.00 | 116.00 |        74.60 |
| Typed Erlang, OTP `json` | `json_typed.erl`                                 |  32.12 |  17.83 |         8.94 |
| Native built-in          | `speed_native` `json_parse` and `json_stringify` |   6.67 |   4.62 |         1.86 |
| Node 25.9.0              | `kernels/json.ts`                                |   5.16 |   3.62 |         1.44 |
| Bun 1.3.14               | `kernels/json.ts`                                |   3.59 |   3.35 |         1.00 |

No tier gets past Bun yet. The Rust built-in is 4.8 times as fast as OTP's `json`, and still 1.9 times as slow as Bun. It builds one Erlang term for each value of the document through the NIF API, and the process collects those terms afterwards.

### Strings

Load average 28 to 48. Time in ms per pass.

| Tier                   | Program                            | Median |  Best | Median ÷ Bun |
| ---------------------- | ---------------------------------- | -----: | ----: | -----------: |
| Current engine         | `kernels/strings.ts` on the engine |  438.0 | 360.0 |         6.36 |
| Typed Erlang, binaries | `strings_typed.erl`                |   75.8 |  68.7 |         1.10 |
| Node 25.9.0            | `kernels/strings.ts`               |   42.9 |  31.1 |         0.62 |
| Bun 1.3.14             | `kernels/strings.ts`               |   68.9 |  49.2 |         1.00 |

Typed Erlang comes close to Bun: it is 1.1 times as slow. BEAM's binaries and its in-place append fit this kernel. Node is 1.6 times as fast as Bun, so Bun is not the fastest JavaScript runtime on this kernel.

### Regex

Load average 26 to 44. Time in ms per pass.

| Tier                   | Program                          | Median |  Best | Median ÷ Bun |
| ---------------------- | -------------------------------- | -----: | ----: | -----------: |
| Current engine         | `kernels/regex.ts` on the engine |  390.0 | 301.0 |        32.99 |
| Typed Erlang, OTP `re` | `regex_typed.erl`                |  118.8 |  86.4 |        10.05 |
| Native built-in        | `speed_native` `regex_*`         |   11.9 |  10.3 |         1.01 |
| Node 25.9.0            | `kernels/regex.ts`               |   16.1 |  10.0 |         1.36 |
| Bun 1.3.14             | `kernels/regex.ts`               |   11.8 |   8.8 |         1.00 |

The Rust built-in runs at Bun's speed, 10 times as fast as OTP's `re`. The `regex` crate runs finite automata and has no backreferences or lookaround, so a full built-in needs a backtracking engine for those patterns.

### Map and Set

Load average 25 to 41. Time in ms per pass.

| Tier               | Program                           | Median |  Best | Median ÷ Bun |
| ------------------ | --------------------------------- | -----: | ----: | -----------: |
| Current engine     | `kernels/mapset.ts` on the engine |  474.0 | 334.0 |        16.07 |
| Typed Erlang, maps | `mapset_typed.erl`                |  175.9 | 123.4 |         5.96 |
| Node 25.9.0        | `kernels/mapset.ts`               |   35.2 |  21.2 |         1.19 |
| Bun 1.3.14         | `kernels/mapset.ts`               |   29.5 |  18.1 |         1.00 |

Typed Erlang is 6 times as slow as Bun. An Erlang map is persistent, so each insert allocates new nodes. Bun updates a hash table in place. This spike did not build a native Map.

### Closures and array methods

Load average 25 to 47. Time in ms per pass.

| Tier                | Program                             | Median |  Best | Median ÷ Bun |
| ------------------- | ----------------------------------- | -----: | ----: | -----------: |
| Current engine      | `kernels/closures.ts` on the engine |  406.0 | 302.0 |        62.89 |
| Typed Erlang, lists | `closures_typed.erl`                |   26.9 |  17.3 |         4.17 |
| Node 25.9.0         | `kernels/closures.ts`               |   10.4 |   7.5 |         1.62 |
| Bun 1.3.14          | `kernels/closures.ts`               |    6.5 |   4.6 |         1.00 |

Typed Erlang is 4.2 times as slow as Bun. The records hold boxed floats, and every `map` and `filter` builds a new list. This spike did not build a native version.

## Multicore throughput

Each runtime ran 18 copies of one kernel at once, one per core: 18 BEAM processes in one VM, or 18 worker threads under Bun and Node ([`bench/speed/workers.ts`](../../bench/speed/workers.ts), [`bench/speed/erlang/multicore.erl`](../../bench/speed/erlang/multicore.erl)). Each copy ran for a few seconds without a warm-up, and the throughput is the units of all copies divided by the wall time from the first start to the last result. The table holds the median of 3 rounds. Load average 17.7 to 53.7.

| Kernel   | Tier                           | Units per second | ÷ Bun |
| -------- | ------------------------------ | ---------------: | ----: |
| Richards | Typed Erlang, `richards_local` |      13,897 runs |  0.13 |
| Richards | Native tier                    |     292,559 runs |  2.82 |
| Richards | Node 25.9.0, worker threads    |     123,511 runs |  1.19 |
| Richards | Bun 1.3.14, worker threads     |     103,617 runs |  1.00 |
| NBody    | Typed Erlang, `nbody_flat`     |     7.43 M steps |  0.07 |
| NBody    | Native tier                    |   273.36 M steps |  2.42 |
| NBody    | Node 25.9.0, worker threads    |    16.77 M steps |  0.15 |
| NBody    | Bun 1.3.14, worker threads     |   113.14 M steps |  1.00 |

BEAM spreads the processes over the cores, but it does not make each copy faster. Bun's worker threads also use every core. So on independent CPU-bound copies, each tier stays on the same side of Bun as in the single-thread tables, and only the native tier is ahead.

## Preemption proof

[`bench/speed/erlang/preempt.erl`](../../bench/speed/erlang/preempt.erl) runs on a VM with one scheduler (`+S 1`). One process runs a kernel for about 1 to 3 seconds. Meanwhile a pinger sends a ping to an echo process, waits for the pong, sleeps 1 ms, and repeats. The harness loads the NIF library before the pinger starts, so the load does not count as a stall. The table gives the range over 3 rounds. Load average 14.8 to 16.9.

| Kernel                              | Kernel time (s) | Pings in the run | Round trip p50 (ms) | Round trip p99 (ms) | Round trip max (ms) | Longest gap between pings (ms) |
| ----------------------------------- | --------------: | ---------------: | ------------------: | ------------------: | ------------------: | -----------------------------: |
| Native NBody, sliced (60M steps)    |      1.8 to 2.1 |      888 to 1059 |        0.46 to 0.49 |        0.60 to 1.26 |        0.68 to 4.11 |                     3.0 to 9.5 |
| Native Richards, sliced (100k runs) |      2.8 to 3.2 |     1322 to 1586 |        0.47 to 0.48 |        0.57 to 1.21 |        0.90 to 9.32 |                    3.2 to 32.4 |
| Typed Erlang NBody (4M steps)       |      2.0 to 2.3 |     1021 to 1178 |        0.30 to 0.35 |        0.48 to 1.21 |        0.89 to 4.72 |                     3.0 to 6.9 |
| Native NBody, blocking (control)    |      0.9 to 3.3 |               11 |                   — |                   — |                   — |                   891 to 3,285 |

The control runs the same NBody in one NIF call. The pinger cannot run at all while it runs, so its longest gap equals the kernel time, and its 11 pings fall before or after the kernel. The other runs count the pings of the 20 ms before the kernel too. During a sliced NIF, the pinger completes a ping about every 2 ms, as it does during typed Erlang. Over the 3 rounds, the median round trip is 0.47 to 0.48 ms with a native kernel and 0.31 ms with typed Erlang. The difference of about 0.16 ms matches the NIF slice of 0.2 ms, which is longer than the slice of an Erlang process. This note did not test a shorter slice. One native Richards round had a gap of 32.4 ms, against at most 6.9 ms for typed Erlang. The cause is not known.

## What each technique bought

Each factor is the quotient of two medians of the tables above.

| Technique                                                                            | Kernel and rows                                                 |      Factor |
| ------------------------------------------------------------------------------------ | --------------------------------------------------------------- | ----------: |
| Shapes as tuples, slot indexes, direct calls, native integers (engine to typed heap) | Richards                                                        |         7.9 |
|                                                                                      | DeltaBlue                                                       |        21.2 |
| The same with floats, and escape analysis to tuples (engine to `nbody_typed`)        | NBody                                                           |        28.4 |
| Escape analysis: no heap (`richards_heap` to `richards_local`)                       | Richards                                                        |         2.3 |
| Scalar replacement and unrolling (`nbody_typed` to `nbody_flat`)                     | NBody                                                           |         1.6 |
| OTP built-ins in C and Erlang (engine to typed Erlang)                               | JSON, strings, regex, Map and Set, closures                     | 2.7 to 15.1 |
| Rust built-ins (typed Erlang to native built-in)                                     | JSON                                                            |         4.8 |
|                                                                                      | Regex                                                           |        10.0 |
| Native tier (best typed Erlang to native)                                            | Richards                                                        |        22.3 |
|                                                                                      | DeltaBlue                                                       |        12.2 |
|                                                                                      | NBody                                                           |        18.4 |
| 18 cores (single-thread native to multicore native, at the multicore load)           | Richards: 33,000 runs/s for one copy (30.3 µs a run) to 292,559 |         8.9 |

The last row compares a single-thread median with a multicore median of another load range, so it shows the order of the gain, not the scaling of an idle machine.

## Where BEAM is the limit

Four properties of BEAM keep typed Erlang behind Bun on these kernels. A better compiler to Erlang does not remove them.

1. **Floats are boxed.** A float on the heap takes 2 words. The JIT keeps floats in registers inside one function body, but every float that goes into a tuple or a list, or lives across a call, is boxed. `math:sqrt/1` is an external call, so each of the 10 square roots of an NBody step boxes the floats that live across it. NBody shows the cost: 9.3 times Bun after scalar replacement.
2. **Terms are immutable.** A field write builds a new tuple, and in the heap variants it also stores the tuple back into the process dictionary. JavaScriptCore and V8 write one word in place. Richards writes fields almost everywhere, so it has the largest gap of the object kernels: 13 times Bun without a heap.
3. **Persistent data structures allocate on every update.** An Erlang map shares structure between versions, so an insert allocates. Map and Set stay 6 times as slow as Bun.
4. **The OTP built-ins are slower than Bun's.** OTP's `json` module is written in Erlang, and `re` was 10 times as slow as Bun on the regex kernel.

The design that gets around all four is the native tier. Code that the compiler can type runs as machine code on native data, in time slices, inside the actor's process. Data becomes Erlang terms only where it leaves the hot code. The sliced NIFs show that this keeps the scheduler fair.

## Targets: what gets each kernel past Bun

The target is to beat Bun on every kernel. "Missing" names the work that no measurement here covers yet. The costs are estimates of this note, not measurements.

| Kernel    | Best measured                   | Technique past Bun                                     | Missing, and estimated cost                                                                                                                                                                                                        |
| --------- | ------------------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Richards  | Native tier, 0.60 of Bun's time | Native tier                                            | A Cranelift backend that emits this code from typed TypeScript, with arena objects. Part of the native tier, below.                                                                                                                |
| DeltaBlue | Native tier, 0.64               | Native tier                                            | The same backend, with class-tag dispatch for the four constraint classes and allocation in a native heap per actor.                                                                                                               |
| NBody     | Native tier, 0.50               | Native tier                                            | The numeric subset of the backend. It needs no heap, so it can come first.                                                                                                                                                         |
| JSON      | Native built-in, 1.86           | Native built-in, then the native tier                  | Parse straight into the actor's object representation instead of Erlang terms, scan with SIMD, and write stringify output without one NIF call per term. About 3 to 5 weeks with full `JSON.parse` and `JSON.stringify` semantics. |
| Strings   | Typed Erlang, 1.10              | Native built-ins for `split`, `indexOf`, and case maps | A rope or builder for `+=`, and Rust for the scans. About 2 to 3 weeks.                                                                                                                                                            |
| Regex     | Native built-in, 1.01           | Native built-in                                        | A backtracking fallback for backreferences and lookaround, `lastIndex` and the flags, and a batch path for a test on many short strings, which pays one NIF call each today. About 3 to 4 weeks.                                   |
| Map, Set  | Typed Erlang, 5.96              | A native mutable hash table, or the native tier        | A Map and Set owned by the actor in native memory, for primitive keys first. The open question is how values that are Erlang terms live there. About 3 to 5 weeks, with the most design risk of this list.                         |
| Closures  | Typed Erlang, 4.17              | Native tier                                            | Arrays of records as native structs, and closures that the backend inlines into `map`, `filter`, and `reduce`. Part of the native tier.                                                                                            |

Across cores, the same techniques win: the native tier had 2.4 to 2.8 times Bun's throughput on 18 cores. BEAM adds the fairness of its preemptive scheduler, which the preemption proof shows.

## Realistic targets per tier

| Tier                                 | Where it runs                               | Measured against Bun                                                                   | Target                                                                                                             |
| ------------------------------------ | ------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Engine with shapes and inline caches | Untyped code and npm packages               | Today 6.4 to 417 times as slow. The typed heap rows bound this tier: 7.9 and 31 times. | Phase 5 of ADR 0003: each `bench/reference` program within 10 times Node. It cannot beat Bun.                      |
| Typed Erlang                         | Typed code that the native tier cannot take | 1.1 to 13 times as slow, with the best variant of each kernel                          | Within 2 times Bun on string and library code with native built-ins. It cannot beat Bun on object or float code.   |
| Native built-ins                     | Every tier calls them                       | 1.01 (regex) and 1.86 (JSON)                                                           | Faster than Bun on JSON, regex, strings, and Map and Set.                                                          |
| Native tier                          | Hot typed functions, in time slices         | 0.50 to 0.64 of Bun's time                                                             | At most 0.7 of Bun's time on typed CPU-bound code, with a p99 ping on one scheduler within 1 ms of typed Erlang's. |
| All cores                            | Every tier, one actor per core or more      | Native 2.4 to 2.8 times Bun's throughput                                               | Above Bun's worker-thread throughput on every kernel where the native tier or a native built-in runs.              |

## Build order for the speed phase of ADR 0003

Phase 5 of [ADR 0003](../adr/0003-run-typescript-on-beam.md) plans shapes with slot tuples and inline caches, which is step 3 below. These measurements support that work and add the other steps. The estimates are those of this note, except the ADR's own.

1. **Move this suite into `crates/bouy-bench`.** Add the kernels as single-thread suites with Bun and Node baselines and thresholds, so every later step shows its gain. AGENTS.md lets only `crates/bouy-bench`, `crates/bouy-fuzz`, and `scripts/freeze-expectations.sh` start node. `run.sh` starts the baselines that `SPEED_JS` names, node among them, so the move also ends that exception. About 1 week.
2. **Rust built-ins for JSON and RegExp.** They help untyped npm code at once, they need no compiler work, and they cut the largest library gaps from 8.9 and 10 times Bun to 1.9 and 1.0. About 6 to 9 weeks for both, with full semantics.
3. **Shapes with slot tuples, direct calls, and inline caches** (Phase 5 as planned). The typed heap rows bound the gain: 7.9 times on Richards and 21 times on DeltaBlue over today's engine. 1 to 3 months (E3 of the ADR).
4. **A typed IR with escape analysis and scalar replacement.** It gives typed code the typed Erlang rows: a further 2.3 times on Richards and 1.6 times on NBody. The native tier needs the same IR. About 2 months.
5. **The native tier.** A Cranelift backend from the typed IR to NIFs that run in slices of about 0.2 ms, numeric code first because it needs no heap, then object graphs in a native heap per actor. It is the only tier that beat Bun on CPU-bound code here: 12 to 22 times faster than typed Erlang. About 4 to 6 months.
6. **Native Map, Set, and record arrays.** They close the last gaps, 6 and 4.2 times Bun, after the native heap of step 5 exists. About 1 to 2 months.

Steps 2 and 3 can run in parallel, because they touch different code.

## Limits of this spike

- The machine was shared. The load average was 14.8 to 53.7 on 18 cores, so the absolute times are higher and noisier than on an idle machine. The tiers of a kernel ran in turn in each round, so the load reached all of them.
- Hand-written Rust stands for Cranelift output. LLVM, which compiles the Rust, usually optimizes more than Cranelift does, so a real backend may land between these native rows and Bun. No benchmark here measures that difference.
- The native kernels keep their state in Rust, so they pay almost no conversion. NBody passes 280 bytes between slices, and Richards and DeltaBlue build their objects inside the NIF. Code that converts large object graphs between Erlang terms and native memory pays more.
- The typed Erlang is hand-written. A compiler must prove each fact that a module header lists before it can emit that code.
- The JSON built-in returns Erlang terms in the representation of `json_typed`, not objects of the engine's heap.
- The regex built-in covers the patterns of this kernel only.
- The engine numbers use 1 warm-up, 3 timed iterations, fewer units, and a clock with millisecond resolution.
- The ping of the preemption proof measures one scheduler. A kernel on each of 18 schedulers was not measured for latency.
