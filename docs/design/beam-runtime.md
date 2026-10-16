# Bouy on BEAM: the compiler and runtime contract

Status: the working contract for the BEAM runtime, 2026-10-16. It replaces the "now" decision of ADR 0001. Bouy no longer runs on Node, Bun, or V8, and the product has no Node or V8 dependency. Node appears only as a test oracle and as a benchmark baseline.

This file is the contract between the compiler (`crates/bouy-compiler`), the CLI (`crates/bouy-cli`), and the runtime (`runtime/`). Every name in this file is normative. A change to a name changes this file in the same commit.

## 1. Pipeline

`bouy run app.ts [args...]`:

1. The CLI resolves the module graph from the entry module. It follows relative imports (`./x.ts`, `./x.js`, `./x`, `./dir/index.ts`) and library imports (section 11). Any other import is error `BOUY201`.
2. The compiler parses each module with oxc, runs oxc semantic analysis, checks the Bouy subset (section 10), and lowers the module to one Erlang source file.
3. The CLI writes the Erlang files to `<project>/.bouy/build/src/`. The project root is the nearest ancestor directory of the entry that holds a `package.json`, or else the entry's directory.
4. The CLI starts one VM: `erl -noshell -noinput -pa <runtime ebin> -eval "bouy_main:start(...)"`. `bouy_main:start/1` compiles each changed Erlang file in the VM with `compile:file/2`, writes the `.beam` file to `.bouy/build/ebin/`, loads every module, runs the entry module, and halts. One VM start serves both compilation and execution.
5. The program ends when the top-level code of the entry module returns. Then the runtime stops every actor and halts with status 0. An uncaught error in top-level code prints `Uncaught <name>: <message>` to stderr and halts with status 1. A compile diagnostic prints `<path>:<line>:<column>: <code>: <message>` to stderr, and the CLI exits with status 2 before it starts the VM.

The CLI embeds the runtime sources, `runtime/src/*.erl`, through `crates/bouy-cli/build.rs`. On the first run, the CLI writes them to `$XDG_CACHE_HOME/bouy/runtime-<hash>/` (default `~/.cache/bouy/runtime-<hash>/`) and compiles them there with `erlc`. The installed OTP compiles the runtime, so the `.beam` files always match the installed OTP release. `BOUY_RUNTIME=<dir>` overrides that directory for development. The CLI finds `erl` on `PATH`, or uses `BOUY_ERL`.

`bouy check app.ts` runs steps 1 and 2 and prints diagnostics. `bouy build app.ts` runs steps 1 to 3 and prints the paths of the Erlang files.

## 2. Names

| TypeScript                              | Erlang                                                                                                                                                                                                               |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Module `src/agents/team.ts`             | Module `'bouy@src@agents@team'`: the path from the project root without the extension, with `/` → `@` and each character outside `[A-Za-z0-9_]` → `_`                                                                |
| Top-level code of a module              | `'__init__'/0`, exported. `bouy_main:import/1` runs it once and records that it ran.                                                                                                                                 |
| Function `foo`                          | `'foo'/1`, exported. It takes the argument list (section 4).                                                                                                                                                         |
| Module-level `const x = expr`           | `'__init__'/0` stores the value with `persistent_term:put({Module, <<"x">>}, V)`. A function reads it with `persistent_term:get({Module, <<"x">>})`. The compiler inlines a literal initializer at each use instead. |
| Module-level `const f = (args) => body` | The same as `function f(args) { body }`.                                                                                                                                                                             |
| Class `Counter`                         | `'Counter#new'/1`, `'Counter#dispatch'/3`, `'Counter#streams'/0`, and one `'Counter#m'/2` per method (section 9)                                                                                                     |
| Error class `NotFound`                  | `'NotFound#new'/1` (section 9)                                                                                                                                                                                       |
| Local variable `count`, version 3       | `Count@3`. A compiler temporary is `T@<n>`. Every variable name is unique within one Erlang function.                                                                                                                |

## 3. Values

| TypeScript value                     | Erlang term                                                                                                                                                                                                                                           |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `number`                             | `integer()` or `float()`. An integer literal is an integer. `/` yields an integer when both operands are integers and the remainder is zero, else a float. `NaN`, `Infinity`, and `-Infinity` are the atoms `'NaN'`, `'Infinity'`, and `'-Infinity'`. |
| `string`                             | `binary()`, UTF-8                                                                                                                                                                                                                                     |
| `boolean`                            | `true`, `false`                                                                                                                                                                                                                                       |
| `null`, `undefined`                  | `null`, `undefined`                                                                                                                                                                                                                                   |
| array                                | `list()`                                                                                                                                                                                                                                              |
| object                               | `map()` with `binary()` keys                                                                                                                                                                                                                          |
| `Map<K, V>`                          | `{'$map', Entries}`. `bouy_map` owns the shape of `Entries` and keeps insertion order.                                                                                                                                                                |
| `Set<T>`                             | `{'$set', Members}`. `bouy_set` owns the shape of `Members` and keeps insertion order.                                                                                                                                                                |
| function                             | `fun((Args :: list()) -> term())`                                                                                                                                                                                                                     |
| user class                           | `{'$class', Module :: atom(), Name :: binary()}`                                                                                                                                                                                                      |
| library namespace (`Math`, `Effect`) | `{'$namespace', Module :: atom()}`                                                                                                                                                                                                                    |
| actor ref                            | `{'$ref', Id :: pos_integer()}`; `cast(ref)` yields `{'$cast', Id}`                                                                                                                                                                                   |
| error                                | a map with `<<"$error">> => true`, `<<"name">>`, `<<"message">>`, `<<"stack">>`, and any own fields, such as `<<"_tag">>` for a tagged error and `<<"cause">>`                                                                                        |
| Effect                               | `{'$effect', fun(() -> {ok, A} \| {error, E})}`                                                                                                                                                                                                       |
| stream (an async iterable)           | `{'$stream', Pid :: pid(), Ref :: reference()}`                                                                                                                                                                                                       |

Every value has value semantics. A mutation changes the variable or the field that holds the value. Another variable that held the same value keeps the old one. This is the largest difference from JavaScript, and it is what isolates actors: a message cannot share mutable state, because no value changes in place.

Known differences from JavaScript. Each one is a documented limitation:

- `===` on arrays and objects compares contents, because values have no identity.
- Object keys iterate in Erlang term order (sorted), not in insertion order. This shows in `Object.keys`, `for...in`, `JSON.stringify`, and `console.log`.
- `string.length` and string indexes count Unicode code points, not UTF-16 code units. The two differ only for characters outside the Basic Multilingual Plane.
- Integers have arbitrary precision. `2 ** 53 + 1` is exact.

## 4. Calling convention

- Every compiled function and every function value takes one argument: the list of arguments. `bouy_rt:arg(N, Args)` returns argument `N` (1-based) or `undefined`.
- A default parameter compiles to `case bouy_rt:arg(N, Args) of undefined -> Default; V -> V end`. A rest parameter compiles to `bouy_rt:rest(N, Args)`, which returns the arguments from position `N` on.
- A call to a function declared in the same module compiles to a local call `'foo'([A, B])`. A call to a function imported from another Bouy module compiles to a remote call `'bouy@other':'foo'([A, B])`. A call to a library function compiles to a remote call to its Erlang module (section 11).
- A call of any other value compiles to `bouy_rt:call(F, [A, B])`. `call/2` accepts a fun and throws `TypeError: <value> is not a function` for anything else.
- A function used as a value compiles to `fun 'foo'/1` or `fun 'bouy@other':'foo'/1`.

## 5. Expressions

| TypeScript                                   | Erlang                                                                                                                                                       |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `a + b`                                      | `bouy_rt:add(A, B)`: number addition, or string concatenation when either side is a string                                                                   |
| `a - b`, `a * b`, `a / b`, `a % b`, `a ** b` | `bouy_rt:sub/2`, `mul/2`, `divide/2`, `remainder/2`, `power/2`                                                                                               |
| `-a`, `+a`                                   | `bouy_rt:negate/1`, `bouy_rt:to_number/1`                                                                                                                    |
| `&`, `\|`, `^`, `~`, `<<`, `>>`, `>>>`       | `bouy_rt:bit_and/2`, `bit_or/2`, `bit_xor/2`, `bit_not/1`, `shift_left/2`, `shift_right/2`, `shift_right_unsigned/2`, on 32-bit integers as in JavaScript    |
| `a === b`, `a == b`                          | `bouy_rt:strict_eq/2`, `bouy_rt:loose_eq/2`. Numbers compare by value. `loose_eq(null, undefined)` is true.                                                  |
| `a !== b`, `a != b`                          | `not bouy_rt:strict_eq(A, B)`, `not bouy_rt:loose_eq(A, B)`                                                                                                  |
| `<`, `<=`, `>`, `>=`                         | `bouy_rt:lt/2`, `le/2`, `gt/2`, `ge/2`: numbers by value, strings by code point                                                                              |
| `!a`                                         | `not bouy_rt:truthy(A)`                                                                                                                                      |
| `a && b`, `a \|\| b`                         | a `case` on `bouy_rt:truthy(A)` with `A` bound once. `b` runs only when the result needs it.                                                                 |
| `a ?? b`                                     | `case A of null -> B; undefined -> B; _ -> A end`                                                                                                            |
| `c ? a : b`                                  | `case bouy_rt:truthy(C) of true -> A; false -> B end`                                                                                                        |
| `typeof a`                                   | `bouy_rt:type_of/1`                                                                                                                                          |
| `a instanceof C`                             | `bouy_rt:instance_of(A, C)`                                                                                                                                  |
| `k in o`                                     | `bouy_rt:has(O, K)`                                                                                                                                          |
| `` `x ${y}` ``                               | `bouy_rt:concat([<<"x ">>, Y])`. `concat/1` applies `bouy_rt:to_string/1` to each part.                                                                      |
| `o.p`, `o[k]`                                | `bouy_rt:get(O, <<"p">>)`, `bouy_rt:get(O, K)`                                                                                                               |
| `o?.p`, `f?.()`                              | a `case` that yields `undefined` when the value is `null` or `undefined`                                                                                     |
| `{ a, b: 1, ...c }`                          | `bouy_rt:object([...])` of `{Key, Value}` pairs and `{'$spread', C}` entries, applied in order. An object literal without spreads compiles to a map literal. |
| `const { a, b: [c] = [], ...r } = o`         | `bouy_rt:get/2` for each key, defaults through `case`, and `bouy_rt:object_rest/2` and `bouy_rt:array_rest/2` for rest elements                              |
| `[x, ...y]`                                  | `bouy_rt:array([...])` of `{'$item', X}` and `{'$spread', Y}` entries. An array literal without spreads compiles to a list.                                  |
| `r.m(args)`                                  | section 6                                                                                                                                                    |
| `new C(args)`                                | `Module:new(Args)` for a global namespace such as `Map`, and `Module:'C#new'(Args)` for an error class value `{'$class', Module, <<"C">>}`                   |
| `await e`                                    | `E`. Every call blocks until its result is ready, so `await` changes nothing.                                                                                |

## 6. Mutation and methods

- `let` and reassignment compile to new single-assignment variables (`Count@1`, `Count@2`).
- A place is a local variable, `this`, or a chain of property reads from one of them: `x`, `x.a.b`, `x[i]`, `this.#items`, `this.#state.users`.
- `place = v`, `place += v`, `place++`, and `delete place.k` read the chain, compute the new value, and write it back from the innermost key outward with `bouy_rt:set(Object, Key, Value)` and `bouy_rt:delete(Object, Key)`. Then the compiler rebinds the root variable. Each key expression runs once.
- `r.m(args)`, where `m` is a mutator name and `r` is a place, compiles to `{Result, R1} = bouy_rt:mutate(R, <<"m">>, Args)`. The compiler writes `R1` back to the place, and the expression yields `Result`. The mutator names are `push`, `pop`, `shift`, `unshift`, `splice`, `sort`, `reverse`, `fill`, `copyWithin`, `set`, `add`, `delete`, `clear`.
- Any other method call `r.m(args)` compiles to `bouy_rt:call_method(R, <<"m">>, Args)`, which returns the result only.
- `this.m(args)` inside a class method compiles to a direct call `'C#m'(This, Args)`. The call returns `{Result, This1}`, and the compiler rebinds `This`.
- `call_method/3` and `mutate/3` dispatch on the receiver: a list goes to `bouy_array`, a binary to `bouy_string`, a number to `bouy_number`, `{'$map', _}` to `bouy_map`, `{'$set', _}` to `bouy_set`, a ref or a `{'$cast', Id}` to `bouy_actor`, `{'$namespace', M}` to `M:'m'(Args)`, an Effect to `bouy_effect` (for `pipe`), an error map to `bouy_error`, and another map to the function in its property `m`.

## 7. Statements and control flow

Section 12 describes the lowering.

- `if`, `else`, `switch`, conditional expressions, and the logical operators branch with `case`.
- `for`, `while`, `do...while`, `for...of`, and `for...in` compile to named recursive funs. A loop in an actor stays preemptible, because the BEAM scheduler preempts every process after a budget of reductions.
- `throw e` compiles to `erlang:error({'$throw', E})`.
- `try`/`catch`/`finally` compiles to `try ... catch error:Reason:Stack -> E = bouy_rt:caught(Reason, Stack), ... after ... end`. `caught/2` turns `{'$throw', V}` into `V`. It turns an Erlang runtime error (`badarith`, `badarg`, `function_clause`, `{badmatch, _}`, `{case_clause, _}`, `undef`) into an error value named `TypeError`. The `throw` class is reserved for Effect failures (section 13), so a `catch` does not catch them.
- `async` functions compile like other functions. A BEAM process can block, so a call returns when its result is ready.
- `Promise.all([e1, e2, ...])` compiles each element to a thunk and runs the thunks in parallel processes: `bouy_task:all([fun() -> E1 end, ...])`. `Promise.all(xs.map(f))` compiles to `bouy_task:map(Xs, F)`. `Promise.allSettled` and `Promise.race` compile the same way to `bouy_task:all_settled/1` and `bouy_task:race/1`. The results keep the input order. When a thunk throws, the call throws the first error in input order, after every other thunk ends.

## 8. The `bouy` module

`import { ... } from "bouy"` imports from the Erlang module `bouy`. Each function takes the argument list.

| TypeScript                                                    | Behavior                                                                                                           |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `spawn(Class, { args?, name?, mailbox?, restart? })`          | Starts an actor under the root supervisor and returns its ref.                                                     |
| `ref.method(...args)`                                         | A call: sends a request and waits for the reply.                                                                   |
| `cast(ref).method(...args)`                                   | Sends a request without a reply. Returns `true`, or throws `MailboxFull`.                                          |
| `stop(ref)`                                                   | Stops the actor at once, also during a turn. Its waiting callers get `ActorStopped`.                               |
| `inspect()`                                                   | An array of `{ id, name, class, status, restarts, mailbox, memory }`.                                              |
| `supervise({ strategy?, maxRestarts?, withinMs?, children })` | Starts a supervisor with one child for each entry of `children`, and returns an object of refs with the same keys. |
| `child(Class, { args?, restart?, mailbox? })`                 | A child specification for `supervise`.                                                                             |
| `schedule(ref, { every } \| { after }, method, ...args)`      | Casts `method` to the actor once after `after` ms, or every `every` ms. Returns a handle for `cancelSchedule`.     |
| `sleep(ms)`                                                   | Blocks the calling process.                                                                                        |
| `withTimeout(ms, fn)`                                         | Runs `fn` in a new process. When `ms` passes first, it kills that process and throws `CallTimedOut`.               |
| `self(this)`                                                  | Inside an actor method: the ref of the actor.                                                                      |

Actor semantics:

- An actor is a `gen_server` (`bouy_actor`) whose state holds the class and `This`. `init/1` runs `'C#new'/1`. A call runs `'C#dispatch'/3` and replies with the result.
- A turn is one call or one cast. The process handles one message at a time, so turns never interleave.
- Identity: an id is a positive integer. The ETS table `bouy_actors` maps an id to the current pid, the name, the class, the restart count, and the mailbox policy. A restart keeps the id, so a ref stays valid after a restart.
- A thrown error in a turn: the actor replies `ActorFailed` to the caller and exits. `ActorFailed` is an error value with `_tag` `"ActorFailed"`, the actor name, and the original error as `cause`. The supervisor restarts the actor with a new `This` from `'C#new'/1` and the original arguments. Messages in the mailbox of the failed process are lost, and their callers get `ActorStopped`. This is the BEAM model.
- A method that returns an Effect: the actor runs the Effect in the same turn. A success replies the value. A typed failure replies the failure, the caller throws it, and the actor keeps its state. A defect crashes the actor.
- Mailbox (`mailbox: { capacity?: number, overflow?: "backpressure" | "reject" }`, default capacity 1024 with `backpressure`): before a send, `bouy_actor` reads the length of the message queue. With `reject`, a full mailbox throws `MailboxFull`. With `backpressure`, a cast to a full mailbox becomes a call, so the sender waits until the actor takes the message. A call always waits. So the mailbox holds at most the capacity plus one message for each blocked sender.
- Call cycles: a call carries the chain of actor ids that wait on it. A call to an actor in its own chain throws `CallCycle` instead of a deadlock.
- Supervision maps to OTP. `"one-for-one"`, `"one-for-all"`, and `"rest-for-one"` map to the OTP strategies of the same names. `maxRestarts` and `withinMs` (default 3 in 5000) map to `intensity` and `period`. The restart types are `"permanent"`, `"transient"` (the default), and `"temporary"`. A top-level `spawn` runs under `bouy_root_sup` with one supervisor for each actor, so a crashing actor cannot use up the restart budget of another actor.
- A crash prints one line to stderr: `bouy: <class> <name or #id> crashed: <name>: <message>`.

## 9. Classes

A class without `extends` is an actor class. `new` on an actor class is error `BOUY203`. Use `spawn`.

- `'C#new'(Args) -> This` binds the constructor parameters, runs the field initializers in order, runs the constructor body, and returns `This`. `This` is a map from field key to value. A private field `#x` has the key `<<"#x">>`. A public field `x` has the key `<<"x">>`.
- `'C#dispatch'(Method :: binary(), This, Args) -> {Result, This1}` has one clause for each public method. Another name throws `TypeError: <class>.<method> is not a function`.
- `'C#m'(This, Args) -> {Result, This1}` exists for each method, private methods included.
- `'C#streams'() -> [binary()]` returns the names of the `async *` methods.

A class with `extends Error`, `extends Data.TaggedError("Tag")`, or `extends Data.Error` is an error class. `new E(args)` compiles to `'E#new'(Args)`, which builds an error value with `name` set to the class name, and with `_tag` for a tagged error. An error class may declare `readonly` fields without initializers, and nothing else.

## 10. The Bouy subset

The compiler rejects each of these with a code, a position, and a message that names the alternative:

| Code    | Rule                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| BOUY201 | An import of a module that is neither relative nor a library in section 11                                                                                                                                                                                                                                                                                                                                                 |
| BOUY202 | A module-level `let` or `var`, or a module-level value that changes after initialization                                                                                                                                                                                                                                                                                                                                   |
| BOUY203 | `new` on an actor class                                                                                                                                                                                                                                                                                                                                                                                                    |
| BOUY205 | A closure that rebinds a variable of an enclosing function or `this` (an assignment, an update, or a mutator call), for example `items.forEach((i) => { total += i; })`. Also a closure that reads a variable, or `this`, that the enclosing function rebinds after the closure is created, or anywhere in a loop that encloses the closure. An Erlang fun copies the values it captures, so it cannot see a later change. |
| BOUY206 | Syntax with no BEAM lowering: `var`, `eval`, `with`, `arguments`, getters and setters, labeled statements, `switch` fall-through between non-empty cases, generators other than `Effect.gen` bodies and `async *` methods, class inheritance other than error classes, static class members, `.then()`/`.catch()`/`.finally()` chains, `new Promise`, decorators, enums, namespaces, and `import()`                        |
| BOUY207 | `setTimeout`, `setInterval`, `setImmediate`, `queueMicrotask`, `globalThis`, and any use of `process` other than reading `process.env.NAME` and `process.argv`                                                                                                                                                                                                                                                             |

Types are erased. Bouy does not check types.

## 11. Libraries

A library import compiles to calls to an Erlang module. The compiler holds the table below in `crates/bouy-compiler/src/library.rs`. An import of a name that is not in the table is error `BOUY201`.

| Specifier                                 | Export                                                            | Erlang                          |
| ----------------------------------------- | ----------------------------------------------------------------- | ------------------------------- |
| `bouy`                                    | each function                                                     | `bouy:<name>/1`                 |
| `effect`                                  | `Effect`                                                          | namespace `bouy_effect`         |
| `effect`                                  | `Data`                                                            | namespace `bouy_data`           |
| `effect`                                  | `Schedule`                                                        | namespace `bouy_schedule`       |
| `effect`                                  | `Schema`                                                          | namespace `bouy_schema`         |
| `effect`                                  | `Console`                                                         | namespace `bouy_effect_console` |
| `effect`                                  | `Duration`                                                        | namespace `bouy_duration`       |
| `effect`                                  | `pipe`                                                            | `bouy_effect:pipe/1`            |
| `effect/Effect`, `effect/Data`, and so on | the namespace import                                              | the same namespace              |
| `ai`                                      | `generateText`, `streamText`, `tool`, `stepCountIs`, `jsonSchema` | `bouy_ai:<name>/1`              |
| `@ai-sdk/openai`                          | `openai`, `createOpenAI`                                          | `bouy_ai_openai:<name>/1`       |

Globals use the same mechanism: `console` → `bouy_console`, `Math` → `bouy_math`, `JSON` → `bouy_json`, `Object` → `bouy_object`, `Array` → `bouy_array`, `Number` → `bouy_number`, `String` → `bouy_string`, `Date` → `bouy_date`, `Promise` → `bouy_task`, `Error`/`TypeError`/`RangeError` → `bouy_error`, `Map` → `bouy_map`, and `Set` → `bouy_set`. `parseInt`, `parseFloat`, `isNaN`, and `isFinite` compile to `bouy_number` functions, and `structuredClone` compiles to `bouy_rt:structured_clone/1`. `process.env.NAME` compiles to `bouy_rt:env(<<"NAME">>)`, and `process.argv` compiles to `bouy_rt:argv()`.

The namespace module contract:

- `Ns.f(args)` compiles to the remote call `Module:'f'(Args)`.
- `Ns.x` that is not called compiles to `Module:'$member'(<<"x">>)`, which returns a constant or `fun Module:'x'/1`.
- `new Ns(args)` compiles to `Module:new(Args)`.
- Each type module (`bouy_array`, `bouy_string`, `bouy_number`, `bouy_map`, `bouy_set`, `bouy_error`) also exports `call(Name :: binary(), Receiver, Args) -> Result` for its methods and `get(Receiver, Key) -> Value` for its properties, such as `length` and `size`. A module with mutators exports `mutate(Name, Receiver, Args) -> {Result, Receiver1}`. `mutate/3` on a name that is not a mutator returns `{call(Name, Receiver, Args), Receiver}`.

## 12. Lowering control flow

The compiler keeps a map from each oxc `SymbolId` to the Erlang name of its current version. An assignment creates a new version. A construct that rebinds variables declared outside it returns their new versions, and the code after the construct binds them.

A statement completes normally, or it completes abruptly through `return`, `break`, or `continue`. A `throw` is an Erlang exception, so it needs no completion. Each lowered block knows its frame:

- In the top-level sequence of a function body, `return e` becomes the final expression `E`, and falling off the end yields `undefined`.
- An `if` or `switch` whose branches all complete normally is an expression that yields the tuple of the variables it rebinds: `{X@2, Y@1} = case ... end`.
- An `if` or `switch` with an abrupt branch yields a tagged completion: `{next, {X@2, Y@1}}`, `{return, V}`, `{break, State}`, or `{continue, State}`. The compiler lowers the code after the construct once, inside the `{next, ...}` clause of a `case` on the completion. The other clauses forward the completion to the enclosing frame. In a function frame, `{return, V}` yields `V`.
- A loop is a named fun over a state tuple of the variables that the loop rebinds: `Loop = fun Loop({I, Sum}) -> ... end`. Falling through and `continue` run the update expression and call `Loop` with the new state. `break` yields `{break, State}`. `return e` yields `{return, V}`. After the loop, a `case` binds the state from `{break, State}` and forwards `{return, V}`.
- A `try` block that rebinds outer variables yields the tuple of the rebound variables from both the body and the handler.

A pre-pass over the subtree of a construct finds the variables it rebinds. They are the targets of every write reference to a symbol declared outside the subtree, plus the root variable of every place that a mutation or a mutator call writes (section 6). `this` counts as the variable `This`.

## 13. The Effect subset (`effect`)

| TypeScript                                                                                                                                               | Runtime                                                                    |
| -------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `Effect.succeed`, `fail`, `sync`, `try`, `promise`, `tryPromise`, `void`, `die`                                                                          | `bouy_effect` functions of the same names                                  |
| `Effect.gen(function* () { ... })`, `Effect.fn("name")(function* (...) { ... })`                                                                         | a compiled body, described below                                           |
| `Effect.map`, `flatMap`, `andThen`, `tap`, `catch`, `catchTag`, `catchTags`, `mapError`, `orElseSucceed`, `result`, `match`, `ensuring`, `asVoid`, `zip` | `bouy_effect` functions, in data-first and data-last forms as in Effect    |
| `Effect.all(effects, { concurrency })`, `Effect.forEach(items, f, { concurrency })`                                                                      | parallel processes when `concurrency` is a number above 1 or `"unbounded"` |
| `Effect.sleep(duration)`, `Effect.timeout(effect, duration)`, `Effect.retry(effect, policy)`, `Effect.race`                                              | `bouy_effect` on BEAM processes and timers                                 |
| `Effect.runPromise(e)`, `Effect.runSync(e)`                                                                                                              | Runs `e`. A failure throws the failure value.                              |
| `effect.pipe(f, g)`, `pipe(x, f, g)`                                                                                                                     | Applies the functions in order.                                            |
| `Schedule.recurs`, `spaced`, `exponential`, `fixed`                                                                                                      | `bouy_schedule`                                                            |
| `Data.TaggedError("Tag")` classes                                                                                                                        | error classes (section 9)                                                  |
| `Console.log`                                                                                                                                            | `bouy_effect_console:log/1`, which returns an Effect                       |
| `Schema.Struct`, `String`, `Number`, `Boolean`, `Literal`, `Array`, `optional`, `Union`, `decodeUnknownSync`, `decodeUnknownEffect`, `is`                | `bouy_schema`                                                              |

The `Effect.gen` lowering compiles the generator body to a fun. In the body, `yield* e` compiles to `bouy_effect:bind(E)`. `bind/1` runs the Effect and returns the success value, or it ends the body with `erlang:throw({'$fail', Error})`. The wrapper is `{'$effect', fun() -> try {ok, Body()} catch throw:{'$fail', Error} -> {error, Error} end end}`. A JavaScript `try`/`catch` in the body does not catch a failure, because `catch` lowers to the `error` class only. This matches Effect, where a failure is a value and not an exception.

## 14. `ai` and `@ai-sdk/openai`

`generateText({ model, prompt?, system?, messages?, tools?, stopWhen? })`, `streamText(...)`, `tool({ description, inputSchema, execute })`, `stepCountIs(n)`, `openai(modelName)`, and `createOpenAI({ baseURL?, apiKey? })` call an OpenAI-compatible Chat Completions endpoint through OTP `httpc` and `json`. `OPENAI_API_KEY` and `OPENAI_BASE_URL` give the defaults. `runtime/test/bouy_fake_openai.erl` serves fixed responses for the tests and the examples.

## 15. Tests and benchmarks

- `crates/bouy-compiler/tests`: snapshot tests of the generated Erlang for each construct in sections 5 to 13.
- `tests/conformance/*.ts`: programs that use only language features and globals. A Rust test runs each program with `node` (the oracle) and with `bouy run`, and asserts that the two outputs are equal.
- `runtime/test`: EUnit tests for the runtime modules (`rebar3 eunit` in `runtime/`).
- `crates/bouy-cli/tests`: end-to-end tests that run `bouy run` on the programs in `tests/programs/` and check stdout, stderr, and the exit status: fault isolation, state isolation, ordering, supervision, cancellation, bounded mailboxes, streams, load, and fairness.
- `tests/equivalence/*.ts`: Effect and AI programs that run with `node` and the real npm packages, and with `bouy run`. The outputs must be equal.
- `bench/`: each suite runs a Bouy program and an equivalent plain Node program, and records both results.

## 16. Runtime helper index

Generated code calls only the functions in this section, the library functions of section 11, and the class and module functions of sections 2 and 9. Every function below is exported and has a `-spec`.

`bouy_rt`, the value core:

| Function                                                                                                     | Use                                                                                                              |
| ------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| `arg(N, Args)`, `rest(N, Args)`                                                                              | Parameters (section 4)                                                                                           |
| `call(F, Args)`                                                                                              | A call of a function value                                                                                       |
| `call_method(R, Name, Args)`, `mutate(R, Name, Args)`                                                        | Method calls (section 6)                                                                                         |
| `add/2`, `sub/2`, `mul/2`, `divide/2`, `remainder/2`, `power/2`, `negate/1`, `to_number/1`                   | Arithmetic                                                                                                       |
| `bit_and/2`, `bit_or/2`, `bit_xor/2`, `bit_not/1`, `shift_left/2`, `shift_right/2`, `shift_right_unsigned/2` | Bitwise operators                                                                                                |
| `strict_eq/2`, `loose_eq/2`, `lt/2`, `le/2`, `gt/2`, `ge/2`                                                  | Comparison                                                                                                       |
| `truthy/1`, `type_of/1`, `instance_of/2`, `has/2`                                                            | Tests                                                                                                            |
| `to_string/1`, `concat/1`                                                                                    | String conversion and template literals                                                                          |
| `get(O, Key)`, `set(O, Key, V)`, `delete(O, Key)`                                                            | Property access. `set/3` and `delete/2` return the new object.                                                   |
| `object(Entries)`, `array(Entries)`                                                                          | Literals with spreads (section 5)                                                                                |
| `object_rest(O, Keys)`, `array_rest(List, N)`                                                                | Rest elements in destructuring: the object without `Keys`, and the list from index `N`                           |
| `to_list(V)`                                                                                                 | The items that `for...of` and `...v` visit: list items, string code points, `[K, V]` pairs of a Map, Set members |
| `keys(V)`                                                                                                    | The keys that `for...in` visits                                                                                  |
| `caught(Reason, Stack)`                                                                                      | The value that a `catch` clause binds (section 7)                                                                |
| `env(Name)`, `argv()`, `structured_clone(V)`                                                                 | `process.env.NAME`, `process.argv`, `structuredClone`                                                            |

`bouy_error`, errors for every runtime module:

| Function                                                                          | Use                                                                                                                                                                                |
| --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `new(Name, Message)`, `new(Name, Message, Fields)`                                | Builds an error value. `Fields` is a map of extra own fields, such as `_tag` or `cause`.                                                                                           |
| `throw(Name, Message)`, `throw(Name, Message, Fields)`                            | Raises `erlang:error({'$throw', new(...)})`.                                                                                                                                       |
| `'Error#new'/1`, `'TypeError#new'/1`, `'RangeError#new'/1`, `'SyntaxError#new'/1` | The global error classes. The class value of `TypeError` is `{'$class', bouy_error, <<"TypeError">>}`, so `new` and `instanceof` treat global and user error classes the same way. |

`bouy_actor`, called from `bouy_rt` dispatch: `call(Ref, Name, Args) -> Result` and `cast({'$cast', Id}, Name, Args) -> true`.

`bouy_main`: `start/0` boots a program (section 1), and `import(Module)` runs the top-level code of `Module` once.
