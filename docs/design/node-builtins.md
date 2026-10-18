# Node's built-in modules

Buoy runs Node's own JavaScript for the built-in modules, as ADR 0003 chooses: the `lib/` of the pinned Node release, on native bindings written in Erlang. This document is the manual for the work on one module. [testing.md](testing.md) section 5.7 describes how Node's tests measure it.

## 1. The parts

| Path                                  | What it holds                                                                                                                |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `runtime/vendor/node/lib/`            | Node's `lib/` at the tag of `.node-version`, byte for byte. `scripts/vendor-node-lib.sh` copies it and writes `lib.sha256`.  |
| `runtime/vendor/node/deps/`           | The bundled dependencies that `lib/` requires as `internal/deps/<path>`: undici, acorn, and minimatch.                       |
| `runtime/node/builtins.txt`           | The ids that `crates/buoy-cli/build.rs` compiles into the runtime. It lists every file of `lib/` and of `deps/`.             |
| `runtime/node/<id>.js`                | Buoy's own version of an id. build.rs takes it in place of the vendored file. `internal/main/buoy.js` is Buoy's main script. |
| `runtime/src/buoy_node.erl`           | The C++ side of Node: the bootstrap, the primordials, `internalBinding`, and the helpers of the bindings.                    |
| `runtime/src/buoy_node_process.erl`   | The process object before the bootstrap, and `process.env`.                                                                  |
| `runtime/src/buoy_node_loop.erl`      | The event loop of Node on the job queue of the realm.                                                                        |
| `runtime/src/buoy_node_encoding.erl`  | The byte encodings of Buffer, and the bytes of typed arrays.                                                                 |
| `runtime/src/buoy_binding_<name>.erl` | `internalBinding('<name>')`. Its `binding/0` returns the binding object.                                                     |
| `runtime/src/buoy_node_stubs.erl`     | The bindings that have no `buoy_binding_<name>.erl` yet, with Node's shape.                                                  |

build.rs compiles each id with the reference compiler into the runtime module `buoy_node@<id>`, with `/` as `@` and `-` as `_`. Its `'__eval__'/3` returns the function that Node wraps around the code: `(exports, require, module, process, internalBinding, primordials)` for a module, and the parameters of `src/builtin_info.h` for the bootstrap and per-context scripts. The CLI caches each compiled `.beam` by the hash of its source, so a change to one id compiles one module.

## 2. The bootstrap

The first use of a built-in module, or of `process`, `Buffer`, `global`, `setImmediate`, or `clearImmediate`, runs the bootstrap in the realm. It runs the steps of Node's `node.cc`:

1. `internal/per_context/primordials`, `domexception`, and `messageport`, with the private and per-isolate symbols of `src/env_properties.h`.
2. `internal/bootstrap/realm`, which defines `BuiltinModule` and hands `internalBinding` and `requireBuiltin` to the `builtins` binding.
3. `internal/bootstrap/node`, `web/exposed-wildcard`, `web/exposed-window-or-worker`, `switches/is_main_thread`, and `switches/does_own_process_state`.
4. `internal/main/buoy`: the steps of `prepareMainThreadExecution` that a program needs. Buoy's compiler loads the program, so Node's module loaders do not run.

A program that never uses Node pays nothing.

## 3. Bindings

`internalBinding(name)` returns `buoy_binding_<name>:binding()`, built once per realm. A name without such a module takes its entry of `buoy_node_stubs`: each function throws `ERR_BUOY_NOT_IMPLEMENTED` with the binding and the member, each class throws when constructed, each `set*` function does nothing, and each value is Node's. So Node's lib loads, and a program fails only where it calls missing native code. Read `src/<file>.cc` of Node for the semantics of a member.

The helpers in `buoy_node`:

- `fn(Name, Length, fun(This, Args) -> ... end)`, `constructor/3`, `object/1`, `object/2`, and `typed_array(Kind, Length)`.
- `stubs(Binding, Names)` and `not_implemented/2` for the members that a binding does not implement yet, and `missing_constructor/3` for a class.
- `throw_code(Class, Code, Message)` for an error with Node's `code`, `arg/2`, `string/1`, `symbol/1`, and `from_json/1`.
- `buoy_binding_fs:uv_error/3,4` throws Node's `uvException`, and `buoy_binding_uv:name/1` gives the name of an errno.
- `buoy_node_encoding` converts strings and bytes, and reads and writes the bytes of a typed array.
- `buoy_node_loop:defer(Fun)` runs a callback as a later macrotask, as libuv calls back from its thread pool, and `ref_handle/0` and `unref_handle/0` keep the loop alive for an open handle.
- A process of a binding runs a callback in the realm with `buoy_node_stream:call(Realm, Fun)`, the message `{'$buoy_node_call', Fun}`, which the loop runs as a job. A JavaScript value that only such a callback names must stay a root of the heap, in the process dictionary under a key that is no integer, until the callback has run.
- `buoy_node_stream` gives a stream handle the StreamBase methods of `src/stream_base.cc` (`readStart`, `writeBuffer`, `shutdown`, `close`, and the others) over a channel process; `attach/2` binds a handle and `deliver/2` hands it data or `eof`. The pipes of `process_wrap` use it.
- `buoy_node_socket` drives the TCP, local, and UDP sockets of OTP's `socket` module in nowait mode, as libuv drives a descriptor: the realm owns each socket, and the loop routes its select messages (`{'$socket', ...}`) to `buoy_node_socket:event/1`. A write tries the kernel first and completes synchronously when the kernel takes every byte; the rest waits for the socket to be writable. `readStop` leaves data in the kernel, so TCP's flow control reaches the peer. `tcp_wrap`, `pipe_wrap`, and `udp_wrap` sit on it, and `set_listener/2` hands a handle's reads to a stream that wraps it.
- `tls_wrap` runs TLS on OTP's `ssl`: `buoy_tls_transport` is ssl's `cb_info` transport over the parent handle, an agent process per connection runs the handshake and moves cleartext, and `buoy_crypto_context` keeps a `SecureContext` as ssl options. `cares_wrap` resolves in worker processes with the native resolver and `inet_res`.
- `buoy_node_url` is the WHATWG URL parser of ada, and `buoy_binding_spawn_sync` and `buoy_binding_process_wrap` start child processes through `/bin/sh`, which wires their stdio.

A binding function that only throws must call a function, such as `buoy_node:throw_code/3`, through a named fun (`fun ?MODULE:name/2`), or dialyzer reports the created fun.

## 4. The event loop

`buoy_node_loop` serves the bindings of `lib/internal/timers`, `lib/internal/process/task_queues`, and `lib/internal/process/promises`:

- After each job: the microtasks, and the tick callback when `tickInfo` asks for it.
- Timers: one Erlang `send_after` for the native timer of `lib/internal/timers`, ref'd or not.
- Immediates: after each poll of the mailbox, while `immediateInfo` counts any.
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

- Buoy has no OpenSSL, Intl, or inspector yet: `process.versions` has no `openssl`, and `process.config` sets no `v8_enable_i18n_support`, so the tests that need them skip.
- The constants of the `constants`, `uv`, and `os` bindings are darwin's, as the oracle recorded them.
- Stack traces of errors are `at <buoy>`: the engine has no JavaScript call stack yet.
- `async_context_frame` keeps one value per realm, which promise jobs do not carry yet.
- The engine has no call stack limit, so deep recursion grows the process until `BUOY_MAX_MEMORY` stops the VM, where V8 throws `RangeError: Maximum call stack size exceeded`. `assert.deepStrictEqual` of a cyclic value relies on that error to switch to its cycle check.
- Child processes start through `/bin/bash`, which connects their piped stdin, stderr, and extra pipes as loopback sockets (`/dev/tcp`). Handles cannot pass over an IPC channel yet, and `process.execve` cannot replace the VM.
- `process.title` keeps the value that a program sets, but the OS process keeps its name. Signals that OTP cannot catch, such as SIGINT, reach `process.on` only when the program sends them to itself.
- The `tty_wrap` handle, `url_pattern`, `worker`, and `webstorage` bindings are stubs: an interactive terminal, URLPattern, worker_threads, and Web Storage, which needs SQLite, do not work yet.
- TLS on `ssl` has no `getFinished`, `getPeerFinished`, PSK, OCSP stapling, `getSharedSigalgs`, server session callbacks (`newSession`, `resumeSession`), or TLS 1.2 session tickets (RFC 5077). A server connection comes from an ssl listener of the realm, one for each set of context options, because ssl runs its TLS 1.3 ticket tracker only for a listener; the listen socket is an unbound UDP socket that only ssl's trackers watch. ssl decrypts in its own processes, so the peer's cleartext arrives after the write callback that Node runs after it, and one `data` event can hold several records, so `setMaxSendFragment` sets no record size. TLSWrap reads ssl in passive mode with no receive waiting, so ssl keeps a connection whose peer sent close_notify and it can still write, as with `allowHalfOpen`; the TLS stream ends when the peer's stream ends, so a close_notify that comes without the end of the stream ends nothing yet. ssl's keylog has no `EXPORTER_SECRET` line, and a peer that ssl refuses for want of a signature algorithm gets ssl's `insufficient_security` alert, where OpenSSL sends `handshake_failure`. Renegotiation works for TLS 1.2: both sides see it in the record types, which ssl does not report, a server reports it to `onhandshakestart`, and the agent takes no cleartext meanwhile, since a receive that times out during it makes ssl fail the connection later. ssl answers a renegotiation in its own process, so it can finish one that the server's `CLIENT_RENEG_LIMIT` refuses. PKCS#12 (`pfx`) loads with 3DES and PBES2; RC2 and RC4 fail as OpenSSL 3 fails them without its legacy provider.
- A TLS 1.3 client holds its last flight until `onhandshakedone` has run, so a client that rejects the server sends no Finished and the server never completes, as with OpenSSL, which writes that flight after the callback.
- A cluster worker cannot share a server: the round-robin and shared handles pass over IPC, which cannot pass handles yet.
- `node:vm` contexts copy the sandbox's properties into the context's realm before a run and back after it, where V8 intercepts each access.
