# ADR 0002: Language and runtime split

## 1. Status and context

**Superseded, 2026-10-16:** Buoy no longer runs on Node or Bun. It compiles TypeScript to Erlang and runs on BEAM; see [the BEAM contract](../design/beam-runtime.md). Paths under `packages/`, `e2e/`, `examples/`, and `bench/` refer to commit [`90529d8`](https://github.com/JGalbss/buoy/tree/90529d8), the last commit with the Node runtime.

**Status:** Accepted, 2026-10-16. The code at commit `86b0df8` implements each decision below.

[ADR 0001](0001-execution-architecture.md) chooses many default actors per thread on Node and Bun, with opt-in thread actors, and plans a pool of worker-thread schedulers (D1). This record decides which language each part uses, how the parts connect, and which command runs each check.

| Part                                               | Package                                        | Language and main dependency               |
| -------------------------------------------------- | ---------------------------------------------- | ------------------------------------------ |
| Compiler                                           | `crates/buoy-compiler`                         | Rust 1.98.0, oxc 0.154                     |
| Compiler binding                                   | `@buoy/compiler` (`crates/buoy-compiler-node`) | Rust, napi-rs 3                            |
| Runtime, public API, loader, CLI, standard library | `buoy` (`packages/buoy`)                       | TypeScript, Effect 4.0.5, built by tsdown  |
| Checker                                            | `@buoy/checker` (`packages/checker`)           | TypeScript, Effect 4.0.5, TypeScript 6.0.3 |

Turborepo and pnpm workspaces build the TypeScript packages, and a Cargo workspace builds the crates.

Constraints:

- The loader compiles each user file while Node or Bun loads it (`packages/buoy/src/loader/Loader.ts`), so compile time adds to every start.
- The owner chose Effect for TypeScript only: "effect ts only for ts". Code in another language follows that language's own idioms (`AGENTS.md`).
- Every performance claim cites a benchmark and its recorded output (`AGENTS.md`).

## 2. Options

| #   | Decision                      | Chosen                                                   | Alternative                                              |
| --- | ----------------------------- | -------------------------------------------------------- | -------------------------------------------------------- |
| 1   | Compiler front end            | A per-file oxc transform in Rust, loaded through napi-rs | A transformer on the TypeScript compiler API             |
| 2   | Code in the JavaScript engine | TypeScript with Effect                                   | TypeScript without Effect                                |
| 3   | Type-aware checks             | The TypeScript 6.0.3 compiler API, in-process            | The TypeScript 7.0.2 API                                 |
| 4   | Fiber scheduler               | `FairScheduler`, a custom Effect `Scheduler`             | Effect's `MixedScheduler`, in `"async"` or `"sync"` mode |
| 5   | Message copies                | An Effect Schema decode                                  | `structuredClone`, or a hand-written copy                |
| 6   | Runtime delivery              | A tsdown bundle in `dist/`                               | TypeScript source, stripped at load                      |
| 7   | Compilation scope             | One file at a time; whole-program checks in `buoy check` | A whole-program pass inside `buoy run`                   |

## 3. Decision

**1. Rust for the compiler front end.** The lowering needs syntax and scopes, and no types. It puts `if (__buoy.tick()) await __buoy.pause();` at the top of every loop inside an `async` function. It records each exported class with `__buoy.locate(Class, import.meta.url, "Name")`, so that a worker can load the class (`crates/buoy-compiler/src/lower.rs`). oxc parses one file, strips its types, and prints it. napi-rs exposes `compile(path, source)` as a synchronous function, so the Node loader hook and the Bun plugin call it in-process. A transformer on the TypeScript compiler API would load that compiler on every start, and TypeScript 7.0.2 has no transformer API.

**2. TypeScript with Effect in the engine.** The runtime runs each actor on an Effect fiber, keeps mailboxes and stream windows in Effect `Queue`s, and retires an incarnation with a `Scope` finalizer. Its public errors are `Schema.TaggedError` classes (`packages/buoy/src/runtime/`). Scripts in `bench/evidence/` that time raw platform primitives stay plain, because Effect would add its own cost to the number (`AGENTS.md`).

**3. TypeScript 6.0.3 for `buoy check`.** The rules BUOY101 to BUOY107 ask about the types of actor methods, module bindings, promises, and emitters (`packages/checker/src/`). `Project.load` builds one `ts.Program` from the entry and queries its checker in-process. The main entry of TypeScript 7.0.2 exports only version strings. TypeScript 7.0.2 puts its checker API under `typescript/unstable/sync` and `typescript/unstable/async`. That API sends each request to a separate `tsgo` process. TypeScript 7.0.2 has no transformer API (`package.json` and `dist/api/` of `typescript` 7.0.2).

**4. A custom Effect scheduler.** Effect's default `MixedScheduler` dispatches fiber work through `setImmediate` (`src/Scheduler.ts` of `effect` 4.0.5). On a hand-written actor, a `setImmediate` scheduler had a 13.4 µs p50 round trip on Node, and a microtask scheduler 0.17 µs ([measurements-node E2](../research/measurements-node.md)). A microtask-only scheduler let no timer run during a 6.5 ms window on Node (E2), and Effect documents that its `"sync"` mode does not yield to the event loop. `FairScheduler` runs fibers on microtasks inside a 4 ms slice and then yields one `setImmediate`, so timers and I/O run. Compiled loops check the slice through `tick()` every 1,024 iterations (`packages/buoy/src/runtime/FairScheduler.ts`).

**5. An Effect Schema decode for message copies.** One schema, `SendableValue`, defines what may cross (`packages/buoy/src/runtime/Sendable.ts`). Its decode checks and copies in one pass, and a failure names the path, for example `a function at [0][meta][render]` (`e2e/isolation.test.ts`). The worker protocol decodes with the same schema (`packages/buoy/src/thread/protocol.ts`). `structuredClone` turns a class instance into a plain object with no error: for a class `A`, `structuredClone(new A()) instanceof A` is `false` on Node 25.9.0.

**6. A tsdown bundle.** tsdown bundles the runtime, the CLI, and Effect into minified chunks in `packages/buoy/dist/` (`tsdown.config.ts`). The bin and the package exports point there, and types resolve from `src/`. The message of commit `86b0df8` reports a 258 ms median for `buoy run hello.ts` on Node. The source CLI took 871 ms, and the load average was near 20. No results file records that run.

**7. Per-file compilation.** The compiler reads one module and keeps no state between modules, so `buoy run` has no whole-program pass. `buoy check <entry>` and `buoy run --check <entry>` run the whole-program checks. The CLI imports `@buoy/checker`, and with it TypeScript, only inside those commands (`checkEntry` in `packages/buoy/src/cli/main.ts`).

## 4. Consequences

Easy:

- User files go through the compiler, and npm packages load unchanged through the loader of the host.
- Thread actors reuse the split, because each worker installs the same loader and binding (`packages/buoy/src/thread/host.ts`).

Hard:

- Contributors need two toolchains: rustup with Rust 1.98.0 (`rust-toolchain.toml`) and pnpm. The binding is a native file for each platform, such as `buoy-compiler.darwin-arm64.node`, so each platform needs its own build. oxc is before version 1.0 (0.154), so an upgrade can change the abstract syntax tree (AST) API that `lower.rs` uses.
- The compiler sees no types and no other files. It guards every loop in every `async` function, and `tick()` checks at run time whether a turn is active. Synchronous functions and package code get no preemption points.
- A Buoy actor costs more than a hand-written actor. A Buoy actor holds 8,669 bytes of V8 heap on Node, 67.7 times a hand-written actor. A sequential call has a p50 of 1.75 µs, 10.5 times the hand-written actor ([benchmarks](../benchmarks.md#spawn), load 7.0 to 38.5). The suite does not split the heap between Effect and Buoy's own objects. The message of commit `16b86fd` reports that the heap per idle actor fell from 15.1 KiB to 8.9 KiB. That commit runs each actor on one fiber and turns off Effect tracing for `spawn`.
- The Schema copy costs more than `structuredClone` in the recorded suite. A 77-byte record took 3.01 µs against 0.819 µs on Node, at a 1-minute load average of 7.1 to 37.0. Across three payloads, the ratio was 3.68 to 4.39 on Node and 5.17 to 7.42 on Bun ([benchmarks](../benchmarks.md#messages)). The copy runs synchronously on the thread of the sender.
- `FairScheduler` implements the `Scheduler` interface of Effect, so an Effect upgrade can break it.
- The repository type-checks with TypeScript 7.0.2, and `buoy check` uses 6.0.3, so the two can disagree on a diagnostic.
- `@buoy/checker` exports its TypeScript source, and Node 25.9.0 refuses to strip types under `node_modules` (`ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING`). On Node, `buoy check` therefore works only from this workspace until the checker has a build step.
- The bundle is minified and has no source maps, so runtime frames in a stack trace show minified names. The CLI, `e2e/`, and `bench/` load the built packages, so a change to `packages/buoy/src` or `crates/` needs `pnpm build` first.
- `buoy run` checks no types, so a program that skips `buoy check` gets no isolation diagnostics.

## 5. Validation

On 2026-10-16 between 15:43 and 15:49 UTC, `cargo test --workspace` passed 4 tests. `vitest run` passed 38 tests in `packages/buoy/` and 57 in `packages/checker/`. In `e2e/`, it passed 63 tests, which start programs on Node 25.9.0 and Bun 1.3.11.

| #   | Decision             | Existing test or benchmark                                 | To add                                                                                  |
| --- | -------------------- | ---------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| 1   | Rust compiler        | `crates/buoy-compiler/tests/compile.rs`; the startup suite | A benchmark of `compile()` per file                                                     |
| 2   | Effect runtime       | `packages/buoy/test/`; the spawn and request-reply suites  | None                                                                                    |
| 3   | TypeScript 6 checker | `packages/checker/test/`                                   | A timed `buoy check`; a check from an installed package                                 |
| 4   | `FairScheduler`      | E2; `e2e/fairness.test.ts`; the fairness suite             | A benchmark of Effect's default scheduler against `FairScheduler`, in `bench/evidence/` |
| 5   | Schema copies        | The messages suite; `e2e/isolation.test.ts`                | A benchmark of the Schema copy against a hand-written copy, in `bench/evidence/`        |
| 6   | Bundle               | The message of commit `86b0df8`                            | A new `bench/run.ts` session on Node and Bun, which loads `dist/`                       |
| 7   | Per-file compilation | `crates/buoy-compiler/tests/compile.rs`                    | None                                                                                    |

In the recorded startup suite, the compiler hook left the Node CPU median for a one-file program at 375 ms. It raised the Bun CPU median from 170 to 190 ms ([benchmarks](../benchmarks.md#startup)). Decision 1 fails if a recorded run shows the hook costing more CPU than the runtime import.

## 6. Revisit triggers

1. TypeScript releases a stable in-process checker API for version 7. Move `@buoy/checker` to it and drop TypeScript 6.0.3.
2. A lowering needs types or facts from another file. Reconsider the per-file compiler.
3. A recorded agent workload shows message copies taking longer than the method bodies. Replace the decode with a hand-written copy that keeps the `NotSendable` paths.
4. An Effect release changes the `Scheduler` interface or the dispatch of `MixedScheduler`. Measure both schedulers again, and keep `FairScheduler` only while the default hops through a macrotask.

## 7. References

- [ADR 0001](0001-execution-architecture.md) and [AGENTS.md](../../AGENTS.md)
- [benchmarks.md](../benchmarks.md), output in [bench/results/](https://github.com/JGalbss/buoy/tree/90529d8/bench/results)
- [measurements-node.md](../research/measurements-node.md), E2
- Commit messages: `git show 16b86fd` and `git show 86b0df8`
- `effect` 4.0.5: `src/Scheduler.ts`
- `typescript` 7.0.2: `package.json` and `dist/api/`
