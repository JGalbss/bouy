# Repository guidance

## Layout

- `crates/bouy-compiler`: the Rust compiler. oxc parses each TypeScript module, and the compiler lowers it to one Erlang module.
- `crates/bouy-cli`: the `bouy` command. It embeds the runtime sources, writes the generated Erlang, and starts one BEAM VM.
- `runtime`: the `bouy` OTP application in Erlang: the JavaScript value core, actors, supervision, and the library modules. rebar3 builds and tests it.
- `crates/bouy-bench`: the benchmark harness. It runs each suite in `bench/programs` with Bouy and with plain Node, and records the results in `bench/results`.
- `tests`: TypeScript programs that the Rust tests compile and run. `tests/conformance` holds language programs, `tests/equivalence` holds `effect` and `ai` programs, and `tests/programs` holds actor programs, which `crates/bouy-cli/tests/programs.rs` checks against the contract. Each conformance and equivalence program has a frozen `.stdout` file that `scripts/freeze-expectations.sh` records with node, the oracle. The tests never run node.
- `docs/design/beam-runtime.md`: the contract between the compiler, the CLI, and the runtime. `docs/adr/` holds the decision records, and `docs/research/` holds the research notes.

Turborepo orders and caches the runtime tasks. Cargo builds the crates. `rust-toolchain.toml` pins Rust, so use the rustup toolchain, not a system `cargo`.

## Rules

- The product runs on BEAM only. Do not add a Node, Bun, or V8 dependency to the compiler, the CLI, or the runtime. Node may appear only as a test oracle for JavaScript semantics and as a benchmark baseline.
- Run `pnpm check` before every commit. It runs the oxfmt and rustfmt checks, oxlint, clippy, the Cargo tests, and the rebar3 EUnit tests and dialyzer.
- Write commit subjects as Conventional Commits: `<type>(<scope>): <summary>`. The `commit-msg` hook in `.githooks/` and the CI `commits` job reject other subjects.
- The contract in `docs/design/beam-runtime.md` is normative. Change it in the same commit as a change to a name or a semantic it defines.
- Rust follows Rust idioms and the workspace lints. Erlang follows OTP conventions: a `-spec` on every exported function, no compiler warnings, and a clean dialyzer run. TypeScript source, such as examples, uses Effect 4.
- The lint uses the vendored guardrails plugins in `tools/oxlint/guardrails/`. Do not edit that copy. Do not disable a rule, lower a severity, or add a cast to make the lint pass. Change the code.
- Every performance claim in a document cites a benchmark in `bench/` and its recorded output. Do not write a number that no benchmark produced.
- Every claim about library compatibility names the package, the version, and the test that proves it.
