# Repository guidance

## Layout

- `crates/buoy-compiler`: the Rust compiler. oxc parses each TypeScript module, and the compiler lowers it to one Erlang module.
- `crates/buoy-cli`: the `buoy` command. It embeds the runtime sources, writes the generated Erlang, and starts one BEAM VM.
- `runtime`: the `buoy` OTP application in Erlang. rebar3 builds and tests it. `runtime/src` holds one directory for each subsystem, as Bun's `src/` does. Put a new module in the directory of its subsystem: `crates/buoy-suites/tests/rules.rs` fails on an `.erl` file at the top of `runtime/src` or `runtime/test`.
  - `engine`: the reference engine: the operations of compiled code, the heap, the realm, the job queue, classes, and the module loader.
  - `builtins`: the families of `buoy_ref_realm:families/0`. A family of several files has a directory: `regexp`, `binary`, `time`, `iterator`, and `intl`.
  - `node`: the Node host. `node/bindings` holds the `internalBinding` modules, one `buoy_binding_<name>.erl` for each binding.
  - `actors`: the functions of `"buoy"`, actors, supervision, the registry, and the worker processes of `Promise.all`.
  - `library`: the `effect` and `ai` modules.
  - `host`: the boot of a program, the OTP application, the memory guard, and the loaders of the NIF libraries.
  - `value`: `buoy_rt`, the value core of `--semantics value`, and its namespaces.
  - A new file goes by its name: `buoy_binding_*` into `node/bindings`, `buoy_node_*` and the Node agents such as `buoy_trace` into `node`, `buoy_crypto*` into `node/crypto`, `buoy_ref_*` into `builtins` or the directory of its family, `buoy_jit` into `engine`, the NIF loader `buoy_native` into `host`, and `<module>_tests.erl` into the `runtime/test` directory of `<module>`.
  - `runtime/include` holds the headers. `runtime/test` has the directories of `runtime/src`. `runtime/node` holds Buoy's versions of Node's `lib/` ids, and `runtime/vendor` holds the vendored upstream code.
- `crates/buoy-bench`: the benchmark harness. It runs each suite in `bench/programs` with Buoy, Node, and Bun, and records the results in `bench/results`. `buoy-bench compare` checks the nightly runs against the limits of `bench/thresholds.json`.
- `tests`: TypeScript programs that the Rust tests compile and run. `tests/README.md` is the manual. `tests/conformance` holds language programs, `tests/equivalence` holds library programs (`effect` and `ai` pass, and the other areas are AI-stack scenarios with an `expectations.txt`), `tests/npm` holds module resolution cases, `tests/packages` holds one program directory for each major version of the AI-tier npm packages, `tests/ecosystem` holds the tier of the top 1,000 npm packages that `scripts/ecosystem.sh` generates and installs, `tests/programs` holds actor programs, which `crates/buoy-cli/tests/programs.rs` checks against the contract, `tests/migration` holds a Node-style app that Buoy must run unchanged, and `tests/node/test` holds Node's own tests, which `scripts/vendor-node-tests.sh` copies byte for byte at the tag of `.node-version`. Only `tests/node/test/common` may change, with a line in `tests/node/edited.txt`. Each conformance and equivalence program has a frozen `.stdout` file that `scripts/freeze-expectations.sh` records with node, the oracle, at the release in `.node-version`. The tests never run node: `tests/shim/node` fails every call.
- `crates/buoy-suites`: the runner of the upstream test suites of `docs/design/testing.md`, and the rule checks of the test layout. `cargo run --release -p buoy-suites -- test262` fetches test262 at the commit of `tests/test262/config.json` into the cache and compares the run with `tests/test262/expectations.txt`. `--update` rewrites that file and `summary.json`. `buoy-suites node` runs `tests/node/test`, one `buoy` process per file, against `tests/node/expectations.txt`. `buoy-suites packages` runs `tests/npm`, `tests/packages`, and the scenario areas against their expectation files, and `crates/buoy-cli/tests/ecosystem.rs` runs it in `pnpm check`. `pnpm compat` writes `docs/COMPAT.md` and `docs/compat.json` from the summaries; never edit these files by hand.
- `crates/buoy-fuzz`: the differential fuzz campaign. `cargo run --release -p buoy-fuzz -- campaign` runs generated programs on Node and on Buoy, minimizes each silent mismatch and each crash, and writes it with its Node output to `tests/fuzz/<generator>/<seed>.ts`. `crates/buoy-cli/tests/fuzz.rs` replays the cases against `tests/fuzz/expectations.txt` in `pnpm check`.
- `docs/design/beam-runtime.md`: the contract between the compiler, the CLI, and the runtime. `docs/adr/` holds the decision records, and `docs/research/` holds the research notes.

Turborepo orders and caches the runtime tasks. Cargo builds the crates. `rust-toolchain.toml` pins Rust, so use the rustup toolchain, not a system `cargo`.

## Rules

- `docs/goal.md` holds the objective and the definition of done. Check your work against it.
- The product runs on BEAM only. Do not add a Node, Bun, or V8 dependency to the compiler, the CLI, or the runtime. Node may appear only as a test oracle for JavaScript semantics and as a benchmark baseline.
- Run `pnpm check` before every commit. It runs the oxfmt and rustfmt checks, oxlint, clippy, the Cargo tests, the rebar3 EUnit tests and dialyzer, and `buoy-suites compat --check`.
- Write commit subjects as Conventional Commits: `<type>(<scope>): <summary>`. The `commit-msg` hook in `.githooks/` and the CI `commits` job reject other subjects.
- The contract in `docs/design/beam-runtime.md` is normative. Change it in the same commit as a change to a name or a semantic it defines.
- Rust follows Rust idioms and the workspace lints. Erlang follows OTP conventions: a `-spec` on every exported function, no compiler warnings, and a clean dialyzer run. TypeScript source, such as examples, uses Effect 4.
- The lint uses the vendored guardrails plugins in `tools/oxlint/guardrails/`. Do not edit that copy. Do not disable a rule, lower a severity, or add a cast to make the lint pass. Change the code.
- Every performance claim in a document cites a benchmark in `bench/` and its recorded output. Do not write a number that no benchmark produced.
- Every claim about library compatibility names the package, the version, and the test that proves it, or links to its row of `docs/COMPAT.md`.
- Put a new test where the placement table of `tests/README.md` says. Add it to the existing file of the behavior, and name a program after the behavior that it shows.
- A `fix(...)` commit adds a test that fails on the merge base. Prove it with `BUOY_BIN=<buoy built from the base>` (`tests/README.md`).
- Only `scripts/freeze-expectations.sh`, `scripts/node-surface.sh`, `crates/buoy-bench`, `crates/buoy-fuzz`, and the baseline scripts in `bench/reference` start node. `crates/buoy-suites/tests/rules.rs` checks it.
- A runner that starts many test VMs gives each one a memory limit and starts at most 8 at once: build the command with `buoy_suites::buoy_env` (`BUOY_MAX_MEMORY=1G`, and `ERL_AFLAGS` for 2 schedulers without busy wait) and use `buoy_suites::default_jobs`. An unbounded run once grew three VMs to 128 GB and rebooted a 64 GB machine.
