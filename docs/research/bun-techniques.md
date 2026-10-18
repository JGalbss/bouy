# Bun techniques: what Buoy copies on BEAM

This note is the guide for agents who build Node built-ins, the event loop, native code, startup, and the test runners of Buoy. It explains how Bun gets its speed and its Node compatibility, and it gives the Buoy equivalent of each technique with a priority. Read the section of your area before you design anything, then read the Bun files that it names.

[goal.md](../goal.md) requirement 11 makes Bun the bar for speed and recovery, and the owner said: "learn from shit bun did".

## How to read this note

- **Bun source.** Paths such as `src/js/node/fs.ts` are relative to [oven-sh/bun at `5667cd6`](https://github.com/oven-sh/bun/tree/5667cd6c0ad4c9f3343237c08661cd9e1f710692) (2026-10-17, Bun 1.4.3). A shallow clone of that commit is in `/tmp/bun-ref` on the build machine. Never edit it.
- **Numbers about Bun** are Bun's own claims, from the post or document that each sentence links. No Buoy benchmark has reproduced them.
- **Numbers about Buoy** come from `bench/` through [ADR 0003](../adr/0003-run-typescript-on-beam.md) evidence E1 and [speed-ceiling.md](speed-ceiling.md), as AGENTS.md requires.
- **Priorities:**
  - **P0:** it blocks Node coverage or a common npm path now.
  - **P1:** the next speed or startup step. Write the benchmark first.
  - **P2:** later.
  - **Never:** do not copy. Section 12 gives the reasons.

## Summary

| #   | Bun technique                                                        | Buoy equivalent on BEAM                                                                                    | Priority | Section |
| --- | -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | -------- | ------- |
| 1   | Native built-ins in Rust and C++, called from JS with no resolver    | Erlang bindings as today; one Rust NIF crate for byte-heavy members, in time slices                        | P0       | 2       |
| 2   | Rewrites of `node:*` in TypeScript over Bun's own APIs               | Run Node's `lib/` as it is, and copy only Bun's choice of what must be native                              | Never    | 3       |
| 3   | uWebSockets: native parser, corking, cached Date, lazy JS objects    | `tcp_wrap` on the `socket` module, owned by the actor; writes batched as an iolist; llhttp in a NIF        | P0, P1   | 4       |
| 4   | uSockets loop on epoll and kqueue; files on a thread pool            | ERTS poll threads and the mailbox; bounded work per turn; dirty I/O schedulers for files                   | P0, P1   | 5       |
| 5   | Lazy builtins, transpiler cache, bytecode cache                      | Measure first; a shared compile cache keyed by compiler version; a snapshot of the bootstrapped Node realm | P1       | 6       |
| 6   | JavaScriptCore's WebAssembly tiers                                   | A WebAssembly engine in a NIF that yields; Node's own `fetch` needs it                                     | P0       | 7       |
| 7   | Native fetch on an HTTP thread; native web streams                   | Node's undici over fast `net`, WebAssembly, and buffers; backpressure from the socket up                   | P0, P1   | 8       |
| 8   | mimalloc, GC paced by allocation, idle GC                            | Per-actor heaps; JS collection paced by growth and run once when idle; hibernation; copy-on-write buffers  | P1       | 9       |
| 9   | One process for `bun test`; `--isolate` and `--parallel`             | One actor per test file in one VM, on all schedulers                                                       | P1       | 10      |
| 10  | Replacing npm packages (`ws`, `undici`, `node-fetch`) with built-ins | Nothing. That is a one-off                                                                                 | Never    | 12      |

Section 11 lists the mistakes Bun made and fixed, each with the rule that it gives Buoy. Section 13 gives the build order.

## 1. How Bun is built

Bun is a runtime on JavaScriptCore (JSC), the engine of WebKit. Since Bun 1.4 it is written in Rust, with C++ for the JSC bindings and TypeScript for the built-in modules ([Rewriting Bun in Rust](https://bun.com/blog/bun-in-rust), 2026-07-08). Before that it was Zig. The source is a Cargo workspace of about 200 crates (`CLAUDE.md`):

| Bun path                                    | What it holds                                                                        | Buoy counterpart                                  |
| ------------------------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------- |
| `src/js/node/<module>.ts`                   | The `node:*` modules, mostly rewritten in TypeScript                                 | `runtime/vendor/node/lib/` (Node's own, verbatim) |
| `src/js/internal/`                          | Internal modules; some are ports of Node's `lib/internal`                            | `runtime/vendor/node/lib/internal/`               |
| `src/runtime/node/*_binding.rs`             | The native half of each Node module (`node_fs_binding.rs`, `node_net_binding.rs`)    | `runtime/src/buoy_binding_<name>.erl`             |
| `src/jsc/bindings/*.cpp`                    | JSC classes: `JSBuffer.cpp`, `BunProcess.cpp`, `NodeHTTP.cpp`, `JSNextTickQueue.cpp` | `runtime/src/buoy_node*.erl`, `buoy_ref_*.erl`    |
| `src/event_loop/`, `src/io/`                | The event loop and the poll layer                                                    | `runtime/src/buoy_node_loop.erl`, ERTS            |
| `packages/bun-uws`, `packages/bun-usockets` | uWebSockets and uSockets, Bun's fork                                                 | `gen_tcp` and `socket` of OTP                     |
| `test/js/node/test/parallel`                | 3,662 of Node's test files, added one by one as they pass                            | `tests/node/test`, every file at the tag          |

Bun vendors C libraries for the work that must be fast: simdutf and highway (SIMD text and search), zlib-ng, brotli, zstd, libdeflate, BoringSSL, c-ares, llhttp, lshpack, lsquic, mimalloc, and SQLite (`CLAUDE.md`, "Vendored Dependencies"). OTP already ships native code for some of these: `crypto` (OpenSSL), `zlib`, `zstd` (OTP 28 and later), `ssl`, `socket`, and `prim_file`. Use those before you write a NIF.

## 2. Native built-ins and how JavaScript calls them

### What Bun does

- **Direct calls to host functions.** A built-in module calls native code with `$newRustFunction("node_net_binding.rs", "doConnect", 2)` or `$rust(...)` and `$cpp(...)` (140, 31, and 23 uses in `src/js`). The build turns each call into a reference to the host function (`src/runtime/generated_js2native.rs`). JavaScript reaches native code with no lookup.
- **Generated glue.** A `*.classes.ts` file declares a JSC class: its methods, getters, and cached values. `src/codegen/generate-classes.ts` writes the C++ class and the Rust stubs. A `*.bind.ts` file declares a function's argument types, and `src/codegen/bindgen.ts` writes the conversion, so "a binding's Rust code never sees a `CallFrame`" (`docs/project/bindgen.mdx`).
- **No resolver between built-ins.** Each file in `src/js` gets a numeric id, and `require("x")` becomes a direct load of module `n` (`src/js/README.md`, `src/jsc/bindings/InternalModuleRegistry.cpp`). The modules are minified and embedded in the binary.
- **Tamper-proof intrinsics.** `$` names reach private JSC names and bytecode intrinsics: `fn.$call(...)`, `$newArrayWithSize(5)`, `$isCallable(x)`. User code cannot replace them (`src/js/AGENTS.md`).
- **Cached structures.** A JSC class keeps one structure for each global object (`LazyClassStructure`), so inline caches work. A structure made for each instance "permanently defeats inline caching" (`.claude/docs/landing-prs.md`, "Performance").

### What carries to BEAM

An Erlang binding is a host function with no foreign function interface (FFI) hop. `internalBinding('fs').open` is an Erlang fun that the generated code calls directly. It cannot crash the VM, and the scheduler preempts it. Keep Erlang as the default for bindings.

Node's own `lib/` validates arguments in JavaScript before it calls a binding (`lib/internal/validators.js`). So Buoy needs less glue than Bun, which validates in native code. Do not build a code generator for bindings until three bindings repeat the same argument checks.

Byte-heavy members need native code. BEAM has no mutable byte array, and the ArrayBuffer bytes of Buoy live in `atomics` arrays of 64-bit words (contract §17.2, "Binary data"). A loop over bytes in Erlang is slow, as [speed-ceiling.md](speed-ceiling.md) measured: the Rust JSON built-in is 4.8 times as fast as typed Erlang, and the Rust regex built-in is 10 times as fast.

### The Buoy design

1. **One NIF crate, P0.** Put Rust NIFs in one crate, for example `crates/buoy-native`, with one module for each Node binding that it serves (`encoding.rs`, `llhttp.rs`, `wasm.rs`), as Bun keeps `node_<name>_binding.rs`. `crates/buoy-cli/build.rs` builds it for the target, the CLI embeds the library next to the runtime sources and writes it into `runtime-<hash>/priv/`, and `buoy_native.erl` loads it. Keep one implementation of each member. Do not keep an Erlang twin of a NIF.
2. **The rules for every NIF.** A NIF crash ends the whole VM ([ADR 0003](../adr/0003-run-typescript-on-beam.md) §2.2), so the NIF is the one place where Buoy can lose its recovery advantage over Bun.
   - Return within 1 ms ([erl_nif](https://www.erlang.org/doc/apps/erts/erl_nif.html), "Long-running NIFs"). For longer work, count the time with `enif_consume_timeslice` and continue through `enif_schedule_nif`, as `bench/speed/native/src/lib.rs` does. Use a dirty scheduler only for a blocking system call.
   - Catch every panic at the NIF boundary and raise an Erlang exception. The spike crate builds with `panic = "abort"`, which ends the VM on a panic. Production code must not.
   - A NIF reads and writes bytes and numbers. It never reads the JavaScript heap of an actor.
   - Cross the boundary once for each operation, with whole binaries. Write into the final destination, and count the copies (Bun's rule in `.claude/docs/landing-prs.md`).
   - Fuzz every parser in a NIF, and keep `unsafe` in the FFI layer only. The workspace lints deny `unsafe`, so the crate states its own exception, as `bench/speed/native/Cargo.toml` does.
3. **Primordials as intrinsics, P1.** Node's `lib/` calls `ArrayPrototypePush(list, x)` and `FunctionPrototypeCall(fn, self)` from the frozen `primordials` object. V8 inlines these calls, and Bun gets the same effect from `$` intrinsics. On Buoy each one is a call through `uncurryThis`. The compiler can lower a call through a name that a built-in module takes from its `primordials` parameter to a direct call of the runtime function. Count the primordial calls on a hot path, such as a stream write, before you build it.
4. **The NIF candidates, in order.** Each needs its benchmark first.

| Member                                                                           | Native code                        | Priority | Why                                                                                  |
| -------------------------------------------------------------------------------- | ---------------------------------- | -------- | ------------------------------------------------------------------------------------ |
| `WebAssembly`                                                                    | A WebAssembly engine (section 7)   | P0       | Node's `fetch` instantiates llhttp as WebAssembly                                    |
| `buffer` and `encoding_binding` transcoding: UTF-8, UTF-16, Latin-1, base64, hex | the `simdutf` crate                | P1       | Bun's encodings use simdutf (`src/runtime/webcore/encoding.rs`, `Base64Helpers.cpp`) |
| `JSON.parse`, `JSON.stringify`                                                   | Rust, as in the spike              | P1       | 4.8 times typed Erlang ([speed-ceiling.md](speed-ceiling.md))                        |
| `RegExp`                                                                         | Rust, with a backtracking fallback | P1       | 10 times typed Erlang, at Bun's speed ([speed-ceiling.md](speed-ceiling.md))         |
| `http_parser`                                                                    | llhttp, the C parser of Node       | P1       | Bun vendors the same parser (`src/jsc/bindings/node/http/llhttp/`)                   |
| `zlib` brotli                                                                    | the `brotli` crate                 | P2       | OTP's `zlib` and `zstd` cover deflate and zstd                                       |

## 3. The Node compatibility layer

### What Bun does

- **Most modules are rewrites.** `node:fs` is TypeScript over a native `NodeFS` object (`src/js/node/fs.ts`, `src/runtime/node/node_fs.rs`, 10,103 lines). Each asynchronous call is an `AsyncFSTask` on a thread pool (`WorkPool`). The callback form waits on the promise and calls back through `process.nextTick`. `node:net` sits on uSockets (`node_net_binding.rs`). The `node:http` server calls `Bun.serve` (section 4). `node:zlib` became native code in Bun 1.2 ([Bun 1.2](https://bun.com/blog/bun-v1.2)).
- **Some modules are ports of Node's JavaScript.** `src/js/internal/streams/*`, `node:events`, `node:readline`, `internal/validators`, and `internal/fixed_queue` follow Node's `lib/`. Bun 1.4 replaced the `node:http` client, which had been a shim over `fetch()`, with "a direct port of Node's `_http_client.js`", and it replaced a REPL stub with "a working port of Node v26.3.0's REPL" ([Bun 1.4](https://bun.com/blog/bun-v1.4)). `src/js/node/_http_client.ts` links the Node file at v26.3.0.
- **`util.inspect` is a third copy.** Bun vendors node-inspect-extracted, a copy of Node's `inspect.js`, and its header says "TODO: delete this file. It is too much JavaScript" (`src/js/internal/util/inspect.js`). Bun's `console` uses a native formatter instead, so "replacing `process.stdout.write` does not capture the output, and object layout differs from `util.inspect`" ([Bun Node.js compatibility](https://bun.com/docs/runtime/nodejs-compat)).
- **No `internalBinding`.** Bun has no binding layer that matches Node's. `process.binding` is partial.
- **The direction.** Each release moves Bun closer to Node's own JavaScript and Node's own tests. Bun 1.2 says that fixing bugs from issue reports was "too much of a 'wack-a-mole' approach" and started to run Node's test suite on every change ([Bun 1.2](https://bun.com/blog/bun-v1.2)).

### The Buoy design

Buoy already runs Node's `lib/` byte for byte on Node's binding contract ([node-builtins.md](../design/node-builtins.md), ADR 0003). That is the end state that Bun moves toward for the JavaScript half. So:

1. **Never rewrite a module of `lib/`.** Write the binding member that it calls. Override an id in `runtime/node/<id>.js` only where Node's code depends on V8 itself (node-builtins.md §5).
2. **Copy Bun's choice of what is native.** Where Bun moved code from JavaScript to native code for speed, such as `Buffer` methods, zlib, and text encodings, Buoy puts the binding member in a NIF (section 2). Where Bun ported Node's JavaScript, Buoy already has it.
3. **Read Bun's Rust for edge cases, and Node's C++ for the contract.** Node's `src/<binding>.cc` defines what a member does. Bun's `src/runtime/node/` shows which errno and platform cases a real program hits.
4. **Apply Bun's review rules to binding members** (`.claude/docs/landing-prs.md`, "Node/Web compat"):
   - Real Node's observed behavior is the spec. Port it bug for bug, and do not modernize a message.
   - Match the whole error contract: the `ERR_*` code, the class, the message, the properties (`syscall`, `errno`, `path`), the order of the checks, and the channel (a throw, an `'error'` event, or a rejection).
   - The whole observable surface is the API, including property attributes, `constructor.name`, and underscore internals such as `_writableState`.
   - Port the whole behavior, with every sibling form (sync, callback, promise), and not only the case that a test names.

## 4. HTTP servers: Bun.serve and uWebSockets

### Why Bun's HTTP is fast

1. **A native server.** `Bun.serve` runs on uWebSockets in C++ (`packages/bun-uws/src`). Its parser (`HttpParser.h`) reads the request line and headers in place in the receive buffer.
2. **Corking.** `AsyncSocket.h` corks a socket while a response is written, so the status line, headers, and body leave in one system call.
3. **A cached Date header.** The loop formats the `Date` value once a second (`LoopData.h`, `updateDate`).
4. **Lazy JavaScript objects.** For `node:http`, the native side passes a bitfield of the headers that the dispatcher needs, "so no header object or array is materialized unless user code reads them" (`onNodeHTTPRequest` in `src/js/node/_http_server.ts`, `src/jsc/bindings/NodeHTTP.cpp`).
5. **Prebuilt responses.** A static route keeps its response bytes (`src/runtime/server/StaticRoute.rs`). A file body goes out through `sendfile` (`FileResponseStream.rs`).
6. **Less work for each connection.** Bun 1.4 sets `TCP_DEFER_ACCEPT` on Linux, keeps the backpressure buffer as a slab with a cursor, and holds large writes by reference ([Bun 1.4](https://bun.com/blog/bun-v1.4)).
7. **Native pub/sub.** WebSocket topics fan out in C++ (`TopicTree.h`), with no JavaScript call for each subscriber.

`node:http` runs on the same native server, so Express and Fastify get most of the gain. A JavaScript fallback serves an arbitrary `Duplex` (`src/js/internal/http1_server_fallback.ts`).

### The Buoy design

On Buoy, `http.createServer` is Node's `_http_server.js` over the `tcp_wrap`, `stream_wrap`, and `http_parser` bindings. `tcp_wrap` is a stub today (node-builtins.md §6).

1. **`tcp_wrap` on the `socket` module, P0.** The `socket` module is a NIF over the ERTS poll set (kqueue or epoll). The realm process owns each socket, and readiness arrives in its mailbox as a `select` message. No relay process stands between the socket and the JavaScript, as Bun keeps I/O on its main thread (`src/io/lib.rs`: "Most I/O happens on the main thread"). `readStart` and `readStop` arm and disarm the read, so a socket without a reader does not fill memory.
2. **Corking, P1.** Node already corks in JavaScript (`res.cork()`, `writev` of `stream_wrap`). The binding sends the chunks of one `writev` as one iolist in one send. A write during a job joins a queue that the loop flushes after the job, as Bun's `DeferredTaskQueue` flushes buffered response writes (`src/event_loop/README.md`).
3. **llhttp for `http_parser`, P1.** Node's tests check llhttp's error codes (`HPE_*`) and its lenient flags. ERTS has an HTTP parser in C (`erlang:decode_packet/3` with `http_bin`), but its errors and limits differ, so it cannot back `HTTPParser`. Bun made the same choice: it vendors llhttp for `node:http`.
4. **All cores, P2.** One `http.Server` lives in one realm, so its JavaScript runs on one scheduler, as in Node and in Bun. Bun scales with `reusePort` and `node:cluster` processes. Buoy can run the workers of `node:cluster` as actors in the same VM and hand each one accepted sockets, since a socket can change its owner process. This beats Bun's process model on memory and recovery. Measure it against Bun with `reusePort`.
5. **WebSocket fan-out, P2.** An actor API for topics can use `pg` process groups, the BEAM form of `TopicTree.h`.

## 5. I/O and the event loop

### What Bun does

- **One loop on the main thread.** `src/event_loop/README.md` gives the order: the concurrent tasks from other threads, each task followed by the microtasks, the immediates, the poll of uSockets, the timers, and the rejections. uSockets uses epoll on Linux and kqueue on macOS (`packages/bun-usockets/src/eventing/epoll_kqueue.c`), and libuv on Windows.
- **Threads for blocking work.** File system calls run on a thread pool (`WorkPool` in `src/runtime/node/node_fs.rs`). `fetch` runs on one HTTP client thread with its own loop and keep-alive pool (`src/http/HTTPThread.rs`, `src/http/HTTPContext.rs`).
- **No io_uring.** Early Bun used io_uring "for `bun install` and `fetch()`", and it failed on hosts without it ([#785](https://github.com/oven-sh/bun/issues/785), [#4040](https://github.com/oven-sh/bun/issues/4040)). Bun now uses epoll and polyfills `copy_file_range` and `pidfd_open` on old kernels.
- **Fixes in Bun 1.4** ([Bun 1.4](https://bun.com/blog/bun-v1.4)):
  - The Linux wakeup `eventfd` is edge-triggered, which removes one `read()` for each tick.
  - `setImmediate` no longer writes the `eventfd` on each iteration, about 44,000 writes in a 5-second loop before the fix.
  - A worker drains its messages with "a bounded budget per turn, so a message flood no longer starves timers, I/O".
  - On macOS, 500 concurrent `dns.lookup()` calls use about 9 threads instead of 513.

### The Buoy design

BEAM already has the parts of a loop. The ERTS poll threads watch kqueue or epoll, the scheduler runs each actor in turn, and the mailbox is the task queue. Buoy has no global loop. Each realm runs Node's loop in `buoy_node_loop` (node-builtins.md §4).

1. **Bound the work of each turn, P1.** Run at most a fixed count of mailbox messages and `'$buoy_node_call'` jobs before the loop checks its timers and immediates again. This is Bun's bounded drain.
2. **No message to self for each immediate, P1.** Run the immediates in the loop while `immediateInfo` counts any. A message for each one is Bun's `eventfd` mistake on BEAM.
3. **The actor owns its I/O, P0.** Sockets, pipes, and TTYs belong to the realm process (section 4). A process between the socket and the realm adds a hop to each read. Binaries over 64 bytes are reference-counted and are not copied by a send, but the hop still adds latency.
4. **Files.** `file:open/2` with `raw` uses `prim_file`, which runs on the dirty I/O schedulers (10 on the build machine), so a slow disk blocks only the calling actor. Node lets one process run many file operations at once on libuv's pool, and Bun uses `WorkPool`. When a test needs several file operations of one realm to overlap, run each asynchronous request in a short-lived process and deliver the result with `buoy_node_stream:call/2`. P2.
5. **DNS, P1.** `dns.lookup()` is `getaddrinfo` on libuv's pool in Node. On BEAM, `inet:getaddrs/2` asks the `inet_gethost` port program, which calls the system resolver outside the VM. The resolver methods of `cares_wrap` can use `inet_res`, a DNS client in Erlang.
6. **Child processes, P2.** Bun spawns with `posix_spawn` and file actions (`src/spawn_sys/posix_spawn.rs`). Buoy starts children through `/bin/bash` and loopback sockets (node-builtins.md §6). A small spawn helper that maps file descriptors as Node does removes that limit.
7. **No Linux-only system call without a fallback.** This is the io_uring lesson. The release must run on the Linux kernels and containers of goal.md requirement 13.

## 6. Startup

### What Bun does

- **Lazy built-ins.** The built-in modules are minified into the binary and run on first use (`src/js/README.md`). `src/jsc/bindings/ZigGlobalObject.h` has 145 lines that declare a `LazyProperty` or a `LazyClassStructure`, so a global is built when a program first reads it. A Bun `vm` context cost 34.3 KiB of heap against 162 KiB on Node ([js-engines-and-isolates.md](js-engines-and-isolates.md) §7).
- **Lazy exports and lazy imports.** In Bun 1.4, an ESM import of a built-in computes each export "when something first binds to it", and `require("ws")` no longer loads `node:http`, which saves "about 10 ms" ([Bun 1.4](https://bun.com/blog/bun-v1.4)).
- **A transpiler cache.** `src/jsc/RuntimeTranspilerCache.rs` stores the transpiled output of each source file of at least 4 KiB on disk. The key holds a hash of the input, a hash of the features that change the output, and a format version, which is now 35. The version log shows two bugs where a stale entry brought back a fixed bug (#30887 and #33904).
- **A bytecode cache.** `bun build --bytecode` writes JSC bytecode next to the bundle. Bun reports 2 times faster startup for `tsc`, and bytecode files up to 8 times the size of the source ([Bun v1.1.30](https://bun.com/blog/bun-v1.1.30), [bytecode docs](https://bun.com/docs/bundler/bytecode)).
- **A link order.** `scripts/orderfile` orders the startup symbols in the binary, which Bun 1.4 says cut the RSS of `bun -e` by about 9 MB.

Bun 1.4 reports 5.1 ms for a hello-world program on Linux, against 27.2 ms for Node 26.

### The Buoy design

ADR 0003 evidence E1 measured Buoy's startup at 199.7 ms against 100.6 ms for Node (`bench/results/2026-10-16-apple-m5-pro.json`), before the Node bootstrap existed.

1. **Measure where the time goes, P0.** Split the startup suite into: the VM boot, the start of the runtime application, the loading of modules, the Node bootstrap, and the program. Each later step names the part that it cuts.
2. **A shared compile cache, P1.** Today `buoy_main` caches each `.beam` in `<project>/.buoy/build/ebin/` under an MD5 of the generated Erlang and the OTP release, and the CLI still runs the TypeScript compiler on every module. Copy Bun's cache:
   - Key each npm file on the hash of its source, the compiler version, the options that change the output, and the OTP release.
   - Share the cache between projects under `~/.cache/buoy`, so a hit skips both the compiler and `erlc`.
   - Keep a format version, and add a test that a cache hit and a miss run the same program.
3. **A snapshot of the bootstrapped realm, P1.** Node starts from a V8 startup snapshot of its bootstrap. Buoy's realm heap is Erlang terms in the process dictionary (contract §17.2). After the bootstrap, `term_to_binary/1` of the heap entries and of the loop state is a snapshot, and one `binary_to_term/1` restores it. Funs in the snapshot name their modules, so key the snapshot on the runtime hash. Measure the bootstrap first.
4. **Lazy intrinsics, P2.** The `{lazy, Module}` record of contract §17.2, used for `Temporal`, can cover other large families of intrinsics, as JSC does with `LazyProperty`.
5. **Keep code loading lazy.** The VM loads each `buoy_node@<id>` module on its first call. Do not switch to a mode that loads every module at boot. A release (goal.md requirement 13) can preload the hot modules into its boot script, which is the BEAM form of `bun build --compile`.

## 7. WebAssembly

### What Bun does

JSC runs WebAssembly in its own tiers, so Bun gets it from the engine. `bun ./program.wasm` runs a WASI command ([Bun Node.js compatibility](https://bun.com/docs/runtime/nodejs-compat)).

### Why it is P0 for Buoy

Buoy has no `WebAssembly` global: `buoy -e 'console.log(typeof WebAssembly)'` prints `undefined`. Of the 29 files of Node's tests with `wasm` in the name, 28 fail (`tests/node/expectations.txt`). Node's `fetch` is undici, and undici instantiates its HTTP parser, llhttp, with `new WebAssembly.Module(...)` (`runtime/vendor/node/deps/undici/undici.js`, line 7075). So `fetch` needs WebAssembly. Many npm packages also ship a WebAssembly build as their fallback for a native addon, which is the general mechanism of goal.md requirement 2.

### The Buoy design

1. **An engine in the NIF crate.** Code compiled to Erlang would loop over bytes at the speed that [speed-ceiling.md](speed-ceiling.md) measured for typed Erlang, which is too slow. The engine must resume after a slice, so a long WebAssembly call yields to the scheduler. Two candidates:
   - wasmtime, which compiles with Cranelift and can yield on an epoch deadline in its async mode.
   - wasmi, an interpreter in Rust with fuel metering.
     A spike decides between them on the llhttp module of undici and on one large package build.
2. **Linear memory is an ArrayBuffer.** `memory.buffer` is an `ArrayBuffer` over the same bytes. So the engine's memory and the native buffers of section 9 must be one design.

## 8. fetch and streams

### What Bun does

- `fetch` is native (`src/runtime/webcore/fetch.rs`) and runs on the HTTP client thread, with a keep-alive pool, HTTP/2, and HTTP/3 clients (`src/http/`).
- Web streams became native in Bun 1.4. A "direct" `ReadableStream` writes chunks to the destination with no queue (`docs/runtime/streams.mdx`).
- Bun 1.4 added backpressure to `fetch`: "the HTTP thread stops reading from the socket instead of buffering the whole body". Before it, a slow reader let the whole body pile up in memory.
- `node:stream` is a port of Node's `lib/internal/streams` (`src/js/internal/streams/`).

### The Buoy design

On Buoy, `fetch` is Node's undici over `net` and `tls`, with llhttp in WebAssembly, and web streams are Node's `lib/internal/webstreams`. Keep both. Their speed comes from the layers under them:

1. `net` on the `socket` module (section 4), P0.
2. WebAssembly in a NIF (section 7), P0.
3. Fast buffers and encodings (sections 2 and 9), P1.
4. Promises and property access in the engine (Phase 5 of ADR 0003).

**Backpressure from the socket up.** A socket reads only while its stream wants data (`readStart`). Never arm a socket to deliver every packet to the mailbox without a reader. This is the BEAM form of Bun's 1.4 fix.

**TLS needs a decision, P1.** Node's `tls_wrap` runs TLS over any stream. Bun runs BoringSSL over in-memory buffers on its sockets (`packages/bun-usockets/src/crypto`). On BEAM there are two options:

- OTP's `ssl` application with a custom transport (`cb_info`).
- A TLS library in the NIF crate that runs over buffers, as Bun does.

A spike compares the two on Node's `test-tls-*` files and on throughput.

## 9. Memory

### What Bun does

- **mimalloc** for Bun's allocations, and since 1.4 for ICU, libuv, and BoringSSL too (`src/bun_alloc`, [Bun 1.4](https://bun.com/blog/bun-v1.4)).
- **GC paced by allocation.** JSC paces its collections by the allocation rate. `src/jsc/GarbageCollectionController.rs` adds an idle collection, and after 10 s, 2 min, and 10 min of quiet it runs full collections that let JSC drop code that no longer runs.
- **A mistake in pacing.** Before 1.4, a sampler on each tick ran about 62 young-generation collections a second, and "a 150 rps server with a 300 MB live heap spent up to about 40% of wall time in GC" ([Bun 1.4](https://bun.com/blog/bun-v1.4)).
- **`--smol`** trades speed for a smaller heap (`docs/runtime/bunfig.mdx`).
- **Leak tests** with RSS thresholds that depend on the build type, and LeakSanitizer in CI (`CLAUDE.md`, "Writing Tests").

### The Buoy design

BEAM collects each process on its own, so one actor's collection never stops another. Buoy's JavaScript heap is a second layer: `buoy_heap:gc/1` marks and sweeps the realm between jobs (contract §17.2).

1. **Pace the JavaScript collector by growth, P1.** Collect when the heap has grown by a factor since the last collection, and once more when the actor goes idle. Never collect on each tick or each job. Then call `erlang:garbage_collect/0`, and let an actor that stays idle hibernate (`erlang:hibernate/3`), which shrinks its process heap.
2. **Keep the limit for each actor.** `buoy_guard` gives each process a `max_heap_size` (contract §1). In Bun, "`Worker` ignores the `resourceLimits` and `trackUnmanagedFds` options" ([Bun Node.js compatibility](https://bun.com/docs/runtime/nodejs-compat)). This is one of Buoy's recovery wins. Keep it tested.
3. **Do not let a slice keep a large binary alive.** A sub-binary keeps its whole parent binary alive. A header string cut from a 64 KiB socket read keeps the 64 KiB. Copy the slice with `binary:copy/1` when a long-lived value keeps a small part of a large read.
4. **Copy-on-write buffers, P1.** An `ArrayBuffer` keeps its bytes in `atomics` words (contract §17.2). Most buffers of Node I/O are never written after they arrive: file contents, socket data, and the input of `toString`. An `ArrayBuffer` can hold the Erlang binary that I/O returned until its first write, and move to mutable storage then. The read paths then copy nothing. Benchmark `Buffer.from`, `toString`, `copy`, and `readFile` of 1 KiB and 1 MiB first. The design must also serve WebAssembly memory (section 7).
5. **Do not swap the allocator.** ERTS has its own allocators. Change an `erts_alloc` flag only with a measurement, as Bun's rule says: "existing settings encode prior measurements".
6. **Soak and leak tests.** Goal.md requirement 13 asks for soak tests that run for hours. Record `erlang:memory/0` by category, and set thresholds well below what a leak produces.

## 10. Test runner speed

### What Bun does

- **One process.** `bun test` runs all test files in one process with one global object by default, and `expect` is native (`src/runtime/test_runner/expect.rs`).
- **`--isolate` and `--parallel`.** Bun 1.3.13 added `--isolate`: a fresh global object for each file in the same process, with the transpiled source of shared modules cached. `--parallel` runs files in worker processes. Bun's docs say that one shared global "is the fastest mode", and that isolation costs "re-evaluating imports per file" ([Parallel and isolated test runs](https://bun.com/docs/test/parallel)).
- **Leaks between files.** Bun 1.4 fixed fake timers, subprocesses, and `process.chdir()` that leaked from one file into the next, and a crash when a collection ran during the swap between files ([Bun 1.4](https://bun.com/blog/bun-v1.4)).
- **CI scheduling.** `test/expected-durations.json` and `scripts/update-parallel-allowlist.mjs` decide which files run together. `scripts/runner.node.ts` runs Node's test files one process each.

### The Buoy design

1. **One actor for each test file, P1.** `buoy test` (goal.md requirement 8) runs each file as its own realm in one VM, on all schedulers. Each file gets a fresh global object, as with `--isolate`, and the files run in parallel, as with `--parallel`, with no OS process for each one. When the actor exits, BEAM releases its timers, ports, and sockets, so Bun's leaks cannot happen there.
2. **VM-wide state.** The working directory (`file:set_cwd/1`), the environment, and the umask belong to the whole VM. The runner must keep them for each realm, or `process.chdir()` leaks between files as it did in Bun.
3. **One compile cache for all files** (section 6). Each shared module compiles once.
4. **Longest files first in `buoy-suites`, P2.** Record the time of each file of Node's tests and start the slowest first, as Bun does with `expected-durations.json`. Keep the limits of AGENTS.md: `BUOY_MAX_MEMORY=1G` for each VM, and at most 8 VMs at once.
5. **Keep Buoy's stricter rules.**
   - Buoy keeps Node's tests byte for byte. Bun changed some tests to check "the `name` and `code`, instead of the `message`" ([Bun 1.2](https://bun.com/blog/bun-v1.2)).
   - Buoy records an outcome for each file and runs them all. Bun commits only the files that pass (`scripts/fetch-node-test.ts`), and an entry of `test/expectations.txt` removes a whole file from the run.

## 11. Mistakes Bun made and fixed

| Mistake                                                                                           | Fix                                                          | Source                                                                                                             | Rule for Buoy                                                                                                 |
| ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| Fixing Node bugs one issue report at a time                                                       | Run Node's test suite on every change                        | [Bun 1.2](https://bun.com/blog/bun-v1.2)                                                                           | Measure each module with Node's tests and the API surface. Fix causes in general code, never for one package. |
| The `node:http` client as a shim over `fetch()`; stubs for `node:repl` and `node:domain`          | Ports of Node's JavaScript                                   | [Bun 1.4](https://bun.com/blog/bun-v1.4)                                                                           | Never replace a file of `lib/` with a shim. Write the binding.                                                |
| A native `console` formatter that bypasses `process.stdout.write` and differs from `util.inspect` | Still open                                                   | [Bun Node.js compatibility](https://bun.com/docs/runtime/nodejs-compat)                                            | Run Node's `console` and `util.inspect`. Make them fast in the engine.                                        |
| Depending on io_uring                                                                             | epoll and kqueue through uSockets, and polyfills             | [#785](https://github.com/oven-sh/bun/issues/785), [#4040](https://github.com/oven-sh/bun/issues/4040)             | Use ERTS polling. Give any Linux-only system call a fallback.                                                 |
| Use-after-free and double-free crashes from manual memory next to the GC, in Zig                  | A port to Rust, with `Drop`                                  | [Rewriting Bun in Rust](https://bun.com/blog/bun-in-rust)                                                          | Keep native code in safe Rust NIFs that never touch the JavaScript heap. Catch panics. Fuzz the parsers.      |
| Cache entries that brought back fixed bugs (#30887, #33904)                                       | A format version and a hash of the output options in the key | `src/jsc/RuntimeTranspilerCache.rs`                                                                                | Key the compile cache on the compiler version and options. Test that a hit and a miss run the same program.   |
| A GC sampler on each tick: up to about 40% of wall time in GC                                     | A timer that runs only when idle                             | [Bun 1.4](https://bun.com/blog/bun-v1.4)                                                                           | Pace `buoy_heap:gc` by heap growth and idleness.                                                              |
| An `eventfd` write for each `setImmediate`                                                        | No wakeup while the loop runs                                | [Bun 1.4](https://bun.com/blog/bun-v1.4)                                                                           | Run immediates in the loop, with no message to self.                                                          |
| A message flood in a worker starved timers and I/O                                                | A bounded budget for each turn                               | [Bun 1.4](https://bun.com/blog/bun-v1.4)                                                                           | Bound the messages and jobs of each turn of `buoy_node_loop`.                                                 |
| `fetch()` buffered a whole body for a slow reader                                                 | Backpressure from the HTTP thread                            | [Bun 1.4](https://bun.com/blog/bun-v1.4)                                                                           | Read a socket only while its stream reads.                                                                    |
| `require("ws")` loaded `node:http`; built-in ESM imports computed every export                    | Lazy loading and lazy exports                                | [Bun 1.4](https://bun.com/blog/bun-v1.4)                                                                           | Measure the cost of `require` for each module, and keep the bootstrap lazy.                                   |
| Test files leaked fake timers, subprocesses, and the working directory into the next file         | `--isolate`, then fixes to it                                | [Bun 1.3.13](https://bun.com/blog/bun-v1.3.13), [Bun 1.4](https://bun.com/blog/bun-v1.4)                           | One actor for each test file, and VM-wide state kept for each realm.                                          |
| `worker.terminate()` did not stop a spinning worker on Bun 1.3.11                                 | Not reproducible on 1.3.13                                   | [#12616](https://github.com/oven-sh/bun/issues/12616), [js-engines-and-isolates.md](js-engines-and-isolates.md) §7 | BEAM preempts and kills any process. Keep a test that a runaway actor stops.                                  |

## 12. What not to copy

- **Replacing npm packages.** Bun's resolver maps the npm names `undici`, `ws`, `node-fetch`, `isomorphic-fetch`, and `@vercel/fetch` to its own modules (`src/resolve_builtins/HardcodedModule.rs`, `src/js/thirdparty/`). That is a special case for each package, which goal.md requirement 2 forbids: "liek we dont do 1 offs". Buoy runs the package from `node_modules`.
- **Rewriting `node:*` in TypeScript.** Bun spends each release porting Node's JavaScript back (section 3). Buoy runs `lib/`.
- **A second formatter for `console`,** and a third copy of `util.inspect`.
- **Edits to Node's tests,** and quarantine of whole files.
- **JSC syntax.** The `$` intrinsics are JSC bytecode. Buoy's form is the compiler lowering of primordials (section 2).
- **`panic = "abort"` in a NIF,** and `unsafe` outside the FFI layer.
- **io_uring as a requirement.**

## 13. Build order

1. **The NIF crate**, with build, embedding, loading, panic safety, time slices, and a fuzz target. P0.
2. **`tcp_wrap`, `pipe_wrap`, and `stream_wrap` on the `socket` module**, owned by the realm. P0. They unblock `net`, `http`, `tls`, and `fetch`.
3. **WebAssembly in the NIF crate.** P0. It unblocks `fetch` and the WebAssembly tests.
4. **A startup breakdown** in `bench/`. P0.
5. **Copy-on-write buffers and simdutf transcoding.** P1.
6. **llhttp for `http_parser`.** P1.
7. **The TLS spike.** P1.
8. **The loop rules:** a bounded turn, immediates without messages, and writes batched after each job. P1.
9. **GC pacing and hibernation.** P1.
10. **The shared compile cache and the realm snapshot**, after step 4 shows their share. P1.
11. **`buoy test` with one actor for each file.** P1.

Steps 1, 2, and 4 touch different code, so separate agents can run them at the same time. Each step names in its commit body the Bun approach that it follows, or why BEAM needs another one.

## Sources

Bun's posts and documents:

- [Rewriting Bun in Rust](https://bun.com/blog/bun-in-rust), 2026-07-08.
- [Bun 1.4](https://bun.com/blog/bun-v1.4), [Bun 1.3.13](https://bun.com/blog/bun-v1.3.13), [Bun 1.2](https://bun.com/blog/bun-v1.2), [Bun 1.1.30](https://bun.com/blog/bun-v1.1.30).
- [Node.js compatibility](https://bun.com/docs/runtime/nodejs-compat), [Bytecode caching](https://bun.com/docs/bundler/bytecode), [Parallel and isolated test runs](https://bun.com/docs/test/parallel), [WebSockets](https://bun.com/docs/runtime/http/websockets), [Streams](https://bun.com/docs/runtime/streams), [Node-API](https://bun.com/docs/runtime/node-api).
- Issues [#785](https://github.com/oven-sh/bun/issues/785), [#4040](https://github.com/oven-sh/bun/issues/4040), [#12616](https://github.com/oven-sh/bun/issues/12616), and [#4290](https://github.com/oven-sh/bun/issues/4290) (V8 C++ APIs for addons).

Bun's source at [`5667cd6`](https://github.com/oven-sh/bun/tree/5667cd6c0ad4c9f3343237c08661cd9e1f710692): `CLAUDE.md`, `.claude/docs/landing-prs.md`, `src/js/README.md`, `src/event_loop/README.md`, `docs/project/bindgen.mdx`, and the files that each section names.

BEAM: [erl_nif](https://www.erlang.org/doc/apps/erts/erl_nif.html), [socket](https://www.erlang.org/doc/apps/kernel/socket.html), and [erlang:hibernate/3](https://www.erlang.org/doc/apps/erts/erlang.html#hibernate/3).
