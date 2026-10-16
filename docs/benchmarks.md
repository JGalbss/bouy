# Benchmarks: Bouy against plain Node.js and plain Bun

This document compares the Bouy runtime with plain TypeScript that does the same work, on Node and on Bun. Every number below comes from one of three results files, except the figures that the text attributes to a commit message or to ADR 0001. The load averages are the 1-, 5-, and 15-minute values on 18 logical cores.

| Host         | Results file                                            | Command                      | Run started (UTC)   | Load average at start | Load average at end |
| ------------ | ------------------------------------------------------- | ---------------------------- | ------------------- | --------------------- | ------------------- |
| Node         | `bench/results/node-2026-10-16-m5pro.json`              | `node bench/run.ts`          | 2026-10-16 15:30:29 | 7.21, 10.8, 12.7      | 33.9, 21.0, 16.4    |
| Bun          | `bench/results/bun-2026-10-16-m5pro.json`               | `bun bench/run.ts`           | 2026-10-16 15:34:28 | 33.9, 21.0, 16.4      | 33.0, 26.8, 19.9    |
| Node and Bun | `bench/fairness/results/fairness-2026-10-16-m5pro.json` | `node bench/fairness/run.ts` | 2026-10-16 15:14:12 | 14.1, 12.7, 15.3      | 11.3, 12.8, 14.8    |

Other jobs loaded the machine during all three runs. Read [Load](#load) before you rely on a wall time. Read [Source](#source) before you compare these numbers with the code at HEAD. The runs used the runtime from its TypeScript source, before commit `86b0df8` bundled it.

## Machine and versions

| Item             | Value                                                           | Source                                    |
| ---------------- | --------------------------------------------------------------- | ----------------------------------------- |
| CPU              | Apple M5 Pro, 18 logical cores                                  | `machine` in the results files            |
| Memory           | 64 GiB (68,719,476,736 bytes)                                   | `machine` in the results files            |
| Operating system | macOS 26.6.1, Darwin 25.6.0                                     | `sw_vers`, `machine` in the results files |
| Node             | v25.9.0                                                         | `versions` in the results files           |
| Bun              | 1.3.11                                                          | `versions` in the results files           |
| Effect           | 4.0.5                                                           | `packages/bouy/package.json`              |
| Bouy             | commit `16b86fd`, with the changes in [Source](#source)         | `source` in the results files             |
| Clock            | 24 MHz timebase, so `process.hrtime` moves in steps of 41.67 ns | `sysctl -n hw.tbfrequency`                |

### Source

`bench/run.ts` hashes every file in `packages/bouy/src` and `crates/bouy-compiler/src` at the start and at the end of a run. It also records `git status` for those paths at the start.

- Node: the hash at the start matches commit `16b86fd` with no local changes. The hash at the end differs, so the runtime source changed during the run. The file does not record which suite runs loaded which version.
- Bun: the hash is the same at the start and at the end, and it equals the Node end hash. That source is commit `16b86fd` with local changes to `Actor.ts`, `ActorSystem.ts`, and `Sendable.ts` in `packages/bouy/src/runtime/`. Commit `0ff2ab8` changes the same three files, but no commit has this hash.
- Both runs imported `bouy` from the TypeScript files in `packages/bouy/src`, because the package exports pointed at `src/` before commit `86b0df8`. At HEAD, the exports and the CLI point at `packages/bouy/dist/`, so a new run measures the bundle.
- The fairness file records no commit and no hash. Its `summary` lists `bun ../node_modules/bouy/src/cli/main.ts run fairness.ts` for the Bun CLI host, so that run also used the CLI from source.

## Commands

Build the packages with `pnpm build`, then run each host from the repository root. A session starts every suite 5 times and overwrites the results file for its host and date. Each session records only the version of its own host, so the Node session does not need Bun on the `PATH`. At the load below, the suite processes took 237 s in total on Node and 200 s on Bun (the `seconds` field of each suite).

```sh
node bench/run.ts    # the same as: pnpm --filter @bouy/bench bench
bun bench/run.ts
```

The runner writes `JSON.stringify` output with an indent of 2. Run `pnpm format` before you commit a new copy, because `pnpm check` checks the format of the results files.

Each suite also runs alone and prints one JSON object. Use `bun` in place of `node` for the Bun host.

```sh
node --expose-gc bench/suites/spawn.ts
node bench/suites/request-reply.ts
node bench/suites/fan-out.ts
node bench/suites/fairness.ts
node bench/suites/streaming.ts
node bench/suites/messages.ts
node bench/suites/startup.ts
```

## Method

- Every suite run is a fresh process. The runner interleaves the suites, so a change in machine load spreads across all of them.
- A table cell shows the median of the 5 runs in one session, where a session is one run of `bench/run.ts`. The parentheses show the lowest and the highest of those 5 runs. They show the spread inside one session and do not bound the spread between sessions.
- p50 and p99 are the 50th and 99th percentiles of the samples in one run. They use the nearest-rank method (`percentile` in `bench/evidence/measure.ts`).
- A ratio divides two medians from the same table, so both medians come from the same session. The ratios are the main result.
- The spawn, request-reply, fan-out, streaming, and messages suites run their TypeScript file directly. Neither Bouy nor the baselines go through the Bouy compiler there, so no loop in those suites pays for a preemption check.
- The fairness and startup suites start child processes. When the runner recorded these files, `bouy run` meant `<host> bench/node_modules/bouy/src/cli/main.ts run <file>` (`bench/suite.ts` at commit `c450390`). At HEAD, `bouyRun` in `bench/suite.ts` runs `bench/node_modules/bouy/dist/cli.mjs` instead. The `node_modules/.bin/bouy` shell shim adds one `/bin/sh` start, which these numbers leave out.

The baselines:

- **Plain class instance**: `new Counter()`, with no messaging.
- **Hand-written actor**: `PlainActor` in `bench/plain-actor.ts`. It is an object with an array mailbox. A send pushes a closure and, if the actor is idle, schedules one microtask that runs the mailbox. The actor runs one message at a time and waits for an async result before it starts the next message. It does not copy messages, contain failures, or restart.
- **Direct async call**: `await instance.echoLater(value)` on a plain object.
- **Worker**: a `worker_threads` worker that runs the inline echo script from `bench/evidence/echo.ts`.

## Load

Other jobs ran on the machine during all runs. Before each suite run, the 1-minute load average was between 7.0 and 38.5 for the Node session and between 30.6 and 36.6 for the Bun session. The results files record the load before each suite run. The two hosts ran at different loads, so a difference between a Node cell and a Bun cell can come from the load.

Inside one session, the load moved some metrics more than others:

- Memory per unit moved little. The heap per Bouy actor on Node stayed between 8,637 and 8,676 bytes in all 10 measured batches.
- CPU time moved more. The per-run CPU medians of `node hello.ts` ranged from 330 to 430 ms, and those of `bouy run hello.ts` on Node from 575 to 915 ms.
- Wall times and tail latencies moved most. Single samples of `bouy run hello.ts` on Node took between 465 and 5,085 ms, and its per-run medians ranged from 521 to 3,327 ms. The per-run p99 of a worker round trip ranged from 34.4 to 422 µs on Node and from 196 to 946 µs on Bun.

Each host has one recorded session, so these ranges do not show how much the numbers change between sessions. Rely on the ratios. Treat an absolute time as one session on a loaded machine. Before you quote a time, record a second session or a session on a quiet machine.

## Spawn

Command: `node --expose-gc bench/suites/spawn.ts` and `bun --expose-gc bench/suites/spawn.ts`.

The suite creates a batch of 10,000 units of each kind, then a batch of 100,000, and keeps each batch in one array. It calls `gc()` before and after a batch. It divides the change in `v8.getHeapStatistics().used_heap_size` and in the resident set size (RSS) by the batch size. On Bun 1.3.11, `process.memoryUsage().heapUsed` does not grow when a script allocates objects, so the suite does not use it. Each kind first runs a warm-up batch of 1,000. The Bouy runtime already exists when a measured batch starts, so the suite does not count its one-time setup. The suite calls `shutdown()` between the two Bouy batches and times that call.

The worker row starts 64 workers one at a time and times each one from `new Worker()` to its `online` event. Its time per unit is the mean of the 64 times in each run. A worker has its own heap, so the worker row uses RSS for memory. The worker ratios compare it with the 100,000-actor Bouy row. RSS grows only when the process maps new pages, so at 10,000 units it can grow less than the heap. Use the 100,000 rows for RSS.

| Host | Unit                    |   Count | Time per unit, µs      | V8 heap per unit, KiB  | RSS per unit, KiB       | Bouy time ÷ row | Bouy memory ÷ row |
| ---- | ----------------------- | ------: | ---------------------- | ---------------------- | ----------------------- | --------------: | ----------------: |
| Node | Plain class instance    |  10,000 | 0.0281 (0.0244–0.0336) | 0.0395 (0.0394–0.0395) | 0 (0–0.00800)           |            733× |              214× |
| Node | Hand-written actor      |  10,000 | 0.0608 (0.0425–0.0668) | 0.126 (0.125–0.126)    | 0 (0–0.00320)           |            338× |             67.2× |
| Node | Bouy `spawn()`          |  10,000 | 20.6 (13.5–24.8)       | 8.46 (8.43–8.46)       | 1.61 (1.46–1.74)        |              1× |                1× |
| Node | Plain class instance    | 100,000 | 0.0282 (0.0222–0.0481) | 0.0391 (0.0391–0.0391) | 0.0101 (0.00832–0.0130) |            545× |              217× |
| Node | Hand-written actor      | 100,000 | 0.0460 (0.0366–0.0538) | 0.125 (0.125–0.125)    | 0.0379 (0.0346–0.0387)  |            334× |             67.7× |
| Node | Bouy `spawn()`          | 100,000 | 15.4 (11.4–17.8)       | 8.47 (8.46–8.47)       | 7.65 (7.58–8.03)        |              1× |                1× |
| Node | `worker_threads` Worker |      64 | 13,450 (10,395–16,743) | not measured           | 6,277 (6,264–6,295)     |        0.00114× |    0.00122× (RSS) |
| Bun  | Plain class instance    |  10,000 | 0.0202 (0.0146–0.0270) | 0.0707 (0.0706–0.0708) | 0.224 (0.221–0.238)     |            843× |              121× |
| Bun  | Hand-written actor      |  10,000 | 0.0247 (0.0202–0.0797) | 0.195 (0.195–0.196)    | 0.0288 (0.0128–0.0320)  |            690× |             43.6× |
| Bun  | Bouy `spawn()`          |  10,000 | 17.0 (13.9–34.3)       | 8.53 (8.52–8.53)       | 8.39 (8.25–9.00)        |              1× |                1× |
| Bun  | Plain class instance    | 100,000 | 0.0156 (0.0140–0.0262) | 0.0704 (0.0704–0.0704) | 0.0722 (0.0720–0.0766)  |          1,788× |              120× |
| Bun  | Hand-written actor      | 100,000 | 0.0332 (0.0318–0.0429) | 0.195 (0.195–0.195)    | 0.150 (0.148–0.155)     |            841× |             43.4× |
| Bun  | Bouy `spawn()`          | 100,000 | 27.9 (15.1–39.5)       | 8.47 (8.46–8.47)       | 11.1 (10.8–11.4)        |              1× |                1× |
| Bun  | `worker_threads` Worker |      64 | 6,563 (5,880–7,310)    | not measured           | 4,501 (4,466–4,608)     |        0.00426× |    0.00246× (RSS) |

The same runs also give these numbers:

| Host | `shutdown()` per actor, 10,000 actors, µs | Worker `online` p50, ms | Worker `online` p99, ms |
| ---- | ----------------------------------------- | ----------------------- | ----------------------- |
| Node | 29.9 (17.6–68.8)                          | 13.2 (10.4–16.5)        | 23.3 (12.8–31.0)        |
| Bun  | 25.6 (15.5–26.6)                          | 6.32 (5.92–6.99)        | 10.4 (7.66–18.9)        |

With 64 workers in a run, the nearest-rank p99 is the slowest worker of that run.

ADR 0001 quotes 14.7 KiB and 21.9 µs per Bouy actor on Node. Those figures come from an earlier session that no results file keeps. The message of commit `16b86fd` reports that the heap per idle actor fell from 15.1 KiB to 8.9 KiB. The commit measured 20,000 actors.

## Request-reply

Command: `node bench/suites/request-reply.ts` and `bun bench/suites/request-reply.ts`.

Every variant replies with the number it receives. A variant first makes 5,000 warm-up calls. Then it makes 50,000 sequential calls and times each one with `process.hrtime.bigint()`. For the throughput column, 64 callers start at once and each makes 1,000 sequential calls, so 64 calls are in flight.

The arguments and the replies are numbers. Numbers take the primitive fast path in `copyArguments` and `copyValue` (`packages/bouy/src/runtime/Sendable.ts`) and skip the Schema walk. The [messages](#messages) suite measures the Schema walk.

The ratio columns compare a row with the Bouy call of the same method kind. The ratios of the sync rows and the worker row use the Bouy `ref.echo()` row. The ratios of the async rows use the Bouy `ref.echoLater()` row.

| Host | Call                                 | p50, µs                | p99, µs              | Thousand calls/s, 64 in flight | Bouy p50 ÷ row | Row calls/s ÷ Bouy |
| ---- | ------------------------------------ | ---------------------- | -------------------- | ------------------------------ | -------------: | -----------------: |
| Node | Bouy `ref.echo()`, sync method       | 1.75 (1.42–2.17)       | 17.6 (13.5–21.5)     | 461 (295–562)                  |             1× |                 1× |
| Node | Bouy `ref.echoLater()`, async method | 1.50 (1.46–2.29)       | 15.2 (11.8–18.5)     | 383 (155–558)                  |             1× |                 1× |
| Node | Direct `instance.echoLater()`        | 0.0420 (0.0420–0.0420) | 0.125 (0.0840–0.125) | 4,792 (4,728–7,825)            |          35.7× |              12.5× |
| Node | Hand-written actor, sync method      | 0.167 (0.166–0.208)    | 0.459 (0.292–0.833)  | 4,039 (3,196–6,297)            |          10.5× |              8.76× |
| Node | Hand-written actor, async method     | 0.167 (0.125–0.167)    | 0.375 (0.250–0.625)  | 3,653 (770–4,771)              |          8.98× |              9.53× |
| Node | Worker `MessagePort` round trip      | 9.13 (8.04–13.5)       | 164 (34.4–422)       | 390 (209–596)                  |         0.192× |             0.846× |
| Bun  | Bouy `ref.echo()`, sync method       | 1.29 (1.00–1.38)       | 10.5 (9.67–10.8)     | 218 (95.8–560)                 |             1× |                 1× |
| Bun  | Bouy `ref.echoLater()`, async method | 1.50 (1.38–1.58)       | 11.9 (9.25–12.6)     | 349 (130–475)                  |             1× |                 1× |
| Bun  | Direct `instance.echoLater()`        | 0.0420 (0.0420–0.0420) | 0.292 (0.250–0.417)  | 3,955 (2,698–4,268)            |          35.7× |              11.3× |
| Bun  | Hand-written actor, sync method      | 0.166 (0.166–0.167)    | 0.958 (0.958–1.21)   | 2,688 (963–2,783)              |          7.78× |              12.3× |
| Bun  | Hand-written actor, async method     | 0.208 (0.208–0.208)    | 0.875 (0.875–1.04)   | 2,039 (300–2,258)              |          7.21× |              5.84× |
| Bun  | Worker `MessagePort` round trip      | 17.1 (9.46–25.4)       | 410 (196–946)        | 242 (190–399)                  |        0.0754× |              1.11× |

The p50 values of the direct call and of the hand-written actor are between 0.0420 and 0.208 µs, which is 1 to 5 clock steps of 41.67 ns. Those latencies are therefore coarse, and so are the latency ratios against them.

## Fan-out

Command: `node bench/suites/fan-out.ts` and `bun bench/suites/fan-out.ts`.

Each of 1,000 agents awaits 5 calls of `setTimeout(1)` from `node:timers/promises`, one after another. The plain variant runs the async function `research()` 1,000 times under `Promise.all`. The Bouy variant spawns 1,000 `Agent` actors before the clock starts, then calls `research()` on each ref under `Promise.all`. The actor method calls the same function. The suite alternates the two variants for 30 rounds and reports the median round of each. Each run computes its overhead per call as (Bouy median round − plain median round) ÷ 1,000. The overhead column shows the median of the 5 per-run overheads. It can differ from the Bouy wall-time median minus the plain wall-time median, divided by 1,000. Five sequential 1 ms timers put a floor of 5 ms under both variants.

| Host | Variant                                  | Wall time, ms    | Overhead per call, µs | Bouy ÷ plain |
| ---- | ---------------------------------------- | ---------------- | --------------------- | -----------: |
| Node | `Promise.all` over plain async functions | 8.03 (7.02–10.9) |                       |           1× |
| Node | Bouy, 1,000 actors                       | 16.9 (11.5–28.2) | 9.05 (4.53–17.3)      |        2.11× |
| Bun  | `Promise.all` over plain async functions | 7.64 (7.31–8.61) |                       |           1× |
| Bun  | Bouy, 1,000 actors                       | 16.2 (14.3–18.7) | 8.53 (6.92–10.3)      |        2.12× |

## Fairness

Command: `node bench/suites/fairness.ts` and `bun bench/suites/fairness.ts`. Program: `bench/programs/noisy-neighbor.ts`.

The program spawns two actors. `Cruncher.crunch()` is an async method that spins in a `while` loop until 2,000 ms have passed. `Pinger.ping()` returns its argument. The main module gives each 1 ms slot of the 2,000 ms window one ping, and it sends the pings one after another. It measures each ping from the start of its slot to the reply. A ping that leaves late therefore counts its wait, so the percentiles avoid coordinated omission, the error that hides the time when no ping could leave.

The suite runs the program four times per run:

- `compiled` runs the program under `bouy run`. The compiler puts `if (__bouy.tick()) await __bouy.pause();` at the top of the `while` loop.
- `plain` runs the same file directly, with no preemption point.
- `busy` sets `NEIGHBOR_CPU_MS=2000`, so the loop spins for the whole window.
- `idle` sets `NEIGHBOR_CPU_MS=0`, so `crunch()` returns at once. The idle rows show the latency floor of the timers and of the loaded machine.

| Host | Mode     | Neighbor | Pings | Ping p50, ms        | Ping p99, ms        | Ping max, ms        | Loop rounds, millions | p99 ÷ compiled p99 |
| ---- | -------- | -------- | ----: | ------------------- | ------------------- | ------------------- | --------------------- | -----------------: |
| Node | compiled | busy     | 2,001 | 2.25 (2.17–2.45)    | 6.57 (6.49–15.2)    | 8.22 (8.15–22.1)    | 89.6 (76.9–102)       |                 1× |
| Node | plain    | busy     | 2,001 | 1,018 (1,011–1,020) | 1,982 (1,981–1,982) | 2,001 (2,000–2,001) | 98.7 (79.2–102)       |               302× |
| Node | compiled | idle     | 2,001 | 0.594 (0.562–1.28)  | 3.90 (1.20–219)     | 9.73 (1.28–239)     | 0                     |                 1× |
| Node | plain    | idle     | 2,001 | 0.580 (0.557–0.853) | 1.85 (1.19–25.8)    | 4.95 (2.49–35.2)    | 0                     |             0.474× |
| Bun  | compiled | busy     | 2,001 | 3.05 (2.31–9.91)    | 45.9 (13.8–119)     | 59.8 (27.5–139)     | 64.5 (31.4–87.8)      |                 1× |
| Bun  | plain    | busy     | 2,001 | 1,018 (1,015–1,055) | 1,982 (1,982–2,018) | 2,001 (2,000–2,037) | 56.3 (22.5–93.7)      |              43.1× |
| Bun  | compiled | idle     | 2,001 | 0.767 (0.721–0.904) | 10.5 (2.75–67.1)    | 21.8 (7.43–86.7)    | 0                     |                 1× |
| Bun  | plain    | idle     | 2,001 | 0.723 (0.629–0.782) | 2.95 (1.65–10.9)    | 6.92 (4.59–30.8)    | 0                     |             0.283× |

## Fairness bound

Command: `node bench/fairness/run.ts`. Program: `e2e/test/fairness.ts`.

The program spins one actor for 1,000 ms and sends a ping to a second actor every 50 ms, 20 pings in all. The runner starts the program 30 times on each host, in turn, and keeps the latency of every ping. [The e2e README](../e2e/README.md#the-fairness-bound) describes the program and the 250 ms bound that `e2e/fairness.test.ts` asserts. Before each run, the 1-minute load average was between 11.3 and 18.2.

| Host                          | Worst ping, lowest run | Worst ping, median run | Worst ping, highest run |
| ----------------------------- | ---------------------: | ---------------------: | ----------------------: |
| `node via bouy run`           |                2.85 ms |                3.74 ms |                  143 ms |
| `node --import bouy/register` |                2.52 ms |                3.41 ms |                  172 ms |
| `bun via bouy run`            |                3.71 ms |                4.34 ms |                 98.6 ms |
| `bun --preload bouy/register` |                3.69 ms |                4.25 ms |                 94.2 ms |
| `plain node`                  |               1,002 ms |               1,003 ms |                1,084 ms |

## Streaming

Command: `node bench/suites/streaming.ts` and `bun bench/suites/streaming.ts`.

`Feed.count(100000)` is an `async *` method that yields the numbers 0 to 99,999. The suite reads it with `for await`, once through a Bouy ref and once from a plain `Feed` instance, for 5 rounds each. It checks the sum and reports the median rate.

| Host | Variant                     | Million items/s    | Plain ÷ Bouy |
| ---- | --------------------------- | ------------------ | -----------: |
| Node | Plain async generator       | 12.4 (8.58–14.6)   |           1× |
| Node | Bouy `async *` actor method | 0.933 (0.679–1.06) |        13.3× |
| Bun  | Plain async generator       | 9.62 (7.82–12.3)   |           1× |
| Bun  | Bouy `async *` actor method | 0.990 (0.770–1.36) |        9.72× |

## Messages

Command: `node bench/suites/messages.ts` and `bun bench/suites/messages.ts`.

Bouy copies an argument list or a reply that holds an object through an Effect Schema decode (`copyArguments` and `copyValue` in `packages/bouy/src/runtime/Sendable.ts`). The `bouy` package does not export the copy, so the suite imports `copyValue` from that file. It times `copyValue` against `structuredClone` on three payloads:

- Small: one record with five fields (`id`, `kind`, `priority`, `sentAt`, `urgent`).
- Medium: an array of 100 such records.
- Large: an array of 10,000 such records.

Before it starts the clock, the suite checks that each copy deep-equals its input and is a new object. Each run reports the median of 5 trials for each cell.

| Host | Payload | JSON bytes | Bouy Schema copy, µs   | `structuredClone`, µs | Schema ÷ `structuredClone` |
| ---- | ------- | ---------: | ---------------------- | --------------------- | -------------------------: |
| Node | small   |         77 | 3.01 (1.77–5.81)       | 0.819 (0.753–1.09)    |                      3.68× |
| Node | medium  |      7,941 | 207 (196–524)          | 47.2 (44.8–106)       |                      4.39× |
| Node | large   |    813,891 | 22,246 (19,283–95,379) | 5,926 (4,000–29,582)  |                      3.75× |
| Bun  | small   |         77 | 2.17 (1.72–5.41)       | 0.420 (0.371–0.786)   |                      5.17× |
| Bun  | medium  |      7,941 | 287 (188–349)          | 38.8 (36.8–80.3)      |                      7.42× |
| Bun  | large   |    813,891 | 23,430 (22,348–38,177) | 3,766 (3,637–4,911)   |                      6.22× |

## Startup

Command: `node bench/suites/startup.ts` and `bun bench/suites/startup.ts`. Programs: `bench/programs/hello.ts` and `bench/programs/plain-hello.ts`.

`hello.ts` spawns one actor, awaits one call, and prints the reply. `plain-hello.ts` does the same work with a plain class instance. The suite runs each command 4 times in each run, in turn, through `/usr/bin/time -p`. The wall time comes from the clock of the parent process. The CPU time is user time plus system time from `time -p`, which prints steps of 10 ms. CPU time counts every thread of the child, so it can be larger than the wall time.

These rows load the runtime and the CLI from TypeScript source ([Source](#source)).

| Host | Command                                | Wall p50, ms      | CPU p50, ms     | Wall ÷ plain | Wall ÷ runtime import |
| ---- | -------------------------------------- | ----------------- | --------------- | -----------: | --------------------: |
| Node | `node plain-hello.ts`                  | 188 (109–349)     | 95.0 (90.0–110) |           1× |                0.236× |
| Node | `node hello.ts`                        | 795 (284–1,098)   | 375 (330–430)   |        4.23× |                    1× |
| Node | `node --import bouy/register hello.ts` | 594 (283–1,062)   | 375 (320–420)   |        3.16× |                0.747× |
| Node | `bouy run hello.ts` on Node            | 1,874 (521–3,327) | 850 (575–915)   |        9.97× |                 2.36× |
| Bun  | `bun plain-hello.ts`                   | 96.6 (38.4–166)   | 0 (0–0)         |           1× |                0.476× |
| Bun  | `bun hello.ts`                         | 203 (159–282)     | 170 (170–185)   |        2.10× |                    1× |
| Bun  | `bun --preload bouy/register hello.ts` | 282 (202–319)     | 190 (180–200)   |        2.92× |                 1.39× |
| Bun  | `bouy run hello.ts` on Bun             | 1,159 (793–1,332) | 545 (510–595)   |        12.0× |                 5.71× |

`bun plain-hello.ts` used less CPU than one 10 ms step of `time -p` in every sample, so its CPU cell is 0.

### Bundled startup, from the message of commit 86b0df8

No results file records these numbers. They come from the message of commit `86b0df8` (`git show 86b0df8`), which gives medians "under a load average near 20 on the M5 Pro". The message does not state the harness, the sample count, or the directory of `hello.ts`. These runs come from a different session from the table above. Do not divide a number here by a number there.

| Command                                | Bundled, wall median, ms | From source, wall median, ms |
| -------------------------------------- | -----------------------: | ---------------------------: |
| `bouy run hello.ts` on Node            |                      258 |                          871 |
| `node --import bouy/register hello.ts` |                      142 |                          602 |
| `bouy run hello.ts` on Bun             |                       91 |                 not reported |
| `node -e 1`                            |                       65 |               not applicable |

## What the numbers show

**Memory per actor.** At 100,000 actors, a Bouy actor holds 8.47 KiB of V8 heap on Node (8,669 bytes) and 8.47 KiB on Bun (8,677 bytes). On Node, that is 67.7 times the hand-written actor and 217 times a plain class instance. On Bun, it is 43.4 times the hand-written actor and 120 times a plain class instance. 100,000 Bouy actors on Node hold about 827 MiB of heap. The RSS per actor at that count is 7.65 KiB on Node and 11.1 KiB on Bun. The suite measures the total heap and does not split it among the objects that `spawn()` creates (`Actor.ts`, `ActorSystem.ts`, and `Mailbox.ts` in `packages/bouy/src/runtime/`).

**Spawn and stop.** At 100,000 actors, a Bouy spawn takes 15.4 µs on Node and 27.9 µs on Bun. A hand-written actor takes 0.0460 µs on Node and 0.0332 µs on Bun, so a Bouy spawn takes 334 times as long on Node and 841 times as long on Bun. For 10,000 actors on Node, `shutdown()` took 29.9 µs per actor, and a spawn took 20.6 µs. On Bun, `shutdown()` took 25.6 µs per actor, and a spawn took 17.0 µs. On both hosts the per-run ranges of stopping and spawning overlap, so this session does not show which costs more.

**Bouy against a worker thread.** A worker start takes 13,450 µs on Node, about 875 times a Bouy spawn (15.4 µs). On Bun it takes 6,563 µs, about 235 times a Bouy spawn (27.9 µs). On Node, a worker adds about 820 times the RSS of a Bouy actor (6,277 KiB against 7.65 KiB). On Bun, it adds about 407 times as much (4,501 KiB against 11.1 KiB). On Node, a sequential Bouy call has a p50 of 0.192 times a worker round trip. On Bun, the ratio is 0.0754.

**One call.** A sequential call to a sync method has a p50 of 1.75 µs on Node and 1.29 µs on Bun. On Node, that is 10.5 times the hand-written actor. On Bun, it is 7.78 times. The p50 of the hand-written actor is four clock steps. For each call, the runtime does four things (`Messaging.ts`, `Actor.ts`, and `Turn.ts` in `packages/bouy/src/runtime/`):

- It allocates an envelope and a reply.
- It resumes the actor fiber through the fair scheduler.
- It runs the method inside `AsyncLocalStorage`.
- It copies the arguments and the reply.

These calls send numbers, so the copy skips the Schema walk.

**Calls in flight.** With 64 calls in flight, one Bouy actor answers 461 thousand calls per second on Node and 218 thousand on Bun. The hand-written actor answers 8.76 times as many on Node and 12.3 times as many on Bun. A worker echo answers 390 thousand on Node and 242 thousand on Bun. On both hosts the per-run ranges of the worker and of Bouy overlap (Node: 209–596 against 295–562 thousand; Bun: 190–399 against 95.8–560 thousand), so this session does not rank them.

**Fan-out.** 1,000 agents that each wait on 5 timers finish in 16.9 ms under Bouy and 8.03 ms with `Promise.all` on Node, which is 2.11 times as long. On Bun the times are 16.2 ms and 7.64 ms, which is 2.12 times as long. Bouy adds 9.05 µs per agent call on Node and 8.53 µs on Bun. That overhead is larger than the p50 of one sequential async call (1.50 µs on both hosts). The suite does not show where the extra time goes.

**Fairness.** With the compiler on Node, a ping waits 2.25 ms at p50 and 6.57 ms at p99 while the neighbor spins. The slowest ping of a run took 8.22 ms (8.15–22.1), which is about two 4 ms scheduler slices (`SLICE_MS` in `packages/bouy/src/runtime/FairScheduler.ts`). Without the compiler, the p50 is 1,018 ms and the p99 1,982 ms on both hosts, because the loop keeps the thread for the whole 2 seconds. The plain p99 is 302 times the compiled p99 on Node. On Node, one idle run had a compiled p99 of 219 ms, so the idle rows do not give a floor to subtract from the busy rows. The compiled loop finished 89.6 million rounds and the plain loop 98.7 million, and the ranges overlap. The suite therefore does not show the cost of the `tick()` checks.

On Bun, the compiled p99 is 45.9 ms (13.8–119), and the plain p99 is 43.1 times as large. The Bun session ran at a load of 30.6 to 36.6, and its idle rows also had long tails: the compiled idle p99 was 10.5 ms (2.75–67.1). This session does not separate Bun's scheduling from the load.

**Fairness bound.** In the e2e program, the median run had a worst ping of 3.41 to 4.34 ms on the four Bouy hosts, and the highest run reached 172 ms. Under plain Node, the worst ping took 1,002 ms or more in every run.

**Streaming.** An `async *` actor method delivers 0.933 million items per second on Node and 0.990 million on Bun. A plain async generator delivers 12.4 million on Node and 9.62 million on Bun. A Bouy item therefore takes 13.3 times as long on Node and 9.72 times as long on Bun. For each item, `Actor.#pump` in `packages/bouy/src/runtime/Actor.ts` waits on `iterator.next()` inside `runTurn`, copies the item with `copyValue`, and offers it to a bounded Effect `Queue` of 16 slots (`STREAM_WINDOW` in `packages/bouy/src/runtime/Streaming.ts`). The caller reads that queue through an Effect `Stream` as an async iterable. The suite streams numbers, which take the primitive fast path of `copyValue`. An item that holds an object also pays the Schema copy that the [messages](#messages) suite measures.

**Copying messages.** The Schema copy costs 3.68 to 4.39 times as much as `structuredClone` on Node and 5.17 to 7.42 times as much on Bun. A 77-byte record takes 3.01 µs on Node and 2.17 µs on Bun. An argument of 10,000 records (813,891 bytes of JSON) takes 22.2 ms on Node and 23.4 ms on Bun. The sender pays the argument copy inside its call to the ref, before the message reaches the mailbox (`dispatch.call` in `packages/bouy/src/runtime/Messaging.ts`). The actor pays the reply copy at the end of its turn.

**Startup.** These rows measure the runtime and the CLI from source. On Node, `bouy run hello.ts` takes 1,874 ms of wall time and 850 ms of CPU, against 188 ms and 95.0 ms for the plain program. Its per-run wall medians range from 521 to 3,327 ms, and its per-run CPU medians from 575 to 915 ms. Three steps lead from the plain program to `bouy run`:

- Importing the Bouy runtime (`node hello.ts`) raises the CPU median from 95.0 to 375 ms.
- The compiler hook (`node --import bouy/register hello.ts`) leaves the CPU median at 375 ms. The per-run medians overlap (320–420 ms against 330–430 ms).
- The source CLI adds 475 ms more.

On Bun, the plain program uses less than one 10 ms step of CPU. `bun hello.ts` uses 170 ms, the preload hook raises that to 190 ms, and `bouy run` uses 545 ms. The per-run medians of the first two overlap (170–185 ms against 180–200 ms). For this one-file program, loading the runtime and the source CLI costs more CPU than compiling the file. The bundled figures in the message of commit `86b0df8` come from another session, and no results file records them yet.

**Summary.** Bouy is slower than the plain baselines in the spawn, request-reply, fan-out, streaming, messages, and startup suites. For example:

- A Schema copy costs 3.68 to 7.42 times a `structuredClone`.
- A sequential call has a p50 of 7.21 to 10.5 times the hand-written actor.
- A streamed item takes 9.72 to 13.3 times as long as from a plain generator.
- The fan-out takes 2.11 to 2.12 times as long as plain code.

Bouy holds 8.46 to 8.53 KiB of heap per actor. A Bouy spawn is faster than a worker start, and a Bouy actor adds less RSS than a worker. A sequential Bouy call also has a lower p50 than a worker round trip. With 64 calls in flight, this session does not rank one Bouy actor against one worker. With the compiler, a CPU-bound actor delays a ping to its neighbor by 6.57 ms at p99 on Node. On Bun, at a load of 30.6 to 36.6, the delay is 45.9 ms. Without the compiler, it delays the neighbor for the whole loop.
