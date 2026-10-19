# Node's built-in modules

Buoy runs Node's own JavaScript for the built-in modules, as ADR 0003 chooses: the `lib/` of the pinned Node release, on native bindings written in Erlang. This document is the manual for the work on one module. [testing.md](testing.md) section 5.7 describes how Node's tests measure it.

## 1. The parts

| Path                                                | What it holds                                                                                                                |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `runtime/vendor/node/lib/`                          | Node's `lib/` at the tag of `.node-version`, byte for byte. `scripts/vendor-node-lib.sh` copies it and writes `lib.sha256`.  |
| `runtime/vendor/node/deps/`                         | The bundled dependencies that `lib/` requires as `internal/deps/<path>`: undici, acorn, and minimatch.                       |
| `runtime/node/builtins.txt`                         | The ids that `crates/buoy-cli/build.rs` compiles into the runtime. It lists every file of `lib/` and of `deps/`.             |
| `runtime/node/<id>.js`                              | Buoy's own version of an id. build.rs takes it in place of the vendored file. `internal/main/buoy.js` is Buoy's main script. |
| `runtime/src/node/buoy_node.erl`                    | The C++ side of Node: the bootstrap, the primordials, `internalBinding`, and the helpers of the bindings.                    |
| `runtime/src/node/buoy_node_process.erl`            | The process object before the bootstrap, and `process.env`.                                                                  |
| `runtime/src/node/buoy_node_loop.erl`               | The event loop of Node on the job queue of the realm.                                                                        |
| `runtime/src/node/buoy_node_encoding.erl`           | The byte encodings of Buffer, and the bytes of typed arrays.                                                                 |
| `runtime/src/node/bindings/buoy_binding_<name>.erl` | `internalBinding('<name>')`. Its `binding/0` returns the binding object.                                                     |
| `runtime/src/node/buoy_node_stubs.erl`              | The bindings that have no `buoy_binding_<name>.erl` yet, with Node's shape.                                                  |
| `crates/buoy-native`                                | The NIF library `buoy_native`: native code in Rust that a binding needs, such as the codecs of `zlib`, and WebAssembly.      |
| `runtime/src/host/buoy_native.erl`                  | Loads the NIF library and declares its functions.                                                                            |

build.rs compiles each id with the reference compiler into the runtime module `buoy_node@<id>`, with `/` as `@` and `-` as `_`. Its `'__eval__'/3` returns the function that Node wraps around the code: `(exports, require, module, process, internalBinding, primordials)` for a module, and the parameters of `src/builtin_info.h` for the bootstrap and per-context scripts. The CLI caches each compiled `.beam` by the hash of its source, so a change to one id compiles one module.

## 2. The bootstrap

The first use of a built-in module, or of `process`, `Buffer`, `global`, `setImmediate`, or `clearImmediate`, the first call of `setTimeout` or `setInterval`, or the first use of a `console` member other than `log`, `info`, `debug`, `warn`, and `error`, runs the bootstrap in the realm. It runs the steps of Node's `node.cc`:

1. `internal/per_context/primordials`, `domexception`, and `messageport`, with the private and per-isolate symbols of `src/env_properties.h`.
2. `internal/bootstrap/realm`, which defines `BuiltinModule` and hands `internalBinding` and `requireBuiltin` to the `builtins` binding.
3. `internal/bootstrap/node`, `web/exposed-wildcard`, `web/exposed-window-or-worker`, `switches/is_main_thread`, and `switches/does_own_process_state`.
4. `internal/main/buoy`: the steps of `prepareMainThreadExecution` that a program needs, and the modules of `--require`. Buoy's compiler links the program, and a CommonJS module of the program loads through Node's CommonJS loader, with its compiled wrapper as the code cache.

The bootstrap also runs before the main script when the code comes from `-e`, `-p`, or stdin, when `--require` names modules, and when the entry is a CommonJS module. An ES module that never uses Node pays nothing.

## 3. Bindings

`internalBinding(name)` returns `buoy_binding_<name>:binding()`, built once per realm. A name without such a module takes its entry of `buoy_node_stubs`: each function throws `ERR_BUOY_NOT_IMPLEMENTED` with the binding and the member, each class throws when constructed, each `set*` function does nothing, and each value is Node's. So Node's lib loads, and a program fails only where it calls missing native code. Read `src/<file>.cc` of Node for the semantics of a member.

`tests/node/bindings.json` lists every binding and every member that `src/` of Node sets on it, and `cargo run --release -p buoy-suites -- node-bindings` writes it from Node's source at the tag of `.node-version`, with `runtime/src/node/buoy_node_manifest.erl`. `binding/1` gives each binding a stub for each function and class of the manifest that it lacks, so no member is silently missing. The "Node native bindings" section of `docs/COMPAT.md` counts the members of each binding that its module implements, which is the work list of the bindings.

The helpers in `buoy_node`:

- `fn(Name, Length, fun(This, Args) -> ... end)`, `constructor/3`, `object/1`, `object/2`, and `typed_array(Kind, Length)`.
- `stubs(Binding, Names)` and `not_implemented/2` for the members that a binding does not implement yet, and `missing_constructor/3` for a class.
- `throw_code(Class, Code, Message)` for an error with Node's `code`, `arg/2`, `string/1`, `symbol/1`, and `from_json/1`.
- `buoy_binding_fs:uv_error/3,4` throws Node's `uvException`, and `buoy_binding_uv:name/1` gives the name of an errno.
- `buoy_node_encoding` converts strings and bytes, and reads and writes the bytes of a typed array.
- `buoy_node_loop:defer(Fun)` runs a callback as a later macrotask, as libuv calls back from its thread pool, with the async context frame of the call that deferred it, and `ref_handle/0` and `unref_handle/0` keep the loop alive for an open handle.
- `buoy_node_loop:add_handle_wrap(Handle, Info)` puts a handle in the realm's version of Node's `handle_wrap_queue`, and `remove_handle_wrap/1` takes it out when it closes. `process._getActiveHandles()` and `process.getActiveResourcesInfo()` list the ref'd handles of the queue.
- `buoy_binding_async_wrap:wrap(Resource, Provider)` makes a handle or request an AsyncWrap: an async id, the trigger id, the async context frame, and the init hooks. `make_callback(Resource, Callback, Args)` calls back as `MakeCallback` does, between the before and after hooks, and `emit_destroy(Resource)` queues the destroy hooks when the resource ends.
- `buoy_trace` is the trace agent of the VM. `event/5`, `scope/3`, `complete/3`, and `instant/3` record an event of a category group, such as `node,node.fs,node.fs.sync`, while `--trace-event-categories` or an enabled `CategorySet` turns one of its categories on. The VM writes the events to `node_trace.${rotation}.log` before it halts.
- A process of a binding runs a callback in the realm with `buoy_node_stream:call(Realm, Fun)`, the message `{'$buoy_node_call', Fun}`, which the loop runs as a job. A JavaScript value that only such a callback names must stay a root of the heap, in the process dictionary under a key that is no integer, until the callback has run.
- `buoy_node_stream` gives a stream handle the StreamBase methods of `src/stream_base.cc` (`readStart`, `writeBuffer`, `shutdown`, `close`, and the others) over a channel process; `attach/2` binds a handle and `deliver/2` hands it data or `eof`. The pipes of `process_wrap` use it.
- `buoy_node_socket` drives the TCP, local, and UDP sockets of OTP's `socket` module in nowait mode, as libuv drives a descriptor: the realm owns each socket, and the loop routes its select messages (`{'$socket', ...}`) to `buoy_node_socket:event/1`. A write tries the kernel first and completes synchronously when the kernel takes every byte; the rest waits for the socket to be writable. `readStop` leaves data in the kernel, so TCP's flow control reaches the peer. `tcp_wrap`, `pipe_wrap`, and `udp_wrap` sit on it, and `set_listener/2` hands a handle's reads to a stream that wraps it.
- `tls_wrap` runs TLS on OTP's `ssl`: `buoy_tls_transport` is ssl's `cb_info` transport over the parent handle, an agent process per connection runs the handshake and moves cleartext, and `buoy_crypto_context` keeps a `SecureContext` as ssl options. `cares_wrap` resolves in worker processes with the native resolver and `inet_res`.
- `buoy_node_url` is the WHATWG URL parser of ada, and `buoy_binding_spawn_sync` and `buoy_binding_process_wrap` start child processes through `/bin/sh`, which wires their stdio.

A binding that needs native code calls a NIF of `buoy_native`. The NIF library is Rust in `crates/buoy-native`, one module for each subsystem, ported from the `src/*.cc` file of Node. A call that can take more than a millisecond runs on a dirty CPU scheduler, as Node runs it on the libuv thread pool. A NIF that crashes stops every actor of the VM, so the code is safe Rust where a Rust port of the library exists. Its allocations go through `enif_alloc`, so `BUOY_MAX_MEMORY` counts them.

A binding function that only throws must call a function, such as `buoy_node:throw_code/3`, through a named fun (`fun ?MODULE:name/2`), or dialyzer reports the created fun.

## 4. The event loop

`buoy_node_loop` serves the bindings of `lib/internal/timers`, `lib/internal/process/task_queues`, and `lib/internal/process/promises`:

- After each job: the microtasks, and the tick callback when `tickInfo` asks for it.
- Timers: one Erlang `send_after` for the native timer of `lib/internal/timers`, ref'd or not. Each turn of the loop starts with the timer when the clock has passed its deadline, before the poll, as libuv's `uv__run_timers` does, so a late message does not let the next immediates run first.
- Immediates: after each poll of the mailbox, while `immediateInfo` counts any.
- Closing: after the immediates, the close callbacks that `closing(Fun)` queued, as `uv__run_closing_handles` runs them, so a handle's `'close'` comes before the timers of the next turn.
- Rejections: the hook of `buoy_jobs` calls the callback of `setPromiseRejectCallback`.
- Uncaught exceptions: `process._fatalException` decides. An error that no handler takes prints its stack and `Node.js v25.9.0`, and the program exits with `process.exitCode`, or 1.
- Exit: with no ref'd timer, immediate, or handle left, `'beforeExit'`, then `'exit'`, then the exit code.

## 5. Making a module pass

1. Build: `cargo build --release -p buoy-cli -p buoy-suites`.
2. Run the module's files: `target/release/buoy-suites node --filter test-<module> --buoy $PWD/target/release/buoy`. The report gives the first lines of stderr for each failure. Each file runs as `buoy <the words of its // Flags: line> test/<id>`, the node form of the CLI (beam-runtime.md section 1), so the flags reach `process.execArgv` and the option values of Node's lib.
3. Run one file by hand from `tests/node`, as `test/<id>`, with the environment that the report prints. `BUOY_NODE_DEBUG=1` traces the bootstrap, prints the Erlang stack of the last error that the runtime threw, and traces the loop. The generated Erlang of an id is `~/.cache/buoy/runtime-*/src/buoy_node@<id>.erl`.
4. Fix the cause where it lives: a missing binding member in its `buoy_binding_<name>.erl` (create the file to replace the stub), an engine gap in the compiler or the runtime with a test of `tests/reference`, and a difference of Buoy in `runtime/node/<id>.js` only where Node's lib depends on V8 itself.
5. Record the result: `buoy-suites node --update --filter test-<module>` rewrites the lines of those files in `tests/node/expectations.txt`, and `buoy-suites node-surface --update --filter <module>` the surface. Never weaken an expectation to pass.
6. Each VM of a runner has `BUOY_MAX_MEMORY=1G`, and a runner starts at most 8 at once (AGENTS.md).

## 6. Limits

- Buoy has no Intl or inspector yet: `process.config` sets no `v8_enable_i18n_support`, so the tests that need them skip.
- `internalBinding('crypto')` runs on OTP's `crypto`, which links OpenSSL, and `process.versions.openssl` names that OpenSSL. Erlang code fills what the NIF lacks: the ASN.1 key codecs, streaming AEAD, X.509, TurboSHAKE, KangarooTwelve, KMAC, keys from ML-DSA and ML-KEM seeds, and Ed448 and ML-DSA signatures with a context. The NIF of `crates/buoy-native` runs the compute-bound parts: the Keccak sponge of TurboSHAKE, KangarooTwelve, and KMAC, the ROMix of scrypt, and Argon2, with the rust-argon2 crate that Bun uses. SLH-DSA with a context does not work. OTP's crypto gives no control of OpenSSL's providers, default properties, or secure heap, so `setFips(true)`, `--openssl-config`, and `--secure-heap` do not work, and `secureHeapUsed` reports no secure heap.
- The `constants` and `uv` bindings hold the tables of darwin and of Linux, as the oracle recorded them, and another OS gets darwin's.
- The engine has no JavaScript call stack yet. The `stack` of an error formats on its first read, as in V8: Node's `prepareStackTraceCallback`, else `Error.prepareStackTrace`, gets one CallSite of an anonymous frame, so a stack reads `Error [CODE]: message\n    at <anonymous>`. A test that matches real frames fails.
- The engine has no call stack limit, so deep recursion grows the process until `BUOY_MAX_MEMORY` stops the VM, where V8 throws `RangeError: Maximum call stack size exceeded`. `assert.deepStrictEqual` of a cyclic value relies on that error to switch to its cycle check.
- Child processes start through `/bin/bash`, which connects their piped stdin, stdout, stderr, and extra pipes as loopback sockets (`/dev/tcp`) and then execs `buoy --buoy-exec`, which gives the file the exact environment, `argv[0]`, ids, and session (beam-runtime.md section 1). erl_child_setup starts each child in a session of its own, so a terminal's Ctrl-C does not reach a child that is not detached. The IPC channel of `fork` is a local socket that the exec step connects (`buoy_node_ipc`), so handles pass over it as libuv passes them. A socket that passed to another process closes as its owner's exit closes it, since OTP's `socket:close` makes the shared descriptor blocking first. A child whose stdio is a socket of the parent, such as a `net.Socket`, reads and writes it through the parent. `process.execve` cannot replace the VM.
- `process.stdout` and `process.stderr` are `SyncWriteStream`s over the VM's standard I/O even when the descriptor is a pipe or a socket, where Node makes a `net.Socket`, so they have no `ref`, `unref`, or `_handle` (test-child-process-recv-handle). A file descriptor that `fs` opens belongs to its realm, so a worker's descriptor does not work in its parent (test-worker-track-unmanaged-fds).
- A `worker_threads` Worker is a realm in a BEAM process of its own, with its own heap, loop, `process.env`, and argv. Its `resourceLimits` become the `max_heap_size` of the process. Each worker realm runs Node's bootstrap and keeps its own copy of its objects, so the 256 workers of `test/parallel/test-worker-init-failure.js` pass the 1 GiB that the test runners give a VM.
- `process.title` keeps the value that a program sets, but the OS process keeps its name. SIGINT, which OTP cannot catch, reaches `process.on` and the `breakOnSigint` of `node:vm` through a handler of `buoy_native` while a listener or a watchdog waits for it; without one, it stops the VM as it stops Node. Other signals that OTP cannot catch reach `process.on` only when the program sends them to itself.
- The `url_pattern` binding is a stub: URLPattern does not work yet.
- `sqlite` and `webstorage` run SQLite 3.53.2 on a thread for each connection (`crates/buoy-native/src/sqlite.rs`); a JavaScript call of SQLite, such as a user-defined function, reaches the realm as a message while the method waits.
- TLS on `ssl` has no `getFinished`, `getPeerFinished`, PSK, OCSP stapling, `getSharedSigalgs`, server session callbacks (`newSession`, `resumeSession`), or TLS 1.2 session tickets (RFC 5077). A server connection comes from an ssl listener of the realm, one for each set of context options, because ssl runs its TLS 1.3 ticket tracker only for a listener; the listen socket is an unbound UDP socket that only ssl's trackers watch. ssl decrypts in its own processes, so the peer's cleartext arrives after the write callback that Node runs after it, and one `data` event can hold several records, so `setMaxSendFragment` sets no record size. TLSWrap reads ssl in passive mode with no receive waiting, so ssl keeps a connection whose peer sent close_notify and it can still write, as with `allowHalfOpen`; the TLS stream ends when the peer's stream ends, so a close_notify that comes without the end of the stream ends nothing yet. ssl's keylog has no `EXPORTER_SECRET` line, and a peer that ssl refuses for want of a signature algorithm gets ssl's `insufficient_security` alert, where OpenSSL sends `handshake_failure`. Renegotiation works for TLS 1.2: both sides see it in the record types, which ssl does not report, a server reports it to `onhandshakestart`, and the agent takes no cleartext meanwhile, since a receive that times out during it makes ssl fail the connection later. ssl answers a renegotiation in its own process, so it can finish one that the server's `CLIENT_RENEG_LIMIT` refuses. PKCS#12 (`pfx`) loads with 3DES and PBES2; RC2 and RC4 fail as OpenSSL 3 fails them without its legacy provider.
- A TLS 1.3 client holds its last flight until `onhandshakedone` has run, so a client that rejects the server sends no Finished and the server never completes, as with OpenSSL, which writes that flight after the callback.
- `http2` runs on `buoy_h2`, an Erlang port of nghttp2's session, and `buoy_hpack`; `http_parser` runs on `buoy_llhttp`, an Erlang port of llhttp. `fetch` and `WebSocket` run Node's undici, which parses HTTP with llhttp compiled to WebAssembly, which runs on the `WebAssembly` of `buoy_ref_wasm`. `respondWithFile` reads its FileHandle in the realm, as the fs binding reads every descriptor, so a FIFO that has no writer yet blocks the realm.
- The inspector binding has V8's console and `consoleCall` only, which Buoy's bootstrap wraps into the global console as Node does when it has the inspector. `config.hasInspector` stays false.
- `zlib` compresses with zlib-rs, brotli-rs, and libzstd 1.5.7. A deflate stream can differ in a few bytes from the one of Node's Chromium zlib, and stays valid. A brotli encoder with a dictionary uses the dictionary only within its window.
- WebAssembly keeps one store for each process, so the memory of an instance lives until the process ends. A `WebAssembly.Exception` does not cross into WebAssembly yet, and an `anyref`, `exnref`, or `v128` value cannot cross into JavaScript.
- The `fs` binding opens, reads, and writes files with prim_file, and makes stat, readdir, statfs, access, and the calls that change modes, owners, and times through the NIFs of `buoy_native`, as libuv makes them. On Linux, `fs.watch` watches with inotify. On macOS, it polls its path every 100 ms, as Buoy has no FSEvents or kqueue NIF yet, and `fs.watchFile` polls at its interval on every OS. A child process that takes a descriptor of `fs.open` as its stdio opens the path again, so it shares no file offset with the parent.
- A `node:vm` context is a realm whose global proxy intercepts the sandbox, as V8's named property callbacks do. A `timeout` compiles the script again to check its deadline at each turn of a loop, so a loop in a function that the script calls but did not define runs on.
- The heap collects garbage between macrotasks and at the safepoints of the loops of sync functions (beam-runtime.md). Garbage that the callbacks of one macrotask make outside such a loop stays until the macrotask ends.
