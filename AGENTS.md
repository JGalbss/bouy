# Repository guidance

## Layout

- `packages/bouy`: the `bouy` npm package. It holds the actor runtime, the public API, and the CLI, in TypeScript with Effect.
- `packages/checker`: `@bouy/checker`, type-aware isolation diagnostics built on the TypeScript compiler API.
- `crates/bouy-compiler`: the Rust compiler that lowers one TypeScript module into actor-aware JavaScript with oxc.
- `crates/bouy-compiler-node`: `@bouy/compiler`, the napi-rs binding that loads the Rust compiler into Node.
- `examples`, `bench`, `e2e`: runnable agents, benchmarks against plain Node.js, and end-to-end tests.
- `docs`: the architecture document, the decision records in `docs/adr/`, and research notes in `docs/research/`.

Turborepo runs the TypeScript tasks. Cargo builds the crates. `rust-toolchain.toml` pins Rust, so use the rustup toolchain, not a system `cargo`.

## Rules

- Run `pnpm check` before every commit. It runs oxfmt and rustfmt checks, oxlint and clippy, the TypeScript type check, the Vitest and Cargo tests, and the builds.
- Write commit subjects as Conventional Commits: `<type>(<scope>): <summary>`. The `commit-msg` hook in `.githooks/` and the CI `commits` job reject other subjects.
- The lint uses the vendored guardrails plugins in `tools/oxlint/guardrails/`. Do not edit that copy. Do not disable a rule, lower a severity, or add a cast to make the lint pass. Change the code.
- Write TypeScript source with Effect 4: services as `Context.Service` with a static `layer`, errors as `Schema.TaggedError`, reusable operations as `Effect.fn("Module.operation")`. Effect applies to TypeScript only. Code in another language follows that language's own idioms. Measurement scripts in `bench/evidence/` that time raw platform primitives stay plain, because Effect would add its own cost to the number.
- `src/` uses erasable TypeScript syntax only, because Node runs it with type stripping. Use `.ts` extensions on relative imports.
- Every performance claim in a document cites a benchmark in `bench/` and its recorded output. Do not write a number that no benchmark produced.
- Every claim about npm compatibility names the package, the version, and the test that proves it.
- `docs/architecture.md` is the living design document. Update it in the same commit as a change to the semantics it describes.
