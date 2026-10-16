# End-to-end tests

Each test starts real processes with `node:child_process` and checks their standard output, standard error, and exit code. Run the suite from the repository root:

```sh
pnpm --filter @bouy/e2e test
```

This command runs Vitest directly. Turborepo, which runs the tests for `pnpm test` and `pnpm check`, does not hash `examples/` or `docs/npm-compatibility.md` as inputs of this package. After you change only those files, Turborepo can replay a cached result.

## Hosts

| Host                          | Command                                             |
| ----------------------------- | --------------------------------------------------- |
| `node via bouy run`           | `e2e/node_modules/.bin/bouy run <file>`             |
| `node --import bouy/register` | `node --import bouy/register <file>`                |
| `bun via bouy run`            | `bun e2e/node_modules/bouy/dist/cli.mjs run <file>` |
| `bun --preload bouy/register` | `bun --preload bouy/register <file>`                |
| `plain node`                  | `node <file>`, with no compiler, as the baseline    |

The Bun cases need `bun` on the `PATH`. Without it, Vitest reports them as skipped. The CI workflow in `.github/workflows/ci.yml` does not install Bun, so CI runs only the Node cases.

## Tests

| File                      | What it proves                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Hosts                           |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| `examples.test.ts`        | `hello.ts`, `research-team.ts`, and `zod-validation.ts` in `examples/` print their expected output and exit 0. `research-team.ts` prints how many chunks of the summary crossed the actor boundary, so a buffered stream fails the test.                                                                                                                                                                                                                             | All four Bouy hosts             |
| `fairness.test.ts`        | Under Bouy, another actor answers a ping every 50 ms within 250 ms during a 1,000 ms loop. Plain Node holds the first ping for the whole loop.                                                                                                                                                                                                                                                                                                                       | All four Bouy hosts, plain Node |
| `faults.test.ts`          | An actor that throws in a `setTimeout` callback, in a `queueMicrotask` callback, from a floating promise, or in an `EventEmitter` listener that its own timer emits restarts with fresh state, and a second actor keeps its state and keeps answering. On Bun, a microtask or floating promise fault is reported instead and sets exit code 1. A listener fault that another actor emits restarts the emitting actor instead; see [Known failures](#known-failures). | All four Bouy hosts             |
| `isolation.test.ts`       | A sender cannot change data after it sends it. `NotSendable` names the path of the value that cannot cross. Library errors cross as copies. Module-level state in a package is shared between actors.                                                                                                                                                                                                                                                                | All four Bouy hosts             |
| `npm-equivalence.test.ts` | zod, `ai`, and `@ai-sdk/openai` give byte-identical results in plain Node and in three actors. The installed versions match the table in `docs/npm-compatibility.md`, which the test reads.                                                                                                                                                                                                                                                                          | All four Bouy hosts, plain Node |
| `load.test.ts`            | 2,000 actors answer 20 concurrent calls each, and the process exits 0.                                                                                                                                                                                                                                                                                                                                                                                               | Both CLI hosts                  |
| `argv.test.ts`            | A program sees its own path and arguments in `process.argv`. It fails on both CLI hosts; see [Known failures](#known-failures).                                                                                                                                                                                                                                                                                                                                      | All four Bouy hosts             |
| `ref-types.test.ts`       | A ref types a call to a method that returns `never` as a promise, and the call rejects with `ActorFailed`. `vitest.config.ts` also type-checks this file, so a type regression fails the run.                                                                                                                                                                                                                                                                        | Vitest process, type check      |

The files in `test/` are the programs that the tests run, and each program prints one JSON line. `test/npm-scenario.ts` is the module that both npm programs share. The programs live in `test/` because `pnpm lint` checks that directory and Turborepo hashes it for the type check and the tests.

## The fairness bound

`test/fairness.ts` starts a `Cruncher` actor that spins for 1,000 ms inside an async method. While it spins, the main program sends a ping to a second actor every 50 ms, 20 pings in all, and prints the worst round-trip time. It measures each ping from the time it was due, so a ping that leaves late counts its wait. A timer can fire before the due time, and a ping that leaves early is measured from the time it left. The test asserts that the worst ping stays under 250 ms on every Bouy host, and that the loop started before the second ping was due. It also asserts that plain Node, which runs the loop without preemption points, holds the first ping for at least the length of the loop.

The numbers below come from 30 runs of the program on each host, recorded by `node bench/fairness/run.ts` in `bench/fairness/results/fairness-2026-10-16-m5pro.json`. The results file keeps the latency of every ping. Other jobs loaded the machine during the recording: before each run, the 1-minute load average was between 11.3 and 18.2 on 18 logical cores.

| Host                          | Worst ping, lowest run | Worst ping, median run | Worst ping, highest run |
| ----------------------------- | ---------------------: | ---------------------: | ----------------------: |
| `node via bouy run`           |                2.85 ms |                3.74 ms |               143.13 ms |
| `node --import bouy/register` |                2.52 ms |                3.41 ms |               171.78 ms |
| `bun via bouy run`            |                3.71 ms |                4.34 ms |                98.62 ms |
| `bun --preload bouy/register` |                3.69 ms |                4.25 ms |                94.24 ms |
| `plain node`                  |            1,002.37 ms |            1,003.36 ms |             1,083.85 ms |

In 60 of the 120 Bouy runs, the worst ping was one of the 10 pings due in the second half of the loop. In 21 of the 120 Bouy runs, the worst ping took longer than 20 ms. The bound of 250 ms is 1.46 times the highest Bouy run, and it is a quarter of the 1,000 ms loop. In all 30 plain Node runs, the first ping waited longer than the loop.

## Timeouts

Each test has a 60 s timeout, and the harness kills a child process after 50 s. A healthy run finishes in a few seconds, so a timeout means that a process hung.

## Known failures

These tests assert the behavior that the runtime should have, and they fail until the runtime changes.

- `faults.test.ts`, "restarts the actor whose EventEmitter listener throws, not the actor that emits", on all four hosts. The `faulty` actor registers a listener that throws on a module-level `EventEmitter`, and the `steady` actor emits from a timer. The run reports `faultyRestarts: 0`, `steadyRestarts: 1`, and exit code 0: `steady` restarts and loses its count of answered pings, and `faulty` keeps its state and its listener. `attributeFault` in `packages/bouy/src/runtime/ActorSystem.ts` crashes the turn that `currentTurn()` returns, and a listener runs in the async context of `emit()`.
- `argv.test.ts` on `node via bouy run` and `bun via bouy run`. `bouy run argv.ts a b` exits 1 with `Unexpected positional arguments: "a", "b"`. Without arguments, the program sees the argv of the CLI, `[".../bouy/dist/cli.mjs", "run", "argv.ts"]`, so its entry-point check is false. `Cli.run` in `packages/bouy/dist/cli.mjs` accepts one entry argument and imports the entry without setting `process.argv`.
