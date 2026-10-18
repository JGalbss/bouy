# Rust async runtimes, Rust actor frameworks, and WebAssembly process models

> Paths under `packages/`, `e2e/`, `examples/`, and `bench/` refer to commit [`90529d8`](https://github.com/JGalbss/buoy/tree/90529d8), the last commit with the Node runtime.

Research track: rust-wasm. Date: 2026-10-16.

This note collects evidence for two options in the architecture decision:

- **Option B.** TypeScript compiles to an intermediate representation (IR). A custom Rust actor runtime runs it, with or without an embedded JS engine (V8 through rusty_v8, QuickJS through rquickjs).
- **Option D4.** Wasm components act as Lunatic-style processes. Each actor is a Wasm instance that runs JS compiled to Wasm (StarlingMonkey through ComponentizeJS, or QuickJS through Javy).

Section 8 scores both options on the nine shared criteria. The last section lists the implications for Buoy.

## Summary

- Tokio cannot preempt CPU-bound code. Each task gets a budget of 128 resource operations per poll, and a loop that never touches a Tokio resource never yields. The BEAM swaps a process out after 4,000 reductions. A BEAM-like runtime on Tokio needs a second preemption mechanism inside the JS engine or the Wasm code (Section 1.2).
- QuickJS-ng and Wasmtime both offer a hook that can suspend running JS. QuickJS-ng calls an interrupt handler about every 10,000 interpreter ticks. Wasmtime instruments Wasm code with fuel (deterministic) or epochs (time based). V8 offers termination and an interrupt callback that must not re-enter the isolate. It can stop an actor. Suspending one needs a separate stack per isolate, which I did not test (Sections 3.2, 5.1, 5.2).
- A prototype preempts native QuickJS-ng actors without Wasm. Each actor owns a runtime on a stackful coroutine, and the interrupt handler switches coroutines. Four spinning actors finished within 1 ms of each other with 84 to 93 µs slices. Run sequentially, they finished 310 to 370 ms apart (Section 5.3).
- Wasmtime preemption cost 0 to 101% extra run time with fuel and 0 to 42% with epochs in my measurements. The cost depends on code shape. Loops cost nothing measurable, and call-heavy code costs the most (Section 3.2).
- Resident memory per idle actor spans three orders of magnitude: Tokio task with mailbox 1,112 B, ractor actor 7,644 B, empty Wasm instance 23.6 KiB, QuickJS-ng runtime 174 KiB, Javy instance 234 KiB, V8 isolate 1,096 KiB, StarlingMonkey instance 1,669 to 1,688 KiB. A new BEAM process uses 327 words, which is 2,616 B on a 64-bit system (Sections 1.2, 1.4, 2, 3.3, 4.1, 5).
- npm compatibility depends on Web APIs. zod 4.6.7 needs only the language core, and it passed on every engine I tried. ai 7.0.142 failed wherever `TransformStream` was missing. It passed on LLRT and on StarlingMonkey after one regex was rewritten (Section 4.3).
- StarlingMonkey has no `Intl`, so it rejects Unicode property escapes such as `/[\p{L}\p{N}]+/u`. ai 7.0.142 uses one at module top level. The upstream issue has been open since 2024-05-09 (Section 4.1).
- Lunatic is dormant. Its last release is v0.13.2 (2023-05-03) and its last commit is a build fix from 2025-03-29. It pins Wasmtime 8 (Section 3.1).
- WASI 0.3.0 shipped on 2026-06-11 with native `async`, `stream<T>`, and `future<T>`. Wasmtime 46 and later enable it by default. JS guest toolchains still target WASI 0.2 (Section 3.4).
- Ahead-of-time TS-to-native compilers do not run today's npm graph for agents. Porffor alpha 17 ran the zod probe, and both AI SDK probes crashed with SIGSEGV. Its docs say client `fetch()` is not implemented and `Proxy` has no shim. AssemblyScript has no closures. The Static Hermes typed mode is "in progress and considered unstable" (Section 6).

## Method and environment

- Machine: Apple M5 Pro, 18 cores (6 + 12 in two performance levels), 64 GB RAM, macOS 26.6.1 (Darwin 25.6). The page size is 16 KiB (`pagesize`).
- Rust: toolchain 1.98.0 from rustup. The Homebrew Rust 1.88 is too old for Wasmtime 49, which requires Rust 1.96.
- Crates: wasmtime 49.0.3 (Cranelift 0.136.3), wasmtime-wasi 49.0.3, wasmtime-wasi-http 49.0.3, tokio 1.53.3, ractor 0.16.5, rquickjs 0.14.0 (bundles QuickJS-ng 0.16.2), corosensei 0.3.4, v8 152.2.0 (V8 15.2.124.1), boa_engine 0.22.0.
- JS toolchains: Javy 9.1.0, jco 1.39.0 with componentize-js 0.23.0, LLRT v0.9.0-beta, Porffor 0.0.0-alpha.17, Node 25.9.0, Bun 1.3.11 (bundler only).
- Javy, jco, LLRT, and Porffor are not installed on the host. They ran in Docker (OrbStack, Linux arm64). The Wasm files they produced ran on the host in Wasmtime. LLRT and Porffor programs ran inside Docker.
- Resident memory per actor is `(RSS after N live actors - RSS before) / N`, read with `ps -o rss=`. With 16 KiB pages, small allocations round up. Linux on 4 KiB pages will show different values.
- Timings are medians or ranges over 3 to 9 runs, as each table states.
- Other research tracks ran builds and benchmarks on the same machine at the same time. The one-minute load average was 27.01 at 10:38 local time (`uptime`). The ranges include this noise. Rerun Appendix A on an idle machine before relying on absolute values.
- The harness is a set of scratch projects outside the repository. Appendix A holds the complete source and the commands. AGENTS.md requires benchmarks under `bench/`. This track could only write this file, so the harness must move to `bench/` before an ADR cites these numbers.

## 1. Tokio scheduler design

### 1.1 Work stealing

- Each worker owns a fixed-size local run queue. The capacity is 256 tasks in tokio 1.53.3 ([`queue.rs`](https://github.com/tokio-rs/tokio/blob/tokio-1.53.3/tokio/src/runtime/scheduler/multi_thread/queue.rs)).
- Overflow and tasks spawned from outside the runtime go to a global injection queue. An idle worker steals half of another worker's queue. At most half of the workers search for work at the same time ([Tokio blog, 2019-10-13](https://tokio.rs/blog/2019-10-scheduler)).
- A LIFO slot holds the task woken most recently, so a message receiver often runs right after its sender (same source). Tokio 1.53.3 limits LIFO polls to 3 per tick (`MAX_LIFO_POLLS_PER_TICK` in [`worker.rs`](https://github.com/tokio-rs/tokio/blob/tokio-1.53.3/tokio/src/runtime/scheduler/multi_thread/worker.rs)).
- The interval between global-queue checks tunes itself toward 200 µs of polling ([`stats.rs`](https://github.com/tokio-rs/tokio/blob/tokio-1.53.3/tokio/src/runtime/scheduler/multi_thread/stats.rs)). The runtime polls the I/O and timer drivers every 61 ticks by default ([`builder.rs`](https://github.com/tokio-rs/tokio/blob/tokio-1.53.3/tokio/src/runtime/builder.rs)).

### 1.2 Cooperative budget and BEAM reductions

- The scheduler gives a task a budget of 128 operations each time it polls the task (`Budget::initial()` in [`task/coop/mod.rs`](https://github.com/tokio-rs/tokio/blob/tokio-1.53.3/tokio/src/task/coop/mod.rs)).
- Tokio resources such as sockets, channels, and timers consume the budget. At zero, they return `Pending`, and the task yields ([Tokio blog, 2020-04-01](https://tokio.rs/blog/2020-04-preemption)).
- The same post says the mechanism "cannot preempt tasks". Users "must still take care to avoid both CPU intensive work and blocking APIs". It reports tail latencies "reduced by almost 3x" in some cases.
- The BEAM counts reductions, roughly function calls and units of built-in work. It swaps a process out after 4,000 reductions (`CONTEXT_REDS` in [`erl_vm.h`, OTP-29.1.2](https://github.com/erlang/otp/blob/OTP-29.1.2/erts/emulator/beam/erl_vm.h)).
- A newly spawned Erlang process uses 327 words of memory, including 233 words for the heap and stack. The BEAM copies message data between process heaps, except reference-counted binaries and literals ([Erlang efficiency guide](https://www.erlang.org/doc/system/eff_guide_processes.html)).
- The two budgets count different things. The BEAM budget counts work, so a tight loop is preempted. The Tokio budget counts I/O readiness, so a JS loop that never awaits runs until it finishes.

### 1.3 Blocking work

- `spawn_blocking` runs a closure on a separate thread pool. The default limit is 512 threads ([`builder.rs`](https://github.com/tokio-rs/tokio/blob/tokio-1.53.3/tokio/src/runtime/builder.rs)).
- The docs say these tasks "cannot be aborted" after they start ([`task/blocking.rs`](https://github.com/tokio-rs/tokio/blob/tokio-1.53.3/tokio/src/task/blocking.rs)).
- `block_in_place` hands the worker's queued tasks to another worker, then blocks the current thread. It cannot be used on a current-thread runtime (same file).
- An actor that runs JS inside `spawn_blocking` cannot be killed from Tokio. The kill switch has to come from the engine: the QuickJS interrupt handler, V8 `TerminateExecution`, or a Wasmtime epoch trap.

### 1.4 Measured baseline

Program `native_actors` (Appendix A). Three runs each.

| Measurement                                                 | Result per item            | Command                                              |
| ----------------------------------------------------------- | -------------------------- | ---------------------------------------------------- |
| Spawn an idle task with an unbounded mpsc mailbox           | 127 to 138 ns, 1,112 B RSS | `native_actors tokio-idle 1000000`                   |
| Ping-pong round trip, current-thread runtime, no drivers    | 65 to 90 ns                | `BUOY_RT=nodrv native_actors tokio-pingpong 1000000` |
| Ping-pong round trip, current-thread runtime, I/O and timer | 477 to 1,798 ns            | `native_actors tokio-pingpong 1000000`               |
| Ping-pong round trip, multi-thread runtime                  | 109 to 126 ns              | `native_actors tokio-pingpong-mt 1000000`            |

Enabling the I/O driver on a current-thread runtime made the same ping-pong 5 to 28 times slower on macOS. Every comparison below states which configuration it used.

## 2. Rust actor frameworks

| Framework         | Latest version (date) | Supervision                                                                                                                            | Mailbox                                                                       | Distribution                                                       | Status                                                   |
| ----------------- | --------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------ | -------------------------------------------------------- |
| ractor            | 0.16.5 (2026-08-07)   | Linked children send `ActorStarted`, `ActorTerminated`, and `ActorFailed` events to the supervisor. Panics in handlers are caught.     | Four channels with priority: signals, stop, supervision, messages. Unbounded. | `ractor_cluster`, which "shouldn't be considered production ready" | Active. Basis of Meta's Rust Thrift overload protection. |
| ractor-supervisor | 0.2.0 (2026-08-02)    | OTP-style `OneForOne`, `OneForAll`, `RestForOne`; `Permanent`, `Transient`, `Temporary`; meltdown after `max_restarts` in `max_window` | Uses ractor                                                                   | Not applicable                                                     | Small third-party crate                                  |
| kameo             | 0.22.2 (2026-07-18)   | `OneForOne` (default), `OneForAll`, `RestForOne`; `on_panic`, `on_link_died`                                                           | Bounded or unbounded                                                          | Remote actors over libp2p                                          | Active                                                   |
| actix             | 0.13.5 (2024-06-09)   | `Supervisor` calls `restarting()` on the same actor value. Messages in flight are lost.                                                | Bounded, default capacity 16                                                  | Not checked                                                        | No release since 2024-06; repository active              |
| bastion           | 0.4.5 (2022-01-07)    | Supervisor trees with one-for-one, one-for-all, rest-for-one                                                                           | Not checked; runs on its own executor (LightProc)                             | Not checked                                                        | Last push 2023-04-22                                     |

Sources: [ractor README](https://github.com/slawlor/ractor) and `actor.rs`, `actor/messages.rs`, `actor/actor_properties.rs` in ractor 0.16.5; [ractor-supervisor README](https://github.com/simke9445/ractor-supervisor); [kameo README](https://github.com/tqwewe/kameo) and [`Actor` docs](https://docs.rs/kameo/0.22.2/kameo/actor/trait.Actor.html); [actix `Supervisor`](https://docs.rs/actix/0.13.5/actix/struct.Supervisor.html) and [`Context::set_mailbox_capacity`](https://docs.rs/actix/0.13.5/actix/struct.Context.html); [bastion README](https://github.com/bastion-rs/bastion). Versions and dates come from the crates.io API and the GitHub API on 2026-10-16.

Measured with `native_actors` (three runs each):

| Measurement                                    | Result per item            | Command                                               |
| ---------------------------------------------- | -------------------------- | ----------------------------------------------------- |
| Spawn an idle ractor actor                     | 669 to 849 ns, 7,644 B RSS | `native_actors ractor-idle 100000`                    |
| ractor ping-pong, current-thread, no drivers   | 384 to 523 ns              | `BUOY_RT=nodrv native_actors ractor-pingpong 1000000` |
| ractor ping-pong, current-thread, with drivers | 815 to 1,003 ns            | `native_actors ractor-pingpong 1000000`               |
| ractor ping-pong, multi-thread                 | 406 to 459 ns              | `native_actors ractor-pingpong-mt 1000000`            |

These frameworks host Rust actors. They do not run JS. For Buoy they are design references: the ractor mailbox priorities, its supervision events, and the kameo and ractor-supervisor restart strategies map directly onto OTP concepts. A Rust host for JS actors can reuse their structure. It cannot reuse their actor trait, because a JS actor's state lives in a JS heap.

## 3. WebAssembly process models

### 3.1 Lunatic

- Lunatic describes itself as "an Erlang-inspired runtime for WebAssembly". The README promises preemptive scheduling on a work-stealing executor, per-process heaps and syscalls, and fair scheduling even for infinite loops ([README](https://github.com/lunatic-solutions/lunatic)).
- Preemption uses Wasmtime fuel. Each store yields to the async executor after every 100,000 units of fuel (`out_of_fuel_async_yield(..., UNIT_OF_COMPUTE_IN_INSTRUCTIONS)` with the constant 100,000 in [`runtimes/wasmtime.rs` and `config.rs`](https://github.com/lunatic-solutions/lunatic/blob/28a2f387ebf6a64ce4b87e2638812e2c032d5049/crates/lunatic-process/src/runtimes/wasmtime.rs)).
- Messages are byte buffers plus host resources, copied between processes. Links deliver `LinkDied` signals ([`message.rs`](https://github.com/lunatic-solutions/lunatic/blob/28a2f387ebf6a64ce4b87e2638812e2c032d5049/crates/lunatic-process/src/message.rs)). Supervision lives in the guest library (`supervisor.rs` in [rust-lib](https://github.com/lunatic-solutions/rust-lib)), whose last push was 2024-03-18.
- Status on 2026-10-16: last release v0.13.2 on 2023-05-03, last commit on 2025-03-29 ("Fix build with rust 1.80"), dependency on Wasmtime 8 (GitHub API; `Cargo.toml` at commit `28a2f387`). Lunatic is useful to Buoy as a design reference only.
- Lunatic publishes no per-process memory or spawn numbers that I could find. Section 3.3 measures the same model directly on Wasmtime 49.

### 3.2 Wasmtime fuel and epoch interruption

- Fuel instruments code with a counter. When fuel runs out, the store traps or, with `fuel_async_yield_interval`, yields the async call ([`config.rs` and `store.rs`, v49.0.3](https://github.com/bytecodealliance/wasmtime/blob/v49.0.3/crates/wasmtime/src/config.rs)).
- Epochs instrument loop back edges and function entries with a check of a global counter. The embedder increments the counter, for example once per millisecond. On a deadline the store traps, runs a callback, or yields (same file).
- The docs say: "In general, epoch-based interruption results in faster execution. This difference is sometimes significant: in some measurements, up to 2-3x." They recommend fuel when "deterministic yielding or trapping is needed" (same file).
- The original epoch pull request measured epochs as "~twice as fast as fuel-based timeslicing for some workloads, especially control-flow-intensive workloads such as the SpiderMonkey JS interpreter on Wasm/WASI" ([PR #3699, 2022-01-19](https://github.com/bytecodealliance/wasmtime/pull/3699)).
- Neither mechanism interrupts a blocking host call. Bulk memory instructions such as `memory.copy` check the epoch only once at the start (same `config.rs`).
- Since Wasmtime 49 the `async_support` setting is deprecated and "no longer has any effect" (same file). Async stacks default to 2 MiB of reserved address space.

Measured with `wasm_interrupt` (Appendix A). Each cell is the median of 9 runs, interleaved across modes, in milliseconds. "Instrumentation only" means fuel or epochs are compiled in but never fire. The yielding modes use a fuel interval of 100,000 (the Lunatic value) or an epoch tick of 1 ms. This table uses a busy-poll executor with a no-op waker (`wasm_interrupt js noop`).

| Workload                                 | None   | Fuel, instrumentation only | Fuel, yield every 100,000 | Epoch, instrumentation only | Epoch, 1 ms ticks |
| ---------------------------------------- | ------ | -------------------------- | ------------------------- | --------------------------- | ----------------- |
| `loop_sum`, 10^9 iterations (WAT)        | 1081.2 | 1062.1                     | 1078.6                    | 1085.4                      | 1043.8            |
| `fib(36)`, recursive calls (WAT)         | 57.9   | 116.6                      | 121.7                     | 82.4                        | 81.1              |
| QuickJS `fib(27)` inside Javy 9.1.0      | 24.9   | 28.1                       | 29.2                      | 33.0                        | 31.0              |
| QuickJS JSON round trips, 20,000 objects | 101.4  | 158.5                      | 165.3                     | 132.9                       | 131.1             |

- Relative to no interruption, fuel cost 0%, 101%, 13%, and 56% on the four workloads. Epochs cost 0%, 42%, 33%, and 31%.
- The QuickJS JSON workload is noisy. Its fastest run without interruption took 75.5 ms against a median of 101.4 ms.
- On QuickJS `fib(27)`, epochs were slower than fuel in all three executor runs (33.0 against 28.1 ms with the busy-poll executor). On the JSON workload, epochs were faster. The PR reported epochs faster for SpiderMonkey. I did not investigate the difference.
- The yield itself is cheap. With the busy-poll executor, 149,992 fuel yields added 16.5 ms to `loop_sum`, about 0.1 µs each.
- The executor decides the real yield cost. Inside `Runtime::block_on` on a current-thread Tokio runtime without drivers, each yield cost about 0.35 µs (`wasm_interrupt js tokio`). With the I/O driver enabled, each yield cost about 19 µs, because every yield polled kqueue (`wasm_interrupt js tokio-io`: 3,935.1 ms against 1,096.7 ms).

### 3.3 One Wasm instance per actor

Measured with `wasm_actors` (Appendix A), three runs each. An "idle actor" is a Wasm instance with one 64 KiB memory page, suspended inside an async host import `recv` that awaits a Tokio channel. It holds a fiber stack while suspended.

| Measurement                                                          | Result per actor                    | Command                                      |
| -------------------------------------------------------------------- | ----------------------------------- | -------------------------------------------- |
| Instantiate and suspend an idle actor, on-demand allocator           | 10.4 to 12.8 µs, 23.6 KiB RSS       | `wasm_actors idle 10000`                     |
| Same, pooling allocator                                              | 5.2 to 6.0 µs, 23.6 KiB RSS         | `wasm_actors idle-pool 10000`                |
| Ping-pong between two Wasm actors through host channels, i64 payload | 646 to 699 ns per round trip        | `BUOY_RT=nodrv wasm_actors pingpong 1000000` |
| Same, current-thread runtime with drivers                            | 924 to 1,175 ns per round trip      | `wasm_actors pingpong 1000000`               |
| Javy 9.1.0 static module (QuickJS-ng) instantiate and run `_start`   | 46.1 to 53.4 µs, 233 to 234 KiB RSS | `wasm_actors javy-idle 2000 js`              |

- The ping-pong costs 556 to 634 ns more per round trip than two plain Tokio tasks in the same runtime configuration (65 to 90 ns). Each round trip suspends and resumes two fibers.
- The Javy module reports a 1,408 KiB linear memory, but only 234 KiB per instance became resident. Wasmtime mapped the image copy-on-write. On macOS this works only for modules loaded with `Module::deserialize_file` ([`config.rs`, `memory_init_cow`](https://github.com/bytecodealliance/wasmtime/blob/v49.0.3/crates/wasmtime/src/config.rs)). On Linux it also works through `memfd_create`.
- The futures that `call_async` returns are `Send`. The harness spawns them with `tokio::spawn`, which requires `Send`. A multi-thread Tokio runtime can therefore move a preempted Wasm actor to another worker thread.
- The Wasmtime 1.0 performance post reports SpiderMonkey.wasm instantiation falling from "about 2 milliseconds" to 5 µs through copy-on-write and lazy initialization ([Chris Fallin, 2022-09-06](https://bytecodealliance.org/articles/wasmtime-10-performance)). With copy-on-write images, the per-instance numbers in this note (234 KiB for Javy, 1.6 MiB for StarlingMonkey) count the pages each instance writes or touches. Image pages that no instance writes stay shared.

### 3.4 Component model, WASI 0.2, and WASI 0.3

- WASI 0.2 launched on 2024-01-25 with the `wasi-cli` and `wasi-http` worlds. Its post said async would come in 0.3 ([Dan Gohman](https://bytecodealliance.org/articles/WASI-0.2)).
- WASI 0.3.0 shipped on 2026-06-11 and 0.3.1 on 2026-08-11. WASI 0.3 rebases on Component Model async: `async func`, `stream<T>`, and `future<T>` are part of the canonical ABI ([WASI 0.3 release page](https://wasi.dev/releases/wasi-p3); [Bailey Hayes and Yosh Wuyts, 2026-06-11](https://bytecodealliance.org/articles/WASI-0.3)).
- Wasmtime 46 and later run WASI 0.3 with Component Model async on by default. Wasmtime 41 to 45 implemented release candidates behind flags (same release page).
- The launch post says async support for guest binding generators, including JavaScript, is "in-progress". jco supports WASI 0.3 as a host. ComponentizeJS still documents imports as synchronous, "pending component-model-level async support" ([ComponentizeJS README](https://github.com/bytecodealliance/ComponentizeJS)).
- The StarlingMonkey components built for this note imported WASI 0.2 interfaces (`wasi:io@0.2.12`, `wasi:http@0.2.10`, and others), as printed by `component_probe run`.

## 4. JavaScript inside Wasm

### 4.1 StarlingMonkey, ComponentizeJS, and jco

- StarlingMonkey is "a SpiderMonkey based JS runtime optimized for use in WebAssembly Components". Fastly's JS Compute platform and Fermyon's Spin JS SDK use it in production. Its core builtins target WASI 0.2.0 ([README](https://github.com/bytecodealliance/StarlingMonkey)).
- Its Web builtins include fetch, streams, text encoding, timers, crypto, URL, Blob, FormData, structured clone, `AbortController`, and `performance` ([`builtins/web`](https://github.com/bytecodealliance/StarlingMonkey/tree/main/builtins/web)).
- It has no `Intl`. A test component returned `typeof Intl` as `"undefined"`, and `new RegExp("\\p{L}", "u")` threw `SyntaxError: invalid property name in regular expression` (`component_probe run js/intl-component.wasm`). Issue [#45 "Intl support"](https://github.com/bytecodealliance/StarlingMonkey/issues/45) has been open since 2024-05-09. Its last update (2025-02-28) says the work waits on a SpiderMonkey rebase.
- ComponentizeJS turns an ES module and a WIT world into a component. Its [README](https://github.com/bytecodealliance/ComponentizeJS) calls the project "experimental" and gives "around 8MB" as the embedding size. My idle component was 11,988,034 bytes.
- jco 1.39.0 adds three things relevant to Buoy: a `--bundle` mode built on Rolldown, adapter files for 43 Node built-in modules ([`src/node-builtins`](https://github.com/bytecodealliance/jco/tree/jco-v1.39.0/packages/jco/src/node-builtins), which I did not test beyond the probes), and a plugin that rewrites regular expressions the engines cannot parse ([`engine-compat.ts`](https://github.com/bytecodealliance/jco/blob/jco-v1.39.0/packages/jco/src/engine-compat.ts), wired up in [`cmd/componentize.ts`](https://github.com/bytecodealliance/jco/blob/jco-v1.39.0/packages/jco/src/cmd/componentize.ts)). It also offers a QuickJS backend (`--backend quickjs`, componentize-qjs 0.4.5, per `jco componentize --help` and the package dependencies).
- StarlingMonkey ships an experimental VS Code debugger. Its README says it "will break in surprising and not always enjoyable ways" and requires the `--enable-script-debugging` runtime flag ([debugger README](https://github.com/bytecodealliance/StarlingMonkey/tree/main/debugger/vscode-dap-extension)).

Measured with `component_probe` (Appendix A). Components built with `jco componentize` 1.39.0 and componentize-js 0.23.0.

| Measurement                                                       | Result                                | Command                                                         |
| ----------------------------------------------------------------- | ------------------------------------- | --------------------------------------------------------------- |
| Instantiate an idle component and call `run()` once, per instance | 263 to 327 µs, 1,669 to 1,688 KiB RSS | `component_probe instances js/idle-component.wasm 500`          |
| Same with zod loaded and 1,000 `safeParse` calls, per instance    | 15.4 ms, 4,608 KiB RSS                | `component_probe instances js/zod-component.wasm 200`           |
| Host call into `run()` on a live instance (string result)         | 5.49 to 5.78 µs per call              | `component_probe calls js/idle-component.wasm 100000`           |
| JS `fib(27)`, interpreter / weval AOT (`--aot`)                   | 46.7 ms / 29.0 ms (median of 9)       | `component_probe repeat js/fib-sm.wasm`, `js/fib-sm-aot.wasm`   |
| JS JSON round trips, 20,000 objects, interpreter / weval AOT      | 31.8 ms / 38.1 ms (median of 9)       | `component_probe repeat js/json-sm.wasm`, `js/json-sm-aot.wasm` |
| Compile the zod component with Cranelift                          | 835 ms                                | `component_probe run js/zod-component.wasm`                     |

### 4.2 Javy

- Javy is a Bytecode Alliance toolchain that compiles JS to a Wasm module with an embedded QuickJS runtime. Javy 9.1.0 depends on rquickjs 0.12 ([`crates/javy/Cargo.toml` at v9.1.0](https://github.com/bytecodealliance/javy/blob/v9.1.0/crates/javy/Cargo.toml)).
- Static modules embed the engine. The README gives "at least 869 KB". My static builds were 1,358,226 to 1,358,540 bytes. Dynamic modules were 516 to 830 bytes and import a 1,341,751-byte plugin ([README](https://github.com/bytecodealliance/javy)).
- `javy build -J help` lists four runtime options: `javy-stream-io`, `simd-json-builtins`, `text-encoding`, and `event-loop`. Javy offers no fetch, no streams, no timers, and no Node APIs.

### 4.3 npm compatibility probes

Three probes, bundled with `bun build --target=browser --format=esm` (Appendix A):

- **zod@4.6.7**: 1,000 `safeParse` calls on a nested schema, then one failing parse that must report 3 issues.
- **ai@7.0.142**: `generateText` and `streamText` against `MockLanguageModelV4` from `ai/test`. No network.
- **@ai-sdk/openai@4.0.95**: `generateText` through `createOpenAI` with a custom `fetch` that returns a `Response` built in JS. No network.

| Runtime                                                                  | zod@4.6.7                                                                    | ai@7.0.142                                                                                                                    | @ai-sdk/openai@4.0.95                              |
| ------------------------------------------------------------------------ | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| Node 25.9.0 (reference)                                                  | Pass                                                                         | Pass                                                                                                                          | Pass                                               |
| QuickJS-ng 0.16.2 through rquickjs 0.14.0, no host APIs                  | Pass                                                                         | Fail: `TransformStream is not defined`                                                                                        | Fail: same error                                   |
| Boa 0.22.0, engine only                                                  | Pass                                                                         | Fail: `TransformStream is not defined`                                                                                        | Fail: same error                                   |
| LLRT v0.9.0-beta (QuickJS through rquickjs 0.12, Rust modules)           | Pass                                                                         | Pass                                                                                                                          | Pass                                               |
| Javy 9.1.0 with `-J event-loop=y -J text-encoding=y`                     | Pass                                                                         | Fail: `TransformStream is not defined`, then a Wasm trap                                                                      | Fail: same error                                   |
| StarlingMonkey (componentize-js 0.23.0), Bun bundle                      | Pass                                                                         | Fail at build: `SyntaxError: invalid class property name in regular expression` for `/[\p{L}\p{N}]+/gu` in `ai/dist/index.js` | Fail: same error                                   |
| Same, after replacing that one regex with `/[A-Za-z0-9\u00C0-\uFFFF]+/g` | Not rerun                                                                    | Pass                                                                                                                          | Pass                                               |
| StarlingMonkey through `jco componentize --bundle`                       | Pass                                                                         | Fail at pre-initialization: calls the `jco:node/os@0.1.0` `platform` import                                                   | Fail: same error                                   |
| jco `--backend quickjs --bundle`                                         | Builds; imports `jco:node/*` interfaces that plain Wasmtime does not provide | Fail at pre-initialization: `platform` adapter                                                                                | Fail: same error                                   |
| Porffor 0.0.0-alpha.17 (AOT to C, clang)                                 | Pass                                                                         | Fail: compiles, then exits with code 139 (SIGSEGV), with and without `--event-loop`                                           | Fail: compiles, then exits with code 139 (SIGSEGV) |

Commands: `js_probe quickjs <bundle>`, `js_probe javy <module.wasm>`, `buoy-boa-bench probe <bundle>`, `component_probe run <component.wasm>`, `llrt <bundle>`, and `npx porf --module <bundle>`. Appendix A lists the build commands.

The failures have four causes: missing Web platform APIs (`TransformStream`, `Response`), engine build options (`Intl` and Unicode property escapes), pre-initialization rules (no host calls while Wizer snapshots the heap), and a compiler crash (Porffor). zod avoids all four and passed everywhere.

## 5. Embedding a JS engine in a Rust host

### 5.1 V8 through rusty_v8

- Deno uses the `v8` crate from [rusty_v8](https://github.com/denoland/rusty_v8). Version 152.2.0 embeds V8 15.2.124.1 (`v8/include/v8-version.h`).
- `Isolate::terminate_execution` stops JS from any thread. `request_interrupt` runs a callback on the isolate's thread, and the callback "must not reenter interrupted Isolate" ([`src/isolate.rs` in v8 152.2.0](https://docs.rs/crate/v8/152.2.0/source/src/isolate.rs)). V8 can kill a runaway actor. JS run inside the callback nests on the same stack, so the interrupted isolate cannot resume until that work returns. Round-robin slicing between isolates on one thread would need a separate stack per isolate. I did not test that.
- `OwnedIsolate` values must be dropped in reverse order of creation on a thread. My first run panicked with that message. A scheduler that multiplexes isolates on a thread has to manage `Locker`s and enter/exit order explicitly.
- The crate exposes the V8 inspector (`src/inspector.rs`), which Deno uses for Chrome DevTools debugging.
- Deno's own Node layer passes "over 75% of Node's own test suite" as of Deno 2.8, and supports Node-API addons with `--allow-ffi` ([Deno docs, updated 2026-07-30](https://docs.deno.com/runtime/fundamentals/node/)). That layer is the size of the work a V8-based option B has to reuse or rebuild.

Measured with `buoy-v8-bench` (Appendix A), three runs each. Each actor evaluates the same 1-line actor script.

| Measurement                               | Result per actor                      | Command                       |
| ----------------------------------------- | ------------------------------------- | ----------------------------- |
| New isolate plus context per actor        | 365 to 416 µs, 1,095 to 1,096 KiB RSS | `buoy-v8-bench isolates 200`  |
| New context per actor in a shared isolate | 135 to 144 µs, 199 to 200 KiB RSS     | `buoy-v8-bench contexts 2000` |

### 5.2 QuickJS-ng through rquickjs

- rquickjs binds QuickJS-ng, a maintained fork of Bellard's QuickJS. It integrates promises with Rust futures. Its `parallel` feature is described as experimental ([README](https://github.com/DelSkayn/rquickjs)).
- rquickjs 0.14.0 bundles QuickJS-ng 0.16.2 (`QJS_VERSION_*` in `quickjs.h`).
- QuickJS-ng decrements a counter at 21 poll sites: jump opcodes in the bytecode loop, constructor calls, `for..in` setup, prototype-chain walks, and array builtins such as `every`, `reduce`, `indexOf`, and `find`. When the counter reaches zero, it calls the runtime's interrupt handler and resets the counter to 10,000 (`JS_INTERRUPT_COUNTER_INIT` and `js_poll_interrupts` in [`quickjs.c`](https://docs.rs/crate/rquickjs-sys/0.14.0/source/quickjs/quickjs.c)). A `true` return throws an uncatchable "interrupted" error.
- Each `Runtime` owns its heap and garbage collector. rquickjs exposes `set_memory_limit`, `set_max_stack_size`, and `set_gc_threshold` per runtime ([`src/runtime/base.rs` in rquickjs-core 0.14.0](https://docs.rs/crate/rquickjs-core/0.14.0/source/src/runtime/base.rs)).

Measured with `quickjs_native` (Appendix A), three runs each.

| Measurement                                              | Result per actor or call                        | Command                         |
| -------------------------------------------------------- | ----------------------------------------------- | ------------------------------- |
| New runtime and full context per actor                   | 54 to 66 µs, 174.0 KiB RSS                      | `quickjs_native runtimes 10000` |
| New context per actor in one shared runtime              | 81 to 89 µs, 56.3 KiB RSS                       | `quickjs_native contexts 10000` |
| Rust calls a JS `onMessage(1)` closure                   | 36 to 41 ns per call                            | `quickjs_native calls 1000000`  |
| `fib(27)` without / with an interrupt handler            | 14.5 / 14.0 ms (median of 9); 128 handler calls | `quickjs_native workloads`      |
| JSON round trips, 20,000 objects, without / with handler | 68.9 / 62.2 ms (median of 9); 11 handler calls  | `quickjs_native workloads`      |

The handler cost is below the run-to-run noise. In `fib(27)` it ran about every 110 µs.

The track note [`measurements-beam-quickjs.md`](measurements-beam-quickjs.md) measured Bellard's QuickJS (2025-09-13) compiled to Wasm by quickjs-emscripten inside Node, in a Linux VM. It reports 52,654 bytes by QuickJS accounting and about 66,000 bytes of RSS per runtime and context pair. rquickjs reports 98.9 KiB (`malloc_size`) for a QuickJS-ng runtime with a full context here. The engines, the enabled intrinsics, the host, and the page size all differ, so the two notes do not contradict each other.

### 5.3 Preemptive QuickJS-ng actors without Wasm (prototype)

The program `quickjs_preempt` (Appendix A) tests whether option B can time-slice arbitrary JS like the BEAM does:

- Each actor runs on its own stackful coroutine (corosensei 0.3.4) and creates its own QuickJS-ng runtime there, so the engine's stack limit matches the coroutine stack.
- The interrupt handler suspends the coroutine and returns `false` when resumed, so JS continues where it stopped.
- A round-robin loop resumes the actors. Each actor runs a 20,000,000-iteration JS loop with no `await`.

| Run | Sequential finish times (cooperative) | Preemptive finish times | Preemptions per actor | Mean slice |
| --- | ------------------------------------- | ----------------------- | --------------------- | ---------- |
| 1   | 372, 739, 1094, 1460 ms               | 1487 to 1488 ms         | 4,001                 | 93 µs      |
| 2   | 317, 624, 938, 1255 ms                | 1337 ms (all four)      | 4,001                 | 84 µs      |
| 3   | 341, 698, 1060, 1413 ms               | 1402 ms (all four)      | 4,001                 | 88 µs      |

Command: `quickjs_preempt 4`. The total time with preemption stayed within run-to-run noise of the sequential total, so the switch cost is too small to measure at this slice length. A suspended actor with a 256 KiB coroutine stack cost 190.2 KiB RSS and 54 to 60 µs to create (`quickjs_preempt suspended 5000`).

Limits of the prototype:

- Builtins without a poll site run to completion. `JSON.parse` on a large string is one example, because the JSON parser in `quickjs.c` contains no poll site. The BEAM has the same issue with long-running NIFs.
- The handler dereferences a raw pointer to the coroutine's yielder. It is sound only while each runtime stays on its own coroutine and the coroutine stays on one thread. rquickjs runtimes are not `Send` without the experimental `parallel` feature, so work stealing of a suspended JS actor across threads is untested.
- A stack overflow inside a coroutine hits a guard page and kills the process. Wasm traps the same fault and returns an error to the host.

### 5.4 Boa

- Boa is a JS engine written in Rust. v0.22 (2026-08-28) reports 95.60% on Test262. It enables Temporal by default, adds a polymorphic inline cache, and starts a move from `boa_runtime` to `boa_wintertc` for Web APIs ([release notes](https://github.com/boa-dev/boa/releases/tag/v0.22)).
- Measured with `buoy-boa-bench` (Appendix A): `fib(27)` took 68.8 ms and the JSON workload 378.0 ms (median of 5). A context per actor cost 263 to 272 µs (one run had a 1,550 µs outlier) and 336 KiB RSS (`buoy-boa-bench contexts 2000`).
- Boa is the slowest engine measured here, at 4.7 times QuickJS-ng on `fib(27)`. It is the only one without C or C++ code.

### 5.5 AWS LLRT

- LLRT is "built in Rust, utilizing QuickJS as JavaScript engine". v0.9.0-beta (2026-09-06) depends on rquickjs 0.12 ([`Cargo.toml` at v0.9.0-beta](https://github.com/awslabs/llrt/blob/v0.9.0-beta/Cargo.toml)).
- The README calls LLRT "an experimental package" and says it is "NOT a drop in replacement for Node.js, nor will it ever be" ([README](https://github.com/awslabs/llrt)).
- Its compatibility matrix marks `http`, `https`, `tls`, `http2`, `worker_threads`, `vm`, `cluster`, `dgram`, `inspector`, and `sqlite` as unsupported. It marks `fs`, `crypto`, `net`, `buffer`, `events`, `child_process`, `zlib`, and others as partial. `stream` is supported "but not native".
- The README asks users to bundle and tree-shake for the `browser` platform. It also says LLRT shows "notable drawbacks" for large data processing and long loops.
- LLRT passed all three probes in Section 4.3. Its modules are published as crates for rquickjs embedders, for example `llrt_modules`, `llrt_fetch`, and `llrt_stream_web` at 0.8.1-beta ([crates.io](https://crates.io/crates/llrt_modules)). An option B host could start from them.

### 5.6 Engine speed on the same JS

Two workloads: recursive `fib(27)` and 20,000 `JSON.stringify` plus `JSON.parse` round trips of a small chat-message object. Milliseconds, median of 5 to 9 runs.

| Engine and host                               | `fib(27)` | JSON, 20,000 objects | Command                        |
| --------------------------------------------- | --------- | -------------------- | ------------------------------ |
| V8 with JIT (Node 25.9.0)                     | 1.3       | 26.1                 | `node workloads.mjs`           |
| V8 without JIT (Node 25.9.0 `--jitless`)      | 12.6      | 30.6                 | `node --jitless workloads.mjs` |
| QuickJS-ng 0.16.2, native (rquickjs 0.14.0)   | 14.5      | 68.9                 | `quickjs_native workloads`     |
| QuickJS in Wasm (Javy 9.1.0, Wasmtime 49.0.3) | 24.9      | 101.4                | `wasm_interrupt js noop`       |
| StarlingMonkey in Wasm, interpreter           | 46.7      | 31.8                 | `component_probe repeat ...`   |
| StarlingMonkey in Wasm, weval AOT             | 29.0      | 38.1                 | `component_probe repeat ...`   |
| Boa 0.22.0, native                            | 68.8      | 378.0                | `buoy-boa-bench workloads`     |
| Porffor alpha 17, AOT to C                    | 1         | not run              | `npx porf fib.js`              |

- The Javy rows include instantiation (about 50 µs). Javy 9.1.0 embeds an older QuickJS-ng than rquickjs 0.14.0, so the native and Wasm QuickJS rows are not the same engine version.
- The Porffor value is the program's own `Date.now()` difference, which has 1 ms resolution.
- For JSON-heavy work, StarlingMonkey in Wasm ran within 22% of V8 with JIT. For call-heavy work, the interpreters ran 9.7 to 53 times slower than V8 with JIT.

## 6. TypeScript to IR to native compilers

Option B without an embedded engine needs an ahead-of-time compiler for TypeScript and for the JS in `node_modules`.

- **Porffor** compiles JS and TS ahead of time to C, then to a native binary ([porffor.dev](https://porffor.dev)). The site says: "Porffor is alpha and still has a lot of compatibility bugs" and "most existing JavaScript projects will not work out of the box yet".
  - Its package table tests 101 npm packages (tests dated 2026-07-22 to 2026-07-26): 49 pass, 15 partial, 26 runtime failures, 5 compiler failures, 5 invalid C, and 1 Node compatibility failure. It lists zod 4.4.3 as a runtime failure ([compat table](https://porffor.dev/compat.html), counted from the page source on 2026-10-16).
  - My run of 0.0.0-alpha.17 (2026-10-10) passed the zod@4.6.7 probe. The ai@7.0.142 probe compiled, then crashed with exit code 139 (SIGSEGV), with and without `--event-loop`. The @ai-sdk/openai@4.0.95 probe crashed the same way (Section 4.3).
  - The migration guide says `Proxy` and runtime-generated code have "no reliable shim", Node modules must move out of the compiled core, and `process.argv` is not supplied. The HTTP guide says client-side `fetch()` "is not implemented" and streaming responses "are not ready" ([adapt](https://porffor.dev/docs/adapt.html), [http](https://porffor.dev/docs/http.html)).
- **AssemblyScript** is a separate language with TypeScript syntax. Its status page lists no closures, no union types except nullable classes, no `any`, no exceptions, no iterators, no `for..of`, and no async/await "due to the lack of an event loop" ([status](https://www.assemblyscript.org/status.html)). It cannot compile zod or the AI SDK.
- **Static Hermes** compiles JS through C to native code. Its typed mode is "in progress and considered unstable". It accepts Flow syntax and only partial TypeScript syntax. Its object types are exact: no extra properties, in a fixed order ([TypedLanguage.md](https://github.com/facebook/hermes/blob/static_h/doc/TypedLanguage.md)). Untyped code keeps JS semantics with a few documented deviations ([SpecIncompat.md](https://github.com/facebook/hermes/blob/static_h/doc/SpecIncompat.md)).
  - A 2026-10-09 talk by Tzvetan Mikov compiled two real programs to native, a 6,200-line TypeScript CLI with Ink and React and the Flow bundler. Both needed a `hermes-node` runtime that ports Node's C++ bindings to Node-API. The talk lists gaps found along the way, including `crypto.randomUUID`, the regex `v` flag, top-level await, `Intl.Segmenter`, and `queueMicrotask`. For the CLI, native code cut run time from 940 ms to 505 ms and grew the binary from 16.8 MB to 44.0 MB ([slides](https://speakerdeck.com/tmikov2023/compiling-a-real-world-cli-tool-to-native-with-static-hermes)).
  - I did not run Static Hermes on the probes.

Conclusion: a native compiler alone does not deliver npm compatibility. Each project that runs real npm code natively also adds a runtime layer for Web or Node APIs (hermes-node, the Porffor server runtime). For option B, the compiler would at best be a speed tier for typed actor code, beside an embedded engine that runs `node_modules`.

## 7. How B and D4 handle the JS features the decision must cover

| Concern                   | B with QuickJS-ng runtime per actor                                                                                | B with V8                                                                                                                                                             | D4 (StarlingMonkey or Javy instance per actor)                                                                     |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Closures, mutable objects | Full JS semantics inside an actor. Objects cannot cross runtimes, so messages carry copies.                        | Same within an isolate. Contexts in one isolate can share objects unless the runtime forbids it.                                                                      | Full JS semantics inside an instance. Messages cross linear memories as bytes.                                     |
| Promises, event loop      | Each runtime has its own job queue (`execute_pending_job`). The host maps timers and I/O to Tokio.                 | Each isolate has its own microtask queue. The host supplies the event loop, as Deno does.                                                                             | StarlingMonkey runs its own event loop per instance on WASI pollables. Javy has an optional event loop.            |
| Native npm modules        | Not supported. QuickJS cannot load Node-API addons.                                                                | Possible through a Node-API layer, as Deno does with `--allow-ffi`. Addons share the process.                                                                         | Not supported unless the addon is compiled to Wasm.                                                                |
| Node APIs                 | Must be written or reused from `llrt_modules`. LLRT covers a partial set.                                          | Must be written or reused from Deno's Node layer.                                                                                                                     | jco 1.39 adapters exist but failed on ai at pre-initialization.                                                    |
| Async I/O                 | Native Tokio I/O.                                                                                                  | Native Tokio I/O.                                                                                                                                                     | WASI 0.2 pollables and `wasi:http` today. WASI 0.3 native async runs in Wasmtime 46+. JS guests do not use it yet. |
| Garbage collection        | One collector per runtime, so a collection pauses one actor. A shared-runtime context design shares one collector. | One collector per isolate.                                                                                                                                            | One collector per instance, inside its linear memory.                                                              |
| Cross-actor messages      | Copy or structured clone between heaps, as the BEAM copies. Rust can pass byte buffers without JS involvement.     | Same between isolates. Contexts in one isolate could pass references.                                                                                                 | Host-mediated copies. 646 to 699 ns round trip for an i64. 5.5 to 5.8 µs per call into StarlingMonkey.             |
| Preemption                | Interrupt handler plus coroutine (Section 5.3), about 90 µs slices.                                                | Terminate only. No tested suspend-and-resume.                                                                                                                         | Epoch or fuel at every loop and call in the engine, including its builtins.                                        |
| Fault containment         | JS errors and per-runtime memory limits stay local. Engine memory bugs and stack overflows crash the process.      | Same for JS errors. V8 reports heap exhaustion through OOM and near-heap-limit callbacks (`v8-isolate.h`). I did not test whether one isolate's OOM can be contained. | Traps return an error to the host. The Javy ai probe trapped and the harness continued.                            |

## 8. Scores for B and D4

Scale: 1 is poor for Buoy and 5 is strong. B is scored as its most viable variant: a Rust host on Tokio with one QuickJS-ng runtime per actor and coroutine preemption. D4 is scored as Wasmtime with one component instance per actor running StarlingMonkey, because StarlingMonkey is the only JS-in-Wasm engine here that ran the AI SDK. The notes say where B with V8, B without an engine, or D4 with Javy would score differently.

| Criterion                             | B   | D4  |
| ------------------------------------- | --- | --- |
| TypeScript and npm compatibility      | 3   | 2   |
| Runtime isolation and fault tolerance | 3   | 5   |
| Scheduling fairness                   | 4   | 5   |
| Startup time and memory per actor     | 3   | 2   |
| Message throughput and latency        | 4   | 3   |
| I/O and streaming performance         | 4   | 3   |
| Implementation complexity             | 2   | 2   |
| Debuggability and tooling             | 2   | 2   |
| Long-term extensibility               | 4   | 4   |
| **Total (unweighted)**                | 29  | 28  |

**TypeScript and npm compatibility.** B: 3. zod passes on QuickJS-ng. ai and @ai-sdk/openai need Web APIs, and LLRT shows that Rust modules on the same engine close that gap. Node API coverage stays partial and Node-API addons do not load. B without an engine scores 1 (Section 6). B with V8 and a Deno-sized Node layer could score 4. D4: 2. ai fails on Javy, on unpatched StarlingMonkey, and through jco `--bundle`. It passes on StarlingMonkey only after a manual regex rewrite.

**Runtime isolation and fault tolerance.** B: 3. Separate heaps, memory limits, and an uncatchable interrupt give per-actor containment for JS faults. Rust supervision crates provide OTP restart strategies. All actors share one address space, so a C engine bug or a stack overflow ends the process. D4: 5. Each actor has its own linear memory, engine heap, and stack. A trap returns an error to the host, and epochs can kill an actor at any loop.

**Scheduling fairness.** B: 4. The prototype gave equal progress with 84 to 93 µs slices. Builtins without a poll site, such as `JSON.parse`, are not preemptible, and Tokio itself only yields cooperatively. D4: 5. Fuel or epochs reach every loop and call in the engine, builtins included. Fuel gives a deterministic count that matches BEAM reductions most closely. The cost is 0 to 101% (fuel) or 0 to 42% (epochs) extra run time.

**Startup time and memory per actor.** B: 3. A runtime per actor costs 174 to 190 KiB and 54 to 66 µs. That is 68 to 74 times the 2,616 B of a new BEAM process. A shared runtime costs 56 KiB per context, with a shared fault domain. D4: 2. A StarlingMonkey instance costs 1,669 to 1,688 KiB and 263 to 327 µs. Javy costs 234 KiB and 46 to 53 µs, but without Web APIs it does not run the AI SDK.

**Message throughput and latency.** B: 4. Rust-to-JS calls take 36 to 41 ns. Tokio channels add 65 to 90 ns per round trip without drivers. Messages between runtimes must be copied, and I did not measure serialization. D4: 3. Host-mediated round trips take 646 to 699 ns for an integer. Each delivery into StarlingMonkey costs 5.5 to 5.8 µs, plus a copy into linear memory.

**I/O and streaming performance.** B: 4. I/O runs natively on Tokio, and LLRT runs `streamText` with Rust stream modules. JS-side parsing runs at interpreter speed: 2.6 times V8 on the JSON workload. D4: 3. `wasi:http` and WASI 0.2 streams work, and StarlingMonkey ran the JSON workload within 22% of V8 with JIT. Every byte crosses the sandbox boundary as a copy. JS guests do not yet use WASI 0.3 async.

**Implementation complexity.** B: 2. Buoy would build the scheduler, coroutine preemption, mailboxes, supervision, structured clone between runtimes, Web and Node APIs (partly from `llrt_modules`), module loading, and debugging. D4: 2. Wasmtime supplies isolation and preemption. Buoy would still build the actor host interface in WIT, supervision, message codecs, and a build pipeline on an experimental toolchain (ComponentizeJS, Wizer, weval) with known gaps (no `Intl`, pre-initialization limits).

**Debuggability and tooling.** B: 2. I found no maintained debugger for QuickJS-ng. Host-side Rust tooling such as [tokio-console](https://github.com/tokio-rs/console) helps. B with V8 would score 4 through the V8 inspector. D4: 2. StarlingMonkey's VS Code debugger is labelled experimental. Native profilers see the engine's Wasm functions. I did not check whether any tool maps them back to JS functions.

**Long-term extensibility.** B: 4. Buoy would own the scheduler, the per-actor heap, and the distribution protocol. The engine sits behind a host API, so QuickJS-ng, V8, or Boa can be swapped. The ceiling is interpreter speed unless V8 is used. D4: 4. The component model gives language-neutral actor interfaces, capability security, and WASI 0.3 async. Progress depends on the JS-in-Wasm toolchains, which still lack `Intl`, JIT-level speed, and JS async bindings.

## 9. Unverified items

- **Lunatic per-process cost.** Lunatic publishes no numbers. Building v0.13.2 with a Rust guest and spawning 10,000 processes would verify it.
- **Linux numbers.** All measurements ran on macOS with 16 KiB pages. Copy-on-write on macOS needs `Module::deserialize_file`. Rerunning Appendix A on Linux arm64 and x86-64 would verify memory per actor there.
- **Message serialization cost.** I measured transport with integer payloads only. A benchmark that sends a realistic chat message (structured clone or JSON) between two QuickJS runtimes and between two StarlingMonkey instances would verify it.
- **Cross-thread migration of preempted QuickJS actors.** It needs the experimental rquickjs `parallel` feature. A test that resumes suspended coroutines on other threads under load would verify it.
- **Suspend-and-resume for V8 isolates on fibers.** Untested. A prototype with per-isolate stacks and `Isolate::SetStackLimit` would verify it.
- **Cause of the Porffor crash on the AI SDK.** The ai and @ai-sdk/openai probes exit with SIGSEGV on alpha 17. A debug build (`porf -d`) of a reduced case would locate it.
- **Static Hermes on the probes.** Not run. Building the `static_h` branch and compiling the three bundles would verify it.
- **Boa with `boa_wintertc`.** Not tested. Adding its Web API crate and rerunning the ai probe would verify it.
- **StarlingMonkey `Intl` timeline.** Issue #45 shows no date.
- **ComponentizeJS on WASI 0.3.** The launch post says JS guest async is in progress. A build that exports an `async func` would verify it.
- **QuickJS-ng debugger.** I found none. A search of the QuickJS-ng issue tracker would confirm.
- **Why epochs ran slower than fuel on QuickJS `fib(27)`.** Comparing the machine code Cranelift generates for the QuickJS dispatch loop under each mode would explain it.

## Appendix A. Measurement harness

This appendix records every program that produced a number in this note. It belongs in `bench/` once the repository accepts it.

### A.1 Commands

The Rust programs live in three scratch Cargo projects. They need the rustup toolchain 1.98.0, because the Homebrew `cargo` on this machine is 1.88.

```sh
export TC=$HOME/.rustup/toolchains/1.98.0-aarch64-apple-darwin/bin
PATH="$TC:$PATH" RUSTC="$TC/rustc" "$TC/cargo" build --release   # in each of the three projects
```

The npm probes come from a scratch npm project. Bun bundles them.

```sh
npm install --ignore-scripts zod@4.6.7 ai@7.0.142 @ai-sdk/openai@4.0.95
bun build --target=browser --format=esm src/zod-main.js --outfile out/zod-main.js
bun build --target=browser --format=esm src/zod-component.js --outfile out/zod-component.js
# repeat for ai and openai
```

Javy 9.1.0 ran in Docker (`debian:bookworm-slim`) from the release binary `javy-arm-linux-v9.1.0.gz` (SHA-256 `826962f0e82354cf97d6e928ea36777872bbae76c626e326948e0367c4b55cb5`, matching the published checksum).

```sh
javy build js/fib.js -o js/fib.static.wasm
javy emit-plugin -o js/plugin.wasm
javy build -C dynamic -C plugin=js/plugin.wasm js/fib.js -o js/fib.dynamic.wasm
javy build -J event-loop=y -J text-encoding=y out/zod-main.js -o js/zod-main.wasm
```

ComponentizeJS ran in Docker (`node:24-bookworm-slim`) with `npm install @bytecodealliance/jco@1.39.0 @bytecodealliance/componentize-js@0.23.0`.

```sh
npx jco componentize js/idle-component.js --wit js/probe.wit --world-name probe -o js/idle-component.wasm
npx jco componentize --aot js/fib-component.js --wit js/probe.wit --world-name probe -o js/fib-sm-aot.wasm
npx jco componentize out/ai-component.js --wit probe.wit --world-name probe -o out/ai-component.wasm
npx jco componentize --bundle src/ai-component.js --wit probe.wit --world-name probe -o out/ai-bundled-sm.wasm
npx jco componentize --backend quickjs --bundle src/zod-component.js --wit probe.wit --world-name probe -o out/zod-bundled-qjs.wasm
```

The patched ai and openai components replaced one regular expression in the Bun bundle before `jco componentize`:

```python
s = open("ai-component.js").read()
s = s.replace("/[\\p{L}\\p{N}]+/gu", "/[A-Za-z0-9\\u00C0-\\uFFFF]+/g")
open("ai-component-patched.js", "w").write(s)
```

LLRT v0.9.0-beta ran in Docker from `llrt-linux-arm64-no-sdk.zip` (SHA-256 `ab582e0d60e570781c72f4615ba12271b14344278646edbaa2ed7c0214933a04`, matching the release asset digest): `./llrt out/zod-main.js`.

Porffor 0.0.0-alpha.17 ran in Docker (`node:24-bookworm-slim` plus `clang`) from npm: `npx porf --module out/zod-main.js`.

The measurement commands appear next to each table in the body of this note. Raw output is in A.5.

### A.2 Cargo manifests

`buoy-rust-wasm-bench/Cargo.toml`

```toml
[package]
name = "buoy-rust-wasm-bench"
version = "0.1.0"
edition = "2024"
publish = false

[dependencies]
tokio = { version = "1.53", features = ["full"] }
wasmtime = { version = "49", features = [
  "async",
  "pooling-allocator",
  "wat",
  "component-model",
  "cranelift",
] }
wasmtime-wasi = { version = "49" }
wasmtime-wasi-http = { version = "49" }
ractor = "0.16"
rquickjs = { version = "0.14", features = ["futures"] }
anyhow = "1"
corosensei = "0.3"

[profile.release]
debug = false
```

`buoy-v8-bench/Cargo.toml`

```toml
[package]
name = "buoy-v8-bench"
version = "0.1.0"
edition = "2024"
publish = false

[dependencies]
v8 = "152"

[profile.release]
debug = false
```

`buoy-boa-bench/Cargo.toml`

```toml
[package]
name = "buoy-boa-bench"
version = "0.1.0"
edition = "2024"
publish = false

[dependencies]
boa_engine = "0.22"

[profile.release]
debug = false
```

### A.3 Rust programs

`src/bin/wasm_interrupt.rs`

```rust
// Measures the execution-time cost of Wasmtime preemption hooks (fuel and epochs).
// Run: cargo run --release --bin wasm_interrupt -- <js-dir>
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use wasmtime::*;
use wasmtime_wasi::WasiCtxBuilder;
use wasmtime_wasi::p1::WasiP1Ctx;

const WAT: &str = r#"
(module
  (func (export "loop_sum") (param $n i64) (result i64)
    (local $i i64) (local $acc i64)
    (block $done
      (loop $l
        (br_if $done (i64.ge_u (local.get $i) (local.get $n)))
        (local.set $acc (i64.add (i64.mul (local.get $acc) (i64.const 31)) (local.get $i)))
        (local.set $i (i64.add (local.get $i) (i64.const 1)))
        (br $l)))
    (local.get $acc))
  (func $fib (export "fib") (param $n i32) (result i32)
    (if (result i32) (i32.lt_u (local.get $n) (i32.const 2))
      (then (local.get $n))
      (else (i32.add
        (call $fib (i32.sub (local.get $n) (i32.const 1)))
        (call $fib (i32.sub (local.get $n) (i32.const 2))))))))
"#;

#[derive(Clone, Copy, Debug, PartialEq)]
enum Mode {
    None,
    Fuel,
    FuelNoYield,
    Epoch,
    EpochNoTicks,
}

const FUEL_YIELD_INTERVAL: u64 = 100_000; // same unit size Lunatic uses
const EPOCH_TICK: Duration = Duration::from_millis(1);

fn engine(mode: Mode) -> Engine {
    let mut c = Config::new();
    match mode {
        Mode::None => {}
        Mode::Fuel | Mode::FuelNoYield => {
            c.consume_fuel(true);
        }
        Mode::Epoch | Mode::EpochNoTicks => {
            c.epoch_interruption(true);
        }
    }
    Engine::new(&c).unwrap()
}

fn configure<T>(store: &mut Store<T>, mode: Mode) {
    match mode {
        Mode::None => {}
        Mode::Fuel => {
            store.set_fuel(u64::MAX).unwrap();
            store.fuel_async_yield_interval(Some(FUEL_YIELD_INTERVAL)).unwrap();
        }
        Mode::FuelNoYield => {
            store.set_fuel(u64::MAX).unwrap();
        }
        Mode::Epoch => {
            store.set_epoch_deadline(1);
            store.epoch_deadline_async_yield_and_update(1);
        }
        Mode::EpochNoTicks => {
            store.set_epoch_deadline(u64::MAX / 2);
        }
    }
}

// Counts how many times the future returned Pending (one per preemptive yield).
struct CountYields<F> {
    inner: Pin<Box<F>>,
    yields: u64,
}
impl<F: Future> Future for CountYields<F> {
    type Output = (F::Output, u64);
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        match self.inner.as_mut().poll(cx) {
            Poll::Ready(v) => Poll::Ready((v, self.yields)),
            Poll::Pending => {
                self.yields += 1;
                Poll::Pending
            }
        }
    }
}
fn count<F: Future>(f: F) -> CountYields<F> {
    CountYields { inner: Box::pin(f), yields: 0 }
}

fn ticker(engine: Engine, stop: Arc<AtomicBool>) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        while !stop.load(Ordering::Relaxed) {
            std::thread::sleep(EPOCH_TICK);
            engine.increment_epoch();
        }
    })
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[v.len() / 2]
}

async fn wat_case(engine: &Engine, mode: Mode, which: &str) -> (Duration, u64) {
    let module = Module::new(engine, WAT).unwrap();
    let mut store = Store::new(engine, ());
    configure(&mut store, mode);
    let instance = Instance::new_async(&mut store, &module, &[]).await.unwrap();
    let start = Instant::now();
    let yields = match which {
        "loop_sum" => {
            let f = instance.get_typed_func::<i64, i64>(&mut store, "loop_sum").unwrap();
            let (r, y) = count(f.call_async(&mut store, 1_000_000_000)).await;
            std::hint::black_box(r.unwrap());
            y
        }
        _ => {
            let f = instance.get_typed_func::<i32, i32>(&mut store, "fib").unwrap();
            let (r, y) = count(f.call_async(&mut store, 36)).await;
            assert_eq!(r.unwrap(), 14_930_352);
            y
        }
    };
    (start.elapsed(), yields)
}

async fn javy_case(engine: &Engine, mode: Mode, module: &Module) -> (Duration, u64) {
    let mut linker: Linker<WasiP1Ctx> = Linker::new(engine);
    wasmtime_wasi::p1::add_to_linker_async(&mut linker, |s| s).unwrap();
    let pre = linker.instantiate_pre(module).unwrap();
    let mut store = Store::new(engine, WasiCtxBuilder::new().build_p1());
    configure(&mut store, mode);
    let start = Instant::now();
    let instance = pre.instantiate_async(&mut store).await.unwrap();
    let run = instance.get_typed_func::<(), ()>(&mut store, "_start").unwrap();
    let (r, y) = count(run.call_async(&mut store, ())).await;
    r.unwrap();
    (start.elapsed(), y)
}

fn noop_block_on<F: Future>(f: F) -> F::Output {
    let mut f = std::pin::pin!(f);
    let mut cx = Context::from_waker(std::task::Waker::noop());
    loop {
        if let Poll::Ready(v) = f.as_mut().poll(&mut cx) {
            return v;
        }
    }
}

fn main() {
    let js_dir = std::env::args().nth(1).unwrap_or_else(|| "js".to_string());
    let executor = std::env::args().nth(2).unwrap_or_else(|| "noop".to_string());
    let rt = match executor.as_str() {
        "tokio-io" => tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap(),
        _ => tokio::runtime::Builder::new_current_thread().build().unwrap(),
    };
    let reps = 9;
    let modes = [Mode::None, Mode::Fuel, Mode::FuelNoYield, Mode::Epoch, Mode::EpochNoTicks];
    let engines: Vec<Engine> = modes.iter().map(|m| engine(*m)).collect();
    let stop = Arc::new(AtomicBool::new(false));
    let tick = ticker(engines[3].clone(), stop.clone());
    println!("executor,workload,mode,median_ms,min_ms,yields_per_run");
    for which in ["loop_sum", "fib", "javy_fib", "javy_json"] {
        let modules: Vec<Option<Module>> = engines
            .iter()
            .map(|e| match which {
                "javy_fib" => Some(Module::from_file(e, format!("{js_dir}/fib.static.wasm")).unwrap()),
                "javy_json" => Some(Module::from_file(e, format!("{js_dir}/json.static.wasm")).unwrap()),
                _ => None,
            })
            .collect();
        let mut times: Vec<Vec<f64>> = vec![vec![]; modes.len()];
        let mut yields = vec![0u64; modes.len()];
        for _ in 0..reps {
            for (i, mode) in modes.iter().enumerate() {
                let fut = async {
                    match &modules[i] {
                        Some(m) => javy_case(&engines[i], *mode, m).await,
                        None => wat_case(&engines[i], *mode, which).await,
                    }
                };
                let (d, y) = match executor.as_str() {
                    "noop" => noop_block_on(fut),
                    _ => rt.block_on(fut),
                };
                times[i].push(d.as_secs_f64() * 1e3);
                yields[i] = y;
            }
        }
        for (i, mode) in modes.iter().enumerate() {
            let min = times[i].iter().cloned().fold(f64::MAX, f64::min);
            println!("{executor},{which},{mode:?},{:.1},{:.1},{}", median(times[i].clone()), min, yields[i]);
        }
    }
    stop.store(true, Ordering::Relaxed);
    tick.join().unwrap();
}
```

`src/bin/wasm_actors.rs`

```rust
// Measures Wasm-instance-per-actor costs in Wasmtime: spawn time, resident memory per
// suspended actor, and host-mediated ping-pong latency between two Wasm actors.
// Run: cargo run --release --bin wasm_actors -- <mode> <n> [js-dir]
//   mode = idle | idle-pool | pingpong | javy-idle
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use wasmtime::*;
use wasmtime_wasi::WasiCtxBuilder;
use wasmtime_wasi::p1::WasiP1Ctx;

const WAT: &str = r#"
(module
  (import "host" "recv" (func $recv (result i64)))
  (import "host" "send" (func $send (param i64)))
  (memory (export "memory") 1)
  (func (export "idle") (result i64) (call $recv))
  (func (export "echo") (param $n i64)
    (local $i i64)
    (block $done (loop $l
      (br_if $done (i64.ge_u (local.get $i) (local.get $n)))
      (call $send (i64.add (call $recv) (i64.const 1)))
      (local.set $i (i64.add (local.get $i) (i64.const 1)))
      (br $l)))))
"#;

struct Actor {
    inbox: UnboundedReceiver<i64>,
    outbox: Option<UnboundedSender<i64>>,
    parked: Arc<AtomicUsize>,
}

pub fn rss_kib() -> u64 {
    let out = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .unwrap();
    String::from_utf8(out.stdout).unwrap().trim().parse().unwrap()
}

fn linker(engine: &Engine) -> Linker<Actor> {
    let mut l: Linker<Actor> = Linker::new(engine);
    l.func_wrap_async("host", "recv", |mut caller: Caller<'_, Actor>, (): ()| {
        Box::new(async move {
            caller.data().parked.fetch_add(1, Ordering::Relaxed);
            caller.data_mut().inbox.recv().await.unwrap_or(-1)
        })
    })
    .unwrap();
    l.func_wrap("host", "send", |caller: Caller<'_, Actor>, v: i64| {
        if let Some(tx) = &caller.data().outbox {
            let _ = tx.send(v);
        }
    })
    .unwrap();
    l
}

fn engine(pool: bool) -> Engine {
    let mut c = Config::new();
    if pool {
        let mut p = PoolingAllocationConfig::default();
        p.total_memories(20_000).total_core_instances(20_000).total_stacks(20_000);
        p.max_memory_size(1 << 16);
        c.allocation_strategy(InstanceAllocationStrategy::Pooling(p));
    }
    Engine::new(&c).unwrap()
}

async fn idle(n: usize, pool: bool) {
    let engine = engine(pool);
    let module = Module::new(&engine, WAT).unwrap();
    let pre = linker(&engine).instantiate_pre(&module).unwrap();
    let parked = Arc::new(AtomicUsize::new(0));
    let mut senders = Vec::with_capacity(n);
    let base = rss_kib();
    let t0 = Instant::now();
    for _ in 0..n {
        let (tx, rx) = unbounded_channel();
        senders.push(tx);
        let mut store = Store::new(&engine, Actor { inbox: rx, outbox: None, parked: parked.clone() });
        let instance = pre.instantiate_async(&mut store).await.unwrap();
        let f = instance.get_typed_func::<(), i64>(&mut store, "idle").unwrap();
        tokio::spawn(async move { f.call_async(&mut store, ()).await.unwrap() });
    }
    while parked.load(Ordering::Relaxed) < n {
        tokio::task::yield_now().await;
    }
    let dt = t0.elapsed();
    let rss = rss_kib();
    println!(
        "wasm_idle_actors,pool={pool},n={n},spawn_us_per_actor={:.2},rss_kib_per_actor={:.1},rss_total_mib={:.1}",
        dt.as_secs_f64() * 1e6 / n as f64,
        (rss - base) as f64 / n as f64,
        rss as f64 / 1024.0
    );
    drop(senders);
}

async fn pingpong(n: i64) {
    let engine = engine(false);
    let module = Module::new(&engine, WAT).unwrap();
    let pre = linker(&engine).instantiate_pre(&module).unwrap();
    let parked = Arc::new(AtomicUsize::new(0));
    let (a_tx, a_rx) = unbounded_channel();
    let (b_tx, b_rx) = unbounded_channel();
    let mut sa = Store::new(&engine, Actor { inbox: a_rx, outbox: Some(b_tx), parked: parked.clone() });
    let mut sb = Store::new(&engine, Actor { inbox: b_rx, outbox: Some(a_tx.clone()), parked: parked.clone() });
    let ia = pre.instantiate_async(&mut sa).await.unwrap();
    let ib = pre.instantiate_async(&mut sb).await.unwrap();
    let fa = ia.get_typed_func::<i64, ()>(&mut sa, "echo").unwrap();
    let fb = ib.get_typed_func::<i64, ()>(&mut sb, "echo").unwrap();
    let t0 = Instant::now();
    let ja = tokio::spawn(async move { fa.call_async(&mut sa, n).await.unwrap() });
    let jb = tokio::spawn(async move { fb.call_async(&mut sb, n).await.unwrap() });
    a_tx.send(0).unwrap();
    ja.await.unwrap();
    jb.await.unwrap();
    let dt = t0.elapsed();
    println!(
        "wasm_pingpong,round_trips={n},ns_per_round_trip={:.0}",
        dt.as_secs_f64() * 1e9 / n as f64
    );
}

async fn javy_idle(n: usize, js_dir: &str) {
    let engine = Engine::default();
    let cwasm = format!("{js_dir}/idle.static.cwasm");
    let bytes = engine.precompile_module(&std::fs::read(format!("{js_dir}/idle.static.wasm")).unwrap()).unwrap();
    std::fs::write(&cwasm, bytes).unwrap();
    // deserialize_file lets Wasmtime map the image copy-on-write on macOS.
    let module = unsafe { Module::deserialize_file(&engine, &cwasm).unwrap() };
    let mut linker: Linker<WasiP1Ctx> = Linker::new(&engine);
    wasmtime_wasi::p1::add_to_linker_async(&mut linker, |s| s).unwrap();
    let pre = linker.instantiate_pre(&module).unwrap();
    let mut stores = Vec::with_capacity(n);
    let base = rss_kib();
    let t0 = Instant::now();
    for _ in 0..n {
        let mut store = Store::new(&engine, WasiCtxBuilder::new().build_p1());
        let instance = pre.instantiate_async(&mut store).await.unwrap();
        let start = instance.get_typed_func::<(), ()>(&mut store, "_start").unwrap();
        start.call_async(&mut store, ()).await.unwrap();
        stores.push((store, instance));
    }
    let dt = t0.elapsed();
    let rss = rss_kib();
    let (store0, instance0) = &mut stores[0];
    let mem = instance0.get_memory(&mut *store0, "memory").unwrap();
    let pages = mem.size(&*store0);
    println!(
        "javy_quickjs_instances,n={n},instantiate_and_start_us={:.1},rss_kib_per_instance={:.1},linear_memory_kib={},rss_total_mib={:.1}",
        dt.as_secs_f64() * 1e6 / n as f64,
        (rss - base) as f64 / n as f64,
        pages * 64,
        rss as f64 / 1024.0
    );
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("idle").to_string();
    let n: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(10_000);
    let js_dir = args.get(3).cloned().unwrap_or_else(|| "js".to_string());
    // BUOY_RT=nodrv builds the current-thread runtime without the I/O and timer drivers.
    let rt = match std::env::var("BUOY_RT").as_deref() {
        Ok("nodrv") => tokio::runtime::Builder::new_current_thread().build().unwrap(),
        _ => tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap(),
    };
    rt.block_on(async {
        match mode.as_str() {
            "idle" => idle(n, false).await,
            "idle-pool" => idle(n, true).await,
            "pingpong" => pingpong(n as i64).await,
            "javy-idle" => javy_idle(n, &js_dir).await,
            _ => panic!("unknown mode"),
        }
    });
}
```

`src/bin/native_actors.rs`

```rust
// Baseline costs for native Rust actors: Tokio tasks with mpsc mailboxes, and ractor actors.
// Run: cargo run --release --bin native_actors -- <mode> <n>
//   mode = tokio-idle | tokio-pingpong | tokio-pingpong-mt | ractor-idle | ractor-pingpong
use ractor::{Actor, ActorProcessingErr, ActorRef};
use std::time::Instant;
use tokio::sync::mpsc::unbounded_channel;
use tokio::sync::oneshot;

fn rss_kib() -> u64 {
    let out = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .unwrap();
    String::from_utf8(out.stdout).unwrap().trim().parse().unwrap()
}

async fn tokio_idle(n: usize) {
    let mut senders = Vec::with_capacity(n);
    let base = rss_kib();
    let t0 = Instant::now();
    for _ in 0..n {
        let (tx, mut rx) = unbounded_channel::<u64>();
        senders.push(tx);
        tokio::spawn(async move {
            let mut total = 0u64;
            while let Some(v) = rx.recv().await {
                total += v;
            }
            total
        });
    }
    tokio::task::yield_now().await;
    let dt = t0.elapsed();
    let rss = rss_kib();
    println!(
        "tokio_idle_tasks,n={n},spawn_ns_per_task={:.0},rss_bytes_per_task={:.0}",
        dt.as_secs_f64() * 1e9 / n as f64,
        (rss - base) as f64 * 1024.0 / n as f64
    );
}

async fn tokio_pingpong(n: u64) {
    let (a_tx, mut a_rx) = unbounded_channel::<u64>();
    let (b_tx, mut b_rx) = unbounded_channel::<u64>();
    let t0 = Instant::now();
    let b = tokio::spawn(async move {
        while let Some(v) = b_rx.recv().await {
            let _ = a_tx.send(v + 1);
        }
    });
    let a = tokio::spawn(async move {
        let mut v = 0;
        for _ in 0..n {
            b_tx.send(v).unwrap();
            v = a_rx.recv().await.unwrap();
        }
        v
    });
    assert_eq!(a.await.unwrap(), n);
    b.await.unwrap();
    let dt = t0.elapsed();
    println!("tokio_pingpong,round_trips={n},ns_per_round_trip={:.0}", dt.as_secs_f64() * 1e9 / n as f64);
}

struct Idle;
impl Actor for Idle {
    type Msg = u64;
    type State = u64;
    type Arguments = ();
    async fn pre_start(&self, _: ActorRef<u64>, _: ()) -> Result<u64, ActorProcessingErr> {
        Ok(0)
    }
    async fn handle(&self, _: ActorRef<u64>, m: u64, s: &mut u64) -> Result<(), ActorProcessingErr> {
        *s += m;
        Ok(())
    }
}

async fn ractor_idle(n: usize) {
    let mut refs = Vec::with_capacity(n);
    let base = rss_kib();
    let t0 = Instant::now();
    for _ in 0..n {
        let (r, _h) = Actor::spawn(None, Idle, ()).await.unwrap();
        refs.push(r);
    }
    let dt = t0.elapsed();
    let rss = rss_kib();
    println!(
        "ractor_idle_actors,n={n},spawn_ns_per_actor={:.0},rss_bytes_per_actor={:.0}",
        dt.as_secs_f64() * 1e9 / n as f64,
        (rss - base) as f64 * 1024.0 / n as f64
    );
}

enum Ping {
    Ball(u64, ActorRef<Ping>),
}
struct Player;
impl Actor for Player {
    type Msg = Ping;
    type State = (u64, Option<oneshot::Sender<()>>);
    type Arguments = (u64, Option<oneshot::Sender<()>>);
    async fn pre_start(&self, _: ActorRef<Ping>, a: Self::Arguments) -> Result<Self::State, ActorProcessingErr> {
        Ok(a)
    }
    async fn handle(&self, me: ActorRef<Ping>, m: Ping, s: &mut Self::State) -> Result<(), ActorProcessingErr> {
        let Ping::Ball(v, from) = m;
        if v >= 2 * s.0 {
            if let Some(done) = s.1.take() {
                let _ = done.send(());
            }
            return Ok(());
        }
        from.cast(Ping::Ball(v + 1, me))?;
        Ok(())
    }
}

async fn ractor_pingpong(n: u64) {
    let (done_tx, done_rx) = oneshot::channel();
    let (done_tx2, done_rx2) = oneshot::channel();
    let (a, _) = Actor::spawn(None, Player, (n, Some(done_tx))).await.unwrap();
    let (b, _) = Actor::spawn(None, Player, (n, Some(done_tx2))).await.unwrap();
    let t0 = Instant::now();
    b.cast(Ping::Ball(0, a.clone())).unwrap();
    tokio::select! { _ = done_rx => {}, _ = done_rx2 => {} }
    let dt = t0.elapsed();
    println!("ractor_pingpong,round_trips={n},ns_per_round_trip={:.0}", dt.as_secs_f64() * 1e9 / n as f64);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).cloned().unwrap_or_else(|| "tokio-idle".into());
    let n: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(100_000);
    let rt = match mode.as_str() {
        "tokio-pingpong-mt" | "ractor-pingpong-mt" => tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap(),
        "tokio-pingpong-nodrv" => tokio::runtime::Builder::new_current_thread().build().unwrap(),
        _ if std::env::var("BUOY_RT").as_deref() == Ok("nodrv") => tokio::runtime::Builder::new_current_thread().build().unwrap(),
        _ => tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap(),
    };
    rt.block_on(async {
        match mode.as_str() {
            "tokio-idle" => tokio_idle(n).await,
            "tokio-pingpong" | "tokio-pingpong-mt" | "tokio-pingpong-nodrv" => tokio_pingpong(n as u64).await,
            "ractor-idle" => ractor_idle(n).await,
            "ractor-pingpong" | "ractor-pingpong-mt" => ractor_pingpong(n as u64).await,
            _ => panic!("unknown mode"),
        }
    });
}
```

`src/bin/quickjs_native.rs`

```rust
// Costs of embedding QuickJS-ng natively in Rust through rquickjs: one runtime per actor,
// one context per actor, Rust-to-JS message calls, and the interrupt-handler hook.
// Run: cargo run --release --bin quickjs_native -- <mode> <n>
//   mode = runtimes | contexts | calls | workloads
use rquickjs::{Context, Function, Runtime};
use std::cell::Cell;
use std::rc::Rc;
use std::time::Instant;

const ACTOR_JS: &str = "let count = 0; globalThis.onMessage = (m) => { count += m; return count; }; onMessage(1);";
const FIB_JS: &str = "function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); } fib(27);";
const JSON_JS: &str = r#"let total = 0;
for (let i = 0; i < 20000; i++) {
  const msg = { id: i, role: "assistant", content: "token ".repeat(20), tools: [{ name: "search", args: { q: "x" + i } }] };
  total += JSON.parse(JSON.stringify(msg)).content.length;
}
total;"#;

fn rss_kib() -> u64 {
    let out = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .unwrap();
    String::from_utf8(out.stdout).unwrap().trim().parse().unwrap()
}

fn runtimes(n: usize) {
    let mut keep = Vec::with_capacity(n);
    let base = rss_kib();
    let t0 = Instant::now();
    for _ in 0..n {
        let rt = Runtime::new().unwrap();
        let ctx = Context::full(&rt).unwrap();
        ctx.with(|ctx| ctx.eval::<(), _>(ACTOR_JS).unwrap());
        keep.push((rt, ctx));
    }
    let dt = t0.elapsed();
    let rss = rss_kib();
    let usage = keep[0].0.memory_usage();
    println!(
        "quickjs_runtime_per_actor,n={n},create_us={:.1},rss_kib_per_actor={:.1},quickjs_malloc_size_kib={:.1}",
        dt.as_secs_f64() * 1e6 / n as f64,
        (rss - base) as f64 / n as f64,
        usage.malloc_size as f64 / 1024.0
    );
}

fn contexts(n: usize) {
    let rt = Runtime::new().unwrap();
    let mut keep = Vec::with_capacity(n);
    let base = rss_kib();
    let t0 = Instant::now();
    for _ in 0..n {
        let ctx = Context::full(&rt).unwrap();
        ctx.with(|ctx| ctx.eval::<(), _>(ACTOR_JS).unwrap());
        keep.push(ctx);
    }
    let dt = t0.elapsed();
    let rss = rss_kib();
    println!(
        "quickjs_context_per_actor,n={n},create_us={:.1},rss_kib_per_actor={:.1}",
        dt.as_secs_f64() * 1e6 / n as f64,
        (rss - base) as f64 / n as f64
    );
}

fn calls(n: usize) {
    let rt = Runtime::new().unwrap();
    let ctx = Context::full(&rt).unwrap();
    ctx.with(|ctx| {
        ctx.eval::<(), _>(ACTOR_JS).unwrap();
        let f: Function = ctx.globals().get("onMessage").unwrap();
        let t0 = Instant::now();
        let mut last = 0i64;
        for _ in 0..n {
            last = f.call((1i64,)).unwrap();
        }
        let dt = t0.elapsed();
        assert_eq!(last, n as i64 + 1);
        println!("quickjs_rust_to_js_call,n={n},ns_per_call={:.0}", dt.as_secs_f64() * 1e9 / n as f64);
    });
}

fn run_timed(src: &str, interrupt: bool) -> (f64, u64) {
    let rt = Runtime::new().unwrap();
    let polls = Rc::new(Cell::new(0u64));
    if interrupt {
        let p = polls.clone();
        rt.set_interrupt_handler(Some(Box::new(move || {
            p.set(p.get() + 1);
            false
        })));
    }
    let ctx = Context::full(&rt).unwrap();
    let t0 = Instant::now();
    ctx.with(|ctx| ctx.eval::<(), _>(src).unwrap());
    (t0.elapsed().as_secs_f64() * 1e3, polls.get())
}

fn workloads() {
    for (name, src) in [("fib27", FIB_JS), ("json20k", JSON_JS)] {
        for interrupt in [false, true] {
            let mut times = vec![];
            let mut polls = 0;
            for _ in 0..9 {
                let (ms, p) = run_timed(src, interrupt);
                times.push(ms);
                polls = p;
            }
            times.sort_by(|a, b| a.partial_cmp(b).unwrap());
            println!(
                "quickjs_native_workload,{name},interrupt_handler={interrupt},median_ms={:.1},min_ms={:.1},handler_calls={polls}",
                times[4], times[0]
            );
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).cloned().unwrap_or_else(|| "runtimes".into());
    let n: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(10_000);
    match mode.as_str() {
        "runtimes" => runtimes(n),
        "contexts" => contexts(n),
        "calls" => calls(n),
        "workloads" => workloads(),
        _ => panic!("unknown mode"),
    }
}
```

`src/bin/quickjs_preempt.rs`

```rust
// Prototype: preemptive time slicing of natively embedded QuickJS-ng actors without Wasm.
// Each actor owns a QuickJS runtime on its own stackful coroutine. QuickJS calls the runtime's
// interrupt handler about every 10,000 interpreter ticks; the handler suspends the coroutine,
// and a round-robin scheduler resumes the next actor. Compare with running the same scripts
// sequentially, which is what a cooperative scheduler does with code that never awaits.
// Run: cargo run --release --bin quickjs_preempt -- <actors>
use corosensei::stack::DefaultStack;
use corosensei::{Coroutine, CoroutineResult, Yielder};
use rquickjs::{Context, Runtime};
use std::time::{Duration, Instant};

const SPIN_JS: &str = "let x = 0; for (let i = 0; i < 20000000; i++) { x = (x + i) | 0; } x;";

fn sequential(actors: usize) -> (Duration, Vec<Duration>) {
    let t0 = Instant::now();
    let mut finished = vec![];
    for _ in 0..actors {
        let rt = Runtime::new().unwrap();
        let ctx = Context::full(&rt).unwrap();
        let r: i32 = ctx.with(|ctx| ctx.eval(SPIN_JS).unwrap());
        std::hint::black_box(r);
        finished.push(t0.elapsed());
    }
    (t0.elapsed(), finished)
}

fn preemptive(actors: usize) -> (Duration, Vec<Duration>, Vec<u64>) {
    let mut coroutines: Vec<Option<Coroutine<(), (), i32, DefaultStack>>> = (0..actors)
        .map(|_| {
            Some(Coroutine::with_stack(DefaultStack::new(1 << 20).unwrap(), |yielder: &Yielder<(), ()>, ()| {
                let rt = Runtime::new().unwrap();
                rt.set_max_stack_size(512 * 1024);
                let y = yielder as *const Yielder<(), ()>;
                // SAFETY: the yielder outlives the runtime, which is dropped inside this coroutine.
                rt.set_interrupt_handler(Some(Box::new(move || {
                    unsafe { (*y).suspend(()) };
                    false
                })));
                let ctx = Context::full(&rt).unwrap();
                ctx.with(|ctx| ctx.eval::<i32, _>(SPIN_JS).unwrap())
            }))
        })
        .collect();
    let mut preemptions = vec![0u64; actors];
    let mut finished = vec![Duration::ZERO; actors];
    let t0 = Instant::now();
    let mut alive = actors;
    while alive > 0 {
        for i in 0..actors {
            let Some(co) = coroutines[i].as_mut() else { continue };
            match co.resume(()) {
                CoroutineResult::Yield(()) => preemptions[i] += 1,
                CoroutineResult::Return(r) => {
                    std::hint::black_box(r);
                    finished[i] = t0.elapsed();
                    coroutines[i] = None;
                    alive -= 1;
                }
            }
        }
    }
    (t0.elapsed(), finished, preemptions)
}

fn rss_kib() -> u64 {
    let out = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .unwrap();
    String::from_utf8(out.stdout).unwrap().trim().parse().unwrap()
}

// Memory per preemptible actor: each actor is suspended mid-loop at its first interrupt.
fn suspended(n: usize) {
    let base = rss_kib();
    let t0 = Instant::now();
    let mut keep = Vec::with_capacity(n);
    for _ in 0..n {
        let mut co: Coroutine<(), (), i32, DefaultStack> =
            Coroutine::with_stack(DefaultStack::new(256 * 1024).unwrap(), |yielder: &Yielder<(), ()>, ()| {
                let rt = Runtime::new().unwrap();
                rt.set_max_stack_size(128 * 1024);
                let y = yielder as *const Yielder<(), ()>;
                rt.set_interrupt_handler(Some(Box::new(move || {
                    unsafe { (*y).suspend(()) };
                    false
                })));
                let ctx = Context::full(&rt).unwrap();
                ctx.with(|ctx| ctx.eval::<i32, _>(SPIN_JS).unwrap())
            });
        assert!(matches!(co.resume(()), CoroutineResult::Yield(())));
        keep.push(co);
    }
    let dt = t0.elapsed();
    let rss = rss_kib();
    println!(
        "suspended_quickjs_actors,n={n},spawn_us_per_actor={:.1},rss_kib_per_actor={:.1}",
        dt.as_secs_f64() * 1e6 / n as f64,
        (rss - base) as f64 / n as f64
    );
    // Dropping a suspended coroutine unwinds its stack; leak instead to keep the probe simple.
    std::mem::forget(keep);
}

fn ms(d: &Duration) -> String {
    format!("{:.0}", d.as_secs_f64() * 1e3)
}

fn main() {
    if std::env::args().nth(1).as_deref() == Some("suspended") {
        suspended(std::env::args().nth(2).and_then(|s| s.parse().ok()).unwrap_or(2000));
        return;
    }
    let actors: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(4);
    let (seq_total, seq_done) = sequential(actors);
    let (pre_total, pre_done, preemptions) = preemptive(actors);
    let total_switches: u64 = preemptions.iter().sum();
    println!(
        "sequential(cooperative),actors={actors},total_ms={},finish_ms=[{}]",
        ms(&seq_total),
        seq_done.iter().map(ms).collect::<Vec<_>>().join(" ")
    );
    println!(
        "preemptive(interrupt+coroutine),actors={actors},total_ms={},finish_ms=[{}],preemptions=[{}],mean_slice_us={:.0},overhead_ns_per_switch={:.0}",
        ms(&pre_total),
        pre_done.iter().map(ms).collect::<Vec<_>>().join(" "),
        preemptions.iter().map(|p| p.to_string()).collect::<Vec<_>>().join(" "),
        pre_total.as_secs_f64() * 1e6 / total_switches as f64,
        (pre_total.as_secs_f64() - seq_total.as_secs_f64()) * 1e9 / total_switches as f64
    );
}
```

`src/bin/js_probe.rs`

```rust
// Runs an npm compatibility probe bundle in QuickJS-ng (rquickjs, native) or a Javy-built
// Wasm module (QuickJS in Wasmtime). The probe stores its JSON report in globalThis.__probeResult
// (QuickJS) or prints it with console.log (Javy).
// Run: cargo run --release --bin js_probe -- quickjs <bundle.js>
//      cargo run --release --bin js_probe -- javy <module.wasm>
use rquickjs::{CatchResultExt, Context, Module, Runtime};
use wasmtime::*;
use wasmtime_wasi::WasiCtxBuilder;
use wasmtime_wasi::p1::WasiP1Ctx;

fn run_quickjs(path: &str) {
    let src = std::fs::read_to_string(path).unwrap();
    let rt = Runtime::new().unwrap();
    let ctx = Context::full(&rt).unwrap();
    ctx.with(|ctx| {
        let result = Module::evaluate(ctx.clone(), "probe", src).catch(&ctx);
        if let Err(e) = result {
            println!("quickjs: module evaluation failed: {e}");
            return;
        }
        if let Err(e) = result.unwrap().finish::<()>().catch(&ctx) {
            println!("quickjs: module evaluation threw: {e}");
        }
    });
    while rt.is_job_pending() {
        if rt.execute_pending_job().is_err() {
            println!("quickjs: a pending job threw");
        }
    }
    ctx.with(|ctx| {
        let r: Option<String> = ctx.globals().get("__probeResult").unwrap_or(None);
        println!("quickjs: {}", r.unwrap_or_else(|| "no result (probe did not finish)".into()));
    });
}

fn run_javy(path: &str) {
    let engine = Engine::default();
    let module = wasmtime::Module::from_file(&engine, path).unwrap();
    let mut linker: Linker<WasiP1Ctx> = Linker::new(&engine);
    wasmtime_wasi::p1::add_to_linker_sync(&mut linker, |s| s).unwrap();
    let mut store = Store::new(&engine, WasiCtxBuilder::new().inherit_stdout().inherit_stderr().build_p1());
    let instance = linker.instantiate(&mut store, &module).unwrap();
    let start = instance.get_typed_func::<(), ()>(&mut store, "_start").unwrap();
    if let Err(e) = start.call(&mut store, ()) {
        println!("javy: trap or error: {e:?}");
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args[1].as_str() {
        "quickjs" => run_quickjs(&args[2]),
        "javy" => run_javy(&args[2]),
        _ => panic!("unknown engine"),
    }
}
```

`src/bin/component_probe.rs`

```rust
// Runs a ComponentizeJS (StarlingMonkey) component that exports `run: func() -> string`.
// Run: cargo run --release --bin component_probe -- run <component.wasm>
//      cargo run --release --bin component_probe -- instances <component.wasm> <n>
use std::time::Instant;
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Config, Engine, Store};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};
use wasmtime_wasi_http::{WasiHttpCtx, WasiHttpCtxView, WasiHttpView};

struct Ctx {
    wasi: WasiCtx,
    http: WasiHttpCtx,
    table: ResourceTable,
}
impl WasiView for Ctx {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}
impl WasiHttpView for Ctx {
    fn http(&mut self) -> WasiHttpCtxView<'_> {
        WasiHttpCtxView { ctx: &mut self.http, table: &mut self.table, hooks: Default::default() }
    }
}
fn new_ctx() -> Ctx {
    Ctx { wasi: WasiCtxBuilder::new().inherit_stdout().inherit_stderr().build(), http: WasiHttpCtx::new(), table: ResourceTable::new() }
}

fn rss_kib() -> u64 {
    let out = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .unwrap();
    String::from_utf8(out.stdout).unwrap().trim().parse().unwrap()
}

fn linker(engine: &Engine) -> Linker<Ctx> {
    let mut l = Linker::new(engine);
    wasmtime_wasi::p2::add_to_linker_async(&mut l).unwrap();
    wasmtime_wasi_http::p2::add_only_http_to_linker_async(&mut l).unwrap();
    l
}

async fn call_run(store: &mut Store<Ctx>, instance: &wasmtime::component::Instance) -> String {
    let f = instance.get_typed_func::<(), (String,)>(&mut *store, "run").unwrap();
    let (s,) = f.call_async(&mut *store, ()).await.unwrap();
    s
}

async fn run(path: &str) {
    let engine = Engine::new(&Config::new()).unwrap();
    let t0 = Instant::now();
    let component = Component::from_file(&engine, path).unwrap();
    let compile = t0.elapsed();
    let imports: Vec<String> = component.component_type().imports(&engine).map(|(n, _)| n.to_string()).collect();
    println!("imports: {}", imports.join(" "));
    let pre = linker(&engine).instantiate_pre(&component).unwrap();
    let mut store = Store::new(&engine, new_ctx());
    let t1 = Instant::now();
    let instance = pre.instantiate_async(&mut store).await.unwrap();
    let inst = t1.elapsed();
    let t2 = Instant::now();
    let out = call_run(&mut store, &instance).await;
    println!(
        "starlingmonkey: {out}\ncompile_ms={:.0},instantiate_us={:.0},run_ms={:.1}",
        compile.as_secs_f64() * 1e3,
        inst.as_secs_f64() * 1e6,
        t2.elapsed().as_secs_f64() * 1e3
    );
}

async fn instances(path: &str, n: usize) {
    let engine = Engine::new(&Config::new()).unwrap();
    let cwasm = format!("{path}.cwasm");
    std::fs::write(&cwasm, engine.precompile_component(&std::fs::read(path).unwrap()).unwrap()).unwrap();
    // deserialize_file lets Wasmtime map the image copy-on-write on macOS.
    let component = unsafe { Component::deserialize_file(&engine, &cwasm).unwrap() };
    let pre = linker(&engine).instantiate_pre(&component).unwrap();
    let mut keep = Vec::with_capacity(n);
    let base = rss_kib();
    let t0 = Instant::now();
    for _ in 0..n {
        let mut store = Store::new(&engine, new_ctx());
        let instance = pre.instantiate_async(&mut store).await.unwrap();
        let out = call_run(&mut store, &instance).await;
        std::hint::black_box(out);
        keep.push((store, instance));
    }
    let dt = t0.elapsed();
    let rss = rss_kib();
    println!(
        "starlingmonkey_instances,n={n},instantiate_and_run_us={:.1},rss_kib_per_instance={:.1},rss_total_mib={:.1}",
        dt.as_secs_f64() * 1e6 / n as f64,
        (rss - base) as f64 / n as f64,
        rss as f64 / 1024.0
    );
}

async fn repeat(path: &str) {
    let engine = Engine::new(&Config::new()).unwrap();
    let component = Component::from_file(&engine, path).unwrap();
    let pre = linker(&engine).instantiate_pre(&component).unwrap();
    let mut times = vec![];
    let mut last = String::new();
    for _ in 0..9 {
        let mut store = Store::new(&engine, new_ctx());
        let instance = pre.instantiate_async(&mut store).await.unwrap();
        let t = Instant::now();
        last = call_run(&mut store, &instance).await;
        times.push(t.elapsed().as_secs_f64() * 1e3);
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!("{path},median_run_ms={:.1},min_run_ms={:.1},last={last}", times[4], times[0]);
}

async fn calls(path: &str, n: usize) {
    let engine = Engine::new(&Config::new()).unwrap();
    let component = Component::from_file(&engine, path).unwrap();
    let pre = linker(&engine).instantiate_pre(&component).unwrap();
    let mut store = Store::new(&engine, new_ctx());
    let instance = pre.instantiate_async(&mut store).await.unwrap();
    let f = instance.get_typed_func::<(), (String,)>(&mut store, "run").unwrap();
    let t = Instant::now();
    let mut last = String::new();
    for _ in 0..n {
        let (s,) = f.call_async(&mut store, ()).await.unwrap();
        last = s;
    }
    println!("{path},calls={n},us_per_call={:.2},last={last}", t.elapsed().as_secs_f64() * 1e6 / n as f64);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    rt.block_on(async {
        match args[1].as_str() {
            "run" => run(&args[2]).await,
            "repeat" => repeat(&args[2]).await,
            "calls" => calls(&args[2], args[3].parse().unwrap()).await,
            "instances" => instances(&args[2], args[3].parse().unwrap()).await,
            _ => panic!("unknown mode"),
        }
    });
}
```

`buoy-v8-bench/src/main.rs`

```rust
// Costs of embedding V8 through rusty_v8 (the `v8` crate Deno uses): one isolate per actor,
// or one context per actor inside a shared isolate.
// Run: cargo run --release -- isolates <n> | contexts <n>
use std::time::Instant;

const ACTOR_JS: &str = "let count = 0; globalThis.onMessage = (m) => { count += m; return count; }; onMessage(1);";

fn rss_kib() -> u64 {
    let out = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .unwrap();
    String::from_utf8(out.stdout).unwrap().trim().parse().unwrap()
}

fn run_actor_script(scope: &mut v8::PinScope<'_, '_, ()>) -> v8::Global<v8::Context> {
    let context = v8::Context::new(scope, Default::default());
    let scope = &v8::ContextScope::new(scope, context);
    let code = v8::String::new(scope, ACTOR_JS).unwrap();
    let script = v8::Script::compile(scope, code, None).unwrap();
    script.run(scope).unwrap();
    v8::Global::new(scope, context)
}

fn isolates(n: usize) {
    let mut keep = Vec::with_capacity(n);
    let base = rss_kib();
    let t0 = Instant::now();
    for _ in 0..n {
        let mut isolate = v8::Isolate::new(v8::CreateParams::default());
        let ctx = {
            v8::scope!(let scope, &mut isolate);
            run_actor_script(scope)
        };
        keep.push((ctx, isolate));
    }
    let dt = t0.elapsed();
    let rss = rss_kib();
    println!(
        "v8_isolate_per_actor,n={n},create_us={:.0},rss_kib_per_actor={:.0}",
        dt.as_secs_f64() * 1e6 / n as f64,
        (rss - base) as f64 / n as f64
    );
    for (ctx, isolate) in keep.into_iter().rev() {
        drop(ctx);
        drop(isolate);
    }
}

fn contexts(n: usize) {
    let mut isolate = v8::Isolate::new(v8::CreateParams::default());
    v8::scope!(let scope, &mut isolate);
    let mut keep = Vec::with_capacity(n);
    let base = rss_kib();
    let t0 = Instant::now();
    for _ in 0..n {
        keep.push(run_actor_script(scope));
    }
    let dt = t0.elapsed();
    let rss = rss_kib();
    println!(
        "v8_context_per_actor,n={n},create_us={:.0},rss_kib_per_actor={:.0}",
        dt.as_secs_f64() * 1e6 / n as f64,
        (rss - base) as f64 / n as f64
    );
}

fn main() {
    let platform = v8::new_default_platform(0, false).make_shared();
    v8::V8::initialize_platform(platform);
    v8::V8::initialize();
    let args: Vec<String> = std::env::args().collect();
    let n: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(200);
    match args.get(1).map(String::as_str) {
        Some("contexts") => contexts(n),
        _ => isolates(n),
    }
}
```

`buoy-boa-bench/src/main.rs`

```rust
// Costs of embedding Boa (pure-Rust JS engine): workload speed, context per actor, zod probe.
// Run: cargo run --release -- workloads | contexts <n> | probe <bundle.js>
use boa_engine::{js_string, Context, Module, Source};
use std::time::Instant;

const ACTOR_JS: &str = "let count = 0; globalThis.onMessage = (m) => { count += m; return count; }; onMessage(1);";
const FIB_JS: &str = "function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); } fib(27);";
const JSON_JS: &str = r#"let total = 0;
for (let i = 0; i < 20000; i++) {
  const msg = { id: i, role: "assistant", content: "token ".repeat(20), tools: [{ name: "search", args: { q: "x" + i } }] };
  total += JSON.parse(JSON.stringify(msg)).content.length;
}
total;"#;

fn rss_kib() -> u64 {
    let out = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .unwrap();
    String::from_utf8(out.stdout).unwrap().trim().parse().unwrap()
}

fn workloads() {
    for (name, src) in [("fib27", FIB_JS), ("json20k", JSON_JS)] {
        let mut times = vec![];
        for _ in 0..5 {
            let mut ctx = Context::default();
            let t0 = Instant::now();
            ctx.eval(Source::from_bytes(src)).unwrap();
            times.push(t0.elapsed().as_secs_f64() * 1e3);
        }
        times.sort_by(|a, b| a.partial_cmp(b).unwrap());
        println!("boa_workload,{name},median_ms={:.1},min_ms={:.1}", times[2], times[0]);
    }
}

fn contexts(n: usize) {
    let mut keep = Vec::with_capacity(n);
    let base = rss_kib();
    let t0 = Instant::now();
    for _ in 0..n {
        let mut ctx = Context::default();
        ctx.eval(Source::from_bytes(ACTOR_JS)).unwrap();
        keep.push(ctx);
    }
    let dt = t0.elapsed();
    let rss = rss_kib();
    println!(
        "boa_context_per_actor,n={n},create_us={:.0},rss_kib_per_actor={:.0}",
        dt.as_secs_f64() * 1e6 / n as f64,
        (rss - base) as f64 / n as f64
    );
}

fn probe(path: &str) {
    let src = std::fs::read_to_string(path).unwrap();
    let mut ctx = Context::default();
    let module = match Module::parse(Source::from_bytes(src.as_bytes()), None, &mut ctx) {
        Ok(m) => m,
        Err(e) => return println!("boa: parse failed: {e}"),
    };
    let promise = module.load_link_evaluate(&mut ctx);
    let _ = ctx.run_jobs();
    if let boa_engine::builtins::promise::PromiseState::Rejected(e) = promise.state() {
        return println!("boa: module evaluation threw: {}", e.display());
    }
    let r = ctx.global_object().get(js_string!("__probeResult"), &mut ctx).unwrap();
    println!("boa: {}", r.display());
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("contexts") => contexts(args.get(2).and_then(|s| s.parse().ok()).unwrap_or(2000)),
        Some("probe") => probe(&args[2]),
        _ => workloads(),
    }
}
```

### A.4 JavaScript inputs

`node/workloads.mjs`

```js
// Same JS workloads as quickjs_native.rs and the Javy modules, timed in-process.
const fib = (n) => (n < 2 ? n : fib(n - 1) + fib(n - 2));
const json = () => {
  let total = 0;
  for (let i = 0; i < 20000; i++) {
    const msg = {
      id: i,
      role: "assistant",
      content: "token ".repeat(20),
      tools: [{ name: "search", args: { q: "x" + i } }],
    };
    total += JSON.parse(JSON.stringify(msg)).content.length;
  }
  return total;
};
for (const [name, f] of [
  ["fib27", () => fib(27)],
  ["json20k", json],
]) {
  const times = [];
  for (let i = 0; i < 9; i++) {
    const t0 = performance.now();
    f();
    times.push(performance.now() - t0);
  }
  times.sort((a, b) => a - b);
  console.log(
    `node_workload,${process.execArgv.join(" ") || "default"},${name},median_ms=${times[4].toFixed(1)},first_ms=${times[0].toFixed(1)}`,
  );
}
```

`js/fib.js (Javy)`

```js
function fib(n) {
  return n < 2 ? n : fib(n - 1) + fib(n - 2);
}
console.log(fib(27));
```

`js/json.js (Javy)`

```js
let total = 0;
for (let i = 0; i < 20000; i++) {
  const msg = {
    id: i,
    role: "assistant",
    content: "token ".repeat(20),
    tools: [{ name: "search", args: { q: "x" + i } }],
  };
  total += JSON.parse(JSON.stringify(msg)).content.length;
}
console.log(total);
```

`js/idle.js (Javy)`

```js
let count = 0;
globalThis.onMessage = (m) => {
  count += m;
  return count;
};
globalThis.onMessage(1);
```

`js/probe.wit`

```wit
package buoy:probe;

world probe {
  export run: func() -> string;
}
```

`js/idle-component.js`

```js
let count = 0;
export function run() {
  count += 1;
  return String(count);
}
```

`js/fib-component.js`

```js
function fib(n) {
  return n < 2 ? n : fib(n - 1) + fib(n - 2);
}
export function run() {
  const t0 = Date.now();
  const r = fib(27);
  return JSON.stringify({ r, ms: Date.now() - t0 });
}
```

`js/json-component.js`

```js
export function run() {
  const t0 = Date.now();
  let total = 0;
  for (let i = 0; i < 20000; i++) {
    const msg = {
      id: i,
      role: "assistant",
      content: "token ".repeat(20),
      tools: [{ name: "search", args: { q: "x" + i } }],
    };
    total += JSON.parse(JSON.stringify(msg)).content.length;
  }
  return JSON.stringify({ total, ms: Date.now() - t0 });
}
```

`js/intl-component.js`

```js
export function run() {
  let re = "ok";
  try {
    new RegExp("\\p{L}", "u");
  } catch (e) {
    re = String(e);
  }
  return JSON.stringify({
    intl: typeof Intl,
    regexPropertyEscape: re,
    localeCompare: "a".localeCompare("b"),
  });
}
```

`src/zod-probe.js`

```js
import { z } from "zod";
const Message = z.object({
  id: z.number().int(),
  role: z.enum(["user", "assistant"]),
  content: z.string().min(1),
  tools: z
    .array(z.object({ name: z.string(), args: z.record(z.string(), z.unknown()) }))
    .optional(),
});
export async function run() {
  let ok = 0;
  for (let i = 0; i < 1000; i++) {
    const r = Message.safeParse({
      id: i,
      role: i % 2 ? "user" : "assistant",
      content: "hi",
      tools: [{ name: "search", args: { q: "x" } }],
    });
    if (r.success) ok++;
  }
  const bad = Message.safeParse({ id: 1.5, role: "system", content: "" });
  return JSON.stringify({
    probe: "zod@4.6.7",
    ok,
    issues: bad.success ? 0 : bad.error.issues.length,
  });
}
```

`src/ai-probe.js`

```js
import { generateText, streamText } from "ai";
import { MockLanguageModelV4, simulateReadableStream } from "ai/test";
const usage = {
  inputTokens: { total: 3, noCache: 3, cacheRead: 0, cacheWrite: 0 },
  outputTokens: { total: 2, text: 2, reasoning: 0 },
};
const model = new MockLanguageModelV4({
  doGenerate: async () => ({
    content: [{ type: "text", text: "hello" }],
    finishReason: { unified: "stop", raw: "stop" },
    usage,
    warnings: [],
  }),
  doStream: async () => ({
    stream: simulateReadableStream({
      chunks: [
        { type: "text-start", id: "t" },
        { type: "text-delta", id: "t", delta: "hel" },
        { type: "text-delta", id: "t", delta: "lo" },
        { type: "text-end", id: "t" },
        { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage },
      ],
    }),
  }),
});
const report = (o) => JSON.stringify({ probe: "ai@7.0.142", ...o });
export async function run() {
  const steps = [];
  try {
    const g = await generateText({ model, prompt: "hi" });
    steps.push("generateText:" + g.text);
    const s = streamText({ model, prompt: "hi" });
    let text = "";
    for await (const d of s.textStream) text += d;
    steps.push("streamText:" + text);
    return report({ ok: true, steps });
  } catch (e) {
    return report({ ok: false, steps, error: String((e && e.message) || e) });
  }
}
```

`src/openai-probe.js`

```js
import { generateText } from "ai";
import { createOpenAI } from "@ai-sdk/openai";
const body = {
  id: "r1",
  object: "response",
  created_at: 0,
  model: "gpt-x",
  status: "completed",
  output: [
    {
      type: "message",
      id: "m1",
      role: "assistant",
      status: "completed",
      content: [{ type: "output_text", text: "pong", annotations: [] }],
    },
  ],
  usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
};
const report = (o) => JSON.stringify({ probe: "@ai-sdk/openai@4.0.95", ...o });
export async function run() {
  try {
    const openai = createOpenAI({
      apiKey: "test",
      fetch: async () =>
        new Response(JSON.stringify(body), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    });
    const r = await generateText({ model: openai("gpt-x"), prompt: "ping" });
    return report({ ok: r.text === "pong", text: r.text });
  } catch (e) {
    return report({ ok: false, error: String((e && e.message) || e) });
  }
}
```

`src/zod-main.js (same shape for ai and openai)`

```js
import { run } from "./zod-probe.js";
run().then(
  (r) => {
    globalThis.__probeResult = r;
    if (typeof console !== "undefined") console.log(r);
  },
  (e) => {
    globalThis.__probeResult = "threw: " + String((e && e.message) || e);
    if (typeof console !== "undefined") console.log(globalThis.__probeResult);
  },
);
```

`src/zod-component.js (same shape for ai and openai)`

```js
import { run as probe } from "./zod-probe.js";
export async function run() {
  try {
    return await probe();
  } catch (e) {
    return "threw: " + String((e && e.message) || e);
  }
}
```

### A.5 Raw output

`results_wasm_interrupt.csv`

```text
executor,workload,mode,median_ms,min_ms,yields_per_run
noop,loop_sum,None,1081.2,996.1,0
noop,loop_sum,Fuel,1078.6,1046.5,149992
noop,loop_sum,FuelNoYield,1062.1,1032.5,0
noop,loop_sum,Epoch,1043.8,1001.0,837
noop,loop_sum,EpochNoTicks,1085.4,998.3,0
noop,fib,None,57.9,54.1,0
noop,fib,Fuel,121.7,106.2,4831
noop,fib,FuelNoYield,116.6,103.9,0
noop,fib,Epoch,81.1,75.6,60
noop,fib,EpochNoTicks,82.4,75.4,0
noop,javy_fib,None,24.9,23.6,0
noop,javy_fib,Fuel,29.2,26.2,4797
noop,javy_fib,FuelNoYield,28.1,26.2,0
noop,javy_fib,Epoch,31.0,28.6,23
noop,javy_fib,EpochNoTicks,33.0,30.0,0
noop,javy_json,None,101.4,75.5,0
noop,javy_json,Fuel,165.3,149.8,19288
noop,javy_json,FuelNoYield,158.5,134.4,0
noop,javy_json,Epoch,131.1,97.8,109
noop,javy_json,EpochNoTicks,132.9,107.0,0
executor,workload,mode,median_ms,min_ms,yields_per_run
tokio,loop_sum,None,1088.5,1044.7,0
tokio,loop_sum,Fuel,1177.7,1081.1,149992
tokio,loop_sum,FuelNoYield,1125.9,1072.9,0
tokio,loop_sum,Epoch,1125.5,1046.1,875
tokio,loop_sum,EpochNoTicks,1108.5,982.9,0
tokio,fib,None,54.0,48.0,0
tokio,fib,Fuel,112.9,103.3,4831
tokio,fib,FuelNoYield,112.3,104.2,0
tokio,fib,Epoch,78.6,70.3,66
tokio,fib,EpochNoTicks,78.3,69.4,0
tokio,javy_fib,None,23.8,21.0,0
tokio,javy_fib,Fuel,27.5,24.9,4797
tokio,javy_fib,FuelNoYield,26.0,25.0,0
tokio,javy_fib,Epoch,27.9,25.0,21
tokio,javy_fib,EpochNoTicks,29.2,25.1,0
tokio,javy_json,None,101.6,89.0,0
tokio,javy_json,Fuel,164.8,152.0,19288
tokio,javy_json,FuelNoYield,157.8,145.1,0
tokio,javy_json,Epoch,128.4,106.5,104
tokio,javy_json,EpochNoTicks,137.7,119.5,0
executor,workload,mode,median_ms,min_ms,yields_per_run
tokio-io,loop_sum,None,1093.2,1031.7,0
tokio-io,loop_sum,Fuel,3935.1,3264.5,149992
tokio-io,loop_sum,FuelNoYield,1096.7,1032.4,0
tokio-io,loop_sum,Epoch,1118.5,1066.4,884
tokio-io,loop_sum,EpochNoTicks,1071.6,1007.1,0
tokio-io,fib,None,56.2,50.3,0
tokio-io,fib,Fuel,195.8,176.3,4831
tokio-io,fib,FuelNoYield,114.4,110.4,0
tokio-io,fib,Epoch,80.7,75.5,60
tokio-io,fib,EpochNoTicks,79.2,76.4,0
tokio-io,javy_fib,None,23.2,21.6,0
tokio-io,javy_fib,Fuel,112.6,95.1,4797
tokio-io,javy_fib,FuelNoYield,25.9,23.6,0
tokio-io,javy_fib,Epoch,29.0,24.7,22
tokio-io,javy_fib,EpochNoTicks,28.2,24.8,0
tokio-io,javy_json,None,82.9,75.4,0
tokio-io,javy_json,Fuel,487.7,452.7,19288
tokio-io,javy_json,FuelNoYield,137.6,127.1,0
tokio-io,javy_json,Epoch,115.2,94.8,86
tokio-io,javy_json,EpochNoTicks,112.0,89.6,0
```

`results_wasm_actors.csv`

```text
wasm_idle_actors,pool=false,n=10000,spawn_us_per_actor=10.97,rss_kib_per_actor=23.6,rss_total_mib=241.1
wasm_idle_actors,pool=true,n=10000,spawn_us_per_actor=5.67,rss_kib_per_actor=23.6,rss_total_mib=245.0
wasm_pingpong,round_trips=1000000,ns_per_round_trip=1175
javy_quickjs_instances,n=2000,instantiate_and_start_us=46.5,rss_kib_per_instance=233.9,linear_memory_kib=1408,rss_total_mib=563.7
wasm_idle_actors,pool=false,n=10000,spawn_us_per_actor=12.77,rss_kib_per_actor=23.6,rss_total_mib=240.5
wasm_idle_actors,pool=true,n=10000,spawn_us_per_actor=5.38,rss_kib_per_actor=23.6,rss_total_mib=244.9
wasm_pingpong,round_trips=1000000,ns_per_round_trip=1058
javy_quickjs_instances,n=2000,instantiate_and_start_us=53.4,rss_kib_per_instance=234.0,linear_memory_kib=1408,rss_total_mib=562.5
wasm_idle_actors,pool=false,n=10000,spawn_us_per_actor=11.85,rss_kib_per_actor=23.6,rss_total_mib=241.1
wasm_idle_actors,pool=true,n=10000,spawn_us_per_actor=5.96,rss_kib_per_actor=23.6,rss_total_mib=244.9
wasm_pingpong,round_trips=1000000,ns_per_round_trip=1130
javy_quickjs_instances,n=2000,instantiate_and_start_us=50.7,rss_kib_per_instance=233.9,linear_memory_kib=1408,rss_total_mib=560.5
```

`results_native_actors.csv`

```text
tokio_idle_tasks,n=1000000,spawn_ns_per_task=133,rss_bytes_per_task=1112
tokio_pingpong,round_trips=1000000,ns_per_round_trip=563
tokio_pingpong,round_trips=1000000,ns_per_round_trip=109
ractor_idle_actors,n=100000,spawn_ns_per_actor=813,rss_bytes_per_actor=7644
ractor_pingpong,round_trips=1000000,ns_per_round_trip=879
ractor_pingpong,round_trips=1000000,ns_per_round_trip=459
tokio_idle_tasks,n=1000000,spawn_ns_per_task=127,rss_bytes_per_task=1112
tokio_pingpong,round_trips=1000000,ns_per_round_trip=621
tokio_pingpong,round_trips=1000000,ns_per_round_trip=113
ractor_idle_actors,n=100000,spawn_ns_per_actor=849,rss_bytes_per_actor=7644
ractor_pingpong,round_trips=1000000,ns_per_round_trip=1003
ractor_pingpong,round_trips=1000000,ns_per_round_trip=406
tokio_idle_tasks,n=1000000,spawn_ns_per_task=138,rss_bytes_per_task=1112
tokio_pingpong,round_trips=1000000,ns_per_round_trip=477
tokio_pingpong,round_trips=1000000,ns_per_round_trip=126
ractor_idle_actors,n=100000,spawn_ns_per_actor=669,rss_bytes_per_actor=7644
ractor_pingpong,round_trips=1000000,ns_per_round_trip=815
ractor_pingpong,round_trips=1000000,ns_per_round_trip=444
```

`results_pingpong_nodrv.csv`

```text
wasm_pingpong,round_trips=1000000,ns_per_round_trip=661
tokio_pingpong,round_trips=1000000,ns_per_round_trip=90
ractor_pingpong,round_trips=1000000,ns_per_round_trip=398
wasm_pingpong,round_trips=1000000,ns_per_round_trip=699
tokio_pingpong,round_trips=1000000,ns_per_round_trip=84
ractor_pingpong,round_trips=1000000,ns_per_round_trip=523
wasm_pingpong,round_trips=1000000,ns_per_round_trip=646
tokio_pingpong,round_trips=1000000,ns_per_round_trip=87
ractor_pingpong,round_trips=1000000,ns_per_round_trip=384
```

`results_quickjs_native.csv`

```text
quickjs_native_workload,fib27,interrupt_handler=false,median_ms=14.5,min_ms=12.3,handler_calls=0
quickjs_native_workload,fib27,interrupt_handler=true,median_ms=14.0,min_ms=12.3,handler_calls=128
quickjs_native_workload,json20k,interrupt_handler=false,median_ms=68.9,min_ms=62.4,handler_calls=0
quickjs_native_workload,json20k,interrupt_handler=true,median_ms=62.2,min_ms=60.9,handler_calls=11
```

`results_quickjs_preempt.csv`

```text
sequential(cooperative),actors=4,total_ms=1460,finish_ms=[372 739 1094 1460]
preemptive(interrupt+coroutine),actors=4,total_ms=1488,finish_ms=[1487 1488 1488 1488],preemptions=[4001 4001 4001 4001],mean_slice_us=93,overhead_ns_per_switch=1734
sequential(cooperative),actors=4,total_ms=1255,finish_ms=[317 624 938 1255]
preemptive(interrupt+coroutine),actors=4,total_ms=1337,finish_ms=[1337 1337 1337 1337],preemptions=[4001 4001 4001 4001],mean_slice_us=84,overhead_ns_per_switch=5125
sequential(cooperative),actors=4,total_ms=1413,finish_ms=[341 698 1060 1413]
preemptive(interrupt+coroutine),actors=4,total_ms=1402,finish_ms=[1402 1402 1402 1402],preemptions=[4001 4001 4001 4001],mean_slice_us=88,overhead_ns_per_switch=-645
suspended_quickjs_actors,n=5000,spawn_us_per_actor=59.7,rss_kib_per_actor=190.2
suspended_quickjs_actors,n=5000,spawn_us_per_actor=55.5,rss_kib_per_actor=190.2
suspended_quickjs_actors,n=5000,spawn_us_per_actor=53.9,rss_kib_per_actor=190.2
```

`results_starlingmonkey_workloads.csv`

```text
js/fib-sm.wasm,median_run_ms=46.7,min_run_ms=44.5,last={"r":196418,"ms":45}
js/fib-sm-aot.wasm,median_run_ms=29.0,min_run_ms=28.3,last={"r":196418,"ms":28}
js/json-sm.wasm,median_run_ms=31.8,min_run_ms=30.7,last={"total":2400000,"ms":33}
js/json-sm-aot.wasm,median_run_ms=38.1,min_run_ms=35.1,last={"total":2400000,"ms":38}
```

`other runs`

```text
# quickjs_native runtimes 10000 / contexts 10000 / calls 1000000 (three runs)
quickjs_runtime_per_actor,n=10000,create_us=60.6,rss_kib_per_actor=174.0,quickjs_malloc_size_kib=98.9
quickjs_context_per_actor,n=10000,create_us=81.4,rss_kib_per_actor=56.3
quickjs_rust_to_js_call,n=1000000,ns_per_call=40
quickjs_runtime_per_actor,n=10000,create_us=65.6,rss_kib_per_actor=174.0,quickjs_malloc_size_kib=98.9
quickjs_context_per_actor,n=10000,create_us=83.4,rss_kib_per_actor=56.3
quickjs_rust_to_js_call,n=1000000,ns_per_call=36
quickjs_runtime_per_actor,n=10000,create_us=54.2,rss_kib_per_actor=174.0,quickjs_malloc_size_kib=98.9
quickjs_context_per_actor,n=10000,create_us=89.4,rss_kib_per_actor=56.3
quickjs_rust_to_js_call,n=1000000,ns_per_call=41

# extra tokio ping-pong runs: BUOY_RT=nodrv tokio-pingpong, then default tokio-pingpong (three pairs)
tokio_pingpong,round_trips=1000000,ns_per_round_trip=79
tokio_pingpong,round_trips=1000000,ns_per_round_trip=1798
tokio_pingpong,round_trips=1000000,ns_per_round_trip=86
tokio_pingpong,round_trips=1000000,ns_per_round_trip=631
tokio_pingpong,round_trips=1000000,ns_per_round_trip=65
tokio_pingpong,round_trips=1000000,ns_per_round_trip=488

# first single runs of wasm_actors (n=10000 idle, n=1000 javy)
wasm_idle_actors,pool=false,n=10000,spawn_us_per_actor=10.43,rss_kib_per_actor=23.6,rss_total_mib=241.0
wasm_idle_actors,pool=true,n=10000,spawn_us_per_actor=5.19,rss_kib_per_actor=23.6,rss_total_mib=245.0
wasm_pingpong,round_trips=1000000,ns_per_round_trip=924
javy_quickjs_instances,n=1000,instantiate_and_start_us=46.1,rss_kib_per_instance=233.0,linear_memory_kib=1408,rss_total_mib=328.4

# buoy-v8-bench isolates 200 / contexts 2000 (first isolate run panicked at drop after printing; drop order fixed)
v8_isolate_per_actor,n=200,create_us=389,rss_kib_per_actor=1095
v8_isolate_per_actor,n=200,create_us=365,rss_kib_per_actor=1096
v8_context_per_actor,n=2000,create_us=144,rss_kib_per_actor=199
v8_isolate_per_actor,n=200,create_us=416,rss_kib_per_actor=1096
v8_context_per_actor,n=2000,create_us=135,rss_kib_per_actor=199
v8_isolate_per_actor,n=200,create_us=392,rss_kib_per_actor=1096
v8_context_per_actor,n=2000,create_us=144,rss_kib_per_actor=200

# buoy-boa-bench workloads / contexts 2000 (three runs) / probe
boa_workload,fib27,median_ms=68.8,min_ms=66.7
boa_workload,json20k,median_ms=378.0,min_ms=356.8
boa_context_per_actor,n=2000,create_us=272,rss_kib_per_actor=336
boa_context_per_actor,n=2000,create_us=263,rss_kib_per_actor=336
boa_context_per_actor,n=2000,create_us=1550,rss_kib_per_actor=336
boa: "{\"probe\":\"zod@4.6.7\",\"ok\":1000,\"issues\":3}"
boa: module evaluation threw: ReferenceError: TransformStream is not defined (native)
boa: module evaluation threw: ReferenceError: TransformStream is not defined (native)

# node workloads.mjs (label "first_ms" in this output is the minimum of 9 runs)
node_workload,default,fib27,median_ms=1.3,first_ms=1.3
node_workload,default,json20k,median_ms=26.1,first_ms=24.2
node_workload,--jitless,fib27,median_ms=12.6,first_ms=10.8
node_workload,--jitless,json20k,median_ms=30.6,first_ms=29.4

# component_probe instances (StarlingMonkey, componentize-js 0.23.0)
starlingmonkey_instances,n=500,instantiate_and_run_us=299.9,rss_kib_per_instance=1688.4,rss_total_mib=1428.2
starlingmonkey_instances,n=500,instantiate_and_run_us=327.0,rss_kib_per_instance=1669.7,rss_total_mib=1420.5
starlingmonkey_instances,n=500,instantiate_and_run_us=263.1,rss_kib_per_instance=1668.8,rss_total_mib=1414.1
starlingmonkey_instances,n=200,instantiate_and_run_us=15360.3,rss_kib_per_instance=4608.4,rss_total_mib=1504.1

# component_probe calls js/idle-component.wasm 100000 (three runs)
js/idle-component.wasm,calls=100000,us_per_call=5.78,last=100000
js/idle-component.wasm,calls=100000,us_per_call=5.49,last=100000
js/idle-component.wasm,calls=100000,us_per_call=5.65,last=100000

# npm probes
quickjs: {"probe":"zod@4.6.7","ok":1000,"issues":3}
quickjs: module evaluation threw: Error: TransformStream is not defined
quickjs: module evaluation threw: Error: TransformStream is not defined
javy zod: {"probe":"zod@4.6.7","ok":1000,"issues":3}
javy ai: Error: TransformStream is not defined ... wasm trap: wasm `unreachable` instruction executed
javy openai: Error: TransformStream is not defined ... wasm trap: wasm `unreachable` instruction executed
starlingmonkey intl-component.wasm: {"intl":"undefined","regexPropertyEscape":"SyntaxError: invalid property name in regular expression","localeCompare":-1}
starlingmonkey zod-component.wasm: {"probe":"zod@4.6.7","ok":1000,"issues":3} compile_ms=835,instantiate_us=1388,run_ms=24.2
jco componentize ai-component.js: SyntaxError: invalid class property name in regular expression: [\p{L}\p{N}]+ (ai-component.js:15783:76)
starlingmonkey ai-component-patched.wasm: {"probe":"ai@7.0.142","ok":true,"steps":["generateText:hello","streamText:hello"]} compile_ms=570,instantiate_us=1610,run_ms=6.4
starlingmonkey openai-component-patched.wasm: {"probe":"@ai-sdk/openai@4.0.95","ok":true,"text":"pong"} compile_ms=603,instantiate_us=1874,run_ms=8.3
starlingmonkey zod-bundled-sm.wasm (jco --bundle): {"probe":"zod@4.6.7","ok":1000,"issues":3}
jco componentize --bundle ai-component.js: Error: attempted to call an unknown imported function: 'jco:node/os@0.1.0' 'platform'. You cannot call arbitrary imported functions during Wizer initialization.
jco componentize --backend quickjs --bundle ai-component.js: error while executing at wasm backtrace ... adapter platform
component_probe run zod-bundled-qjs.wasm: component imports instance `jco:node/http@0.1.0`, but a matching implementation was not found in the linker
LLRT v0.9.0-beta zod: {"probe":"zod@4.6.7","ok":1000,"issues":3}
LLRT v0.9.0-beta ai: {"probe":"ai@7.0.142","ok":true,"steps":["generateText:hello","streamText:hello"]}
LLRT v0.9.0-beta openai: {"probe":"@ai-sdk/openai@4.0.95","ok":true,"text":"pong"}
node zod: {"probe":"zod@4.6.7","ok":1000,"issues":3}
node ai: {"probe":"ai@7.0.142","ok":true,"steps":["generateText:hello","streamText:hello"]}
node openai: {"probe":"@ai-sdk/openai@4.0.95","ok":true,"text":"pong"}
porffor fib.js: 196418 1
porffor zod: {"probe":"zod@4.6.7","ok":1000,"issues":3}
porffor ai, first run: (no output)
porffor openai, first run: (no output)
porffor ai, rerun default: exit=139
porffor ai, rerun --event-loop: exit=139
porffor openai, rerun default: exit=139
```

## Implications for Buoy

1. **Drop B without an embedded engine.** No ahead-of-time compiler here runs the AI SDK. The projects that run real npm code natively each add a runtime layer for Web or Node APIs: hermes-node for Static Hermes and a server runtime for Porffor (Section 6). A Buoy compiler can still emit faster code for typed actor modules later. It cannot replace a JS engine for `node_modules`.
2. **Keep Tokio for I/O and timers, and add preemption in the engine.** Tokio's budget counts I/O readiness and cannot stop a JS loop. JS preemption must come from the engine: the QuickJS-ng interrupt handler with a coroutine per actor, or Wasmtime epochs. Model the time slice on BEAM reductions: the QuickJS prototype gave 84 to 93 µs slices and Lunatic used 100,000 units of fuel.
3. **If Buoy builds its own Rust runtime (option B), start from QuickJS-ng through rquickjs.** A preemptible actor costs 190.2 KiB and 54 to 60 µs, the lowest JS cost measured here except shared-runtime contexts. Reuse `llrt_modules` for Web APIs, because LLRT on the same engine passed all three probes. Keep the engine behind a small host interface, so V8 can serve CPU-heavy actors where JIT speed matters (1.3 ms against 14.5 ms on `fib(27)`).
4. **Use D4 where isolation matters more than density.** A StarlingMonkey actor costs 1.6 MiB, but a trap or runaway loop stays inside its instance and epochs can stop it at any loop. That fits sandboxed tool execution and model-generated code. It does not fit the default actor at 10,000 actors per node.
5. **Define the actor protocol once, independent of the host.** Write spawn, send, receive, link, monitor, and exit as one interface, shaped so it maps to WIT. The same actor code can then run in-process (option B or C) or in a Wasm sandbox (D4). Placement becomes a deployment choice.
6. **Copy messages, as the BEAM does.** Every isolated design measured here (QuickJS runtimes, V8 isolates, Wasm instances) has separate heaps. Define messages as structured-clone data, validate them with zod at the actor boundary, and give large binaries a host-owned, reference-counted buffer, the analogue of BEAM refc binaries. Measure serialization cost before fixing the message format (Section 9).
7. **Budget memory per actor explicitly.** From the measured per-actor resident memory, 10,000 idle actors need about: Tokio tasks 11 MiB, BEAM processes 25 MiB (from the cited 327 words), QuickJS-ng contexts 550 MiB, preemptible QuickJS-ng runtimes 1.8 GiB, V8 contexts 1.9 GiB, Javy instances 2.2 GiB, V8 isolates 10.5 GiB, StarlingMonkey instances 16.1 GiB. A two-tier design (many cheap contexts, fewer isolated runtimes) keeps most agents in the cheap tier.
8. **Prefer epochs for time slicing and keep fuel for determinism.** Epochs cost 0 to 42% extra run time and fuel 0 to 101% here. Fuel makes runs repeatable, which helps record-and-replay tests of supervision.
9. **Keep the yield path cheap.** A preemption that returned to an executor which polled kqueue cost about 19 µs per yield. One that did not cost about 0.1 to 0.35 µs. The scheduler should resume the next ready actor without a driver poll on every slice.
10. **Do not build on Lunatic or bastion.** Lunatic's last release is from 2023-05-03 and bastion's from 2022-01-07. ractor, kameo, and ractor-supervisor are active and show how to express OTP supervision in Rust.
11. **Turn the probes into repository tests.** AGENTS.md requires each npm compatibility claim to name the package, the version, and the test. Move the three probes and the Appendix A harness into `tests/` and `bench/`. Rerun them when StarlingMonkey gains `Intl` (issue #45), when ComponentizeJS supports WASI 0.3 async exports, and when Porffor implements client `fetch()`.
