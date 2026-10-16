# Measurements: JavaScript isolation units on Node 25 and Bun 1.3.11

> Paths under `packages/`, `e2e/`, `examples/`, and `bench/` refer to commit [`90529d8`](https://github.com/JGalbss/bouy/tree/90529d8), the last commit with the Node runtime.

This note records what each JavaScript isolation unit costs on one machine. The architecture decision record uses the numbers for three designs:

- Option C: many actors inside one isolate on Node, Deno, or Bun.
- Option D1: a Node host with a pool of worker-thread schedulers, each running many actors.
- The hard-isolation variant: one worker thread or one child process per actor.

Every number below comes from `bench/evidence/results/node-2026-10-16-m5pro.json`. The scripts in `bench/evidence/` wrote that file at 2026-10-16T14:08:02.173Z.

## Machine

| Item             | Value                                                              | How it was read                                                                                    |
| ---------------- | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| CPU              | Apple M5 Pro, 18 cores: 6 "Super" cores and 12 "Performance" cores | `sysctl hw.perflevel0.name hw.perflevel0.physicalcpu hw.perflevel1.name hw.perflevel1.physicalcpu` |
| Memory           | 64 GiB (68,719,476,736 bytes)                                      | `os.totalmem()`, recorded in the results file                                                      |
| Operating system | macOS 26.6.1, Darwin 25.6.0                                        | `sw_vers`, `os.version()`                                                                          |
| Node             | v25.9.0, Homebrew build, V8 14.1.146.11-node.25                    | `node --version`, `process.versions.v8`                                                            |
| Bun              | 1.3.11                                                             | `bun --version`                                                                                    |
| Power            | AC power, `powermode 2`                                            | `pmset -g`                                                                                         |
| Clock            | 24 MHz timebase, so one `process.hrtime()` step is 41.67 ns        | `sysctl -n hw.tbfrequency`                                                                         |

Other jobs ran on the machine during the measurement. The 1-minute load average was between 7.6 and 14.3 on 18 cores. The results file records the load before each run. Each script also reports its involuntary context switches. That count grows each time the operating system gives the CPU to another process ([Node `process.resourceUsage()`](https://nodejs.org/api/process.html#processresourceusage)). Load can raise latency percentiles and spawn times. The memory numbers changed little between runs, as the ranges in the E1 table show.

## Method

`bench/evidence/run.ts` runs every script 5 times. It interleaves the scripts, so a change in load affects all experiments alike. Each table shows the median of the 5 runs. The range in parentheses shows the lowest and the highest run. Inside one run, latency percentiles use the nearest-rank method over all samples of that run.

Run all experiments from the repository root:

```sh
node bench/evidence/run.ts
```

The runner parses the script output with `zod`, a dependency of the `@bouy/bench` package. It takes about 2 minutes on this machine and overwrites the results file. The file is plain `JSON.stringify` output, so run `pnpm format` before you commit a new copy. Each script also runs alone and prints one JSON object. Each section gives the command for its script.

## E1. Spawn cost and memory per unit

Command: `node --expose-gc bench/evidence/spawn-cost.ts`

- Light actor: an object with a `state` number, an empty array as the mailbox, and a `receive` closure that updates `state`. The script creates 100,000 actors and keeps them in one array. It calls `gc()` before and after, and divides the change in `heapUsed` by 100,000. The result includes the 8-byte array slot that holds each actor.
- vm context: 1,000 calls of `vm.createContext()`, measured the same way. Node states that "the `node:vm` module is not a security mechanism" ([vm](https://nodejs.org/api/vm.html)).
- Worker thread: 64 workers, created one at a time from an inline echo script with `new Worker(source, { eval: true })`. The time runs from `new Worker()` to the `online` event. Node emits `online` "when the worker thread has started executing JavaScript code" ([worker_threads](https://nodejs.org/api/worker_threads.html)). The memory is the change in process RSS after all 64 workers answered one message, divided by 64. `worker.getHeapStatistics()` reports the V8 heap of each worker.
- Child process: 16 children from `child_process.fork()`, created one at a time. Node states that each forked process "has its own memory, with their own V8 instances" ([child_process](https://nodejs.org/api/child_process.html)). The time runs from `fork()` to the first IPC message from the child. `ps -o rss=` gives the RSS of each child in 1024-byte units (macOS `man ps`; [FreeBSD ps(1)](https://man.freebsd.org/cgi/man.cgi?query=ps&sektion=1)). The script forks two kinds of child. The first runs an inline JavaScript echo script through `execArgv: ["-e", source]`. The second runs the TypeScript file `bench/evidence/echo-child.ts`, which Node type-strips.

| Unit                             |   Count | Spawn time: median of runs (range)                  | Memory per unit: median of runs (range)                               |
| -------------------------------- | ------: | --------------------------------------------------- | --------------------------------------------------------------------- |
| Light actor                      | 100,000 | 153 ns (125–192)                                    | 184.0 bytes of V8 heap (184.0–184.0)                                  |
| vm context                       |   1,000 | 259 µs (192–325)                                    | 161.8 KiB of V8 heap (161.8–161.8); 203.3 KiB of RSS                  |
| Worker thread                    |      64 | p50 12.8 ms (8.8–16.0); p99 19.6 ms (12.5–45.4)     | 6.29 MiB of RSS (6.28–6.31); worker V8 heap 4.04 MiB used of 6.39 MiB |
| Child process, inline JavaScript |      16 | p50 66.2 ms (44.2–73.9); p99 82.0 ms (49.4–140.2)   | 46.8 MiB of RSS (46.7–46.8)                                           |
| Child process, `.ts` file        |      16 | p50 93.8 ms (67.6–145.0); p99 111.6 ms (73.8–234.3) | 70.4 MiB of RSS (69.4–71.2)                                           |

With 64 or 16 samples in a run, the nearest-rank p99 is the slowest sample of that run.

A `.ts` entry file makes Node load its internal module `internal/deps/amaro/dist/index`, and a `.mjs` entry file does not. A one-off probe shows this: `printf 'console.log(process.moduleLoadList.filter((name) => name.includes("amaro")))' > /tmp/probe.ts && node /tmp/probe.ts && cp /tmp/probe.ts /tmp/probe.mjs && node /tmp/probe.mjs`. The `.ts` run prints the module name, and the `.mjs` run prints an empty list. Node's TypeScript parser needs WebAssembly ([Node TypeScript docs](https://nodejs.org/api/typescript.html)). E1 does not show how much of the extra 23.6 MiB of RSS per child comes from that module.

## E2. Request/reply latency and throughput

Commands: `node bench/evidence/request-reply.ts` and `bun bench/evidence/request-reply.ts`

Each transport has one echo peer. The requester sends a number and waits for the echo.

- Latency: 2,000 warm-up round trips, then 20,000 sequential round trips. `process.hrtime.bigint()` times each round trip.
- Throughput: 64 concurrent request lanes with 1,500 round trips each, so 96,000 round trips in total. A 1 ms `setInterval` timer counts its own callbacks during this window. The count shows whether the event loop ran timers while the transport was busy.
- In-isolate transports: one actor with a mailbox array, a run queue, and a scheduler loop that empties the run queue. One variant schedules the loop with `queueMicrotask`. The other variant schedules it with `setImmediate`, which runs in the check phase after the poll phase of the event loop ([Node event loop guide](https://nodejs.org/en/learn/asynchronous-work/event-loop-timers-and-nexttick)).
- Worker transport: `worker.postMessage()` to an inline echo worker. Node copies the value "in a way which is compatible with the HTML structured clone algorithm" ([worker_threads](https://nodejs.org/api/worker_threads.html)).
- Child process transport: `child.send()` to an inline echo child from `fork()`. The default IPC serialization is JSON ([child_process](https://nodejs.org/api/child_process.html)).

| Transport                            | Runtime | p50 µs (range)         | p99 µs (range)         | Million round trips per second, window 64 (range) | Timer callbacks in the window / window length |
| ------------------------------------ | ------- | ---------------------- | ---------------------- | ------------------------------------------------- | --------------------------------------------- |
| In-isolate, microtask scheduler      | Node    | 0.167 (0.125–0.250)    | 1.000 (0.292–1.333)    | 14.70 (10.99–20.14)                               | 0 / 6.5 ms                                    |
| In-isolate, microtask scheduler      | Bun     | 0.125 (0.125–0.125)    | 1.417 (1.250–2.000)    | 8.94 (7.51–10.80)                                 | 0 / 10.7 ms                                   |
| In-isolate, `setImmediate` scheduler | Node    | 13.416 (13.125–14.791) | 68.625 (27.291–97.917) | 3.26 (1.98–3.60)                                  | 30 / 29.5 ms                                  |
| In-isolate, `setImmediate` scheduler | Bun     | 0.417 (0.375–0.458)    | 2.042 (0.750–3.041)    | 9.25 (8.06–12.30)                                 | 10 / 10.4 ms                                  |
| Worker `MessagePort`                 | Node    | 8.5 (7.2–10.3)         | 38.9 (27.5–54.2)       | 0.57 (0.53–0.68)                                  | 117 / 167.1 ms                                |
| Worker `MessagePort`                 | Bun     | 8.5 (8.5–12.2)         | 65.5 (14.1–108.7)      | 0.43 (0.39–0.90)                                  | 131 / 221.1 ms                                |
| Child process IPC                    | Node    | 16.0 (9.8–19.4)        | 66.8 (19.1–76.9)       | 0.84 (0.74–1.23)                                  | 115 / 114.3 ms                                |
| Child process IPC                    | Bun     | 9.5 (8.6–10.8)         | 59.4 (22.3–110.1)      | 0.66 (0.21–1.00)                                  | 137 / 144.8 ms                                |

In the two microtask rows and the Bun `setImmediate` row, the percentiles are a few clock steps of 41.67 ns. For those rows, the throughput column is the more exact number. The last column shows the median timer count and the median window length as two separate medians.

## E3. Message copy cost

Command: `node bench/evidence/message-copy.ts`

The small payload is one object with 5 primitive fields, 77 bytes as JSON. The medium payload is an array of 100 such objects, 7,941 bytes as JSON. The large payload is an array of 10,000 such objects, 813,891 bytes as JSON. Each method runs 5 trials per payload. One trial copies the small payload 200,000 times, the medium payload 5,000 times, or the large payload 50 times. Each run reports the median of its 5 trials, and each cell is the median of the 5 runs. Before it times a method, the script checks one copy with `assert.deepStrictEqual`. The recursive copy uses `Array.prototype.map` for arrays and an `Object.keys` loop for objects.

| Payload               | `structuredClone` (range) | `JSON.parse(JSON.stringify(x))` (range) | Recursive copy (range) |
| --------------------- | ------------------------- | --------------------------------------- | ---------------------- |
| Small, 1 object       | 728 ns (581–886)          | 284 ns (237–290)                        | 73 ns (67–84)          |
| Medium, 100 objects   | 39.7 µs (33.9–53.4)       | 21.3 µs (17.4–22.1)                     | 8.1 µs (6.4–8.4)       |
| Large, 10,000 objects | 4.20 ms (4.00–6.91)       | 2.28 ms (2.05–3.03)                     | 0.81 ms (0.75–0.83)    |

## E4. AsyncLocalStorage cost per call

Command: `node bench/evidence/async-context-cost.ts`

Each arm makes 500,000 sequential calls of an async function that awaits one resolved promise. The script interleaves the arms over 5 trials.

- Bare call: the async function alone.
- `run()`: `storage.run(1, call)` on every call.
- Snapshot: the script calls `AsyncLocalStorage.snapshot()` once inside `storage.run(1, ...)` and reuses the returned function for every call. `snapshot()` "captures the current execution context and returns a function" that runs its argument in that context ([async_context](https://nodejs.org/api/async_context.html)).

Since v24.0.0, Node backs `AsyncLocalStorage` with `AsyncContextFrame`, and `--no-async-context-frame` restores the older implementation on `async_hooks` ([Node CLI docs](https://nodejs.org/api/cli.html#--no-async-context-frame)). E4 measures the default. The script asserts that the store is visible after the await, both inside `run()` and through the snapshot.

| Arm                      | ns per call (range) | Extra ns per call over the bare call (range) |
| ------------------------ | ------------------- | -------------------------------------------- |
| Bare call                | 48 (40–50)          | 0                                            |
| `storage.run()` per call | 214 (206–227)       | 166 (162–176)                                |
| Snapshot captured once   | 102 (89–108)        | 57 (48–59)                                   |

The extra cost is the median of the per-trial differences, so it is not exactly the difference of the two medians.

## E5. Preemption-check overhead

Command: `node bench/evidence/preemption-check.ts`

The loop body is `total = (total + index) | 0`, and the loop runs 100,000,000 times. Each variant first runs 1,000,000 iterations to warm up. The script interleaves the variants over 5 trials. The budget is 4,000 checks per slice, the value of `CONTEXT_REDS` in the BEAM source ([erl_vm.h](https://github.com/erlang/otp/blob/master/erts/emulator/beam/erl_vm.h)).

- No check.
- Module counter: decrement a module-level counter on every iteration and compare it with zero.
- Imported call: call `spendReduction()` from `bench/evidence/reductions.ts` on every iteration. That function decrements and compares a counter in its own module. `node --trace-turbo-inlining bench/evidence/preemption-check.ts` shows that TurboFan inlined `spendReduction` into the loop.
- Local slice: decrement a local counter on every iteration. Every 1,024 iterations, charge 1,024 to the module-level budget.
- Index mask: test `(index & 1023) === 0` on every iteration, and charge 1,024 to the module-level budget on a hit. The task did not ask for this variant. It shows a check that adds no counter to the loop.

| Variant                  | ms per 100,000,000 iterations (range) | ns per iteration | Extra ns per iteration | Overhead against no check |
| ------------------------ | ------------------------------------- | ---------------- | ---------------------- | ------------------------- |
| No check                 | 28.2 (26.6–30.0)                      | 0.28             | 0                      | 0%                        |
| Module counter           | 86.5 (79.2–116.3)                     | 0.86             | 0.58                   | 213%                      |
| Imported call            | 119.5 (109.5–507.0)                   | 1.20             | 0.91                   | 332%                      |
| Local slice, every 1,024 | 85.6 (83.3–120.9)                     | 0.86             | 0.57                   | 213%                      |
| Index mask, every 1,024  | 48.5 (46.7–63.5)                      | 0.49             | 0.20                   | 72%                       |

The overhead percentages hold for this loop body only. A loop body that does more work per iteration gives a smaller percentage for the same extra nanoseconds.

## E6. Fault attribution with AsyncLocalStorage

Commands: `node bench/evidence/fault-attribution.ts` and `bun bench/evidence/fault-attribution.ts`

Each fault starts inside `storage.run(actorName, ...)`. The throwing callback records the store it sees. The process listeners for `uncaughtException` and `unhandledRejection` record the store that they see. The script prints its report 500 ms after it starts. All 5 runs on each runtime gave the same values.

The two cross-actor faults use an emitter that the actor `listener-actor` creates and subscribes to. The actor `emitting-actor` calls `emit()` from a timer. Listeners on an ordinary `EventEmitter` "run in the same async context as the emit()", and listeners on an `EventEmitterAsyncResource` run in the async context of the emitter ([events](https://nodejs.org/api/events.html#class-eventseventemitterasyncresource-extends-eventemitter)). Bun documents that it does not propagate `AsyncLocalStorage` context into `MessagePort`, `BroadcastChannel`, or `Worker` events ([Bun Node.js compatibility](https://bun.com/docs/runtime/nodejs-compat)).

| Fault source                                            | Node: process event | Node: store at throw / in listener  | Bun: process event | Bun: store at throw / in listener |
| ------------------------------------------------------- | ------------------- | ----------------------------------- | ------------------ | --------------------------------- |
| `setTimeout` callback                                   | uncaughtException   | timer / timer                       | uncaughtException  | timer / timer                     |
| `queueMicrotask` callback                               | uncaughtException   | microtask / microtask               | uncaughtException  | microtask / none                  |
| Floating promise rejection                              | unhandledRejection  | floating-promise / floating-promise | unhandledRejection | floating-promise / none           |
| `EventEmitter` listener, same actor                     | uncaughtException   | emitter / emitter                   | uncaughtException  | emitter / emitter                 |
| `fs.readFile` callback                                  | uncaughtException   | io-callback / io-callback           | unhandledRejection | io-callback / none                |
| `EventEmitter` listener, other actor emits              | uncaughtException   | emitting-actor / emitting-actor     | uncaughtException  | emitting-actor / emitting-actor   |
| `EventEmitterAsyncResource` listener, other actor emits | uncaughtException   | listener-actor / emitting-actor     | uncaughtException  | listener-actor / emitting-actor   |

## What the numbers show

- Memory per unit: a light actor uses 184 bytes of V8 heap. A vm context uses 900 times that heap. A worker thread adds 6.3 MiB of RSS, and a forked Node process uses 47 MiB of RSS, or 70 MiB when its entry file is TypeScript.
- Spawn time: a light actor takes 153 ns, a vm context 259 µs, a worker 12.8 ms to come online (p50), and a child process 66 ms to its first IPC message (p50) under the recorded load.
- Round trip on Node: the in-isolate actor with a microtask scheduler answers in 0.17 µs (p50). A worker answers in 8.5 µs (p50), and a child process in 16.0 µs (p50). With 64 requests in flight, the in-isolate actor completed 14.7 million round trips per second, the worker 0.57 million, and the child process 0.84 million.
- Scheduler hop: on Node, one `setImmediate` hop per scheduler pass raised the in-isolate p50 from 0.17 µs to 13.4 µs. On Bun the same change gave 0.42 µs. The microtask scheduler let 0 timer callbacks run during its 6.5 ms window on Node and 0 during 10.7 ms on Bun. The `setImmediate` scheduler let timers run about once per millisecond.
- Copy cost: for all three payloads, `structuredClone` was the slowest method and the recursive copy the fastest. For 10,000 objects, `structuredClone` took 4.2 ms and the recursive copy 0.8 ms.
- Context cost: `storage.run()` around a call with one await added 166 ns. A snapshot captured once added 57 ns.
- Preemption checks: each variant that decrements a counter on every iteration added 0.57 to 0.91 ns per iteration. That holds for the local slice too, although it charges the budget only every 1,024 iterations. The index mask added 0.20 ns per iteration. The imported function cost more than the module counter although TurboFan inlined it.
- Fault attribution on Node 25: for all five same-actor fault sources, the process listener saw the store of the actor that started the work. For both cross-actor emitter faults, the process listener saw the store of the emitting actor. `EventEmitterAsyncResource` ran the listener in the listener actor's context, but the process listener still saw the emitting actor.
- Fault attribution on Bun 1.3.11: the process listener lost the store for the microtask, floating-promise, and `fs.readFile` faults. Bun reported the throw in the `fs.readFile` callback as `unhandledRejection`.

## Limits

- Other jobs loaded the machine. Spawn times and latency percentiles on an idle machine are likely lower. A rerun with no other load would verify this.
- The scripts did not run on Deno. E1, E3, E4, and E5 did not run on Bun.
- E1 spawns workers and children one at a time. It does not measure concurrent spawns, workers with `resourceLimits`, or actors whose mailboxes have grown.
- E1 counts the memory of a light actor with an empty mailbox and an unused closure. An actor with real state uses more.
- E2 sends a number as the message. E3 gives the copy cost of larger messages separately.
- E5 measures a synchronous loop. It does not measure the cost of suspending and resuming an actor when its budget runs out.
- E6 covers the listed fault sources only. It does not cover errors inside streams, native addons, or worker threads.

## Sources

All pages were read on 2026-10-16.

- Node.js `child_process`: <https://nodejs.org/api/child_process.html>
- Node.js `worker_threads`: <https://nodejs.org/api/worker_threads.html>
- Node.js `vm`: <https://nodejs.org/api/vm.html>
- Node.js `async_context`: <https://nodejs.org/api/async_context.html>
- Node.js CLI, `--no-async-context-frame`: <https://nodejs.org/api/cli.html#--no-async-context-frame>
- Node.js `events`, `EventEmitterAsyncResource`: <https://nodejs.org/api/events.html#class-eventseventemitterasyncresource-extends-eventemitter>
- Node.js `process.resourceUsage()`: <https://nodejs.org/api/process.html#processresourceusage>
- Node.js TypeScript support: <https://nodejs.org/api/typescript.html>
- Node.js event loop guide: <https://nodejs.org/en/learn/asynchronous-work/event-loop-timers-and-nexttick>
- Bun Node.js compatibility: <https://bun.com/docs/runtime/nodejs-compat>
- Erlang/OTP `erl_vm.h`, `CONTEXT_REDS`: <https://github.com/erlang/otp/blob/master/erts/emulator/beam/erl_vm.h>
- FreeBSD `ps(1)`: <https://man.freebsd.org/cgi/man.cgi?query=ps&sektion=1>
