# Bouy

Bouy compiles TypeScript to Erlang and runs it on BEAM, the Erlang virtual machine. Actors are the execution primitive: each actor is a BEAM process with its own heap, its own mailbox, and a supervisor. Bouy has no JavaScript event loop and no Node or V8 dependency.

```ts
import { spawn } from "bouy";

class Counter {
  #count = 0;

  increment(): number {
    this.#count += 1;
    return this.#count;
  }
}

const counter = spawn(Counter);
console.log(await counter.increment());
```

`bouy run counter.ts` lowers each TypeScript module to an Erlang module, compiles the Erlang inside one BEAM VM, and runs it there.

## Status

Work in progress. The compiler, the CLI, and the runtime are being built against [the contract](docs/design/beam-runtime.md). This README gets a quick start when `bouy run` passes its end-to-end tests.

## Layout

| Path                   | Contents                                                                              |
| ---------------------- | ------------------------------------------------------------------------------------- |
| `crates/bouy-compiler` | The compiler. oxc parses the TypeScript, and the compiler lowers it to Erlang source. |
| `crates/bouy-cli`      | The `bouy` command.                                                                   |
| `runtime`              | The OTP application: JavaScript values, actors, and supervision.                      |
| `tests`                | TypeScript programs that the end-to-end tests compile and run.                        |
| `docs`                 | The contract, the decision records, and the research notes.                           |

## Requirements

- Erlang/OTP 27 or later, for `erl` and `erlc`.
- Rust 1.98, which `rust-toolchain.toml` pins, to build the CLI.
- rebar3, to test the runtime.
- pnpm, for the repository tools: turbo, oxfmt, and oxlint.
