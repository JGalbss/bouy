# Test architecture

Status: design, 2026-10-16. Section 2 lists what exists today. The rest is a plan, and section 11 orders it. This file is normative for the test layout, the outcome names, the expectation file format, and the `bouy test` command. It replaces the runner design of [migration-plan.md](migration-plan.md) section 11, and section 12 lists each change to the other documents.

The owner's direction, verbatim:

> we need to be able to use all npm packages otherwise what is the point

> really good tests for these take inspiration from bun

Requirement 7 of [goal.md](../goal.md): "test262 covers the language. Node's own test suite covers each built-in module. web-platform-tests cover the web APIs. The test suites of popular packages cover the ecosystem. A `bouy test` runner is compatible with `bun:test`. Differential fuzzing compares Bouy with Node. A dashboard publishes the pass rates. Node is the oracle, and the tests never run it."

## 1. Principles

1. **Every claim has a test.** A document that states a behavior or a compatibility links to the test file or to the row of `docs/COMPAT.md` that proves it. AGENTS.md already asks for the package, the version, and the test.
2. **Node is the oracle, and no test runs it.** Node runs in three places only: `scripts/freeze-expectations.sh`, `crates/bouy-bench`, and the fuzz campaign of `crates/bouy-fuzz`. Their output is committed. At test time a `node` shim on `PATH` fails every call (section 8).
3. **One Node version for every oracle.** `.node-version` at the repository root holds it. The freeze script refuses another version. The vendored Node suite uses the same tag, and Bouy reports it as `process.versions.node`.
4. **Silent divergence is the worst failure.** A program that compiles and then prints something other than what Node prints is a silent divergence. A diagnostic or a late rejection is loud, so the user sees it. Every report lists silent failures first.
5. **Regressions fail CI, and new passes need no hand edit.** `bouy-suites <suite> --update` rewrites the expectation files. A nightly job opens a pull request with the new passes that the per-PR run did not reach.
6. **Expectation files list every test.** A line that matches no test fails the run, and so does a test with no line. No entry can hide a test. Bun's `test/expectations.txt` warns about the opposite case: "A stale entry is invisible."
7. **Upstream tests stay byte-identical.** Bouy changes its harness, never a test. A check hashes each vendored file.
8. **A fix proves itself.** A `fix(...)` commit adds a test that fails on the merge base, and a CI job checks it (section 9).
9. **Tests check conditions, never elapsed time.** No test sleeps to wait for an event, and no test contacts the public network. Bun's test/CLAUDE.md: "You are not testing the TIME PASSING, you are testing the CONDITION."

## 2. Today

| Tier               | Location                                          | Runner                                 | Size                  |
| ------------------ | ------------------------------------------------- | -------------------------------------- | --------------------- |
| Compiler snapshots | `crates/bouy-compiler/tests/{fixtures,snapshots}` | insta, plus an `erlc` check            | 34 snapshots          |
| Runtime unit tests | `runtime/test/*_tests.erl`                        | EUnit through rebar3                   | 24 modules            |
| Conformance        | `tests/conformance`                               | `crates/bouy-cli/tests/conformance.rs` | 72 programs           |
| Equivalence        | `tests/equivalence/{effect,ai}`                   | `equivalence.rs`, `ai.rs`              | 23 Effect, 7 AI       |
| Actor invariants   | `tests/programs`                                  | `crates/bouy-cli/tests/programs.rs`    | 31 tests              |
| Benchmarks         | `bench/programs`                                  | `crates/bouy-bench`                    | 9 suites              |
| Migration fixture  | `tests/migration/before`                          | none yet                               | one app of 22 modules |

The gaps that this design closes:

- `compare()` in `crates/bouy-cli/tests/common/mod.rs` calls `Command::output()` with no time limit, so one program that hangs stops `cargo test`.
- The freeze script runs the `node` that `PATH` finds. The oracle of the last bench run is Node v25.9.0 (`bench/results/2026-10-16-apple-m5-pro.json`), and the v25 line reached end of life on 2026-06-01.
- Each corpus is all or nothing. A program that Bouy cannot run yet has no place to wait, so no corpus measures the distance to the goal.
- One `#[test]` runs a whole corpus, so `cargo test` cannot select one program.
- No upstream suite runs, and no dashboard exists.

## 3. Outcomes and expectation files

These rules apply to every tier that has an expectation file.

### 3.1 Outcomes

The runner records facts: the diagnostics of the compiler, the exit status, the uncaught error, the Erlang exit reason, and the elapsed time. One Rust function, `classify` in `crates/bouy-suites`, turns the facts into one outcome. `bouy run` writes the facts as one JSON object to the path in `BOUY_RESULT_FILE`, so no runner parses stderr.

| Outcome         | Meaning                                                                                                                                                                                 | Rank      |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| `pass`          | The result equals the Node result, or the upstream test's own check passes.                                                                                                             | 0         |
| `rejected`      | The compiler reported a diagnostic for the test or for a harness file that the test includes.                                                                                           | 1, loud   |
| `late`          | The run threw a `TypeError` whose `code` is `ERR_BOUY_UNSUPPORTED` (migration-plan.md decision D8).                                                                                     | 1, loud   |
| `skip`          | `config.json` skips the test with a reason code from the fixed list of section 3.5. The test never runs.                                                                                | 1, loud   |
| `fail`          | The program compiled and ran, and the result differs: an assertion failed, the output differs, the wrong error, or no async completion. This is a silent divergence.                    | 2, silent |
| `timeout`       | The deadline passed.                                                                                                                                                                    | 2, silent |
| `harness_error` | A harness file compiled and then threw, so the test never started.                                                                                                                      | 2, silent |
| `crash`         | A Bouy bug: a compiler panic, generated Erlang that does not compile, a VM crash, or an Erlang error that reached the program as a non-JS value (`badarg`, `function_clause`, `undef`). | 3, bug    |

The migration plan used other names. Its `rejected`, `late`, and `crash` keep their names. Its `silent` is `fail`, `timeout`, or `harness_error` here, and its `not applicable` is `skip`.

### 3.2 Expectation files

Each suite has `tests/<suite>/expectations.txt`. A script writes it, sorted by id, one line for each test:

```text
# Generated by `bouy-suites test262 --update`. Do not edit. Change config.json instead.
# test262 d53ebc8b1931d9f1541e43d59650776e4b766248
built-ins/Array/from/elements-added-after.js pass
built-ins/Array/prototype/flat/non-object-ctor-throws.js nonstrict=pass,strict=fail
language/statements/with/12.10-0-1.js rejected
```

- The outcome is the last word of the line, so an id can hold spaces. The writer escapes a newline and a backslash in an id.
- A line holds no message and no error code, so a reworded message changes no line. `results.json` keeps the details.
- `.gitattributes` marks the files `linguist-generated=true`.

| Suite                                           | Id                                                                         |
| ----------------------------------------------- | -------------------------------------------------------------------------- |
| test262                                         | path under `test/`, with per-mode outcomes when modes differ               |
| web-platform-tests                              | `<file variant>` for the harness status, and `<file variant> :: <subtest>` |
| Node                                            | path under `test/`                                                         |
| npm cases, packages, scenarios, fuzz, migration | the program path under the corpus directory                                |
| package suites, `tests/bun-test`                | `<package>@<version> :: <file> > <describe> > <test>`                      |

### 3.3 Regressions and stale lines

CI compares three things: the run, the expectation file of the pull request, and the expectation file of the base commit.

| Finding                                                                                                                | Result                                        |
| ---------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| An id moves from `pass` to any other outcome, or from any outcome to `crash`                                           | regression: CI fails                          |
| In a Bouy corpus with an expectation file (tiers 8a to 8c, 10, and 12 of section 5), an id moves from rank 1 to rank 2 | regression: CI fails                          |
| In an upstream suite, an id moves from rank 1 to rank 2                                                                | newly silent: the report lists it, CI passes  |
| The run differs from the pull request's file in any other way, a new pass included                                     | stale: CI fails and prints the update command |
| A line matches no test, or a test has no line                                                                          | stale                                         |

A move from loud to silent is a regression in Bouy's own corpora, because each of those programs was written for the behavior that it checks. In an upstream suite the move usually shows an old gap. When a harness file starts to compile, thousands of tests run for the first time, and their gaps existed before. The report lists those tests, and the dashboard counts them.

A maintainer can accept a regression with the pull request label `accept-regression`. The pull request body then names each id and its reason.

The report lists regressions first, then the newly silent ids, then the stale lines, then the summary. The runner also writes the regenerated file to `target/suites/<suite>/expectations.txt`, so `gh run download <run> -n <suite>` updates a branch with no local run.

### 3.4 Retries and flaky tests

- An id that the run does not expect gets one rerun alone, in a fresh process or VM. The rerun decides the outcome.
- When the rerun alone matches the file and the batch run did not, the report marks the id `batch-sensitive`. That id gets an issue, because state leaked between two realms or two actors.
- `config.json` lists flaky ids, each with a reason. A flaky id gets up to three attempts, and one pass is enough.
- No other id gets a retry. On BEAM a test that flakes under load usually shows a scheduler or ordering bug, and a retry would hide it.
- A `crash` never gets a retry, and the runner attaches the slogan of `erl_crash.dump` to the report.

### 3.5 Skips

A skip means that the test can never apply to Bouy. A test that Bouy cannot run yet always runs, and its outcome says why it fails. The crate holds the fixed list of reason codes, and a new code needs review:

| Code                    | Use                                                                       |
| ----------------------- | ------------------------------------------------------------------------- |
| `needs-dom`             | The test needs `document`, a browser window, or `IsHTMLDDA`.              |
| `can-block`             | test262 `CanBlockIsFalse`: an actor can block, so `[[CanBlock]]` is true. |
| `v8-flag`               | A V8 option in the `// Flags:` line of a Node test.                       |
| `node-internals`        | `--expose-internals` or `require('internal/...')`.                        |
| `native-addon`          | The test loads a `.node` addon.                                           |
| `node-inspector`        | The test drives the inspector or `node inspect`.                          |
| `node-permission-model` | The test checks Node's permission model.                                  |

A skip counts in the denominator. The dashboard shows skips by reason, so a reader can compute the rate over the tests that apply.

### 3.6 Results and summaries

- `target/suites/<suite>/results.json`, a CI artifact: the date, the host, the tool versions, the duration of each phase, and for each id its outcome, its time in ms for each mode, and a detail of at most 500 bytes. The detail holds the first failed assertion, the Erlang reason and stack of a crash, the missing function of a late rejection, or every diagnostic code of a rejected file.
- `tests/<suite>/summary.json`, committed and written by `--update`: the counts of each outcome for the suite and for each group. Section 6 builds the dashboard from these files alone.
- The durations order the next run, slowest first, and later decide the shards.

### 3.7 Selection on a pull request

On a pull request, an upstream suite runs every id that the file expects to pass. It also runs a fixed 10% sample of the other ids: the ids whose FNV-1a hash, modulo 100, is below 10. The nightly job runs every id. A suite runs whole on every pull request once it takes less than 10 minutes on the CI runner. Bouy's own corpora always run whole.

## 4. `bouy test`

### 4.1 Use

```ts
import { beforeEach, describe, expect, mock, test } from "bouy:test";

describe("Cart", () => {
  test("adds a line", () => {
    expect(addLine([], "a")).toEqual(["a"]);
  });
});
```

- `bouy test [paths...]` runs the files named `*.test.*`, `*_test.*`, `*.spec.*`, or `*_spec.*` with the extension `.ts`, `.tsx`, `.js`, `.mjs`, or `.cjs`, outside `node_modules`. Bun uses the same rule.
- Under `bouy test`, the specifiers `bun:test`, `@jest/globals`, and `vitest` resolve to `bouy:test`. `describe`, `test`, `it`, `expect`, the hooks, `jest`, and `vi` are also globals, as in Jest. A Bun, Jest, or Vitest test file runs with no change.
- `node:test` runs on the same core (section 4.6).

### 4.2 API

| Area      | First release                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Later                                                           |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| Tests     | `describe`, `test`, `it`, with `.skip`, `.todo`, `.only`, `.if`, `.skipIf`, `.todoIf`, `.failing`, and `.each` (arrays, tables, and `%s %d %i %f %j %o %p %#`)                                                                                                                                                                                                                                                                                                                                                                                          | `.concurrent`, `.serial`, and the options `retry` and `repeats` |
| Hooks     | `beforeAll`, `afterAll`, `beforeEach`, `afterEach`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | `onTestFinished`, and hooks in a `--preload` file               |
| Matchers  | `toBe`, `toEqual`, `toStrictEqual`, `toBeTruthy`, `toBeFalsy`, `toBeNull`, `toBeUndefined`, `toBeDefined`, `toBeNaN`, `toBeGreaterThan`, `toBeGreaterThanOrEqual`, `toBeLessThan`, `toBeLessThanOrEqual`, `toBeCloseTo`, `toContain`, `toContainEqual`, `toHaveLength`, `toHaveProperty`, `toMatch`, `toMatchObject`, `toThrow`, `toBeInstanceOf`; `.not`, `.resolves`, `.rejects`; `expect.any`, `anything`, `objectContaining`, `arrayContaining`, `stringContaining`, `stringMatching`; `expect.assertions`, `expect.hasAssertions`, `expect.extend` | the jest-extended matchers                                      |
| Mocks     | `mock(fn)`, `jest.fn`, `vi.fn`, `spyOn`, `toHaveBeenCalled`, `toHaveBeenCalledTimes`, `toHaveBeenCalledWith`, `toHaveBeenLastCalledWith`, `toHaveReturned`                                                                                                                                                                                                                                                                                                                                                                                              | `mock.module`, fake timers (`useFakeTimers`, `setSystemTime`)   |
| Snapshots | `toMatchSnapshot`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | `toMatchInlineSnapshot`, `toThrowErrorMatchingSnapshot`         |
| Timeouts  | 5000 ms for each test by default; `test(name, fn, ms)`, the option `timeout`, and `--timeout`                                                                                                                                                                                                                                                                                                                                                                                                                                                           |                                                                 |

The matchers are native to the runtime. The engine's own tests need them before Bouy runs arbitrary npm packages. The failure messages copy Jest's text, and `tests/bun-test` checks them (section 4.7). Snapshot files are `__snapshots__/<file>.snap` in Jest's format, with the header `// Bouy Snapshot v1`. The runner also reads files with Jest's or Bun's header, and it serializes values with Jest's pretty-format rules, so a project keeps its snapshots.

### 4.3 Files, actors, and parallel runs

| Part                 | On BEAM                                                                                                                                                                                                                                                                                                                                                                                   |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Runner               | One process for the command. It finds and compiles the files, starts one actor per file, holds the deadlines, and prints the report.                                                                                                                                                                                                                                                      |
| Test file            | One actor: a fresh JavaScript heap, global object, module instances, and promise queue. Two files never see each other's module state. Bun needs `--isolate` for this, and on BEAM it is the default.                                                                                                                                                                                     |
| Collection           | The file actor runs the top-level code and the `describe` callbacks, then sends the test tree to the runner.                                                                                                                                                                                                                                                                              |
| Order                | The file actor runs its tests in order. `test.concurrent` tests interleave on the promise queue of the file, as in Bun and Jest, so they use one heap.                                                                                                                                                                                                                                    |
| Parallel files       | Files run at the same time, up to `--jobs`, which defaults to the number of online schedulers. A compiled module loads once for each VM.                                                                                                                                                                                                                                                  |
| Spawned actors       | The actors that a test spawns are children of a supervisor for that test. When the test ends, the runner stops them and closes each port that the test opened: sockets, files, and child OS processes. Bun calls this its zombie process killer.                                                                                                                                          |
| Timeout              | At the deadline the runner sends a cancel to the file actor. A test that waits on a promise fails at once with a timeout error, its `afterEach` hooks run, and the file goes on. A test in synchronous code cannot read the message. After 1 s more, the runner kills the file actor, reports that test as `timeout`, and fails the rest of the file with `file stopped after a timeout`. |
| Errors between tests | An uncaught error from a stray promise or a linked actor fails the file, as in Bun.                                                                                                                                                                                                                                                                                                       |
| `process.exit`       | Ends the actor of the file. A status other than 0 fails the file. The other files go on.                                                                                                                                                                                                                                                                                                  |
| Console output       | The runner buffers the output of each file and prints it with the report of the file, so the lines of parallel files never mix.                                                                                                                                                                                                                                                           |

### 4.4 Output

The default reporter uses Bun's layout, so a tool that reads Bun's output reads Bouy's output:

```text
tests/unit/url.test.ts:
(pass) URL > parses a host [0.21ms]
(fail) URL > keeps the port [0.40ms]

error: expect(received).toBe(expected)

Expected: "8080"
Received: ""

      at <anonymous> (tests/unit/url.test.ts:14:25)

(skip) URL > converts punycode

 1 pass
 1 skip
 1 fail
 2 expect() calls
Ran 3 tests across 1 file. [118.00ms]
```

| Flag                                           | Meaning                                                                                               |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `-t, --test-name-pattern <regex>`              | Runs the tests whose full name matches.                                                               |
| `--timeout <ms>`                               | The default deadline of each test.                                                                    |
| `--jobs <n>`                                   | The files that run at the same time.                                                                  |
| `--bail[=n]`                                   | Stops after `n` failures, 1 by default.                                                               |
| `--rerun-each <n>`                             | Runs each test `n` times, to find order bugs.                                                         |
| `-u, --update-snapshots`                       | Writes new and changed snapshots.                                                                     |
| `--todo`                                       | Runs `todo` tests. A `todo` test that passes fails, so its author removes the `todo`.                 |
| `--reporter <default\|dots\|junit\|jsonl>`     | `jsonl` writes one object per line, with a `kind` field: `file-start`, `test`, `file-end`, `summary`. |
| `--reporter-outfile <path>`                    | Where `junit` and `jsonl` write.                                                                      |
| `--shard <i>/<n>`, `--randomize`, `--seed <n>` | Later.                                                                                                |

The exit status is 0 when no test fails and 1 otherwise. A file with diagnostics fails, and the other files still run. A usage error exits with 2.

Under `CI=1`, `.only` fails the run, and a missing snapshot fails the test unless `--update-snapshots` is given. Bun has both rules.

### 4.5 Where it lives

- `runtime/src/bouy_test_runner.erl`: collection, order, deadlines, the supervisors of each test, and the reporters.
- `runtime/src/bouy_expect.erl`, `bouy_mock.erl`, and `bouy_snapshot.erl`.
- `bouy:test` in the library table of contract section 11, and the `test` command in the CLI.

### 4.6 `node:test` and the other front ends

Bun builds `node:test` on the core of `bun:test`, and Bouy does the same. `node:test` gives `test`, `describe`, `it`, the hooks, `t.test` subtests, and `mock.fn`. A file that imports it runs under `bouy run`, as Node runs it, and under `bouy test`. A failed test sets the exit status to 1. Under `bouy test`, the globals `before` and `after` map to `beforeAll` and `afterAll` for mocha files, as Bun's mocha shim does.

### 4.7 How the runner is tested

- `tests/bun-test/` holds Bun's tests of `bun:test`, copied byte-identical from oven-sh/bun at commit f8bc171976fb (MIT license), with `UPSTREAM.md`. The first files are `test/js/bun/test/expect.test.js`, `jest-each.test.ts`, `mock-fn.test.js`, `spyMatchers.test.ts`, and the snapshot tests. `expect.test.js` is "meant to be runnable in Jest, Vitest, and Bun", so it checks Bouy's matchers against Jest's behavior with no oracle run. The outcome of each test goes to `tests/bun-test/expectations.txt`.
- `tests/cli/test-runner/` holds Bouy's own tests that spawn `bouy test` on fixture files and compare the normalized output with the format of section 4.4.
- The Rust harness stays the outer runner of every Bouy suite until `tests/bun-test` passes, so a bug in `bouy test` cannot hide a failure.

## 5. Tiers

| #   | Tier                      | Location                                                                          | Runner                                                     | Input                                                           | Expectations                            | Cadence                          |
| --- | ------------------------- | --------------------------------------------------------------------------------- | ---------------------------------------------------------- | --------------------------------------------------------------- | --------------------------------------- | -------------------------------- |
| 1   | Unit                      | `crates/*/src`, `runtime/test`                                                    | `cargo test`, `rebar3 eunit`                               | in the repository                                               | assertions                              | every PR                         |
| 2   | Compiler snapshots        | `crates/bouy-compiler/tests`                                                      | insta, `erlc`                                              | in the repository                                               | `.snap`, plus `.stdout` from Node       | every PR                         |
| 3   | Bouy programs             | `tests/{conformance,divergence,regressions,equivalence}`                          | `crates/bouy-cli/tests`                                    | in the repository                                               | `.stdout` and `.status` from Node       | every PR                         |
| 4   | Bouy TypeScript tests     | `tests/unit`, `tests/cli`                                                         | `bouy test`                                                | in the repository                                               | `expect`, and a Node-verified hash      | every PR                         |
| 5   | test262                   | `tests/test262`                                                                   | `bouy-suites test262`                                      | fetched at a pinned commit into a cache                         | `expectations.txt`                      | PR: section 3.7. Nightly: all    |
| 6   | web-platform-tests        | `tests/wpt`                                                                       | `bouy-suites wpt`                                          | vendored areas, each at a pinned commit                         | `expectations.txt`                      | PR: section 3.7. Nightly: all    |
| 7   | Node's own tests          | `tests/node`                                                                      | `bouy-suites node`                                         | vendored at the tag of `.node-version`                          | `expectations.txt`                      | PR: section 3.7. Nightly: all    |
| 8   | Ecosystem                 | `tests/npm`, `tests/packages`, `tests/equivalence/<area>`, `tests/package-suites` | `bouy-suites packages`, `bouy-suites package-suites`, Rust | committed packages, a pnpm workspace, clones at a pinned commit | `.stdout` from Node, `expectations.txt` | every PR; package suites nightly |
| 9   | Actor and BEAM invariants | `tests/programs`                                                                  | `programs.rs`                                              | in the repository                                               | the contract                            | every PR; checked lane nightly   |
| 10  | Differential fuzzing      | `tests/fuzz`, `crates/bouy-fuzz`                                                  | campaign, then replay                                      | generated programs                                              | `.stdout` from Node, `expectations.txt` | replay every PR; campaign weekly |
| 11  | Performance               | `bench`                                                                           | `crates/bouy-bench`                                        | in the repository                                               | `bench/thresholds.json`                 | nightly                          |
| 12  | Migration fixture         | `tests/migration`                                                                 | `migration.rs`                                             | in the repository, hash-locked                                  | `expected.stdout`, one expectation line | every PR                         |

### 5.1 Unit tests

No change. Rust unit tests sit next to their code. EUnit tests each runtime module, and dialyzer checks it. One rule is new: each runtime function that JavaScript can reach has an EUnit test of its error path, which must throw a JavaScript error and never exit with `badarg`.

### 5.2 Compiler snapshots

The insta snapshots check the shape of the generated Erlang only. Bun's bundler notes say the same of its snapshots: they "are used to check for regressions and not necessarily check accuracy". So each fixture that neither imports `bouy` nor sits in `fixtures/diagnostics` gets a `.stdout` from Node, and the test also runs the fixture. A snapshot is never the only check. insta writes no snapshot in CI. The diagnostic fixtures keep the rule of diagnostics.md section 13: one fixture for each code.

### 5.3 Bouy programs

| Directory                  | Holds                                                                                                |
| -------------------------- | ---------------------------------------------------------------------------------------------------- |
| `tests/conformance`        | Language programs (exists)                                                                           |
| `tests/divergence`         | The register of documented differences and `open.txt`, which only shrinks (migration-plan.md WP 2.8) |
| `tests/regressions`        | True regressions with a real issue number (section 7)                                                |
| `tests/equivalence/<area>` | Library programs against the real npm package: `effect` and `ai` exist, and tier 8 adds more         |

- Each program has a `.stdout`, and a `.status` when the status is not 0. `scripts/freeze-expectations.sh` writes them.
- The freeze script reads `.node-version` and exits when `node --version` differs. It runs Node twice in the environment of section 8 and exits when the two outputs differ, so a program that depends on time or order cannot enter a corpus.
- The freeze step and the test apply the same normalization: paths, durations, and stack positions. No program needs a wildcard pattern.
- A program shows one behavior and prints only what that behavior needs. A short diff is easier to read.
- `BOUY_TEST_FILTER=<substring>` runs the matching programs only.
- The failure report keeps today's format: the lines that differ, `-` for Node and `+` for Bouy, then stderr and the statuses. It adds the command that reproduces the run.

### 5.4 Bouy TypeScript tests

`tests/unit/<module>.test.ts` tests one built-in or one Node module with `bouy:test`, as Deno's `tests/unit_node` does. These files check themselves with `expect`, so the oracle must check the hand-written expectations:

1. `scripts/freeze-expectations.sh tests/unit` runs each file on Node through `tests/oracle/bouy-test-on-node.mjs`. That module maps `bouy:test` to `node:test` and to the `expect` and `jest-mock` packages, pinned in `tests/package.json`.
2. When a file passes on Node, the script writes `<sha256> <path>` to `tests/node-verified.txt`.
3. A Rust test fails when a file under `tests/unit` has no matching line. An edit after the Node run needs a new Node run.

`tests/cli` holds the tests that only Bouy can run, such as tests that spawn `bouy` or use actors. They skip the Node check.

The seeded fuzzers of section 5.10 also live in `tests/unit`.

### 5.5 test262

- **Source.** tc39/test262 at the commit in `tests/test262/config.json`, first d53ebc8b1931d9f1541e43d59650776e4b766248. The runner fetches it by SHA into `$XDG_CACHE_HOME/bouy/test262-<sha>/`. The repository does not vendor it. test262.fyi counts 53,616 test files at that revision.
- **Specification.** test262's `INTERPRETING.md` defines the runner. A hand-written Rust parser reads the frontmatter keys `flags`, `includes`, `features`, `negative`, and `locale`. An unknown key, flag, or phase stops the run, so an upstream format change shows at once. `harness/features.yml` adds the features that an include implies.
- **Modes.** A file without `onlyStrict`, `noStrict`, `module`, or `raw` runs twice: as written and in strict mode. That gives 102,994 executions at the pinned commit. A file passes when each of its modes passes. The `module` flag alone sets the goal. The runner never lets oxc detect the goal from the content, and never compiles a test as TypeScript. The compiler's mapping of a reserved-word `yield` to BOUY206 applies to TypeScript sources only.
- **Harness.** The harness stays unmodified. Each harness file compiles once to its own Erlang module and runs as a separate sloppy script in the realm of the test, before the test. The runner adds no port, no wrapper, and no `bouy fix` step. Today `assert.js` and `sta.js` use `var` and assign properties to functions (BOUY206 and BOUY202), so every test that includes them is `rejected`, and the blockers table names the file. That is the honest baseline. 35,486 files need only these two files.
- **Negative tests.** A parse-phase test passes when the compiler reports BOUY200 for the test file. A resolution-phase test passes on the error for a missing export. Any other code is `rejected` and never a pass. The compiler must therefore keep the codes that mean "the program is wrong" apart from the codes that mean "Bouy cannot do this yet".
- **Execution.** One VM runs a batch of executions. Each execution runs in its own BEAM process with a fresh realm, a `max_heap_size`, and a deadline of 10 s. At the deadline the VM kills that process and goes on. A watchdog kills a VM that stops writing results and reruns its executions alone. One VM per execution would cost too much: the startup suite of `bench/results/2026-10-16-apple-m5-pro.json`, recorded at commit cabaaa9, has a median of 199.7 ms, so 102,994 starts take about 5.7 hours.
- **Host.** An Erlang module installs `print` and `$262` in each realm. `global` is the global object of the realm. `detachArrayBuffer` calls the runtime. `gc` calls `erlang:garbage_collect()` once `WeakRef` exists. `evalScript` and `createRealm` need the runtime compile path and realms, so until then they throw a late rejection. `agent` maps to one BEAM process per agent. An async test passes after `print('Test262:AsyncTestComplete')`, and fails on `Test262:AsyncTestFailure` or when its process ends without either line.
- **Dynamic code.** `eval(`, `Function(`, `$262.evalScript`, and `createRealm` appear in about 1,971 files. They stay `rejected` until the runtime can compile code, and the dashboard shows them as one row, `dynamic-code`.
- **Runtime entry points.** The runner needs these from the runtime, and the contract defines each one when it lands:
  1. Create a realm with host hooks.
  2. Evaluate a compiled script in a realm. Top-level `var` and function declarations become properties of the global object.
  3. Evaluate a module graph.
  4. Return a completion as data, and keep the VM running.
  5. Send `print` to the runner of each realm.
- **Config.** `tests/test262/config.json` holds the commit, the timeout, the heap limit, the skips, and the flaky ids. `intl402/` and `staging/` have lines from the start, and they run in the nightly job only.
- **Groups.** Directory to depth 3, feature, edition (computed as Boa does), positive and negative tests, and one subset that predicts npm success: ES5 to ES2022 without `intl402`, `staging`, and proposals.
- **Later.** Data in test262.fyi's format (`index.json`, one file per directory, `meta.json`, `history.json`) on a results branch, so a fork of the test262.fyi frontend shows Bouy next to other engines. A listing on test262.fyi when `bouy` runs plain `.js` scripts.

### 5.6 web-platform-tests

- **Source.** Vendored areas only, in `tests/wpt/suite/<area>/`, byte-identical. `tests/wpt/versions.json` uses Node's format, `{"url": {"commit": "<sha>", "path": "url"}}`, so each area moves on its own. `scripts/vendor-wpt.sh <area> <sha>` copies one directory. WPT's `LICENSE.md` (BSD-3-Clause) sits next to the files. The full WPT repository (2.8 GB), Python, and `wpt serve` stay out until fetch needs a server.
- **Areas, in order.** `console`, `url`, `encoding` (the UTF-8 files only), `dom/abort`, `dom/events`, `html/webappapis/timers`, `html/webappapis/microtask-queuing`, `html/webappapis/structured-clone`, `html/webappapis/atob`, `hr-time`, `streams`, `FileAPI`, `compression`, then `fetch/api` with a local server, then `WebCryptoAPI`.
- **Runner.** The runner reads the `// META:` lines (`script`, `timeout`, `global`, `title`, `variant`). For each `.any.js` file it builds one program: the META scripts, upstream `resources/testharness.js`, Bouy's reporter `tests/wpt/testharnessreport.js`, and the test. The reporter writes one line per subtest and one completion line. Each line starts with a fixed prefix and holds JSON, so a test that prints its own JSON cannot confuse the runner. testharness.js has no timeout in a shell, so the runner owns it: 10 s, or 60 s for `timeout=long`. A kill keeps the subtests that finished.
- **Variants.** The ids use the `.any.html` variant names, so they match wpt.fyi. Bouy generates only that variant until a dedicated worker maps to a spawned actor. Then the `.any.worker.html` ids join the file. A `.window.js` or `.html` test that needs `document` gets `needs-dom`.
- **Fetch shim.** For areas other than fetch, `globalThis.fetch` in the WPT runner reads files of the vendored tree, as Node's WPT runner does.
- **Gate.** `testharness.js` uses `var`, `arguments`, and regular expression literals, which BOUY206 rejects today. Until it compiles, every file is `rejected`. `idlharness.js` needs `eval`, so the IDL tests count as `dynamic-code`.
- **Expectations.** Each file has one line for its harness status and one line per subtest. A subtest that stops registering leaves a stale line, which fails the run.

### 5.7 Node's own tests

- **Source.** nodejs/node `test/` at the tag in `.node-version`. `scripts/vendor-node-tests.sh` copies `common`, `fixtures`, `parallel`, `sequential`, and `es-module` into `tests/node/suite/`, with Node's MIT `LICENSE`, and records the tag and the commit. The script copies every file of these directories, so the denominator is in the repository. Bun copies only the files that pass, and loses the denominator. Deno keeps the whole directory in a submodule.
- **Pin.** Node 26 becomes LTS on 2026-10-28, and Deno tracks 26.5.1. `.node-version` holds one 26.x release. The move from v25.9.0 refreezes every `.stdout` in one reviewed commit.
- **Edits.** The test files stay byte-identical. Bouy's adaptation goes into `tests/node/suite/common` only. Each change carries a `// Bouy:` comment and a line in `tests/node/edited.txt` with its reason. A check hashes every file against the upstream manifest. Bun states the same rule but does not check it, and 6 of 40 sampled Bun files did not match Node v26.3.0.
- **Runner.** One `bouy` OS process per file, because these files use `process.exit`, signals, stdio, and child processes. The environment adds `NODE_TEST_KNOWN_GLOBALS=0`, `NODE_SKIP_FLAG_CHECK=1`, `TEST_SERIAL_ID=<n>`, `NO_COLOR=1`, `TZ=Etc/UTC`, and a fresh `TMPDIR`. The runner reads the `// Flags:` line: it passes the flags that Bouy honors, and a flag that Bouy cannot honor gives `v8-flag` or `node-internals`. A file passes when it exits with 0 within 20 s. `sequential/` runs one file at a time. Every failure prints the command that reproduces it.
- **Runtime work, ordered by what the tests need.** At node f513ec7, 5,010 of the 5,084 files in `test/parallel` require `../common`, 2,798 use `common.mustCall`, 548 spawn `process.execPath`, 448 need `--expose-internals`, and 277 import `node:test`. So:
  1. `require('../common')` loads. `test/common` names `cluster`, `child_process`, `tty`, `os`, and `async_hooks` inside functions that most tests never call. So a `require` of an unimplemented module must throw a late rejection at the call, and the compile must succeed.
  2. Node's exit rule: the root actor ends when it has no queued jobs, no timers, and no referenced handles, and then `'exit'` fires. `common.mustCall` checks its counts in an `'exit'` handler.
  3. `process.execPath` starts `bouy` with Node's argv: a script path, `-e`, `-p`, and `--`.
  4. `node:test` (section 4.6).
- **Groups.** Deno's table maps a file prefix to a module (`test-buffer-*` to `buffer`). The rate of a module is its passing files over all its files at the tag.
- **First number.** The files that pass when a file with only `require('../common')` exits 0.

### 5.8 Ecosystem

**a. Resolution cases: `tests/npm/<case>/`.** Synthetic packages, committed as `node_modules/@bouytest/<package>/`, one module rule per case: export conditions and subpath patterns, `imports` and `#` specifiers, `module.exports =` and `exports.x`, `__esModule` default interop, named imports from CommonJS, `require` of an ES module, JSON modules, `main` fallbacks, a directory `main`, self-reference, and pnpm symlinks. Each program has a `.stdout` from Node. Of the 55 AI-tier packages, 18 ship only ES modules, among them `chalk` 6, `commander` 15, `ai` 7, and `effect` 4.

**b. Package programs: `tests/packages/<name>@<major>/`.**

| File                         | Content                                                                                                                                                                                                            |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `package.json`               | One dependency at an exact version. The directory is a member of the pnpm workspace, and `pnpm-lock.yaml` pins the integrity.                                                                                      |
| `exports.mjs`, `exports.cjs` | Generated by `scripts/package-exports.sh`. Imports or requires the package and prints each export name with its `typeof`, sorted. It checks resolution, conditions, interop, and top-level code with no hand work. |
| `main.mjs`                   | Hand-written from the usage section of the README: at most 40 lines, with no network, no clock, and no randomness.                                                                                                 |
| `*.stdout`, `*.status`       | From Node, through the freeze script.                                                                                                                                                                              |

- **Selection.** `scripts/rank-packages.sh` writes `tests/packages/ranking.json` from the candidates of ecosyste.ms, the weekly counts of the npm downloads API, and the shares per version of the npm versions API. It classifies from registry metadata: `os` or `cpu` marks a platform binary, and a package with types and no JavaScript entry gets no program. It tags the AI tier: the LLM SDKs and agent frameworks, and the HTTP, validation, and utility packages that they load. The first scan of the tier counted 55 packages, among them `ai`, `openai`, `@anthropic-ai/sdk`, `@modelcontextprotocol/sdk`, `@langchain/core`, `zod`, `effect`, `hono`, and `ws`. The file is refreshed each quarter.
- **Versions.** Each major version with at least 20% of the weekly downloads, at most three, plus the latest. In the week to 2026-10-12, `chalk` 4.x had 54% of the downloads of `chalk`, while the latest is 6.0.1.
- **Order.** The 55 AI-tier packages first, then the top 150 runtime packages, then the top 500. `main.mjs` programs for the AI tier and the top 150.
- **Code generation.** A package that builds functions at run time (`ajv`, the JIT path of `zod`) runs in two configurations: the defaults, and an eval-free one such as `z.config({ jitless: true })`. A failure in the default configuration only is a `dynamic-code` gap, which the dashboard shows apart from engine bugs.
- **Replacements.** When Bouy replaces a package with a native module, as Bun replaces `ws` and `undici`, the replacement must print the frozen Node output of the real package, and the dashboard names the replacement.

**c. AI-stack scenarios: `tests/equivalence/<area>/`.** Programs on the model of `tests/equivalence/ai`, against fake servers. Each new area has an `expectations.txt`, because its programs cannot pass yet. `effect` and `ai` keep their rule that every program passes. `runtime/test/bouy_fake_openai.erl` gains the OpenAI Responses API and the Anthropic Messages API with SSE and `tool_use`. The first scenarios: `ai` with `zod` (text, streaming, tools, structured output), `openai` (chat and Responses streaming), `@anthropic-ai/sdk` (a streamed tool call), and an MCP server and client over `InMemoryTransport`, then over stdio, then over Streamable HTTP. Package mocks replace the server where they exist: `MockLanguageModelV4` of `ai/test`, `FakeListChatModel` of `@langchain/core`. A Bouy-only variant in `tests/programs` runs one SDK in many actors at once and checks that each actor keeps its own module state.

**d. Package suites: `tests/package-suites/`.**

- `lookup.json` uses a subset of CITGM's fields: `package`, `version`, `repo`, `sha` (the `gitHead` of the registry), `framework`, `scripts` or `files`, `env`, `timeoutMs`, and `skip` (a glob and a reason).
- The nightly job clones each repository at its `sha` into the cache, installs it with its own lockfile, and runs its test files under `bouy test`, with the aliases of section 4.1.
- `<package>.node.json` is the per-test oracle. `scripts/freeze-expectations.sh tests/package-suites` records the outcome of each test id in three Node runs. A test whose outcome differs between the runs is dropped as flaky on Node.
- The rate of a package is its tests that pass on Bouy over its tests that pass on Node.
- First suites: `ms`, `semver`, `picocolors`, `uuid`, `commander`, `yargs`, `dotenv`, `chalk`, `p-limit`, `eventsource-parser`, `zod`, `date-fns`. Then `fastify`, `express`, `ws`, `hono`. Then `ai`, `@ai-sdk/openai`, `openai`, `@anthropic-ai/sdk`, `@modelcontextprotocol/sdk`, `effect`. Suites that need Postgres, Redis, or the network stay out.

**e. Applications: `tests/apps/<app>/`, later.** Whole applications whose stdout and HTTP responses come from one Node run. The migration fixture (section 5.12) is the first one.

### 5.9 Actor and BEAM invariants

`tests/programs` stays as it is. The contract defines each expected output, so Node plays no part. Each invariant of the definition of done has a test:

| Invariant            | Test in `crates/bouy-cli/tests/programs.rs`                                    |
| -------------------- | ------------------------------------------------------------------------------ |
| Fault isolation      | `a_crash_restarts_only_the_failed_actor`                                       |
| State isolation      | `actors_of_one_class_keep_separate_state`                                      |
| Message ordering     | `casts_and_a_call_arrive_in_order`                                             |
| Supervision          | `one_for_all_restarts_every_child`                                             |
| Cancellation         | `stop_ends_a_turn_and_with_timeout_cancels`                                    |
| Bounded mailboxes    | `a_full_mailbox_rejects_a_cast`, `concurrent_senders_cannot_pass_the_capacity` |
| Stability under load | `ten_thousand_actors_answer`, `a_spinning_actor_does_not_delay_replies`        |
| npm equivalence      | tier 8, and `tests/equivalence`                                                |

New tests:

- **Leak check.** With `BOUY_CHECK=1`, the runtime stops the actors of the program at its end. Then it compares the process count, the port count, the ETS tables, and the binary memory with the values at the start, and exits with an error when they grew. The Rust harness sets it for every program.
- **Checked lane.** `BOUY_CHECK=1` also turns on runtime assertions: the term shapes of JavaScript values, the heap invariants, and the rule that every Erlang exception that reaches JavaScript becomes a JavaScript error. One nightly lane runs every suite in this mode.
- **Built-in sweep.** A program lists every global, every export of every built-in module, and every prototype method. It calls each with no arguments, with each primitive, and with `new`. Each throw must be an instance of a JavaScript `Error` class, and the actor must survive. Bun's `fuzzy-wuzzy.test.ts` does the same for its own functions. In Bouy the sweep finds an Erlang `badarg` or `function_clause` that escapes as a non-JS error.

### 5.10 Differential fuzzing

- **Campaign.** `crates/bouy-fuzz` generates seeded programs, runs Node and Bouy, and keeps each silent mismatch. A `rejected` or `late` run is not a finding, and the campaign counts it as a coverage gap. The tool minimizes each mismatch: it deletes statements and simplifies expressions while the mismatch stays. It writes `tests/fuzz/<generator>/<seed>.ts` with the Node `.stdout`, and opens a pull request. It runs on a dev machine or in a weekly job. It is a freeze step, never a gate.
- **First generators.** Number formatting, parsing, and coercion (`-0`, values near 2^53); strings and UTF-16 indices; JSON round trips; `sort` with comparators; `Date` with a fixed time zone; control flow with `finally`, labels, and `switch`. These are the areas where BEAM differs most from V8.
- **Replay.** `tests/fuzz` runs on every pull request with `tests/fuzz/expectations.txt`. A case stays `fail` until a fix makes it pass, and its outcome can only improve.
- **Seeded fuzzers in the suite.** `tests/unit/fuzz-*.test.ts` check invariants with no oracle: `JSON.parse(JSON.stringify(x))` equals `x` for JSON values, `sort` returns an ordered permutation, and `Number(String(n)) === n`. `BOUY_FUZZ_SEED` and `BOUY_FUZZ_ITERS` replay a run. The Node check of section 5.4 also proves each invariant on Node.
- **Later.** Fuzzilli, through a REPRL front end that compiles each program and runs it in a fresh actor.

### 5.11 Performance

- `bench/thresholds.json` gives, for each suite and metric, the largest allowed change of the median, as a ratio: `{"startup": {"wall_ms": 1.15}}`. These values are limits, and no document may quote them as results.
- The nightly job runs `bouy-bench --runs 5` on one fixed runner type and compares each median with the previous nightly result of the same host. A metric past its limit in two nightly runs in a row fails the job and opens an issue. One run past the limit only warns, because hosted runners are noisy.
- Every pull request runs `bouy check` on each `bench/programs/*/bouy.ts`, so a program never stops compiling.
- A document still quotes only a committed file of `bench/results` (AGENTS.md).

### 5.12 Migration fixture

- `tests/migration/before` must run unchanged. `crates/bouy-cli/tests/migration.rs`, on the model of `ai.rs`, starts the fake OpenAI server, runs `bouy run tests/migration/before/src/main.ts`, and compares stdout and the exit status with `expected.stdout`.
- Today the fixture does not compile. `tests/migration/expectations.txt` holds its one line, `before/src/main.ts rejected`, so the test records the outcome, and the dashboard shows it. When the program passes, the line becomes `pass`, and the test is a gate.
- `tests/migration/before.sha256` holds a hash of the tree. A check fails on any change, so nobody can make the test pass by changing the fixture.
- The README of the fixture gives the Node command, which needs `--experimental-transform-types`. The freeze script takes over that command, so `expected.stdout` comes from the one place that runs Node.
- The agent port runs of migration-plan.md section 10 stay a test of the diagnostics. This test is the gate.

## 6. Compatibility dashboard

- `bouy-suites compat` writes `docs/COMPAT.md` and `docs/compat.json` from the committed `tests/*/summary.json` files and the program counts of tiers 3, 4, and 9.
- `pnpm check` runs `bouy-suites compat --check`, which fails when the two files differ from what the summaries give. So the page cannot go stale. Bun's Node.js compatibility page is written by hand, and an audit of it in PR #41352 noted that its percentages "were not measured again".
- A compatibility claim in any document links to a row of `docs/COMPAT.md`. Each row names the package or the suite, its version, and the test path, which is the evidence that AGENTS.md asks for.
- The headline denominator of an upstream suite is every upstream test, skips included, so a skip never raises a rate.

`docs/COMPAT.md` has these sections:

1. **Tiers.** One row per suite: the suite and its version, pass, total, the percentage, silent failures (`fail`, `timeout`, `harness_error`), crashes, and the commit of the last update.
2. **Language.** test262 by outcome, with rows for positive and negative tests; by edition; by feature; by directory; and the blockers table. The blockers table lists each diagnostic code, each built-in that throws a late rejection, and each failing harness file. For each one it counts the files that it blocks and the files where it is the only blocker, and it sorts by the second count. It is the work queue, and its codes are the stable codes of goal.md requirement 6.
3. **Node.** One row per module: passing files over files at the tag, and the skips by reason.
4. **Web.** One row per WPT area: subtests and files.
5. **Packages.** One row per `<name>@<major>`: the exports program, the main program, the scenario programs, and the package suite (Bouy passes over Node passes).
6. **Bouy corpora.** Program counts, which pass by rule, the open count of the divergence register, the open fuzz cases, and the outcome of the migration fixture.

`docs/compat.json` holds the same data. Each tier uses one shape:

```json
{
  "tier": "language",
  "suite": "test262",
  "suite_version": "d53ebc8",
  "updated": "<commit>",
  "total": 53616,
  "outcomes": {
    "pass": 0,
    "rejected": 0,
    "late": 0,
    "skip": 0,
    "fail": 0,
    "timeout": 0,
    "harness_error": 0,
    "crash": 0
  },
  "groups": { "feature": {}, "edition": {}, "directory": {} }
}
```

On a pull request the suites job writes a comment that starts with `<!-- bouy-suites -->`. For each suite it compares `main` with the pull request. Then it lists the regressions, the newly silent ids, and the new passes, each in a collapsed list with `(previously <outcome>)`. A second workflow, started by `workflow_run`, posts the comment, so a pull request from a fork never holds a write token. Boa uses the same split.

Later: `history.jsonl` and a badge on a results branch.

## 7. Layout and naming

```text
.node-version                 the Node version of every oracle
tests/
  README.md                   outcomes, placement, and the procedure of section 9
  package.json                oracle packages (exists)
  node-verified.txt           sha256 and path of each tests/unit file that passed on Node
  harness.ts                  the TypeScript harness, imported as "#harness"
  oracle/                     bouy-test-on-node.mjs, used only by the freeze script
  conformance/                exists
  divergence/                 migration-plan.md WP 2.8
  regressions/<issue>.ts
  equivalence/<area>/         effect and ai exist
  programs/                   exists
  unit/<module>.test.ts
  cli/
  migration/                  before/ exists; expectations.txt, before.sha256
  test262/                    config.json, expectations.txt, summary.json
  wpt/                        versions.json, suite/<area>/, testharnessreport.js, config.json, expectations.txt, summary.json
  node/                       suite/, config.json, edited.txt, expectations.txt, summary.json
  npm/<case>/
  packages/                   ranking.json, <name>@<major>/, expectations.txt, summary.json
  package-suites/             lookup.json, <package>.node.json, expectations.txt, summary.json
  bun-test/                   UPSTREAM.md, the copied files, expectations.txt
  fuzz/<generator>/<seed>.ts
crates/
  bouy-suites/                the runner of tiers 5 to 8, and the dashboard
  bouy-fuzz/                  the fuzz campaign
docs/
  COMPAT.md, compat.json      generated
```

Naming and placement:

- A corpus program is named after the behavior that it shows, such as `arrays-sort.ts`, never after a bug.
- A fix adds its case to the existing program or test file of the behavior or the module. A new file comes only when no file covers the area. Bun's rule reads: "Default: add your test to the existing test file for the code you're changing. Do not create a new file."
- Add a case next to the existing ones. Never change an existing case into the new one.
- `tests/regressions/<issue>.ts` takes only true regressions: behavior that worked on `main` and then broke, with a real issue number, written with no zero padding. A case with several files gets a directory, `tests/regressions/<issue>/main.ts`. Bun's mixed padding (02005, 012039, 40561) breaks sorting.
- `tests/fuzz/<generator>/<seed>.ts`: the seed lets the generator replay the case.
- A file that a test spawns ends in `-fixture.ts`.
- A Rust test function reads as a sentence, as in `programs.rs` today. A `bouy:test` name is `describe("<module or API>")` with `test("<behavior>")`.

`crates/bouy-suites/tests/rules.rs` checks the rules that matter, in `pnpm check`:

1. Each name in `tests/regressions` is an issue number, and each name in `tests/fuzz` is a seed.
2. Each vendored file matches its upstream hash, unless an `edited.txt` lists it with a reason.
3. `tests/migration/before` matches `before.sha256`.
4. Each file in `tests/unit` has a line in `node-verified.txt` with its current hash.
5. Each skip, flaky id, and edited file has a reason.
6. Only `scripts/freeze-expectations.sh`, `crates/bouy-bench`, and `crates/bouy-fuzz` start `node`.

## 8. The test harness API

`crates/bouy-cli/tests/common/mod.rs` gains these parts, so every Rust test of a program uses them:

| Part                   | Behavior                                                                                                                                                                                     |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bouy_env(command)`    | Sets `TZ=Etc/UTC`, `LANG=C.UTF-8`, `NO_COLOR=1`, `CI=1`, and a fresh `TMPDIR`. Removes the variables of the host. Puts the `node` shim first on `PATH`. The freeze script uses the same set. |
| `node` shim            | A script named `node` that prints "a test tried to run node" and exits with 1. bun-ecosystem-ci used the same shim.                                                                          |
| `BOUY_BIN`             | The `bouy` binary under test. The default is the binary of the build. The proof job sets the build of the merge base.                                                                        |
| Deadline               | `compare()` kills the child after 20 s, or after `BOUY_TEST_TIMEOUT` ms.                                                                                                                     |
| `temp_dir(tree)`       | Writes a tree of files and deletes it on drop.                                                                                                                                               |
| `normalize(text, dir)` | Replaces the directory, the temporary directory, and the home directory with `<dir>`, `<tmp>`, and `<home>`. Removes durations, versions, and stack line numbers.                            |
| `BOUY_TEST_FILTER`     | Runs only the programs whose path contains the value.                                                                                                                                        |
| Failure report         | The stdout diff, then stderr, then the statuses, then the command that reproduces the run.                                                                                                   |
| Leak check             | Sets `BOUY_CHECK=1` (section 5.9).                                                                                                                                                           |
| Workers                | The number of cores minus 1, instead of the fixed `WORKERS = 4`.                                                                                                                             |

The TypeScript harness, `tests/harness.ts`, is imported as `#harness` through the `imports` field of `tests/package.json`. Its names follow Bun's `harness.ts`, so a Bun test ports by changing one import:

| Name                         | Behavior                                                                    |
| ---------------------------- | --------------------------------------------------------------------------- |
| `bouyExe()`                  | The path of the `bouy` binary under test.                                   |
| `bouyEnv`                    | The environment of `bouy_env`.                                              |
| `tempDir(prefix, tree)`      | A directory that `using` deletes at the end of the scope.                   |
| `normalizeOutput(text, dir)` | The normalization of `normalize`.                                           |
| `fakeOpenAI()`               | Starts the fake server and returns `{ baseURL, apiKey }`. `using` stops it. |
| `isCI`, `isLinux`, `isMacOS` | Platform facts.                                                             |

Tests that need actor or heap internals import `bouy:internal-for-testing`, which exists only when `BOUY_INTERNAL_FOR_TESTING=1`. It gives the actor count, the heap size of the calling actor, a garbage collection of the calling actor, and the port count. Bun's review rule applies: "Never add production code solely to make a test writable."

Fake servers listen on port 0 and print their port, as `bouy_fake_openai.erl` does today.

## 9. A test for every fixed bug

The procedure for an agent or a person:

1. Write the smallest program or test that shows the bug. Choose its place with the table below.
2. Record the oracle. For a program, run `scripts/freeze-expectations.sh <directory>`. For a file in `tests/unit`, run the same script on `tests/unit`.
3. Prove that the test fails without the fix: `BOUY_BIN=<bouy built from the base> cargo test -p bouy-cli --test <corpus>`, or `<that bouy> test <file>`. A test that passes on the base proves nothing.
4. Fix the cause, then run `pnpm check`.
5. When the fix changes upstream outcomes, run `bouy-suites <suite> --update` and `bouy-suites compat`, and commit the expectation, summary, and `COMPAT` files.
6. Commit the test and the fix together, as `fix(<scope>): <summary>`.

| The bug                                     | The test goes to                                                              |
| ------------------------------------------- | ----------------------------------------------------------------------------- |
| Language behavior differs from Node         | the conformance program of that behavior                                      |
| A documented difference                     | `tests/divergence`                                                            |
| A built-in or a Node API                    | `tests/unit/<module>.test.ts`                                                 |
| A package misbehaves                        | `tests/packages/<name>@<major>/main.mjs`, or a new program in that directory  |
| Module resolution                           | `tests/npm/<case>`                                                            |
| An actor, supervision, or CLI behavior      | `tests/programs` with a test in `programs.rs`, or `tests/cli`                 |
| A compiler crash or wrong Erlang            | a fixture in `crates/bouy-compiler/tests/fixtures`, and a conformance program |
| A runtime function                          | `runtime/test/<module>_tests.erl`                                             |
| It worked before, then broke, with an issue | `tests/regressions/<issue>.ts`                                                |
| A fuzz finding                              | `tests/fuzz/<generator>/<seed>.ts`, written by the campaign                   |

Rules for writing a test, from Bun's rules:

- Wait for the condition, never for a time. A sleep of 50 ms or more outside a bounded poll needs a comment.
- Use port 0, and never the public network.
- Read stdout and stderr of a child together. A pipe that nobody reads fills, and the child stops.
- Assert the exact stdout, stderr, and exit status. Never assert that output lacks `badarg` or `erl_crash.dump`: such a test still passes when the crash text changes.
- Keep each test under 1 s and each file under 10 s. The runners print the slowest files.
- Never weaken a test. A `skip` or `todo` names the failure that it saw, and a fix removes the `todo` entries that it makes pass.

The proof job checks step 3. For a pull request with a `fix` commit, CI builds `bouy` at the merge base. It runs the programs and test files that the pull request adds or changes, and each one must fail there.

## 10. CI

| Job         | Trigger                               | Work                                                                                                                                                                                                                     |
| ----------- | ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `check`     | every push and pull request (exists)  | `pnpm check`: formats, lints, tiers 1 to 4, 8a to 8c, 9, the fuzz replay, the migration fixture, the rule checks, and `compat --check`                                                                                   |
| `suites`    | every pull request and push to `main` | `bouy-suites` for test262, web-platform-tests, Node, and `tests/bun-test`, selected by section 3.7                                                                                                                       |
| `proof`     | a pull request with a `fix` commit    | section 9                                                                                                                                                                                                                |
| `comment`   | `workflow_run` of `suites`            | posts the comment of section 6                                                                                                                                                                                           |
| `nightly`   | schedule                              | every suite in full, the package suites, the bench limits, the checked lane, and the platform matrix. It opens one pull request that updates the expectation files, with regressions listed first and an issue for each. |
| `weekly`    | schedule                              | a pull request that moves test262 to the tip of tc39/test262; the fuzz campaign                                                                                                                                          |
| `quarterly` | manual                                | the package ranking, the Node pin, and an audit: remove every flaky entry, run the matrix, and keep the entries that still flake, as Bun's PR #36780 did                                                                 |

- The pull request jobs run on Linux x64 with OTP 29. The nightly matrix is OTP {the oldest supported release, 29} × {Linux x64, Linux arm64, macOS arm64}.
- Before a job runs a test, the runner checks the OTP release and the OS against the values that the job declares.
- A job splits into shards only when it passes 20 minutes. A test goes to the shard of its FNV-1a id hash, so a new upstream test moves no other test.
- GitHub starts no workflow for a pull request opened with `GITHUB_TOKEN`, so the nightly and weekly jobs open theirs with a GitHub App token.

## 11. Build order

The first seven phases start now, against today's compiler. Their first numbers are low by design and mark the start of the scale. Each phase lands with `pnpm check` green.

| Phase                                   | Work                                                                                                                                                                                                                                                                                                     | Exit criteria                                                                                                                                                                                                                                                                                                                                                    | Effort                                  |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| 0. Harness                              | The deadline in `compare()`; `bouy_env` and the `node` shim; `BOUY_BIN`; `BOUY_TEST_FILTER`; `.node-version` with a 26.x release, the version check, and the double run in the freeze script; one refreeze commit; `tests/README.md`; the rule checks; `migration.rs` with its expectation line.         | A program with an endless loop fails its test in 20 s. A test that starts `node` fails with the shim message. The freeze script refuses another Node version. The refreeze diff is reviewed and committed.                                                                                                                                                       | 1 day                                   |
| 1. Suite core and test262 compile phase | `crates/bouy-suites`: expectation files, `classify`, the comparison of section 3.3, `--update`, results, summaries, and the selection of section 3.7. test262: the fetch, the frontmatter parser, the modes, and the compile outcomes. The executions that compile run through `bouy run` until phase 8. | `tests/test262/expectations.txt` has one line for each of the 53,616 files. The CI job runs. Unit tests with small fake suites cover regressions, newly silent ids, and stale lines. The blockers table names `harness/assert.js`. Expected baseline: the parse-phase negative tests can pass, and almost every positive test is `rejected` through `assert.js`. | 2 days                                  |
| 2. Dashboard                            | `bouy-suites compat`, `docs/COMPAT.md`, `docs/compat.json`, `compat --check` in `pnpm check`, and the pull request comment.                                                                                                                                                                              | `docs/COMPAT.md` shows each tier with its first numbers.                                                                                                                                                                                                                                                                                                         | 1 day                                   |
| 3. Ecosystem baseline                   | `ranking.json`; the `tests/npm` cases; `tests/packages` for the 55 AI-tier packages; the pnpm workspace; `bouy-suites packages`; AI-stack scenarios with the fake server extensions.                                                                                                                     | Each program has its Node output and an expectation line, and `docs/COMPAT.md` has a row for each package. Expected baseline: no package program passes, because the compiler rejects a bare npm import with BOUY201.                                                                                                                                            | 3 days                                  |
| 4. Node suite                           | `scripts/vendor-node-tests.sh`, `tests/node`, `config.json`, `edited.txt`, the hash check, and the runner with its PR, filter, and nightly modes.                                                                                                                                                        | The suite at the pinned tag is vendored and checked. Each file has a line. The nightly report runs. First milestone: a file with only `require('../common')` exits with 0.                                                                                                                                                                                       | 1 day, then one module per pull request |
| 5. `bouy test`, first release           | `bouy_test_runner` and the first-release API of section 4.2, the reporters, parallel files, deadlines, and the CI rules. `tests/unit` with the Node check. `tests/cli/test-runner`. The first files of `tests/bun-test`. Test files stay inside today's subset until the engine grows.                   | Bouy's own TypeScript tests run under `bouy test` in `pnpm check`. The output tests pass. `tests/bun-test/expectations.txt` exists.                                                                                                                                                                                                                              | 1 week                                  |
| 6. Fuzzing                              | `crates/bouy-fuzz` with the number, string, and JSON generators, the minimizer, and the replay corpus.                                                                                                                                                                                                   | One campaign ran. Each silent mismatch has a minimized case with its Node output, and the replay runs on every pull request.                                                                                                                                                                                                                                     | 2 days                                  |
| 7. Performance limits                   | `bench/thresholds.json`, the nightly bench job, and the `bouy check` of each bench program.                                                                                                                                                                                                              | The nightly job compared two runs with the limits and passed.                                                                                                                                                                                                                                                                                                    | half a day                              |

The next phases grow with the engine. Each one names the engine work that it waits for.

| Phase                               | Work                                                                                                                                                   | Waits for                                                                                | Exit criteria                                                                                                                                                              |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 8. test262 in the VM                | The batch runner, realms, the `$262` host, the async rule, the watchdog, and the reruns alone.                                                         | The realm and script entry points of section 5.5, and a promise job queue in each actor. | The full suite runs within the CI time limit, and `results.json` records the durations. `assert.js` and `sta.js` compile, so 35,486 files run code.                        |
| 9. `bouy test`, later release       | Mocks of modules, snapshots inline, fake timers, `.concurrent`, `node:test`, the aliases, and the mocha globals.                                       | Closures that write captured variables, getters, and `import()`.                         | The expect, mock, and snapshot files of `tests/bun-test` pass. Node files that use `node:test` run.                                                                        |
| 10. web-platform-tests              | The vendor script, the reporter, the runner, and the expectations.                                                                                     | `testharness.js` compiles.                                                               | `console`, `url`, `encoding`, `dom/abort`, `dom/events`, timers, and structured clone have rows in `docs/COMPAT.md`. Then `streams`, then `fetch/api` with a local server. |
| 11. Package suites and applications | `lookup.json`, the per-test Node oracle, the runner, and the framework shims.                                                                          | The module loader for `node_modules`, and `node:test` or mocha on Bouy.                  | The 12 first suites of section 5.8 have expectation files.                                                                                                                 |
| 12. Hardening                       | The checked lane, the platform matrix, the built-in sweep, each conformance program also inside a spawned actor, one SDK in many actors, and Fuzzilli. | The features that each item exercises.                                                   | Each runs nightly, and each finding has an issue.                                                                                                                          |

## 12. Changes to other documents

Each change lands with the phase that needs it:

- **migration-plan.md section 11 and decision D9.** This design replaces the harness port, the wrapper function, the `bouy fix` step, `subset.txt`, and `baseline.json`. test262 runs unmodified, every file has a line in `tests/test262/expectations.txt`, and a pull request runs the selection of section 3.7. The crate is `crates/bouy-suites`, not `crates/bouy-test262`, because the runners of tiers 5 to 8 use one expectation format, one `classify`, and one dashboard. The silent failures stay the tracked number.
- **beam-runtime.md.** Section 15 points to this file. The contract gains `bouy test`, `bouy:test`, `BOUY_RESULT_FILE`, `BOUY_CHECK`, the Node argv of `bouy`, and the realm entry points when each one lands.
- **AGENTS.md.** The `tests` item lists the new directories. Three rules join the list: the placement rule of section 7, the proof rule of section 9, and the three places that may run `node`.
- **tests/conformance/README.md.** The double run, the version check, and the normalization of the freeze script.
- **tests/README.md.** New, as the short manual: the outcomes, the placement table, and the procedure of section 9.

## 13. Not in this design

- Code coverage.
- Watch mode, and a `--changed` mode that selects tests from the import graph.
- Uploads to wpt.fyi, which need an account.
- A local npm registry. Bouy does not install packages, and `tests/npm` commits its `node_modules`. A registry comes with `bouy install`.
- Windows.
- Deno's unit tests. Bun's generated port of them has not been regenerated since 2024.

## 14. Sources

| Source                                                                                                                                                              | Used for                                                                               |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| oven-sh/bun at f8bc171976fb: `test/harness.ts`, `test/expectations.txt`, `test/flaky-tests.txt`, `scripts/runner.node.ts`, `test/CLAUDE.md`, `REVIEW.md`            | The harness API, the expectation format, retries, and the rules for tests              |
| oven-sh/bun `test/js/third_party/wpt-streams/` and `wpt-testharness-shim.ts`                                                                                        | Pinned counts, the record mode, and the graduation of expected failures                |
| oven-sh/bun `src/runtime/test_runner/`, `test/js/bun/test/expect.test.js`, `docs/test/*.mdx`                                                                        | The `bun:test` API, its phases, and its CI rules                                       |
| oven-sh/bun PRs #32630, #36780, #41352                                                                                                                              | Per-module Node rates, the expectations audit, and stale percentages                   |
| denoland/deno at a18ce337: `tests/node_compat/`, `tests/wpt/`, `tests/util/lib/test_runner.rs`; denoland/node_test at f287abd8                                      | The Node suite runner, the reports, WPT expectations, and hash sharding                |
| nodejs/node at f513ec7: `test/common/`, `test/common/wpt.js`, `test/wpt/status/`, `test/fixtures/wpt/versions.json`                                                 | Node's test needs, and WPT vendoring without a server                                  |
| cloudflare/workerd at 3d28dc61: `build/wpt_test.bzl`, `src/wpt/url-test.ts`                                                                                         | One entry for each file, and the split of "not yet" from "never"                       |
| tc39/test262 `INTERPRETING.md`, `harness/`, `features.txt`; test262.fyi `meta.json`                                                                                 | The runner rules, the harness, and the file count at d53ebc8                           |
| boa-dev/boa `tests/tester` and its workflows; bellard/quickjs `run-test262.c`; Kiesel `tools/test262`; LadybirdBrowser/libjs-test262; CanadaHonk/porffor `test262/` | The PR comment, the ratchet, the committed results map, batches, and compiler outcomes |
| nodejs/citgm `lib/lookup.json`; vitejs/vite-ecosystem-ci; vercel/next.js test manifests                                                                             | Package suite fields and per-test manifests                                            |
| npm downloads API, ecosyste.ms, wooorm/npm-high-impact                                                                                                              | The package ranking                                                                    |
| `bench/results/2026-10-16-apple-m5-pro.json`                                                                                                                        | The startup median of section 5.5                                                      |
| [migration-plan.md](migration-plan.md), [diagnostics.md](diagnostics.md), [beam-runtime.md](beam-runtime.md)                                                        | D8, the divergence register, the codes, and the contract                               |
