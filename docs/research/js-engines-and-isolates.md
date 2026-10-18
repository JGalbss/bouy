# JavaScript engines and isolates as actor substrates

> Paths under `packages/`, `e2e/`, `examples/`, and `bench/` refer to commit [`90529d8`](https://github.com/JGalbss/bouy/tree/90529d8), the last commit with the Node runtime.

This note is the "engines" track of the architecture decision. It evaluates three options:

- **C**: TypeScript compiles to JavaScript that runs on V8 or JavaScriptCore. Node, Deno, or Bun hosts many lightweight actors in one isolate.
- **D1**: a Node host runs a pool of worker-thread schedulers. Each worker runs many lightweight actors (M:N).
- **D2**: a Rust host embeds several V8 isolates and uses them as schedulers.

The note covers V8 isolates and contexts, Cloudflare Workers and workerd, Node.js, isolated-vm, ShadowRealm, Deno, Bun, and JavaScriptCore. It ends with scores on the nine criteria and a section named "Implications for Buoy".

Date: 2026-10-16. Machine: Apple M5 Pro, 18 cores, 64 GiB of memory, macOS 26.6.1 (Darwin 25.6.0).

## Summary

1. **Hard isolation per actor costs 3 to 4 orders of magnitude more memory than soft isolation.** A lightweight actor in one isolate costs about 754 bytes of V8 heap on Node and 400 to 600 bytes on Bun. A bare V8 isolate costs about 1 MiB of RSS, or about 0.77 MiB with pointer compression. A Node worker thread costs about 7.96 MiB when idle and about 23.7 MiB after it loads `zod`, `ai`, and `@ai-sdk/openai`.
2. **One isolate gives no fault isolation between actors beyond caught errors.** One actor's prototype pollution made `z.object()` throw a `TypeError` for every other actor on Node and Bun. One actor's heap growth aborted the whole Node process with exit code 134. zod's global registry and the AI SDK's default provider live on `globalThis`, so all actors share them.
3. **Engine termination stops whole isolates, and it misses some loops.** V8's `TerminateExecution` drops every queued microtask of the isolate, so other actors lose work. On V8 13.6, 14.1, and 15.0, a TurboFan-optimized loop that calls no function and allocates a fixed-length array ignored termination for more than 5 s; rusty_v8 issue #2088 reports the same gap. Deno 2.9.7 and Bun 1.3.11 did not stop a spinning worker at all. Node 25.9 and Bun 1.4.3 did.
4. **A Node worker is a usable fault domain.** A worker that exceeds `resourceLimits` ends with `ERR_WORKER_OUT_OF_MEMORY`, and the main thread keeps running. Bun ignores `resourceLimits`.
5. **Cloudflare runs thousands of tenant isolates per process and stops them on a CPU budget.** A per-thread CPU timer sends a signal, and the handler calls `TerminateExecution`. I found no published mechanism that time-slices isolates. The open-source workerd enforces no CPU or memory limits.

## How to read the numbers

- **Measured numbers** name their script and command. Appendix A holds every script. The batch script `run-all.sh` ran its measurements 3 times; a number written as "median (lowest–highest)" comes from that batch. Other numbers come from single runs of the named script.
- **Load.** Other agents ran benchmarks and builds on this machine at the same time. The 1-minute load average was between 15.8 and 42.8 on 18 cores during the batch. Treat times as upper bounds. Memory numbers moved less between runs.
- **Binaries.** `node` means the official Node v25.9.0 binary from `nodejs.org` (V8 14.1.146.11-node.25), checked against `SHASUMS256.txt`. The Homebrew Node v25.9.0 on this machine reports `node_use_node_snapshot=false` and `node_shared=true` in `process.config.variables`; the official build reports `node_use_node_snapshot=true`. Other runtimes: Node v24.2.0 (official build through nvm, V8 13.6.233.10), Bun 1.3.11, and the rusty_v8 crate `v8` 150.4.0 (V8 15.0.245.2-rusty).
- **Docker.** Docker 29.4 ran Deno 2.9.7, Bun 1.4.3, and Node 25.9.0 in a Linux arm64 virtual machine with 18 vCPUs and 16 GiB. Compare Docker rows only with other Docker rows.
- **Quoted numbers** name their source and date. The sources did not state hardware unless the text says so. The scripts live outside `bench/` because this track may edit only this file, and `AGENTS.md` asks that performance claims cite `bench/` outputs. Moving Appendix A into `bench/evidence/` closes that gap. The section "Implications for Buoy" at the end lists the design consequences.

## 1. V8 isolates, contexts, and isolate groups

### 1.1 Terms

- An **isolate** is one V8 engine instance with its own heap. "An isolate can be entered by at most one thread at any given time" ([v8-isolate.h](https://github.com/v8/v8/blob/main/include/v8-isolate.h)).
- A **context** is a realm: a global object with its own built-ins. All contexts of an isolate share its heap and its thread.
- An **isolate group** owns one pointer-compression cage and one sandbox. "With pointer compression enabled, total heap usage of isolates in a group cannot exceed 4 GB, not counting array buffers and other off-heap storage" ([v8-isolate.h](https://github.com/v8/v8/blob/main/include/v8-isolate.h)).

### 1.2 Memory floor and creation time

Command: `target/release/isolate-cost isolates 200` and `isolate-cost contexts 1000` (Appendix A, `rusty/src/main.rs`). The `ptrcomp` rows use the same program built with the crate feature `v8_enable_pointer_compression`, which links the prebuilt `librusty_v8_ptrcomp_release` archive.

| Unit (rusty_v8, V8 15.0)                          | Creation time (p50)    | Memory                                             |
| ------------------------------------------------- | ---------------------- | -------------------------------------------------- |
| Isolate                                           | 0.215 (0.214–0.234) ms | 1,080 KiB RSS per isolate with one context         |
| First context plus a one-line script              | 0.172 (0.170–0.190) ms | 212 KiB of used heap per isolate after the script  |
| Extra context in one isolate                      | 149 (146–158) µs       | 211 (210–211) KiB RSS per context                  |
| Isolate, pointer compression                      | 0.200 (0.191–0.202) ms | 789 (788–789) KiB RSS per isolate with one context |
| Extra context in one isolate, pointer compression | 134 (132–137) µs       | 117 KiB RSS per context                            |

The default heap limit of each isolate was 1,496 MiB.

Published numbers agree in order of magnitude:

- Cloudflare, 2018: "Isolates start in 5 milliseconds". A runtime shared by all isolates drops the memory cost "to around 3 MB" per isolate, against 35 MB for "a basic Node Lambda running no real code" ([Cloud Computing without Containers](https://blog.cloudflare.com/cloud-computing-without-containers/), 2018-11-09).
- Cloudflare, 2026: "An isolate takes a few milliseconds to start and uses a few megabytes of memory" ([Dynamic Workers](https://blog.cloudflare.com/dynamic-workers/), 2026-03-24).
- V8, 2015: a startup snapshot cuts context creation "from 40 ms down to less than 2 ms" on "a regular desktop computer" ([Custom startup snapshots](https://v8.dev/blog/custom-startup-snapshots), 2015-09-25).

### 1.3 Pointer compression, cages, and isolate groups

- Pointer compression requires that "all V8 objects are allocated within a 4-GB memory range". V8 reported heap savings of "up to 43%" in Chrome on Windows 10 ([Pointer Compression in V8](https://v8.dev/blog/pointer-compression), 2020-03-30).
- Before isolate groups, "all isolates in a process had to be one single sandbox", which "would have limited the total size of all V8 heaps to be less than 4 GiB" ([Safe in the sandbox](https://blog.cloudflare.com/safe-in-the-sandbox-security-hardening-for-cloudflare-workers/)). Igalia, paid by Cloudflare, added `v8::IsolateGroup`, "a new unit that owns an independent pointer-compression cage", then multiple cages per process and one sandbox per group ([Igalia 2025 retrospective](https://blogs.igalia.com/compilers/2026/02/06/igalia-s-compilers-team-a-2025-retrospective/), 2026-02-06).
- Cloudflare now gives each Worker isolate its own group. "Each sandbox reserves 8 GiB of space in the virtual memory map of the process", and Cloudflare currently puts "a single isolate in each sandbox" ([Safe in the sandbox](https://blog.cloudflare.com/safe-in-the-sandbox-security-hardening-for-cloudflare-workers/), 2025-09-25). workerd PR [#7445](https://github.com/cloudflare/workerd/pull/7445) uses "fresh isolate groups when available".
- The V8 sandbox reserves "one terabyte" of virtual address space and costs "around 1% or less on typical workloads" on Speedometer and JetStream ([The V8 Sandbox](https://v8.dev/blog/sandbox), 2024-04-04).
- Node added isolate-group support in [nodejs/node#60254](https://github.com/nodejs/node/pull/60254) (merged 2025-10-17, released in v25.1.0). The PR keeps pointer compression off by default because it "may be too breaking for some workloads". Both Node 25.9.0 builds on this machine report `v8_enable_pointer_compression=0`.
- Platformatic's `node-caged` image enables pointer compression and reports "about 50% less memory" for a Next.js server on AWS m5.2xlarge, with a 2.5% to 4.2% rise in average latency. Addons built on NAN do not work; Node-API addons do ([We cut Node.js' memory in half](https://blog.platformatic.dev/we-cut-nodejs-memory-in-half), undated; it describes work that landed in October 2025).
- rusty_v8 downloads an archive without pointer compression by default. Its build script appends `_ptrcomp` to the archive name only when the feature `v8_enable_pointer_compression` is on (`build.rs` of crate `v8` 150.4.0). The README marks `v8_enable_multi_cage` as experimental, and it needs `V8_FROM_SOURCE=1` ([rusty_v8](https://github.com/denoland/rusty_v8)). Crate 150.4.0 has no `IsolateGroup` binding; a search of its `src/` finds none. The binding landed later: [PR #2060](https://github.com/denoland/rusty_v8/pull/2060) ("feat: isolate groups") merged into `main` on 2026-09-02. The latest release, v152.2.0 (2026-08-20), predates it and has no `src/isolate_group.rs`, so no released crate exposes isolate groups on 2026-10-16.
- Deno enables only the `simdutf` feature of its V8 crate ([Deno Cargo.toml](https://github.com/denoland/deno/blob/main/Cargo.toml)), so Deno runs without pointer compression.

### 1.4 Termination and interrupts

The V8 API offers two cross-thread controls ([v8-isolate.h](https://github.com/v8/v8/blob/main/include/v8-isolate.h)):

- `TerminateExecution()`: "Forcefully terminate the current thread of JavaScript execution in the given isolate. This method can be used by any thread even if that thread has not acquired the V8 lock". The isolate cannot run again "until all JavaScript frames have propagated the uncatchable exception". `CancelTerminateExecution()` re-enables it.
- `RequestInterrupt(callback, data)`: "Request V8 to interrupt long running JavaScript code and invoke the given |callback|". It "Can be called from another thread without acquiring a |Locker|".

Measured in the rusty_v8 probe (`isolate-cost terminate 10 'for (;;) {}'` and `isolate-cost interrupt`):

| Operation                                      | Latency                                                |
| ---------------------------------------------- | ------------------------------------------------------ |
| `TerminateExecution` on `for (;;) {}`, 10 runs | p50 0.026 (0.025–0.027) ms, max 0.045 (0.034–0.122) ms |
| `RequestInterrupt` callback on `for (;;) {}`   | 14.3 (9.60–20.2) µs                                    |

Three gaps matter for an actor runtime.

**Gap 1: some optimized loops never see the request.** Termination and interrupts take effect only where generated code checks for them. Some loops that TurboFan optimized never responded. These loops call no function, and they allocate a fixed-length array:

```js
// L1: fixed-length allocation
(() => {
  const sink = [];
  for (let n = 0; ; n++) sink[n & 1023] = new Array(64);
})();
// L2: fixed-length allocation plus fill
for (let n = 0; ; n++) sink[n & 1023] = new Array(1024).fill({ n });
```

| Host and engine                       | Loop and trigger                                                | Result                                                                                                          |
| ------------------------------------- | --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Node 25.9.0, V8 14.1, macOS and Linux | L1 with lengths 8 to 100,000; `worker.terminate()` after 300 ms | Lengths 64 to 2,048 not stopped in 3 s. Lengths 8 and 16,000 stopped in 1 to 8 ms (`terminate-const-sizes.mjs`) |
| Node 24.2.0, V8 13.6                  | L1 with length 1,024; `worker.terminate()`                      | Not stopped in 5 s (`terminate-matrix.mjs`)                                                                     |
| Node 25.9.0                           | L1 with the length read at run time from `workerData`           | Stopped in 0.9 to 113 ms (`terminate-sizes.mjs`)                                                                |
| Node 25.9.0                           | L2; `worker.terminate()`, default flags or `--no-maglev`        | Not stopped in 3 s (`terminate-fill.mjs`)                                                                       |
| Node 25.9.0                           | L2; `worker.terminate()` with `--no-turbofan` or `--jitless`    | Stopped in 8 to 62 ms (`terminate-fill.mjs`)                                                                    |
| Node 25.9.0                           | L2 that keeps every array; worker heap limit of 32 MB           | No `ERR_WORKER_OUT_OF_MEMORY`. RSS reached about 1 GB in 5 s (`oom-debug2.mjs ./hog-worker.mjs`)                |
| Node 25.9.0, main thread              | L1; inspector `Runtime.terminateExecution` after 50 ms          | Not stopped; the process ran until the 8 s alarm (`main-inspector-alloc2.mjs 50`)                               |
| Node 24.2.0, isolated-vm 6.2.0        | L1; `timeout: 100`                                              | Not stopped in 5 s (`ivm-alloc-timeout.mjs`)                                                                    |
| rusty_v8, V8 15.0                     | L1; `terminate_execution()` after 300 ms                        | Not stopped in 5 s. With `V8_FLAGS=--no-turbofan`, stopped in 0.03 ms                                           |
| Bun 1.4.3, JavaScriptCore (Docker)    | L1 with lengths 8 to 100,000; `worker.terminate()`              | All stopped, in 3 to 709 ms                                                                                     |

L1 with an `Atomics.add` call in its body stopped normally on Node (`terminate-counter.mjs`). A `node:vm` timeout also stopped L1 when the code ran inside a vm context (`vm-local-alloc.mjs`, `worker-vm-alloc.mjs`). The rusty_v8 issue [#2088](https://github.com/denoland/rusty_v8/issues/2088) (opened 2026-10-06, open, no maintainer reply) reports the same gap for loops that call `Array.prototype.fill`, with the same flag results. Root cause: unverified. A V8 bug report with the scripts above would confirm it.

**Gap 2: termination drops other actors' microtasks.** When termination interrupts `MicrotaskQueue::RunMicrotasks`, V8 deletes the ring buffer and sets `size_ = 0` ([microtask-queue.cc](https://github.com/v8/v8/blob/main/src/execution/microtask-queue.cc)). `preempt-inspector-order.mjs` queued two microtasks after a runaway microtask on Node's main thread. After termination, neither ran, and a later timer did run. In a single-isolate actor runtime, killing one actor this way silently loses pending promise reactions of other actors.

**Gap 3: Node does not support termination of main-thread callbacks.** `preempt-inspector-plain.mjs timer` stopped a runaway timer callback through `inspector.Session.connectToMainThread()` and `Runtime.terminateExecution`. Node then aborted with `Error: async hook stack has become corrupted (actual: 14, expected: 0)` and exit code 1. The same request against a microtask let the process continue.

### 1.5 Heap limits

- `ResourceConstraints` sets the old and young generation sizes. If garbage collection does not help "and the callback does not increase the limit, then V8 will crash with V8::FatalProcessOutOfMemory" ([v8-isolate.h](https://github.com/v8/v8/blob/main/include/v8-isolate.h)).
- `AddNearHeapLimitCallback` runs "when the heap size is close to the heap limit". The callback "can extend the heap limit by returning a value that is greater than the current_heap_limit" ([v8-callbacks.h](https://github.com/v8/v8/blob/main/include/v8-callbacks.h)). An embedder can raise the limit a little, then terminate the isolate, which is what Node does for workers.
- Node's worker callback adds 16 MiB "to let it finish rather than crash hard" and calls `Worker::Exit` with `ERR_WORKER_OUT_OF_MEMORY` ([node_worker.cc v25.9.0](https://github.com/nodejs/node/blob/v25.9.0/src/node_worker.cc)). `Exit` calls `TerminateExecution` ([env.cc v25.9.0](https://github.com/nodejs/node/blob/v25.9.0/src/env.cc)), so Gap 1 also defeats the heap limit.
- Measured: a worker with `maxOldGenerationSizeMb: 32` that allocates small objects ended with `ERR_WORKER_OUT_OF_MEMORY` after 34 to 169 ms on Node 25.9.0 (official and Homebrew) and Node 24.2.0. The main thread kept running at 84 to 99 MiB RSS (`oom-debug2.mjs`, `oom-debug2.mjs ./hog-worker3.mjs`).
- Measured: the same allocation in one isolate with `--max-old-space-size=64` printed `FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory` and exited with code 134. The `exit` handler did not run (`oom-single.mjs`). Every actor in that isolate dies.

### 1.6 Startup snapshots

- `CreateParams::snapshot_blob` starts an isolate from a serialized heap. "The embedder _must_ ensure that the snapshot is from a trusted source" ([v8-isolate.h](https://github.com/v8/v8/blob/main/include/v8-isolate.h)).
- A bare isolate plus its first context took 0.215 ms plus 0.172 ms. A Node worker took 21.9 ms to its first message. Node's environment bootstrap, module loader, and thread start take most of the worker time. I did not profile the split.
- The official Node build (with the built-in snapshot) and the Homebrew build (without it) spawned workers at similar speed: 21.9 (19.0–29.9) ms against 21.0 (19.4–22.8) ms. The official build used more memory per worker: 7.96 MiB against 6.42 MiB.

## 2. Cloudflare Workers and workerd

**Isolate per tenant.** "In Cloudflare Workers, tenants are isolated from each other using V8 isolates — not processes nor VMs" ([Workers security model](https://developers.cloudflare.com/workers/reference/security-model/)). "A single instance of the runtime can run hundreds or thousands of isolates" ([How Workers works](https://developers.cloudflare.com/workers/reference/how-workers-works/)). Cloudflare adds process-level layers. It runs several runtime instances per machine, called cordons, and it can move a suspicious Worker "into its own process". With strict process isolation, "the CPU cost can easily be 10x what it is with a shared process" ([Mitigating Spectre](https://blog.cloudflare.com/mitigating-spectre-and-other-security-threats-the-cloudflare-workers-security-model/), 2020-07-29).

**Published limits** ([Workers limits](https://developers.cloudflare.com/workers/platform/limits/), page read 2026-10-16):

- "Each isolate can consume up to 128 MB of memory, including the JavaScript heap and WebAssembly allocations." Above that, the runtime "lets in-flight requests complete and creates a new isolate for subsequent requests".
- CPU time per HTTP request: 10 ms on the Free plan; 30 s by default and 5 min at most on the Paid plan.
- "A Worker must parse and execute its global scope ... within 1 second."
- "A single isolate can handle many concurrent requests."

**Preemption.** Workers stop code when it exceeds a CPU budget. I found no published mechanism that time-slices isolates. Kenton Varda wrote: "The enforced limit is strictly on CPU time, not wall time. We use Linux's timer_create() with CLOCK_THREAD_CPUTIME_ID to set a timer that delivers a signal", and "The signal handler immediately terminates execution of JavaScript using V8's TerminateExecution()" ([Hacker News](https://news.ycombinator.com/item?id=27751649), 2021-07-06). In workerd, `IsolateLimitEnforcer::exitJs()` "Returns true if the isolate has exceeded limits and become condemned" ([limit-enforcer.h](https://github.com/cloudflare/workerd/blob/main/src/workerd/io/limit-enforcer.h)). For memory, the limits page says the runtime "creates a new isolate for subsequent requests".

**Open-source workerd enforces no limits.** `NullIsolateLimitEnforcer` returns empty `CreateParams` and no-op `enterStartupJs`, and `NullLimitEnforcer::enterJs` and `topUpActor` do nothing ([worker-factory.c++ at c91a263](https://github.com/cloudflare/workerd/blob/c91a26392b27f2f0ba657271e614ba4358342282/src/workerd/server/factory/worker-factory.c%2B%2B), 2026-10-14). The README warns: "`workerd` is not a hardened sandbox" ([workerd](https://github.com/cloudflare/workerd)).

**Durable Objects** are the closest production analogue of an actor. "Each Durable Object instance can be seen as an Actor instance", and they "are single-threaded and cooperatively multi-tasked" ([What are Durable Objects](https://developers.cloudflare.com/durable-objects/concepts/what-are-durable-objects/)). Two gates make interleaving safe ([Durable Objects: Easy, Fast, Correct](https://blog.cloudflare.com/durable-objects-easy-fast-correct-choose-three/), Kenton Varda, 2021-08-03):

- Input gate: "While a storage operation is executing, no events shall be delivered to the object except for storage completion events."
- Output gate: "any new outgoing network messages will be held back until the write has completed." If the write fails, the messages "will be discarded and replaced with errors".

The gates give an actor turn atomicity across `await` without locks. Buoy can copy this rule for actor state that persists.

## 3. Node.js

### 3.1 worker_threads

Command: `node --expose-gc worker-cost.mjs 50`, `bun worker-cost.mjs 50`, and the same with `--agent`, which makes each worker import `zod`, `ai`, and `@ai-sdk/openai` first.

| Runtime                                           | Spawn to first message (p50, ms) | RSS per worker (MiB) |
| ------------------------------------------------- | -------------------------------- | -------------------- |
| Node 25.9.0 official, idle worker                 | 21.9 (19.0–29.9)                 | 7.96                 |
| Node 25.9.0 Homebrew, idle worker                 | 21.0 (19.4–22.8)                 | 6.42                 |
| Bun 1.3.11, idle worker                           | 6.27 (4.79–7.19)                 | 4.74 (4.70–4.75)     |
| Node 25.9.0 official, worker loads agent packages | 132 (122–138)                    | 23.7 (23.6–23.7)     |
| Bun 1.3.11, worker loads agent packages           | 69.2 (52.7–75.4)                 | 23.2 (22.8–23.6)     |
| Docker: Node 25.9.0, idle worker                  | 22.1 (21.3–27.1)                 | 8.00 (7.98–8.01)     |
| Docker: Deno 2.9.7, idle Web Worker               | 8.69 (7.31–9.63)                 | 5.42 (5.37–5.42)     |

`await worker.terminate()` on an idle Node worker took 0.910 (0.539–1.78) ms (p50). Bun's `smol: true` worker option did not change RSS per worker in a separate run (4.74 MiB both ways). The sibling note [measurements-node.md](measurements-node.md) measured the Homebrew build with a different script and reports 6.29 MiB per worker, which matches the Homebrew row.

Documented behavior ([worker_threads](https://nodejs.org/docs/latest-v25.x/api/worker_threads.html)):

- "Workers (threads) are useful for performing CPU-intensive JavaScript operations. They do not help much with I/O-intensive work." The page also says: "In practice, use a pool of Workers ... Otherwise, the overhead of creating Workers would likely exceed their benefit."
- `resourceLimits` sets `maxOldGenerationSizeMb`, `maxYoungGenerationSizeMb`, `codeRangeSizeMb`, and `stackSizeMb`. The limits "only affect the JS engine, and no external data, including no `ArrayBuffer`s". "the process may still abort if it encounters a global out-of-memory situation."
- An uncaught exception in a worker emits `'error'` on the `Worker` object, and "the worker is terminated". In a worker, `process.exit()` "does not stop the whole program, just the single thread".
- Signals are not delivered to workers through `process.on(...)`, `process.chdir()` is unavailable, and `process.env` is a copy.
- `worker.getHeapStatistics()` (v24.0.0) and `worker.cpuUsage()` (v24.6.0) let a parent watch a worker. Both answered within 1 s while a worker spun in `for (;;) {}` (`watch-spinning.mjs`). In the Gap 1 heap test, `getHeapStatistics()` never answered (`oom-debug.mjs`).
- libuv's threadpool "is global and shared across all event loops", with a default size of 4 ([libuv threadpool](https://docs.libuv.org/en/v1.x/threadpool.html)). File system, DNS, and some crypto work from all workers share those 4 threads.

### 3.2 Messages between workers

`port.postMessage()` uses the HTML structured clone algorithm. "object prototypes are not preserved", and "instances of JavaScript classes will be cloned as plain JavaScript objects". Functions cannot be cloned ([worker_threads](https://nodejs.org/docs/latest-v25.x/api/worker_threads.html)). My first in-isolate benchmark passed a mailbox object inside a cloned message. The clone arrived as a plain object, and the reply failed with `TypeError: mailbox.push is not a function`. An actor reference must be a handle that the runtime resolves, such as a numeric id.

Command: `node message-cost.mjs 64`, `node message-cost.mjs 4096`, and the same with `bun`. Round trip means one request and one reply between two actors.

| Path                                               | Node 25.9.0, 64 B body        | Bun 1.3.11, 64 B body           | Node 25.9.0, 4 KiB body   |
| -------------------------------------------------- | ----------------------------- | ------------------------------- | ------------------------- |
| In one isolate, no copy: round trip (µs)           | 0.222 (0.181–0.270)           | 0.182 (0.167–0.372)             | 0.226 (0.226–0.284)       |
| In one isolate, `structuredClone`: round trip (µs) | 2.54 (2.04–3.12)              | 2.56 (2.42–4.07)                | 3.48 (3.23–4.12)          |
| In one isolate, `structuredClone`: one-way (msg/s) | 1,234,231 (947,824–1,337,043) | 2,938,877 (1,611,576–3,358,957) | 432,004 (269,117–467,759) |
| Worker `MessagePort`: round trip (µs)              | 27.3 (16.6–27.7)              | 23.7 (18.3–76.5)                | 39.9 (34.7–76.5)          |
| Worker `MessagePort`: one-way (msg/s)              | 1,148,855 (782,240–1,338,678) | 2,107,939 (1,242,679–2,255,560) | 647,021 (250,868–651,990) |

Bun with a 4 KiB body: in-isolate round trip with `structuredClone` 7.97 (7.79–46.6) µs, worker round trip 57.6 (28.2–126) µs, worker one-way 1,549,530 (696,561–1,586,314) msg/s. Bun documents fast paths: a pure string skips structured clone, and simple objects store "properties directly without full structured cloning" ([Bun workers](https://bun.com/docs/runtime/workers)).

A mailbox queue must not use `Array.prototype.shift()`. On Node 25.9.0, draining 100,000 items with `shift()` took 4,218 ms. Draining 10,000 items took 0.62 ms, and an index-based drain of 100,000 items took 0.17 ms (`node shift-cost.mjs`). Bun drained 100,000 items with `shift()` in 1.92 ms. V8's cost grows with queue length above some size, so a burst of messages makes each dequeue slower. I did not find the threshold.

### 3.3 node:vm contexts

- "The `node:vm` module is not a security mechanism. Do not use it to run untrusted code" ([vm](https://nodejs.org/docs/latest-v25.x/api/vm.html)).
- Each context has its own built-ins. `shared-state.mjs` polluted `Object.prototype` in one context, and a second context and the host did not see it. An object passed in from the host keeps the host's prototype, so pollution can still cross through shared objects.
- All contexts share one heap. `vm.measureMemory()` (experimental) can measure "all contexts known to the current V8 isolate", which could attribute memory per context.
- Command: `node --expose-gc realm-cost.mjs vm 1000`. A context cost 219 (186–222) µs to create and 162 KiB of heap (210 KiB RSS). Bun: 61.3 (49.4–62.0) µs and 34.3 (33.8–34.7) KiB of heap.
- `timeout` creates a watchdog. Each `Watchdog` runs `uv_loop_init` and `uv_thread_create`, and its timer calls `TerminateExecution()` ([node_watchdog.cc](https://github.com/nodejs/node/blob/main/src/node_watchdog.cc)). Command `node vm-timeout-overhead.mjs`: a trivial script cost 0.239 (0.229–0.262) µs per call without a timeout and 105 (94.7–329) µs with one. Bun: 0.468 (0.440–0.584) µs and 0.705 (0.664–0.709) µs.
- Timeouts fire on time for synchronous code. `preempt-vm.mjs` asked for 50 ms and measured 51.2 (51.2–51.9) ms on Node and 55.1 (54.5–55.2) ms on Bun (p50 of 20).
- Async work escapes the timeout. "Promises and async functions can schedule tasks ... This allows escaping the functionality of the `timeout` and `breakOnSigint` options." `microtaskMode: 'afterEvaluate'` gives the context its own microtask queue, but callbacks passed to `setTimeout`, `setImmediate`, `process.nextTick`, or `queueMicrotask` from the host "are added to global queues, which are shared by all contexts" ([vm](https://nodejs.org/docs/latest-v25.x/api/vm.html)). Sharing promises between such contexts can stall: "this task will remain pending indefinitely".
- npm packages do not load into a vm context directly. ES modules in a context need `vm.SourceTextModule`, which requires `--experimental-vm-modules` (Stability 1). `vm.constants.USE_MAIN_CONTEXT_DEFAULT_LOADER` loads modules through the main context, so their objects belong to the main realm.

### 3.4 AsyncLocalStorage and AsyncContextFrame

- Since v24.0.0, `AsyncLocalStorage` uses `AsyncContextFrame` by default. `--no-async-context-frame` restores the older `async_hooks` implementation ([CLI](https://nodejs.org/docs/latest-v25.x/api/cli.html)).
- An earlier measurement in this session, given to this track as a fact, found that a store set with `als.run()` is visible in `uncaughtException` and `unhandledRejection` handlers for errors from timers, microtasks, event emitters, and floating promises created in that `run()`. The sibling note [measurements-node.md](measurements-node.md), section E6, records the details and Bun's gaps. Bun "does not propagate `AsyncLocalStorage` context into `MessagePort`, `BroadcastChannel`, or `Worker` events" ([Bun Node.js compatibility](https://bun.com/docs/runtime/nodejs-compat)).
- Command `node --expose-gc actor-cost.mjs 100000 --als`: starting each actor inside its own `run()` raised the heap per idle actor from 754 to 970 bytes, and spawn time from 661 (397–5,925) to 807 (670–1,285) ns per actor.

### 3.5 Module hooks

- `module.registerHooks()` adds synchronous hooks that run "in the same thread and the same realm where the modules are loaded". It is "Stability: 1.2 - Release candidate" ([module](https://nodejs.org/docs/latest-v25.x/api/module.html)).
- `module.register()`, the asynchronous off-thread variant, is deprecated since v25.9.0.
- Synchronous hooks "are not inherited into child worker threads by default". A file preloaded with `--import` or `--require` registers them in workers too. A D1 scheduler pool must preload the Buoy loader in every worker.
- Bun does not implement `registerHooks`, and its `module.register` is a no-op ([Bun Node.js compatibility](https://bun.com/docs/runtime/nodejs-compat)).

### 3.6 Uncaught exceptions and rejections

- By default, an uncaught exception prints the stack and exits with code 1. A handler overrides that. Node warns: "It is not safe to resume normal operation after `'uncaughtException'`" ([process](https://nodejs.org/docs/latest-v25.x/api/process.html)).
- `--unhandled-rejections=throw` has been the default since v15.0.0. It emits `unhandledRejection` and, without a handler, raises the rejection as an uncaught exception ([CLI](https://nodejs.org/docs/latest-v25.x/api/cli.html)).
- `unhandled.mjs` exited with code 1 on both Node 25.9.0 and Bun 1.3.11 for one top-level rejection.

The Node warning refers to shared state. In a single-isolate actor runtime, an exception can leave module-level state half-updated, and no handler can tell. A worker boundary limits that risk to the actors of one worker.

### 3.7 Native addons in workers

- To load in a main thread and a worker, an addon must "Be an Node-API addon" or "Be declared as context-aware using `NODE_MODULE_INIT()`" ([addons](https://nodejs.org/docs/latest-v25.x/api/addons.html)).
- Node-API says bindings "may be called multiple times, from multiple contexts, and even concurrently from multiple threads", and passing a `napi_env` between workers "is not allowed" ([Node-API](https://nodejs.org/docs/latest-v25.x/api/n-api.html)).
- A second load of a non-context-aware addon fails with "Module did not self-register", and `--force-context-aware` rejects such addons at first load ([node_binding.cc v25.9.0](https://github.com/nodejs/node/blob/v25.9.0/src/node_binding.cc)).

### 3.8 Preempting a runaway loop on Node

| Mechanism                                            | Scope                             | Result on this machine                                                                                |
| ---------------------------------------------------- | --------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `worker.terminate()`                                 | Whole worker                      | 0.776 (0.619–1.95) ms p50 on `for (;;) {}` (`preempt-worker.mjs`); Gap 1 applies                      |
| `resourceLimits` heap cap                            | Whole worker                      | 34–169 ms to `ERR_WORKER_OUT_OF_MEMORY`; Gap 1 applies                                                |
| `vm` `timeout`                                       | One synchronous call in a context | 51.2 ms for a 50 ms limit; 105 µs extra per call for the watchdog thread; async work escapes          |
| Inspector `Runtime.terminateExecution` from a worker | Main thread JavaScript            | Aborts Node inside timer callbacks; drops microtasks (Gaps 2 and 3)                                   |
| Compiler-inserted yield or budget checks             | Compiled Buoy code only           | Not measured here; [measurements-node.md](measurements-node.md) E5 measured 0.57 to 0.91 ns per check |

Node offers no supported way to stop one runaway actor on the main thread and keep the other actors.

## 4. isolated-vm

- isolated-vm exposes V8 isolates to Node. It is in maintenance mode: "It will continue to be supported for as long as is technically feasible." Node 20 or later needs `--no-node-snapshot`. Its table maps Node 24 to versions 6.x or 5.x and Node 26 to 7.x ([isolated-vm](https://github.com/laverdet/isolated-vm)).
- `memoryLimit` "is more of a guideline instead of a strict limit": "A determined attacker could use 2-3 times this limit".
- An isolate has no Node APIs. File, network, and native-module work needs "some kind of shim delegate".
- On Node 25.9.0, isolated-vm 7.0.1 failed to compile (`no member named 'kEmbedderDataTypeTagDefault' in namespace 'v8'`). Version 6.2.0 compiled from source in 3 minutes, then crashed with a segmentation fault in `new ivm.Isolate()`.
- On Node 24.2.0 with the prebuilt 6.2.0 binary (`ivm-cost.mjs 200`): isolate plus context plus one script took 0.643 (0.628–0.697) ms p50 and 1.10 MiB RSS per isolate. A 100 ms timeout on `for (;;) {}` fired as `Script execution timed out` after 106 ms. An isolate over its 8 MB limit was disposed, and the host process continued.

isolated-vm gives hard isolation inside one Node process at about 1 MiB per isolate. It cannot run npm packages that need Node built-ins, and each Node major needs a matching native build.

## 5. ShadowRealm

- The proposal "is Currently at Stage 2.7" ([proposal-shadowrealm](https://github.com/tc39/proposal-shadowrealm)). Only primitives and callables cross the boundary: `evaluate(sourceText: string): PrimitiveValueOrCallable`.
- Node has `--experimental-shadow-realm` since v19.0.0. [nodejs/node#65650](https://github.com/nodejs/node/pull/65650) (opened 2026-08-29, still open) proposes to remove it because the proposal "remains unimplemented by browsers" and WPT dropped its tests.
- Bun 1.3.11 exposes `ShadowRealm` without a flag; `typeof ShadowRealm` printed `function`.
- Command `realm-cost.mjs shadowrealm`: a Node ShadowRealm cost 4,826 (4,694–6,362) µs and 1,374 KiB of heap. A Bun ShadowRealm cost 98.0 (79.4–102) µs and 35.0 (34.1–35.4) KiB of heap.
- `npm-in-realm.mjs`: in Node's ShadowRealm, importing `ai` failed with `Cannot find module 'path'`, raised by its dependency `@vercel/oidc`. In Bun's ShadowRealm, the full agent turn ran, and the realm created its own zod registry.
- Command `bun realm-import-cost.mjs 10`: a Bun ShadowRealm that imports the agent packages cost 63.5 (34.5–97.5) ms and 16.1 (14.9–16.3) MiB RSS per realm. A Bun worker that loads the same packages costs 23.2 MiB. The realm saves about a third of that memory, but it shares the thread and the heap.

ShadowRealm separates built-ins and module singletons. It does not separate CPU time, heap limits, or crashes.

## 6. Deno

- Deno is a Rust host on rusty_v8. `deno_core` provides `JsRuntime`, an event loop that the embedder drives "in the context of Rust's future executor (eg. tokio, smol)", and ops registered with `deno_core::extension!` ([deno core README](https://github.com/denoland/deno/tree/main/libs/core)). The separate `deno_core` repository was archived on 2026-04-02 and merged into `denoland/deno` ([deno_core](https://github.com/denoland/deno_core)).
- Node compatibility: "Most Node.js code runs in Deno without modification", and "over 75% of Node's own test suite passes" as of Deno 2.8 ([Deno Node docs](https://docs.deno.com/runtime/fundamentals/node/)). `node:worker_threads` and `node:vm` are partial: `receiveMessageOnPort` and `markAsUntransferable` are unsupported, and `vm.measureMemory` is a "non-functional stub" ([Node APIs in Deno](https://docs.deno.com/runtime/reference/node_apis/), updated 2026-07-30).
- Workers: "Each instance of `Worker` is run on a separate thread, dedicated only to that worker." Deno supports only module workers ([Deno web platform APIs](https://docs.deno.com/runtime/reference/web_platform_apis/)).
- Measured in Docker (`deno run --allow-read --v8-flags=--expose-gc deno-worker-cost.ts 50`): 8.69 (7.31–9.63) ms to the first message and 5.42 (5.37–5.42) MiB RSS per idle worker. Node in the same VM: 22.1 (21.3–27.1) ms and 8.00 (7.98–8.01) MiB.
- Measured in Docker (`deno-terminate.ts`): after `terminate()`, a worker that spun on `Atomics.add` kept incrementing a shared counter. It added 176,578,258 increments in the first second and 18,881,535 between 1,000 and 1,100 ms. Deno PR [#36955](https://github.com/denoland/deno/pull/36955) (opened 2026-10-04, open) states the cause: "`Worker.terminate()` only sets a flag and wakes the worker's event loop". The PR adds `TerminateExecution`.
- The agent turn (zod, ai, @ai-sdk/openai with a mock model) ran on Deno's main thread and in a `node:worker_threads` worker with `--node-modules-dir=manual` (`npm-in-worker.mjs`). Without that flag, Deno failed with `Import "zod/v4" not a dependency`.

Deno shows the size of the compatibility work that D2 needs: its Node layer passes "over 75%" of Node's own test suite as of Deno 2.8.

## 7. Bun and JavaScriptCore

- Bun runs on JavaScriptCore. Its compatibility page targets Node v26 and lists `node:worker_threads` as partial: "`Worker` ignores `resourceLimits`" ([Bun Node.js compatibility](https://bun.com/docs/runtime/nodejs-compat)). Bun's `node:vm` is "Fully implemented". "Bun implements [Node-API] from scratch, so most existing Node-API extensions work" ([Bun Node-API](https://bun.com/docs/runtime/node-api)).
- Bun calls a worker "a new JavaScript instance running on a separate thread" and warns: "The `Worker` API is still experimental (particularly for terminating workers)" ([Bun workers](https://bun.com/docs/runtime/workers)).
- Measured (`terminate-counter.mjs`): on Bun 1.3.11, macOS and Docker, a spinning worker kept running after `terminate()`: about 580 million increments in the next second and about 60 million between 1,000 and 1,100 ms. On Bun 1.4.3 in Docker, the worker stopped: 4,001 increments in the first second and 0 after. Issue [#12616](https://github.com/oven-sh/bun/issues/12616) was closed on 2026-05-13 as not reproducible on Bun 1.3.13.
- JavaScriptCore groups contexts in a `JSContextGroup`. "Contexts in the same group may share and exchange JavaScript objects", and sharing across groups "will produce undefined behavior" ([JSContextRef.h](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSContextRef.h)).
- JavaScriptCore has a group-wide watchdog: `JSContextGroupSetExecutionTimeLimit(group, limit, callback, context)`. The callback decides: "If you return true, the timed out script will terminate" ([JSContextRefPrivate.h](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSContextRefPrivate.h)). It is a private API.
- Global objects are cheap in JavaScriptCore. A Bun vm context cost 34.3 (33.8–34.7) KiB of heap against 162 KiB on Node. `JSGlobalObject.h` declares 72 `LazyProperty<JSGlobalObject, ...>` members and 29 `LazyClassStructure` members ([JSGlobalObject.h at 733b18f](https://github.com/WebKit/WebKit/blob/733b18f696db58c67250673de025e075533a7fb5/Source/JavaScriptCore/runtime/JSGlobalObject.h), 2026-10-15). Lazy creation of built-ins is a likely cause of the gap. I did not verify it.
- Bun's vm timeout cost little per call (see 3.3). On the Gap 1 loop, a 500 ms Bun vm timeout fired after 2,210 to 2,748 ms (`bun vm-local-alloc.mjs 64 500`).

## 8. Isolation inside one isolate versus hard isolation

### 8.1 What actors in one realm share

Command: `node shared-state.mjs` and `bun shared-state.mjs`. Actor A wrote to shared state; actor B then read it.

| Check by actor B                                               | Node 25.9.0                                                          | Bun 1.3.11                                                          |
| -------------------------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------- |
| Sees `Object.prototype.isAdmin` set by actor A                 | yes                                                                  | yes                                                                 |
| Sees the schema id actor A put in `z.globalRegistry`           | yes                                                                  | yes                                                                 |
| Sees the zod config actor A set with `z.config()`              | yes                                                                  | yes                                                                 |
| Sees `globalThis.AI_SDK_DEFAULT_PROVIDER` set by actor A       | yes                                                                  | yes                                                                 |
| Can build `z.object({ name: z.string() })` after the pollution | no: `TypeError: Cannot read properties of undefined (reading 'get')` | no: `TypeError: undefined is not an object (evaluating 'desc.get')` |

zod's `members()` walks keys with `for...in`, which includes the polluted inherited key. zod 4.6.7 stores its registry on `globalThis.__zod_globalRegistry` and its config on `globalThis.__zod_globalConfig`. `ai` 7.0.142 reads `globalThis.fetch`, `AI_SDK_DEFAULT_PROVIDER`, `AI_SDK_TELEMETRY_INTEGRATIONS`, and `AI_SDK_LOG_WARNINGS` (grep of `dist/index.js`).

Freezing the built-in prototypes before user code runs blocks this attack (`frozen-intrinsics.mjs`). On Node 25.9.0, the pollution attempt threw `TypeError: Cannot add property isAdmin, object is not extensible`, and the agent turn still ran. On Bun 1.3.11, the freeze broke Bun's lazily loaded `node:events` and `node:fs` (`TypeError: Attempted to assign to readonly property`). With those built-ins imported before the freeze (`--preload-builtins`), the agent turn ran on Bun too.

### 8.2 Failure modes by isolation unit

| Failure                   | Actors in one isolate (C)                                 | Worker per group of actors (D1)                            | Isolate per actor or group (D2)          |
| ------------------------- | --------------------------------------------------------- | ---------------------------------------------------------- | ---------------------------------------- |
| Thrown error or rejection | Caught per actor; attribution through `AsyncLocalStorage` | Same inside a worker; uncaught errors end only that worker | Same inside an isolate                   |
| Prototype pollution       | Breaks every actor                                        | Breaks the actors of one worker                            | Breaks one isolate                       |
| Module singleton writes   | Shared by every actor                                     | Shared inside one worker                                   | Shared inside one isolate                |
| Infinite synchronous loop | Blocks every actor; no supported stop                     | `worker.terminate()` ends the worker, except Gap 1         | `TerminateExecution`, except Gap 1       |
| Heap exhaustion           | Process abort, exit code 134                              | `ERR_WORKER_OUT_OF_MEMORY`; main survives                  | Near-heap-limit callback, then terminate |
| V8 crash or Gap 1 loop    | Process lost                                              | Process lost, or a thread spins forever                    | Process lost, or a thread spins forever  |

### 8.3 Cost per unit

| Unit                                | Spawn time         | Memory per unit      | Source                       |
| ----------------------------------- | ------------------ | -------------------- | ---------------------------- |
| Light actor in one isolate, Node    | 661 (397–5,925) ns | 754 B heap           | `actor-cost.mjs 100000`      |
| Light actor in one isolate, Bun     | 210 (159–230) ns   | 587 (401–588) B heap | `actor-cost.mjs 100000`      |
| vm context, Node                    | 219 (186–222) µs   | 162 KiB heap         | `realm-cost.mjs vm 1000`     |
| Bare V8 isolate with one context    | 0.215 + 0.172 ms   | 1,080 KiB RSS        | `isolate-cost isolates 200`  |
| isolated-vm isolate, Node 24.2      | 0.643 ms           | 1.10 MiB RSS         | `ivm-cost.mjs 200`           |
| Node worker, idle                   | 21.9 ms            | 7.96 MiB RSS         | `worker-cost.mjs 50`         |
| Node worker with agent packages     | 132 ms             | 23.7 MiB RSS         | `worker-cost.mjs 20 --agent` |
| Bun ShadowRealm with agent packages | 63.5 ms            | 16.1 MiB RSS         | `realm-import-cost.mjs 10`   |

A worker that loads the agent packages costs about 23.7 MiB. With one worker per actor, 1,000 agents would need about 23 GiB before they do any work. With the same packages loaded once per scheduler, 1,000 light actors add under 1 MiB of heap.

## 9. Preemption by host

| Host                       | Stop a runaway loop in one actor without losing others                          | Stop a whole thread or isolate                                                     |
| -------------------------- | ------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Node main thread           | No supported way. vm `timeout` covers only a synchronous call into a vm context | Not applicable                                                                     |
| Node worker (D1)           | No                                                                              | `worker.terminate()` and `resourceLimits`; Gap 1 can defeat both                   |
| Bun                        | No; vm `timeout` works for synchronous calls                                    | `worker.terminate()` failed on 1.3.11 and worked on 1.4.3; no heap limits          |
| Deno 2.9.7                 | No                                                                              | `terminate()` did not stop spinning workers; PR #36955 open                        |
| Cloudflare Workers         | No; termination condemns the isolate                                            | CPU-time signal, then `TerminateExecution`                                         |
| Rust host on rusty_v8 (D2) | `RequestInterrupt` can run host code at the next check, about 14.3 µs here      | `TerminateExecution` from any thread; CPU-time timers as in Workers; Gap 1 applies |
| JavaScriptCore embedder    | No                                                                              | `JSContextGroupSetExecutionTimeLimit` (private API)                                |

No engine preempts one actor inside a shared isolate. Fair scheduling inside an isolate must come from yield points that the Buoy compiler inserts. Engine termination stays a backstop that removes a whole isolate or worker, and a process boundary must back it up because of Gap 1.

## 10. Scores

Scale: 5 is best for Buoy. Evidence names the section or script.

| Criterion                             | C   | D1  | D2  |
| ------------------------------------- | --- | --- | --- |
| TypeScript and npm compatibility      | 5   | 4   | 2   |
| Runtime isolation and fault tolerance | 2   | 3   | 4   |
| Scheduling fairness                   | 2   | 3   | 4   |
| Startup time and memory per actor     | 5   | 4   | 4   |
| Message throughput and latency        | 4   | 4   | 3   |
| I/O and streaming performance         | 4   | 4   | 3   |
| Implementation complexity             | 5   | 3   | 1   |
| Debuggability and tooling             | 5   | 4   | 2   |
| Long-term extensibility               | 3   | 4   | 5   |

- **C.** Every package runs unchanged, and actors cost under 1 KiB. Actors can catch and supervise thrown errors. One isolate offers no other fault boundary (8.1, 8.2, 1.5) and no preemption (3.8). One core caps throughput. The same actor code can later move into D1 workers.
- **D1.** The worker is a real fault and memory domain (1.5, 3.1). Packages run in workers on Node, Bun, and Deno (`npm-in-worker.mjs`). Addons must be Node-API or context-aware (3.7), and module hooks need a preload (3.5). Each worker costs about 23.7 MiB once agent packages load. A cross-worker round trip took 27.3 (16.6–27.7) µs for a 64-byte body.
- **D2.** The host controls isolate groups, heap callbacks, CPU timers, and interrupts (1.3 to 1.5, 2). A bare isolate costs about 1 MiB. The host must rebuild Node APIs: Deno's Node layer passes "over 75%" of Node's own test suite (6). I did not measure cross-isolate messages through Rust.

## Unverified

- The root cause of Gap 1. A V8 bug report with `terminate-const-sizes.mjs` would confirm whether TurboFan drops the loop interrupt check.
- Cross-isolate message cost in a Rust host. A rusty_v8 benchmark that moves `ValueSerializer` output between isolates through a channel would measure it.
- Why a JavaScriptCore global object is cheaper. A heap profile of `vm.createContext` in Bun would show it.
- Whether Bun 1.3.13 to 1.4.2 fixed worker termination. Running `terminate-counter.mjs` on each release would show it.
- Whether Node's compile cache shortens worker start with the agent packages. One run with `NODE_COMPILE_CACHE` was inconclusive under load.

## Appendix A. Scripts

The scripts lived in `/tmp/buoy-engines/scripts`. `run-all.sh` produced every table value written as "median (range)". The packages `zod` 4.6.7, `ai` 7.0.142, and `@ai-sdk/openai` 4.0.95 were installed with `npm install --ignore-scripts` into `/tmp/buoy-engines/npm-deps`, outside the repository. The Rust probe in `/tmp/buoy-engines/rusty` was built with `cargo build --release` (Rust 1.88.0).

### Shared helpers

`scripts/lib.mjs`

```js
// Shared measurement helpers for the engine-substrate scripts.
export const collectGarbage = () => {
  if (globalThis.Bun) return Bun.gc(true);
  if (typeof globalThis.gc !== "function") throw new Error("run with --expose-gc");
  globalThis.gc();
  globalThis.gc();
};
export const percentile = (values, p) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];
};
export const summarize = (values) => ({
  n: values.length,
  p50: +percentile(values, 50).toFixed(3),
  p95: +percentile(values, 95).toFixed(3),
  min: +Math.min(...values).toFixed(3),
  max: +Math.max(...values).toFixed(3),
});
export const runtime = () =>
  globalThis.Bun ? `bun ${Bun.version}` : `node ${process.version} v8 ${process.versions.v8}`;
export const mib = (bytes) => +(bytes / 1048576).toFixed(3);
export const kib = (bytes) => +(bytes / 1024).toFixed(2);
export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
```

`scripts/mailbox.mjs`

```js
// Minimal single-isolate actor: a mailbox plus an async receive loop.
// The queue uses a head index because V8's Array#shift is O(n) on large arrays.
export class Mailbox {
  #queue = [];
  #head = 0;
  #waiter = undefined;
  push(message) {
    const waiter = this.#waiter;
    if (waiter === undefined) return void this.#queue.push(message);
    this.#waiter = undefined;
    waiter(message);
  }
  take() {
    if (this.#head < this.#queue.length) return Promise.resolve(this.#dequeue());
    return new Promise((resolve) => {
      this.#waiter = resolve;
    });
  }
  #dequeue() {
    const message = this.#queue[this.#head];
    this.#queue[this.#head++] = undefined;
    if (this.#head === this.#queue.length) {
      this.#queue = [];
      this.#head = 0;
    }
    return message;
  }
}
export const spawn = (behavior) => {
  const mailbox = new Mailbox();
  const loop = async () => {
    for (;;) await behavior(await mailbox.take());
  };
  loop();
  return mailbox;
};
```

### Batch runner and table filler

`scripts/run-all.sh`

```sh
#!/bin/zsh
# Usage: zsh run-all.sh > ../results/final.jsonl
# Runs every measurement 3 times and prefixes each result with the 1-minute load average.
NODE=/tmp/buoy-engines/dl-node/node-v25.9.0-darwin-arm64/bin/node
BREW=/opt/homebrew/bin/node
NODE24=$HOME/.nvm/versions/node/v24.2.0/bin/node
RUSTY=/tmp/buoy-engines/rusty/target/release/isolate-cost
RUSTYPC=/tmp/buoy-engines/rusty/target-ptrcomp/release/isolate-cost
cd /tmp/buoy-engines/scripts
run() { local label=$1; shift; local load=$(sysctl -n vm.loadavg | awk '{print $2}'); local out=$(perl -e 'alarm shift; exec @ARGV' 300 "$@" 2>&1 | tr '\n' ' '); echo "{\"label\":\"$label\",\"load1\":$load,\"out\":$(printf '%s' "$out" | python3 -I -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"; }
for rep in 1 2 3; do
  run worker-node-official $NODE --expose-gc worker-cost.mjs 50
  run worker-node-homebrew $BREW --expose-gc worker-cost.mjs 50
  run worker-bun bun worker-cost.mjs 50
  run worker-agent-node-official $NODE --expose-gc worker-cost.mjs 20 --agent
  run worker-agent-bun bun worker-cost.mjs 20 --agent
  run vm-node $NODE --expose-gc realm-cost.mjs vm 1000
  run shadowrealm-node $NODE --expose-gc --experimental-shadow-realm realm-cost.mjs shadowrealm 200
  run vm-bun bun realm-cost.mjs vm 1000
  run shadowrealm-bun bun realm-cost.mjs shadowrealm 1000
  run shadowrealm-agent-bun bun realm-import-cost.mjs 10
  run actor-node $NODE --expose-gc actor-cost.mjs 100000
  run actor-als-node $NODE --expose-gc actor-cost.mjs 100000 --als
  run actor-bun bun actor-cost.mjs 100000
  run actor-als-bun bun actor-cost.mjs 100000 --als
  run message64-node $NODE message-cost.mjs 64
  run message64-bun bun message-cost.mjs 64
  run message4096-node $NODE message-cost.mjs 4096
  run message4096-bun bun message-cost.mjs 4096
  run vm-timeout-overhead-node $NODE vm-timeout-overhead.mjs
  run vm-timeout-overhead-bun bun vm-timeout-overhead.mjs
  run preempt-worker-node $NODE preempt-worker.mjs
  run preempt-vm-node $NODE preempt-vm.mjs
  run preempt-vm-bun bun preempt-vm.mjs
  run rusty-isolates $RUSTY isolates 200
  run rusty-contexts $RUSTY contexts 1000
  run rusty-terminate $RUSTY terminate 10 'for (;;) {}'
  run rusty-interrupt $RUSTY interrupt
  run rusty-ptrcomp-isolates $RUSTYPC isolates 200
  run rusty-ptrcomp-contexts $RUSTYPC contexts 1000
  run ivm-node24 env IVM_PATH=/tmp/buoy-engines/dl-ivm24/node_modules/isolated-vm $NODE24 --no-node-snapshot --expose-gc ivm-cost.mjs 200
  run docker-deno-worker docker run --rm -v /tmp/buoy-engines/scripts:/scripts:ro denoland/deno:2.9.7 run --allow-read --v8-flags=--expose-gc /scripts/deno-worker-cost.ts 50
  run docker-node-worker docker run --rm -v /tmp/buoy-engines/scripts:/scripts:ro node:25.9.0-bookworm-slim node --expose-gc /scripts/worker-cost.mjs 50
done
```

`scripts/fill.py`

```python
# Usage: python3 -I fill.py results.jsonl draft.md out.md
# Replaces {{label:key}} with "median (min–max)" across runs, and {{label:key:med}} with the median only.
import json, re, statistics, sys

runs = {}
for line in open(sys.argv[1]):
    record = json.loads(line)
    out = record["out"]
    try:
        value = json.loads(out[out.index("{"):])
    except Exception:
        continue
    runs.setdefault(record["label"], []).append((record["load1"], value))

def lookup(value, key):
    try:
        for part in key.split("."):
            value = value[part]
    except KeyError:
        if not key.endswith("Ms"):
            raise
        return lookup(value, key[:-2])
    if isinstance(value, str):
        # Strings such as "Script execution timed out. after 106.4 ms" yield their last number.
        return float(re.findall(r"[0-9]+(?:\.[0-9]+)?", value)[-1])
    return value

def fmt(x):
    if abs(x) >= 1000:
        return f"{x:,.0f}"
    if abs(x) >= 100:
        return f"{x:.0f}"
    if abs(x) >= 10:
        return f"{x:.1f}"
    if abs(x) >= 1:
        return f"{x:.2f}"
    return f"{x:.3f}"

missing = []
def replace(match):
    label, key, mode = match.group(1), match.group(2), match.group(3)
    if label not in runs:
        missing.append(match.group(0))
        return match.group(0)
    if key == "load":
        loads = [load for load, _ in runs[label]]
        return f"{min(loads):g}–{max(loads):g}"
    values = [lookup(v, key) for _, v in runs[label]]
    median = statistics.median(values)
    if mode == "med" or len(values) == 1 or fmt(min(values)) == fmt(max(values)):
        return fmt(median)
    return f"{fmt(median)} ({fmt(min(values))}–{fmt(max(values))})"

text = open(sys.argv[2]).read()
filled = re.sub(r"\{\{([a-z0-9-]+):([A-Za-z0-9_.]+)(?::(med))?\}\}", replace, text)
open(sys.argv[3], "w").write(filled)
print("runs per label:", {k: len(v) for k, v in runs.items()})
print("unfilled:", sorted(set(missing)))
```

### Worker cost

`scripts/worker-cost.mjs`

```js
// Usage: node --expose-gc worker-cost.mjs [count] [--agent|--cjs] | bun worker-cost.mjs [count] [--agent] [--smol-worker]
// Spawns workers one at a time, keeps them alive, and reports spawn latency and RSS per worker.
import { Worker } from "node:worker_threads";
import { collectGarbage, summarize, runtime, mib, sleep } from "./lib.mjs";

const count = Number(process.argv[2] ?? 50);
const smol = process.argv.includes("--smol-worker");
const script = new URL(
  process.argv.includes("--agent")
    ? "./worker-agent-idle.mjs"
    : process.argv.includes("--cjs")
      ? "./worker-idle.cjs"
      : "./worker-idle.mjs",
  import.meta.url,
);

const spawnWorker = () =>
  new Promise((resolve, reject) => {
    const started = performance.now();
    const worker = new Worker(script, smol ? { smol: true } : {});
    worker.once("error", reject);
    worker.once("message", () => resolve({ worker, ms: performance.now() - started }));
  });

// Warm up the loader with one throwaway worker.
const warm = await spawnWorker();
await warm.worker.terminate();
await sleep(200);
collectGarbage();
const rssBefore = process.memoryUsage().rss;

const workers = [];
const spawnMs = [];
for (let index = 0; index < count; index++) {
  const { worker, ms } = await spawnWorker();
  workers.push(worker);
  spawnMs.push(ms);
}
await sleep(1000);
collectGarbage();
const rssAfter = process.memoryUsage().rss;

const heap =
  typeof workers[0].getHeapStatistics === "function"
    ? await workers[0].getHeapStatistics()
    : undefined;

const terminateMs = [];
for (const worker of workers) {
  const started = performance.now();
  await worker.terminate();
  terminateMs.push(performance.now() - started);
}

console.log(
  JSON.stringify(
    {
      runtime: runtime(),
      smol,
      cjs: process.argv.includes("--cjs"),
      agentModules: process.argv.includes("--agent"),
      workers: count,
      spawnToFirstMessageMs: summarize(spawnMs),
      rssPerWorkerMiB: mib((rssAfter - rssBefore) / count),
      rssTotalDeltaMiB: mib(rssAfter - rssBefore),
      oneWorkerHeap: heap && {
        usedMiB: mib(heap.used_heap_size),
        totalMiB: mib(heap.total_heap_size),
      },
      terminateIdleMs: summarize(terminateMs),
    },
    null,
    1,
  ),
);
```

`scripts/worker-idle.mjs`

```js
import { parentPort } from "node:worker_threads";
parentPort.on("message", (message) => {
  if (message === "memory") parentPort.postMessage(process.memoryUsage());
});
parentPort.postMessage("ready");
```

`scripts/worker-idle.cjs`

```js
const { parentPort } = require("node:worker_threads");
parentPort.on("message", (message) => {
  if (message === "memory") parentPort.postMessage(process.memoryUsage());
});
parentPort.postMessage("ready");
```

`scripts/worker-agent-idle.mjs`

```js
import { parentPort } from "node:worker_threads";
import "./agent-turn.mjs";
parentPort.on("message", () => {});
parentPort.postMessage("ready");
```

### Realm cost

`scripts/realm-cost.mjs`

```js
// Usage: node --expose-gc [--experimental-shadow-realm] realm-cost.mjs <vm|vm-after-evaluate|shadowrealm> [count]
// Creates many realms in one isolate and reports creation time and memory per realm.
import vm from "node:vm";
import { collectGarbage, summarize, runtime, kib } from "./lib.mjs";

const kind = process.argv[2] ?? "vm";
const count = Number(process.argv[3] ?? 1000);
const makers = {
  vm: () => vm.createContext({}),
  "vm-after-evaluate": () => vm.createContext({}, { microtaskMode: "afterEvaluate" }),
  shadowrealm: () => new ShadowRealm(),
};
const touchers = {
  vm: (realm) => vm.runInContext("[1, 2].map((x) => x * 2).length", realm),
  "vm-after-evaluate": (realm) => vm.runInContext("[1, 2].map((x) => x * 2).length", realm),
  shadowrealm: (realm) => realm.evaluate("[1, 2].map((x) => x * 2).length"),
};
const make = makers[kind];
const touch = touchers[kind];

make(); // warm-up
collectGarbage();
const before = process.memoryUsage();
const realms = [];
const createUs = [];
const firstEvalUs = [];
for (let index = 0; index < count; index++) {
  const started = performance.now();
  const realm = make();
  const created = performance.now();
  touch(realm);
  firstEvalUs.push((performance.now() - created) * 1000);
  createUs.push((created - started) * 1000);
  realms.push(realm);
}
collectGarbage();
const after = process.memoryUsage();
console.log(
  JSON.stringify(
    {
      runtime: runtime(),
      kind,
      count,
      createUs: summarize(createUs),
      firstEvalUs: summarize(firstEvalUs),
      heapUsedPerRealmKiB: kib((after.heapUsed - before.heapUsed) / count),
      rssPerRealmKiB: kib((after.rss - before.rss) / count),
      keepAlive: realms.length,
    },
    null,
    1,
  ),
);
```

`scripts/realm-import-cost.mjs`

```js
// Usage: bun realm-import-cost.mjs [count]
// Cost of a ShadowRealm per actor when each realm loads zod + ai + @ai-sdk/openai.
import { collectGarbage, summarize, runtime, mib } from "./lib.mjs";
const count = Number(process.argv[2] ?? 20);
const entry = new URL("./shadow-agent.mjs", import.meta.url).href;
const warm = new ShadowRealm();
await warm.importValue(entry, "runJson");
collectGarbage();
const before = process.memoryUsage();
const realms = [];
const importMs = [];
for (let index = 0; index < count; index++) {
  const started = performance.now();
  const realm = new ShadowRealm();
  await realm.importValue(entry, "runJson");
  importMs.push(performance.now() - started);
  realms.push(realm);
}
collectGarbage();
const after = process.memoryUsage();
console.log(
  JSON.stringify({
    runtime: runtime(),
    count,
    createAndImportMs: summarize(importMs),
    heapPerRealmMiB: mib((after.heapUsed - before.heapUsed) / count),
    rssPerRealmMiB: mib((after.rss - before.rss) / count),
    keep: realms.length,
  }),
);
```

`scripts/shadow-agent.mjs`

```js
// Entry point loaded inside a ShadowRealm. Only primitives and callables cross the boundary.
import { runAgentTurn } from "./agent-turn.mjs";
export const runJson = (onDone) => {
  runAgentTurn().then(
    (result) => onDone(JSON.stringify(result)),
    (error) => onDone(`error: ${error}`),
  );
};
export const zodRegistryIsShared = () =>
  globalThis.__zod_globalRegistry === undefined ? "no registry yet" : "registry exists in realm";
```

`scripts/npm-in-realm.mjs`

```js
// Usage: node --experimental-shadow-realm npm-in-realm.mjs | bun npm-in-realm.mjs
// Runs the agent turn inside a ShadowRealm, and checks whether the realm shares zod's registry.
import { runtime } from "./lib.mjs";
await import("/tmp/buoy-engines/npm-deps/node_modules/zod/index.js"); // host realm creates its zod registry
const realm = new ShadowRealm();
let shadow;
try {
  const runJson = await realm.importValue(
    new URL("./shadow-agent.mjs", import.meta.url).href,
    "runJson",
  );
  const result = await new Promise((resolve) => runJson(resolve));
  const registry = realm.evaluate(
    "globalThis.__zod_globalRegistry === undefined ? 'separate (undefined before import)' : 'present'",
  );
  shadow = { result, realmRegistryState: registry };
} catch (error) {
  shadow = { error: `${error.name}: ${error.message}` };
}
console.log(JSON.stringify({ runtime: runtime(), shadow }, null, 1));
```

### Light actor cost

`scripts/actor-cost.mjs`

```js
// Usage: node --expose-gc actor-cost.mjs [count] [--als] | bun actor-cost.mjs [count] [--als]
// Spawns idle single-isolate actors and reports heap bytes and spawn time per actor.
import { AsyncLocalStorage } from "node:async_hooks";
import { spawn } from "./mailbox.mjs";
import { collectGarbage, runtime, sleep } from "./lib.mjs";

const count = Number(process.argv[2] ?? 100000);
const withContext = process.argv.includes("--als");
const actorContext = new AsyncLocalStorage();
const behavior = async (message) => {
  message.reply?.(message.value);
};
const spawnActor = withContext
  ? (id) => actorContext.run({ id }, () => spawn(behavior))
  : () => spawn(behavior);

for (let index = 0; index < 1000; index++) spawnActor(index); // warm-up
await sleep(50);
collectGarbage();
const before = process.memoryUsage();
const actors = [];
const started = performance.now();
for (let index = 0; index < count; index++) actors.push(spawnActor(index));
const spawnNs = ((performance.now() - started) * 1e6) / count;
await sleep(50);
collectGarbage();
const after = process.memoryUsage();
console.log(
  JSON.stringify({
    runtime: runtime(),
    actors: count,
    asyncLocalStorage: withContext,
    heapBytesPerActor: Math.round((after.heapUsed - before.heapUsed) / count),
    rssBytesPerActor: Math.round((after.rss - before.rss) / count),
    spawnNsPerActor: Math.round(spawnNs),
    keepAlive: actors.length,
  }),
);
```

### Messages and queues

`scripts/message-cost.mjs`

```js
// Usage: node message-cost.mjs [payloadBytes] | bun message-cost.mjs [payloadBytes]
// Compares ping-pong latency and one-way throughput for in-isolate actors and worker threads.
import { Worker } from "node:worker_threads";
import { spawn } from "./mailbox.mjs";
import { runtime } from "./lib.mjs";

const payloadBytes = Number(process.argv[2] ?? 64);
const body = "x".repeat(payloadBytes);
const roundTrips = 100000;
const oneWay = 1000000;
const message = (seq) => ({ kind: "ping", seq, body, meta: { from: "a", tags: ["t1", "t2"] } });

const inIsolatePingPong = async (copy) => {
  // The envelope carries the reply address by reference; only the payload is copied.
  const send = copy
    ? (mailbox, payload, replyTo) => mailbox.push({ payload: structuredClone(payload), replyTo })
    : (mailbox, payload, replyTo) => mailbox.push({ payload, replyTo });
  let finish;
  const done = new Promise((resolve) => {
    finish = resolve;
  });
  const echo = spawn(async ({ payload, replyTo }) => send(replyTo, payload, undefined));
  let remaining = roundTrips;
  const self = spawn(async () => {
    remaining -= 1;
    if (remaining === 0) return finish();
    send(echo, message(remaining), self);
  });
  const started = performance.now();
  send(echo, message(remaining), self);
  await done;
  return ((performance.now() - started) * 1000) / roundTrips;
};

const inIsolateOneWay = async () => {
  let received = 0;
  let finish;
  const done = new Promise((resolve) => {
    finish = resolve;
  });
  const sink = spawn(async () => {
    received += 1;
    if (received === oneWay) finish();
  });
  const started = performance.now();
  for (let seq = 0; seq < oneWay; seq++) sink.push(structuredClone({ kind: "data", seq, body }));
  await done;
  return oneWay / ((performance.now() - started) / 1000);
};

const workerPingPong = async (worker) => {
  const started = performance.now();
  for (let seq = 0; seq < roundTrips; seq++) {
    const reply = new Promise((resolve) => worker.once("message", resolve));
    worker.postMessage(message(seq));
    await reply;
  }
  return ((performance.now() - started) * 1000) / roundTrips;
};

const workerOneWay = async (worker) => {
  const started = performance.now();
  for (let seq = 0; seq < oneWay; seq++) worker.postMessage({ kind: "data", seq, body });
  const counted = new Promise((resolve) => worker.once("message", resolve));
  worker.postMessage({ kind: "count" });
  const { received } = await counted;
  if (received !== oneWay) throw new Error(`lost messages: ${received}`);
  return oneWay / ((performance.now() - started) / 1000);
};

const worker = new Worker(new URL("./echo-worker.mjs", import.meta.url));
await workerPingPong(worker); // warm-up
const result = {
  runtime: runtime(),
  payloadBytes,
  inIsolateRoundTripUs_noCopy: +(await inIsolatePingPong(false)).toFixed(3),
  inIsolateRoundTripUs_structuredClone: +(await inIsolatePingPong(true)).toFixed(3),
  inIsolateOneWayMsgPerSec_structuredClone: Math.round(await inIsolateOneWay()),
  workerRoundTripUs: +(await workerPingPong(worker)).toFixed(3),
  workerOneWayMsgPerSec: Math.round(await workerOneWay(worker)),
};
await worker.terminate();
console.log(JSON.stringify(result));
```

`scripts/echo-worker.mjs`

```js
import { parentPort } from "node:worker_threads";
let received = 0;
parentPort.on("message", (message) => {
  if (message.kind === "ping") return parentPort.postMessage(message);
  if (message.kind === "data") return void received++;
  if (message.kind === "count") parentPort.postMessage({ kind: "count", received });
});
```

`scripts/shift-cost.mjs`

```js
// Usage: node shift-cost.mjs | bun shift-cost.mjs
// Times draining an array queue with shift() versus a head index, at two sizes.
import { runtime } from "./lib.mjs";
const drainWithShift = (size) => {
  const queue = Array.from({ length: size }, (_, index) => ({ index }));
  const started = performance.now();
  while (queue.length > 0) queue.shift();
  return performance.now() - started;
};
const drainWithHead = (size) => {
  const queue = Array.from({ length: size }, (_, index) => ({ index }));
  const started = performance.now();
  for (let head = 0; head < queue.length; head++) queue[head] = undefined;
  return performance.now() - started;
};
const result = { runtime: runtime() };
for (const size of [10000, 100000]) {
  result[`shift_${size}_ms`] = +drainWithShift(size).toFixed(2);
  result[`head_${size}_ms`] = +drainWithHead(size).toFixed(2);
}
console.log(JSON.stringify(result));
```

### vm timeouts

`scripts/vm-timeout-overhead.mjs`

```js
// Usage: node vm-timeout-overhead.mjs | bun vm-timeout-overhead.mjs
// Per-call cost of runInContext with and without a timeout watchdog.
import vm from "node:vm";
import { runtime } from "./lib.mjs";
const context = vm.createContext({});
const script = new vm.Script("1 + 1");
const time = (options) => {
  const calls = 20000;
  const started = performance.now();
  for (let index = 0; index < calls; index++) script.runInContext(context, options);
  return +(((performance.now() - started) * 1000) / calls).toFixed(3);
};
time({});
time({ timeout: 1000 });
console.log(
  JSON.stringify({
    runtime: runtime(),
    usPerCall_noTimeout: time({}),
    usPerCall_timeout: time({ timeout: 1000 }),
  }),
);
```

`scripts/preempt-vm.mjs`

```js
// Usage: node preempt-vm.mjs | bun preempt-vm.mjs
// Measures how close vm timeouts fire to the requested 50 ms on a synchronous loop.
import vm from "node:vm";
import { summarize, runtime } from "./lib.mjs";

const context = vm.createContext({});
const elapsedMs = [];
let message = "";
for (let run = 0; run < 20; run++) {
  const started = performance.now();
  try {
    vm.runInContext("for (;;) {}", context, { timeout: 50 });
  } catch (error) {
    message = error.message;
  }
  elapsedMs.push(performance.now() - started);
}
console.log(
  JSON.stringify({ runtime: runtime(), requestedMs: 50, elapsedMs: summarize(elapsedMs), message }),
);
```

`scripts/vm-local-alloc.mjs`

```js
// Usage: node vm-local-alloc.mjs <size> [timeoutMs]
// Like vm-timeout-alloc.mjs, but the array sink is a local constant instead of a context global.
import vm from "node:vm";
const size = Number(process.argv[2] ?? 64);
const timeout = Number(process.argv[3] ?? 500);
const context = vm.createContext({});
const started = performance.now();
const watchdog = setTimeout(() => {}, 0);
try {
  vm.runInContext(
    `(() => { const sink = []; for (let n = 0; ; n++) sink[n & 1023] = new Array(${size}); })()`,
    context,
    { timeout },
  );
} catch (error) {
  console.log(
    JSON.stringify({
      size,
      timeout,
      outcome: error.message,
      elapsedMs: +(performance.now() - started).toFixed(1),
    }),
  );
}
```

`scripts/worker-vm-alloc.mjs`

```js
// Usage: node worker-vm-alloc.mjs
// Inside a worker, run the allocation loop under a vm timeout; then try worker.terminate() on the bare loop.
import { Worker } from "node:worker_threads";
const source = `const vm = require("node:vm"); const { parentPort } = require("node:worker_threads");
const started = performance.now();
try { vm.runInContext("(() => { const sink = []; for (let n = 0; ; n++) sink[n & 1023] = new Array(64); })()", vm.createContext({}), { timeout: 500 }); }
catch (error) { parentPort.postMessage({ outcome: error.message, elapsedMs: performance.now() - started }); }`;
const worker = new Worker(source, { eval: true });
console.log(JSON.stringify(await new Promise((resolve) => worker.once("message", resolve))));
await worker.terminate();
process.exit(0);
```

### Worker termination

`scripts/preempt-worker.mjs`

```js
// Usage: node preempt-worker.mjs | bun preempt-worker.mjs
// Times worker.terminate() against a worker stuck in a synchronous infinite loop.
import { Worker } from "node:worker_threads";
import { summarize, runtime, sleep } from "./lib.mjs";

const terminateMs = [];
const exitCodes = new Set();
for (let run = 0; run < 20; run++) {
  const worker = new Worker(new URL("./busy-worker.mjs", import.meta.url));
  await new Promise((resolve) => worker.once("message", resolve));
  await sleep(20);
  const started = performance.now();
  exitCodes.add(await worker.terminate());
  terminateMs.push(performance.now() - started);
}
console.log(
  JSON.stringify({
    runtime: runtime(),
    terminateBusyMs: summarize(terminateMs),
    exitCodes: [...exitCodes],
  }),
);
```

`scripts/busy-worker.mjs`

```js
import { parentPort } from "node:worker_threads";
parentPort.postMessage("spinning");
for (;;) {}
```

`scripts/terminate-matrix.mjs`

```js
// Usage: node [v8 flags] terminate-matrix.mjs
// For several loop bodies, times worker.terminate() after 300 ms of warm-up; gives up after 5 s.
import { Worker } from "node:worker_threads";
const kinds = [
  "empty",
  "newArray1024",
  "newArray8",
  "arrayLiteral",
  "objectLiteral",
  "stringConcat",
  "mathOnly",
];
const results = {};
for (const kind of kinds) {
  const worker = new Worker(new URL("./loop-worker.mjs", import.meta.url), { workerData: kind });
  await new Promise((resolve) => worker.once("message", resolve));
  await new Promise((resolve) => setTimeout(resolve, 300));
  const started = performance.now();
  const outcome = await Promise.race([
    worker.terminate().then(() => "terminated"),
    new Promise((resolve) => setTimeout(() => resolve("not-terminated-in-5s"), 5000)),
  ]);
  results[kind] =
    outcome === "terminated" ? `${(performance.now() - started).toFixed(1)} ms` : outcome;
}
console.log(
  JSON.stringify({
    node: process.version,
    v8: process.versions.v8,
    flags: process.execArgv,
    results,
  }),
);
process.kill(process.pid, "SIGKILL");
```

`scripts/loop-worker.mjs`

```js
import { parentPort, workerData } from "node:worker_threads";
const sink = [];
const bodies = {
  empty: () => {
    for (;;) {}
  },
  newArray1024: () => {
    for (let n = 0; ; n++) sink[n & 1023] = new Array(1024);
  },
  newArray8: () => {
    for (let n = 0; ; n++) sink[n & 1023] = new Array(8);
  },
  arrayLiteral: () => {
    for (let n = 0; ; n++) sink[n & 1023] = [n, n];
  },
  objectLiteral: () => {
    for (let n = 0; ; n++) sink[n & 1023] = { n };
  },
  stringConcat: () => {
    for (let n = 0; ; n++) sink[n & 1023] = "s" + n;
  },
  mathOnly: () => {
    let x = 0;
    for (let n = 0; ; n++) x = (x + Math.sqrt(n)) % 1e9;
  },
};
parentPort.postMessage("spinning");
bodies[workerData]();
```

`scripts/terminate-sizes.mjs`

```js
// Usage: node terminate-sizes.mjs
// Finds the new Array(size) threshold at which terminate() stops working within 3 s.
import { Worker } from "node:worker_threads";
const results = {};
for (const size of [16, 64, 100, 128, 256, 512, 1024, 4096, 100000]) {
  const worker = new Worker(new URL("./loop-size-worker.mjs", import.meta.url), {
    workerData: size,
  });
  await new Promise((resolve) => worker.once("message", resolve));
  await new Promise((resolve) => setTimeout(resolve, 300));
  const started = performance.now();
  const outcome = await Promise.race([
    worker.terminate().then(() => "terminated"),
    new Promise((resolve) => setTimeout(() => resolve("stuck"), 3000)),
  ]);
  results[size] =
    outcome === "terminated" ? `${(performance.now() - started).toFixed(1)} ms` : outcome;
}
console.log(JSON.stringify({ node: process.version, results }));
process.kill(process.pid, "SIGKILL");
```

`scripts/loop-size-worker.mjs`

```js
import { parentPort, workerData } from "node:worker_threads";
const sink = [];
const size = workerData;
parentPort.postMessage("spinning");
for (let n = 0; ; n++) sink[n & 1023] = new Array(size);
```

`scripts/terminate-const-sizes.mjs`

```js
// Usage: node terminate-const-sizes.mjs
// Same as terminate-sizes.mjs, but the array length is a compile-time constant in the worker source.
import { Worker } from "node:worker_threads";
const results = {};
for (const size of [8, 64, 128, 256, 512, 1000, 1024, 2048, 16000, 100000]) {
  const source = `const { parentPort } = require("node:worker_threads");
const sink = [];
parentPort.postMessage("spinning");
for (let n = 0; ; n++) sink[n & 1023] = new Array(${size});`;
  const worker = new Worker(source, { eval: true });
  await new Promise((resolve) => worker.once("message", resolve));
  await new Promise((resolve) => setTimeout(resolve, 300));
  const started = performance.now();
  const outcome = await Promise.race([
    worker.terminate().then(() => "terminated"),
    new Promise((resolve) => setTimeout(() => resolve("stuck"), 3000)),
  ]);
  results[size] =
    outcome === "terminated" ? `${(performance.now() - started).toFixed(1)} ms` : outcome;
}
console.log(JSON.stringify({ node: process.version, results }));
process.kill(process.pid, "SIGKILL");
```

`scripts/terminate-fill.mjs`

```js
// Usage: node terminate-fill.mjs
// Times worker.terminate() against a loop that calls Array.prototype.fill without retaining memory.
import { Worker } from "node:worker_threads";
const results = [];
for (let run = 0; run < 5; run++) {
  const worker = new Worker(new URL("./busy-fill-worker.mjs", import.meta.url));
  await new Promise((resolve) => worker.once("message", resolve));
  await new Promise((resolve) => setTimeout(resolve, 200));
  const started = performance.now();
  const outcome = await Promise.race([
    worker.terminate().then(() => "terminated"),
    new Promise((resolve) => setTimeout(() => resolve("still-running-after-3s"), 3000)),
  ]);
  results.push({ outcome, ms: +(performance.now() - started).toFixed(2) });
  if (outcome !== "terminated") break;
}
console.log(JSON.stringify({ node: process.version, results }));
process.kill(process.pid, "SIGKILL");
```

`scripts/busy-fill-worker.mjs`

```js
import { parentPort } from "node:worker_threads";
const sink = [];
parentPort.postMessage("spinning");
for (let n = 0; ; n++) sink[n & 1023] = new Array(1024).fill({ n });
```

`scripts/terminate-counter.mjs`

```js
// Usage: node terminate-counter.mjs | bun terminate-counter.mjs
// Calls terminate() on spinning workers and checks whether a shared counter keeps increasing.
import { Worker } from "node:worker_threads";
import { runtime } from "./lib.mjs";
const results = {};
for (const kind of ["empty", "newArray64"]) {
  const counter = new SharedArrayBuffer(4);
  const view = new Int32Array(counter);
  const worker = new Worker(new URL("./spin-worker.mjs", import.meta.url));
  const spinning = new Promise((resolve) => worker.once("message", resolve));
  worker.postMessage({ kind, counter });
  await spinning;
  await new Promise((resolve) => setTimeout(resolve, 300));
  worker.terminate();
  const atTerminate = Atomics.load(view, 0);
  await new Promise((resolve) => setTimeout(resolve, 1000));
  const oneSecondLater = Atomics.load(view, 0);
  await new Promise((resolve) => setTimeout(resolve, 100));
  const later = Atomics.load(view, 0);
  results[kind] = {
    stillRunningOneSecondAfterTerminate: later > oneSecondLater,
    incrementsInFirstSecond: oneSecondLater - atTerminate,
    incrementsFrom1000To1100Ms: later - oneSecondLater,
  };
}
console.log(JSON.stringify({ runtime: runtime(), results }));
process.kill(process.pid, "SIGKILL");
```

`scripts/spin-worker.mjs`

```js
import { parentPort } from "node:worker_threads";
parentPort.once("message", ({ kind, counter }) => {
  const view = new Int32Array(counter);
  const sink = [];
  parentPort.postMessage("spinning");
  if (kind === "empty") for (;;) Atomics.add(view, 0, 1);
  for (let n = 0; ; n++) {
    sink[n & 1023] = new Array(64);
    Atomics.add(view, 0, 1);
  }
});
```

`scripts/watch-spinning.mjs`

```js
// Usage: node watch-spinning.mjs
// Do worker.getHeapStatistics() and worker.cpuUsage() answer while the worker spins?
import { Worker } from "node:worker_threads";
const worker = new Worker(
  "require('node:worker_threads').parentPort.postMessage('spinning'); for (;;) {}",
  { eval: true },
);
await new Promise((resolve) => worker.once("message", resolve));
const within = (promise, ms) =>
  Promise.race([
    promise.then((value) => ({ answered: true, value })),
    new Promise((resolve) => setTimeout(() => resolve({ answered: false }), ms)),
  ]);
const heap = await within(worker.getHeapStatistics(), 1000);
const cpu = await within(worker.cpuUsage(), 1000);
console.log(
  JSON.stringify({
    node: process.version,
    heapStatisticsAnsweredIn1s: heap.answered,
    cpuUsageAnsweredIn1s: cpu.answered,
    cpuUserMicros: cpu.value?.user,
  }),
);
await worker.terminate();
```

### Main-thread termination through the inspector

`scripts/watchdog-worker.mjs`

```js
// Runs on a worker thread and terminates main-thread JavaScript through the inspector.
import { Session } from "node:inspector/promises";
import { parentPort } from "node:worker_threads";
const session = new Session();
session.connectToMainThread();
parentPort.on("message", async (message) => {
  if (message !== "terminate") return;
  const started = performance.now();
  await session.post("Runtime.terminateExecution");
  parentPort.postMessage({ kind: "terminated", postMs: performance.now() - started });
});
parentPort.postMessage({ kind: "ready" });
```

`scripts/preempt-inspector-plain.mjs`

```js
// Usage: node preempt-inspector-plain.mjs <timer|microtask|toplevel>
// Same as preempt-inspector.mjs without AsyncLocalStorage, from different entry points.
import { Worker } from "node:worker_threads";
const mode = process.argv[2] ?? "timer";
const watchdog = new Worker(new URL("./watchdog-worker.mjs", import.meta.url));
await new Promise((resolve) => watchdog.once("message", resolve));
const log = [];
const runaway = () => {
  watchdog.postMessage("terminate");
  for (;;) {}
};
queueMicrotask(() => log.push("other-microtask"));
setTimeout(() => log.push("other-timer"), 0);
const entries = {
  timer: () => setTimeout(runaway, 0),
  microtask: () => queueMicrotask(runaway),
  toplevel: () => runaway(),
};
entries[mode]();
setTimeout(() => {
  console.log(JSON.stringify({ mode, log, survived: true }));
  watchdog.terminate();
}, 300);
```

`scripts/preempt-inspector-order.mjs`

```js
// Usage: node preempt-inspector-order.mjs
// Does a microtask queued after the runaway microtask still run after termination?
import { Worker } from "node:worker_threads";
const watchdog = new Worker(new URL("./watchdog-worker.mjs", import.meta.url));
await new Promise((resolve) => watchdog.once("message", resolve));
const log = [];
setTimeout(() => {
  queueMicrotask(() => log.push("before-runaway"));
  queueMicrotask(() => {
    watchdog.postMessage("terminate");
    for (;;) {}
  });
  queueMicrotask(() => log.push("after-runaway"));
  Promise.resolve().then(() => log.push("promise-after-runaway"));
  setTimeout(() => log.push("later-timer"), 0);
}, 10);
setTimeout(() => {
  console.log(JSON.stringify({ log, survived: true }));
  watchdog.terminate();
}, 400);
```

`scripts/watchdog-delay-worker.mjs`

```js
// Waits, then terminates main-thread JavaScript through the inspector.
import { Session } from "node:inspector/promises";
import { parentPort } from "node:worker_threads";
const session = new Session();
session.connectToMainThread();
parentPort.on("message", ({ delayMs }) => {
  setTimeout(() => session.post("Runtime.terminateExecution"), delayMs);
});
parentPort.postMessage("ready");
```

`scripts/main-inspector-alloc2.mjs`

```js
// Usage: node main-inspector-alloc2.mjs <delayMs>
// The main thread enters the call-free allocation loop in a microtask; the watchdog terminates it after delayMs.
import { Worker } from "node:worker_threads";
const delayMs = Number(process.argv[2] ?? 50);
const watchdog = new Worker(new URL("./watchdog-delay-worker.mjs", import.meta.url));
await new Promise((resolve) => watchdog.once("message", resolve));
let started = 0;
setTimeout(
  () =>
    queueMicrotask(() => {
      watchdog.postMessage({ delayMs });
      started = performance.now();
      (() => {
        const sink = [];
        for (let n = 0; ; n++) sink[n & 1023] = new Array(64);
      })();
    }),
  10,
);
setTimeout(() => {
  console.log(
    JSON.stringify({
      delayMs,
      outcome: "main thread resumed",
      msAfterLoopStart: +(performance.now() - started).toFixed(1),
    }),
  );
  watchdog.terminate();
}, 1500);
```

### Heap limits

`scripts/oom-debug.mjs`

```js
import { Worker } from "node:worker_threads";
const worker = new Worker(new URL("./hog-worker.mjs", import.meta.url), {
  resourceLimits: { maxOldGenerationSizeMb: 32, maxYoungGenerationSizeMb: 8 },
});
for (const event of ["online", "message", "error", "exit", "messageerror"])
  worker.on(event, (value) =>
    console.log(performance.now().toFixed(0), event, value?.code ?? value?.message ?? value),
  );
const timer = setInterval(async () => {
  try {
    const h = await worker.getHeapStatistics();
    console.log(
      performance.now().toFixed(0),
      "heap MiB",
      (h.used_heap_size / 1048576).toFixed(1),
      "limit",
      (h.heap_size_limit / 1048576).toFixed(1),
    );
  } catch (e) {
    console.log("stats error", e.message);
  }
}, 500);
setTimeout(() => {
  console.log("giving up; rss MiB", (process.memoryUsage().rss / 1048576).toFixed(0));
  process.exit(0);
}, 5000);
```

`scripts/oom-debug2.mjs`

```js
import { Worker } from "node:worker_threads";
const script = process.argv[2] ?? "./hog-worker2.mjs";
const worker = new Worker(new URL(script, import.meta.url), {
  resourceLimits: { maxOldGenerationSizeMb: 32, maxYoungGenerationSizeMb: 8 },
});
const t0 = performance.now();
for (const event of ["message", "error", "exit"])
  worker.on(event, (value) =>
    console.log(
      (performance.now() - t0).toFixed(0),
      event,
      JSON.stringify(value?.code ?? value?.message ?? value),
    ),
  );
setTimeout(() => {
  console.log("giving up; rss MiB", (process.memoryUsage().rss / 1048576).toFixed(0));
  process.kill(process.pid, "SIGKILL");
}, 5000);
```

`scripts/hog-worker.mjs`

```js
import { parentPort } from "node:worker_threads";
const hoard = [];
parentPort.postMessage("allocating");
for (;;) hoard.push(new Array(1024).fill({ hoard: hoard.length }));
```

`scripts/hog-worker2.mjs`

```js
import { parentPort } from "node:worker_threads";
import v8 from "node:v8";
const hoard = [];
parentPort.postMessage({ limitMiB: v8.getHeapStatistics().heap_size_limit / 1048576 });
let n = 0;
for (;;) {
  hoard.push({ n: n++, s: "x" + n });
  if (n % 1000000 === 0)
    parentPort.postMessage({ n, usedMiB: v8.getHeapStatistics().used_heap_size / 1048576 });
}
```

`scripts/hog-worker3.mjs`

```js
import { parentPort } from "node:worker_threads";
const hoard = [];
parentPort.postMessage("allocating");
for (;;) {
  const chunk = new Array(1024);
  for (let i = 0; i < 1024; i++) chunk[i] = i;
  hoard.push(chunk);
}
```

`scripts/oom-single.mjs`

```js
// Usage: node --max-old-space-size=64 oom-single.mjs
// One "actor" in a shared isolate allocates forever; a second actor keeps ticking.
let ticks = 0;
setInterval(() => {
  ticks++;
}, 5);
process.on("exit", (code) => console.error(JSON.stringify({ event: "exit", code, ticks })));
const hoard = [];
setTimeout(function allocate() {
  for (let index = 0; index < 1000; index++) hoard.push(new Array(1024).fill({ index }));
  setImmediate(allocate);
}, 20);
```

### Shared state and npm packages

`scripts/shared-state.mjs`

```js
// Usage: node shared-state.mjs | bun shared-state.mjs
// Shows what two actors in one realm share: built-in prototypes and npm module singletons.
import vm from "node:vm";
import { z } from "/tmp/buoy-engines/npm-deps/node_modules/zod/index.js";
import { runtime } from "./lib.mjs";

const actorA = () => {
  z.globalRegistry.add(z.string(), { id: "actor-a-schema" }); // zod keeps this on globalThis.__zod_globalRegistry
  z.config({ jitless: true }); // zod keeps this on globalThis.__zod_globalConfig
  globalThis.AI_SDK_DEFAULT_PROVIDER = { name: "actor-a-provider" }; // ai reads this for string model ids
  Object.prototype.isAdmin = true; // prototype pollution
};
const attempt = (operation) => {
  try {
    operation();
    return "ok";
  } catch (error) {
    return `${error.name}: ${error.message}`;
  }
};
const actorB = () => ({
  seesPollutedObjectPrototype: {}.isAdmin === true,
  seesActorAZodSchemaId: z.globalRegistry._idmap.has("actor-a-schema"),
  seesActorAZodConfig: z.config().jitless === true,
  seesActorADefaultProvider: globalThis.AI_SDK_DEFAULT_PROVIDER?.name === "actor-a-provider",
  buildsZodSchemaAfterPollution: attempt(() => z.object({ name: z.string() })),
});
actorA();
const sameRealm = actorB();
delete Object.prototype.isAdmin;
const afterCleanup = attempt(() => z.object({ name: z.string() }));

// Separate vm contexts have their own intrinsics, but objects passed in keep the host prototypes.
const contextA = vm.createContext({});
const contextB = vm.createContext({ hostObject: {} });
vm.runInContext("Object.prototype.isAdmin = true", contextA);
const separateContexts = {
  contextBSeesContextAPollution: vm.runInContext("({}).isAdmin === true", contextB),
  hostSeesContextAPollution: {}.isAdmin === true,
  hostObjectInsideContextBHasHostPrototype: vm.runInContext(
    "Object.getPrototypeOf(hostObject) !== Object.prototype",
    contextB,
  ),
};
console.log(
  JSON.stringify(
    { runtime: runtime(), sameRealm, buildsZodSchemaAfterCleanup: afterCleanup, separateContexts },
    null,
    1,
  ),
);
```

`scripts/frozen-intrinsics.mjs`

```js
// Usage: node frozen-intrinsics.mjs [--preload-builtins] | bun frozen-intrinsics.mjs [--preload-builtins]
// Freezes common built-in prototypes, then runs the agent turn and a pollution attempt.
import { runtime } from "./lib.mjs";
if (process.argv.includes("--preload-builtins"))
  for (const name of [
    "fs",
    "path",
    "events",
    "stream",
    "util",
    "crypto",
    "os",
    "url",
    "http",
    "https",
    "zlib",
    "buffer",
  ])
    await import(`node:${name}`);
for (const constructor of [
  Object,
  Array,
  Function,
  String,
  Number,
  Boolean,
  Promise,
  Map,
  Set,
  RegExp,
  Error,
  Date,
]) {
  Object.freeze(constructor.prototype);
}
const pollution = (() => {
  try {
    Object.prototype.isAdmin = true;
    return "assignment did not throw";
  } catch (error) {
    return `${error.name}: ${error.message}`;
  }
})();
const { runAgentTurn } = await import("./agent-turn.mjs");
const turn = await runAgentTurn().then(
  (result) => ({ ok: true, streamedText: result.streamedText, plan: result.plan }),
  (error) => ({ ok: false, error: String(error) }),
);
console.log(JSON.stringify({ runtime: runtime(), pollution, turn }));
```

`scripts/agent-turn.mjs`

```js
// One agent turn with zod, ai, and @ai-sdk/openai, using a mock model so no network is needed.
import { z } from "/tmp/buoy-engines/npm-deps/node_modules/zod/index.js";
import {
  generateText,
  streamText,
  Output,
} from "/tmp/buoy-engines/npm-deps/node_modules/ai/dist/index.js";
import {
  MockLanguageModelV4,
  convertArrayToReadableStream,
} from "/tmp/buoy-engines/npm-deps/node_modules/ai/dist/test/index.js";
import { createOpenAI } from "/tmp/buoy-engines/npm-deps/node_modules/@ai-sdk/openai/dist/index.js";

const usage = {
  inputTokens: { total: 3, noCache: 3, cacheRead: undefined, cacheWrite: undefined },
  outputTokens: { total: 5, text: 5, reasoning: undefined },
};
const finishReason = { unified: "stop", raw: "stop" };

export const runAgentTurn = async () => {
  const openai = createOpenAI({ apiKey: "not-used" });
  const realModelId = openai("gpt-4o-mini").modelId;
  const Plan = z.object({ steps: z.array(z.string()).min(1) });
  const model = new MockLanguageModelV4({
    doGenerate: {
      content: [{ type: "text", text: JSON.stringify({ steps: ["search", "summarize"] }) }],
      finishReason,
      usage,
      warnings: [],
    },
    doStream: {
      stream: convertArrayToReadableStream([
        { type: "stream-start", warnings: [] },
        { type: "text-start", id: "t" },
        { type: "text-delta", id: "t", delta: "hello " },
        { type: "text-delta", id: "t", delta: "actor" },
        { type: "text-end", id: "t" },
        { type: "finish", finishReason, usage },
      ]),
    },
  });
  const generated = await generateText({
    model,
    prompt: "plan",
    output: Output.object({ schema: Plan }),
  });
  const streamed = streamText({ model, prompt: "greet" });
  let text = "";
  for await (const delta of streamed.textStream) text += delta;
  return { realModelId, plan: generated.output, streamedText: text };
};
```

`scripts/agent-worker.mjs`

```js
import { parentPort } from "node:worker_threads";
import { runAgentTurn } from "./agent-turn.mjs";
runAgentTurn().then(
  (result) => parentPort.postMessage({ ok: true, result }),
  (error) => parentPort.postMessage({ ok: false, error: String(error?.stack ?? error) }),
);
```

`scripts/npm-in-worker.mjs`

```js
// Usage: node npm-in-worker.mjs | bun npm-in-worker.mjs
// Runs one agent turn (zod + ai + @ai-sdk/openai) on the main thread and inside a worker thread.
import { Worker } from "node:worker_threads";
import { runAgentTurn } from "./agent-turn.mjs";
import { runtime } from "./lib.mjs";
const mainThread = await runAgentTurn().then(
  (result) => ({ ok: true, result }),
  (error) => ({ ok: false, error: String(error) }),
);
const worker = new Worker(new URL("./agent-worker.mjs", import.meta.url));
const inWorker = await new Promise((resolve) => worker.once("message", resolve));
await worker.terminate();
console.log(JSON.stringify({ runtime: runtime(), mainThread, inWorker }, null, 1));
```

`scripts/unhandled.mjs`

```js
// Does an unhandled rejection end the process while a timer keeps the loop alive?
const keepAlive = setInterval(() => {}, 1000);
setTimeout(() => {
  console.log("still alive after 300 ms");
  clearInterval(keepAlive);
}, 300);
Promise.reject(new Error("boom"));
```

### Deno

`scripts/deno-worker-cost.ts`

```ts
// Usage: deno run --allow-read --v8-flags=--expose-gc deno-worker-cost.ts [count]
// Spawns Web Workers one at a time, keeps them alive, and reports spawn latency and RSS per worker.
const count = Number(Deno.args[0] ?? 50);
const script = new URL("./deno-idle-worker.ts", import.meta.url).href;
const percentile = (values: number[], p: number) =>
  [...values].sort((a, b) => a - b)[
    Math.min(values.length - 1, Math.floor((p / 100) * values.length))
  ];
const spawnWorker = () =>
  new Promise<{ worker: Worker; ms: number }>((resolve) => {
    const started = performance.now();
    const worker = new Worker(script, { type: "module" });
    worker.onmessage = () => resolve({ worker, ms: performance.now() - started });
  });
const collect = () => (globalThis as unknown as { gc?: () => void }).gc?.();
const warm = await spawnWorker();
warm.worker.terminate();
await new Promise((r) => setTimeout(r, 200));
collect();
const rssBefore = Deno.memoryUsage().rss;
const workers: Worker[] = [];
const spawnMs: number[] = [];
for (let index = 0; index < count; index++) {
  const { worker, ms } = await spawnWorker();
  workers.push(worker);
  spawnMs.push(ms);
}
await new Promise((r) => setTimeout(r, 1000));
collect();
const rssAfter = Deno.memoryUsage().rss;
for (const worker of workers) worker.terminate();
console.log(
  JSON.stringify({
    runtime: `deno ${Deno.version.deno} v8 ${Deno.version.v8}`,
    workers: count,
    spawnToFirstMessageMs: {
      p50: +percentile(spawnMs, 50).toFixed(3),
      p95: +percentile(spawnMs, 95).toFixed(3),
    },
    rssPerWorkerMiB: +((rssAfter - rssBefore) / count / 1048576).toFixed(3),
  }),
);
```

`scripts/deno-idle-worker.ts`

```ts
self.onmessage = () => {};
self.postMessage("ready");
```

`scripts/deno-terminate.ts`

```ts
// Usage: deno run --allow-read deno-terminate.ts
// Calls terminate() on spinning workers and checks whether a shared counter keeps increasing.
const results: Record<string, unknown> = {};
for (const kind of ["empty", "newArray64"]) {
  const counter = new SharedArrayBuffer(4);
  const view = new Int32Array(counter);
  const worker = new Worker(new URL("./deno-spin-worker.ts", import.meta.url).href, {
    type: "module",
  });
  const spinning = new Promise((resolve) => (worker.onmessage = resolve));
  worker.postMessage({ kind, counter });
  await spinning;
  await new Promise((r) => setTimeout(r, 300));
  worker.terminate();
  const atTerminate = Atomics.load(view, 0);
  await new Promise((r) => setTimeout(r, 1000));
  const oneSecondLater = Atomics.load(view, 0);
  await new Promise((resolve) => setTimeout(resolve, 100));
  const later = Atomics.load(view, 0);
  results[kind] = {
    stillRunningOneSecondAfterTerminate: later > oneSecondLater,
    incrementsInFirstSecond: oneSecondLater - atTerminate,
    incrementsFrom1000To1100Ms: later - oneSecondLater,
  };
}
console.log(
  JSON.stringify({ runtime: `deno ${Deno.version.deno} v8 ${Deno.version.v8}`, results }),
);
Deno.exit(0);
```

`scripts/deno-spin-worker.ts`

```ts
self.onmessage = (event: MessageEvent<{ kind: string; counter: SharedArrayBuffer }>) => {
  const counter = new Int32Array(event.data.counter);
  const sink: unknown[] = [];
  self.postMessage("spinning");
  if (event.data.kind === "empty") for (;;) Atomics.add(counter, 0, 1);
  for (let n = 0; ; n++) {
    sink[n & 1023] = new Array(64);
    Atomics.add(counter, 0, 1);
  }
};
```

### isolated-vm

`scripts/ivm-cost.mjs`

```js
// Usage: node --no-node-snapshot --expose-gc ivm-cost.mjs [count]
// isolated-vm: bare V8 isolates inside one Node process. Reports creation cost, memory, and timeouts.
import { createRequire } from "node:module";
import { collectGarbage, summarize, runtime, mib } from "./lib.mjs";
const ivm = createRequire(import.meta.url)(
  process.env.IVM_PATH ?? "/tmp/buoy-engines/dl-ivm/node_modules/isolated-vm",
);
const count = Number(process.argv[2] ?? 200);

collectGarbage();
const before = process.memoryUsage().rss;
const isolates = [];
const createMs = [];
for (let index = 0; index < count; index++) {
  const started = performance.now();
  const isolate = new ivm.Isolate({ memoryLimit: 8 });
  const context = isolate.createContextSync();
  context.evalSync("[1, 2].map((x) => x * 2).length");
  createMs.push(performance.now() - started);
  isolates.push({ isolate, context });
}
collectGarbage();
const rssPerIsolateMiB = mib((process.memoryUsage().rss - before) / count);
const heap = isolates[0].isolate.getHeapStatisticsSync();

const timeoutOf = (source) => {
  const { isolate } = isolates[0];
  const context = isolate.createContextSync();
  const started = performance.now();
  try {
    context.evalSync(source, { timeout: 100 });
    return "returned";
  } catch (error) {
    return `${error.message} after ${(performance.now() - started).toFixed(1)} ms`;
  }
};
const emptyLoop = timeoutOf("for (;;) {}");
const oom = (() => {
  const isolate = new ivm.Isolate({ memoryLimit: 8 });
  const context = isolate.createContextSync();
  try {
    context.evalSync("const hoard = []; for (let n = 0; ; n++) hoard.push({ n, s: 'x' + n });");
    return "returned";
  } catch (error) {
    return `${error.message}; isolate.isDisposed=${isolate.isDisposed}`;
  }
})();
console.log(
  JSON.stringify(
    {
      runtime: runtime(),
      isolatedVm: "6.2.0",
      count,
      isolatePlusContextMs: summarize(createMs),
      rssPerIsolateMiB,
      oneIsolateUsedHeapKiB: Math.round(heap.used_heap_size / 1024),
      emptyLoopTimeout: emptyLoop,
      hostSurvivesIsolateOom: oom,
    },
    null,
    1,
  ),
);
```

`scripts/ivm-alloc-timeout.mjs`

```js
// Usage: node --no-node-snapshot ivm-alloc-timeout.mjs
// isolated-vm timeout against the call-free allocation loop.
import { createRequire } from "node:module";
const ivm = createRequire(import.meta.url)(process.env.IVM_PATH);
const isolate = new ivm.Isolate({ memoryLimit: 64 });
const context = isolate.createContextSync();
const started = performance.now();
setTimeout(() => {
  console.log(JSON.stringify({ outcome: "still running after 5 s" }));
  process.exit(2);
}, 5000).unref();
context
  .eval("(() => { const sink = []; for (let n = 0; ; n++) sink[n & 1023] = new Array(64); })()", {
    timeout: 100,
  })
  .catch((error) => {
    console.log(
      JSON.stringify({
        outcome: error.message,
        elapsedMs: +(performance.now() - started).toFixed(1),
      }),
    );
    process.exit(0);
  });
setInterval(() => {}, 1000);
```

### rusty_v8 probe

`rusty/Cargo.toml`

```toml
[package]
name = "isolate-cost"
version = "0.1.0"
edition = "2021"

[dependencies]
v8 = "=150.4.0"

[profile.release]
debug = false

[features]
ptrcomp = ["v8/v8_enable_pointer_compression"]
```

`rusty/src/main.rs`

```rust
// Measures bare V8 isolate and context cost and cross-thread termination latency through rusty_v8.
// Usage: isolate-cost <isolates|contexts|terminate|interrupt> [count] [script]
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

fn rss_kib() -> u64 {
    let pid = std::process::id().to_string();
    let output = Command::new("ps").args(["-o", "rss=", "-p", &pid]).output().expect("ps");
    String::from_utf8_lossy(&output.stdout).trim().parse().unwrap_or(0)
}

fn percentile(values: &mut Vec<f64>, p: f64) -> f64 {
    values.sort_by(|a, b| a.partial_cmp(b).unwrap());
    values[((p / 100.0) * values.len() as f64).floor().min(values.len() as f64 - 1.0) as usize]
}

fn run_script(isolate: &mut v8::Isolate, source: &str) -> Option<String> {
    let scope = std::pin::pin!(v8::HandleScope::new(isolate));
    let scope = &mut scope.init();
    let context = v8::Context::new(scope, Default::default());
    let scope = &mut v8::ContextScope::new(scope, context);
    let code = v8::String::new(scope, source).unwrap();
    let script = v8::Script::compile(scope, code, None)?;
    let value = script.run(scope)?;
    Some(value.to_rust_string_lossy(scope))
}

fn measure_isolates(count: usize) {
    let before = rss_kib();
    let mut create_ms = Vec::new();
    let mut first_context_ms = Vec::new();
    let mut isolates = Vec::new();
    for _ in 0..count {
        let started = Instant::now();
        let mut isolate = v8::Isolate::new(Default::default());
        create_ms.push(started.elapsed().as_secs_f64() * 1000.0);
        let started = Instant::now();
        run_script(&mut isolate, "[1, 2].map((x) => x * 2).length");
        first_context_ms.push(started.elapsed().as_secs_f64() * 1000.0);
        isolates.push(isolate);
    }
    std::thread::sleep(Duration::from_millis(200));
    let after = rss_kib();
    let stats = isolates[0].get_heap_statistics();
    println!(
        "{{\"mode\":\"isolates\",\"v8\":\"{}\",\"count\":{},\"createMsP50\":{:.3},\"createMsP95\":{:.3},\"contextPlusScriptMsP50\":{:.3},\"rssPerIsolateKiB\":{},\"oneIsolateUsedHeapKiB\":{},\"oneIsolateTotalHeapKiB\":{},\"heapLimitMiB\":{}}}",
        v8::V8::get_version(), count,
        percentile(&mut create_ms.clone(), 50.0), percentile(&mut create_ms, 95.0),
        percentile(&mut first_context_ms, 50.0),
        (after - before) / count as u64,
        stats.used_heap_size() / 1024, stats.total_heap_size() / 1024, stats.heap_size_limit() / 1048576
    );
    while let Some(isolate) = isolates.pop() {
        drop(isolate);
    }
}

fn measure_contexts(count: usize) {
    let mut isolate = v8::Isolate::new(Default::default());
    let scope = std::pin::pin!(v8::HandleScope::new(&mut isolate));
    let scope = &mut scope.init();
    let before = rss_kib();
    let mut keep = Vec::new();
    let mut create_us = Vec::new();
    for _ in 0..count {
        let started = Instant::now();
        let context = v8::Context::new(scope, Default::default());
        create_us.push(started.elapsed().as_secs_f64() * 1e6);
        keep.push(v8::Global::new(scope, context));
    }
    let after = rss_kib();
    println!(
        "{{\"mode\":\"contexts\",\"count\":{},\"createUsP50\":{:.1},\"createUsP95\":{:.1},\"rssPerContextKiB\":{:.1}}}",
        count, percentile(&mut create_us.clone(), 50.0), percentile(&mut create_us, 95.0),
        (after - before) as f64 / count as f64
    );
}

fn measure_terminate(script: &str, runs: usize) {
    let mut isolate = v8::Isolate::new(Default::default());
    let mut latencies = Vec::new();
    for _ in 0..runs {
        let handle = isolate.thread_safe_handle();
        let requested_at = Arc::new(Mutex::new(None::<Instant>));
        let requested = requested_at.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(300));
            *requested.lock().unwrap() = Some(Instant::now());
            handle.terminate_execution();
            std::thread::sleep(Duration::from_secs(5));
            println!("{{\"mode\":\"terminate\",\"outcome\":\"not terminated within 5 s\"}}");
            std::process::exit(2);
        });
        run_script(&mut isolate, script);
        let latency = requested_at.lock().unwrap().map(|t| t.elapsed().as_secs_f64() * 1000.0).unwrap_or(-1.0);
        latencies.push(latency);
        isolate.cancel_terminate_execution();
    }
    println!(
        "{{\"mode\":\"terminate\",\"runs\":{},\"latencyMsP50\":{:.3},\"latencyMsMax\":{:.3}}}",
        runs, percentile(&mut latencies.clone(), 50.0), percentile(&mut latencies, 100.0)
    );
    std::process::exit(0);
}

extern "C" fn on_interrupt(_isolate: v8::UnsafeRawIsolatePtr, data: *mut std::ffi::c_void) {
    let sender = unsafe { &*(data as *const Mutex<Option<Instant>>) };
    let requested = sender.lock().unwrap().take();
    if let Some(at) = requested {
        println!("{{\"mode\":\"interrupt\",\"callbackLatencyUs\":{:.1}}}", at.elapsed().as_secs_f64() * 1e6);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("isolates");
    let count: usize = args.get(2).and_then(|v| v.parse().ok()).unwrap_or(100);
    if let Ok(flags) = std::env::var("V8_FLAGS") {
        v8::V8::set_flags_from_string(&flags);
    }
    let platform = v8::new_default_platform(0, false).make_shared();
    v8::V8::initialize_platform(platform);
    v8::V8::initialize();
    match mode {
        "isolates" => measure_isolates(count),
        "contexts" => measure_contexts(count),
        "terminate" => measure_terminate(args.get(3).map(String::as_str).unwrap_or("for (;;) {}"), count),
        _ => {
            let mut isolate = v8::Isolate::new(Default::default());
            let requested: &'static Mutex<Option<Instant>> = Box::leak(Box::new(Mutex::new(None)));
            let handle = isolate.thread_safe_handle();
            let pointer = requested as *const _ as usize;
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(300));
                *unsafe { &*(pointer as *const Mutex<Option<Instant>>) }.lock().unwrap() = Some(Instant::now());
                handle.request_interrupt(on_interrupt, pointer as *mut std::ffi::c_void);
                std::thread::sleep(Duration::from_millis(300));
                std::process::exit(0);
            });
            run_script(&mut isolate, "for (;;) {}");
        }
    }
}
```

## Implications for Buoy

### Decide now

1. **Make the actor a light object in a shared isolate.** Per-actor isolates or workers cost 1 to 24 MiB each, against under 1 KiB for a light actor (8.3). Agent swarms of thousands of actors fit only the light model.
2. **Make the worker the failure domain, as a BEAM node.** Group actors into a pool of worker-thread schedulers (D1). Set `resourceLimits` on each worker. A supervisor in the main thread restarts a worker that dies, then restarts its actors from their specs. Do not resume a worker after a fault that may have touched module state (3.6).
3. **Never use engine termination to kill one actor in a shared isolate.** Termination drops the microtasks of every actor (Gap 2), and on Node's main thread it can abort the process (Gap 3). Kill and restart the whole worker instead.
4. **Insert yield points in the compiler.** No host preempts one actor in a shared isolate (9). Buoy must count reductions at loop back edges and calls in compiled code, and yield when the budget runs out. Code in npm packages has no such points, so a watchdog must detect a worker that stops answering and terminate it.
5. **Keep a process-level backstop.** Gap 1 lets a short loop ignore `worker.terminate()` and the worker heap limit, and Bun 1.3.11 and Deno 2.9.7 do not stop spinning workers at all. Run schedulers in a child process that a parent can kill with a signal, as Cloudflare runs cordons (2). File the Gap 1 scripts as a V8 bug.

### Build into the runtime

1. **Treat realm-wide state as shared node state.** Freeze the built-in prototypes in each worker before user code runs, so prototype pollution throws instead of spreading (8.1). On Bun, import the `node:` built-ins first. Document that packages such as zod and ai keep state on `globalThis`, shared by every actor of a worker.
2. **Pass handles, not objects, as actor addresses.** Structured clone drops prototypes and functions, and a cloned mailbox stops working (3.2). Copy message payloads by default; `structuredClone` raised a small round trip from 0.222 µs to 2.54 µs (3.2). Let the compiler skip the copy when it proves a value immutable.
3. **Build mailboxes on index or ring queues.** V8's `Array.prototype.shift()` took 4.2 s to drain 100,000 queued items (3.2).
4. **Attribute faults with `AsyncLocalStorage`.** The store survives into `uncaughtException` and `unhandledRejection` on Node 25.9.0 (3.4). Bun drops it for worker and message-port events, so fault attribution on Bun is partial.
5. **Copy the Durable Objects gates for persistent state.** Hold an actor's outgoing messages until its state write commits, and defer new deliveries while a storage operation runs (2).

### Track for later

1. **Keep D2 as a later path.** A Rust host gains isolate groups, CPU-time limits, and near-heap-limit control (1.3 to 1.5), but it must rebuild Node APIs (6). Keep the runtime boundary narrow (spawn, send, receive, link, monitor) so that a Rust host can implement it later.
2. **Watch pointer compression in Node.** It cut a bare isolate from about 1.05 MiB to 0.77 MiB here (1.2), and Platformatic reports half the memory for a real server (1.3). It breaks NAN addons, and the official Node builds do not enable it yet.
3. **Support Bun as a second host, with its gaps written down.** Bun workers start faster and use less memory (3.1), but Bun ignores `resourceLimits` and Bun 1.3.11 cannot stop a spinning worker (7).
