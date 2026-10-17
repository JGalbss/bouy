# Engine progress

This file holds the test262 counts of the reference engine (`--semantics reference`, section 17 of [the contract](beam-runtime.md)). Each agent that changes the engine reruns the directories that its change touches, replaces their rows and the totals, and adds a line to the run log.

## How to run

```sh
scripts/test262-dev.sh --failures /tmp/language.txt test/language
scripts/test262-dev.sh --failures /tmp/built-ins.txt test/built-ins
```

Each command took about 11 minutes with 8 jobs on the 18-core development machine. The failures file lists each test that did not pass, with its first error line.

The columns of the tables:

- **Compile:** the compiler rejected the test with a Bouy diagnostic. Most are `BOUY206`, syntax that the reference lowering does not lower yet.
- **Skip:** a `noStrict` test (the engine compiles strict code only), a `CanBlockIsFalse` test, or an `IsHTMLDDA` test.
- **Pass rate:** the passes divided by the tests that ran, which are the tests minus the skips.

The counts include proposals, such as Temporal and ShadowRealm, and the features after ES2022. The number T of ADR 0003 (testing.md §5.5) leaves them out, and this runner does not compute T.

## Totals

| Directory      | Tests |  Pass |  Fail | Compile | Timeout | Skip | Pass rate |
| -------------- | ----: | ----: | ----: | ------: | ------: | ---: | --------: |
| test/language  | 23726 | 12091 |  3247 |    6844 |       0 | 1544 |     54.5% |
| test/built-ins | 23823 | 12204 |  8186 |    3232 |       3 |  198 |     51.6% |
| **Total**      | 47549 | 24295 | 11433 |   10076 |       3 | 1742 |     53.0% |

## Run log

- 2026-10-17, commit `7090eb1`: the baseline. Other workflows kept the load average between 40 and 95 during the run, so the 3 timeouts are an upper bound.
- 2026-10-17, branch `engine-primitives`, commit `b80f085`: the primitive built-ins (Number, String, BigInt, Boolean, Math, Date, JSON, Array, Map, Set, the errors, typed arrays, ArrayBuffer, DataView, and the URI functions). Both directories ran in full; the Atomics row comes from commit `0c2b661`. The load average was between 35 and 160, so a run took 27 minutes for test/built-ins and 10 for test/language.

## test/language

| Directory                             | Tests | Pass | Fail | Compile | Timeout | Skip | Pass rate |
| ------------------------------------- | ----: | ---: | ---: | ------: | ------: | ---: | --------: |
| test/language/arguments-object        |   263 |  104 |   42 |      60 |       0 |   57 |     50.4% |
| test/language/asi                     |   102 |  102 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/block-scope             |   145 |  143 |    0 |       2 |       0 |    0 |     98.6% |
| test/language/comments                |    52 |   43 |    9 |       0 |       0 |    0 |     82.6% |
| test/language/computed-property-names |    48 |   39 |    5 |       4 |       0 |    0 |     81.2% |
| test/language/destructuring           |    19 |   12 |    6 |       0 |       0 |    1 |     66.6% |
| test/language/directive-prologue      |    62 |    5 |    0 |       0 |       0 |   57 |    100.0% |
| test/language/eval-code               |   347 |    9 |  117 |       1 |       0 |  220 |      7.0% |
| test/language/export                  |     3 |    3 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/expressions             | 11102 | 5129 |  955 |    4430 |       0 |  588 |     48.7% |
| test/language/function-code           |   217 |   94 |   14 |       0 |       0 |  109 |     87.0% |
| test/language/future-reserved-words   |    55 |   47 |    1 |       0 |       0 |    7 |     97.9% |
| test/language/global-code             |    42 |   15 |   20 |       2 |       0 |    5 |     40.5% |
| test/language/identifier-resolution   |    14 |    3 |    5 |       1 |       0 |    5 |     33.3% |
| test/language/identifiers             |   268 |  267 |    1 |       0 |       0 |    0 |     99.6% |
| test/language/import                  |   129 |   10 |    3 |     116 |       0 |    0 |      7.7% |
| test/language/keywords                |    25 |   25 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/line-terminators        |    41 |   32 |    9 |       0 |       0 |    0 |     78.0% |
| test/language/literals                |   536 |  299 |  196 |      27 |       0 |   14 |     57.2% |
| test/language/module-code             |   599 |  336 |   39 |     224 |       0 |    0 |     56.0% |
| test/language/punctuators             |    11 |   10 |    1 |       0 |       0 |    0 |     90.9% |
| test/language/reserved-words          |    27 |   26 |    1 |       0 |       0 |    0 |     96.2% |
| test/language/rest-parameters         |    11 |   10 |    1 |       0 |       0 |    0 |     90.9% |
| test/language/source-text             |     1 |    1 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/statementList           |    80 |   32 |   40 |       8 |       0 |    0 |     40.0% |
| test/language/statements              |  9347 | 5179 | 1756 |    1940 |       0 |  472 |     58.3% |
| test/language/types                   |   113 |   90 |   10 |       4 |       0 |    9 |     86.5% |
| test/language/white-space             |    67 |   26 |   16 |      25 |       0 |    0 |     38.8% |

## test/built-ins

| Directory                                     | Tests | Pass | Fail | Compile | Timeout | Skip | Pass rate |
| --------------------------------------------- | ----: | ---: | ---: | ------: | ------: | ---: | --------: |
| test/built-ins/AbstractModuleSource           |     8 |    0 |    8 |       0 |       0 |    0 |      0.0% |
| test/built-ins/AggregateError                 |    25 |   20 |    5 |       0 |       0 |    0 |     80.0% |
| test/built-ins/Array                          |  3083 | 2791 |  225 |      31 |       0 |   36 |     91.5% |
| test/built-ins/ArrayBuffer                    |   221 |  179 |   41 |       1 |       0 |    0 |     80.9% |
| test/built-ins/ArrayIteratorPrototype         |    27 |   19 |    0 |       0 |       0 |    8 |    100.0% |
| test/built-ins/AsyncDisposableStack           |   104 |    0 |  100 |       4 |       0 |    0 |      0.0% |
| test/built-ins/AsyncFromSyncIteratorPrototype |    38 |    0 |    0 |      38 |       0 |    0 |      0.0% |
| test/built-ins/AsyncFunction                  |    18 |    8 |   10 |       0 |       0 |    0 |     44.4% |
| test/built-ins/AsyncGeneratorFunction         |    23 |    2 |   21 |       0 |       0 |    0 |      8.6% |
| test/built-ins/AsyncGeneratorPrototype        |    48 |    0 |   41 |       7 |       0 |    0 |      0.0% |
| test/built-ins/AsyncIteratorPrototype         |    13 |    0 |   13 |       0 |       0 |    0 |      0.0% |
| test/built-ins/Atomics                        |   389 |  209 |   14 |     164 |       0 |    2 |     54.0% |
| test/built-ins/BigInt                         |    77 |   74 |    3 |       0 |       0 |    0 |     96.1% |
| test/built-ins/Boolean                        |    51 |   45 |    5 |       1 |       0 |    0 |     88.2% |
| test/built-ins/DataView                       |   561 |  531 |   30 |       0 |       0 |    0 |     94.6% |
| test/built-ins/Date                           |   594 |  572 |   18 |       4 |       0 |    0 |     96.2% |
| test/built-ins/DisposableStack                |    93 |    0 |   92 |       1 |       0 |    0 |      0.0% |
| test/built-ins/Error                          |    93 |   49 |   40 |       4 |       0 |    0 |     52.6% |
| test/built-ins/FinalizationRegistry           |    47 |    0 |   47 |       0 |       0 |    0 |      0.0% |
| test/built-ins/Function                       |   509 |  104 |  241 |      76 |       0 |   88 |     24.7% |
| test/built-ins/GeneratorFunction              |    23 |    2 |   21 |       0 |       0 |    0 |      8.6% |
| test/built-ins/GeneratorPrototype             |    61 |   31 |   14 |      16 |       0 |    0 |     50.8% |
| test/built-ins/Infinity                       |     6 |    2 |    2 |       0 |       0 |    2 |     50.0% |
| test/built-ins/Iterator                       |   654 |   16 |  621 |      17 |       0 |    0 |      2.4% |
| test/built-ins/JSON                           |   166 |  137 |   28 |       1 |       0 |    0 |     82.5% |
| test/built-ins/Map                            |   204 |  198 |    4 |       1 |       0 |    1 |     97.5% |
| test/built-ins/MapIteratorPrototype           |    11 |   11 |    0 |       0 |       0 |    0 |    100.0% |
| test/built-ins/Math                           |   327 |  325 |    2 |       0 |       0 |    0 |     99.3% |
| test/built-ins/NaN                            |     6 |    2 |    2 |       0 |       0 |    2 |     50.0% |
| test/built-ins/NativeErrors                   |    94 |   76 |   18 |       0 |       0 |    0 |     80.8% |
| test/built-ins/Number                         |   340 |  334 |    3 |       3 |       0 |    0 |     98.2% |
| test/built-ins/Object                         |  3411 | 2102 | 1290 |       5 |       3 |   11 |     61.8% |
| test/built-ins/Promise                        |   732 |  376 |  348 |       5 |       0 |    3 |     51.5% |
| test/built-ins/Proxy                          |   311 |    0 |  292 |       8 |       0 |   11 |      0.0% |
| test/built-ins/Reflect                        |   153 |    0 |  153 |       0 |       0 |    0 |      0.0% |
| test/built-ins/RegExp                         |  1879 |    1 |  658 |    1219 |       0 |    1 |      0.0% |
| test/built-ins/RegExpStringIteratorPrototype  |    17 |    0 |    0 |      17 |       0 |    0 |      0.0% |
| test/built-ins/Set                            |   383 |  364 |   10 |       8 |       0 |    1 |     95.2% |
| test/built-ins/SetIteratorPrototype           |    11 |   11 |    0 |       0 |       0 |    0 |    100.0% |
| test/built-ins/ShadowRealm                    |    64 |    0 |   64 |       0 |       0 |    0 |      0.0% |
| test/built-ins/SharedArrayBuffer              |   104 |   93 |   11 |       0 |       0 |    0 |     89.4% |
| test/built-ins/String                         |  1223 |  994 |  126 |     100 |       0 |    3 |     81.4% |
| test/built-ins/StringIteratorPrototype        |     7 |    7 |    0 |       0 |       0 |    0 |    100.0% |
| test/built-ins/SuppressedError                |    22 |   17 |    5 |       0 |       0 |    0 |     77.2% |
| test/built-ins/Symbol                         |    98 |   69 |   27 |       0 |       0 |    2 |     71.8% |
| test/built-ins/Temporal                       |  4605 |    0 | 3128 |    1477 |       0 |    0 |      0.0% |
| test/built-ins/ThrowTypeError                 |    14 |    7 |    7 |       0 |       0 |    0 |     50.0% |
| test/built-ins/TypedArray                     |  1453 | 1311 |  116 |      18 |       0 |    8 |     90.7% |
| test/built-ins/TypedArrayConstructors         |   738 |  518 |  203 |       1 |       0 |   16 |     71.7% |
| test/built-ins/Uint8Array                     |    70 |   68 |    2 |       0 |       0 |    0 |     97.1% |
| test/built-ins/WeakMap                        |   141 |  137 |    4 |       0 |       0 |    0 |     97.1% |
| test/built-ins/WeakRef                        |    29 |    0 |   29 |       0 |       0 |    0 |      0.0% |
| test/built-ins/WeakSet                        |    85 |   82 |    3 |       0 |       0 |    0 |     96.4% |
| test/built-ins/decodeURI                      |    55 |   53 |    2 |       0 |       0 |    0 |     96.3% |
| test/built-ins/decodeURIComponent             |    56 |   54 |    2 |       0 |       0 |    0 |     96.4% |
| test/built-ins/encodeURI                      |    31 |   29 |    2 |       0 |       0 |    0 |     93.5% |
| test/built-ins/encodeURIComponent             |    31 |   29 |    2 |       0 |       0 |    0 |     93.5% |
| test/built-ins/eval                           |    10 |    0 |    9 |       1 |       0 |    0 |      0.0% |
| test/built-ins/global                         |    29 |   11 |   14 |       4 |       0 |    0 |     37.9% |
| test/built-ins/isFinite                       |    15 |   14 |    1 |       0 |       0 |    0 |     93.3% |
| test/built-ins/isNaN                          |    15 |   14 |    1 |       0 |       0 |    0 |     93.3% |
| test/built-ins/parseFloat                     |    54 |   52 |    2 |       0 |       0 |    0 |     96.2% |
| test/built-ins/parseInt                       |    55 |   53 |    2 |       0 |       0 |    0 |     96.3% |
| test/built-ins/undefined                      |     8 |    1 |    4 |       0 |       0 |    3 |     20.0% |

## Causes left in the primitive built-ins

After the primitives work (commit `b80f085`), 1,374 tests of its directories still fail: the built-ins of the primitive values, typed arrays, ArrayBuffer, DataView, the URI functions, `test/language/literals`, and the operator directories of `test/language/expressions`. Most wait on other areas of the engine. Each count is of tests whose first error has the cause.

| Cause                                                                                                                       | Tests | Area         |
| --------------------------------------------------------------------------------------------------------------------------- | ----: | ------------ |
| Regular expression literals, `RegExp`, and the `Symbol.match`, `replace`, `search`, and `split` protocols of String methods |   438 | RegExp       |
| `new Function`, `eval`, and the subclasses that `resizableArrayBufferUtils.js` makes with `new Function`                    |   234 | objects      |
| `Reflect` and `Proxy`                                                                                                       |   205 | objects      |
| `this` at the top level of a script, which test262 reads as the global object                                               |    55 | objects      |
| `$DONE` as a property of the global object, which `asyncTest` checks                                                        |    71 | objects      |
| `Object.isExtensible`, `preventExtensions`, and `defineProperties`                                                          |    57 | objects      |
| `$262.createRealm` and the other hooks of another realm                                                                     |    68 | test harness |
| `ArrayBuffer.prototype.transferToImmutable`, a proposal that Node 25 does not ship                                          |    50 | none         |
| A realm that grows past 256 MB in one long job, before the collector can run                                                |     3 | heap         |

## Largest causes at the baseline

Each count is the number of tests whose first error has this cause. When a cause is fixed, a test can fail on its next error.

Diagnostics at compile time:

| Cause                                                  | language | built-ins | Notes                                                                                                                                                           |
| ------------------------------------------------------ | -------: | --------: | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| a class expression                                     |     3683 |        25 | 3,368 are in `expressions/class`.                                                                                                                               |
| a regular expression literal                           |       79 |      2985 | About 1,600 are in harness files: `temporalHelpers.js` (1,480), `testTypedArray.js`, and `nativeFunctionMatcher.js`. Each test that includes one of them fails. |
| a BigInt literal                                       |      169 |      1434 |                                                                                                                                                                 |
| `yield*`                                               |      940 |        33 |                                                                                                                                                                 |
| `for await`                                            |      791 |         4 |                                                                                                                                                                 |
| `import()`                                             |      548 |         0 |                                                                                                                                                                 |
| one module only (`BOUY201`)                            |      226 |         1 | The engine does not load a second module yet.                                                                                                                   |
| a reference to a local variable before its declaration |      164 |       126 | Some are in `atomicsHelper.js`.                                                                                                                                 |

Errors at run time:

| Cause                                                                                                                            | language | built-ins |
| -------------------------------------------------------------------------------------------------------------------------------- | -------: | --------: |
| An assertion of the test failed (`Test262Error`)                                                                                 |     1382 |      3109 |
| A missing global for typed arrays: `ArrayBuffer`, `DataView`, `Atomics`, and the `*Array` classes                                |       44 |      2893 |
| `Temporal` is not defined                                                                                                        |        0 |      1929 |
| Another missing method (`x.y is not a function`), such as `Object.defineProperties` (407), `Object.isExtensible`, and `Date.UTC` |       22 |      1091 |
| Async generators: `object.then is not a function`                                                                                |      978 |        15 |
| `new String()`, `new Number()`, and `new Boolean()`                                                                              |      427 |       533 |
| `Iterator`, `Proxy`, `RegExp`, and `Reflect` are not defined                                                                     |       25 |      1230 |
| `eval` is not defined                                                                                                            |      381 |        40 |
| A `SyntaxError` test got another diagnostic: an early error that the compiler does not report                                    |      283 |       191 |
| The `Function` constructor                                                                                                       |       55 |       142 |
| A crash of `bouy_heap:record_of/1` (`function_clause`)                                                                           |        4 |       234 |
| `$262` is not defined: the host hooks of test262                                                                                 |       14 |       134 |
| The realm grew past 256 MB                                                                                                       |        2 |        79 |
| The generated Erlang does not compile                                                                                            |       46 |         4 |
