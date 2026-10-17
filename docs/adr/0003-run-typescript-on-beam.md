# ADR 0003: Run TypeScript on BEAM

## 1. Status and context

**Status:** Accepted, 2026-10-16. The owner decided the open question: "we need to be able to use all npm packages otherwise what is the point".

This record makes two decisions:

1. Bouy compiles TypeScript to Erlang and runs it on BEAM, with no Node, no V8, and no global JavaScript event loop. This decision is already built. The record states its context and its evidence (section 2).
2. Inside each actor, JavaScript gets reference semantics: mutable objects with identity, on a heap that belongs to one BEAM process. Today Bouy gives value semantics. The owner chose reference semantics. Section 3 records the evidence and the cost, and section 6 is the plan.

This record replaces the "now" and "target" decisions of [ADR 0001](0001-execution-architecture.md), which chose Node. [ADR 0002](0002-language-and-runtime-split.md) is already superseded. When Phase 3 of section 6 ends, sections 3, 6, 7, 10, 12, 13, and 14 of [the contract](../design/beam-runtime.md) change in the same commit. [migration-plan.md](../design/migration-plan.md) already defers to this record.

The owner's words, from the amendments of [goal.md](../goal.md):

> ideally no js event loop at all we abandon for a new runtime

> no node v8 deps

> we need to be able to use all npm packages otherwise what is the point

> really good tests for these take inspiration from bun

Requirement 3 of goal.md already states the target: "Each actor is a BEAM process with its own JavaScript heap and promise queue."

Every number in this record comes from one of the sources below, and each sentence names its source. The targets in section 6 are choices of this record, not measurements.

| Key | Source                                   | Where                                                                                                                                                             | Conditions                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| --- | ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| E1  | The benchmark run of today's runtime     | `bench/results/2026-10-16-apple-m5-pro.json`                                                                                                                      | Commit `cabaaa9-dirty`, OTP 29.1.1, Node v25.9.0, Apple M5 Pro, 5 runs, 1-minute load average 10.29 to 14.32 (median 10.85). This record quotes medians. Commit `e5f6b88` later cut several of these costs, but no results file records its numbers, so this record does not quote them.                                                                                                                                                                                                                                              |
| E2  | The package census, 2026-10-16           | The report is [npm-package-census.md](../research/npm-package-census.md). The analyzer and raw output were scratch files and are not kept.                        | oxc 0.154 static analysis, and V8 block coverage under Node 25.9, of effect 4.0.5, zod 4.6.7, ai 7.0.142, @ai-sdk/openai 4.0.95, their dependencies, and `tests/migration/before`. Path codes: G is `Effect.gen` with `runPromise`. T is the Effect code of `tests/migration/before/src/reports/report-service.ts`. S is a Schema decode. A is `generateText` with one tool against `runtime/test/bouy_fake_openai.erl`. Z and J are a zod parse with and without its JIT. Le, Ls, and Lz only import effect, effect/Schema, and zod. |
| E3  | The reference-semantics prototype report | Commits `a45dc64`, `29b426a`, and `4180144` on the branch `worktree-wf_e7ab31de-84b-2`. Scripts: `bench/reference/run.sh heap` and `bench/reference/programs.sh`. | The load average stayed between 17 and 73 during the session, so every time is an upper bound. The programs ran under the debug CLI, and they time themselves, so compile time is not counted. No file in `bench/results` records these runs yet (Phase 0).                                                                                                                                                                                                                                                                           |
| E4  | The usage studies                        | [migration-plan.md §17](../design/migration-plan.md#17-sources). The data is in `/tmp/bouy-scan/` and `/tmp/effect-oracle/`.                                      | The TypeScript study: 37 repos (16 agent apps and SDKs, 8 Effect apps, 13 Node services), 41,693 production `.ts` files, 5.87M lines. The Effect study: 646 files from 500 repos that import `effect`.                                                                                                                                                                                                                                                                                                                                |

## 2. Decision 1: compile TypeScript to Erlang and run it on BEAM

### 2.1 Context

ADR 0001 chose option C: compiled TypeScript on Node or Bun, with many actors in one isolate and a later pool of worker threads. It scored option A, "TypeScript to BEAM bytecode", 1 for compatibility, because Bouy would have to rebuild JavaScript semantics. The owner then set the runtime: "ideally no js event loop at all we abandon for a new runtime", then "no node v8 deps". Commit `c5486a9` removed the Node runtime.

The BEAM implementation, by commit:

- `9de1942`: the OTP runtime. JavaScript values are Erlang terms. Each actor is a `gen_server` with a supervisor, a bounded mailbox, and call-cycle detection.
- `e1e3fc7` and `c257dd2`: the Rust compiler from TypeScript to Erlang source, and `bouy run` on one VM.
- `31648e7` and `6e5ad5b`: subsets of effect 4.0.5, ai 7.0.142, and @ai-sdk/openai 4.0.95, written again in Erlang and checked against the output of the real packages on Node.
- `8b58da7`: the benchmark harness that produced E1.
- `e5f6b88`: cheaper spawns, calls, restarts, fan-out, and startup.

### 2.2 Options

- **BEAM (chosen).** The compiler lowers each module to Erlang. Each actor is a BEAM process. The BEAM scheduler preempts it after a budget of reductions, and OTP supervises it.
- **A JavaScript engine inside BEAM.** ADR 0001 option D3n keeps each actor's state in a QuickJS-ng context behind native implemented functions (NIFs). ADR 0001 §3 records that a NIF crash ends the whole VM, and that a busy context blocks the other contexts on its thread. A Node or V8 host (D2, D3p) breaks "no node v8 deps".
- **A host outside BEAM.** ADR 0001 options B and D4 (a Rust host with QuickJS-ng, or WebAssembly components) give up the BEAM scheduler and OTP supervision. goal.md says that TypeScript runs on BEAM.

### 2.3 Evidence

E1 runs each suite as a Bouy program and as the closest plain Node program. The Node actors are objects with a queue on one event loop, and a Node message passes by reference ([bench/README.md](../../bench/README.md)).

| Suite (E1)                                                                | Metric                            | Bouy           | Node               |
| ------------------------------------------------------------------------- | --------------------------------- | -------------- | ------------------ |
| `fairness`: 8 actors run CPU-bound loops for 2 s, and the main code pings | ping p99 and maximum              | 1.0 ms, 1.0 ms | 2,000 ms, 2,000 ms |
| `fairness`                                                                | pings in the 2 s window           | 994            | 1                  |
| `spawn`: 100,000 actors                                                   | µs per actor, RSS bytes per actor | 9.52, 9,329    | 0.171, 288         |
| `call-latency`: 100,000 sequential calls                                  | mean                              | 1.71 µs        | 0.214 µs           |
| `crash-recovery`                                                          | recovery                          | 2,002 µs       | 0.79 µs            |
| `compute`: `fib(27)` in one actor                                         | time                              | 4.25 ms        | 1.48 ms            |
| `payload`: one 990-byte object per message                                | messages per second               | 480,769        | 13,097,290         |
| `startup`                                                                 | wall time                         | 199.7 ms       | 100.6 ms           |

The fairness rows are the reason for BEAM. With eight CPU-bound actors running, the worst ping took 1.0 ms on Bouy in the median run and 2.0 ms in the worst run. The single Node loop let one ping through in 2 s. Every other row costs Bouy time or memory against plain Node objects, which have no isolation, no preemption, and no supervision.

### 2.4 Decision

Bouy compiles TypeScript to Erlang and runs it on one BEAM VM. The product has no Node, V8, or Bun dependency, and no global event loop. Each actor is a BEAM process. Node runs only as the test oracle and as the benchmark baseline ([AGENTS.md](../../AGENTS.md)).

## 3. Decision 2: value semantics or reference semantics per actor

### 3.1 Context

Today every value is an immutable Erlang term ([contract §3](../design/beam-runtime.md#3-values)):

- An object is a map, and an array is a list. A mutation rebinds the variable that holds the value (§6).
- `let` compiles to single-assignment versions, and loops compile to recursive funs (§12).
- `await` blocks the process, and no promise queue exists (§7).
- A closure copies the values that it captures, so a closure that writes a captured variable is error BOUY205. Getters, `arguments`, `var`, inheritance other than errors, regular expressions, and timers are BOUY206 or BOUY207 (§10).
- `effect`, `ai`, and `@ai-sdk/openai` compile to Erlang modules that implement subsets of those packages (§13, §14).

Value semantics isolates actors by construction. No value changes in place, so a message cannot share mutable state.

### 3.2 Options

**V. Value semantics (today).** Bouy keeps the subset and grows it. The compiler rejects each construct that it cannot lower and names a rewrite. Bouy implements each library again in Erlang. migration-plan.md is this plan.

**H. Two semantics.** User code keeps value semantics, and code in `node_modules` gets reference semantics. Each call across the line converts its arguments and its result.

**R. Reference semantics per actor.** Bouy becomes a JavaScript engine built on BEAM:

- One BEAM process is one JavaScript realm. Its heap holds mutable objects with identity, prototypes, getters and setters, and symbols.
- A local variable that a closure writes lives in a heap cell. Other locals stay Erlang variables.
- Generators and async functions lower to continuation-passing Erlang closures.
- Each realm has a promise job queue. It drains the microtasks after each job, and timers arrive as BEAM messages.
- Messages between actors are structured clones.
- The heap collector runs at job boundaries, when the stack is empty. It traces roots through Erlang terms, and through fun environments with `erlang:fun_info(F, env)`.

E3 built R behind a flag:

- `bouy_heap` keeps the objects of a realm in the process dictionary under integer ids. Built-in objects live in `persistent_term`, and every realm shares them.
- `bouy_jobs` orders promise jobs as V8 does. The turns of one actor never interleave, even across `await`.
- `bouy run --semantics reference` compiles one module that imports only from "bouy".

### 3.3 Comparison

| Criterion               | V                                                                                                                   | H                                                               | R                                                                                                                                     |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Existing code and npm   | Loads none of effect, zod, ai, and @ai-sdk/openai (E2 §8). 11 probe programs print different output from Node (E4). | The packages can load. User code keeps every divergence of V.   | 27 of 27 prototype programs print what Node prints (E3). E2 found nothing in the four packages that BEAM cannot run.                  |
| Effect support          | An Erlang subset that covers 57.9% of 99,572 call sites (E4). About 14 engineer-weeks for the common surface (E4).  | The real package, with a conversion at each call from user code | The real effect 4.0.5. A first `Effect.runPromise` through it is 3 to 5 weeks away (E3).                                              |
| Migration effort        | A rewrite for each rejected construct and each aliasing shape                                                       | The rewrites of V, in user code                                 | None for language constructs. Node built-ins and web APIs still need implementations.                                                 |
| Actor guarantees        | Copies by construction. Preemption and supervision from BEAM.                                                       | Two object models in one actor                                  | Preemption and supervision from BEAM. A structured clone at each send. Only plain data crosses an actor boundary (E2 §7).             |
| Performance             | A push onto a list of 1M items did not finish in about 10 minutes (E3).                                             | The conversion cost is unmeasured.                              | Close to V on the operations that both can run. Far behind Node on both (E3).                                                         |
| Risk and remaining work | Low for each feature, but no path to requirement 2 of goal.md                                                       | Both lowerings, and a boundary whose meaning nobody has defined | About 4 to 6 engineer-months to pass effect's own tests at a usable speed (E3). The ai stack and the Node built-ins have no estimate. |
| Debuggability           | Actor state is Erlang maps. An error prints without stack frames (contract §3).                                     | Both models                                                     | Actor state is a heap of integer ids. Continuation-passing code has no JavaScript call stack (E2 §7).                                 |

**Existing code and npm.** E2 §8 counts the constructs in the four packages that BOUY205, BOUY206, and BOUY207 reject. The counts are 879 closure writes to captured variables, 669 uses of `this` outside class methods, 342 regular expression literals, 243 uses of `globalThis`, and 220 getters and setters. The list continues with 200 uses of `arguments`, 183 `extends` clauses, 102 static members, 5 async generators, and 4 `for await` loops. So the value compiler cannot load any of the four packages.

Application code has the same shapes (E4). Classes with `new` appear in 34 of the 37 repos (11,156 sites), inheritance from program classes in 32 (3,435 classes), static members in 30, getters and setters in 29, and regular expressions in 36. Closures that change captured state appear in 35, and promises, `new Promise`, or timers in 34 to 36. Aliasing shapes that value semantics changes without an error appear in 17 to 36 of the 37 repos. 11 probe programs that today's compiler accepts print different output from Node 25.9.0. [testing.md](../design/testing.md) names such silent divergence as the worst failure. H keeps it in user code.

Under R, aliasing behaves as in JavaScript. The 27 programs of `tests/reference` (E3) cover aliasing, identity keys, closure counters, inheritance, getters and setters, private fields, static members, generators, an event emitter, microtask order, timers, promise combinators, and `try` around `await`. Each prints what Node prints. E2 §6 lists the minimum engine that the four packages need:

- ES modules with live bindings and `export * as`, and a CommonJS loader for @vercel/oidc.
- Object identity, property descriptors, prototype chains, symbol keys, and `Reflect.ownKeys`.
- Classes with `#private` members, static members, computed keys, and superclasses that a call computes at load time. effect evaluates 45 such class factories at load.
- Closures that write captured variables, `this` and `new` on plain functions, `arguments`, and a correct `length`.
- Symbol, Map, Set, WeakMap, WeakSet, BigInt, 32-bit integer math, JSON, RegExp, and a writable `Error.stackTraceLimit`.
- For ai: `fetch`, `Headers`, a response body reader, `TransformStream`, `TextEncoder`, `TextDecoder`, and `URL`.

E2 §7 found no SharedArrayBuffer, Atomics, WeakRef, FinalizationRegistry, `with`, direct `eval`, `Symbol.toPrimitive`, or decorators in reachable code. Only zod uses `new Function`, for its JIT, and zod prints the same output without it.

**Effect support.** Under V, the Erlang subset covers 57.9% of the 99,572 Effect member call sites in the 9 Effect repos of the TypeScript study (E4). In the Effect study, Layer appears in 58% of the Effect 4 files, Schema in 51%, Context in 43%, Option in 24%, Fiber in 17%, Stream in 16%, and Deferred in 15%. No Effect 4 app compiles on today's subset without `Context.Service` classes with static members, `Layer` with `Effect.provide`, and `Scope`. The study estimates about 14 engineer-weeks to implement the common surface (its P0 to P2), plus the platform modules. It also names a risk: concurrent fibers can print in another order than Effect prints. Each Effect release repeats part of that work.

Under R, the real package runs. E2 lists what each path adds. Path G needs generators, and `yield*` over objects whose `[Symbol.iterator]()` returns an iterator. Path T adds `setTimeout`, `clearTimeout`, `Date.now`, and `new Error()` under `Error.stackTraceLimit = 2`. Path S needs nothing beyond loading. Without tree-shaking, an import of `effect` creates 12,708 objects and 12,556 closures (E2 §2). E3 surveyed effect 4.0.5: 519 modules, about 110k lines of code, and 4,011 import and export statements. It puts a first `Effect.runPromise` through the real package 3 to 5 weeks away, without speed work. H runs the real package too, but each Effect that user code builds must cross the conversion.

**Migration effort.** goal.md requirement 6 says that an existing codebase runs as one actor. E2 lists what the migration fixture `tests/migration/before` needs. Its language needs are 22 private fields, 5 private methods, 31 getters, one labeled `break`, one `super.x`, and a regular expression with the `s` flag. Its TypeScript needs are 3 enums, 2 namespaces, and 18 parameter properties. Its Node needs are `node:events`, `node:fs/promises`, `node:path`, `fileURLToPath(import.meta.url)`, `process` events, `process.exit`, `nextTick`, and `setInterval(...).unref()`. Under V, the getters, the labeled `break`, the `super.x`, the regular expression, the enums, and the namespaces are rewrites (contract §10), and the Erlang copies of the libraries drift from the packages. Under R, the language needs run unchanged, and the Node needs are runtime work (Phase 4).

**Actor guarantees.** V and R both run each actor as one BEAM process, so preemption and supervision do not change. Section 4 compares the guarantees one by one. Three things change under R:

- A send must walk the sender's heap, build an Erlang term, and rebuild the objects in the receiver. E2 §7 notes that Effect values, Schema class instances, and ai errors carry prototypes, symbol keys, and functions. A structured clone carries plain data only, unless the clone format names classes. Today an error keeps its class list across actors (contract §3).
- Today `Promise.all` runs each element in its own process (contract §7). Under R, the elements share one heap, so they interleave on the job queue of one process. Parallel CPU work needs actors.
- The heap lives in the process dictionary, so it ends with the process. A restart starts from a new realm. No test checks this yet (section 7).

**Performance.** E3 measured heap operations (Erlang runs 1 and 2, load about 21) and whole programs (3 runs, load 17 to 22):

| Operation (E3)                                      | R                         | V                                  | Node       |
| --------------------------------------------------- | ------------------------- | ---------------------------------- | ---------- |
| Read an own property                                | 17.8–19.4 ns              | 20.8–28.9 ns                       | 0.6–1.3 ns |
| Write an existing property                          | 46–62 ns                  | 38–44 ns (rebind)                  | 0.6–1.5 ns |
| Method call through 2 prototypes                    | 30–37 ns                  | 16–18 ns (12 direct)               | 0.7–1.6 ns |
| Allocate an object, kept live                       | 66–79 ns                  | 83–98 ns                           | 29–31 ns   |
| Increment a captured counter                        | 9.3–10.1 ns               | 2.3–2.5 ns (no closure)            | 1.7–1.8 ns |
| Push 1M objects, then sum                           | 1,295–1,359 ms            | did not finish in about 10 minutes | 29–38 ms   |
| Build 1M objects with `Array.from`, then sum        | 812–1,860 ms (median 951) | 179–218 ms                         | 56–225 ms  |
| 1M method calls that change `this`, inside an actor | 108–126 ms                | 85–94 ms                           | 1–2 ms     |
| 1M calls through a 2-level prototype chain          | 94–107 ms                 | no inheritance                     | 4 ms       |
| 1M increments of a captured counter                 | 28–37 ms                  | BOUY205                            | 1–2 ms     |
| The same loop with a pure function                  | 6–7 ms                    | 8–9 ms                             | 1 ms       |

R is faster than V on some rows and slower on others. V's largest lead is `Array.from` (179–218 ms against 812–1,860 ms). R's largest lead is `push`, because V copies the whole list on each push. Against Node, the pure-function loop takes 6 to 9 times as long on either semantics, and R's push, method, prototype, and counter loops take 14 to 126 times as long. These ratios are quotients of the E3 table. In E3's words, every property read is "a hash lookup, then a tuple, then a map", and loops over 1M objects cost 300 to 500 ns per item.

Memory and collection under R (E3):

- A live object takes 223 to 357 bytes. Node takes about 41.
- A collection pause takes 9.0–9.1 ms with 100k live objects (Node full GC: 3.3 ms), 44–53 ms with 100k live objects and 900k garbage (Node: 3.1–3.4 ms), and 114–142 ms with 1M live objects (Node: 14–16 ms).
- An actor that ran 50,000 turns of about 20 µs kept 2,008 live objects. It ran 256 collections, with a mean pause of 1.2 ms and a maximum of 3.6 ms, and its process memory stayed between 7 and 23 MB.
- An actor with an empty realm takes 4.4 to 4.6 KB of VM memory (10,000 actors). E1's 9,329 bytes per actor is RSS and includes supervisors, so E3 states that the two are not comparable.

The large cost is the state of a realm that has loaded packages. A tree-shaken realm that can run `generateText` holds 15,599 objects and 10,945 closures after load (E2 §2). At 223 to 357 bytes per object, the objects alone take 3.5 to 5.6 MB. That figure is a product of E2 and E3 numbers, not a measurement, and it leaves out the closures. If each actor is one realm, each spawn pays it. E2 §7 notes that one loaded heap shared across actors with copy-on-write needs a write barrier on each property write.

**Risk and remaining work.** E3 estimates the work to run the real effect package:

| Work (E3)                                                                                                                                                                             | Estimate      |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- |
| The ES module graph, with import cycles and live bindings                                                                                                                             | about 3 weeks |
| `yield*` (2,351 uses in 144 modules), `arguments` (847 uses in 104 modules), BigInt (36 modules), RegExp (about 65 modules), Proxy and Reflect, WeakRef, and `finally` around `await` | 6–8 weeks     |
| Built-in coverage against a test262 subset: `Object.defineProperty`, the stack-trace APIs, TextEncoder                                                                                | 6–8 weeks     |
| Speed: shapes and inline caches, to get within about 10 times V8                                                                                                                      | 1–3 months    |

The total is about 4 to 6 engineer-months to pass effect's own test suite at a usable speed (E3). The estimate covers effect only. The ai stack, the web APIs, and the Node built-ins have no estimate. E2 §7 ranks the costly parts, most costly first:

1. State per realm, as above.
2. Property reads without inline caches. Effect's run loop calls a symbol-keyed method on a prototype once per operation.
3. Mutable arrays and byte buffers. BEAM has no mutable array term. `.push()` appears 498 times in effect.
4. Numbers and strings. NaN, ±Infinity, and -0 are not Erlang floats. effect has 375 bitwise operators, and `charCodeAt` counts UTF-16 code units.
5. RegExp. PCRE2 covers the syntax that the packages use, but match indices and `lastIndex` count UTF-16 units, and 29 patterns are strings compiled at run time.
6. Stack traces, the collector (WeakMap needs ephemeron marking), and messages between actors.

E3 adds one risk from the compiler: leaving a `try` that holds an `await` needs a hand-back to the caller, so a loop inside such a `try` grows the stack until its next `await`.

**Debuggability.** No option has a JavaScript debugger on BEAM (ADR 0001 §3). Under V, `observer` and `sys:get_state/1` show actor state as Erlang maps, and an error prints without stack frames (contract §3). Under R, actor state is a set of integer ids in the process dictionary, so a person needs a heap printer to read it. E3's `bouy_ref_console` already walks the heap for `console.log`. Continuation-passing code has no JavaScript call stack (E2 §7). An `undefined` stack is cheap, and effect accepts it. An accurate stack needs a shadow stack, which adds a cost to every call.

### 3.4 Decision

Bouy adopts R: reference semantics, with one JavaScript realm in each BEAM process.

R wins on the evidence:

1. **Compatibility.** Only R can load the real packages. V cannot load effect, zod, ai, or @ai-sdk/openai (E2 §8), and goal.md requirement 2 says that every npm package works unchanged. A package is not code that a team can rewrite, so V's rewrite path does not reach it.
2. **Effect.** R runs effect 4.0.5 itself. V covers 57.9% of the call sites (E4) and must follow each release by hand.
3. **No silent divergence for aliasing.** The aliasing shapes of 17 to 36 of the 37 study repos behave as in Node under R (E4). Under V, they print different output with no error.
4. **Actor guarantees.** R keeps the process per actor, BEAM preemption, OTP supervision, and turns that never interleave (E3, `tests/reference/actor-turns.ts`).
5. **Performance against V.** On the operations that both can run, neither semantics is faster on every row of the E3 table, and R removes the linear-time `push` of V. Both trail Node by far: 1M actor method calls take 85–94 ms under V and 108–126 ms under R, against 1–2 ms on Node (E3).

H loses to R: it keeps V's silent divergence in user code, and it needs both lowerings and a conversion with no defined meaning.

What R costs:

- **An engine.** About 4 to 6 engineer-months for effect alone (E3). The ai stack, the web APIs, and the Node built-ins come on top, with no estimate yet.
- **Memory per realm.** 223 to 357 bytes per object (E3), and about 3.5 to 5.6 MB of objects for a realm that can run `generateText` (E2 and E3, by arithmetic). ADR 0004 chooses between a module instance per realm and a shared snapshot, after Phase 2 measures it.
- **Collection pauses.** 114 to 142 ms with 1M live objects (E3). The collector runs only at job boundaries, so one long synchronous job, such as a large `JSON.parse`, grows the heap (E2 §7).
- **Speed.** The E3 push, method, prototype, and counter loops take 14 to 126 times as long as on Node. Shapes and inline caches take 1 to 3 months (E3).
- **Messages.** Only plain data crosses an actor boundary, unless the clone format names classes.
- **Parallel `Promise.all`.** It becomes concurrency inside one process.
- **Stacks.** No JavaScript call stack without a shadow stack.

## 4. Actor guarantees

| Property                                          | V, today                                                 | R, prototype (E3)                                           | R, target                                             |
| ------------------------------------------------- | -------------------------------------------------------- | ----------------------------------------------------------- | ----------------------------------------------------- |
| The sender cannot change a value after sending it | Yes: Erlang terms do not change                          | Yes: a structured clone                                     | Yes                                                   |
| The turns of one actor never interleave           | Yes: `await` blocks the process                          | Yes, also across `await` (`tests/reference/actor-turns.ts`) | Yes                                                   |
| A loop in one actor cannot starve the others      | Yes: fairness p99 1.0 ms (E1)                            | Expected, because the code is Erlang. Unmeasured.           | The fairness suite under R stays at or below E1's p99 |
| Package code yields                               | No package code runs                                     | Yes, it compiles to Erlang too                              | Yes                                                   |
| The collector cannot stall other actors           | BEAM collects each process on its own                    | Expected: `bouy_heap` is Erlang code. Unmeasured.           | Measured under load                                   |
| A fault restarts only its actor                   | Yes (`tests/programs`)                                   | Untested                                                    | Yes, with a new realm                                 |
| Class instances keep their class across actors    | Errors only: an error keeps its class list (contract §3) | No: plain data only                                         | The clone format of Phase 3 decides                   |
| `Promise.all` runs its elements in parallel       | Yes: one process each (contract §7)                      | No: one job queue                                           | No; parallel work uses actors                         |
| A memory limit stops one actor                    | Unverified                                               | Unverified                                                  | `max_heap_size` ends a runaway realm, with a test     |

## 5. Consequences

Easy:

- Existing TypeScript and npm packages run unchanged as the engine grows. Each package's own tests become Bouy tests (testing.md §5.8).
- One implementation of effect and ai exists: the packages. The Erlang modules `bouy_effect`, `bouy_schedule`, `bouy_schema`, `bouy_effect_console`, `bouy_duration`, `bouy_ai`, and `bouy_ai_openai` go away in Phases 2 and 3.
- The compiler front end, the CLI, the actor runtime, supervision, mailboxes, and the benchmark harness stay.
- Diagnostics BOUY205 to BOUY207 shrink to the features that Bouy has not built yet, as goal.md requirement 6 asks.

Hard:

- Bouy owns ECMAScript conformance. Each new edition is Bouy's work (ADR 0001 §3).
- The contract changes at sections 3, 6, 7, 10, 12, 13, and 14 when the default changes (Phase 3). Until then, two lowerings exist, and CI runs both.
- Phases 2 to 4 of migration-plan.md stop. They guard value semantics, which R replaces. Its Phase 1 diagnostics stay useful for the features that are not built yet.
- The census and the usage studies live in `/tmp`. Phase 0 moves them into the repository before a later document cites them.
- Memory per realm, collection pauses, speed, plain-data messages, and missing stacks, as section 3.4 lists.

The documentation must state:

- Every "No", "Untested", and "Unverified" cell of section 4.
- Only plain data crosses an actor boundary until the clone format names classes.
- `Promise.all` inside one actor is concurrent in one process. Parallel work needs actors.
- `error.stack` is `undefined` until a shadow stack exists.

## 6. Plan

Three numbers measure each phase. [testing.md](../design/testing.md) defines each one:

- **T, test262:** the pass rate of the group that predicts npm success, ES5 to ES2022 without `intl402`, `staging`, and proposals (testing.md §5.5). Silent failures count apart.
- **N, Node's own tests:** passing files over all files at the tag of `.node-version`, for each module, and the share of the documented API surface that exists (testing.md §5.7).
- **P, the top npm packages:** the exports and main programs of `tests/packages` in tier order (the AI tier, the top 150, then the top 500), and the package suites (testing.md §5.8).

The percentages below are targets of this record. Every phase keeps `pnpm check` green, and no tier may regress. Phases 1 and 2 overlap. Phase 5 starts when Phase 2 ends, because it changes the object layout that later phases build on.

| Phase                                   | Work                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Estimate (E3)                                                                                                                                                      | Exit criteria                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0. Land the prototype                   | Review and merge `a45dc64`, `29b426a`, and `4180144`. Run `bench/reference/programs.sh 5` and `bench/reference/run.sh heap` on an idle machine, and record the output in `bench/results`. The census report is in `docs/research/npm-package-census.md`; copy the two usage study reports into `docs/research/`. Build phases 0 to 3 of testing.md §11 for `--semantics reference`.                                                                                                                                                                                                                                                                                                                                                                             | none                                                                                                                                                               | `tests/reference` passes in CI. A results file holds the E3 programs with their load averages. `docs/COMPAT.md` shows a baseline for T, N, and P.                                                                                                                                                                                                                                                                                                                                                                            |
| 1. Language core                        | The module graph from `node_modules`, with cycles, live bindings, `export * as`, and a CommonJS loader. One module instance per realm. `var`, `arguments`, `this` and `new` on plain functions, `call`, `apply`, `bind`, and `length`. Property descriptors, accessors, prototype chains, symbols, and `Reflect`. Classes with `#private`, static members, computed keys, `super`, and superclasses computed at run time. Generators, `yield*` over custom iterables, async generators, `for await`, and labels. JavaScript numbers (NaN, ±Infinity, -0), int32 math, BigInt, UTF-16 strings, RegExp on PCRE2 with UTF-16 indexes and a run-time pattern translator, WeakMap, WeakSet, and `Error.stackTraceLimit`. test262 in the VM (testing.md §11 phase 8). | The module graph: about 3 weeks. `yield*`, `arguments`, BigInt, RegExp, Proxy, WeakRef, `finally` around `await`: 6–8 weeks. Built-ins against test262: 6–8 weeks. | `harness/assert.js` and `sta.js` compile, so test262 runs code. T is at least 60%. P: the E2 probes Le, Ls, and Lz load, so the exports programs of effect and zod pass. The E2 paths S, Z, and J print what Node prints.                                                                                                                                                                                                                                                                                                    |
| 2. The real effect                      | `setTimeout`, `clearTimeout`, and `Date.now` on the job queue. `tests/equivalence/effect` against effect 4.0.5 from `node_modules`. Delete the Erlang Effect modules. Measure the spawn time and memory of an actor whose realm loaded effect, and write ADR 0004 on the realm model.                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | A first `Effect.runPromise`: 3–5 weeks, without speed work                                                                                                         | The E2 paths G and T print what Node prints. Every program of `tests/equivalence/effect` passes with the real package. effect's own test suite has an expectation file, and P for it is at least 50%. T is at least 75%. A results file records the realm measurement, and ADR 0004 is accepted.                                                                                                                                                                                                                             |
| 3. ai, the web surface, and the default | `fetch` on OTP `httpc`, `Headers`, the response body reader, `ReadableStream`, `TransformStream` as a superclass, `TextEncoder`, `TextDecoder`, `URL`, and `AbortController`. The `browser` export condition for @vercel/oidc, and a `process.release.name` that is not `"node"` (E2 §7). The structured clone format for messages. Then R becomes the only lowering.                                                                                                                                                                                                                                                                                                                                                                                           | none                                                                                                                                                               | The E2 path A prints what Node prints with the real ai 7.0.142 and @ai-sdk/openai 4.0.95. Every program of `tests/equivalence/ai` passes with the real packages, and the Erlang AI modules are deleted. Every program of `tests/conformance` and `tests/programs` passes under R. One commit deletes the value lowering and `--semantics`, and rewrites the contract. The WPT areas `url`, `encoding`, and `streams` have rows in `docs/COMPAT.md`. P for the AI tier's exports programs is at least 80%. T is at least 85%. |
| 4. Node built-ins and the fixture       | `node:events`, `node:fs/promises`, `node:path`, `node:url`, `process` events and `exit`, `exitCode`, `nextTick`, `argv`, and `env`, `setInterval(...).unref()`, and Node's exit rule. TypeScript enums, namespaces, and parameter properties.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | none                                                                                                                                                               | `tests/migration/before` runs unchanged and prints `expected.stdout`. N: a file with only `require('../common')` exits with 0, and `events`, `path`, `url`, `timers`, and `process` each pass at least 90% of their files and have 100% of their documented surface. P for the top 150 exports programs is at least 70%.                                                                                                                                                                                                     |
| 5. Speed and memory                     | Shapes with slot tuples, and inline caches in the generated code. Chunked tuples for arrays. Collection inside long jobs, a generational or incremental collector, and weak WeakMap keys.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Shapes and inline caches: 1–3 months                                                                                                                               | A results file shows each `bench/reference` program within 10 times Node. The fairness suite under R has a p99 at or below 1.0 ms, as in E1. The longest pause of `bench/reference/programs/actor-gc.ts` is at or below E3's 3.6 ms. T, N, and P do not fall.                                                                                                                                                                                                                                                                |
| 6. Complete coverage                    | The rest of the Node built-ins, the WPT areas of testing.md §5.6, the fuzzing campaign, the package suites, and a decision on the shadow stack.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | none                                                                                                                                                               | N is 100% on both numbers for every module, apart from the named `never` entries (goal.md requirement 7). T is at least 99%, with no silent failures. P for the top 500 exports programs is at least 95%, and each first suite of testing.md §5.8d passes the tests that pass on Node.                                                                                                                                                                                                                                       |

Phase 2 ends with an estimate for Phases 3 and 4, and Phase 4 ends with one for Phase 6.

## 7. Validation

| #   | Concern                     | Existing test or benchmark                                                                                                             | To add                                                                                      |
| --- | --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| 1   | JavaScript semantics        | `tests/reference` (27 programs) and `crates/bouy-cli/tests/reference.rs`; `runtime/test/bouy_heap_tests.erl` and `bouy_jobs_tests.erl` | test262, and every program of `tests/conformance` under R                                   |
| 2   | Fault isolation             | `tests/programs`, under V                                                                                                              | The same programs under R. A restarted actor has a new realm.                               |
| 3   | State isolation             | `tests/reference/actor-state.ts`                                                                                                       | A sender changes an object after the send, and the receiver keeps the old copy.             |
| 4   | Preemption                  | The `fairness` suite, under V (E1)                                                                                                     | The `fairness` suite under R. A ping during a collection of 1M objects in another actor.    |
| 5   | Turn order                  | `tests/reference/actor-turns.ts`                                                                                                       | None                                                                                        |
| 6   | Message copies              | The `payload` suite, under V (E1)                                                                                                      | The `payload` suite under R. Clones of class instances, symbol keys, and functions.         |
| 7   | Memory per actor            | The `spawn` suite (E1); `bench/reference/programs/realm-memory.ts` (E3)                                                                | `spawn` under R, with an empty realm and with effect loaded                                 |
| 8   | Collector                   | `bench/reference/programs/actor-gc.ts` (E3)                                                                                            | A soak test of one agent actor with a memory ceiling. `max_heap_size` ends a runaway realm. |
| 9   | npm, Node, and the language | None under R                                                                                                                           | T, N, and P in `docs/COMPAT.md`, as section 6 sets                                          |

The decision fails if Phase 2 cannot pass `tests/equivalence/effect` with the real effect package, or if a "Yes" of the target column in section 4 cannot hold under R.

## 8. Revisit triggers

1. Phase 5 ends, and a `bench/reference` program still takes more than 10 times as long as Node. Record the profile, and decide on the object representation in a new ADR.
2. Phase 2 measures the realm. ADR 0004 picks a module instance per realm or a shared snapshot, and states the spawn cost of an agent actor.
3. The `fairness` suite under R shows a p99 above E1's 1.0 ms. Find the code that does not yield, such as a built-in function on a large term.
4. A package of the AI tier fails without `new Function` or `eval`. E2 found only zod's JIT, which has a fallback. Add a path that compiles code at run time.

## 9. References

- [goal.md](../goal.md), [AGENTS.md](../../AGENTS.md)
- [ADR 0001](0001-execution-architecture.md), [ADR 0002](0002-language-and-runtime-split.md)
- [beam-runtime.md](../design/beam-runtime.md): the contract
- [testing.md](../design/testing.md): the tiers and the dashboard behind T, N, and P
- [migration-plan.md](../design/migration-plan.md): the usage studies (E4) and the value-semantics plan that this record stops
- [bench/README.md](../../bench/README.md), and the output in `bench/results/2026-10-16-apple-m5-pro.json` (E1)
- The prototype (E3): `git show a45dc64 29b426a 4180144`, on the branch `worktree-wf_e7ab31de-84b-2`
- The census (E2): [npm-package-census.md](../research/npm-package-census.md)
- Commits since `c5486a9`: `git log c5486a9..main`
