# Bouy on BEAM: the compiler and runtime contract

Status: the working contract for the BEAM runtime, 2026-10-16. It replaces the "now" decision of ADR 0001. Bouy no longer runs on Node, Bun, or V8, and the product has no Node or V8 dependency. Node appears only as a test oracle and as a benchmark baseline.

This file is the contract between the compiler (`crates/bouy-compiler`), the CLI (`crates/bouy-cli`), and the runtime (`runtime/`). Every name in this file is normative. A change to a name changes this file in the same commit.

## 1. Pipeline

`bouy run app.ts [args...]`:

1. The CLI resolves the module graph from the entry module. It follows relative imports (`./x.ts`, `./x.js`, `./x`, `./dir/index.ts`) and library imports (section 11). Any other import is error `BOUY201`.
2. The compiler parses each module with oxc, runs oxc semantic analysis, checks the Bouy subset (section 10), and lowers the module to one Erlang source file.
3. The CLI writes the Erlang files to `<project>/.bouy/build/src/`. The project root is the nearest ancestor directory of the entry that holds a `package.json`, or else the entry's directory.
4. The CLI starts one VM: `erl -noshell -noinput -pa <runtime ebin> -eval "bouy_main:start()" -extra <build dir> <entry module> <entry path> <module,module,...> [args...]`. `bouy_main:start/0` reads these arguments with `init:get_plain_arguments/0`. It compiles each listed module whose source changed in the VM with `compile:file/2`, writes the `.beam` file and an MD5 stamp of the source to `.bouy/build/ebin/` through a temporary file and a rename, loads the module, starts the runtime (section 8), runs the entry module, and halts. One VM start serves both compilation and execution. Generated code that does not compile is a compiler bug: `bouy_main` prints the errors of `compile:file/2` and halts with status 2. Any other failure before the program runs, such as a build directory that is not writable, prints `bouy: cannot start the program: <reason>` and halts with status 1, so the VM leaves no `erl_crash.dump`.
5. The program ends when the top-level code of the entry module returns. Then the runtime stops every actor and halts with status 0. An uncaught error in top-level code prints `Uncaught <name>: <message>` to stderr and halts with status 1. A compile diagnostic prints `<path>:<line>:<column>: <code>: <message>` to stderr, and the CLI exits with status 2 before it starts the VM. An entry path that is not a file prints `bouy: cannot find the file <path>` and exits with status 2. The CLI exits with the status of the VM, or with 128 plus the signal number when a signal ends the VM, as a shell reports it.

The CLI embeds the runtime sources, `runtime/src/*.erl`, `*.hrl`, and `bouy.app.src`, through `crates/bouy-cli/build.rs`. On the first run, the CLI writes them to `$XDG_CACHE_HOME/bouy/runtime-<hash>/src/` (default `~/.cache/bouy/runtime-<hash>/`) and compiles them into `runtime-<hash>/ebin/` with `erlc`, with `bouy.app.src` copied to `ebin/bouy.app`. It builds in a private directory and renames it into place, so concurrent first runs are safe. The hash is FNV-1a over the embedded file names and contents. The installed OTP compiles the runtime, so the `.beam` files always match the installed OTP release. `BOUY_RUNTIME=<dir>` names a directory of compiled runtime `.beam` files that replaces the cache, for development. The CLI finds `erl` on `PATH`, or uses `BOUY_ERL`, and finds `erlc` next to `BOUY_ERL` or on `PATH`.

`process.argv` is the list of binaries `[<<"bouy">>, EntryPath | Args]`, so `process.argv.slice(2)` is the program arguments, as in Node. `bouy_main:start/0` stores it in `persistent_term` under `{bouy, argv}`, and `bouy_rt:argv()` reads it. `bouy_main:start/0` also sets `standard_io` and `standard_error` to `{encoding, unicode}`, so output is UTF-8 under any locale, as with Node.

`bouy check app.ts` runs steps 1 and 2 and prints diagnostics. `bouy build app.ts` runs steps 1 to 3 and prints the paths of the Erlang files. Both exit with status 2 when there is a diagnostic.

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
| `Map<K, V>`                          | `{'$map', {Index, Next}}`. `Index` maps each key to `{Sequence, Value}`, and `Next` is the next sequence number. Iteration sorts by sequence, so entries keep insertion order. Equal numbers share one key: `1.0` is stored as `1`, `-0.0` as `0`.    |
| `Set<T>`                             | `{'$set', {Index, Next}}`. `Index` maps each member to its sequence number, and `Next` is the next sequence number. Members keep insertion order, and equal numbers share one member as in `Map`.                                                     |
| `Date`                               | `{'$date', Ms :: integer() \| 'NaN'}`: milliseconds since the epoch, or `'NaN'` for an invalid date                                                                                                                                                   |
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
- Integers have arbitrary precision. `2 ** 53 + 1` is exact. Text still converts as JavaScript converts it: `Number(s)`, `parseInt`, `parseFloat`, and `JSON.parse` give the nearest double beyond 2^53.
- An integer has no negative zero, so `0 * -1` is `0` where JavaScript has `-0`. Float operations and `Math.round`, `floor`, `ceil`, and `trunc` keep `-0.0`.
- `console.log` prints an error as `Name: message` and its own fields, without stack frames.
- Bouy has no regular expressions. A string method throws a `TypeError` for a pattern that is not a string.
- `localeCompare` compares code points. `toUpperCase` and `toLowerCase` use the Unicode case mapping without the final-sigma rule.
- `Date` supports `Date.now()`, `new Date()`, `new Date(ms)`, `new Date(isoString)`, `getTime`, `valueOf`, `toISOString`, `toJSON`, and `toString`, all in UTC. Other members throw a `TypeError`.
- `JSON.parse` error messages match V8 for an unexpected token and for the end of input only.
- `Math` functions and `parseInt` beyond 2^53 reproduce V8 on arm64, where the compiler fuses `a * b + c` into one rounding. On x86-64, Node can differ from Bouy in the last bit.

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
- A place is a local variable, `this`, or a chain of property reads from one of them: `x`, `x.a.b`, `x[i]`, `this.#items`, `this.#state.users`. An actor ref is not a place, so `ref.add(x)` is an actor call (`bouy_rt:call_method/3`) and not a `Set` mutation. The compiler knows that a value is a ref in two cases. The first is a `const` whose initializer is `spawn(...)` or `supervise(...)` from `bouy`. The second is a variable, a parameter, or a class field whose declared type is `Ref<C>` from `bouy`, alone or in a union with `undefined` and `null`, such as `store: Ref<Store>` or `#peer?: Ref<Peer>`. The type of a field applies to `this.<field>` inside the class that declares it. A library namespace is not a place either.
- `x++` and `++x` compile to `X1 = bouy_rt:sub(X, -1)`, which converts `X` with ToNumber as JavaScript does. When the old value of `x++` is used, it is `T = bouy_rt:to_number(X)` and `X1 = bouy_rt:add(T, 1)`.
- `place = v`, `place += v`, `place++`, and `delete place.k` read the chain, compute the new value, and write it back from the innermost key outward with `bouy_rt:set(Object, Key, Value)` and `bouy_rt:delete(Object, Key)`. Then the compiler rebinds the root variable. Each key expression runs once.
- `r.m(args)`, where `m` is a mutator name and `r` is a place, compiles to `{Result, R1} = bouy_rt:mutate(R, <<"m">>, Args)`. The compiler writes `R1` back to the place, and the expression yields `Result`. The mutator names are `push`, `pop`, `shift`, `unshift`, `splice`, `sort`, `reverse`, `fill`, `copyWithin`, `set`, `add`, `delete`, `clear`.
- Any other method call `r.m(args)` compiles to `bouy_rt:call_method(R, <<"m">>, Args)`, which returns the result only.
- `this.m(args)` inside a class method compiles to a direct call `'C#m'(This, Args)`. The call returns `{Result, This1}`, and the compiler rebinds `This`. A method that never rebinds `this`, directly or through such a call, leaves `This` as it was, so a call to it compiles to `erlang:element(1, 'C#m'(This, Args))` and does not rebind `This`. A closure may call such a method (section 10, `BOUY205`).
- `call_method/3` and `mutate/3` dispatch on the receiver. A list goes to `bouy_array`, a binary to `bouy_string`, a number to `bouy_number`, `{'$map', _}` to `bouy_map`, `{'$set', _}` to `bouy_set`, `{'$date', _}` to `bouy_date`, and an error map to `bouy_error`, each through the `call/3` or `mutate/3` of that type module (section 11). A ref goes to `bouy_actor:call(Ref, <<"m">>, Args)`, and a `{'$cast', Id}` to `bouy_actor:cast/3`. `{'$namespace', M}` calls the function that `M:'$member'(<<"m">>)` returns. An Effect goes to `bouy_effect:call(<<"m">>, Effect, Args)` (for `pipe`). Another map calls the function in its property `m`, or else `hasOwnProperty`, `toString`, or `valueOf` as `Object.prototype` defines them. A function supports `call`, `apply`, and `bind`.

## 7. Statements and control flow

Section 12 describes the lowering.

- `if`, `else`, `switch`, conditional expressions, and the logical operators branch with `case`.
- `for`, `while`, `do...while`, `for...of`, and `for...in` compile to named recursive funs. A loop in an actor stays preemptible, because the BEAM scheduler preempts every process after a budget of reductions.
- `throw e` compiles to `erlang:error({'$throw', E})`.
- `try`/`catch`/`finally` compiles to `try ... catch error:Reason:Stack -> E = bouy_rt:caught(Reason, Stack), ... after ... end`. `caught/2` turns `{'$throw', V}` into `V`. It turns an Erlang runtime error (`badarith`, `badarg`, `function_clause`, `{badmatch, _}`, `{case_clause, _}`, `undef`) into an error value named `TypeError`. The `throw` class is reserved for Effect failures (section 13), so a `catch` does not catch them.
- An Erlang exception drops the bindings of the code that raised it, but JavaScript's `catch` and `finally` see the variables as the `try` body left them. So a `try` that rebinds outer variables, and has a `catch` or a `finally` that reads them, records them: `Key = erlang:make_ref()` and `erlang:put(Key, {Vars})` before the `try`, `erlang:put(Key, {Vars})` after each statement of the body or handler that changes one, `{Vars} = erlang:get(Key)` at the start of the handler and of the `after` block, and `erlang:erase(Key)` in `after`. The key is a fresh ref for each run of the `try`, so recursion and actors cannot mix records.
- A `finally` block that rebinds outer variables cannot be an `after` block, because `after` exports no bindings. Its statements run after the `try`: `Outcome = try {done, try Body catch error:R:S -> Handler end} catch C:R:S -> {raised, C, R, S} end`, then `{Vars} = erlang:get(Key)`, the `finally` statements, and `erlang:raise(C, R, S)` for `{raised, ...}`. A `return`, `break`, or `continue` of the body or handler is rebuilt from the versions that the `finally` statements leave. A `finally` block that itself returns or jumps is error `BOUY206`.
- `async` functions compile like other functions. A BEAM process can block, so a call returns when its result is ready.
- `Promise.all([e1, e2, ...])` compiles each element to a thunk and runs the thunks in parallel processes: `bouy_task:all([fun() -> E1 end, ...])`. `Promise.all(xs.map(f))` compiles to `bouy_task:map(Xs, F)`. `Promise.allSettled` and `Promise.race` compile the same way to `bouy_task:all_settled/1` and `bouy_task:race/1`, and over `xs.map(f)` to `bouy_task:map_settled(Xs, F)` and `bouy_task:map_race(Xs, F)`. The results keep the input order. When a thunk throws, the call throws the first error in input order, after every other thunk ends. `Promise.resolve(v)` and `Promise.reject(e)` follow the namespace rule (section 11) to `bouy_task:resolve/1`, which returns `v`, and `bouy_task:reject/1`, which throws `e`.

## 8. The `bouy` module

`import { ... } from "bouy"` imports from the Erlang module `bouy`. Each function takes the argument list.

| TypeScript                                                    | Behavior                                                                                                           |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `spawn(Class, { args?, name?, mailbox?, restart? })`          | Starts an actor under the root supervisor and returns its ref.                                                     |
| `ref.method(...args)`                                         | A call: sends a request and waits for the reply.                                                                   |
| `cast(ref).method(...args)`                                   | Sends a request without a reply. Returns `true`, or throws `MailboxFull` or `ActorStopped`.                        |
| `stop(ref)`                                                   | Stops the actor at once, also during a turn. Its waiting callers get `ActorStopped`.                               |
| `inspect()`                                                   | An array of `{ id, name, class, status, restarts, mailbox, memory }`.                                              |
| `supervise({ strategy?, maxRestarts?, withinMs?, children })` | Starts a supervisor with one child for each entry of `children`, and returns an object of refs with the same keys. |
| `child(Class, { args?, restart?, mailbox? })`                 | A child specification for `supervise`: `{'$child', Class, Options}`.                                               |
| `schedule(ref, { every } \| { after }, method, ...args)`      | Casts `method` to the actor once after `after` ms, or every `every` ms. Returns the handle `{'$schedule', Pid}`.   |
| `cancelSchedule(handle)`                                      | Stops the timer of a `schedule` handle.                                                                            |
| `sleep(ms)`                                                   | Blocks the calling process.                                                                                        |
| `withTimeout(ms, fn)`                                         | Runs `fn` in a new process. When `ms` passes first, it kills that process and throws `CallTimedOut`.               |
| `self(this)`                                                  | Inside an actor method: the ref of the actor. Elsewhere it throws `Error`.                                         |

Details of the functions:

- When a constructor throws, `spawn` and `supervise` throw `ActorFailed` for the method `constructor`. `supervise` then stops the children that it started.
- `supervise` starts the children in key order. The key is the name of the child.
- After `stop`, every call or cast throws `ActorStopped`. Inside an actor, `stop` returns before the process ends.
- `inspect` lists the actors in id order. `name` is the `name` option or `undefined`. `status` is `"running"`, `"restarting"`, or `"stopped"`. `mailbox` is the length of the message queue, and `memory` is the size of the process in bytes.
- The timer of `schedule` is a process linked to the caller, so it ends with the caller. It also ends when the actor stops. A full mailbox skips one cast.

Actor semantics:

- `bouy_main` starts the runtime with `bouy_app:start(normal, [])`, which needs no `.app` file. `application:ensure_all_started(bouy)` also works when `bouy.app` is on the code path.
- An actor is a `gen_server` (`bouy_actor`) whose state holds the class and `This`. `init/1` runs `'C#new'/1`. A call runs `'C#dispatch'/3` and replies with the result.
- A turn is one call or one cast. The process handles one message at a time, so turns never interleave.
- Identity: an id is a positive integer. The ETS table `bouy_actors` maps an id to the current pid, the name, the class, the restart count, and the mailbox policy. A restart keeps the id, so a ref stays valid after a restart.
- A thrown error in a turn: the actor replies `ActorFailed` to the caller and exits. `ActorFailed` is an error value with `_tag` `"ActorFailed"`, the actor label in `actor`, the method in `method`, and the original error as `cause`. The supervisor restarts the actor with a new `This` from `'C#new'/1` and the original arguments. Messages in the mailbox of the failed process are lost, and their callers get `ActorStopped`. This is the BEAM model. A call that starts after its caller got `ActorFailed` waits for the restart.
- A method that returns an Effect: the actor runs the Effect in the same turn. A success replies the value. A typed failure replies the failure, the caller throws it, and the actor keeps its state. A defect crashes the actor. A typed failure in a cast has no caller, so the actor drops it.
- Mailbox (`mailbox: { capacity?: number, overflow?: "backpressure" | "reject" }`, default capacity 1024 with `backpressure`): before a send, `bouy_actor` reads the length of the message queue. With `reject`, a full mailbox throws `MailboxFull` to a call or a cast. With `backpressure`, a cast to a full mailbox becomes a call, so the sender waits until the actor takes the message. A call always waits. So the mailbox holds at most the capacity plus one message for each blocked sender. A cast to an actor in the call chain of the sender goes in at once, because that actor waits on the sender.
- Call cycles: a call carries the chain of actor ids that wait on it. A call to an actor in its own chain throws `CallCycle` instead of a deadlock. The processes of `bouy_task` and `withTimeout` inherit the chain of their caller.
- Supervision maps to OTP. `"one-for-one"`, `"one-for-all"`, and `"rest-for-one"` map to the OTP strategies of the same names. `maxRestarts` and `withinMs` (default 3 in 5000) map to `intensity` and `period`. OTP counts `period` in whole seconds, so `withinMs` rounds up. The restart types are `"permanent"`, `"transient"` (the default), and `"temporary"`. A crash exits with the reason `{shutdown, crashed}`, and an actor never exits normally, so `"transient"` maps to the OTP type `permanent`. A top-level `spawn` runs under `bouy_root_sup` with one supervisor for each actor, so a crashing actor cannot use up the restart budget of another actor. A supervisor that uses up its budget stops its actors. Their status becomes `"stopped"`, and later calls throw `ActorStopped`.
- A crash prints one line to stderr: `bouy: <class> <name or #id> crashed: <name>: <message>`. The text after `crashed: ` is `String(error)`, so an empty message prints only the name. The runtime drops the OTP supervisor reports of its own supervisors.

The runtime errors are error values (section 3) with the error name in `name` and `_tag`. `<actor>` is the label of the actor, `<class> <name>` or `<class> #<id>`. `<cause>` is `String(cause)`.

| Error          | Own fields                 | `message`                                                                                             |
| -------------- | -------------------------- | ----------------------------------------------------------------------------------------------------- |
| `ActorFailed`  | `actor`, `method`, `cause` | `<actor> failed in <method>: <cause>`                                                                 |
| `ActorStopped` | `actor`                    | `<actor> is stopped`                                                                                  |
| `MailboxFull`  | `actor`                    | `<actor> has a full mailbox`                                                                          |
| `CallCycle`    | `actor`                    | `<actor> is busy with a call that waits on this call. Use cast() or pass the data in the first call.` |
| `CallTimedOut` | `ms`                       | `the call did not finish within <ms> ms`                                                              |

## 9. Classes

A class without `extends` is an actor class. `new` on an actor class is error `BOUY203`. Use `spawn`.

- `'C#new'(Args) -> This` binds the constructor parameters, runs the field initializers in order, runs the constructor body, and returns `This`. `This` is a map from field key to value. A private field `#x` has the key `<<"#x">>`. A public field `x` has the key `<<"x">>`.
- `'C#dispatch'(Method :: binary(), This, Args) -> {Result, This1}` has one clause for each public method. Another name throws `TypeError: <class>.<method> is not a function`.
- `'C#m'(This, Args) -> {Result, This1}` exists for each method, private methods included.
- `'C#streams'() -> [binary()]` returns the names of the `async *` methods.

A class with `extends Error`, `extends Data.TaggedError("Tag")`, or `extends Data.Error` is an error class. `new E(args)` compiles to `'E#new'(Args)`, which builds an error value with `bouy_error:new(<<"E">>, Message, Fields)`: `name` set to the class name, and `_tag` for a tagged error. Without a constructor, `Message` is the first argument as a string (`<<>>` for `undefined`) for `extends Error`, and the `message` field of the first argument for `Data.TaggedError` and `Data.Error`, whose first argument is also `Fields`. An error class may declare `readonly` fields without initializers, which are types only, and fields with initializers, which `'E#new'/1` sets after the error is built. It may also declare a constructor whose first statement is `super(...)`. `super(args)` builds the error from `args` as above, and the rest of the constructor runs with `this` bound to the error, so `this.name = "E"` and `this.field = value` set fields. An error class declares no methods.

The global error classes `Error`, `TypeError`, `RangeError`, and `SyntaxError` are bases of an error class too. `extends` of any other class is error `BOUY206`.

## 10. The Bouy subset

The compiler rejects each of these with a code, a position, and a message that names the alternative:

| Code    | Rule                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| BOUY200 | A syntax error or a semantic error that oxc reports                                                                                                                                                                                                                                                                                                                                                                                                |
| BOUY201 | An import of a module that is neither relative nor a library in section 11                                                                                                                                                                                                                                                                                                                                                                         |
| BOUY202 | A module-level `let` or `var`, or a module-level value that changes after initialization                                                                                                                                                                                                                                                                                                                                                           |
| BOUY203 | `new` on an actor class                                                                                                                                                                                                                                                                                                                                                                                                                            |
| BOUY205 | A closure that rebinds a variable of an enclosing function or `this` (an assignment, an update, or a mutator call), for example `items.forEach((i) => { total += i; })`. Also a closure that reads a variable, or `this`, that the enclosing function rebinds after the closure is created, or anywhere in a loop that encloses the closure and not the declaration. An Erlang fun copies the values it captures, so it cannot see a later change. |
| BOUY206 | Syntax with no BEAM lowering: `var`, `eval`, `with`, `arguments`, getters and setters, labeled statements, `switch` fall-through between non-empty cases, generators other than `Effect.gen` bodies and `async *` methods, class inheritance other than error classes, static class members, `.then()`/`.catch()`/`.finally()` chains, `new Promise`, decorators, enums, namespaces, and `import()`                                                |
| BOUY207 | `setTimeout`, `setInterval`, `setImmediate`, `queueMicrotask`, `globalThis`, and any use of `process` other than reading `process.env.NAME` and `process.argv`                                                                                                                                                                                                                                                                                     |

Types are erased. Bouy does not check types.

## 11. Libraries

A library import compiles to calls to an Erlang module. The compiler holds the table below in `crates/bouy-compiler/src/library.rs`. An import of a name that is not in the table is error `BOUY201`.

| Specifier                                 | Export                                                            | Erlang                          |
| ----------------------------------------- | ----------------------------------------------------------------- | ------------------------------- |
| `bouy`                                    | each function                                                     | `bouy:<name>/1`                 |
| `bouy`                                    | the type `Ref<C>`                                                 | erased; marks a ref (section 6) |
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

Globals use the same mechanism: `console` → `bouy_console`, `Math` → `bouy_math`, `JSON` → `bouy_json`, `Object` → `bouy_object`, `Array` → `bouy_array`, `Number` → `bouy_number`, `String` → `bouy_string`, `Date` → `bouy_date`, `Promise` → `bouy_task`, `Error`/`TypeError`/`RangeError` → `bouy_error`, `Map` → `bouy_map`, and `Set` → `bouy_set`. `parseInt` and `parseFloat` compile to `bouy_number:parseInt/1` and `bouy_number:parseFloat/1`. The global `isNaN` and `isFinite` compile to `bouy_number:'$isNaN'/1` and `bouy_number:'$isFinite'/1`, which convert the argument with ToNumber first, unlike `Number.isNaN` and `Number.isFinite`. `structuredClone` compiles to `bouy_rt:structured_clone/1`. `process.env.NAME` compiles to `bouy_rt:env(<<"NAME">>)`, and `process.argv` compiles to `bouy_rt:argv()`.

The namespace module contract:

- `Ns.f(args)` compiles to the remote call `Module:'f'(Args)`.
- `Ns.x` that is not called compiles to `Module:'$member'(<<"x">>)`, which returns a constant or `fun Module:'x'/1`.
- `new Ns(args)` compiles to `Module:new(Args)`.
- `Ns(args)`, a call of a global constructor as a function such as `String(x)`, `Number(x)`, `Array(n)`, `Object(x)`, or `Date()`, compiles to `Module:'$call'(Args)`. `bouy_rt:call/2` on `{'$namespace', M}` calls `M:'$call'(Args)`, so `xs.map(String)` works.
- Each type module (`bouy_array`, `bouy_string`, `bouy_number`, `bouy_map`, `bouy_set`, `bouy_date`, `bouy_error`) also exports `call(Name :: binary(), Receiver, Args) -> Result` for its methods and `get(Receiver, Key) -> Value` for its properties, such as `length` and `size`. A module with mutators exports `mutate(Name, Receiver, Args) -> {Result, Receiver1}`. `mutate/3` on a name that is not a mutator returns `{call(Name, Receiver, Args), Receiver}`.

## 12. Lowering control flow

The compiler keeps a map from each oxc `SymbolId` to the Erlang name of its current version. An assignment creates a new version. A construct that rebinds variables declared outside it returns their new versions, and the code after the construct binds them.

A statement completes normally, or it completes abruptly through `return`, `break`, or `continue`. A `throw` is an Erlang exception, so it needs no completion. Each lowered block knows its frame:

- In the top-level sequence of a function body, `return e` becomes the final expression `E`, and falling off the end yields `undefined`.
- An `if` or `switch` whose branches all complete normally is an expression that yields the tuple of the variables it rebinds: `{X@2, Y@1} = case ... end`.
- An `if` or `switch` with an abrupt branch yields a tagged completion: `{next, {X@2, Y@1}}`, `{return, V}`, `{break, State}`, or `{continue, State}`. The compiler lowers the code after the construct once, inside the `{next, ...}` clause of a `case` on the completion. The other clauses forward the completion to the enclosing frame. In a function frame, `{return, V}` yields `V`. `State` is the tuple of the variables of the target: the state of a loop, or the variables that a `switch` rebinds.
- Two shapes need no completion. An `if` with an abrupt branch and at most one branch that can reach its end lowers the code after it once, inside that branch, and each jump lowers in place: `case C of true -> V; false -> Rest end` for `if (c) return v; rest`. A `switch` with a `default` whose every case ends in a jump other than `break` is a plain `case` whose clauses lower in place.
- A loop is a named fun over a state tuple of the variables that the loop rebinds: `Loop = fun Loop({I, Sum}) -> ... end`. Falling through and `continue` run the update expression and call `Loop` with the new state. `break` yields `{break, State}`. `return e` yields `{return, V}`. After the loop, a `case` binds the state from `{break, State}` and forwards `{return, V}`. A loop without `return` binds the state directly: `{break, {I@9, Sum@4}} = Loop({I@1, Sum@1})`. The fun of `for...of` and `for...in` also takes the remaining items: `Loop([X | Rest], State)` and `Loop([], State) -> {break, State}`, over `bouy_rt:to_list/1` or `bouy_rt:keys/1` of the right side.
- A `try` block that rebinds outer variables yields the tuple of the rebound variables from both the body and the handler. The handler starts from the recorded versions of section 7.
- A conditional expression or a logical operator whose right side rebinds variables yields `{Value, {Vars}}`. An expression statement `a && f()`, `a || f()`, or `c ? f() : g()` lowers as an `if`.

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
