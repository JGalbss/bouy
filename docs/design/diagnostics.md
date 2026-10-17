# Diagnostics and migration with an agent

Status: design, 2026-10-16. Nothing in this file is built yet. [The contract](beam-runtime.md) stays normative. When a part of this design is built, sections 1, 10, and 15 of the contract change in the same commit.

## 1. Goal

A team moves a Node TypeScript codebase to Bouy with a coding agent, and the compiler guides each step. Each TypeScript construct falls in one of two groups:

- It behaves as it behaves in Node.
- It does not compile. The diagnostic gives a stable code, the cause, and the code to write instead. When the replacement is certain, `bouy fix` writes it.

The worst result is a program that compiles and then prints something different from Node. Section 11 turns the cases that the compiler can see into errors, and lists the cases that need the runtime. Section 12 applies the same rules to `effect` 4.0.5, so an Effect program either compiles or says what must change.

## 2. Rules

Every diagnostic follows these rules. The tests in section 13 check them.

1. A code has one cause and one fix. When one cause has two fixes, it is two codes.
2. The message states the cause in one line. The `help` line states the fix. When the fix is concrete, the help holds the exact code to write.
3. A code has one category. The category tells the agent and the team who acts.

| Category      | Meaning                                                                                  | Who acts                                                                  |
| ------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `invalid`     | The code fails in Node too, such as an import of a name that the module does not export. | The agent fixes the code.                                                 |
| `rejected`    | Valid TypeScript that Bouy rejects by design, because BEAM semantics differ.             | The agent rewrites the code. The rejection is permanent.                  |
| `unsupported` | A language feature that Bouy does not implement yet. An equivalent form exists.          | The agent writes the equivalent form. Bouy can add the feature later.     |
| `missing`     | An API, a module, or a package that Bouy does not provide yet.                           | Bouy adds it. The agent rewrites the code only when the help gives a way. |

4. A fix declares its applicability with the values of rustc.

| Applicability       | Meaning                                                                                                                            | Who writes the fix                |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| `MachineApplicable` | The fix compiles, removes its diagnostic, and adds none. The fixed program under Bouy prints what the original printed under Node. | `bouy fix`                        |
| `MaybeIncorrect`    | The fix suits the usual intent, but the compiler cannot prove it for this program.                                                 | The agent, after it reads the fix |
| `HasPlaceholders`   | The fix holds `/* ... */` placeholders.                                                                                            | The agent, after it fills them in |

5. One cause gives one diagnostic. Code inside a rejected construct reports nothing more when the rewrite of the construct removes that code. For example, the closures in the executor of a rejected `new Promise(...)` get no closure diagnostics.
6. One check reports every diagnostic. An import that fails does not stop the check of its module. The imported names read as unknown values that report nothing more.
7. Codes and names never change meaning, and a retired code is never used again. Message and help text can change, so tools read `code` and `name` and never parse the text.
8. An I/O failure, such as an imported file that exists but cannot be read, is a CLI error (`bouy: cannot read <path>: <reason>`, status 1). It is not a diagnostic, because no edit of the code fixes it.

## 3. Today

- `Diagnostic` in `crates/bouy-compiler/src/diagnostic.rs` holds a path, a line, a column, a code, and a message. It has no span end, no help, no secondary spans, and no fixes.
- The compiler has seven codes. BOUY206 covers more than 40 causes, from `var` to `console.table`. BOUY201, BOUY205, and BOUY207 also cover several causes each.
- A message holds the cause and the fix in one sentence. Some fixes do not fit the case. `new Promise((resolve) => setTimeout(resolve, ms))` gets "call the async function and await it", and the right fix is `sleep(ms)`.
- An import error stops the check before lowering. A module that imports `zod` reports only the import. Its other errors appear after the import is gone.
- `bouy check` takes one entry. A check of each file of a codebase reports the errors of a shared module once for each file that imports it.
- `Effect.repeat` and `Effect.either` get the same message: "is not available in Bouy". effect 4.0.5 exports `Effect.repeat`, and Bouy lacks it. `Effect.either` is an effect 3 name that effect 4.0.5 does not export.
- Some programs compile and print something different from Node: a write through a parameter, a loop variable, or a copy of a place. Section 11 lists them.

## 4. The human format

`bouy check`, `bouy build`, and `bouy run` print diagnostics on stderr in this format, and exit with status 2. Take this file, `pause.ts`:

```ts
export function pause(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function add(xs: number[]): void {
  xs.push(1);
}
```

`bouy check pause.ts` prints:

```text
pause.ts:2:10: BOUY261: this promise only waits for a timer
  |
2 |   return new Promise((resolve) => setTimeout(resolve, ms));
  |          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ a call blocks until its result is ready, so Bouy has no promises
  |
help: write `sleep(ms)`, with `sleep` imported from "bouy"
  |
1 + import { sleep } from "bouy";
2 -   return new Promise((resolve) => setTimeout(resolve, ms));
2 +   return sleep(ms);
  |
fix: bouy fix writes this change

pause.ts:6:3: BOUY241: `push` changes the parameter `xs`, so the caller does not see the change
  |
5 | export function add(xs: number[]): void {
  |                     -- the caller's value
6 |   xs.push(1);
  |   ^^^^^^^^^^ Node changes the caller's array here, and Bouy changes only `xs`
  |
help: return `xs`, and assign the result where `add` is called, as in `list = add(list)`

bouy check: 2 errors in 1 module. `bouy fix` can fix 1. Explain a code with `bouy explain BOUY261`.
```

Today the same file prints one line, ``pause.ts:2:10: BOUY206: `new Promise` is not supported; call the async function and await it``, and nothing for `add`.

The layout:

1. Line 1 keeps the format of contract section 1: `<path>:<line>:<column>: <code>: <message>`. Editors, `grep`, and agents read it.
2. The excerpt shows the lines of the primary span, at most three. A longer span shows its first and last lines around `...`. A row of `^` marks the span, and its label follows.
3. A secondary span within five lines of the primary span gets a row of `-` and its label. Another secondary span prints as `note: <path>:<line>:<column>: <label>`.
4. `help:` is one line.
5. A fix shows the lines that it changes: `-` for a line that it removes, and `+` for a line that it adds. Line numbers refer to the file before the fix.
6. The `fix:` line names the applicability: `bouy fix writes this change`, `check this change before you make it`, or `replace the /* ... */ placeholders, then make this change`. A `missing` diagnostic ends with `note: Bouy does not provide this yet; bouy explain BOUYnnn lists workarounds`.
7. A blank line separates two diagnostics. The last line gives the counts and a code to explain.
8. A path is relative to the working directory when the file is in it. The output has color only when stderr is a terminal and `NO_COLOR` is not set.
9. Modules print in plan order (section 8). Inside a module, diagnostics print by position.

## 5. The JSON format

`bouy check --format json` writes JSON Lines to stdout, one object on each line. The first line is the `header`. One `diagnostic` line follows for each diagnostic. The last line is the `summary` of section 8. With JSON Lines, an agent can read the first diagnostics with `head`, select a code with `grep BOUY251`, and stream a large codebase. In this mode, stderr holds only CLI errors.

The diagnostics of section 4:

```jsonl
{"kind":"header","schema":1,"bouy":"0.1.0","cwd":"/home/ada/app"}
{"kind":"diagnostic","code":"BOUY261","name":"promise-sleep","category":"rejected","severity":"error","message":"this promise only waits for a timer","subject":"new Promise","span":{"path":"pause.ts","start":60,"end":109,"line":2,"column":10,"end_line":2,"end_column":59,"label":"a call blocks until its result is ready, so Bouy has no promises"},"secondary":[],"help":"write `sleep(ms)`, with `sleep` imported from \"bouy\"","fixes":[{"title":"replace the promise with `sleep(ms)`","applicability":"MachineApplicable","edits":[{"path":"pause.ts","start":0,"end":0,"original":"","replacement":"import { sleep } from \"bouy\";\n"},{"path":"pause.ts","start":60,"end":109,"original":"new Promise((resolve) => setTimeout(resolve, ms))","replacement":"sleep(ms)"}]}]}
{"kind":"diagnostic","code":"BOUY241","name":"parameter-write","category":"rejected","severity":"error","message":"`push` changes the parameter `xs`, so the caller does not see the change","subject":"push","span":{"path":"pause.ts","start":158,"end":168,"line":6,"column":3,"end_line":6,"end_column":13,"label":"Node changes the caller's array here, and Bouy changes only `xs`"},"secondary":[{"path":"pause.ts","start":134,"end":136,"line":5,"column":21,"end_line":5,"end_column":23,"label":"the caller's value"}],"help":"return `xs`, and assign the result where `add` is called, as in `list = add(list)`","fixes":[]}
```

The header:

| Field    | Value                                                  |
| -------- | ------------------------------------------------------ |
| `kind`   | `"header"`                                             |
| `schema` | `1`. The stability rules below say when it changes.    |
| `bouy`   | The version of the CLI.                                |
| `cwd`    | The working directory. A relative path starts from it. |

A diagnostic:

| Field       | Value                                                                                                                             |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `kind`      | `"diagnostic"`                                                                                                                    |
| `code`      | The code, such as `"BOUY251"`.                                                                                                    |
| `name`      | The name of the code, such as `"iteration-write"`.                                                                                |
| `category`  | `"invalid"`, `"rejected"`, `"unsupported"`, or `"missing"`.                                                                       |
| `severity`  | `"error"`. Every diagnostic is an error.                                                                                          |
| `message`   | The cause, in one line.                                                                                                           |
| `subject`   | The API or the syntax that the diagnostic names: a module (`node:fs`), a member (`Effect.repeat`), a global, a keyword, a method. |
| `span`      | The primary span.                                                                                                                 |
| `secondary` | Other spans that explain the cause, each with a label.                                                                            |
| `help`      | The fix, in one line.                                                                                                             |
| `fixes`     | Zero or more fixes. The preferred fix comes first.                                                                                |

A span:

| Field                    | Value                                                                                                   |
| ------------------------ | ------------------------------------------------------------------------------------------------------- |
| `path`                   | The path as the human format prints it.                                                                 |
| `start`, `end`           | Byte offsets into the UTF-8 text of the file, from 0. The byte at `end` is not in the span.             |
| `line`, `column`         | The start, from 1. A column counts Unicode scalar values, as the compiler does today and as rustc does. |
| `end_line`, `end_column` | The end, in the same units.                                                                             |
| `label`                  | Short text at the span, or `null`.                                                                      |

A fix and its edits:

| Field                  | Value                                                                                        |
| ---------------------- | -------------------------------------------------------------------------------------------- |
| `title`                | What the fix changes, in one line.                                                           |
| `applicability`        | `"MachineApplicable"`, `"MaybeIncorrect"`, or `"HasPlaceholders"`.                           |
| `edits`                | The edits. A tool writes all of them or none of them. No two edits overlap.                  |
| `edits[].path`         | The file. One fix can change several files, such as a module and the modules that import it. |
| `edits[].start`, `end` | Byte offsets, as in a span. An insertion has `start` equal to `end`.                         |
| `edits[].original`     | The text from `start` to `end` when the check read the file. It is empty for an insertion.   |
| `edits[].replacement`  | The new text.                                                                                |

A tool refuses an edit whose `original` no longer matches the file, so a stale fix cannot damage a file that changed after the check. An agent can also give `original` and `replacement` to its edit tool as the old and the new text. Edit tools, such as the one in Claude Code, match text. Offsets count bytes because oxc spans count bytes. TypeScript, ESLint, and LSP count UTF-16 code units, so an editor integration converts the offsets.

Stability:

- `schema` is 1. A new field or a new `kind` of line keeps the number. A removed field, a renamed field, or a field with a new meaning increments it.
- A consumer ignores unknown fields and unknown `kind` values, as rustc asks of the consumers of its JSON.
- `code`, `name`, `category`, and `subject` are data. `message`, `help`, `label`, and `title` are text for people and agents, and they can change.

## 6. `bouy explain`

`bouy explain BOUY251` prints the page `docs/errors/BOUY251.md`. `bouy explain` without a code lists every code with its name, its category, and its message. `crates/bouy-cli/build.rs` embeds the pages as it embeds the runtime sources, so the pages match the binary and work offline.

A page has a fixed layout, because the tests of section 13 read it:

````markdown
# BOUY251: an iteration callback changes an outer variable

Category: rejected. Fix: MachineApplicable for `forEach` when the callback is an arrow function with one or two plain parameters. MaybeIncorrect for the other iteration methods.

An Erlang fun copies the values that it captures when it is created. The callback of `forEach` holds a copy of `sum`, so `sum += item` would change only the copy. A `for...of` loop is not a closure, so it changes `sum` itself.

## Before

```ts before program
function total(items: number[]): number {
  let sum = 0;
  items.forEach((item) => {
    sum += item;
  });
  return sum;
}

console.log(total([1, 2, 3]));
```

## After

```ts after
function total(items: number[]): number {
  let sum = 0;
  for (const item of items) {
    sum += item;
  }
  return sum;
}

console.log(total([1, 2, 3]));
```

## Other cases

- A callback with two parameters, `(item, index)`, becomes `for (const [index, item] of items.entries())`.
- A `return` at the top level of the callback becomes `continue`.
- When the receiver is not declared or built as an array or a `Set`, the loop reads `items.values()`. It gives the same items as `forEach` for an array, a `Map`, and a `Set`.
````

The info string of a code block tells the tests what to check:

| Info string | Check                                                                                                                                                                               |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `before`    | The block reports the code of the page and no other code.                                                                                                                           |
| `after`     | The block compiles with no diagnostic. For a `MachineApplicable` code, `bouy fix` turns the first Before block into the first After block, byte for byte.                           |
| `program`   | The block is a whole program. `scripts/freeze-expectations.sh docs/errors` records what Node prints for it, and the test checks that `bouy run` of the After block prints the same. |

A retired code keeps its page. The page starts with `# BOUY206 (retired)` and lists the codes that replace it. The rustc error index also keeps a page for each code that rustc no longer emits.

## 7. `bouy fix`

```text
bouy fix [--dry-run] [--code <code>]... <path>...
```

1. Check the paths as `bouy check` does.
2. Take every `MachineApplicable` fix, or only the fixes of the `--code` values.
3. In each file, drop a fix when the `original` of one of its edits no longer matches the file. Also drop a fix when one of its edits overlaps an edit of an earlier fix. A fix takes all of its edits or none.
4. Make the edits from the end of each file to its start, so the offsets stay valid.
5. Check the changed modules again. When a file has a diagnostic that it did not have before, restore that file, and print the fix as a compiler bug.
6. Repeat from step 2 until no fix is left, at most 10 rounds. ESLint stops after 10 rounds, and `cargo fix` after 4.
7. Write each changed file to a temporary file, and rename it into place.
8. Print one line for each fixed diagnostic, and the totals. With `--dry-run`, print a unified diff on stdout, and write nothing.

The exit status is the status of `bouy check` on the result. It is 0 when no diagnostic remains, 2 when one remains, and 1 when a file cannot be read or written. `--dry-run` computes the same status on the result in memory.

`bouy fix` is idempotent. A `MachineApplicable` fix removes its own diagnostic and adds none. The loop stops when no fix is left, so a second run changes no file. A test of section 13 checks this for each code. The fixes write minimal text, and the project's formatter can reformat the result.

## 8. `bouy check` over a codebase

```text
bouy check [--format human|json] [--summary] <path>...
```

- A path is a file or a directory. For a directory, the CLI checks every `.ts`, `.mts`, `.js`, and `.mjs` file under it. It skips `node_modules`, `.bouy`, `*.d.ts`, and test files (`*.test.*`, `*.spec.*`). All the files load into one module graph, so each module is checked once.
- A module compiles when it has no diagnostic and every module that it imports compiles.
- The output lists the diagnostics in plan order. When a path is a directory, or with `--summary`, a report follows them. `--summary` prints the report alone.
- The exit status is 0 when no diagnostic remains, 2 when one remains, and 1 when the check cannot read a file.

The plan orders the work:

1. Step 0 is `bouy fix` when a `MachineApplicable` fix exists.
2. A module comes after the modules that it imports. So the agent fixes a module after its dependencies, and the module stays fixed. The modules of an import cycle form one step, and paths break ties.
3. A module with a `missing` diagnostic moves to the end, marked `blocked`, with the subjects that block it.

A module step counts the diagnostics that remain after step 0. An example report, for a made-up project:

```text
bouy check src: 9 modules, 2 compile, 7 do not. 58 errors, 9 fixable with bouy fix.

  invalid in Node too        2
  rejected: rewrite         35
  unsupported: rewrite       9
  missing in Bouy           12

by code:
  BOUY250 closure-write          11  rejected
  BOUY283 accessor                9  unsupported
  BOUY300 var                     6  rejected, fixable
  BOUY241 parameter-write         5  rejected
  ...

plan:
  0. bouy fix src                9 fixes
  1. src/errors.ts               6  BOUY281 x4, BOUY284 x2
  2. src/util/async.ts           4  BOUY262 x2, BOUY260 x2
  3. src/cache.ts                8  BOUY283 x3, BOUY282 x3, BOUY250, BOUY202
  ...
  7. src/config.ts               3  blocked: node:fs/promises, node:path, node:url

gaps in Bouy, by use:
  getter 9, node:fs/promises 4, process.on 2, node:path 1, node:url 1, fetch 1, ...

next: bouy fix src
```

The `summary` line of the JSON format holds the same data:

```jsonl
{"kind":"summary","modules":9,"compiling":2,"diagnostics":58,"fixable":9,"categories":{"invalid":2,"rejected":35,"unsupported":9,"missing":12},"codes":[{"code":"BOUY250","name":"closure-write","category":"rejected","count":11}],"plan":[{"path":"src/errors.ts","diagnostics":6,"codes":{"BOUY281":4,"BOUY284":2},"blocked_by":[]}],"gaps":[{"subject":"node:fs/promises","code":"BOUY212","count":4}]}
```

`gaps` counts the `unsupported` and `missing` diagnostics by subject, the most used first. Over a real codebase, this list is the order in which Bouy should add features.

## 9. Migrating with an agent

The loop, for a codebase in `src`:

```sh
bouy fix src               # 1. write the MachineApplicable fixes
bouy check src --summary   # 2. read the plan, and take its first module
bouy check src/errors.ts   # 3. fix that module until this prints nothing
bouy explain BOUY281       #    read the page before the first fix of each code
```

Repeat steps 2 and 3 until `bouy check src` exits 0, or until only blocked modules remain.

The instruction text for the agent. Paste it into `AGENTS.md` or `CLAUDE.md`, or into the prompt:

```markdown
## Migrating to Bouy

Move the code in `src` to Bouy. Repeat these steps until `bouy check src` exits 0, or until every module that is left is marked `blocked`.

1. Run `bouy fix src`.
2. Run `bouy check src --summary`. Take the first module of the plan that is not blocked.
3. Run `bouy check <module>`, and fix each diagnostic in that module:
   - Do what the `help:` line says. When the diagnostic shows a fix, write that exact text.
   - Before you fix a code for the first time, run `bouy explain <code>` and read the page.
   - Keep the behavior of the code. Do not delete code, or change what it does, to make a diagnostic go away.
4. Run `bouy check <module>` again until it prints nothing. When the module imports nothing from "bouy", also run its existing tests with Node.
5. A `missing` diagnostic is a gap in Bouy. Use the workaround of `bouy explain` when the page gives one. Otherwise, add the module and the subject to `MIGRATION.md`, and go to the next module.
```

Step 4 relies on the goal of section 1: a construct that Bouy accepts behaves as in Node. So the old tests of a module still hold after the rewrite, as long as the module imports nothing from "bouy". The differences that no diagnostic covers, such as the key order of section 11, are the exception.

After the migration, a Claude Code hook keeps each edit inside the Bouy subset. On exit status 2, Claude Code shows the stderr of the hook to Claude, and stderr holds the diagnostics:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "f=$(jq -r '.tool_input.file_path'); case \"$f\" in *.ts) bouy check \"$f\" || exit 2 ;; esac"
          }
        ]
      }
    ]
  }
}
```

Leave the hook off during the migration. Until a module compiles, it would print the whole list of the module after every edit.

## 10. Codes

Numbering:

- BOUY200, BOUY202, and BOUY203 keep their numbers and their causes.
- BOUY201, BOUY205, BOUY206, and BOUY207 retire, because each one covered several causes. Their pages list the codes that replace them. BOUY204 was never used.
- New codes come in blocks by construct, so a report sorted by code keeps related codes together. The blocks are 210 modules, 230 module state, 240 shared values, 250 closures, 260 promises and timers, 270 generators, 280 classes, 300 statements and expressions, 320 globals.
- BOUY101 to BOUY107 belonged to the TypeScript checker of the Node design (ADR 0002), and stay unused.

In the tables, `Was` gives today's code, or `silent` for a program that compiles today and prints something different from Node. `Fix` gives the applicability: `auto` is `MachineApplicable`, `check` is `MaybeIncorrect`, `fill` is `HasPlaceholders`, and `none` means no fix. The names in backticks in a message or a help come from the source.

### Source and modules

| Code    | Name                   | Was      | Category    | Message                                                                    | Help                                                                                               | Fix                                                                     |
| ------- | ---------------------- | -------- | ----------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| BOUY200 | syntax                 | 200      | invalid     | the message of oxc, such as "Identifier `total` has already been declared" | the help of oxc, when oxc gives one                                                                | none                                                                    |
| BOUY210 | module-not-found       | 201      | invalid     | cannot find the module `./parser.ts`                                       | import an existing file; the nearest one is `./parse.ts`                                           | check: the nearest file                                                 |
| BOUY211 | node-module-replaced   | 201      | rejected    | Bouy replaces `node:events` with actors                                    | make the emitter an actor: a listener becomes a method, and `emit` becomes `cast(ref).method(...)` | check for `node:timers/promises`, which becomes `sleep`; none otherwise |
| BOUY212 | node-module-missing    | 201      | missing     | Bouy has no `node:fs/promises` yet                                         | this module cannot move to Bouy until Bouy adds `node:fs/promises`                                 | none                                                                    |
| BOUY213 | package-missing        | 201      | missing     | Bouy cannot compile the package `zod`                                      | copy the source that you use into the project, and import it as a relative module                  | none                                                                    |
| BOUY214 | library-member-missing | 201, 206 | missing     | Bouy does not implement `Effect.repeat` of effect 4.0.5 yet                | write the supported form that the compiler names; when it names none, the module waits for Bouy    | none                                                                    |
| BOUY215 | library-member-unknown | 201, 206 | invalid     | effect 4.0.5 has no `Effect.catchAll`                                      | write `Effect.catch`, the effect 4 name                                                            | check: a rename table, or the nearest name                              |
| BOUY216 | export-missing         | 201      | invalid     | `./math.ts` does not export `sum`                                          | import a name that `./math.ts` exports, such as `add`                                              | check: the nearest name                                                 |
| BOUY217 | library-reexport       | 201      | unsupported | this module re-exports the library `effect`                                | import from "effect" in each module that uses it                                                   | none                                                                    |
| BOUY218 | module-name-clash      | 201      | rejected    | `a-b.ts` and `a_b.ts` both become the Erlang module `bouy@a_b`             | rename one of the two files                                                                        | none                                                                    |
| BOUY219 | commonjs               | 206      | rejected    | `require` is CommonJS, and Bouy loads ES modules only                      | write `import * as fs from "./fs.ts"`                                                              | check for `import x = require("./x")`; none otherwise                   |
| BOUY220 | dynamic-import         | 206      | unsupported | `import()` loads a module while the program runs                           | import the module at the top of the file                                                           | check when the specifier is a string and a `const` takes the result     |
| BOUY221 | default-export-value   | 206      | unsupported | `export default` of an expression                                          | export a named declaration, such as `export const config = ...`, and import it by name             | none                                                                    |
| BOUY222 | namespace-value        | 206      | unsupported | the module namespace `registry` is used as a value                         | read or call its exports directly, such as `registry.count()`                                      | none                                                                    |
| BOUY223 | reserved-function-name | 206      | rejected    | every Erlang module defines a function named `module_info`                 | rename the function                                                                                | none                                                                    |

BOUY200 also covers the strict-mode errors that oxc does not report: `with`, `break` outside a loop, `delete` of a variable, and a bad escape in a template literal. BOUY219 also covers `import x = require(...)`, `export =`, `export as namespace`, `module.exports`, and `exports`.

### Module state and globals

Actors share no state, so a module-level value cannot change after the module loads.

| Code    | Name             | Was      | Category | Message                                                     | Help                                             | Fix   |
| ------- | ---------------- | -------- | -------- | ----------------------------------------------------------- | ------------------------------------------------ | ----- |
| BOUY202 | module-state     | 202      | rejected | the module-level `cache` changes after the module loads     | keep the state in an actor, and call its methods | none  |
| BOUY230 | module-let       | 202      | rejected | the module-level `let` declaration of `limit` never changes | write `const`                                    | auto  |
| BOUY231 | global-write     | 206      | rejected | `console.log` is a global, and a global cannot change       | call your own function in place of the global    | none  |
| BOUY232 | import-write     | 206, 202 | invalid  | `config` is an import, and an import cannot change          | assign a local variable                          | none  |
| BOUY233 | undeclared-write | 206      | invalid  | `total` is not declared                                     | declare it, as in `let total = 0`                | check |

BOUY202 also covers a static field that changes, and a write through a namespace import, such as `registry.names.push(name)`.

### Values that Node shares

Every Bouy value is a copy. A write changes the variable or the field that holds the value. In Node, every other name for the same object sees the write. These codes reject the writes that Node would share. BOUY241 to BOUY244 are new: today these programs compile and print something else (section 11).

| Code    | Name              | Was    | Category | Message                                                                        | Help                                                                                                          | Fix                                                                                                       |
| ------- | ----------------- | ------ | -------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| BOUY240 | temporary-write   | 206    | rejected | `push` changes a value that no variable holds, so the change is lost           | change it through the variable that holds it, such as `grid[0].push(7)`                                       | auto for the statement `(c ? a : b).m(...)`, which becomes an `if`; check for `xs.at(n)`                  |
| BOUY241 | parameter-write   | silent | rejected | `push` changes the parameter `xs`, so the caller does not see the change       | return `xs`, and assign the result where the function is called                                               | none                                                                                                      |
| BOUY242 | item-write        | silent | rejected | `row` is a copy of an item of `grid`, so the change does not reach `grid`      | build a new collection with `map` from changed copies, as in `grid = grid.map((row) => [1, ...row.slice(1)])` | none                                                                                                      |
| BOUY243 | alias-write       | silent | rejected | `entry` is a copy of `counts.get(word)`, so the change does not reach `counts` | change and read the value through `counts.get(word)`                                                          | auto when the root of the place keeps its value from the copy to the last use of `entry`; check otherwise |
| BOUY244 | write-after-store | silent | rejected | `o` changes after `list.push(o)` stored a copy of it                           | make the change before `list.push(o)`                                                                         | check                                                                                                     |

What each new code matches:

- BOUY241: a write through a parameter. A write is an assignment to a property path, a mutator call (contract section 6), `delete`, or `Object.assign`. `this` is not a parameter.
- BOUY242: a write through a `for...of` variable, or through a parameter of a callback that an array, `Map`, or `Set` method calls.
- BOUY243: a write through a variable that copies a place, such as `const items = this.items`, `const entry = m.get(k)`, or `const { items } = cart`.
- BOUY244: a write through a variable that the code stored in another place before, when the code reads that place after the write. A mutator argument, an assignment, or a literal can store the variable.

### Closures

An Erlang fun copies the values that it captures when it is created.

| Code    | Name                 | Was      | Category | Message                                                                               | Help                                                                             | Fix                                                                                                         |
| ------- | -------------------- | -------- | -------- | ------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| BOUY250 | closure-write        | 205      | rejected | the closure `add` changes `total`, which belongs to `sum`                             | return the new value from the closure, and assign it where the closure is called | none                                                                                                        |
| BOUY251 | iteration-write      | 205      | rejected | a `forEach` callback changes `sum`, which belongs to `total`                          | use a loop: `for (const item of items) { ... }`                                  | auto for `forEach` when the callback is an arrow function with one or two plain parameters; check otherwise |
| BOUY252 | stale-capture        | 205      | rejected | this closure reads `value`, which changes after the closure is created                | pass the value as an argument when you call the closure                          | none                                                                                                        |
| BOUY253 | read-before-creation | 205, 206 | rejected | this closure reads `x`, which does not exist yet when the closure is created          | declare `x` before the closure                                                   | check: move the declaration up when its initializer calls nothing                                           |
| BOUY254 | method-value         | 205      | rejected | `this.inc` changes `this`, so it cannot be a function value                           | call the method, as in `this.inc()`                                              | none                                                                                                        |
| BOUY255 | parallel-write       | 205      | rejected | an operation of `Promise.all` assigns `x`, and each operation runs in its own process | assign from the results: `const [a, b] = await Promise.all([f(), g()])`          | none                                                                                                        |
| BOUY256 | closure-state        | 205      | rejected | the closure `inc` changes `count` after `makeCounter` returns                         | keep `count` in an actor field, and make `inc` a method of the actor             | none                                                                                                        |

Three codes share the cause "a closure changes an outer variable", because the fix depends on where the closure goes. BOUY251 covers the callbacks of `forEach`, `map`, `filter`, `find`, `some`, `every`, `flatMap`, and `reduce`. BOUY256 covers a closure that leaves its function: a `return`, a field, an object, or an array holds it. BOUY250 covers every other closure, such as a local function or the callback of a function of the program. BOUY252 also covers a loop around the closure, a closure that its own write stores (`fact = (n) => n * fact(n - 1)`), a field initializer that reads `this`, and a method value such as `this.report.bind(this)`. BOUY253 also covers an object whose methods call each other through the object, as in `const api = { two: () => api.one() }`.

### Promises, async, and timers

Bouy has no promise objects and no event loop. A call blocks the caller until its result is ready, so `await` changes nothing.

| Code    | Name                | Was    | Category    | Message                                                                                     | Help                                                                                                                     | Fix                                                                 |
| ------- | ------------------- | ------ | ----------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------- |
| BOUY260 | promise-chain       | 206    | rejected    | `.then()` needs a promise, and a call in Bouy returns its result                            | write `const text = await echo.echo("hi");`, and then the body of the callback                                           | check when the chain is a statement                                 |
| BOUY261 | promise-sleep       | 206    | rejected    | this promise only waits for a timer                                                         | write `sleep(ms)`, with `sleep` imported from "bouy"                                                                     | auto                                                                |
| BOUY262 | promise-constructor | 206    | rejected    | `new Promise` makes a promise, and Bouy has none                                            | call the code that does the work; to wait for another actor, call its method                                             | none                                                                |
| BOUY263 | unawaited-call      | silent | rejected    | the call of `work` is not awaited: Node goes on before the call ends, and Bouy waits for it | write `await work(...)`; to run several calls at once, use `Promise.all([...])`                                          | check                                                               |
| BOUY264 | promise-list        | 206    | rejected    | `Promise.race` needs the calls, and `promises` holds their results                          | list the calls, as in `Promise.race([a(), b()])` or `Promise.race(items.map(f))`                                         | none                                                                |
| BOUY265 | timer-callback      | 207    | rejected    | `setInterval` calls a callback later, and Bouy has no event loop                            | in an actor, `schedule(self(this), { every: ms }, "tick")` and a method `tick`; elsewhere, `sleep(ms)` and then the code | fill in an actor method: the name of the new method; none otherwise |
| BOUY266 | timer-cancel        | 207    | rejected    | `clearInterval` stops an event-loop timer                                                   | call `cancelSchedule(handle)` with the handle that `schedule` returned                                                   | check                                                               |
| BOUY267 | microtask           | 207    | rejected    | `queueMicrotask` defers a function to the event loop, and Bouy has none                     | call the function directly                                                                                               | check                                                               |
| BOUY268 | for-await           | 206    | unsupported | `for await` reads an async iterable                                                         | read the items into an array, then loop with `for...of`                                                                  | none                                                                |

BOUY262 also covers `Promise.withResolvers`. BOUY263 matches a call of an `async` function of the program, or a method call through an actor ref. It reports the call when the code ignores the result or stores it in a variable. BOUY267 also covers `setImmediate` and `process.nextTick`.

### Generators and Effect bodies

A generator function is the body of an Effect, and `yield*` runs an Effect (contract section 13).

| Code    | Name             | Was | Category | Message                                                          | Help                                                                                       | Fix   |
| ------- | ---------------- | --- | -------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ----- |
| BOUY270 | plain-generator  | 206 | rejected | `yield` without `*`, and a generator function is an Effect body  | return an array of the values                                                              | none  |
| BOUY271 | nested-yield     | 206 | rejected | `yield*` in a function inside the Effect body                    | make the inner function return `Effect.gen(function* () { ... })`, and `yield*` its result | none  |
| BOUY272 | generator-method | 206 | rejected | the generator method `*each`                                     | make it a method that returns `Effect.gen(function* () { ... })`                           | check |
| BOUY273 | generator-this   | 206 | rejected | `this` in a generator function                                   | read the fields into constants before the generator, as in `const { url } = this;`         | check |
| BOUY274 | async-generator  | 206 | rejected | an `async` generator, and a generator function is an Effect body | drop `async`, and run each asynchronous step with `yield*`                                 | none  |

### Classes and `this`

A class without `extends` is an actor class. A class that extends an error class is an error class (contract section 9).

| Code    | Name                    | Was | Category    | Message                                                                                        | Help                                                                                      | Fix   |
| ------- | ----------------------- | --- | ----------- | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ----- |
| BOUY203 | new-actor               | 203 | rejected    | `new Counter` creates an actor, and actors start with `spawn`                                  | write `spawn(Counter, { args: [a, b] })`, with `spawn` imported from "bouy"               | check |
| BOUY280 | class-extends           | 206 | rejected    | `Square` extends `Shape`, and an actor class cannot extend a class                             | copy the members that `Square` needs, or keep a ref to a `Shape` actor in a field         | none  |
| BOUY281 | error-class-extends     | 206 | unsupported | `ToolError` extends the error class `AgentError`                                               | extend `Error`, repeat the fields of `AgentError`, and test the class with `error.name`   | none  |
| BOUY282 | static-member           | 206 | unsupported | the static member `DEFAULT_TTL_MS`                                                             | move it to module level, as `export const DEFAULT_TTL_MS = 60_000`, and use that name     | check |
| BOUY283 | accessor                | 206 | unsupported | the getter `size`                                                                              | make it a method, `size()`, and call it                                                   | none  |
| BOUY284 | error-class-method      | 206 | unsupported | the error class `AgentError` declares the method `toJSON`                                      | make it a module-level function that takes the error                                      | none  |
| BOUY285 | error-constructor-order | 206 | unsupported | the constructor of `AgentError` runs code before `super(...)`                                  | move the statements before `super(...)` after it                                          | check |
| BOUY286 | local-class             | 206 | rejected    | the class `Job` is declared inside a function, and an actor class is a module-level definition | declare the class at module level, and pass the captured values as constructor arguments  | none  |
| BOUY287 | class-syntax            | 206 | unsupported | Bouy does not support decorators yet                                                           | rewrite the class without the feature; `bouy explain BOUY287` gives the form for each one | none  |
| BOUY288 | this-outside-method     | 206 | unsupported | `this` in an object literal method                                                             | pass the object as a parameter, or make the object a class                                | none  |
| BOUY289 | not-callable            | 206 | invalid     | `Counter` is a class, and a class cannot be called                                             | write `spawn(Counter)` for an actor class, or `new` for an error class                    | none  |
| BOUY290 | ref-write               | 206 | rejected    | `store` is an actor ref, which has no fields to change                                         | call a method of the actor that changes the field                                         | none  |

An error class can extend only `Error`, `TypeError`, `RangeError`, `SyntaxError`, `Data.TaggedError`, and `Data.Error`. BOUY282 does not cover a static field that changes, which is BOUY202. BOUY283 also covers setters, in classes and in object literals. BOUY286 also covers class expressions. BOUY287 covers decorators, computed member names, static blocks, `accessor` fields, and `super.m()`. BOUY288 also covers `this` in a plain function. BOUY289 also covers a call of a module namespace.

### Statements and expressions

| Code    | Name                   | Was | Category    | Message                                                                       | Help                                                                                              | Fix                                                                                                                       |
| ------- | ---------------------- | --- | ----------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| BOUY300 | var                    | 206 | rejected    | `var` declares a variable for the whole function                              | write `let`                                                                                       | auto when no use comes before the declaration or outside its block, and no closure in a loop captures it; check otherwise |
| BOUY301 | label                  | 206 | unsupported | the labeled statement `outer:`                                                | move the loops into a function, and `return` where the code breaks out to the label               | none                                                                                                                      |
| BOUY302 | switch-fallthrough     | 206 | unsupported | `case 1` falls through into `case 2`                                          | end each case with `break`, and repeat the shared statements                                      | check                                                                                                                     |
| BOUY303 | finally-jump           | 206 | unsupported | `return` in a `finally` block                                                 | move the code after the `try` statement                                                           | none                                                                                                                      |
| BOUY304 | using                  | 206 | unsupported | the `using` declaration of `file`                                             | call the dispose method in a `finally` block                                                      | none                                                                                                                      |
| BOUY305 | expression-write       | 206 | unsupported | an assignment inside a `case` test, a default value, or an optional chain     | make the assignment in a statement before it                                                      | check                                                                                                                     |
| BOUY306 | optional-mutation      | 206 | unsupported | `push` after the optional link in `list?.items.push(1)`                       | write `if (list != null) list.items.push(1);`                                                     | auto when the call is a statement on a place                                                                              |
| BOUY307 | arguments              | 206 | rejected    | `arguments`                                                                   | declare a rest parameter, as in `function f(...args)`, and use `args`                             | auto when the function declares no parameters; check otherwise                                                            |
| BOUY308 | eval                   | 206 | rejected    | `eval` runs code from a string                                                | write the code directly                                                                           | none                                                                                                                      |
| BOUY309 | regexp                 | 206 | missing     | Bouy has no regular expressions yet                                           | use string methods: `split`, `includes`, `startsWith`, `endsWith`, and `replaceAll` with a string | none                                                                                                                      |
| BOUY310 | bigint                 | 206 | unsupported | the BigInt literal `10n`                                                      | write `10`, because a Bouy integer is exact at any size                                           | check                                                                                                                     |
| BOUY311 | tagged-template        | 206 | unsupported | the tagged template `` sql`...` ``                                            | call the function with the strings and the values as arguments                                    | none                                                                                                                      |
| BOUY312 | lone-surrogate         | 206 | rejected    | the string holds a lone surrogate, and UTF-8 cannot hold one                  | remove it, or write the whole character                                                           | none                                                                                                                      |
| BOUY313 | proto-literal          | 206 | rejected    | `__proto__` in an object literal sets a prototype, and Bouy objects have none | copy the properties, as in `{ ...base, own: 1 }`                                                  | check                                                                                                                     |
| BOUY314 | enum                   | 206 | rejected    | the enum `Level` makes a runtime object from type syntax                      | write the object that TypeScript emits for `Level`, and a union type                              | auto when no type refers to a member of the enum; check otherwise                                                         |
| BOUY315 | ts-namespace           | 206 | rejected    | the TypeScript namespace `Shapes`                                             | move its members to a module, and import them                                                     | none                                                                                                                      |
| BOUY316 | use-before-declaration | 206 | invalid     | `x` is read before its declaration                                            | move the declaration above the first use                                                          | none                                                                                                                      |
| BOUY317 | syntax-missing         | 206 | unsupported | Bouy does not support `import.meta` yet                                       | rewrite the code without it; `bouy explain BOUY317` gives the form for each case                  | none                                                                                                                      |

BOUY308 also covers `new Function`. BOUY317 covers `import.meta`, `new.target`, JSX, `#x in o`, and a spread in a conversion such as `String(...xs)`.

### Globals and host APIs

| Code    | Name           | Was | Category | Message                              | Help                                                               | Fix                     |
| ------- | -------------- | --- | -------- | ------------------------------------ | ------------------------------------------------------------------ | ----------------------- |
| BOUY320 | global-missing | 206 | missing  | Bouy has no global `fetch` yet       | the replacement that `bouy explain BOUY320` lists, when one exists | none                    |
| BOUY321 | global-unknown | 206 | invalid  | `fetchh` is not declared             | declare or import it; the nearest global is `fetch`                | check: the nearest name |
| BOUY322 | member-missing | 206 | missing  | Bouy has no `console.table` yet      | write `console.log(rows)`                                          | none                    |
| BOUY323 | member-unknown | 206 | invalid  | `Object` has no member `own_entries` | write `Object.entries`                                             | check: the nearest name |
| BOUY324 | process-member | 207 | missing  | Bouy has no `process.exit` yet       | throw an error to end the program with status 1                    | none                    |
| BOUY325 | process-write  | 207 | rejected | `process.env.MODE` cannot change     | keep the value in a variable, and pass it on                       | none                    |
| BOUY326 | global-this    | 207 | rejected | `globalThis` is shared global state  | import the value, or pass it as an argument                        | none                    |

BOUY320 also covers the Node globals, such as `Buffer` and `__dirname`. The compiler holds the names of the ECMAScript, web, and Node globals and their members (section 13). These names tell BOUY320 from BOUY321, and BOUY322 from BOUY323.

## 11. Silent divergences

These programs compile today and print something different from Node. The release build of 2026-10-16 ran each one inside a function, and Node 25.9.0 ran the same file.

| Program                                                                     | Node prints                   | Bouy prints                   | New code |
| --------------------------------------------------------------------------- | ----------------------------- | ----------------------------- | -------- |
| `function add(xs) { xs.push(1); }`, then `add(a); console.log(a)`           | `[ 1 ]`                       | `[]`                          | BOUY241  |
| `people.forEach((p) => { p.age++; })`                                       | `[ { age: 2 } ]`              | `[ { age: 1 } ]`              | BOUY242  |
| `for (const row of grid) row[0] = 1`                                        | `[ [ 1, 0 ], [ 1, 0 ] ]`      | `[ [ 0, 0 ], [ 0, 0 ] ]`      | BOUY242  |
| `const c = b; c.push(2); console.log(b)`                                    | `[ 2 ]`                       | `[]`                          | BOUY243  |
| `const entry = counts.get(word); if (entry) entry.n++`                      | `{ n: 2 }`                    | `{ n: 1 }`                    | BOUY243  |
| `const { items } = cart; items.push("x")`                                   | `[ 'x' ]`                     | `[]`                          | BOUY243  |
| `const list = [o]; o.n = 1; console.log(list[0].n)`                         | `1`                           | `0`                           | BOUY244  |
| `m.set(key, "v"); key.id = 2; console.log(m.get(key))`                      | `v`                           | `undefined`                   | BOUY244  |
| `const p = work("a"); console.log("between")`, where `work` logs and awaits | `start a`, `between`, `end a` | `start a`, `end a`, `between` | BOUY263  |

The compiler can lower some of these writes so that they behave as in Node. A `const` that copies a place (BOUY243) and a `for...of` variable (BOUY242) can lower as writes to the place itself. When the compiler lowers a case that way, the case leaves its code, and a code with no case left retires. This is the better outcome, because the program then needs no change.

Two kinds of divergence stay outside the reach of diagnostics:

- Identity. `[1] === [1]` is `false` in Node and `true` in Bouy. `includes`, `indexOf`, `Set.has`, and `Map` keys also compare objects by contents. The compiler erases types, so at `a === b` it cannot tell an object from a number. A check would need types, and this design has none.
- Runtime behavior. The other differences of contract section 3 need a runtime change, or stay documented. The most frequent is key order. `console.log({ name: "Ada", age: 36 })` prints `{ name: 'Ada', age: 36 }` in Node and `{ age: 36, name: 'Ada' }` in Bouy, and `JSON.stringify` differs the same way. No diagnostic can flag every object whose keys are out of order. An object representation that keeps insertion order is the only fix.

## 12. Effect

The goal for Effect: a program that uses `effect` 4.0.5 compiles on Bouy and prints what it prints on Node. Diagnostics measure the distance to that goal.

An `effect` API in a program has one of three outcomes:

| Outcome                                                                       | Diagnostic                                                 | Who acts  |
| ----------------------------------------------------------------------------- | ---------------------------------------------------------- | --------- |
| Bouy implements it, and contract section 13 lists it.                         | none                                                       | nobody    |
| effect 4.0.5 exports it, and Bouy does not implement it yet.                  | BOUY214, `missing`                                         | Bouy      |
| effect 4.0.5 does not export it, such as the effect 3 name `Effect.catchAll`. | BOUY215, `invalid`, with the effect 4 name when one exists | the agent |

To tell BOUY214 from BOUY215, the compiler holds the exports of each module of effect 4.0.5. A script reads the `.d.ts` files of the package and writes the list to `crates/bouy-compiler/src/effect_exports.rs`, so the compiler needs no Node at run time. The `Effect` module alone exports more than 200 values. Today the compiler accepts 33 of its functions and the value `Effect.void` (`GLOBAL_FUNCTIONS` in `crates/bouy-compiler/src/library.rs`).

Effect code uses classes that today get class diagnostics, such as `class Users extends Context.Service<Users>()("Users", { ... }) {}` and `class User extends Schema.Class<User>("User")({ ... }) {}`. These report BOUY214 with the subject `Context.Service` or `Schema.Class`, and their bodies report nothing more. So they count as Effect work for Bouy, and the agent does not rewrite them.

The `gaps` list of `bouy check <dir>` counts the BOUY214 subjects of a real Effect codebase by use. That list orders the work on the Effect subset. Each member that Bouy adds ships with a program in `tests/equivalence/effect`, which proves it against effect 4.0.5 under Node (contract section 15).

A codebase on effect 3 moves to effect 4 first, because Bouy implements effect 4.0.5 only. BOUY215 holds a rename table for effect 3 names, such as `catchAll` to `catch`. A rename that changes the result is `MaybeIncorrect`: `Effect.either` gives an `Either`, and `Effect.result` gives a `Result`.

The documented differences of the Effect subset, such as the finalizers of a killed worker (contract section 13), are runtime work. No diagnostic covers them.

## 13. Build order and tests

Each step ends with `pnpm check` green, and with the contract changed in the same commit:

1. Structure. `Diagnostic` gets a span end, a help, secondary spans, fixes, and the name and the category of its code. `Reporter::report` takes the help, so no diagnostic can lack one. The compiler renders both formats, and the CLI picks one. `serde_json`, which `bouy-bench` already uses, writes the JSON. One-check reporting (rule 6) and one diagnostic for each cause (rule 5) come in this step.
2. Codes. Each `unsupported(...)` and `report(...)` call in the compiler gets a code of section 10. The fixtures in `crates/bouy-compiler/tests/fixtures/diagnostics` split into one file for each code, named by the code, as today. BOUY201, BOUY205, BOUY206, and BOUY207 retire.
3. Silent divergences: BOUY241 to BOUY244, and BOUY263. They need new analyses of parameters, copies of places, and stores, next to the capture analysis in `crates/bouy-compiler/src/lower/capture.rs`. Each one lands with its program of section 11 as a fixture.
4. `bouy check <dir>`, the report, and the plan.
5. `bouy explain`, the pages in `docs/errors`, and the page tests.
6. `bouy fix`, with the `auto` fixes of BOUY230, BOUY240, BOUY243, BOUY251, BOUY261, BOUY300, BOUY306, BOUY307, and BOUY314.
7. The tables that tell `missing` from `invalid`: the exports of effect 4.0.5 (BOUY214, BOUY215), and the ECMAScript, web, and Node globals and their members (BOUY320 to BOUY323). A script generates them from the `.d.ts` files of `effect`, `typescript`, and `@types/node`, and the repository keeps the output.

The tests that hold the rules:

| Rule                                                                                     | Test                                                                                                              |
| ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Each code has a fixture that reports that code and no other code.                        | `reports_each_diagnostic` in `crates/bouy-compiler/tests/compile.rs`, plus a check that each `Code` has a fixture |
| Each diagnostic has a help, and each `original` matches the source text.                 | A test over all fixtures                                                                                          |
| Each code has a page. Each Before block reports its code, and each After block compiles. | A page test in `crates/bouy-cli/tests`                                                                            |
| An `auto` fix turns the Before block of its page into the After block.                   | The same page test                                                                                                |
| A fixed program prints what the original printed under Node.                             | The `program` blocks, which `scripts/freeze-expectations.sh docs/errors` records                                  |
| A second `bouy fix` changes no file.                                                     | A test that runs `bouy fix` twice over the fixtures                                                               |
| The JSON format stays stable.                                                            | A snapshot of `bouy check --format json` over the fixtures                                                        |
| A real codebase shows its progress.                                                      | A snapshot of `bouy check --summary` over `tests/migration/before`                                                |

## 14. Not in this design

- A language server. The JSON format maps to LSP diagnostics and quick fixes. Agents in editors read the diagnostics of a language server, so a server is the next step.
- SARIF output, and GitHub annotations.
- A mode of `bouy fix` that writes `MaybeIncorrect` fixes. An agent reads those fixes and writes them itself.
- A check for uncommitted changes before `bouy fix`, as `cargo fix` has. Add it when a user loses work.
- Warnings and lint levels. Every diagnostic is an error.
- Checks that need types, such as the identity comparison of section 11.
- A Node build of the `bouy` module, so a module that imports `spawn` or `sleep` can still run its Node tests.

## 15. Sources

| Source                                                                                                                                                      | What this design takes from it                                                                                                |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| [rustc JSON output](https://doc.rust-lang.org/rustc/json.html)                                                                                              | Byte offsets, columns in Unicode scalar values, labeled spans, and the applicability values. Consumers ignore unknown fields. |
| [rustc diagnostic guide](https://rustc-dev-guide.rust-lang.org/diagnostics.html)                                                                            | The message states the cause and the help states the fix. Be conservative with `MachineApplicable`.                           |
| [rustc error index, E0382](https://doc.rust-lang.org/error_codes/E0382.html)                                                                                | Long pages with an erroneous example and a fixed example, tested as code. A retired code keeps its page.                      |
| [cargo fix source](https://rust.googlesource.com/cargo/+/refs/heads/master/src/ops/cargo_fix/mod.rs)                                                        | Only `MachineApplicable` by default. Repeat while fixes apply. Check again, and back out a fix that breaks the build.         |
| TypeScript 6.0.3 `CodeFixAction` (`lib/typescript.d.ts`)                                                                                                    | A fix is a title and a list of file changes. `getCombinedCodeFix` fixes every case of one code at once.                       |
| [ESLint custom rules](https://eslint.org/docs/latest/extend/custom-rules)                                                                                   | Fixes must not overlap. Up to 10 rounds of fixes. A suggestion is a fix that a person applies.                                |
| [Biome linter](https://biomejs.dev/linter/) and [reporters](https://biomejs.dev/reference/reporters/)                                                       | Safe fixes are written by `--write`, and unsafe fixes need `--unsafe`. Several report formats.                                |
| [oxlint output formats](https://oxc.rs/docs/guide/usage/linter/output-formats.html) and [coding agents](https://oxc.rs/docs/guide/usage/coding-agents.html) | A one-line format with the help for agents, and the `AGENTS.md` and Claude Code hook setups.                                  |
| [Writing tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents)                                                                  | Errors give specific and actionable improvements. Agents use natural-language names better than opaque identifiers.           |
| [Claude Code hooks](https://code.claude.com/docs/en/hooks)                                                                                                  | A `PostToolUse` hook that exits with status 2 shows its stderr to Claude.                                                     |
