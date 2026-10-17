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
| test/language  | 23726 | 11354 |  3776 |    7052 |       0 | 1544 |     51.1% |
| test/built-ins | 23823 |  6193 | 12764 |    4665 |       3 |  198 |     26.2% |
| **Total**      | 47549 | 17547 | 16540 |   11717 |       3 | 1742 |     38.3% |

## Run log

- 2026-10-17, commit `7090eb1`: the baseline. Other workflows kept the load average between 40 and 95 during the run, so the 3 timeouts are an upper bound.

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
| test/language/expressions             | 11102 | 4492 | 1406 |    4616 |       0 |  588 |     42.7% |
| test/language/function-code           |   217 |   91 |   17 |       0 |       0 |  109 |     84.2% |
| test/language/future-reserved-words   |    55 |   47 |    1 |       0 |       0 |    7 |     97.9% |
| test/language/global-code             |    42 |   15 |   20 |       2 |       0 |    5 |     40.5% |
| test/language/identifier-resolution   |    14 |    3 |    5 |       1 |       0 |    5 |     33.3% |
| test/language/identifiers             |   268 |  267 |    1 |       0 |       0 |    0 |     99.6% |
| test/language/import                  |   129 |   10 |    3 |     116 |       0 |    0 |      7.7% |
| test/language/keywords                |    25 |   25 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/line-terminators        |    41 |   32 |    9 |       0 |       0 |    0 |     78.0% |
| test/language/literals                |   536 |  279 |  196 |      47 |       0 |   14 |     53.4% |
| test/language/module-code             |   599 |  335 |   40 |     224 |       0 |    0 |     55.9% |
| test/language/punctuators             |    11 |   10 |    1 |       0 |       0 |    0 |     90.9% |
| test/language/reserved-words          |    27 |   26 |    1 |       0 |       0 |    0 |     96.2% |
| test/language/rest-parameters         |    11 |   10 |    1 |       0 |       0 |    0 |     90.9% |
| test/language/source-text             |     1 |    1 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/statementList           |    80 |   32 |   40 |       8 |       0 |    0 |     40.0% |
| test/language/statements              |  9347 | 5109 | 1824 |    1942 |       0 |  472 |     57.5% |
| test/language/types                   |   113 |   84 |   16 |       4 |       0 |    9 |     80.7% |
| test/language/white-space             |    67 |   26 |   16 |      25 |       0 |    0 |     38.8% |

## test/built-ins

| Directory                                     | Tests | Pass | Fail | Compile | Timeout | Skip | Pass rate |
| --------------------------------------------- | ----: | ---: | ---: | ------: | ------: | ---: | --------: |
| test/built-ins/AbstractModuleSource           |     8 |    0 |    8 |       0 |       0 |    0 |      0.0% |
| test/built-ins/AggregateError                 |    25 |   16 |    9 |       0 |       0 |    0 |     64.0% |
| test/built-ins/Array                          |  3083 | 1833 | 1174 |      40 |       0 |   36 |     60.1% |
| test/built-ins/ArrayBuffer                    |   221 |    0 |  216 |       5 |       0 |    0 |      0.0% |
| test/built-ins/ArrayIteratorPrototype         |    27 |    4 |   15 |       0 |       0 |    8 |     21.0% |
| test/built-ins/AsyncDisposableStack           |   104 |    0 |  100 |       4 |       0 |    0 |      0.0% |
| test/built-ins/AsyncFromSyncIteratorPrototype |    38 |    0 |    0 |      38 |       0 |    0 |      0.0% |
| test/built-ins/AsyncFunction                  |    18 |    6 |   12 |       0 |       0 |    0 |     33.3% |
| test/built-ins/AsyncGeneratorFunction         |    23 |    0 |   23 |       0 |       0 |    0 |      0.0% |
| test/built-ins/AsyncGeneratorPrototype        |    48 |    0 |   41 |       7 |       0 |    0 |      0.0% |
| test/built-ins/AsyncIteratorPrototype         |    13 |    0 |   12 |       1 |       0 |    0 |      0.0% |
| test/built-ins/Atomics                        |   389 |    0 |  200 |     187 |       0 |    2 |      0.0% |
| test/built-ins/BigInt                         |    77 |    0 |   34 |      43 |       0 |    0 |      0.0% |
| test/built-ins/Boolean                        |    51 |   28 |   22 |       1 |       0 |    0 |     54.9% |
| test/built-ins/DataView                       |   561 |    0 |  533 |      28 |       0 |    0 |      0.0% |
| test/built-ins/Date                           |   594 |   73 |  515 |       6 |       0 |    0 |     12.2% |
| test/built-ins/DisposableStack                |    93 |    0 |   92 |       1 |       0 |    0 |      0.0% |
| test/built-ins/Error                          |    93 |   36 |   52 |       5 |       0 |    0 |     38.7% |
| test/built-ins/FinalizationRegistry           |    47 |    0 |   47 |       0 |       0 |    0 |      0.0% |
| test/built-ins/Function                       |   509 |   97 |  248 |      76 |       0 |   88 |     23.0% |
| test/built-ins/GeneratorFunction              |    23 |    0 |   23 |       0 |       0 |    0 |      0.0% |
| test/built-ins/GeneratorPrototype             |    61 |   31 |   14 |      16 |       0 |    0 |     50.8% |
| test/built-ins/Infinity                       |     6 |    2 |    2 |       0 |       0 |    2 |     50.0% |
| test/built-ins/Iterator                       |   654 |   14 |  604 |      36 |       0 |    0 |      2.1% |
| test/built-ins/JSON                           |   166 |   93 |   66 |       7 |       0 |    0 |     56.0% |
| test/built-ins/Map                            |   204 |  114 |   86 |       3 |       0 |    1 |     56.1% |
| test/built-ins/MapIteratorPrototype           |    11 |    8 |    3 |       0 |       0 |    0 |     72.7% |
| test/built-ins/Math                           |   327 |  265 |   61 |       1 |       0 |    0 |     81.0% |
| test/built-ins/NaN                            |     6 |    2 |    2 |       0 |       0 |    2 |     50.0% |
| test/built-ins/NativeErrors                   |    94 |   32 |   62 |       0 |       0 |    0 |     34.0% |
| test/built-ins/Number                         |   340 |  219 |  116 |       5 |       0 |    0 |     64.4% |
| test/built-ins/Object                         |  3411 | 1761 | 1625 |      11 |       3 |   11 |     51.7% |
| test/built-ins/Promise                        |   732 |  373 |  345 |      11 |       0 |    3 |     51.1% |
| test/built-ins/Proxy                          |   311 |    0 |  292 |       8 |       0 |   11 |      0.0% |
| test/built-ins/Reflect                        |   153 |    0 |  153 |       0 |       0 |    0 |      0.0% |
| test/built-ins/RegExp                         |  1879 |    1 |  648 |    1229 |       0 |    1 |      0.0% |
| test/built-ins/RegExpStringIteratorPrototype  |    17 |    0 |    0 |      17 |       0 |    0 |      0.0% |
| test/built-ins/Set                            |   383 |  177 |  175 |      30 |       0 |    1 |     46.3% |
| test/built-ins/SetIteratorPrototype           |    11 |    8 |    3 |       0 |       0 |    0 |     72.7% |
| test/built-ins/ShadowRealm                    |    64 |    0 |   64 |       0 |       0 |    0 |      0.0% |
| test/built-ins/SharedArrayBuffer              |   104 |    0 |  102 |       2 |       0 |    0 |      0.0% |
| test/built-ins/String                         |  1223 |  673 |  432 |     115 |       0 |    3 |     55.1% |
| test/built-ins/StringIteratorPrototype        |     7 |    4 |    3 |       0 |       0 |    0 |     57.1% |
| test/built-ins/SuppressedError                |    22 |    0 |   22 |       0 |       0 |    0 |      0.0% |
| test/built-ins/Symbol                         |    98 |   35 |   61 |       0 |       0 |    2 |     36.4% |
| test/built-ins/Temporal                       |  4605 |    0 | 2280 |    2325 |       0 |    0 |      0.0% |
| test/built-ins/ThrowTypeError                 |    14 |    7 |    7 |       0 |       0 |    0 |     50.0% |
| test/built-ins/TypedArray                     |  1453 |    0 | 1150 |     295 |       0 |    8 |      0.0% |
| test/built-ins/TypedArrayConstructors         |   738 |    0 |  615 |     107 |       0 |   16 |      0.0% |
| test/built-ins/Uint8Array                     |    70 |    0 |   70 |       0 |       0 |    0 |      0.0% |
| test/built-ins/WeakMap                        |   141 |   86 |   55 |       0 |       0 |    0 |     60.9% |
| test/built-ins/WeakRef                        |    29 |    0 |   29 |       0 |       0 |    0 |      0.0% |
| test/built-ins/WeakSet                        |    85 |   62 |   23 |       0 |       0 |    0 |     72.9% |
| test/built-ins/decodeURI                      |    55 |    0 |   55 |       0 |       0 |    0 |      0.0% |
| test/built-ins/decodeURIComponent             |    56 |    0 |   56 |       0 |       0 |    0 |      0.0% |
| test/built-ins/encodeURI                      |    31 |    0 |   31 |       0 |       0 |    0 |      0.0% |
| test/built-ins/encodeURIComponent             |    31 |    0 |   31 |       0 |       0 |    0 |      0.0% |
| test/built-ins/eval                           |    10 |    0 |    9 |       1 |       0 |    0 |      0.0% |
| test/built-ins/global                         |    29 |   11 |   14 |       4 |       0 |    0 |     37.9% |
| test/built-ins/isFinite                       |    15 |   13 |    2 |       0 |       0 |    0 |     86.6% |
| test/built-ins/isNaN                          |    15 |   13 |    2 |       0 |       0 |    0 |     86.6% |
| test/built-ins/parseFloat                     |    54 |   49 |    5 |       0 |       0 |    0 |     90.7% |
| test/built-ins/parseInt                       |    55 |   46 |    9 |       0 |       0 |    0 |     83.6% |
| test/built-ins/undefined                      |     8 |    1 |    4 |       0 |       0 |    3 |     20.0% |

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
