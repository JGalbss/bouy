# Measurements: BEAM and QuickJS comparison points

This note measures BEAM processes and QuickJS-wasm runtimes on the Bouy development machine. It also measures Node 25 actors inside one isolate with the same three benchmarks, in the same Linux VM. The architecture decision record uses these numbers for criterion 4 (Startup time and memory per actor) and criterion 5 (Message throughput and latency).

Every number below comes from `bench/evidence/results/beam-quickjs-2026-10-16-m5pro.json`. The `summary` object in that file holds the medians, minimums, and maximums. The `raw` object holds every run. The script `bench/evidence/beam/run-all.sh` produced the file on 2026-10-16 between 14:00:54Z and 14:04:07Z.

## Setup

| Item           | Value                                                                                                                                                                                                                                                |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Host           | Apple M5 Pro (`Mac17,8`), 18 cores, 64 GB (68,719,476,736 bytes), macOS 26.6.1 (25G76), Darwin 25.6.0                                                                                                                                                |
| Docker         | Docker Engine 29.4.0. The active Docker context is `orbstack`, not Docker Desktop.                                                                                                                                                                   |
| Linux VM       | OrbStack VM, kernel `7.0.14-orbstack-00380-ga7e0a2dc9535`, 18 CPUs, 16,817,172,480 bytes of memory                                                                                                                                                   |
| Erlang image   | `erlang:29.1.2` (`sha256:563a62a5a6dae274c2a95679a5364cad79f655ed484e6620f98911b4dc773692`): OTP 29, ERTS 17.1.1, JIT emulator, word size 8                                                                                                          |
| Node image     | `node:25.9.0` (`sha256:78839ac448c23517f8eab2e8f7943d9b4f73979eb7f8bed2c73dbf72ff869e7b`): Node v25.9.0, V8 14.1.146.11-node.25, Debian 12                                                                                                           |
| Native Node    | Node v25.9.0, V8 14.1.146.11-node.25, darwin arm64                                                                                                                                                                                                   |
| Native QuickJS | `alpine:3.22` (3.22.6, `sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8`) with the package `quickjs-0.20250426-r0` (QuickJS 2025-04-26)                                                                                      |
| QuickJS-wasm   | `quickjs-emscripten` 0.32.0, default `RELEASE_SYNC` variant: bellard/quickjs 2025-09-13+f1139494, built with `-Oz -flto` ([variant README](https://github.com/justjake/quickjs-emscripten/tree/main/packages/variant-quickjs-wasmfile-release-sync)) |

OrbStack runs containers in "a lightweight Linux virtual machine" ([OrbStack architecture](https://docs.orbstack.dev/architecture)). Docker Desktop also runs containers in a Linux VM on macOS ([Docker VMM docs](https://docs.docker.com/desktop/features/vmm/)). Absolute numbers inside the VM differ from native runs. The Node rows below show both, so the size of the difference is visible.

Other workloads ran on the host during the measurement. The host load average was between 11.1 and 20.0 (one-minute value) on 18 cores. The `host_load` array in the results file records it at the start of each batch. This load adds noise. The ranges in the tables show its size.

## How to reproduce

```sh
# One-time scratch install outside the repository. quickjs-emscripten is not a repo dependency.
mkdir -p /tmp/bouy-qjs && cd /tmp/bouy-qjs && npm init -y && npm install quickjs-emscripten@0.32.0

# From the repository root: runs every batch below, then writes the results file.
sh bench/evidence/beam/run-all.sh bench/evidence/results/beam-quickjs-2026-10-16-m5pro.json
```

`run-all.sh` runs these commands. Each benchmark runs 5 times in a fresh VM or process.

| Batch                     | Command                                                                                                                   |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| BEAM                      | `docker run --rm -v "$PWD/bench/evidence/beam:/bench:ro" erlang:29.1.2 sh /bench/run-beam.sh`                             |
| Node in Docker            | `docker run --rm -v "$PWD/bench/evidence/beam:/bench:ro" node:25.9.0 sh /bench/run-node.sh`                               |
| Node native               | `sh bench/evidence/beam/run-node.sh`                                                                                      |
| QuickJS-wasm native       | `node --expose-gc /tmp/bouy-qjs/measure-quickjs.mjs 1000 100 1000000`                                                     |
| QuickJS-wasm in Docker    | `docker run --rm -v /private/tmp/bouy-qjs:/qjs:ro node:25.9.0 node --expose-gc /qjs/measure-quickjs.mjs 1000 100 1000000` |
| fib(27) in V8             | `node bench/evidence/quickjs/fib.js` and `node --jitless bench/evidence/quickjs/fib.js`, native and in `node:25.9.0`      |
| fib(27) in native QuickJS | `docker run --rm -v "$PWD/bench/evidence/quickjs:/q:ro" alpine:3.22 sh -c 'apk add --no-cache quickjs && qjs /q/fib.js'`  |

`run-all.sh` copies `measure-quickjs.mjs` and `fib.js` into `/tmp/bouy-qjs` first. `measure-quickjs.mjs` is plain JavaScript because `tsc` cannot resolve `quickjs-emscripten` inside the repository. `bench/evidence/beam/summarize.jq` computes the `summary` object from the raw runs.

## Method

### BEAM: `bench/evidence/beam/actor_bench.erl`

- Every run starts a fresh VM with `erl -noshell +P 2097152`. The default process limit is 1,048,576 ([erl flags](https://www.erlang.org/doc/apps/erts/erl_cmd.html)), so `+P` raises it.
- "18 schedulers" is the default on this VM. "1 scheduler" adds `+S 1:1`.
- **Spawn.** One process calls `spawn(actor_bench, idle, [])` 1,000,000 times and keeps the pids in a list. `idle/0` waits in `receive`. The script waits until every process has status `waiting`, then reads memory.
- **Memory per process.** The script takes the growth of `erlang:memory(processes)`, subtracts the growth of the measuring process, and divides by 1,000,000. It also sums `process_info(Pid, memory)`, which is "the size in bytes of the process", including "call stack, heap, and internal structures" ([erlang module](https://www.erlang.org/doc/apps/erts/erlang.html)).
- **Hibernated spawn.** Each process calls `erlang:hibernate/3` first. Hibernation discards the call stack, collects garbage, and shrinks the heap to the live data ([erlang module](https://www.erlang.org/doc/apps/erts/erlang.html)).
- **Round trip.** A client sends `{ping, Self}` and waits for `pong`. The run does 100,000 warm-up round trips, then 1,000,000 untimed round trips for the mean and the throughput. Then it does 1,000,000 round trips with `erlang:monotonic_time(nanosecond)` around each one for the percentiles. `gen-server-call` repeats this with `gen_server:call/2`.
- **Ring.** 10,000 processes form a ring. A counter starts at 1,000,000 and each process decrements it and forwards it. The run ends when a process receives 0, after 1,000,000 hops.

### Node: `bench/evidence/beam/node-actors.ts`

- A `Mailbox` is an async iterator with a FIFO array and one pending resolver. An actor is an async function that reads its mailbox with `for await`. A send passes a reference and does not copy the message.
- **Spawn.** `spawn-async` starts 1,000,000 async-function actors that wait in `for await`. `spawn-async-als` starts each one inside `AsyncLocalStorage.run(index, ...)`. Node 24 and later implement `AsyncLocalStorage` with `AsyncContextFrame` by default ([Node 24 release notes](https://nodejs.org/en/blog/release/v24.0.0)). `spawn-object` creates 1,000,000 objects that hold a mailbox and a closure, with no suspended function.
- **Memory per actor.** The script forces two garbage collections before and after, then divides the growth of `heapUsed` by 1,000,000. A registry array keeps every actor reachable. The array is part of the measured growth.
- **Round trip and ring.** These use the same counts as the BEAM runs. `performance.now()` times each round trip.
- Node runs the `.ts` file directly with type stripping, which is on by default since Node 23.6.0 ([Node TypeScript docs](https://nodejs.org/api/typescript.html)).

### QuickJS-wasm: `bench/evidence/quickjs/measure-quickjs.mjs`

- `getQuickJS()` returns one shared module ([source](https://github.com/justjake/quickjs-emscripten/blob/main/packages/quickjs-emscripten/src/mod.ts)). The script creates 1,000 runtimes, then 1,000 contexts in one shared runtime, then 1,000 runtime and context pairs in that module.
- `newQuickJSWASMModule()` creates "a new, completely isolated WebAssembly module" ([source](https://github.com/justjake/quickjs-emscripten/blob/main/packages/quickjs-emscripten-core/src/from-variant.ts)). The script creates 100 such modules with one context each.
- **QuickJS memory used** is the "memory used" line of `runtime.dumpMemoryUsage()`. QuickJS computes this estimate from its own data structures.
- **RSS growth** is the growth of the Node process RSS after a forced collection. It includes allocator overhead, page granularity, and the host-side wrapper objects.
- **Round trip between runtimes.** Two runtime and context pairs live in one module. The host passes the string `"ping"` into the server context, reads `"pong"`, and passes it into the client context. Each step uses `newString`, `callFunction`, and `getString`. The counts match the BEAM round trip: 100,000 warm-up, 1,000,000 untimed, and 1,000,000 timed.
- **fib(27).** `bench/evidence/quickjs/fib.js` defines a recursive `fib` and times 6 calls of `fib(27)`. Each engine runs the same file. Inside QuickJS-wasm the host times 6 more calls of `fib(27)` with `performance.now()`. The tables report the median of the last 5 calls in each process.

### Statistics and timer resolution

- Each cell shows the median of 5 runs, with the minimum and maximum in parentheses.
- A percentile is the sample at position `ceil(fraction × count)` in sorted order.
- On this host, every recorded latency percentile is within 1 ns of a multiple of 41.67 ns. The p50 values therefore move in steps of about 42 ns.
- The mean interval between two back-to-back clock reads is 17.4 ns for BEAM, 24.4 ns for Node in Docker, and 11.8 ns for native Node. Each timed round trip includes that interval. The untimed mean does not.

## Results

### 1. Spawn 1,000,000 idle actors

| Runtime and configuration                              | Time per spawn (ns)    | Memory per idle actor (bytes) |
| ------------------------------------------------------ | ---------------------- | ----------------------------- |
| BEAM, 18 schedulers                                    | 1,212 (1,101 to 1,517) | 2,632                         |
| BEAM, 1 scheduler                                      | 1,467 (1,239 to 1,564) | 2,632                         |
| BEAM hibernated, 18 schedulers                         | 876 (768 to 1,044)     | 824                           |
| BEAM hibernated, 1 scheduler                           | 1,024 (934 to 1,091)   | 824                           |
| Node in Docker, async actor                            | 500 (476 to 513)       | 752                           |
| Node in Docker, async actor in `AsyncLocalStorage.run` | 743 (648 to 784)       | 936                           |
| Node in Docker, object actor                           | 104 (78 to 110)        | 216                           |
| Node native, async actor                               | 402 (344 to 787)       | 752                           |
| Node native, async actor in `AsyncLocalStorage.run`    | 625 (545 to 1,616)     | 936                           |
| Node native, object actor                              | 97 (87 to 183)         | 216                           |

- BEAM memory is the `erlang:memory(processes)` growth per process. It varied by less than 1 byte across runs. `process_info(Pid, memory)` reports 2,624 bytes for an idle process (heap 233 words, stack 1 word) and 800 bytes for a hibernated one (heap 5 words).
- Node memory is the `heapUsed` growth per actor. RSS growth per actor is 915 bytes (async), 1,075 bytes (async with `AsyncLocalStorage`), and 248 bytes (object) in Docker.

### 2. Request and reply, 1,000,000 round trips

| Runtime and configuration                       | Mean, untimed (ns)     | Round trips per second | p50 (ns)               | p99 (ns)               | p99.9 (ns)   |
| ----------------------------------------------- | ---------------------- | ---------------------- | ---------------------- | ---------------------- | ------------ |
| BEAM send/receive, 18 schedulers                | 505 (454 to 572)       | 1,978,475              | 458 (417 to 458)       | 875 (708 to 1,166)     | 17,292       |
| BEAM send/receive, 1 scheduler                  | 530 (518 to 561)       | 1,888,025              | 500 (459 to 542)       | 834 (792 to 1,417)     | 11,916       |
| BEAM `gen_server:call`, 18 schedulers           | 908 (803 to 1,076)     | 1,100,747              | 750 (750 to 791)       | 1,833 (1,333 to 3,459) | 26,042       |
| BEAM `gen_server:call`, 1 scheduler             | 848 (810 to 896)       | 1,179,939              | 833 (792 to 917)       | 1,459 (1,208 to 1,792) | 16,542       |
| Node in Docker, async actors                    | 159 (121 to 168)       | 6,286,303              | 166 (125 to 167)       | 250 (167 to 291)       | 3,042        |
| Node native, async actors                       | 111 (93 to 348)        | 8,986,553              | 125 (125 to 167)       | 250 (167 to 292)       | 3,167        |
| QuickJS-wasm, two runtimes via the host, Docker | 1,580 (1,463 to 1,795) | 632,972                | 1,125 (1,041 to 1,333) | 8,792 (8,000 to 9,626) | not recorded |
| QuickJS-wasm, two runtimes via the host, native | 1,661 (1,445 to 2,436) | 602,085                | 1,042 (792 to 1,208)   | 2,375 (1,541 to 2,833) | not recorded |

The columns for round trips per second and p99.9 show only the median across runs.

### 3. Ring of 10,000 actors, 100 laps (1,000,000 hops)

| Runtime and configuration | Ring setup (ms) | Time per hop (ns) | Hops per second |
| ------------------------- | --------------- | ----------------- | --------------- |
| BEAM, 18 schedulers       | 6.68            | 273 (256 to 288)  | 3,669,221       |
| BEAM, 1 scheduler         | 5.91            | 305 (299 to 342)  | 3,279,845       |
| Node in Docker            | 6.44            | 80 (78 to 110)    | 12,514,464      |
| Node native               | 5.82            | 102 (83 to 151)   | 9,772,492       |

### 4. QuickJS-wasm creation cost and memory

| What the script creates                     | Create time per item, Docker | Create time per item, native | QuickJS memory used per item (bytes) | RSS growth per item, Docker (bytes) | RSS growth per item, native (bytes) |
| ------------------------------------------- | ---------------------------- | ---------------------------- | ------------------------------------ | ----------------------------------- | ----------------------------------- |
| 1,000 runtimes                              | 11.9 µs (10.3 to 12.7)       | 12.2 µs (11.6 to 17.1)       | 11,778                               | 22,471                              | 19,726                              |
| 1,000 contexts in one runtime               | 104.5 µs (93.1 to 109.6)     | 137.9 µs (112.9 to 240.7)    | 33,569                               | 42,779                              | 42,320                              |
| 1,000 runtime and context pairs             | 76.8 µs (66.3 to 81.7)       | 92.7 µs (80.5 to 337.1)      | 52,654                               | 66,060                              | 66,241                              |
| 100 separate wasm modules, one context each | 2.51 ms (2.20 to 2.71)       | 3.36 ms (2.23 to 5.13)       | not measured                         | 340,460                             | 440,074                             |

- Each separate module starts with 16,777,216 bytes (16 MiB) of wasm linear memory. RSS grew by 0.34 to 0.44 MB per module.
- Linear memory in the shared module grew by 40,239 bytes per context and 65,012 bytes per pair. The runtimes batch ran first, when the module already had 16 MiB of linear memory. Its growth of 3,408 bytes per runtime therefore understates the cost.
- The host-side V8 heap grew by 1,910 bytes per runtime, 1,725 bytes per context, 3,418 bytes per pair, and 82,511 bytes per module in Docker.

### 5. CPU-bound code: `fib(27)` (ms)

| Engine                                              | Native macOS           | Docker (Linux VM)      |
| --------------------------------------------------- | ---------------------- | ---------------------- |
| V8 14.1 with JIT (Node 25.9.0)                      | 1.28 (1.27 to 1.36)    | 1.38 (1.27 to 1.45)    |
| V8 14.1 with `--jitless`                            | 11.30 (10.58 to 12.07) | 12.19 (11.43 to 12.76) |
| QuickJS 2025-04-26, native build (Alpine package)   | not run                | 14.03 (13.28 to 15.53) |
| QuickJS 2025-09-13, wasm build (quickjs-emscripten) | 22.97 (15.55 to 29.57) | 18.70 (17.36 to 18.92) |

The first call in a fresh process took 1.62 ms (V8 with JIT, native), 11.05 ms (`--jitless`, native), and 13.89 ms (native QuickJS, Docker). V8 `--jitless` runs JavaScript in the Ignition interpreter and disables the optimizing compiler ([V8 blog](https://v8.dev/blog/jitless)).

## What the numbers show

- An idle BEAM process uses 2,632 bytes. The Erlang efficiency guide gives 327 words for a new process ([efficiency guide](https://www.erlang.org/doc/system/eff_guide_processes.html)), which is 2,616 bytes at 8 bytes per word. Hibernation cuts this to 824 bytes, a 69% reduction.
- An idle async-function actor in one V8 heap uses 752 bytes. An idle BEAM process uses 3.5 times as much. A hibernated BEAM process uses 1.1 times as much.
- An object actor with no suspended function uses 216 bytes. The async actor uses 536 bytes more than the object actor.
- One `AsyncLocalStorage.run` per actor adds 184 bytes and about 240 ns to each spawn (Docker medians).
- A BEAM spawn takes 1.2 to 1.5 µs. An async actor spawn takes 0.4 to 0.5 µs.
- A raw BEAM round trip takes about 0.5 µs, and `gen_server:call` takes 0.85 to 0.91 µs. BEAM copies message data between process heaps ([efficiency guide](https://www.erlang.org/doc/system/eff_guide_processes.html)). The in-isolate round trip passes a reference and takes 0.11 to 0.16 µs. In the same VM, a raw BEAM round trip takes 3.2 times as long.
- A ring hop takes 273 to 305 ns on BEAM and 80 to 102 ns in one V8 isolate.
- One scheduler or 18 schedulers changes the BEAM results by less than 25%. These benchmarks pass one message at a time, so they do not test multicore throughput.
- A QuickJS-wasm runtime and context pair uses 52,654 bytes by QuickJS accounting and about 66,000 bytes of RSS. That is 20 to 25 times an idle BEAM process and 70 times the heap of an async actor. Creating a pair takes 77 to 93 µs. In Docker, that is 63 times a BEAM spawn.
- A separate wasm module per actor costs 2.5 to 3.4 ms, 0.34 to 0.44 MB of RSS, and a 16 MiB linear memory reservation.
- A QuickJS-wasm round trip between two runtimes through the Node host takes about 1.6 µs. That is 3.1 times a raw BEAM round trip and 9.9 times an in-isolate round trip (Docker).
- On `fib(27)`, QuickJS-wasm is 13.6 times slower than V8 with JIT in Docker. Natively it is 17.9 times slower, with a wide spread across runs (15.55 to 29.57 ms). It is 1.33 times slower than the native QuickJS build. The two QuickJS builds differ in version and compiler flags. V8 `--jitless` is 1.15 times faster than native QuickJS.
- The Linux VM leaves the Node heap sizes unchanged. It changes the Node timings by factors from 0.78 to 1.43 (Docker over native), in both directions.

## Limits and unverified points

- The host ran other workloads during the measurement. An idle host would verify the absolute values, mostly the maximums and the native QuickJS-wasm `fib` spread.
- The BEAM numbers measure bare processes. Option A adds a JavaScript compatibility layer, and option D3 adds a JavaScript engine behind a NIF or port. Neither cost is measured. A prototype of either would verify it.
- The QuickJS numbers measure bellard/quickjs builds. The wasm build runs inside V8 in Node. Option B with `rquickjs` compiles QuickJS-NG, a fork of QuickJS, as native code ([rquickjs README](https://github.com/DelSkayn/rquickjs)). Option D4 uses a Wasm host such as Wasmtime or Lunatic. A Rust harness that reads `rquickjs` memory usage, and a Wasmtime harness for a Javy or StarlingMonkey module, would verify those costs.
- The QuickJS round trip passes 4-byte strings. Larger JSON messages add serialization cost that this note does not measure.
- No benchmark here measures parallel message throughput across cores or fairness under load.
- Docker Desktop was not used. A run under the `desktop-linux` context would show whether its VM changes the numbers.

## Sources

- Erlang efficiency guide, processes: https://www.erlang.org/doc/system/eff_guide_processes.html
- Erlang `erlang` module (`memory/1`, `process_info/2`, `hibernate/3`): https://www.erlang.org/doc/apps/erts/erlang.html
- Erlang `erl` command flags (`+P`, `+S`): https://www.erlang.org/doc/apps/erts/erl_cmd.html
- Official Erlang image tags: https://hub.docker.com/_/erlang
- OrbStack architecture: https://docs.orbstack.dev/architecture
- Docker Desktop virtual machine managers: https://docs.docker.com/desktop/features/vmm/
- Node.js TypeScript type stripping: https://nodejs.org/api/typescript.html
- Node.js 24.0.0 release notes (`AsyncContextFrame`): https://nodejs.org/en/blog/release/v24.0.0
- V8 JIT-less mode (2019-03-13): https://v8.dev/blog/jitless
- QuickJS: https://bellard.org/quickjs/
- quickjs-emscripten README: https://github.com/justjake/quickjs-emscripten/blob/main/README.md
- quickjs-emscripten `getQuickJS` source: https://github.com/justjake/quickjs-emscripten/blob/main/packages/quickjs-emscripten/src/mod.ts
- quickjs-emscripten `newQuickJSWASMModuleFromVariant` source: https://github.com/justjake/quickjs-emscripten/blob/main/packages/quickjs-emscripten-core/src/from-variant.ts
- quickjs-emscripten release-sync variant: https://github.com/justjake/quickjs-emscripten/tree/main/packages/variant-quickjs-wasmfile-release-sync
- rquickjs README: https://github.com/DelSkayn/rquickjs
