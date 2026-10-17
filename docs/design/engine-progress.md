# Engine progress

This file holds the test262 counts of the reference engine (`--semantics reference`, section 17 of [the contract](beam-runtime.md)). Each agent that changes the engine reruns the directories that its change touches, replaces their rows and the totals, and adds a line to the run log.

## How to run

```sh
scripts/test262-dev.sh --failures /tmp/language.txt test/language
scripts/test262-dev.sh --failures /tmp/built-ins.txt test/built-ins
```

With 8 jobs on the 18-core development machine, `test/language` took about 10 minutes and `test/built-ins` between 17 and 19 minutes at a load average between 15 and 55. The failures file lists each test that did not pass, with its first error line. The runner gives the VM `BOUY_COMPILER`, the `bouy` binary next to it, which compiles the code of `eval` and `new Function`.

The columns of the tables:

- **Baseline pass:** the passes of the directory at the baseline, commit `7090eb1`.
- **Compile:** the compiler rejected the test with a Bouy diagnostic, such as `BOUY206` for syntax that the reference lowering does not lower yet.
- **Skip:** a `CanBlockIsFalse` test or an `IsHTMLDDA` test. A `noStrict` test runs as sloppy code. The baseline skipped the `noStrict` tests: 1544 in `test/language` and 198 in `test/built-ins`.
- **Baseline rate** and **Pass rate:** the passes divided by the tests that ran, which are the tests minus the skips.

The counts include proposals, such as Temporal and ShadowRealm, and the features after ES2022. The number T of ADR 0003 (testing.md §5.5) leaves them out, and this runner does not compute T.

## Totals

| Directory      | Tests | Baseline pass |  Pass | Fail | Compile | Timeout | Skip | Baseline rate | Pass rate |
| -------------- | ----: | ------------: | ----: | ---: | ------: | ------: | ---: | ------------: | --------: |
| test/language  | 23726 |         11354 | 23424 |  293 |       2 |       7 |    0 |         51.1% |     98.7% |
| test/built-ins | 23823 |          6193 | 22615 | 1205 |       0 |       1 |    2 |         26.2% |     94.9% |
| **Total**      | 47549 |         17547 | 46039 | 1498 |       2 |       8 |    2 |         38.3% |     96.8% |

The same run without the proposal tests. A proposal test has a feature from the "Proposed language features" part of test262's `features.txt`. At the pinned commit, Temporal, `explicit-resource-management`, `joint-iteration`, `iterator-chunking`, and `iterator-includes` are in the standard part, so these counts keep them. The proposal tests are 532 in `test/language` and 285 in `test/built-ins`.

| Directory      | Tests |  Pass | Fail | Compile | Timeout | Skip | Pass rate |
| -------------- | ----: | ----: | ---: | ------: | ------: | ---: | --------: |
| test/language  | 23194 | 22914 |  273 |       0 |       7 |    0 |     98.7% |
| test/built-ins | 23538 | 22599 |  936 |       0 |       1 |    2 |     96.0% |
| **Total**      | 46732 | 45513 | 1209 |       0 |       8 |    2 |     97.4% |

Temporal passes 4597 of its 4605 tests. Its 8 failures also fail on Node 25.9 with the same polyfill (cause 1 below).

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

## Causes left

The failures of the round 1 run without the proposal tests (5812, timeouts included), grouped by root cause and largest first:

1. Temporal was not implemented (4595 tests). It runs now through the vendored polyfill, and 8 tests fail. Each of them fails on Node 25.9 with the same polyfill too. 6 tests replace `Array.prototype[Symbol.iterator]` or `Number.isFinite`, which the polyfill calls, and 2 tests of `Duration.prototype.total` need exact arithmetic where the polyfill computes in floating point. A fix belongs in the polyfill.
2. The Promise family does not follow the specification (249 tests: 247 in `test/built-ins/Promise` and the 2 `subclass-Promise` tests). The constructor ignores NewTarget. The statics ignore their `this` and never call `C.resolve`. `Symbol.species`, `Promise.try`, and the `length` and `name` of the resolving and element functions are missing. `all`, `allSettled`, `any`, and `race` read the whole iterable before they start, so the 20 tests with an endless iterator grow past 256 MB.
3. `DisposableStack` and `AsyncDisposableStack` do not exist (197 tests).
4. `Iterator.zip` and `Iterator.zipKeyed` (77 tests), `Iterator.prototype.chunks` and `windows` (69), and `Iterator.prototype.includes` (40) do not exist.
5. Direct eval (179 language tests whose source calls `eval`). `compile-eval` parses the eval code alone, so `super`, `new.target`, private names, and the `arguments` rule of class fields fail (about 70). The completion value of a loop, `if`, `switch`, `try`, or labeled statement is lost (about 63). A sloppy `var` in eval code becomes a global instead of a binding of the caller's function (about 35). Each new source text starts a `bouy compile-eval` process, so the 7 tests that call eval once per character time out.
6. `$262.createRealm` and `$262.evalScript`, which the runner does not provide (189 tests in 20 directories, such as `Proxy`, `TypedArrayConstructors`, `Symbol`, and `Array`). Intrinsics are shared through `persistent_term`, so a second realm in one process needs a redesign that touches every built-in module.
7. `Atomics.wait`, `waitAsync`, and `notify` (116 tests): the runner gives no `$262.agent`, and no buffer keeps a waiter list yet.
8. About 50 other tests in small groups, such as `with` scopes over a Proxy, PutValue on a deleted binding, and the 3 `copyWithin` tests that grow past 256 MB.

The proposal tests that fail (301) are mostly `Promise.allKeyed` and `allSettledKeyed` (87), ShadowRealm (64), immutable `ArrayBuffer` (59), and the `Error.prototype.stack` accessor (35).

## test/language

| Directory                             | Tests | Baseline pass |  Pass | Fail | Compile | Timeout | Skip | Baseline rate | Pass rate |
| ------------------------------------- | ----: | ------------: | ----: | ---: | ------: | ------: | ---: | ------------: | --------: |
| test/language/arguments-object        |   263 |           104 |   261 |    2 |       0 |       0 |    0 |         50.4% |     99.2% |
| test/language/asi                     |   102 |           102 |   102 |    0 |       0 |       0 |    0 |        100.0% |    100.0% |
| test/language/block-scope             |   145 |           143 |   145 |    0 |       0 |       0 |    0 |         98.6% |    100.0% |
| test/language/comments                |    52 |            43 |    47 |    2 |       0 |       3 |    0 |         82.6% |     90.3% |
| test/language/computed-property-names |    48 |            39 |    48 |    0 |       0 |       0 |    0 |         81.2% |    100.0% |
| test/language/destructuring           |    19 |            12 |    18 |    1 |       0 |       0 |    0 |         66.6% |     94.7% |
| test/language/directive-prologue      |    62 |             5 |    62 |    0 |       0 |       0 |    0 |        100.0% |    100.0% |
| test/language/eval-code               |   347 |             9 |   323 |   24 |       0 |       0 |    0 |          7.0% |     93.1% |
| test/language/export                  |     3 |             3 |     3 |    0 |       0 |       0 |    0 |        100.0% |    100.0% |
| test/language/expressions             | 11102 |          4492 | 10995 |  106 |       1 |       0 |    0 |         42.7% |     99.0% |
| test/language/function-code           |   217 |            91 |   217 |    0 |       0 |       0 |    0 |         84.2% |    100.0% |
| test/language/future-reserved-words   |    55 |            47 |    55 |    0 |       0 |       0 |    0 |         97.9% |    100.0% |
| test/language/global-code             |    42 |            15 |    31 |   11 |       0 |       0 |    0 |         40.5% |     73.8% |
| test/language/identifier-resolution   |    14 |             3 |    13 |    1 |       0 |       0 |    0 |         33.3% |     92.9% |
| test/language/identifiers             |   268 |           267 |   268 |    0 |       0 |       0 |    0 |         99.6% |    100.0% |
| test/language/import                  |   129 |            10 |   117 |   12 |       0 |       0 |    0 |          7.7% |     90.7% |
| test/language/keywords                |    25 |            25 |    25 |    0 |       0 |       0 |    0 |        100.0% |    100.0% |
| test/language/line-terminators        |    41 |            32 |    41 |    0 |       0 |       0 |    0 |         78.0% |    100.0% |
| test/language/literals                |   536 |           279 |   532 |    0 |       0 |       4 |    0 |         53.4% |     99.3% |
| test/language/module-code             |   599 |           335 |   593 |    6 |       0 |       0 |    0 |         55.9% |     99.0% |
| test/language/punctuators             |    11 |            10 |    11 |    0 |       0 |       0 |    0 |         90.9% |    100.0% |
| test/language/reserved-words          |    27 |            26 |    27 |    0 |       0 |       0 |    0 |         96.2% |    100.0% |
| test/language/rest-parameters         |    11 |            10 |    11 |    0 |       0 |       0 |    0 |         90.9% |    100.0% |
| test/language/source-text             |     1 |             1 |     1 |    0 |       0 |       0 |    0 |        100.0% |    100.0% |
| test/language/statementList           |    80 |            32 |    76 |    4 |       0 |       0 |    0 |         40.0% |     95.0% |
| test/language/statements              |  9347 |          5109 |  9225 |  121 |       1 |       0 |    0 |         57.5% |     98.7% |
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
| test/built-ins/AsyncDisposableStack           |   104 |             0 |    0 |  104 |       0 |       0 |    0 |          0.0% |      0.0% |
| test/built-ins/AsyncFromSyncIteratorPrototype |    38 |             0 |   38 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/AsyncFunction                  |    18 |             6 |   17 |    1 |       0 |       0 |    0 |         33.3% |     94.4% |
| test/built-ins/AsyncGeneratorFunction         |    23 |             0 |   21 |    2 |       0 |       0 |    0 |          0.0% |     91.3% |
| test/built-ins/AsyncGeneratorPrototype        |    48 |             0 |   48 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/AsyncIteratorPrototype         |    13 |             0 |   13 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/Atomics                        |   389 |             0 |  262 |  125 |       0 |       0 |    2 |          0.0% |     67.7% |
| test/built-ins/BigInt                         |    77 |             0 |   76 |    1 |       0 |       0 |    0 |          0.0% |     98.7% |
| test/built-ins/Boolean                        |    51 |            28 |   50 |    1 |       0 |       0 |    0 |         54.9% |     98.0% |
| test/built-ins/DataView                       |   561 |             0 |  548 |   13 |       0 |       0 |    0 |          0.0% |     97.7% |
| test/built-ins/Date                           |   594 |            73 |  591 |    3 |       0 |       0 |    0 |         12.2% |     99.5% |
| test/built-ins/DisposableStack                |    93 |             0 |    0 |   93 |       0 |       0 |    0 |          0.0% |      0.0% |
| test/built-ins/Error                          |    93 |            36 |   55 |   38 |       0 |       0 |    0 |         38.7% |     59.1% |
| test/built-ins/FinalizationRegistry           |    47 |             0 |   45 |    2 |       0 |       0 |    0 |          0.0% |     95.7% |
| test/built-ins/Function                       |   509 |            97 |  494 |   15 |       0 |       0 |    0 |         23.0% |     97.1% |
| test/built-ins/GeneratorFunction              |    23 |             0 |   21 |    2 |       0 |       0 |    0 |          0.0% |     91.3% |
| test/built-ins/GeneratorPrototype             |    61 |            31 |   61 |    0 |       0 |       0 |    0 |         50.8% |    100.0% |
| test/built-ins/Infinity                       |     6 |             2 |    6 |    0 |       0 |       0 |    0 |         50.0% |    100.0% |
| test/built-ins/Iterator                       |   654 |            14 |  451 |  203 |       0 |       0 |    0 |          2.1% |     69.0% |
| test/built-ins/JSON                           |   166 |            93 |  162 |    4 |       0 |       0 |    0 |         56.0% |     97.6% |
| test/built-ins/Map                            |   204 |           114 |  203 |    1 |       0 |       0 |    0 |         56.1% |     99.5% |
| test/built-ins/MapIteratorPrototype           |    11 |             8 |   11 |    0 |       0 |       0 |    0 |         72.7% |    100.0% |
| test/built-ins/Math                           |   327 |           265 |  327 |    0 |       0 |       0 |    0 |         81.0% |    100.0% |
| test/built-ins/NaN                            |     6 |             2 |    6 |    0 |       0 |       0 |    0 |         50.0% |    100.0% |
| test/built-ins/NativeErrors                   |    94 |            32 |   88 |    6 |       0 |       0 |    0 |         34.0% |     93.6% |
| test/built-ins/Number                         |   340 |           219 |  339 |    1 |       0 |       0 |    0 |         64.4% |     99.7% |
| test/built-ins/Object                         |  3411 |          1761 | 3407 |    4 |       0 |       0 |    0 |         51.7% |     99.9% |
| test/built-ins/Promise                        |   732 |           373 |  398 |  334 |       0 |       0 |    0 |         51.1% |     54.4% |
| test/built-ins/Proxy                          |   311 |             0 |  274 |   37 |       0 |       0 |    0 |          0.0% |     88.1% |
| test/built-ins/Reflect                        |   153 |             0 |  153 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/RegExp                         |  1879 |             1 | 1866 |   12 |       0 |       1 |    0 |          0.0% |     99.3% |
| test/built-ins/RegExpStringIteratorPrototype  |    17 |             0 |   17 |    0 |       0 |       0 |    0 |          0.0% |    100.0% |
| test/built-ins/Set                            |   383 |           177 |  382 |    1 |       0 |       0 |    0 |         46.3% |     99.7% |
| test/built-ins/SetIteratorPrototype           |    11 |             8 |   11 |    0 |       0 |       0 |    0 |         72.7% |    100.0% |
| test/built-ins/ShadowRealm                    |    64 |             0 |    0 |   64 |       0 |       0 |    0 |          0.0% |      0.0% |
| test/built-ins/SharedArrayBuffer              |   104 |             0 |  103 |    1 |       0 |       0 |    0 |          0.0% |     99.0% |
| test/built-ins/String                         |  1223 |           673 | 1220 |    3 |       0 |       0 |    0 |         55.1% |     99.8% |
| test/built-ins/StringIteratorPrototype        |     7 |             4 |    7 |    0 |       0 |       0 |    0 |         57.1% |    100.0% |
| test/built-ins/SuppressedError                |    22 |             0 |   21 |    1 |       0 |       0 |    0 |          0.0% |     95.5% |
| test/built-ins/Symbol                         |    98 |            35 |   80 |   18 |       0 |       0 |    0 |         36.4% |     81.6% |
| test/built-ins/Temporal                       |  4605 |             0 | 4597 |    8 |       0 |       0 |    0 |          0.0% |     99.8% |
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
