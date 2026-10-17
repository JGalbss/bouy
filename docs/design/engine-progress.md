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
| test/language  | 23726 |         11354 | 23691 |   33 |       2 |       0 |    0 |         51.1% |     99.9% |
| test/built-ins | 23823 |          6193 | 23539 |  282 |       0 |       0 |    2 |         26.2% |     98.8% |
| **Total**      | 47549 |         17547 | 47230 |  315 |       2 |       0 |    2 |         38.3% |     99.3% |

The same run without the proposal tests. A proposal test has a feature from the "Proposed language features" part of test262's `features.txt`. At the pinned commit, Temporal, `explicit-resource-management`, `joint-iteration`, `iterator-chunking`, and `iterator-includes` are in the standard part, so these counts keep them. The proposal tests are 532 in `test/language` and 285 in `test/built-ins`.

| Directory      | Tests |  Pass | Fail | Compile | Timeout | Skip | Pass rate |
| -------------- | ----: | ----: | ---: | ------: | ------: | ---: | --------: |
| test/language  | 23194 | 23180 |   14 |       0 |       0 |    0 |     99.9% |
| test/built-ins | 23538 | 23523 |   13 |       0 |       0 |    2 |     99.9% |
| **Total**      | 46732 | 46703 |   27 |       0 |       0 |    2 |     99.9% |

Temporal passes 4597 of its 4605 tests (the rest, below).

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
- 2026-10-17, branch `engine-r2-realms-create-realm`: one process holds more realms, and the runner gives `$262.createRealm` and `$262.evalScript` (contract section 17.2). The 186 tests that call `createRealm` went from 0 passes to 179. Of the 181 that are not proposal tests, the 2 that fail are `derived-return-val-realm.js` and `derived-this-uninitialized-realm.js` of `Function/internals/Construct`: a derived constructor of another realm throws its TypeError and ReferenceError in its own realm, not in the realm of the caller. The other 5 are 3 ShadowRealm tests and 2 tests of the `error-stack-accessor` proposal. Full runs with 6 jobs and a 20 s limit at a load average between 90 and 150: `test/language` 23630 and `test/built-ins` 23377. The fun table filled again and 6 Temporal tests count as "the VM crashed", and 22 `RegExp/property-escapes/generated` tests timed out. These 28 tests pass when they run alone, so `test/built-ins` passes 23405, and the rows and totals above use that count. Each test that fails on the branch also fails at `abb1c84`. `test/language/global-code/script-decl-func-dups.js` passes through the new `evalScript`, an indirect eval of the realm, and `statements` and `expressions` each pass 1 more test without `createRealm` than the round 2 run.
- 2026-10-17, branch `engine-r2-atomics-agents`, cause 2 below: `test/built-ins/Atomics` passes 378 of 389 tests, up from 262, in two runs with 8 jobs at load averages between 42 and 182. The runner defines `$262.agent`, and `bouy_ref_waiters` keeps the waiter lists of `Atomics.wait`, `waitAsync`, and `notify` (contract section 17.3). All 116 tests of the cause pass. The 9 failures left are the `immutable-buffer` tests, and the 2 `CanBlockIsFalse` tests stay skipped. `Promise`, `TypedArray`, `TypedArrayConstructors`, `ArrayBuffer`, `SharedArrayBuffer`, and `DataView` keep their 3637 passes, `test/harness` its 111, and the async directories of `test/language` fail only the 6 tests of causes 1 and 3.
- 2026-10-17, branch `engine-r2-environment-records`, the environment records of ECMA-262 §9.1: `test/language` passes 23659 tests, the 51 tests of cause 3 more than the round 2 run, with no test that passed before failing. `statements` 9321 to 9340, `expressions` 11049 to 11067, `global-code` 31 to 42, `eval-code` 344 to 346, and `identifier-resolution` 13 to 14. The write of a new key through a typed array in the prototype chain now goes through the typed array's [[Set]], so 4 `TypedArrayConstructors/internals/Set/*-prototype-chain-set.js` tests of cause 4 pass too. The full `test/built-ins` run, with 8 jobs at a load average between 110 and 150, lost 57 tests: 49 `RegExp` timeouts, and 8 `Temporal/PlainYearMonth/prototype/since` tests when the fun table filled (cause 5). All 57 pass alone with a 60 s limit, and no other test that passed in round 2 fails, so the `test/built-ins` row is the round 2 count plus 4.
- 2026-10-17, branch `engine-r2-object-operation-order` from `abb1c84`, cause 4 of round 2: all 29 tests of the cause pass. The cluster directories of `test/built-ins` (`Array`, `TypedArray`, `TypedArrayConstructors`, `Object`, `JSON`, `WeakRef`, `FinalizationRegistry`, `Function`, and `Proxy`, 9747 tests) went from 9620 passes to 9638, and `test/language/expressions`, `types`, and `destructuring` (11234 tests) from 11177 to 11188, with 8 jobs at a load average between 110 and 155. No test that passed in the round 2 run fails. `statements/with/set-mutable-binding-binding-deleted-with-typed-array-in-proto-chain.js` of cause 3 passes too, through the fix of the typed array [[Set]]. `tests/reference/object-operation-order.ts` checks the same operations against Node.
- 2026-10-17, branch `engine-r2-runner-capacity`, the runner (cause 5): a VM runs at most 8000 tests and the runner then starts a new one, because a purge does not free the entries of the fun table. The frontmatter parser splits lines on CR, and a test that includes `regExpUtils.js` gets at least 60 s. The full `test/built-ins` run passed 23245 with 8 jobs, no lost test, and no timeout, in 14 minutes at a load average between 16 and 96. The engine code is the same as at `abb1c84`. A run before the last change had the same failures and one timeout more: `RegExp/CharacterClassEscapes/character-class-whitespace-class-escape-negative-cases.js`, which includes `regExpUtils.js`, timed out at 10 s at a load average near 150. In that run, the fullest of the 3 VMs held 351666 of the 524288 entries of the fun table.
- 2026-10-17, commit `6758f12`, the round 2 merge of the five branches above into `engine`: 23691 and 23539, with 8 jobs. `test/language` took 11 minutes and `test/built-ins` 17 minutes, at a load average between 25 and 60. No test was lost and none timed out. Compared test by test with the failures of the realms branch run, no test that passed there fails. The 266 cause tests of the realms, environment, and object-order branches fail only the 7 tests that the realms branch named, and `test/built-ins/Atomics` passes 378 of 389, as on the agents branch. The failures without the proposal tests went from 417 in the round 2 run to 27. The proposal tests fail the same 290 tests. Three merges needed more than a textual resolution: each realm of `$262.createRealm` gets the `evalScript` of the environment branch, GetPrototypeFromConstructor keeps the realm-aware `bouy_ref_realm:proto_for/2`, and a destructured `var` inside `with` writes through `bouy_ref:with_set/4`.

## Causes left

The failures of the round 2 run without the proposal tests (417, timeouts included), grouped by root cause and largest first. The round 2 merge at `6758f12` fixes the first five causes, and 27 of these failures are left: the 2 tests of cause 1 and the 25 tests of the rest.

1. **Realms (181 tests, 2 left).** Fixed by the branch `engine-r2-realms-create-realm` (run log). One process held only one realm, and the runner gave no `$262.createRealm`. Now the realm N names its intrinsics `{N, Id}` and copies their records on first use, and GetPrototypeFromConstructor takes the default from the realm of `new.target`. The 2 tests left are the derived constructors of `Function/internals/Construct`, whose errors must come from the realm of the caller.
2. **Agents (116 tests, all in `Atomics`), fixed by the branch `engine-r2-atomics-agents`.** The runner gave no `$262.agent`, so 112 tests failed at `getReport`. `bouy_ref_atomics` kept no waiter list: `Atomics.notify` woke nobody, and 4 `waitAsync` tests never settled.
3. **Environment records (51 tests, all in `test/language`), fixed by the branch `engine-r2-environment-records`.** The object environment of `with`, the global declarative record with `$262.evalScript`, the dead zone of a closure write, the per-iteration copy before the first test, the inner binding of a class heritage, and `arguments` as an assignment target.
4. **Object operations out of specification order (29 tests), fixed by the branch `engine-r2-object-operation-order`.** CopyDataProperties read the string keys and then the symbols, not the [[OwnPropertyKeys]] of a Proxy with [[GetOwnProperty]] for each key (6). ArraySetLength and `splice` (4). The TypedArray [[Set]] through a prototype chain, the TypedArray constructor, and `Object.freeze` over a resizable buffer (6). PutValue on a primitive base and a `super` write in sloppy code (3). `JSON.parse` revivers that ignore a failed delete (2). 8 others: `Object.prototype.valueOf` on a primitive, GetPrototypeFromConstructor in `WeakRef` and `FinalizationRegistry`, a revoked Proxy as new.target, the order of `null[key]`, the order of keyed destructuring, and `concat` of sloppy `arguments` with duplicate parameter names.
5. **The runner (13 tests), fixed by the branch `engine-r2-runner-capacity`.** The fun table of the VM filled near test 20000 of `test/built-ins` (`no more index entries in fun_staged_index (max=524288)`), although the runner purges the module of each test, and the 8 tests that ran then counted as "the VM crashed". 4 `RegExp/property-escapes/generated` tests timed out at a load average near 40 and passed alone. The frontmatter parser did not split on CR, so `line-terminator-normalisation-CR.js` lost its `includes`.

The rest (25 tests at `6758f12`, 27 in the round 2 run): functions, classes, and modules (13: `arguments.callee.caller` is null, `class extends` an arrow or async function, a class name that overwrites a static `name` method, `(a?.b)()` without its this, `import()` of a specifier that only run time knows or from eval code, a script that imports itself, the template object of eval code, the delete of an uninitialized export of a namespace, and one `for-in` test); Temporal (8, the polyfill causes of round 1: 6 tests replace `Array.prototype[Symbol.iterator]` or `Number.isFinite`, and 2 need exact arithmetic); and realms that grow past 256 MB (3 `copyWithin` tests and `tco-call-args.js`).

The proposal tests that fail (290) are `await-dictionary` (87), ShadowRealm (64), immutable `ArrayBuffer` (64), the `Error.prototype.stack` accessor (35), `Iterator.prototype.join` (16), source phase imports (12), and 12 others.

## test/language

| Directory                             | Tests | Baseline pass |  Pass | Fail | Compile | Timeout | Skip | Baseline rate | Pass rate |
| ------------------------------------- | ----: | ------------: | ----: | ---: | ------: | ------: | ---: | ------------: | --------: |
| test/language/arguments-object        |   263 |           104 |   261 |    2 |       0 |       0 |    0 |         50.4% |     99.2% |
| test/language/asi                     |   102 |           102 |   102 |    0 |       0 |       0 |    0 |        100.0% |    100.0% |
| test/language/block-scope             |   145 |           143 |   145 |    0 |       0 |       0 |    0 |         98.6% |    100.0% |
| test/language/comments                |    52 |            43 |    52 |    0 |       0 |       0 |    0 |         82.6% |    100.0% |
| test/language/computed-property-names |    48 |            39 |    48 |    0 |       0 |       0 |    0 |         81.2% |    100.0% |
| test/language/destructuring           |    19 |            12 |    19 |    0 |       0 |       0 |    0 |         66.6% |    100.0% |
| test/language/directive-prologue      |    62 |             5 |    62 |    0 |       0 |       0 |    0 |        100.0% |    100.0% |
| test/language/eval-code               |   347 |             9 |   347 |    0 |       0 |       0 |    0 |          7.0% |    100.0% |
| test/language/export                  |     3 |             3 |     3 |    0 |       0 |       0 |    0 |        100.0% |    100.0% |
| test/language/expressions             | 11102 |          4492 | 11093 |    8 |       1 |       0 |    0 |         42.7% |     99.9% |
| test/language/function-code           |   217 |            91 |   217 |    0 |       0 |       0 |    0 |         84.2% |    100.0% |
| test/language/future-reserved-words   |    55 |            47 |    55 |    0 |       0 |       0 |    0 |         97.9% |    100.0% |
| test/language/global-code             |    42 |            15 |    42 |    0 |       0 |       0 |    0 |         40.5% |    100.0% |
| test/language/identifier-resolution   |    14 |             3 |    14 |    0 |       0 |       0 |    0 |         33.3% |    100.0% |
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
| test/language/statements              |  9347 |          5109 |  9341 |    5 |       1 |       0 |    0 |         57.5% |     99.9% |
| test/language/types                   |   113 |            84 |   113 |    0 |       0 |       0 |    0 |         80.7% |    100.0% |
| test/language/white-space             |    67 |            26 |    67 |    0 |       0 |       0 |    0 |         38.8% |    100.0% |

## test/built-ins

| Directory                                     | Tests | Baseline pass | Pass | Fail | Compile | Timeout | Skip | Baseline rate | Pass rate |
| --------------------------------------------- | ----: | ------------: | ---: | ---: | ------: | ------: | ---: | ------------: | --------: |
| test/built-ins/AbstractModuleSource           |     8 |             0 |    0 |    8 |       0 |       0 |    0 |          0.0% |      0.0% |
| test/built-ins/AggregateError                 |    25 |            16 |   25 |    0 |       0 |       0 |    0 |         64.0% |    100.0% |
| test/built-ins/Array                          |  3083 |          1833 | 3083 |    0 |       0 |       0 |    0 |         60.1% |    100.0% |
| test/built-ins/ArrayBuffer                    |   221 |             0 |  194 |   27 |       0 |       0 |    0 |          0.0% |     87.8% |
| test/built-ins/ArrayIteratorPrototype         |    27 |             4 |   27 |    0 |       0 |       0 |    0 |         21.0% |    100.0% |
| test/built-ins/AsyncDisposableStack           |   104 |             0 |  104 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/AsyncFromSyncIteratorPrototype |    38 |             0 |   38 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/AsyncFunction                  |    18 |             6 |   18 |    0 |       0 |       0 |    0 |         33.3% |    100.0% |
| test/built-ins/AsyncGeneratorFunction         |    23 |             0 |   23 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/AsyncGeneratorPrototype        |    48 |             0 |   48 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/AsyncIteratorPrototype         |    13 |             0 |   13 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/Atomics                        |   389 |             0 |  378 |    9 |       0 |       0 |    2 |          0.0% |     97.7% |
| test/built-ins/BigInt                         |    77 |             0 |   77 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/Boolean                        |    51 |            28 |   51 |    0 |       0 |       0 |    0 |         54.9% |    100.0% |
| test/built-ins/DataView                       |   561 |             0 |  550 |   11 |       0 |       0 |    0 |          0.0% |     98.0% |
| test/built-ins/Date                           |   594 |            73 |  594 |    0 |       0 |       0 |    0 |         12.2% |    100.0% |
| test/built-ins/DisposableStack                |    93 |             0 |   93 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/Error                          |    93 |            36 |   58 |   35 |       0 |       0 |    0 |         38.7% |     62.4% |
| test/built-ins/FinalizationRegistry           |    47 |             0 |   47 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/Function                       |   509 |            97 |  507 |    2 |       0 |       0 |    0 |         23.0% |     99.6% |
| test/built-ins/GeneratorFunction              |    23 |             0 |   23 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/GeneratorPrototype             |    61 |            31 |   61 |    0 |       0 |       0 |    0 |         50.8% |    100.0% |
| test/built-ins/Infinity                       |     6 |             2 |    6 |    0 |       0 |       0 |    0 |         50.0% |    100.0% |
| test/built-ins/Iterator                       |   654 |            14 |  638 |   16 |       0 |       0 |    0 |          2.1% |     97.6% |
| test/built-ins/JSON                           |   166 |            93 |  166 |    0 |       0 |       0 |    0 |         56.0% |    100.0% |
| test/built-ins/Map                            |   204 |           114 |  204 |    0 |       0 |       0 |    0 |         56.1% |    100.0% |
| test/built-ins/MapIteratorPrototype           |    11 |             8 |   11 |    0 |       0 |       0 |    0 |         72.7% |    100.0% |
| test/built-ins/Math                           |   327 |           265 |  327 |    0 |       0 |       0 |    0 |         81.0% |    100.0% |
| test/built-ins/NaN                            |     6 |             2 |    6 |    0 |       0 |       0 |    0 |         50.0% |    100.0% |
| test/built-ins/NativeErrors                   |    94 |            32 |   94 |    0 |       0 |       0 |    0 |         34.0% |    100.0% |
| test/built-ins/Number                         |   340 |           219 |  340 |    0 |       0 |       0 |    0 |         64.4% |    100.0% |
| test/built-ins/Object                         |  3411 |          1761 | 3411 |    0 |       0 |       0 |    0 |         51.7% |    100.0% |
| test/built-ins/Promise                        |   732 |           373 |  645 |   87 |       0 |       0 |    0 |         51.1% |     88.1% |
| test/built-ins/Proxy                          |   311 |             0 |  311 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/Reflect                        |   153 |             0 |  153 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/RegExp                         |  1879 |             1 | 1879 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/RegExpStringIteratorPrototype  |    17 |             0 |   17 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/Set                            |   383 |           177 |  383 |    0 |       0 |       0 |    0 |         46.3% |    100.0% |
| test/built-ins/SetIteratorPrototype           |    11 |             8 |   11 |    0 |       0 |       0 |    0 |         72.7% |    100.0% |
| test/built-ins/ShadowRealm                    |    64 |             0 |    0 |   64 |       0 |       0 |    0 |          0.0% |      0.0% |
| test/built-ins/SharedArrayBuffer              |   104 |             0 |  104 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/String                         |  1223 |           673 | 1223 |    0 |       0 |       0 |    0 |         55.1% |    100.0% |
| test/built-ins/StringIteratorPrototype        |     7 |             4 |    7 |    0 |       0 |       0 |    0 |         57.1% |    100.0% |
| test/built-ins/SuppressedError                |    22 |             0 |   22 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/Symbol                         |    98 |            35 |   98 |    0 |       0 |       0 |    0 |         36.4% |    100.0% |
| test/built-ins/Temporal                       |  4605 |             0 | 4597 |    8 |       0 |       0 |    0 |          0.0% |     99.8% |
| test/built-ins/ThrowTypeError                 |    14 |             7 |   14 |    0 |       0 |       0 |    0 |         50.0% |    100.0% |
| test/built-ins/TypedArray                     |  1453 |             0 | 1442 |   11 |       0 |       0 |    0 |          0.0% |     99.2% |
| test/built-ins/TypedArrayConstructors         |   738 |             0 |  736 |    2 |       0 |       0 |    0 |          0.0% |     99.7% |
| test/built-ins/Uint8Array                     |    70 |             0 |   68 |    2 |       0 |       0 |    0 |          0.0% |     97.1% |
| test/built-ins/WeakMap                        |   141 |            86 |  141 |    0 |       0 |       0 |    0 |         60.9% |    100.0% |
| test/built-ins/WeakRef                        |    29 |             0 |   29 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/WeakSet                        |    85 |            62 |   85 |    0 |       0 |       0 |    0 |         72.9% |    100.0% |
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
