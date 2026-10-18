# Goal

Buoy makes TypeScript the best language for autonomous, massively concurrent, fault-tolerant AI agent systems. It does this by changing the execution model under TypeScript: TypeScript runs on BEAM, and actors are the execution primitive.

This file is the objective and the definition of done. The owner sets it, and every change to it quotes the owner. Agents check their work against it.

## Requirements

1. **TypeScript first.** Developers write ordinary TypeScript and keep their tools.
2. **Every npm package works unchanged, through general correctness.** Pure-JavaScript packages, ESM and CommonJS, load from `node_modules`. Packages that use Node built-ins work through Buoy's implementations of those APIs on BEAM. The target is 99% of the most-downloaded npm packages, measured by a suite that runs a large sample against Node as the oracle. Compatibility comes from correct JavaScript, Node, and web semantics and from general mechanisms such as WebAssembly fallbacks, never from code that special-cases one package. Native `.node` addons work through a general mechanism or fail with an error that names the alternative.
3. **No Node, no V8, and no global JavaScript event loop.** Buoy compiles to Erlang and runs on BEAM. Each actor is a BEAM process with its own JavaScript heap and promise queue.
4. **Actors by default.** Each actor has isolated state, a mailbox, a lifecycle, and a supervisor. The runtime gives bounded mailboxes, preemptive fair scheduling, cancellation, streaming, monitoring, and a path to durable execution and to distribution across machines.
5. **Effect TS works,** and the examples use it.
6. **Migration is easy.** An existing codebase runs as one actor, and a team adopts actors one class at a time. Anything that Buoy cannot run fails with a stable error code and the exact replacement, so a coding agent can do the migration.
7. **Complete Node coverage, proven by tests.** Every built-in module and global of the pinned Node release works on Buoy. Two numbers prove it for each module: the share of Node's own test files that pass, over every file at the pinned tag, and the share of the documented API surface that exists with the same shape. Both must reach 100%, except files and entries on a reviewed `never` list, which the dashboard names one by one.
8. **Tests on the model of Bun.** test262 covers the language. Node's own test suite covers each built-in module. web-platform-tests cover the web APIs. The test suites of popular packages cover the ecosystem. A `buoy test` runner is compatible with `bun:test`. Differential fuzzing compares Buoy with Node. A dashboard publishes the pass rates. Node is the oracle, and the tests never run it.
9. **Repository practice.** A Turborepo monorepo with `crates/` and packages, clean directories, the guardrails oxlint rules, Conventional Commits, and the public GitHub repository.
10. **Examples** that draw on the best agent and actor examples online.
11. **Faster than Bun, and better recovery than Bun.** Bun is the bar. Buoy must beat it on speed, measured on single-thread and concurrent suites, through type-directed compilation, native built-ins, a native tier for hot typed code that still yields to the BEAM scheduler, and all cores by default. Buoy must also recover better: a crash, a runaway loop, a memory leak, or a stuck call in one agent never stops the others, and a supervisor restarts that agent within milliseconds. `bench/` measures speed and recovery against Bun and Node.
12. **Durable execution built in.** Long-running workflows survive crashes and restarts on Buoy's own runtime: durable timers, retries with backoff, signals, cancellation, and replay or snapshots, with no external workflow server. Code written against Temporal's TypeScript SDK runs on it without the Temporal server.
13. **Production ready.** Teams can run Buoy in production: a self-contained release with the Erlang runtime inside, so the machine needs no Erlang install; Linux x86-64 and arm64 builds and a container image; OpenTelemetry tracing, metrics, and logs that work with existing Node instrumentation; soak, chaos, and memory tests that run for hours without a leak or a crash; a security review of the compiler, the runtime, and the native code; and versioned releases with a changelog.

## Launch gate

Nobody announces Buoy publicly until every line below holds. The owner: "ya this needs to be production grade so if i post on twitter i dont get clowned".

1. **Every claim has proof.** Each claim in the README and the docs links to a test, a row of `docs/COMPAT.md`, or a results file in `bench/results`. The benchmarks show Buoy's losses next to its wins. Nothing says "all of Node" or "all of npm" before the dashboard says 100%.
2. **The quick start works on a clean machine.** On a fresh macOS machine and a fresh Linux container, the install command and the README quick start work when pasted, in under 5 minutes. CI runs this on every release.
3. **One command reproduces the headline numbers,** and each results file records the hardware, the load, and the versions.
4. **A real demo.** The examples run, and a recorded demo shows a real agent app on Buoy surviving a crashed, a looping, and a leaking agent while the others keep serving.
5. **No known crash on the common path.** The fuzz corpus has no open silent mismatch, a 24-hour soak test passes, and every error that a new user can hit names its fix.
6. **A clean public repository.** No private data and no absolute local paths. A license, `CONTRIBUTING.md`, `SECURITY.md`, an honest status and limitations section, and green CI on Linux and macOS.

## Definition of done

- `buoy run example.ts` runs TypeScript.
- Several agents run as isolated actors, exchange messages, and call asynchronous operations.
- An actor can fail and restart without stopping unrelated agents.
- Real npm packages run unchanged: at least 99% of the sampled top npm packages pass, with no per-package special case in the engine, and the dashboard states each tier's rate.
- Every Node built-in module reaches 100% on both Node coverage numbers, apart from the named `never` entries.
- The compiler implements actor-aware lowering.
- The end-to-end tests pass, and the benchmarks against equivalent Node and Bun programs are reproducible.
- `bench/results` shows Buoy faster than Bun on the speed suites, and the recovery suites show each fault contained to one agent and restarted, where Bun loses the process or stalls.
- The documents state the limitations and the next milestones.
- A production release ships for Linux and macOS with the runtime inside, and the soak and chaos suites pass.
- Tests prove each invariant: fault isolation, state isolation, message ordering, supervision recovery, cancellation, bounded mailboxes, npm equivalence, and stability under load.

## Amendments

The owner added these on 2026-10-16, in order:

- "if we are doing typescript use effect ts", then "effect ts only for ts"
- "we should be using a mono repo manager with this and packages and crates", "like turbo repo or something like all modern best practices"
- "ideally no js event loop at all we abandon for a new runtime", then "no node v8 deps"
- "lets use effect ts in our examples with buoy so this all compiles to beam"
- "also add some better examples to this like looking around online"
- "we need to be able to use all npm packages otherwise what is the point"
- "really good tests for these take inspiration from bun"
- "we need complete coverage of node and like a verifiable way to have that with tests"
- "shoudlnt this also be super fast", then "we shold i think be able to make it fast as hell"
- "it needsto be more performant and better recovery then bun"
- "we need 100% node coverage", "if this is going to be used in prod"
- "ya this needs to be production grade so if i post on twitter i dont get clowned"
- "also like we need to be compatible with like 99% of lbis on npm and shit", then "liek we dont do 1 offs"
