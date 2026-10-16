# Bouy architecture

This is the living design document for Bouy. It covers the code in this repository and the semantics that its tests check. Read it before you change the runtime, and update it in the same commit as any change to the semantics below ([AGENTS.md](../AGENTS.md)).

Two decision records explain the large choices:

- [ADR 0001: Execution architecture](adr/0001-execution-architecture.md) chooses many light actors in one isolate on Node and Bun now. Its target is a pool of worker-thread schedulers (option D1).
- [ADR 0002: Language and runtime split](adr/0002-language-and-runtime-split.md) records why the compiler front end is Rust, and why all code that runs in the JavaScript engine is TypeScript with Effect.

[benchmarks.md](benchmarks.md) and `bench/results/` hold the measurements. [npm-compatibility.md](npm-compatibility.md) lists the npm packages that the tests prove.

## 1. Components

| Component        | Path                        | Built with                                  | Job                                                                                                                                               |
| ---------------- | --------------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bouy-compiler`  | `crates/bouy-compiler`      | Rust 1.98.0, oxc 0.154                      | Compiles one TypeScript module into JavaScript with preemption points and class locations. It reads no other file and uses no type information.   |
| `@bouy/compiler` | `crates/bouy-compiler-node` | Rust, napi-rs 3                             | Loads the compiler into the Node or Bun process. `compile(path, source)` returns code with a source map, or diagnostics with a line and a column. |
| `bouy`           | `packages/bouy`             | TypeScript, Effect 4.0.5, tsdown            | The runtime, the public API, the loader, the `bouy` CLI, and `bouy/std`.                                                                          |
| `@bouy/checker`  | `packages/checker`          | TypeScript 6.0.3 compiler API, Effect 4.0.5 | The `bouy check` diagnostics.                                                                                                                     |

The `bouy` package has four entry points. Programs import `bouy`, `bouy/std`, and `bouy/register`. Compiled code imports `bouy/intrinsics`. tsdown bundles these entry points, the CLI, and the thread host into `packages/bouy/dist/`, with Effect tree-shaken and bundled. `@bouy/compiler`, `@bouy/checker`, and `typescript` stay external. The CLI loads the checker and TypeScript only when a check runs.

The public API uses classes, promises, async iterables, and `AbortSignal`s. A program does not need to use Effect.

## 2. From `bouy run` to a running actor

1. `bouy run app.ts a b` starts `dist/cli.mjs`. With `--check`, the CLI runs the checker first, and an error stops the run with exit status 1.
2. The CLI installs the loader: `module.registerHooks` on Node, or `Bun.plugin` on Bun. `node --import bouy/register` and `bun --preload bouy/register` install the same loader without the CLI.
3. The CLI sets `process.argv` to the runtime, the entry path, and the program arguments. Then it loads the entry with `import()`.
4. The loader sends each user source file to `compile()` and returns the result with an inline source map. A user source file ends in `.ts`, `.mts`, or `.tsx`, is not a `.d.ts` file, and lies outside `node_modules` and the Bouy runtime. Other files load unchanged. A compile error throws `CompileFailed`, which lists each diagnostic as `file:line:column`.
5. The first call into the actor system, usually `spawn()`, builds it: an Effect `ManagedRuntime` over the `ActorSystem` layer. The layer adds the process fault listeners (5.10).
6. `spawn()` reads the blueprint of the class (section 3), copies the constructor arguments, and creates the mailbox. Then it forks the fiber of the actor on the fair scheduler.
7. For a default actor, the fiber constructs the instance inside a start turn before `spawn()` returns the ref. If the first construction throws, `spawn()` throws `ActorFailed` for the method `start`. The fiber then serves the mailbox.
8. `ref.method(...args)` copies the arguments into an envelope with the call chain and the cancellation signal of the caller, and it delivers the envelope. The fiber takes the envelope and calls the method inside the `AsyncLocalStorage` context of the turn. When the method's promise settles, the fiber copies the result and settles the caller's promise.

A program also runs under plain `node app.ts` or `bun app.ts`, without the compiler. Then no loop yields, and `isolation: "thread"` fails with `ActorClassInvalid`, because no class has a recorded location.

## 3. Declaring an actor

An actor is an ordinary class. Bouy has no base class, decorator, or keyword for actors. The spawn site makes a class an actor and chooses how it runs:

| Option      | Default                                                    | Meaning                                                                                  |
| ----------- | ---------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `args`      | `[]`                                                       | The constructor arguments. The runtime copies them at spawn and again at each restart.   |
| `name`      | the class name                                             | A label for `inspect()` and for errors, shown as `name#id`. It does not register a name. |
| `mailbox`   | `{ capacity: 1024, overflow: "backpressure" }`             | The mailbox size and its overflow policy (5.6).                                          |
| `restart`   | `{ restart: "permanent", maxRestarts: 3, withinMs: 5000 }` | The restart type, the intensity limit, and an optional `backoff` (5.4).                  |
| `isolation` | `"shared"`                                                 | `"thread"` runs the actor in its own worker thread (5.12).                               |
| `thread`    | `{ stallMs: 5000 }`                                        | The watchdog timeout and an optional `maxHeapMb` for a thread actor.                     |

The runtime builds one blueprint for each class (`packages/bouy/src/runtime/Blueprint.ts`). It walks the prototype chain:

- Each string-keyed function on a prototype becomes a ref method, and inherited methods count. Fields, accessors, `#private` methods, symbol-keyed methods, and static methods do not become ref methods.
- An `async *` method becomes a stream method. Every other method becomes a call method.
- A method named `then` makes the class invalid (`ActorClassInvalid`), because every ref to the class would look like a promise.
- A `[Symbol.asyncDispose]()` or `[Symbol.dispose]()` method becomes the dispose hook. The runtime calls it when an incarnation ends by restart or stop, and it waits up to 5 s.

A ref is a frozen object with one function for each method. It has no path to the fields of the instance (`packages/bouy/test/isolation.test.ts`). Its type derives from the class. On the ref, a method that returns `R` returns `Promise<Awaited<R>>`, and an `async *` method returns an `AsyncIterable`. A method that returns `never` returns `Promise<never>`.

| Function                                                         | Purpose                                                                                                            |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `spawn(Class, options)`                                          | Start an actor and return its ref.                                                                                 |
| `cast(ref).method(...args)`                                      | Send without a reply. The promise resolves to `true` when the mailbox accepts the message.                         |
| `self(this)`                                                     | Return the ref of the current actor. It succeeds only inside the actor's own turn, which includes its constructor. |
| `signal()`, `withSignal(signal, fn)`                             | Read the current cancellation signal, and call `fn` with another signal (5.7).                                     |
| `stop(ref)`, `monitor(ref)`                                      | Stop an actor, and wait for its exit (5.4).                                                                        |
| `inspect()`, `shutdown()`                                        | List the live actors, and stop every actor (5.4).                                                                  |
| `supervise()`, `child()`, `tree()`                               | Build a supervision tree (5.5).                                                                                    |
| `pool()`, `schedule()`, `register()`, `lookup()`, `unregister()` | The `bouy/std` tools for routing, timers, and names (5.13).                                                        |

The spawn site declares the actor for these reasons:

- The class keeps ordinary object semantics. `new ResearchAgent()` makes a plain object with direct calls, so a unit test needs no runtime. `instanceof`, inheritance, and `#private` fields behave as in plain TypeScript.
- One class can run in several placements. It can be a default actor, a thread actor, a pool member, or a tree child, and only the spawn options change.
- Compiled code keeps its plain behavior outside actors. `tick()` returns `false` when no actor turn is running, so a preemption point never yields in code that no actor calls.
- The ref type derives from the class type, so a call site needs no generated code. The checker finds actors by following calls to `spawn`, `child`, and `pool`, so it checks exactly the classes that cross a boundary.

## 4. What the compiler adds

The compiler reads one file at a time and uses no type information, so `bouy run` never waits for a whole-program pass. The type-aware rules run in `bouy check` (4.3). [ADR 0002](adr/0002-language-and-runtime-split.md) records this split.

### 4.1 Preemption points

The compiler strips TypeScript syntax with the oxc transformer. Then it puts this statement at the top of each loop body inside an `async` function, an async arrow function, or an `async *` method:

```js
if (__bouy.tick()) await __bouy.pause();
```

It covers `for`, `for...in`, `for...of`, `while`, and `do...while` loops. Loops in synchronous functions and static blocks get no point, because `await` is not valid there. That includes a synchronous callback inside an async function. The snapshot test `places_preemption_points_only_in_async_code` in `crates/bouy-compiler/tests/compile.rs` covers each shape.

`tick()` decrements a counter that all compiled loops share, and it reads the clock once every 1,024 calls. It returns `true` only when the 4 ms scheduler slice is spent and an actor turn is running. `pause()` waits for one `setImmediate` callback and starts a new slice (5.11).

Each compiled iteration pays for the check. Experiment E5 measured 0.57 to 0.91 ns per iteration for checks that decrement a counter. That is 213% to 332% of a trivial loop body ([measurements-node E5](research/measurements-node.md)). No benchmark isolates the cost of Bouy's own `tick()` yet (ADR 0001, section 5).

### 4.2 Class locations

After each exported class, the compiler adds a call that records the module URL and the export name:

```js
__bouy.locate(ResearchAgent, import.meta.url, "ResearchAgent");
```

The compiler finds `export class`, `export { Local as Exported }`, and a named `export default class`. A worker uses the location to import and construct the class for a thread actor (5.12). When a module needs `tick`, `pause`, or `locate`, the compiler adds `import * as __bouy from "bouy/intrinsics";` at the top.

### 4.3 Static rules

`bouy check <entry>` builds a TypeScript 6.0.3 program from the entry. It uses the nearest `tsconfig.json`, or strict defaults when it finds none. It finds each class that the program passes to `spawn` or `child` from `bouy`, or to `pool` from `bouy/std`. It follows named, renamed, namespace, and re-exported imports. Then it checks those classes and their base classes in your own files:

| Code         | Severity                           | Rule                                                                                                                                                                                                                  |
| ------------ | ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BOUY101`    | error                              | Each parameter of a public method must be Sendable. The message names the part of the type that fails.                                                                                                                |
| `BOUY102`    | error                              | Each return value, and each value that an `async *` method yields, must be Sendable.                                                                                                                                  |
| `BOUY103`    | error                              | Instance members must not read or write mutable module state: a module-level `let` or `var`, or a module-level `const` array, object, `Map`, or `Set` that some code mutates. Calls to functions in your files count. |
| `BOUY104`    | warning                            | Instance members must not drop a promise. Await it, return it, or discard it with `void`. They also must not pass an async function to a caller that ignores its result, such as `forEach`.                           |
| `BOUY105`    | error                              | A class must not have a method named `then`.                                                                                                                                                                          |
| `BOUY106`    | warning                            | A method that returns an async iterable must be an `async *` method, or its ref cannot stream the result.                                                                                                             |
| `BOUY107`    | warning                            | Instance members must not use a module-level value with `on` and `emit` methods, because a listener runs in the turn of the actor that emits.                                                                         |
| `TS<number>` | error, or warning for a TS warning | Each TypeScript pre-emit diagnostic.                                                                                                                                                                                  |

An error makes `bouy check` and `bouy run --check` exit with status 1. The rules are static, so the runtime still copies and checks every message (5.3). BOUY103 reads only your own files, so module state inside npm packages stays unchecked.

## 5. Runtime semantics

### 5.1 Turns

An actor takes one message at a time. A turn starts when the actor takes a message from its mailbox. The turn ends when the method returns a value, or when the method's promise settles. While a turn awaits, the actor takes no other message. An actor that waits on a slow model call therefore holds its mailbox until the call returns. Use more actors, or `pool()`, for concurrent calls. A promise that a method starts but does not await can run after its turn ends, and BOUY104 warns about it.

### 5.2 Ordering

Messages from one sender arrive in send order (`packages/bouy/test/messaging.test.ts`). The mailbox is one queue, so messages from different senders interleave in arrival order. A message that an incarnation takes just as it faults moves to the next incarnation, which keeps the order.

### 5.3 Copies

Every value that crosses an actor boundary is a copy: constructor arguments, call arguments, results, stream items, and error causes. An Effect Schema decode builds the copy (`copyArguments` and `copyValue` in `packages/bouy/src/runtime/Sendable.ts`). These values are Sendable:

- `string`, `number`, `boolean`, `bigint`, `null`, and `undefined`. They skip the Schema walk, because a primitive cannot share state.
- `Date` and `Uint8Array`. The copy clones them.
- Actor refs. A ref crosses as the same frozen object.
- Arrays, `Map`s, `Set`s, and plain objects built from Sendable values. A plain object has the prototype `Object.prototype` or `null`.

Any other value fails with `NotSendable`, and the message gives the path of the value, for example `a function at [0][meta][render]`. Functions, class instances, symbols, and promises fail. Pass a callback as an actor ref, and keep a library object inside the actor that created it. The error appears in three places:

- A call with an argument that is not Sendable rejects with `NotSendable`.
- `cast()` and stream methods throw `NotSendable` at the call site.
- A result that is not Sendable rejects the call with an `Error` named `NotSendable`. The actor keeps its state and does not restart.

Errors cross as copies too. The copy is a plain `Error` with the original name, message, stack, and `cause` chain (`copyError`). An `instanceof` check against a library error class fails on the copy.

The sender pays for the argument copy inside the call, and the actor pays for the result copy at the end of its turn. The copy is synchronous, so a large copy blocks every actor on the thread. In `bench/results/node-2026-10-16-m5pro.json`, the Schema copy took 3.01 µs for a 77-byte record and 22.2 ms for 10,000 records (813,891 bytes of JSON). `structuredClone` took 0.819 µs and 5.93 ms. Section 8 lists a defect with cyclic values.

### 5.4 Failure and restart

When a method throws, or its promise rejects, the actor fails:

1. The caller's promise rejects with `ActorFailed`. The error names the actor and the method, and its `cause` is a copy of the original error.
2. The incarnation ends. Its `AbortSignal` aborts, and the dispose hook runs.
3. The supervisor constructs a new instance from new copies of the constructor arguments.
4. The queued messages stay in the mailbox, and every ref stays valid.

The `restart` option sets the policy:

- `"permanent"` (the default) and `"transient"` restart the actor after a fault. An actor has no normal exit today, so the two types behave the same. `"temporary"` never restarts, so the first fault stops the actor.
- Intensity: by default, an actor can restart 3 times within 5,000 ms (`maxRestarts`, `withinMs`). The next fault in that window stops it for good with the exit `{ kind: "failed", cause }`. Later calls reject with `ActorStopped`.
- Backoff: with `backoff: { initialMs, maxMs }`, restart number n in the window waits `min(maxMs, initialMs × 2^(n−1))` ms.
- A constructor that throws during a restart counts as another fault.

An actor that a turn spawns belongs to the incarnation that ran the turn. It stops when that incarnation ends by restart or stop.

Delivery is at most once. The runtime never retries the message whose turn failed, and a restart discards all in-memory state.

`stop(ref)` stops an actor. The caller of the current turn gets `ActorStopped`, the signal of the turn aborts, queued messages fail with `ActorStopped`, and the dispose hook runs. `monitor(ref)` resolves with the exit: `{ kind: "stopped" }` or `{ kind: "failed", cause }`. `inspect()` lists the live actors with their status, mailbox size and capacity, processed messages, restarts, and last failure. `shutdown()` stops every actor and removes the process fault listeners. The next `spawn()` starts a new system.

### 5.5 Supervision

`supervise({ strategy, maxRestarts, withinMs, children })` starts a tree and returns refs in the shape of `children`. `child(Class, options)` declares an actor in the tree. `tree({ strategy, restart, maxRestarts, withinMs, children })` declares a nested tree.

| Strategy       | When a child fails, the tree restarts         |
| -------------- | --------------------------------------------- |
| `one-for-one`  | that child                                    |
| `one-for-all`  | every child                                   |
| `rest-for-one` | that child and the children declared after it |

- The tree starts its children in declaration order. `supervise()` returns when every child has started.
- The tree counts restarts against its own intensity limit: by default, 3 restarts within 5,000 ms. The tree uses the `restart` type of a child, but it ignores the child's own `maxRestarts`, `withinMs`, and `backoff`.
- A `temporary` child that fails leaves the tree with the exit `{ kind: "stopped" }`.
- When a nested tree exceeds its intensity limit, its parent counts that as a failure of one child. When the top tree exceeds its limit, every actor in it stops with the exit `{ kind: "failed" }`.
- `stop(ref)` on a child removes the child from its tree.

`packages/bouy/test/supervision.test.ts` covers each strategy and a nested tree.

### 5.6 Mailboxes

Each actor has a bounded mailbox, with a default capacity of 1,024 messages. The `overflow` policy decides what happens to a message that arrives when the mailbox is full:

| Policy                   | Result                                                                                                       |
| ------------------------ | ------------------------------------------------------------------------------------------------------------ |
| `backpressure` (default) | The message waits for room. The caller's promise stays pending, and the thread of the sender is not blocked. |
| `reject`                 | The message fails with `MailboxFull`.                                                                        |
| `drop-oldest`            | The oldest queued message fails with `MessageDropped`, and the new message joins the queue.                  |

`cast(ref).method()` resolves to `true` when the mailbox accepts the message. It resolves to `false` when the actor has stopped or a `reject` mailbox is full. The sender of a cast never sees the result or the failure of the method.

### 5.7 Cancellation

A call carries a cancellation signal from its caller:

- Inside a turn, a call carries the signal of the turn. That signal aborts when the caller of the turn cancels, or when the calling actor restarts or stops.
- Inside `withSignal(signal, fn)`, calls carry `signal` combined with any signal already in effect. `withSignal(undefined, fn)` calls `fn` with no change, which suits the optional `abortSignal` of an AI SDK tool.
- At the top level, outside `withSignal`, a call carries no signal.

When the signal aborts:

- A call that still waits in the mailbox never runs.
- The caller's promise rejects at once with the reason of the signal, or with an `AbortError`.
- In the callee, `signal()` aborts. Code that passes it on, for example to `fetch` or `generateText`, stops.
- If the turn of the callee then fails, the callee does not restart.

Bouy cannot interrupt a running promise, so the turn of the callee ends only when its promise settles. Outside any turn, `signal()` returns a signal that never aborts. In `ai` 7.0.142, a `textStream` loop ends without an error after an abort ([actor-models A.4](research/actor-models.md)). Code that relays such a stream must check `signal().aborted` to tell an abort from a complete answer.

### 5.8 Streams

An `async *` method streams. Its ref method returns an `AsyncIterable` in place of a promise.

- The stream starts when the consumer starts to iterate.
- The runtime copies each item and buffers up to 16 items (`STREAM_WINDOW` in `packages/bouy/src/runtime/Streaming.ts`). A full buffer pauses the generator.
- When the consumer stops early, for example with `break`, the runtime calls the generator's `return()`, so its `finally` blocks run (`packages/bouy/test/scheduling.test.ts`).
- The stream holds the turn of the actor. The actor takes no other message until the generator finishes or the consumer stops. A consumer that stops calling `next()` without a call to `return()` keeps the turn open.
- A generator that throws ends the stream with `ActorFailed`, and the actor restarts.
- Only `async *` methods stream. A method that returns another async iterable rejects the call with an `Error` named `NotSendable`, and BOUY106 warns about it.

In `bench/results/node-2026-10-16-m5pro.json`, an `async *` actor method delivered 0.933 million items per second. A plain async generator delivered 12.4 million.

### 5.9 Call cycles

Each call carries a call-chain id. A call from inside a turn keeps the chain of that turn, and a call from outside any turn starts a new chain. When a call or a stream reaches an actor whose current turn has the same chain, it fails at once with `CallCycle`. Without this check, the actor would wait for itself forever. Two examples are `self(this).method()` inside a turn, and a call from actor A to actor B that calls A back.

A cast starts a new chain, so it never fails with `CallCycle`. A cast to `self(this)` runs after the current turn ends. If a method does not catch `CallCycle`, its own turn fails with `ActorFailed`, and the actor restarts.

### 5.10 Fault attribution

Each turn runs inside an `AsyncLocalStorage` context that holds the actor and its incarnation. When the actor system starts, Bouy adds `uncaughtException` and `unhandledRejection` listeners to the process. Each listener reads the context of the fault:

- If the context holds a live incarnation, the actor fails as in 5.4. If a turn is running, its caller gets `ActorFailed`.
- If the context holds no turn, or an incarnation that already stopped or restarted, Bouy logs the error and sets `process.exitCode` to 1. The process keeps running.

On Node 25.9.0, a fault from a timer, a `queueMicrotask` callback, a floating promise, or an `EventEmitter` listener that the actor triggers restarts that actor (`e2e/faults.test.ts`). An `fs` callback also keeps the context ([measurements-node E6](research/measurements-node.md)). `e2e/late-fault.test.ts` covers a fault from a stopped actor.

A listener runs in the async context of `emit()`. A throw in a listener on an emitter that another actor triggers therefore restarts the emitting actor (`e2e/faults.test.ts`). Two actors can reach one emitter only through module state, and BOUY107 warns about that.

On Bun 1.3.11, the process listeners lose the context of a `queueMicrotask`, floating-promise, or `fs` fault. Bouy treats those faults as faults with no turn: it logs them, sets exit status 1, and does not restart the actor.

Node warns that a process is not safe to resume after `uncaughtException` ([js-engines-and-isolates §3.6](research/js-engines-and-isolates.md)). Bouy resumes anyway.

### 5.11 Scheduling

All actor fibers on a thread use one Effect scheduler, `FairScheduler` (`packages/bouy/src/runtime/FairScheduler.ts`):

- It runs fiber tasks in batches on resolved-promise microtasks.
- It checks the clock between batches. When the current 4 ms slice is spent, it runs the next batch from a `setImmediate` callback, so timers and I/O run between slices. To save clock reads, it skips the check for the first 64 batches after each of these yields.
- Compiled loops use the same slice through `tick()` and `pause()` (4.1).

Each actor runs on one Effect fiber. The fiber waits for the promise of a turn through a callback that a fault can interrupt. An idle actor wakes on a marker message.

Effect's default scheduler hops through `setImmediate`. In [measurements-node E2](research/measurements-node.md), one `setImmediate` hop per scheduler pass raised the p50 of a round trip on Node from 0.167 µs to 13.4 µs. A scheduler that used only microtasks let no timer callback run during a 6.5 ms window. `FairScheduler` keeps the microtask path inside a slice and yields to the event loop between slices. ADR 0002 records this choice.

The fairness suite in `bench/results/node-2026-10-16-m5pro.json` spins one actor in a compiled loop for 2 s. Meanwhile, the main module sends a ping to another actor in each 1 ms slot. The ping p99 was 6.57 ms, and the slowest ping of a run took 8.22 ms (medians of 5 runs). The same program without the compiler gave a p99 of 1,982 ms. The 1-minute load average was 7.0 to 34.2 during those runs. On Bun 1.3.11, at a load average of 30.6 to 36.6, the compiled p99 was 45.9 ms. `e2e/fairness.test.ts` asserts that a ping every 50 ms waits less than 250 ms during a 1,000 ms loop, on all four host commands.

### 5.12 Thread actors

`spawn(Class, { isolation: "thread", thread: { stallMs, maxHeapMb } })` runs the actor in its own worker thread. The ref, the mailbox, and the supervisor stay on the main thread, so turns and restarts follow 5.1 and 5.4.

- The class must be exported from a compiled module, so that the worker can import it by its module URL and export name. Otherwise `spawn()` fails with `ActorClassInvalid`.
- The worker imports that module, so the top-level code of the module runs again in the worker. Keep the class of a thread actor in a module without side effects.
- `spawn()` returns before the worker is ready, and the first call waits for it.
- Each message crosses a `MessagePort` as a structured clone, and the receiving side decodes it with the Schema.
- A heartbeat watchdog sends a ping to the worker every `max(10, stallMs / 4)` ms. When no answer arrives for `stallMs` (default 5,000 ms), the watchdog terminates the worker, and the actor restarts. A runaway synchronous loop therefore restarts its actor and does not hang the process (`packages/bouy/test/threads.test.ts`).
- `maxHeapMb` sets the old-generation heap limit of the worker. On Node, heap exhaustion then restarts the actor. Bun 1.3.11 ignores the limit.
- A worker error or exit restarts the actor.

A thread actor differs from a default actor:

- A message that holds an actor ref fails with `NotSendable`, and the actor keeps serving.
- Cancellation does not cross to the worker, and `signal()` in the worker never aborts.
- A call to a streaming method fails with `ActorFailed`, and the actor restarts.
- An error keeps only its name, message, and stack.
- The worker runs no turn, so `self()` throws there, and compiled loops there do not yield.

### 5.13 Standard library

`bouy/std` builds on the same primitives:

- `pool(Class, size, options)` spawns `size` actors with the same options. Its methods send each call to the member with the fewest queued and running messages, and a rotation breaks ties. `pool.members` lists the refs.
- `schedule(ref, { every: ms } | { after: ms }, "method", ...args)` casts the message on a timer. It returns a `Disposable` that cancels the timer. The timer also stops when the target actor exits, or when the incarnation that created the timer ends.
- `register(name, ref)` gives an actor a name, and it throws `NameTaken` for a name in use. `lookup(name, Class)` returns the ref, or `undefined` when the name is free or belongs to another class. A name frees when its actor exits, or with `unregister(name)`.

## 6. Host support

Node is the primary host on its long-term support (LTS) lines: Node 24 now, and Node 26 when it becomes LTS on 2026-10-28. The root `package.json` declares `node >=24`. Development and every measurement used Node 25.9.0 with V8 14.1. ADR 0001 lists a rerun of the key checks on Node 24 and 26 as validation item 11. Bun 1.3.11 is the second host. Deno is not supported, because no Bouy test runs on it.

| Behavior                                                            | Node 25.9.0                                                   | Bun 1.3.11                                            |
| ------------------------------------------------------------------- | ------------------------------------------------------------- | ----------------------------------------------------- |
| Run through the CLI                                                 | `bouy run app.ts`                                             | `bun <bouy>/dist/cli.mjs run app.ts`                  |
| Run with the loader only                                            | `node --import bouy/register app.ts` (`module.registerHooks`) | `bun --preload bouy/register app.ts` (`Bun.plugin`)   |
| Compiled loops yield                                                | Yes (`e2e/fairness.test.ts`)                                  | Yes (`e2e/fairness.test.ts`)                          |
| A fault in a timer or in the actor's own emitter restarts the actor | Yes (`e2e/faults.test.ts`)                                    | Yes (`e2e/faults.test.ts`)                            |
| A `queueMicrotask` or floating-promise fault restarts the actor     | Yes (`e2e/faults.test.ts`)                                    | No. Logged with exit status 1 (`e2e/faults.test.ts`)  |
| An `fs` callback fault keeps its context                            | Yes (E6)                                                      | No (E6)                                               |
| `maxHeapMb` for a thread actor                                      | Enforced (`packages/bouy/test/threads.test.ts`)               | Ignored                                               |
| A stalled thread actor                                              | The worker stops, and the actor restarts                      | The actor restarts, and the old worker keeps spinning |
| `import.meta.main` under `bouy run`                                 | `false`                                                       | `false`                                               |
| CI                                                                  | `pnpm check` on Node 24 and 25                                | Not installed                                         |

Bun 1.4.3 stopped a spinning worker in a Linux VM research run ([js-engines-and-isolates §7](research/js-engines-and-isolates.md)). The loader hooks keep `import.meta.main` true, because they load the entry as the main module.

## 7. npm compatibility

- Bouy compiles only user source files (step 4 of section 2). npm packages load through the module loader of the host, unchanged.
- A library object, such as a zod schema or an AI SDK model, is a class instance, so it cannot cross a boundary. Create it inside the actor or at module level, and send plain data.
- Every actor on a thread uses the same module state of a package. In zod 4.6.7, `z.config({ customError })` called in one actor changes the error messages of another actor (`e2e/isolation.test.ts`).
- `e2e/npm-equivalence.test.ts` runs one scenario as plain Node code and in three actors on each of the four host commands. zod 4.6.7, ai 7.0.142, and @ai-sdk/openai 4.0.95 print byte-identical reports.

[npm-compatibility.md](npm-compatibility.md) lists the APIs that each test proves.

## 8. Known limits

Preemption and hangs:

- Bouy preempts compiled loops in async functions only. npm package code, synchronous functions, recursion, and native calls run to completion. In a default actor, a runaway call hangs every actor on the thread, and nothing stops it.
- Under `bouy run`, the SIGINT and SIGTERM listeners are JavaScript callbacks, so a runaway call blocks them too.
- Gap 1: on V8 13.6 to 15.0, some TurboFan-optimized loops ignored termination and the heap limit. These loops call no function and allocate fixed-length arrays ([js-engines-and-isolates §1.4, §1.5](research/js-engines-and-isolates.md)). Such a loop escapes the watchdog and the `maxHeapMb` limit of a thread actor.

Isolation and memory:

- Default actors on a thread use one heap, one module graph, and one set of built-in prototypes. In the research runs, prototype pollution in one actor broke `z.object()` in the other actors ([js-engines-and-isolates §8.1](research/js-engines-and-isolates.md)). BOUY103 checks module state in your own files only.
- Bouy sets no memory limit for one default actor, and heap exhaustion ends the process.
- A native addon crash ends the process. Containment in a thread actor is unverified.
- An idle actor holds 8,669 bytes of heap on Node at 100,000 actors (`bench/results/node-2026-10-16-m5pro.json`). That is 68 times a hand-written actor (128 bytes) and about 3.3 times an idle BEAM process (2,632 bytes, measured in a Linux VM, [measurements-beam-quickjs](research/measurements-beam-quickjs.md)). Commit `16b86fd` cut this cost from 15.1 KiB to 8.9 KiB in a 20,000-actor measurement. It runs each actor on one fiber and keeps `spawn` untraced.

Messages and errors:

- Delivery is at most once. A restart discards in-memory state until durable actors exist.
- Errors cross as copies, so an `instanceof` check against a library error class fails. Return library failures as data, as zod's `safeParse` does.
- A throw in a listener on an emitter that another actor triggers restarts the emitting actor (5.10).
- The copy does not detect a cyclic value. On Node 25.9.0, a call that sends one keeps the Schema decode allocating until the heap is exhausted, and the process ends. The guard in `Sendable.ts` expects a `RangeError` that the decode never raises, and no test covers this case.

Tooling:

- Under `bouy run`, `import.meta.main` is `false`, because the CLI loads the entry with `import()`. Use a loader hook for a program that checks `import.meta.main`.
- `@bouy/checker` exports its TypeScript source, and Node refuses to strip types under `node_modules`. On Node, `bouy check` therefore needs the workspace copy of `@bouy/checker` until the checker has a build step ([ADR 0002](adr/0002-language-and-runtime-split.md)).
- The `bouy` bundle is minified and has no source maps, so runtime frames in a stack trace show minified names.

The table below states each property of a default actor and a thread actor today. It repeats the current columns of the ADR 0001 table (section 4).

| Property                                                    | Default actor                                                                                                                                                                                              | Thread actor                                                                                        |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| The sender cannot change a value after it sends the value   | Yes                                                                                                                                                                                                        | Yes                                                                                                 |
| A fault restarts only its actor                             | Yes on Node 25.9.0, except a throw in an `EventEmitter` listener, which restarts the actor that called `emit()`. Faults inside streams are untested. Bun 1.3.11 loses microtask, promise, and `fs` faults. | Yes for thrown errors                                                                               |
| A fault with no owning turn is reported                     | Logged with exit status 1, and the process keeps running. A late fault from a stopped or restarted actor takes the same path.                                                                              | An uncaught fault ends the worker, and the actor restarts (untested)                                |
| Messages from one sender arrive in send order               | Yes                                                                                                                                                                                                        | Unverified across `MessagePort`                                                                     |
| Loops inside compiled `async` functions yield               | Yes                                                                                                                                                                                                        | No. The worker runs no turn, so the watchdog restarts an actor whose loop outlasts `stallMs`.       |
| Package code, synchronous functions, and native calls yield | No. A runaway call hangs every actor, and nothing stops it.                                                                                                                                                | No. The watchdog restarts the actor, except in Gap 1. On Bun 1.3.11, the old thread keeps spinning. |
| Actor refs cross                                            | Yes                                                                                                                                                                                                        | No. The call fails with `NotSendable`, and the actor keeps serving.                                 |
| Cancellation reaches the callee                             | Yes, for code that accepts an `AbortSignal`                                                                                                                                                                | No                                                                                                  |
| Streaming methods work                                      | Yes                                                                                                                                                                                                        | No. The call fails.                                                                                 |
| Memory limit                                                | None. Heap exhaustion ends the process.                                                                                                                                                                    | Opt-in on Node. Gap 1 escapes it.                                                                   |
| Package state and built-in prototypes are isolated          | No                                                                                                                                                                                                         | Yes                                                                                                 |
| A native addon crash is contained                           | No                                                                                                                                                                                                         | Unverified                                                                                          |

## 9. Next milestones

1. D1: a pool of worker-thread schedulers that run turns. A supervisor restarts a failed worker, then its actors from their specs (ADR 0001).
2. A process backstop: a parent process that kills a scheduler process stuck in a native call or a Gap 1 loop.
3. A ref wire format, cancellation, and streams across threads, so actor code can move between placements.
4. Distribution across machines on the host-neutral boundary that ADR 0001 names: spawn, send, link, and monitor. `effect/cluster` is a candidate.
5. Durable actors with journaled turns and checkpointed state, so a restart keeps state. `effect/workflow` is a candidate.
6. Effect-native actor methods.
7. Opt-in reentrancy for calls on the call chain of an actor, which fail with `CallCycle` today.
8. A TypeScript language-service plugin that shows `bouy check` diagnostics in the editor (section 10).
9. Lower memory per actor.
10. More npm packages in `e2e/npm-equivalence.test.ts`.
11. Verification runs on Node 24 and 26.

## 10. Editor support

Bouy adds no syntax. A Bouy program is TypeScript, so every editor that highlights TypeScript already highlights Bouy code, and a new grammar would add nothing. Completion, navigation, and type errors work as in any TypeScript project, because the type of a ref derives from its class. The useful editor work is a TypeScript language-service plugin that shows the `bouy check` diagnostics inline (milestone 8).
