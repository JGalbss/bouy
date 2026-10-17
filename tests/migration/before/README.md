# Migration test: the "before" codebase

This directory is a small research assistant service, written the way Node and TypeScript agent apps are written today, before any port to Bouy. It is the input of the migration test: a coding agent ports it to Bouy, and the port must print `expected.stdout`.

## What the app does

`src/main.ts` runs a scripted scenario of four research requests and prints a transcript.

1. The coordinator asks a planner agent for a plan for each request. It parses the numbered steps out of the model text with regular expressions.
2. The coordinator puts every research step of every request on one job queue. The queue starts jobs by priority, two at a time.
3. A research worker carries out each step with AI SDK tool calls: `search`, `fetch_page`, `take_note`, and `calculate`. A TTL cache holds the tool results, and a token bucket limits the page fetches.
4. A summary agent summarizes each request.
5. The report service, written with Effect, validates each report with `Schema`, stores it, and publishes it. The publisher fails the first delivery of each report, so `Effect.retry` runs again.

The scenario exercises these paths:

- `req-1` runs without errors.
- `req-2` has a step that fails (division by zero in `calculate`).
- `req-3` uses the model `fake-500`. The fake server answers HTTP 500, so the worker retries with backoff and then uses the fallback model.
- `req-4` gets a plan with no steps, so planning fails and the report service rejects its report.

| Path                            | Contents                                                             |
| ------------------------------- | -------------------------------------------------------------------- |
| `src/main.ts`                   | CLI entry: arguments, config, the scenario, the transcript, shutdown |
| `src/app.ts`                    | Creates the services and connects them                               |
| `src/config.ts`                 | Reads `config/defaults.json`, the environment, and CLI overrides     |
| `src/scenario.ts`               | The scripted requests                                                |
| `src/agents/`                   | The planner, worker, and summary agents, prompts, and output parsers |
| `src/tools/`                    | The tool registry, the built-in tools, and the documents they serve  |
| `src/queue.ts`                  | The priority job queue, an `EventEmitter`                            |
| `src/cache.ts`                  | The TTL cache and `memoize`                                          |
| `src/rate-limiter.ts`           | The token bucket                                                     |
| `src/util/async.ts`             | `sleep`, `defer`, `withTimeout`, and `retry`                         |
| `src/logger.ts`                 | The JSON-lines logger                                                |
| `src/metrics.ts`                | Counters and token usage                                             |
| `src/lifecycle.ts`              | The heartbeat and the process signal and exit hooks                  |
| `src/reports/report-service.ts` | The Effect services: `ReportStore`, `Publisher`, and `Reports`       |
| `src/transcript.ts`             | Prints the transcript                                                |

## Run it with Node

The program needs the Node release of `.node-version` at the repository root and the fake OpenAI server of `runtime/test/bouy_fake_openai.erl`. It uses enums, namespaces, and parameter properties, which Node's type stripping rejects, so run Node with `--experimental-transform-types`. Node prints an `ExperimentalWarning` to stderr. The warning is not part of the output.

The program imports `ai@7.0.142`, `@ai-sdk/openai@4.0.95`, and `effect@4.0.5`. Node finds them in `tests/node_modules`, because it looks for `node_modules` in each parent directory. Run `pnpm install` at the repository root first. Do not install packages in this directory.

`scripts/freeze-expectations.sh tests/migration`, run from the repository root, records the output. It starts the fake server, runs `node --experimental-transform-types before/src/main.ts` twice, and writes `expected.stdout` when the two runs agree. The program exits with status 0. To compare a run with the recorded output, run the script and then `git diff tests/migration/before`.

## Why the output is deterministic

The port must keep these properties, or its output will differ from `expected.stdout`:

- The logger reads a clock that advances one second for each line, so the `time` fields do not depend on the wall clock.
- Only sequential code writes log lines at `info` level or above. The jobs that run at the same time log at `debug`, which the default config does not print. The one exception is the fallback warning of `req-3`, which is the only job of its request.
- The transcript prints findings in plan order, notes in sorted order, and counts instead of timings.
- The web limit allows two fetches and then one fetch every 30 ms. The only burst of fetches is the one step of `req-2`, so exactly one fetch waits.
- The retry delays have random jitter, but the transcript does not print them.
