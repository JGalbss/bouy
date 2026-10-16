# Bouy

Bouy is a TypeScript compiler and runtime that runs AI agents as actors. You write an agent as an ordinary class. `spawn()` starts the class as an actor with private state, a mailbox, and a supervisor. A call between actors copies its arguments and its result. A failed actor restarts with fresh state. The compiler adds a preemption point to each loop in an async function, so a busy agent shares the thread with the other agents. Bouy follows the Erlang/OTP design: many light processes, message passing, and supervision trees. Bouy runs on Node and Bun. It compiles only your own files, so npm packages load as they do in plain Node.

## Quick start

You need Node 24 or later, pnpm 10, and Rust from rustup. Bun 1.3.11 is optional.

`rust-toolchain.toml` pins Rust 1.98.0, and only rustup reads that file. Inside the repository, `cargo --version` must print 1.98.0. If it prints an older version, put `~/.cargo/bin` first on your `PATH`.

```sh
git clone https://github.com/JGalbss/bouy.git
cd bouy
pnpm install
pnpm build
pnpm install
./examples/node_modules/.bin/bouy run examples/hello.ts
```

`pnpm build` compiles the Rust compiler in release mode and bundles the runtime into `packages/bouy/dist/`. The second `pnpm install` links the `bouy` command. The first install cannot link it, because `dist/cli.mjs` does not exist yet.

The program prints:

```text
Hello, Ada! (1 greeted, checksum 499500)
Hello, Grace! (2 greeted, checksum 499500)
caught: greeter#3 failed in fail: Error: the greeter tripped
Hello, Linus! (1 greeted, checksum 499500)
Greeter: idle, restarts 0
greeter: idle, restarts 1
```

The last line shows that the supervisor restarted `greeter` after `fail()` threw.

The same program runs in three other ways. Run these commands from `examples/`, because Node and Bun find the `bouy` package there:

```sh
cd examples
node --import bouy/register hello.ts            # Node, compiler as a loader hook
bun --preload bouy/register hello.ts            # Bun, compiler as a loader plugin
bun ../packages/bouy/dist/cli.mjs run hello.ts  # Bun, through the CLI
```

`bouy run <entry> [args...]` passes the arguments to the program. Put `--` before arguments that start with `-`. `bouy run --check <entry>` runs the checks before the program starts. `bouy check <entry>` runs only the checks.

## Example

```ts
import { openai } from "@ai-sdk/openai";
import { generateText } from "ai";
import { signal, spawn } from "bouy";

class ResearchAgent {
  readonly #notes: Array<string> = [];

  async research(topic: string): Promise<string> {
    const { text } = await generateText({
      model: openai.chat("gpt-5"),
      prompt: `Research ${topic}.`,
      abortSignal: signal(),
    });
    this.#notes.push(text);
    return text;
  }

  notes(): ReadonlyArray<string> {
    return this.#notes;
  }
}

const topics = ["the actor model", "supervision trees", "green threads"];
const reports = await Promise.all(topics.map((topic) => spawn(ResearchAgent).research(topic)));
console.log(reports);
```

- `spawn(ResearchAgent)` starts one actor and returns a `Ref<ResearchAgent>`. The ref has the class's methods, and each call returns a promise.
- The three agents call the model at the same time. Each agent keeps its own `#notes`.
- If `research()` throws, the caller gets `ActorFailed`, and that agent restarts with an empty `#notes`.
- `signal()` returns the signal of the current turn, so the model call stops when the caller cancels or the agent stops.
- `new ResearchAgent()` still makes a plain object, for example in a unit test.

This example needs `OPENAI_API_KEY`. [`examples/research-team.ts`](examples/research-team.ts) runs a larger team against a local fake model server, so it needs no key. It adds a supervision tree, a search tool that crashes and restarts, and a writer that streams its summary.

## Core ideas

- **Classes as actors.** `spawn(Class, options)` starts an actor and returns a ref. `new Class()` still makes a plain object. The spawn options set the constructor arguments, a name, the mailbox, the restart policy, and the placement.
- **One turn at a time.** An actor takes one message at a time, and its turn lasts until the method's promise settles. Messages from one sender arrive in send order.
- **Copied messages.** Arguments and results cross as copies. Sendable values can cross: plain data, `Date`, `Uint8Array`, `Map`, `Set`, and refs. A function or an instance of another class fails with `NotSendable`. A subclass of `Map`, `Set`, `Array`, or `Date` crosses as its base type. A Node `Buffer` crosses as a view of the sender's memory, so send `new Uint8Array(buffer)`.
- **Restart on failure.** A thrown error rejects the caller with `ActorFailed` and restarts the actor with fresh state. Queued messages and refs survive the restart. `supervise()` builds one-for-one, one-for-all, and rest-for-one trees.
- **Calls.** An `async *` method streams through the ref. `cast(ref).method()` sends without a reply. A call carries the caller's `AbortSignal` into the callee, which reads it with `signal()`. If actor A calls actor B and B calls A back, the call to A fails with `CallCycle`, so the two actors do not deadlock.
- **Scheduling and placement.** A compiled loop in an actor's async method yields to other actors, timers, and I/O once the 4 ms scheduler slice is spent. `spawn(Class, { isolation: "thread" })` runs an actor in its own worker thread, with a stall watchdog.

The other functions are `self`, `withSignal`, `stop`, `monitor`, `inspect`, `shutdown`, `child`, and `tree`. Failures are tagged error classes: `ActorFailed`, `ActorStopped`, `MailboxFull`, `MessageDropped`, `CallCycle`, `NotSendable`, and `ActorClassInvalid`. [docs/architecture.md](docs/architecture.md) defines the full semantics.

## Checks

`bouy check <entry>` type-checks the program. It also checks every class that the program passes to `spawn`, `child`, or `pool`.

| Code         | Severity                           | What it reports                                                                         |
| ------------ | ---------------------------------- | --------------------------------------------------------------------------------------- |
| `BOUY101`    | error                              | A parameter of a public actor method is not Sendable.                                   |
| `BOUY102`    | error                              | An actor method returns or yields a value that is not Sendable.                         |
| `BOUY103`    | error                              | An actor method reads or writes mutable module-level state.                             |
| `BOUY104`    | warning                            | An actor method starts a promise that can outlive its turn.                             |
| `BOUY105`    | error                              | An actor class has a method named `then`.                                               |
| `BOUY106`    | warning                            | A method returns an async iterable but is not an `async *` method, so it cannot stream. |
| `BOUY107`    | warning                            | An actor method uses a module-level event emitter.                                      |
| `TS<number>` | error, or warning for a TS warning | A TypeScript diagnostic.                                                                |

An error makes `bouy check` and `bouy run --check` exit with status 1. A warning does not. On Node, `bouy check` needs the workspace copy of `@bouy/checker` until that package has a build step.

## Standard library

`bouy/std` adds three tools:

- `pool(Class, size, options)` starts `size` actors and sends each call to the least busy one.
- `schedule(ref, { every } | { after }, "method", ...args)` casts a message on a timer and returns a `Disposable`.
- `register(name, ref)`, `lookup(name, Class)`, and `unregister(name)` name actors. `register` throws `NameTaken` for a name in use, and a name frees when its actor exits.

## Hosts

| Host       | Status                                                                                                                                                                                                                                                                                                              |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Node       | The primary host. Bouy targets the long-term support (LTS) lines: Node 24 now, and Node 26 when it becomes LTS on 2026-10-28. Development and every Node run in `bench/` used Node 25.9.0. The research notes also measured Node 24.2.0 (V8 13.6). Continuous integration (CI) runs `pnpm check` on Node 24 and 25. |
| Bun 1.3.11 | The second host. Bouy runs on it, and the end-to-end tests pass on it. CI does not install Bun.                                                                                                                                                                                                                     |

The host limits:

- On Bun 1.3.11, Bouy cannot tell which actor raised a fault in a `queueMicrotask` callback, a floating promise, or an `fs` callback. It logs the fault and sets exit status 1, and the actor does not restart.
- On Bun 1.3.11, the heap limit of a thread actor has no effect. A stalled worker keeps spinning after the watchdog restarts its actor. Bun 1.4.3 stopped a spinning worker in a research run on a Linux virtual machine.
- Under `bouy run`, `import.meta.main` is `false`, because the CLI loads the entry with `import()`. The loader hooks keep it `true`.
- Bouy does not support Deno.

## Benchmarks

These numbers come from one benchmark session per host on an Apple M5 Pro: [`bench/results/node-2026-10-16-m5pro.json`](bench/results/node-2026-10-16-m5pro.json) and [`bench/results/bun-2026-10-16-m5pro.json`](bench/results/bun-2026-10-16-m5pro.json). Other jobs loaded the machine. The 1-minute load average was 7.0 to 38.5 during the Node session and 30.6 to 36.6 during the Bun session. Compare the ratios. Treat each time as one session on a loaded machine. [docs/benchmarks.md](docs/benchmarks.md) explains the method and each suite.

p50 is the median, and p99 is the 99th percentile.

| Measure                                       | Bouy on Node 25.9.0 | Bouy on Bun 1.3.11 | Baseline on Node                          |
| --------------------------------------------- | ------------------- | ------------------ | ----------------------------------------- |
| Heap per idle actor, 100,000 actors           | 8,669 bytes         | 8,677 bytes        | 128 bytes for a hand-written actor        |
| Call to a sync method, p50                    | 1.75 µs             | 1.29 µs            | 0.167 µs for a hand-written actor         |
| Ping p99 while a neighbor actor spins for 2 s | 6.57 ms             | 45.9 ms            | 1,982 ms without the compiler             |
| Items per second from an `async *` method     | 0.933 million       | 0.990 million      | 12.4 million from a plain async generator |
| Schema copy of a 77-byte record               | 3.01 µs             | 2.17 µs            | 0.819 µs with `structuredClone`           |

Startup: commit `86b0df8` bundled the runtime and the CLI. Its message reports a 258 ms median for `bouy run hello.ts` on Node, against 871 ms from source, at a load average near 20. The startup suite in `bench/results/` ran before that commit, so it measured the source CLI.

## Repository layout

| Path                        | Contents                                                                                                                                               |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `crates/bouy-compiler`      | The Rust compiler. It lowers one TypeScript module at a time with oxc 0.154.                                                                           |
| `crates/bouy-compiler-node` | The napi-rs binding, which is the `@bouy/compiler` package.                                                                                            |
| `packages/bouy`             | The `bouy` package: the runtime, the public API, the loader, the CLI, and `bouy/std`, in TypeScript with Effect 4.0.5. tsdown bundles it into `dist/`. |
| `packages/checker`          | `@bouy/checker`, the `bouy check` diagnostics, on the TypeScript 6.0.3 compiler API.                                                                   |
| `examples/`                 | Runnable agents and a fake OpenAI server.                                                                                                              |
| `e2e/`                      | End-to-end tests that start real processes on Node and Bun.                                                                                            |
| `bench/`                    | Benchmarks against equivalent plain Node and Bun code, with recorded results.                                                                          |
| `docs/`                     | The architecture, the decision records, the benchmarks, the npm compatibility note, and the research notes.                                            |

pnpm workspaces and Turborepo run the TypeScript tasks. Cargo builds the crates.

## Development

```sh
pnpm check                    # format and lint checks, clippy, type check, Vitest and Cargo tests, builds
pnpm bench                    # the benchmark suites on Node, written to bench/results/
bun bench/run.ts              # the same suites on Bun
pnpm --filter @bouy/e2e test  # the end-to-end tests only
```

Run `pnpm build` after you change `packages/bouy/src/` or `crates/`, because the CLI, `e2e/`, and `bench/` load the built packages. Run `pnpm check` before every commit. Commit subjects follow Conventional Commits, and a hook rejects other subjects. [AGENTS.md](AGENTS.md) lists the repository rules.

## Status and limits

Bouy 0.1.0 is the first working version. The architecture decision record [ADR 0001](docs/adr/0001-execution-architecture.md) chooses many actors on one thread now. Its target is a pool of worker-thread schedulers. [docs/architecture.md](docs/architecture.md) explains the design and lists every known limit. The main limits today:

- Bouy preempts compiled loops in async functions only. npm package code, synchronous functions, and native calls run to completion, so a runaway call blocks every actor on the thread.
- Default actors, the ones without `isolation: "thread"`, share one heap, the module state of packages, and the built-in prototypes. Bouy sets no memory limit per default actor, and a native addon crash ends the process.
- Delivery is at most once, and a restart discards in-memory state.
- Errors cross as copies, so an `instanceof` check against a library error class fails.
- Thread actors cannot receive refs, stream, or see cancellation yet.

## License

MIT. See [LICENSE](LICENSE).
