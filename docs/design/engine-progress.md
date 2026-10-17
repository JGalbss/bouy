# Engine progress

This file holds the test262 counts of the reference engine (`--semantics reference`, section 17 of [the contract](beam-runtime.md)). Each agent that changes the engine reruns the directories that its change touches, replaces their rows and the totals, and adds a line to the run log.

## How to run

```sh
scripts/test262-dev.sh --failures /tmp/language.txt test/language
scripts/test262-dev.sh --failures /tmp/built-ins.txt test/built-ins
```

With 8 jobs on the 18-core development machine, `test/language` took between 10 and 18 minutes and `test/built-ins` between 17 and 24 minutes at a load average between 15 and 79. The failures file lists each test that did not pass, with its first error line. The runner gives the VM `BOUY_COMPILER`, the `bouy` binary next to it, which compiles the code of `eval` and `new Function`.

The columns of the tables:

- **Baseline pass:** the passes of the directory at the baseline, commit `7090eb1`.
- **Compile:** the compiler rejected the test with a Bouy diagnostic, such as `BOUY206` for syntax that the reference lowering does not lower yet.
- **Skip:** a `CanBlockIsFalse` test or an `IsHTMLDDA` test. A `noStrict` test runs as sloppy code. The baseline skipped the `noStrict` tests: 1544 in `test/language` and 198 in `test/built-ins`.
- **Baseline rate** and **Pass rate:** the passes divided by the tests that ran, which are the tests minus the skips.

The counts include proposals, such as Temporal and ShadowRealm, and the features after ES2022. The number T of ADR 0003 (testing.md §5.5) leaves them out, and this runner does not compute T.

## Totals

| Directory      | Tests | Baseline pass |  Pass | Fail | Compile | Timeout | Skip | Baseline rate | Pass rate |
| -------------- | ----: | ------------: | ----: | ---: | ------: | ------: | ---: | ------------: | --------: |
| test/language  | 23726 |         11354 | 23608 |  116 |       2 |       0 |    0 |         51.1% |     99.5% |
| test/built-ins | 23823 |          6193 | 23348 |  469 |       0 |       4 |    2 |         26.2% |     98.0% |
| **Total**      | 47549 |         17547 | 46956 |  585 |       2 |       4 |    2 |         38.3% |     98.7% |

The same run without the proposal tests. A proposal test has a feature from the "Proposed language features" part of test262's `features.txt`. At the pinned commit, Temporal, `explicit-resource-management`, `joint-iteration`, `iterator-chunking`, and `iterator-includes` are in the standard part, so these counts keep them. The proposal tests are 532 in `test/language` and 285 in `test/built-ins`.

| Directory      | Tests |  Pass | Fail | Compile | Timeout | Skip | Pass rate |
| -------------- | ----: | ----: | ---: | ------: | ------: | ---: | --------: |
| test/language  | 23194 | 23097 |   97 |       0 |       0 |    0 |     99.6% |
| test/built-ins | 23538 | 23332 |  200 |       0 |       4 |    2 |     99.1% |
| **Total**      | 46732 | 46429 |  297 |       0 |       4 |    2 |     99.3% |

Temporal passes 4589 of its 4605 tests in this run and 4597 when the 8 tests that the runner lost run alone (cause 5 and the rest, below).

## Run log

- 2026-10-17, commit `7090eb1`: the baseline. Other workflows kept the load average between 40 and 95 during the run, so the 3 timeouts are an upper bound.
- 2026-10-17, five area branches started from `8a5ddfc`, each alone. Their full runs, against the baseline of 11354 passes in `test/language` and 6193 in `test/built-ins`:
  - `engine-objects` at `9a6ba4d`, functions and objects: 14049 and 8614. `noStrict` tests run as sloppy code from this branch on.
  - `engine-classes` at `bccdd13`, classes and iteration: 19265 and 6785.
  - `engine-modules` at `df30d18`, ES modules and CommonJS: 12174 and 6203. The runner writes each test next to its fixtures, compiles a test without the `module` flag as a classic script, and ignores unhandled rejections, as test262 hosts do.
  - `engine-primitives` at `b80f085`, the primitive built-ins: 12091 and 12204.
  - `engine-regexp` at `7a043c3`, regular expressions: 11602 and 8286.
- 2026-10-17, the merges into `engine`, each run in full: `198bc70` (objects and classes) 21337 and 9295; `89ec6cf` (with modules) 22318 and 9306; `1be63e7` (with primitives) 23142 and 15634; `4c8687c` (with regular expressions) 23425 and 18011. The load average stayed between 18 and 55.
- Each merge run was compared test by test with the five area runs. At `4c8687c`, 6 tests pass on an area branch and fail on `engine`. Four are the `*-element-function-nonconstructor` tests of `Promise.all`, `allSettled`, and `any`: the branches passed them only because the `then` of the thenable never ran and the old `hasOwnProperty` accepted undefined. Two are tests of the `nonextensible-applies-to-private` proposal, which the classes branch passed because adding a private field threw for another reason. The other passes of every branch hold.
- 2026-10-17, commit `d93d434`, round 1 measurement: 23424 and 18010, with 8 jobs at a load average between 15 and 37. `test/built-ins` took 17 minutes. The engine code is the same as at `4c8687c`. The 2 fewer passes are 2 more timeouts: `test/language/comments/S7.4_A5.js` and `General_Category_-_Punctuation.js` of `RegExp/property-escapes`. Near test 23000 the VM halted with `no more index entries in fun_staged_index (max=524288)`: each test loads a module, and the fun table filled. The runner started a new VM, and the 8 Temporal tests that were running count as "the VM crashed".
- 2026-10-17, branch `engine-r1-temporal`: Temporal runs through temporal-polyfill 1.0.6, which `crates/bouy-cli/build.rs` compiles into the runtime (contract section 17.3). The full `test/built-ins` run at the first commit of the branch passed 22606, with 8 jobs at a load average between 15 and 50 in 23 minutes. The fun table filled near test 23000 again, and 8 tests of `Temporal/ZonedDateTime/from` count as "the VM crashed". `Function/prototype/toString/built-in-function-object.js` failed, because it reads the source text of every Temporal function. The final commit prints those functions as native code, and its reruns of `Temporal`, `Date`, and `Function/prototype/toString` pass every test of round 1 and 4605 more: `Temporal` 4597 of 4605 and `Date` 591 of 594, with the 8 tests of `Date.prototype.toTemporalInstant`. The rows and totals above use these reruns.
- 2026-10-17, branch `engine-r1-promise-spec`, the Promise family rewritten against ECMA-262 §27.2: `test/built-ins/Promise` 398 to 644 of 732, and the two `subclass-builtins` directories 68 to 70 of 72. The async directories of `test/language` (`async-*`, `await`, `for-await-of`), `AsyncFromSyncIteratorPrototype`, and `AsyncGeneratorPrototype` went from 2483 to 2485 of 2493 with the same failures otherwise: the 2 `yield-thenable-create-resolving-functions` tests of `async-generator` now pass. The rows above changed by these test-by-test deltas, without a full run. `Promise.try` follows ecma262 PR 3883, which the pinned test262 tests: a promise of the receiver that the callback returns comes back unwrapped.
- 2026-10-17, branch `engine-r1-iterator-zip-chunks-includes` at `6088539`: `Iterator.zip`, `Iterator.zipKeyed`, and `Iterator.prototype.chunks`, `windows`, and `includes`. `test/built-ins/Iterator` passes 637 of 654 tests, up from 451. All 186 tests of `zip`, `zipKeyed`, `chunks`, `windows`, and `includes` pass. The 17 failures left are the 16 tests of the `Iterator.prototype.join` proposal and `proto-from-ctor-realm.js`, which needs `$262.createRealm`.
- 2026-10-17, branch `engine-r1-direct-eval-context` from `38d7857`, direct eval: `test/language` passes 23603 tests, 179 more than the round 1 run, with no timeouts. The directories of the cluster (`eval-code`, `statements`, `expressions/class/elements`, `expressions/super`, `statementList`, `comments`, and `literals/regexp`, 11588 tests) went from 11398 passes to 11554. The `Function`, `GeneratorFunction`, `AsyncFunction`, `AsyncGeneratorFunction`, `eval`, `global`, `String`, `Object`, and `RegExp` directories of `test/built-ins` keep their passes. With 6 jobs at a load average between 30 and 65, 52 `RegExp/property-escapes` tests timed out on this branch and on `38d7857` alike, and passed on both with a 60 s limit, so the `test/built-ins` row keeps the round 1 count.
- 2026-10-17, branch `engine-r1-disposable-stacks` at `974bbcd`: `DisposableStack` and `AsyncDisposableStack`. Their two directories pass 195 of 197 tests, up from 0. The 2 failures are the `proto-from-ctor-realm.js` tests, which need `$262.createRealm`.
- 2026-10-17, commit `a7a0b11`, the round 1 merge of the five branches above into `engine`: 23608 and 23231, with 8 jobs. `test/language` took 16 minutes at a load average between 15 and 60, and `test/built-ins` took 24 minutes at a load average between 17 and 79. Compared test by test with the round 1 run and the branch runs, no test that passed before fails, apart from the 13 tests that the runner lost. `test/language` passes the 179 tests of the eval branch and 5 tests of the Promise branch: the 2 `yield-thenable-create-resolving-functions` tests, the 2 `subclass-Promise` tests, and `import-defer-transitive-async-module/promise-prototype-then-not-called.js`. `test/built-ins` passes 23244 of its tests when the 13 tests that the runner lost run alone. Near test 20000 the fun table filled again, and 8 tests of `Temporal/ZonedDateTime/from` count as "the VM crashed". 5 tests of `RegExp/property-escapes` timed out. A rerun of these 13 tests alone passes all of them. The merge changes one call: `crates/bouy-cli/build.rs` passes the default `EvalContext` to `compile_eval`, and `bouy_ref_temporal` calls `'__eval__'/3`.
- 2026-10-17, commit `f433f10`, round 2 measurement: 23608 and 23232, with 8 jobs. `test/language` took 18 minutes and `test/built-ins` 19 minutes, at a load average between 19 and 46. The engine code is the same as at `a7a0b11`. `test/language` fails the same 118 tests. `test/built-ins` fails the same tests apart from the ones that the runner lost: the fun table filled near test 20000 again, so 8 tests of `Temporal/ZonedDateTime/from` count as "the VM crashed", and 4 `RegExp/property-escapes` tests timed out instead of 5. These 12 tests pass when they run alone, so `test/built-ins` passes 23244. The causes below come from this run.

- 2026-10-17, branch `engine-r2-atomics-agents`, cause 2 below: `test/built-ins/Atomics` passes 378 of 389 tests, up from 262, in two runs with 8 jobs at load averages between 42 and 182. The runner defines `$262.agent`, and `bouy_ref_waiters` keeps the waiter lists of `Atomics.wait`, `waitAsync`, and `notify` (contract section 17.3). All 116 tests of the cause pass. The 9 failures left are the `immutable-buffer` tests, and the 2 `CanBlockIsFalse` tests stay skipped. `Promise`, `TypedArray`, `TypedArrayConstructors`, `ArrayBuffer`, `SharedArrayBuffer`, and `DataView` keep their 3637 passes, `test/harness` its 111, and the async directories of `test/language` fail only the 6 tests of causes 1 and 3.

## Causes left

The failures of the round 2 run without the proposal tests (417, timeouts included), grouped by root cause and largest first. One agent can fix each of the first five causes without the code of the others. Causes 1, 2, and 3 each add a member to the `HOST` line of `$262` in `crates/bouy-cli/src/bin/test262-dev.rs`, and cause 1 reuses the `evalScript` of cause 3 for the new realm.

1. **Realms (181 tests).** The runner gives no `$262.createRealm`, and one process can hold only one realm: each intrinsic is an atom key with a static record in `persistent_term` (`bouy_heap:intrinsic_record/2`), and a builtin function is the same term in every realm. The tests are in `Proxy` (37), `TypedArrayConstructors` (24), `Symbol` (17), `language/expressions` (16), `Array` (16), `Function` (13), `RegExp` (12), and 30 other directories. Most check the realm of the default prototype in GetPrototypeFromConstructor (44 `proto-from-ctor-realm.js` and more variants), `cross-realm.js` (28), and the realm of the TypeError of a Proxy trap check (13 `trap-is-not-callable-realm.js`).
2. **Agents (116 tests, all in `Atomics`).** The runner gives no `$262.agent`, so 112 tests fail at `getReport`. `bouy_ref_atomics` keeps no waiter list: `Atomics.notify` wakes nobody, and 4 `waitAsync` tests never settle.
3. **Environment records (51 tests, all in `test/language`).** The object environment of `with` (24): a write does not check HasProperty again before it sets, so strict code does not throw a ReferenceError when the binding is gone (16 `*-calls-putvalue-*` tests), and the order of Proxy traps differs (8 `statements/with` tests). The global environment (15): the runner gives no `$262.evalScript` (10 `global-code` tests), the top-level `let`, `const`, and `class` of a script are not in a global declarative record, so indirect eval cannot see them (3), `let undefined;` does not throw a SyntaxError, and a strict assignment to a name that its right side creates does not throw a ReferenceError. Other bindings (12): a closure that writes a `let` before its initialization (4), the per-iteration copy of a `for` head and the inner name of a class heritage (3), and `arguments` as a destructuring target of sloppy `for await` (5).
4. **Object operations out of specification order (29 tests).** CopyDataProperties reads the string keys and then the symbols, not the [[OwnPropertyKeys]] of a Proxy with [[GetOwnProperty]] for each key (6). ArraySetLength and `splice` (4). The TypedArray [[Set]] through a prototype chain, the TypedArray constructor, and `Object.freeze` over a resizable buffer (6). PutValue on a primitive base and a `super` write in sloppy code (3). `JSON.parse` revivers that ignore a failed delete (2). 8 others: `Object.prototype.valueOf` on a primitive, GetPrototypeFromConstructor in `WeakRef` and `FinalizationRegistry`, a revoked Proxy as new.target, the order of `null[key]`, the order of keyed destructuring, and `concat` of sloppy `arguments` with duplicate parameter names.
5. **The runner (13 tests).** The fun table of the VM fills near test 20000 of `test/built-ins` (`no more index entries in fun_staged_index (max=524288)`), although the runner purges the module of each test, and the 8 tests that run then count as "the VM crashed". 4 `RegExp/property-escapes/generated` tests time out at a load average near 40 and pass alone. The frontmatter parser does not split on CR, so `line-terminator-normalisation-CR.js` loses its `includes`.

The rest (27 tests): functions, classes, and modules (15: `arguments.callee.caller` is null, `class extends` an arrow or async function, a class name that overwrites a static `name` method, `(a?.b)()` without its this, Function subclasses, `import()` of a specifier that only run time knows or from eval code, a script that imports itself, the template object of eval code, the delete of an uninitialized export of a namespace, and one `for-in` test); Temporal (8, the polyfill causes of round 1: 6 tests replace `Array.prototype[Symbol.iterator]` or `Number.isFinite`, and 2 need exact arithmetic); and realms that grow past 256 MB (3 `copyWithin` tests and `tco-call-args.js`).

The proposal tests that fail (290) are `await-dictionary` (87), ShadowRealm (64), immutable `ArrayBuffer` (64), the `Error.prototype.stack` accessor (35), `Iterator.prototype.join` (16), source phase imports (12), and 12 others.

## test/language

| Directory                             | Tests | Baseline pass |  Pass | Fail | Compile | Timeout | Skip | Baseline rate | Pass rate |
| ------------------------------------- | ----: | ------------: | ----: | ---: | ------: | ------: | ---: | ------------: | --------: |
| test/language/arguments-object        |   263 |           104 |   261 |    2 |       0 |       0 |    0 |         50.4% |     99.2% |
| test/language/asi                     |   102 |           102 |   102 |    0 |       0 |       0 |    0 |        100.0% |    100.0% |
| test/language/block-scope             |   145 |           143 |   145 |    0 |       0 |       0 |    0 |         98.6% |    100.0% |
| test/language/comments                |    52 |            43 |    52 |    0 |       0 |       0 |    0 |         82.6% |    100.0% |
| test/language/computed-property-names |    48 |            39 |    48 |    0 |       0 |       0 |    0 |         81.2% |    100.0% |
| test/language/destructuring           |    19 |            12 |    18 |    1 |       0 |       0 |    0 |         66.6% |     94.7% |
| test/language/directive-prologue      |    62 |             5 |    62 |    0 |       0 |       0 |    0 |        100.0% |    100.0% |
| test/language/eval-code               |   347 |             9 |   344 |    3 |       0 |       0 |    0 |          7.0% |     99.1% |
| test/language/export                  |     3 |             3 |     3 |    0 |       0 |       0 |    0 |        100.0% |    100.0% |
| test/language/expressions             | 11102 |          4492 | 11049 |   52 |       1 |       0 |    0 |         42.7% |     99.5% |
| test/language/function-code           |   217 |            91 |   217 |    0 |       0 |       0 |    0 |         84.2% |    100.0% |
| test/language/future-reserved-words   |    55 |            47 |    55 |    0 |       0 |       0 |    0 |         97.9% |    100.0% |
| test/language/global-code             |    42 |            15 |    31 |   11 |       0 |       0 |    0 |         40.5% |     73.8% |
| test/language/identifier-resolution   |    14 |             3 |    13 |    1 |       0 |       0 |    0 |         33.3% |     92.9% |
| test/language/identifiers             |   268 |           267 |   268 |    0 |       0 |       0 |    0 |         99.6% |    100.0% |
| test/language/import                  |   129 |            10 |   117 |   12 |       0 |       0 |    0 |          7.7% |     90.7% |
| test/language/keywords                |    25 |            25 |    25 |    0 |       0 |       0 |    0 |        100.0% |    100.0% |
| test/language/line-terminators        |    41 |            32 |    41 |    0 |       0 |       0 |    0 |         78.0% |    100.0% |
| test/language/literals                |   536 |           279 |   536 |    0 |       0 |       0 |    0 |         53.4% |    100.0% |
| test/language/module-code             |   599 |           335 |   593 |    6 |       0 |       0 |    0 |         55.9% |     99.0% |
| test/language/punctuators             |    11 |            10 |    11 |    0 |       0 |       0 |    0 |         90.9% |    100.0% |
| test/language/reserved-words          |    27 |            26 |    27 |    0 |       0 |       0 |    0 |         96.2% |    100.0% |
| test/language/rest-parameters         |    11 |            10 |    11 |    0 |       0 |       0 |    0 |         90.9% |    100.0% |
| test/language/source-text             |     1 |             1 |     1 |    0 |       0 |       0 |    0 |        100.0% |    100.0% |
| test/language/statementList           |    80 |            32 |    80 |    0 |       0 |       0 |    0 |         40.0% |    100.0% |
| test/language/statements              |  9347 |          5109 |  9321 |   25 |       1 |       0 |    0 |         57.5% |     99.7% |
| test/language/types                   |   113 |            84 |   110 |    3 |       0 |       0 |    0 |         80.7% |     97.3% |
| test/language/white-space             |    67 |            26 |    67 |    0 |       0 |       0 |    0 |         38.8% |    100.0% |

## test/built-ins

| Directory                                     | Tests | Baseline pass | Pass | Fail | Compile | Timeout | Skip | Baseline rate | Pass rate |
| --------------------------------------------- | ----: | ------------: | ---: | ---: | ------: | ------: | ---: | ------------: | --------: |
| test/built-ins/AbstractModuleSource           |     8 |             0 |    0 |    8 |       0 |       0 |    0 |          0.0% |      0.0% |
| test/built-ins/AggregateError                 |    25 |            16 |   24 |    1 |       0 |       0 |    0 |         64.0% |     96.0% |
| test/built-ins/Array                          |  3083 |          1833 | 3062 |   21 |       0 |       0 |    0 |         60.1% |     99.3% |
| test/built-ins/ArrayBuffer                    |   221 |             0 |  193 |   28 |       0 |       0 |    0 |          0.0% |     87.3% |
| test/built-ins/ArrayIteratorPrototype         |    27 |             4 |   27 |    0 |       0 |       0 |    0 |         21.0% |    100.0% |
| test/built-ins/AsyncDisposableStack           |   104 |             0 |  103 |    1 |       0 |       0 |    0 |          0.0% |     99.0% |
| test/built-ins/AsyncFromSyncIteratorPrototype |    38 |             0 |   38 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/AsyncFunction                  |    18 |             6 |   17 |    1 |       0 |       0 |    0 |         33.3% |     94.4% |
| test/built-ins/AsyncGeneratorFunction         |    23 |             0 |   21 |    2 |       0 |       0 |    0 |          0.0% |     91.3% |
| test/built-ins/AsyncGeneratorPrototype        |    48 |             0 |   48 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/AsyncIteratorPrototype         |    13 |             0 |   13 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/Atomics                        |   389 |             0 |  378 |    9 |       0 |       0 |    2 |          0.0% |     97.6% |
| test/built-ins/BigInt                         |    77 |             0 |   76 |    1 |       0 |       0 |    0 |          0.0% |     98.7% |
| test/built-ins/Boolean                        |    51 |            28 |   50 |    1 |       0 |       0 |    0 |         54.9% |     98.0% |
| test/built-ins/DataView                       |   561 |             0 |  548 |   13 |       0 |       0 |    0 |          0.0% |     97.7% |
| test/built-ins/Date                           |   594 |            73 |  591 |    3 |       0 |       0 |    0 |         12.2% |     99.5% |
| test/built-ins/DisposableStack                |    93 |             0 |   92 |    1 |       0 |       0 |    0 |          0.0% |     98.9% |
| test/built-ins/Error                          |    93 |            36 |   55 |   38 |       0 |       0 |    0 |         38.7% |     59.1% |
| test/built-ins/FinalizationRegistry           |    47 |             0 |   45 |    2 |       0 |       0 |    0 |          0.0% |     95.7% |
| test/built-ins/Function                       |   509 |            97 |  494 |   15 |       0 |       0 |    0 |         23.0% |     97.1% |
| test/built-ins/GeneratorFunction              |    23 |             0 |   21 |    2 |       0 |       0 |    0 |          0.0% |     91.3% |
| test/built-ins/GeneratorPrototype             |    61 |            31 |   61 |    0 |       0 |       0 |    0 |         50.8% |    100.0% |
| test/built-ins/Infinity                       |     6 |             2 |    6 |    0 |       0 |       0 |    0 |         50.0% |    100.0% |
| test/built-ins/Iterator                       |   654 |            14 |  637 |   17 |       0 |       0 |    0 |          2.1% |     97.4% |
| test/built-ins/JSON                           |   166 |            93 |  162 |    4 |       0 |       0 |    0 |         56.0% |     97.6% |
| test/built-ins/Map                            |   204 |           114 |  203 |    1 |       0 |       0 |    0 |         56.1% |     99.5% |
| test/built-ins/MapIteratorPrototype           |    11 |             8 |   11 |    0 |       0 |       0 |    0 |         72.7% |    100.0% |
| test/built-ins/Math                           |   327 |           265 |  327 |    0 |       0 |       0 |    0 |         81.0% |    100.0% |
| test/built-ins/NaN                            |     6 |             2 |    6 |    0 |       0 |       0 |    0 |         50.0% |    100.0% |
| test/built-ins/NativeErrors                   |    94 |            32 |   88 |    6 |       0 |       0 |    0 |         34.0% |     93.6% |
| test/built-ins/Number                         |   340 |           219 |  339 |    1 |       0 |       0 |    0 |         64.4% |     99.7% |
| test/built-ins/Object                         |  3411 |          1761 | 3407 |    4 |       0 |       0 |    0 |         51.7% |     99.9% |
| test/built-ins/Promise                        |   732 |           373 |  644 |   88 |       0 |       0 |    0 |         51.1% |     88.0% |
| test/built-ins/Proxy                          |   311 |             0 |  274 |   37 |       0 |       0 |    0 |          0.0% |     88.1% |
| test/built-ins/Reflect                        |   153 |             0 |  153 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/RegExp                         |  1879 |             1 | 1863 |   12 |       0 |       4 |    0 |          0.0% |     99.1% |
| test/built-ins/RegExpStringIteratorPrototype  |    17 |             0 |   17 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/Set                            |   383 |           177 |  382 |    1 |       0 |       0 |    0 |         46.3% |     99.7% |
| test/built-ins/SetIteratorPrototype           |    11 |             8 |   11 |    0 |       0 |       0 |    0 |         72.7% |    100.0% |
| test/built-ins/ShadowRealm                    |    64 |             0 |    0 |   64 |       0 |       0 |    0 |          0.0% |      0.0% |
| test/built-ins/SharedArrayBuffer              |   104 |             0 |  103 |    1 |       0 |       0 |    0 |          0.0% |     99.0% |
| test/built-ins/String                         |  1223 |           673 | 1220 |    3 |       0 |       0 |    0 |         55.1% |     99.8% |
| test/built-ins/StringIteratorPrototype        |     7 |             4 |    7 |    0 |       0 |       0 |    0 |         57.1% |    100.0% |
| test/built-ins/SuppressedError                |    22 |             0 |   21 |    1 |       0 |       0 |    0 |          0.0% |     95.5% |
| test/built-ins/Symbol                         |    98 |            35 |   81 |   17 |       0 |       0 |    0 |         36.4% |     82.7% |
| test/built-ins/Temporal                       |  4605 |             0 | 4589 |   16 |       0 |       0 |    0 |          0.0% |     99.7% |
| test/built-ins/ThrowTypeError                 |    14 |             7 |   13 |    1 |       0 |       0 |    0 |         50.0% |     92.9% |
| test/built-ins/TypedArray                     |  1453 |             0 | 1442 |   11 |       0 |       0 |    0 |          0.0% |     99.2% |
| test/built-ins/TypedArrayConstructors         |   738 |             0 |  707 |   31 |       0 |       0 |    0 |          0.0% |     95.8% |
| test/built-ins/Uint8Array                     |    70 |             0 |   68 |    2 |       0 |       0 |    0 |          0.0% |     97.1% |
| test/built-ins/WeakMap                        |   141 |            86 |  140 |    1 |       0 |       0 |    0 |         60.9% |     99.3% |
| test/built-ins/WeakRef                        |    29 |             0 |   27 |    2 |       0 |       0 |    0 |          0.0% |     93.1% |
| test/built-ins/WeakSet                        |    85 |            62 |   84 |    1 |       0 |       0 |    0 |         72.9% |     98.8% |
| test/built-ins/decodeURI                      |    55 |             0 |   55 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/decodeURIComponent             |    56 |             0 |   56 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/encodeURI                      |    31 |             0 |   31 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/encodeURIComponent             |    31 |             0 |   31 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/eval                           |    10 |             0 |   10 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/global                         |    29 |            11 |   29 |    0 |       0 |       0 |    0 |         37.9% |    100.0% |
| test/built-ins/isFinite                       |    15 |            13 |   15 |    0 |       0 |       0 |    0 |         86.6% |    100.0% |
| test/built-ins/isNaN                          |    15 |            13 |   15 |    0 |       0 |       0 |    0 |         86.6% |    100.0% |
| test/built-ins/parseFloat                     |    54 |            49 |   54 |    0 |       0 |       0 |    0 |         90.7% |    100.0% |
| test/built-ins/parseInt                       |    55 |            46 |   55 |    0 |       0 |       0 |    0 |         83.6% |    100.0% |
| test/built-ins/undefined                      |     8 |             1 |    8 |    0 |       0 |       0 |    0 |         20.0% |    100.0% |
