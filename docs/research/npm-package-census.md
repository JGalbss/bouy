# Census: what the real npm packages need from a JavaScript engine

Recorded 2026-10-16 by the reference-semantics spike (ADR 0003, evidence E2). It covers effect 4.0.5, ai 7.0.142, @ai-sdk/openai 4.0.95 and their dependencies, zod 4.6.7, and `tests/migration/before`. The analyzer, probes, and raw outputs lived in `/tmp/bouy-census` on the machine that ran the spike and are not kept; this note keeps the report.

**Bottom line:** the real packages need a nearly complete ES2022 engine plus a small web surface. Nothing they use is impossible on BEAM. The biggest cost is state per realm. After tree-shaking, a realm that can run `generateText` still holds 15.6K objects and 10.9K closures once its modules load (V8 heap snapshot). If one actor is one realm, every actor pays that cost when it spawns.

Everything is in `/tmp/bouy-census`. The repo is unchanged.

- **Analyzer:** `analyzer/` is a Rust tool on oxc 0.154, built with `cargo build --offline` and the 1.98 toolchain. Binary: `analyzer/target/release/census`.
- **Probes:** `paths/*.mjs`. Coverage data is in `cov/` and tree-shaken bundles are in `bundles/`.
- **Results:** in `out/`:
  - `static-*.json|tsv` and `cov-*.json|tsv` list every occurrence with file:line:col and whether it ran.
  - `table-syntax.md`, `table-globals.md` and `examples.txt` hold the tables below.
- **Measurement scripts:** in `measure/`:
  - `load-cost.mjs` counts heap objects.
  - `jobs-origin.mjs` attributes promises to packages.
  - `drop-global.mjs` and `drop-test.sh` delete a global and rerun.
  - `trace-*.mjs` record call sites.
  - `bundle*.mjs` tree-shake with rolldown.

### 1. Method

1. **Static:** the analyzer follows imports, `export … from`, literal `import()` and literal `require()` from each entry, using the `import`/`default` conditions. It parses every module with oxc and runs semantic analysis. A global is an unresolved value reference. Member names such as `.push()` are counted by name only.
2. **Execution:** each probe ran under Node 25.9 with V8 block coverage.
   - Marks on functions, methods, getters and generators are exact.
   - Marks on single statements can be false after an early `return`. This happened once: `new Proxy` at `ai/dist/index.js:782`. Tracing showed that no package code builds a Proxy on any core path.
3. **Hard requirements:** each probe ran again with one global deleted. A global counts as required only when the error frame is in package code. Node's own fetch (undici) also reads some globals, and those failures are excluded.
4. **Tree-shaking:** rolldown 1.2.14 (the repo's copy) bundled each probe, and the analyzer then counted the bundle.

Codes in the "ran on" columns refer to library code only, not to the probe code:

- `Le` / `Ls` / `La` / `Lz`: import only of effect, effect/Schema, ai + @ai-sdk/openai, zod.
- `G`: `Effect.gen` + `runPromise`.
- `T`: the Effect code of `tests/migration/before/src/reports/report-service.ts`, as plain JavaScript (services, layers, retry, timeout, Schema, tagged errors).
- `S`: `Schema.decodeUnknownSync` on a Struct.
- `A`: `generateText` with one `jsonSchema` tool, `openai.chat(...)` and `stepCountIs(3)`, against `runtime/test/bouy_fake_openai.erl` (2 HTTP calls).
- `Z` / `J`: a zod object parse with the JIT / with `jitless`.

### 2. Size and what runs

| package                             | version |             modules |            lines |      code lines | format           |
| ----------------------------------- | ------- | ------------------: | ---------------: | --------------: | ---------------- |
| effect (`effect` / `effect/Schema`) | 4.0.5   |           221 / 117 | 158,160 / 89,457 | 52,369 / 27,979 | ESM              |
| zod                                 | 4.6.7   | 95 (64 are locales) |           20,072 |          18,824 | ESM              |
| ai                                  | 7.0.142 |                   2 |           21,028 |          18,659 | ESM              |
| @ai-sdk/openai                      | 4.0.95  |                   1 |           10,316 |           9,566 | ESM              |
| @ai-sdk/provider-utils              | 5.0.61  |                   1 |            4,685 |           3,666 | ESM              |
| @ai-sdk/gateway (imported by ai)    | 4.0.115 |                   1 |            3,362 |           3,010 | ESM              |
| @ai-sdk/provider                    | 4.0.28  |                   1 |              428 |             329 | ESM              |
| eventsource-parser                  | 3.1.1   |                   2 |              207 |             205 | ESM              |
| @vercel/oidc (imported by gateway)  | 3.2.0   |                  10 |              751 |             725 | CommonJS         |
| @workflow/serde                     | 4.1.0   |                   1 |               30 |               2 | ESM              |
| @standard-schema/spec               | 1.1.0   |                   0 |                  |                 | type-only import |
| tests/migration/before              |         |                  22 |            2,212 |           1,878 | TypeScript       |

Reachable modules per entry:

- `ai`: 114 modules, 45,423 code lines (96 of them zod, 10 of them @vercel/oidc).
- `@ai-sdk/openai`: 102 modules, 32,595 code lines.
- The migration app: 358 modules, 109,236 code lines.

| path | functions reachable | functions run | tree-shaken lines (code) | tree-shaken functions | V8 objects + closures retained |
| ---- | ------------------: | ------------: | -----------------------: | --------------------: | -----------------------------: |
| G    |              10,162 |    474 (4.7%) |            3,013 (1,328) |                   241 |                      191 + 538 |
| T    |              10,162 |    837 (8.2%) |           13,451 (5,641) |                 1,184 |                  2,930 + 4,339 |
| S    |               5,274 |    395 (7.5%) |            9,034 (4,282) |                   795 |                  2,451 + 3,345 |
| A    |               4,679 |   532 (11.4%) |          29,023 (26,709) |                 2,496 |    15,599 + 10,945 (load only) |
| Z    |               1,736 |    156 (9.0%) |            5,169 (4,963) |                   806 |                  1,271 + 2,330 |

Without tree-shaking, one import creates these objects + closures:

| import              | objects + closures |
| ------------------- | -----------------: |
| effect              |    12,708 + 12,556 |
| effect/Schema       |      7,712 + 8,556 |
| ai + @ai-sdk/openai |    18,257 + 12,989 |
| zod                 |      2,125 + 2,271 |

Most of ai's load cost is zod schemas that ai and @ai-sdk/openai build at module top level. That is why tree-shaking barely shrinks it.

Promises created by package code on each path:

| path         | promises | split                                                                      |
| ------------ | -------: | -------------------------------------------------------------------------- |
| A (one call) |      467 | ai 319, provider-utils 135, openai 10, zod 3; 119 more inside Node's fetch |
| T            |        6 |                                                                            |
| G            |        2 |                                                                            |

### 3. Constructs per package (static counts, reachable code)

`p-utils` = @ai-sdk/provider-utils, `esp` = eventsource-parser, `oidc` = @vercel/oidc.

| construct                                | effect | zod |  ai | openai | p-utils | gateway | provider | esp | oidc |        app | ran on                  |
| ---------------------------------------- | -----: | --: | --: | -----: | ------: | ------: | -------: | --: | ---: | ---------: | ----------------------- |
| class decl+expr                          |    163 |  11 |  60 |     14 |       5 |      24 |       17 |   2 |    3 |         22 | Le Ls La Lz G T S A Z J |
| class created inside a function          |      8 |   1 |     |        |         |         |          |     |      |            | Le Ls La Lz G T S A Z J |
| extends (any)                            |    111 |   6 |  31 |        |       2 |      11 |       17 |   2 |    3 |         14 | Le Ls La Lz G T S A Z J |
| extends a call (mixin/factory)           |     45 |     |     |        |         |         |          |     |      |          5 | Le Ls G T S             |
| extends Error                            |      1 |   5 |   1 |        |         |       1 |        1 |   1 |    3 |          1 | all                     |
| extends TransformStream                  |        |     |   1 |        |         |         |          |   1 |      |            | La A                    |
| super()                                  |     53 |   5 |  31 |        |       2 |      11 |       17 |   2 |    3 |          8 | Le Ls G T S             |
| class getter/setter                      |     54 |   9 |  87 |     16 |       2 |       8 |          |     |      |         31 | Le La G T S A Z J       |
| object-literal getter/setter             |     13 |  14 |  16 |        |       1 |         |          |     |      |          2 | G T S A Z J             |
| defineProperty with get/set              |      3 |  11 |     |        |         |         |          |     |      |            | all                     |
| static method/field                      |     17 |     |  25 |     19 |       2 |      20 |       19 |     |      |         15 | Le G T                  |
| #private field/method                    |     10 |     |     |        |         |         |          |     |      |         31 | Le Ls G T S             |
| computed keys                            |    372 |   3 |   8 |     59 |       5 |       8 |          |     |      |          2 | Le Ls G T S A           |
| `[Symbol.iterator]()` methods            |     46 |     |     |        |         |         |          |     |      |          2 | G T                     |
| generator functions                      |    183 |   1 |     |        |         |         |          |     |      |          5 | T (plus user code on G) |
| yield / yield*                           |    487 |   1 |     |      1 |      11 |       1 |          |     |      |         12 | T A                     |
| async functions                          |      4 |  16 | 306 |     51 |      42 |      46 |          |     |    7 |         23 | A                       |
| await                                    |      6 |  13 | 531 |    115 |      62 |     127 |          |     |   15 |         21 | A                       |
| async generators                         |        |     |     |      1 |       3 |       1 |          |     |      |            | A                       |
| for await                                |        |     |   1 |      1 |       1 |       1 |          |     |      |            | A (traced)              |
| spread                                   |    671 | 300 | 493 |    237 |     108 |     106 |          |     |    1 |         16 | all                     |
| rest                                     |    184 |  68 |  46 |      1 |      13 |       5 |          |     |      |            | all but Lz              |
| destructuring                            |    555 |  39 | 443 |    122 |     100 |      71 |       19 |   2 |    4 |         16 | all but Lz              |
| optional chaining                        |    537 | 169 | 521 |    290 |      60 |      22 |        9 |     |    9 |          4 | all                     |
| `??` / logical assignment                |    421 | 654 | 442 |    224 |      34 |      78 |          |     |    4 |         21 | all                     |
| labeled statements / labeled jumps       |  3 / 4 |     |     |        |         |         |          |     |      |      1 / 1 |                         |
| regex literals                           |    142 | 119 |  25 |     12 |      32 |       9 |          |   1 |    2 |         12 | all                     |
| `new RegExp(string built at run time)`   |      2 |  22 |   1 |        |       4 |         |          |     |      |            | Le La Lz G T A Z J      |
| tagged templates                         |     48 |     |     |        |         |         |          |     |      |            |                         |
| BigInt literal                           |        |     |     |        |         |         |          |     |      |            |                         |
| closure writes captured variable         |    502 |  38 | 214 |     54 |      15 |      14 |          |  41 |    1 |         10 | Le La G T S A Z J       |
| captured + mutated variables             |    425 |  29 | 162 |     33 |      16 |      10 |          |   8 |    1 |          9 | all                     |
| module-level mutable bindings            |      7 |   7 |   2 |        |       2 |         |          |     |    1 |            | all                     |
| `this` in plain function                 |     57 |  15 |   1 |        |         |         |          |     |      |            | all but Lz              |
| `this` in object-literal method          |    422 | 173 |   1 |        |         |         |          |     |      |            | all but Lz              |
| `X.prototype =` / `X.prototype.y =`      |     19 |   1 |     |        |         |         |          |     |      |            | all                     |
| `arguments`                              |    200 |     |     |        |         |         |          |     |      |            | Le Ls G T S             |
| int32 bitwise operators                  |    375 |   2 |     |        |      26 |         |          |     |      |            | Le Ls G T S A           |
| new.target                               |        |     |     |      1 |         |       1 |          |     |      |            |                         |
| dynamic `import()`                       |        |     |     |        |         |         |          |     |    2 |            |                         |
| var                                      |        |  19 |  64 |     14 |       5 |      24 |       17 |     |  125 |            | La Lz A Z J             |
| instanceof                               |     47 |  76 |  62 |      4 |      25 |      10 |        1 |     |    4 |          5 | La A Z J                |
| with / direct eval                       |        |     |     |        |         |         |          |     |      |            |                         |
| `Function` (zod: `const F = Function`)   |        |   3 |   2 |        |         |         |          |     |      |            | La A Z (traced)         |
| TS enum / namespace / parameter property |        |     |     |        |         |         |          |     |      | 3 / 2 / 18 |                         |

### 4. Globals and host APIs per package

| API                                                           | effect | zod |  ai | openai | p-utils | gateway | provider | esp | oidc | app | ran on                  |
| ------------------------------------------------------------- | -----: | --: | --: | -----: | ------: | ------: | -------: | --: | ---: | --: | ----------------------- |
| Proxy                                                         |      4 |   1 |  12 |        |         |         |          |     |      |     | none (traced)           |
| Reflect.*                                                     |     22 |  23 |     |        |         |         |          |     |      |     | all but Lz              |
| Symbol(), Symbol.for                                          |     22 |  10 |  30 |        |       7 |      11 |       18 |     |    1 |     | all                     |
| Symbol.iterator / asyncIterator                               |    111 |   1 |   2 |        |       1 |         |          |     |      |   2 | G T A                   |
| Symbol.hasInstance / toStringTag / dispose                    |      4 |   2 |   1 |        |         |         |          |     |      |     | La Lz A Z J             |
| Symbol.toPrimitive                                            |        |     |     |        |         |         |          |     |      |     |                         |
| defineProperty(ies) / getOwnPropertyDescriptor(s)             |     44 | 104 |   5 |        |       4 |         |          |     |   20 |     | all                     |
| Object.create / get- and setPrototypeOf                       |    239 |  20 |  22 |        |       2 |         |          |     |    8 |     | all but Lz              |
| WeakMap / WeakSet                                             |     36 |  10 |   2 |        |         |         |          |     |      |     | all                     |
| WeakRef / FinalizationRegistry                                |        |     |     |        |         |         |          |     |      |     |                         |
| globalThis                                                    |    199 |   5 |  21 |        |      16 |       1 |          |     |    1 |     | all                     |
| BigInt()                                                      |    168 |  12 |   2 |        |         |         |          |     |      |     | all                     |
| ArrayBuffer / DataView / typed arrays                         |    109 |   2 |  19 |        |       5 |       1 |          |     |      |     | Le Ls G T S A           |
| SharedArrayBuffer / Atomics                                   |        |     |     |        |         |         |          |     |      |     |                         |
| Error.captureStackTrace / stackTraceLimit / prepareStackTrace |      2 |   1 |     |        |       5 |         |          |     |      |     | all                     |
| Intl / structuredClone                                        |      6 |     |   6 |        |         |         |          |     |      |     |                         |
| fetch / Headers / Response                                    |        |     |  11 |      1 |      13 |         |          |     |    6 |     | A                       |
| ReadableStream / TransformStream / Text*Stream                |      1 |     |  89 |      8 |       7 |       3 |          |   1 |      |     | La A                    |
| TextEncoder / TextDecoder                                     |     19 |     |   7 |        |       5 |       2 |          |     |      |     | Le Ls La G T S A        |
| URL / URLSearchParams                                         |     19 |  10 |  33 |      6 |      11 |      15 |          |     |    1 |     | La A                    |
| FormData / Blob / File                                        |      3 |     |     |     14 |       2 |         |          |     |      |     |                         |
| AbortController / AbortSignal.any,timeout                     |      2 |     |  17 |        |         |         |          |     |      |     | none (traced)           |
| crypto.*                                                      |      2 |     |   5 |        |         |         |          |     |      |     |                         |
| setTimeout / clearTimeout                                     |      4 |     |  28 |      2 |       2 |         |          |     |      |   5 | T                       |
| setInterval / setImmediate / queueMicrotask                   |      3 |     |     |        |         |         |          |     |      |   2 |                         |
| performance.now / Date / Math.random                          |     34 |   4 |  22 |     13 |       3 |      10 |          |     |    3 |   2 | T A                     |
| process.*                                                     |      3 |     |   4 |        |       7 |         |          |     |   15 |  10 | Le Ls La G T S A        |
| Buffer / atob / btoa                                          |        |   4 |   2 |        |       1 |       4 |          |     |    1 |     |                         |
| browser-only (navigator, document, WebSocket, RTC, Audio)     |        |   1 |  12 |        |         |       1 |          |     |      |     | La A Z (feature checks) |
| require / module.exports                                      |        |     |     |        |         |         |          |     |   43 |     | La A                    |

### 5. Example locations

**Classes and functions**

- Superclass computed at load: `effect/dist/Schema.js:367` (`class SchemaError extends Data.TaggedError("SchemaError")`), `app/src/reports/report-service.ts:19`.
- Class built inside a function: `effect/dist/Data.js:76`, `zod/v4/core/core.js:91`.
- Constructor function using `this`: `effect/dist/internal/effect.js:1020` (`ContImpl`). Prototype assignment: `effect/dist/Effectable.js:34`.
- `arguments` with `body.apply(this, arguments)`: `effect/dist/Function.js:69` (`dual`).
- Function `length` decides behavior: `effect/dist/internal/effect.js:851` (`register.length >= 2`) and `:1373` (`f.length !== 1`). It is redefined at `:876`.

**Runtime dispatch, generators and async**

- Run loop: `effect/dist/internal/effect.js:453` (`current[evaluate](this)`). A write to `globalThis[symbol]` happens at `:432`.
- Async generator + `for await`: `@ai-sdk/provider-utils/dist/index.js:4654` (`executeTool`), `ai/dist/index.js:3232`.

**Accessors, symbols and Proxy**

- Accessor defined with `defineProperty`: `zod/v4/classic/schemas.js:1165`. `Symbol.hasInstance`: `zod/v4/core/core.js:112`.
- Proxy: `ai/dist/index.js:782` (v3→v4 model adapter; @ai-sdk/openai 4.0.95 models are already v4), `effect/dist/Data.js:150` (`taggedEnum`), `effect/dist/Equal.js:322`, `zod/v4/core/util.js:357`.

**Code generation and stacks**

- Function constructor: `zod/v4/core/util.js:228` (a probe in try/catch), `doc.js:33`, `compile.js:180`.
- Stacks:
  - `effect/dist/internal/effect.js:889-890`: `stackTraceLimit = 2` and `new Error()` on every `Effect.fn` call.
  - `provider-utils/dist/index.js:2152`: `stackTraceLimit = 0` around `JSON.parse`.
  - `provider-utils/dist/index.js:1365`: `prepareStackTrace` CallSites, Node-only path.
  - `zod/v4/core/util.js:214`: `captureStackTrace`.

**Bytes and streams**

- Byte buffers: `effect/dist/Hash.js:268` (DataView over `ArrayBuffer(8)` for hashing floats), `provider-utils/dist/index.js:1635-1656` (body reader and `Uint8Array.set`).
- TransformStream as a superclass at load: `eventsource-parser/dist/stream.js:3`, `ai/dist/index.js:6222`.
- `z.instanceof(Uint8Array | ArrayBuffer | URL)` at load: `ai/dist/index.js:2144-2166`.

**Regex**

- Lookbehind: `effect/dist/ConfigProvider.js:861`. Backreference: `:841`.
- `\p{…}`: `ai/dist/index.js:3146`, `provider-utils/dist/index.js:2406`, `effect/dist/net/NetAddress.js:586`.
- Pattern built from a string: `zod/v4/classic/from-json-schema.js:546`.

**Other syntax**

- Labeled loops: `effect/dist/Array.js:3733`, `Equal.js:182`, `SchemaAST.js:3104`, `app/src/queue.ts:152`.
- `new.target`: `@ai-sdk/openai/dist/index.js:10244`.
- Tagged template: `effect/dist/persistence/Persistence.js:222` (`sql`…``), reachable from the main entry.

**CommonJS and Node detection**

- `require` at `@vercel/oidc/dist/index.js:29`, imported by name at `@ai-sdk/gateway/dist/index.js:4`.
- The Node build calls `os.platform()` and `os.hostname()` and reads `process.version` at load: `@vercel/oidc/dist/oauth.js:28`.
- Node detection: `ai/dist/index.js:4359`, `provider-utils/dist/index.js:1341`.

### 6. Minimum engine

**Language core that loading any of the four needs**

1. **Modules:** ESM with live bindings and `export * as` (effect's index has 139). A CommonJS loader with named-export interop for @vercel/oidc (ai only).
2. **Object model:** object identity, insertion-ordered keys, property descriptors and accessors, prototype chains (`Object.create`, `setPrototypeOf`, `X.prototype =`), symbol keys, `Reflect.ownKeys`, `in` through prototypes.
3. **Classes:** fields, `#private`, static members, getters, computed keys including symbols, `super()`. `extends` must accept a superclass computed at run time: effect's load evaluates 45 such class factories.
4. **Functions:** closures that write captured variables, `this` and `new` on plain functions, `arguments`, `call`/`apply`/`bind`, and correct `length`.
5. **Built-ins:**
   - Symbol (`Symbol()`, `Symbol.for`, `iterator`, `hasInstance`, `toStringTag`), Map, Set, WeakMap, WeakSet.
   - BigInt (58 call sites run at effect load), int32 bitwise math, JSON.
   - RegExp: literals are compiled at load (effect 39, the ai stack 70, zod 49), and zod builds some patterns from strings at load.
   - Error with a writable `stackTraceLimit`.

**Globals that loading needs** (deleting each one breaks the import inside package code)

- **effect and effect/Schema:** Symbol, Reflect, WeakMap, WeakSet, BigInt, ArrayBuffer, DataView, Uint8Array, TextEncoder, TextDecoder.
- **ai + @ai-sdk/openai:** Symbol, Reflect, WeakMap, WeakSet, BigInt, ArrayBuffer, Uint8Array, TextEncoder, TextDecoder, URL, TransformStream.
  - With the `import` condition, @vercel/oidc's Node build also needs `process` and `node:os` at load.
  - The `browser` condition build needs neither. The tree-shaken `generateText` run passed with `process` deleted.
- **zod:** Symbol, WeakMap, WeakSet, BigInt.

**What each core path adds**

- **G (Effect.gen + runPromise):**
  - Generators, and `yield*` over custom iterables: `[Symbol.iterator]()` returns an iterator, and the runtime drives it with `next(value)`.
  - `new Promise` + `.then`, `try`/`finally`, and one `globalThis[symbol]` write per run loop.
  - No timers.
- **T (typical Effect):**
  - `setTimeout`/`clearTimeout` (required; `effect.js:2889`) and `Date.now`.
  - `new Error()` under `Error.stackTraceLimit = 2` on every `Effect.fn` call. Effect reads `.stack` lazily and accepts `undefined`.
- **S (Schema decode):** nothing beyond what loading needs. It uses class getters, memoizing closures, `Reflect.ownKeys` and `Object.hasOwn`.
- **A (generateText + tool):**
  - Async functions (48 ran, 65 awaits), and one async generator consumed by `for await`.
  - `fetch` (2 calls), `Headers` (5), and `response.headers.get`.
  - `response.body.getReader()` with `read`/`cancel`/`releaseLock`, then `Uint8Array.set` and `TextDecoder`.
  - `JSON.parse` with an own-`__proto__` check and `stackTraceLimit = 0` around it.
  - `Math.random` for IDs. `process.env` is read only when the key is not passed in code.
- **Z (zod parse):**
  - Lazy accessor properties, `instanceof` through `Symbol.hasInstance`, `Reflect.ownKeys`, and regex `lastIndex`.
  - The JIT calls `new Function` once per object schema. With it blocked, zod falls back and prints the same output.

**Not needed on any core path** (each was deleted and the output did not change, or tracing shows only Node-internal calls):

- Code generation and dynamic objects: the Function constructor, Proxy.
- Scheduling: AbortController, setImmediate (effect falls back to setTimeout), queueMicrotask.
- Other built-ins: structuredClone, crypto, Intl, navigator, WeakRef, FinalizationRegistry, SharedArrayBuffer, Atomics.
- `process`, when the browser build of @vercel/oidc is used.

**What the migration app adds**

- **TypeScript transform:** 3 enums, 2 namespaces, 18 parameter properties.
- **Node APIs:**
  - `node:events` (`class JobQueue extends EventEmitter`).
  - `node:fs/promises` `readFile`, `node:path`, `fileURLToPath(import.meta.url)`.
  - `process.on("exit" | "unhandledRejection")`, `process.once("SIGINT" | "SIGTERM")`.
  - `process.exit`, `exitCode`, `nextTick`, `argv`, `env`.
  - `setInterval(...).unref()`.
- **Syntax:** 22 private fields and 5 private methods, 31 getters, one labeled `break`, one `super.x`, regex with the `s` flag.

### 7. Impossible or expensive on BEAM

**Absent from all reachable code:** SharedArrayBuffer, Atomics, WeakRef, FinalizationRegistry, `with`, direct `eval`, `Symbol.toPrimitive`, decorators, `using`, BigInt literals, and top-level await in packages. Nothing found is impossible.

**Avoidable**

1. `new Function` appears only in zod. A constructor that throws costs only zod's JIT speed.
2. Node built-ins appear only in @vercel/oidc's Node build. Choose the `browser` export condition.
3. When `process.release.name === "node"`, provider-utils switches to undici, `module.createRequire` and `Error.prepareStackTrace` CallSites. Bouy must not report `"node"`.
4. ai's browser-only APIs serve realtime voice only.

**Expensive, most costly first**

1. **State per realm.**
   - With one realm per actor, each spawn costs 15.6K objects + 10.9K closures for a tree-shaken `generateText` realm, and 12.7K + 12.6K for a full effect import.
   - Tree-shaking cuts effect to 191 + 538 for G, but barely shrinks ai.
   - Sharing one loaded heap across actors with copy-on-write needs a write barrier on every property write.
2. **Property reads without inline caches.** Every `o.k` walks the prototype chain and checks for accessors and proxies. Effect's run loop calls a symbol-keyed method on a prototype once per operation.
3. **Mutable arrays and byte buffers.** BEAM has no mutable array term.
   - `.push()` counts (by name): effect 498, @ai-sdk/openai 204, ai 187, zod 177.
   - Effect hashes numbers through a DataView. provider-utils copies the response body with `Uint8Array.set`.
4. **Numbers and strings.** NaN, ±Infinity and -0 are not Erlang floats.
   - Effect has 375 bitwise operators and 14 `Math.imul` calls in its hashing.
   - UTF-16 indexing: `charCodeAt` appears 49 times in effect and 26 times in eventsource-parser.
5. **Regex.**
   - PCRE2 covers the syntax used: 1 lookbehind, 1 backreference, 3 `\p{…}`, lazy quantifiers, lookahead, and flags g i m s u. There are no `y`, `d` or `v` flags and no named groups.
   - Match indices and `lastIndex` count UTF-16 units.
   - 29 patterns are strings compiled at run time, so Bouy needs a run-time translator.
6. **Stack traces.** Code lowered to continuation-passing closures has no JS call stack.
   - An `undefined` stack is cheap, and effect accepts it.
   - An accurate stack needs a shadow stack, which adds cost to every call.
7. **GC.**
   - WeakMap and WeakSet (effect 25 + 11, zod 6 + 4) need ephemeron marking.
   - GC only at job boundaries lets one long synchronous job, such as a large `JSON.parse`, grow the heap.
8. **Messages between actors.** Effect values, Schema class instances and ai errors carry prototypes, symbol keys and functions. Only plain data can cross an actor boundary.

### 8. Gap from the current subset

The four packages use, in total, constructs that BOUY205, BOUY206 and BOUY207 reject:

| construct                            |  uses |
| ------------------------------------ | ----: |
| closure writes to captured variables |   879 |
| `this` outside class methods         |   669 |
| regex literals                       |   342 |
| globalThis                           |   243 |
| getters and setters                  |   220 |
| `arguments`                          |   200 |
| `extends` (13 directly on Error)     |   183 |
| static members                       |   102 |
| async generators / for await         | 5 / 4 |

The value-semantics compiler cannot load any of the four packages.

**Not checked:**

- `streamText` and the Responses API (`openai("model")`). The fake server speaks only Chat Completions, and ai's streaming code has 38 `pipeThrough` and 145 `enqueue` sites.
- The migration app's census is static only. Coverage offsets would not match the TypeScript source.
- No costs on BEAM were measured. Section 7 ranks them from the census data alone.

**Next action:** choose one realm per actor or a shared, snapshotted realm, using the per-realm counts in section 2. That choice decides the heap design.
