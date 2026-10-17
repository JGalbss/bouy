# Node's built-in modules

Bouy runs Node's own JavaScript for the built-in modules, as ADR 0003 chooses: the `lib/` of the pinned Node release, on native bindings written in Erlang. This document is the manual for the work on one module. [testing.md](testing.md) section 5.7 describes how Node's tests measure it.

## 1. The parts

| Path                                  | What it holds                                                                                                                |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `runtime/vendor/node/lib/`            | Node's `lib/` at the tag of `.node-version`, byte for byte. `scripts/vendor-node-lib.sh` copies it and writes `lib.sha256`.  |
| `runtime/vendor/node/deps/`           | The bundled dependencies that `lib/` requires as `internal/deps/<path>`: undici, acorn, and minimatch.                       |
| `runtime/node/builtins.txt`           | The ids that `crates/bouy-cli/build.rs` compiles into the runtime. It lists every file of `lib/` and of `deps/`.             |
| `runtime/node/<id>.js`                | Bouy's own version of an id. build.rs takes it in place of the vendored file. `internal/main/bouy.js` is Bouy's main script. |
| `runtime/src/bouy_node.erl`           | The C++ side of Node: the bootstrap, the primordials, `internalBinding`, and the helpers of the bindings.                    |
| `runtime/src/bouy_node_process.erl`   | The process object before the bootstrap, and `process.env`.                                                                  |
| `runtime/src/bouy_node_loop.erl`      | The event loop of Node on the job queue of the realm.                                                                        |
| `runtime/src/bouy_node_encoding.erl`  | The byte encodings of Buffer, and the bytes of typed arrays.                                                                 |
| `runtime/src/bouy_binding_<name>.erl` | `internalBinding('<name>')`. Its `binding/0` returns the binding object.                                                     |
| `runtime/src/bouy_node_stubs.erl`     | The bindings that have no `bouy_binding_<name>.erl` yet, with Node's shape.                                                  |

build.rs compiles each id with the reference compiler into the runtime module `bouy_node@<id>`, with `/` as `@` and `-` as `_`. Its `'__eval__'/3` returns the function that Node wraps around the code: `(exports, require, module, process, internalBinding, primordials)` for a module, and the parameters of `src/builtin_info.h` for the bootstrap and per-context scripts. The CLI caches each compiled `.beam` by the hash of its source, so a change to one id compiles one module.

## 2. The bootstrap

The first use of a built-in module, or of `process`, `Buffer`, `global`, `setImmediate`, or `clearImmediate`, runs the bootstrap in the realm. It runs the steps of Node's `node.cc`:

1. `internal/per_context/primordials`, `domexception`, and `messageport`, with the private and per-isolate symbols of `src/env_properties.h`.
2. `internal/bootstrap/realm`, which defines `BuiltinModule` and hands `internalBinding` and `requireBuiltin` to the `builtins` binding.
3. `internal/bootstrap/node`, `web/exposed-wildcard`, `web/exposed-window-or-worker`, `switches/is_main_thread`, and `switches/does_own_process_state`.
4. `internal/main/bouy`: the steps of `prepareMainThreadExecution` that a program needs. Bouy's compiler loads the program, so Node's module loaders do not run.

A program that never uses Node pays nothing.

## 3. Bindings

`internalBinding(name)` returns `bouy_binding_<name>:binding()`, built once per realm. A name without such a module takes its entry of `bouy_node_stubs`: each function throws `ERR_BOUY_NOT_IMPLEMENTED` with the binding and the member, each class throws when constructed, each `set*` function does nothing, and each value is Node's. So Node's lib loads, and a program fails only where it calls missing native code. Read `src/<file>.cc` of Node for the semantics of a member.

The helpers in `bouy_node`:

- `fn(Name, Length, fun(This, Args) -> ... end)`, `constructor/3`, `object/1`, `object/2`, and `typed_array(Kind, Length)`.
- `stubs(Binding, Names)` and `not_implemented/2` for the members that a binding does not implement yet, and `missing_constructor/3` for a class.
- `throw_code(Class, Code, Message)` for an error with Node's `code`, `arg/2`, `string/1`, `symbol/1`, and `from_json/1`.
- `bouy_binding_fs:uv_error/3,4` throws Node's `uvException`, and `bouy_binding_uv:name/1` gives the name of an errno.
- `bouy_node_encoding` converts strings and bytes, and reads and writes the bytes of a typed array.
- `bouy_node_loop:defer(Fun)` runs a callback as a later macrotask, as libuv calls back from its thread pool, and `ref_handle/0` and `unref_handle/0` keep the loop alive for an open handle.

A binding function that only throws must call a function, such as `bouy_node:throw_code/3`, through a named fun (`fun ?MODULE:name/2`), or dialyzer reports the created fun.

## 4. The event loop

`bouy_node_loop` serves the bindings of `lib/internal/timers`, `lib/internal/process/task_queues`, and `lib/internal/process/promises`:

- After each job: the microtasks, and the tick callback when `tickInfo` asks for it.
- Timers: one Erlang `send_after` for the native timer of `lib/internal/timers`, ref'd or not.
- Immediates: after each poll of the mailbox, while `immediateInfo` counts any.
- Rejections: the hook of `bouy_jobs` calls the callback of `setPromiseRejectCallback`.
- Uncaught exceptions: `process._fatalException` decides. An error that no handler takes prints its stack and `Node.js v25.9.0`, and the program exits with `process.exitCode`, or 1.
- Exit: with no ref'd timer, immediate, or handle left, `'beforeExit'`, then `'exit'`, then the exit code.

## 5. Making a module pass

1. Build: `cargo build --release -p bouy-cli -p bouy-suites`.
2. Run the module's files: `target/release/bouy-suites node --filter test-<module> --bouy $PWD/target/release/bouy`. The report gives the first lines of stderr for each failure. The suite runs on the reference engine (`bouy run --semantics reference`).
3. Run one file by hand from `tests/node`, as `test/<id>`, with the environment that the report prints. `BOUY_NODE_DEBUG=1` traces the bootstrap, prints the Erlang stack of the last error that the runtime threw, and traces the loop. The generated Erlang of an id is `~/.cache/bouy/runtime-*/src/bouy_node@<id>.erl`.
4. Fix the cause where it lives: a missing binding member in its `bouy_binding_<name>.erl` (create the file to replace the stub), an engine gap in the compiler or the runtime with a test of `tests/reference`, and a difference of Bouy in `runtime/node/<id>.js` only where Node's lib depends on V8 itself.
5. Record the result: `bouy-suites node --update --filter test-<module>` rewrites the lines of those files in `tests/node/expectations.txt`, and `bouy-suites node-surface --update --filter <module>` the surface. Never weaken an expectation to pass.
6. Each VM of a runner has `BOUY_MAX_MEMORY=1G`, and a runner starts at most 8 at once (AGENTS.md).

## 6. Limits

- Bouy has no OpenSSL, Intl, or inspector yet: `process.versions` has no `openssl`, and `process.config` sets no `v8_enable_i18n_support`, so the tests that need them skip.
- The constants of the `constants`, `uv`, and `os` bindings are darwin's, as the oracle recorded them.
- Stack traces of errors are `at <bouy>`: the engine has no JavaScript call stack yet.
- `async_context_frame` keeps one value per realm, which promise jobs do not carry yet.
