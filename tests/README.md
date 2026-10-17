# Tests

[docs/design/testing.md](../docs/design/testing.md) is the design of the tests, and it is normative. This file is the short manual: how to run the tests, the outcomes, where a new test goes, and the procedure for a fixed bug.

## Run

| Command                                                                  | Runs                                                                                                                                            |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `pnpm check`                                                             | Every check of a pull request.                                                                                                                  |
| `cargo test -p bouy-cli --test conformance`                              | One corpus. The other test files are `equivalence`, `ai`, `ecosystem`, `node_surface`, `programs`, `migration`, `fuzz`, `bench`, and `harness`. |
| `BOUY_TEST_FILTER=arrays cargo test -p bouy-cli --test conformance`      | Only the corpus programs whose path contains `arrays`.                                                                                          |
| `BOUY_BIN=<path> cargo test -p bouy-cli`                                 | The tests against another `bouy` binary.                                                                                                        |
| `BOUY_TEST_TIMEOUT=60000 cargo test -p bouy-cli`                         | The tests with a deadline of 60 s for each run. The default is 20 s.                                                                            |
| `cargo test -p bouy-suites --test rules`                                 | The rule checks of the test layout.                                                                                                             |
| `cargo build --release -p bouy-cli`                                      | The `bouy` that `bouy-suites` runs. Build it before a suite, or set `BOUY_BIN`.                                                                 |
| `cargo run --release -p bouy-suites -- test262`                          | test262, compared with `tests/test262/expectations.txt`. The first run fetches it into the cache.                                               |
| `cargo run --release -p bouy-suites -- test262 --filter built-ins/Array` | Only the test262 ids that contain `built-ins/Array`.                                                                                            |
| `cargo run --release -p bouy-suites -- test262 --update`                 | Every test262 id, then rewrites `expectations.txt` and `summary.json` in `tests/test262`.                                                       |
| `cargo run --release -p bouy-suites -- node`                             | Node's own tests of `tests/node/suite`, compared with `tests/node/expectations.txt`. `--select pr` runs the selection of a pull request.        |
| `cargo run --release -p bouy-suites -- node --filter parallel/test-fs-`  | Only the Node test files whose path contains `parallel/test-fs-`.                                                                               |
| `cargo run --release -p bouy-suites -- node --update`                    | Every Node test file, then rewrites `expectations.txt` and `summary.json` in `tests/node`.                                                      |
| `cargo run --release -p bouy-suites -- node-surface`                     | Probes each entry of `tests/node/surface.json` on Bouy, compared with `tests/node/surface/expectations.txt`. `--update` rewrites it.            |
| `scripts/node-surface.sh`                                                | Writes `tests/node/surface.json` with the pinned node and Node's `doc/api/all.json`. When the pin moves.                                        |
| `scripts/vendor-node-tests.sh`                                           | Copies Node's tests at the tag of `.node-version` into `tests/node/suite`, and writes `suite.sha256`. When the pin moves.                       |
| `cargo run --release -p bouy-suites -- packages`                         | `tests/npm`, `tests/packages`, and the scenario areas of `tests/equivalence`, compared with their expectation files.                            |
| `cargo run --release -p bouy-suites -- packages --update`                | Every program of those corpora, then rewrites each `expectations.txt` and `tests/packages/summary.json`.                                        |
| `scripts/rank-packages.sh`                                               | Writes `tests/packages/ranking.json` from the npm APIs. Each quarter.                                                                           |
| `scripts/package-exports.sh`                                             | Writes `package.json`, `exports.mjs`, and `exports.cjs` of each AI-tier directory of `tests/packages`. Then `pnpm install`.                     |
| `cargo run --release -p bouy-fuzz -- campaign --count 200`               | The fuzz campaign: seeds 0 to 199 of each generator, on Node and on Bouy. It writes a case for each new mismatch to `tests/fuzz`.               |
| `pnpm compat`                                                            | Writes `docs/COMPAT.md` and `docs/compat.json` from the summaries. `--check` only compares.                                                     |

Each run of a program has the environment of `bouy_env` in `crates/bouy-suites/src/lib.rs`: `TZ=Etc/UTC`, `LANG=C.UTF-8`, `NO_COLOR=1`, `CI=1`, and a fresh `TMPDIR`. The other host variables are gone, except the ones that locate the runtime and Erlang. `tests/shim/node` comes first on `PATH`, so a test that starts node fails with `a test tried to run node`. `BOUY_MAX_MEMORY=1G` halts a test VM past 1 GiB, and a runner starts at most 8 VMs at once. A run past the deadline is killed and fails.

## The oracle

Node is the oracle, and no test runs it. `scripts/freeze-expectations.sh <directory>` records what Node prints for each program, and the tests compare `bouy run` with that record.

- The script runs only the Node release in `.node-version`, and it refuses another release.
- The script runs each program twice, in the environment of `bouy_env`, and it refuses a program whose two runs differ.
- Only the freeze script, `scripts/node-surface.sh`, `crates/bouy-bench`, and `crates/bouy-fuzz` start node. `crates/bouy-suites/tests/rules.rs` checks it.

## Outcomes

| Outcome         | Meaning                                                                               |
| --------------- | ------------------------------------------------------------------------------------- |
| `pass`          | The result equals the Node result, or the upstream test's own check passes.           |
| `rejected`      | The compiler reported a diagnostic.                                                   |
| `late`          | The run threw a `TypeError` with the code `ERR_BOUY_UNSUPPORTED`.                     |
| `skip`          | The test can never apply to Bouy, and `config.json` gives the reason.                 |
| `never`         | Bouy will never have the entry, and `tests/node/never.txt` gives the reviewed reason. |
| `fail`          | The program ran, and the result differs from Node. This is a silent divergence.       |
| `timeout`       | The deadline passed.                                                                  |
| `harness_error` | A harness file compiled and then threw, so the test never started.                    |
| `crash`         | A Bouy bug: a compiler panic, generated Erlang that does not compile, or a VM crash.  |

`rejected`, `late`, and `skip` are loud: the user sees them. `fail`, `timeout`, and `harness_error` are silent. A corpus with an `expectations.txt`, such as `tests/migration`, holds one line for each program: its id and its outcome. A run with another outcome fails.

## Where a test goes

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

Section 11 of the design builds `tests/divergence`, `tests/unit`, and `tests/cli`. Until a directory exists, put the test in the nearest corpus that exists.

- Name a program after the behavior that it shows, such as `arrays-sort.ts`, never after a bug.
- Add a case to the existing file of the behavior. Create a file only when no file covers the area.
- Never change an existing case into the new one.
- Name a regression after its issue number, with no zero padding.

## A test for every fixed bug

1. Write the smallest program or test that shows the bug. The table above gives its place.
2. Record the oracle: `scripts/freeze-expectations.sh <directory>`.
3. Prove that the test fails without the fix: `BOUY_BIN=<bouy built from the base> cargo test -p bouy-cli --test <corpus>`. A test that passes on the base proves nothing.
4. Fix the cause, then run `pnpm check`.
5. When the fix changes the outcomes of an upstream suite, run `cargo run --release -p bouy-suites -- <suite> --update`, then `pnpm compat`. Commit the expectation and summary files with `docs/COMPAT.md` and `docs/compat.json`.
6. Commit the test and the fix together, as `fix(<scope>): <summary>`.

Rules for a test:

- Wait for the condition, never for a time.
- Use port 0, and never the public network.
- Read the stdout and the stderr of a child together.
- Assert the exact stdout, stderr, and exit status.
- Keep each test under 1 s and each file under 10 s.
- Never weaken a test. A `skip` or `todo` names the failure that it saw.
