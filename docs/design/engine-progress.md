# Engine progress

This file holds the test262 counts of the reference engine (`--semantics reference`, section 17 of [the contract](beam-runtime.md)). Each agent that changes the engine reruns the directories that its change touches, replaces their rows and the totals, and adds a line to the run log.

## How to run

```sh
scripts/test262-dev.sh --failures /tmp/language.txt test/language
scripts/test262-dev.sh --failures /tmp/built-ins.txt test/built-ins
```

Each command took about 11 minutes with 8 jobs on the 18-core development machine, and up to 25 minutes when other workflows kept the load average above 100. The failures file lists each test that did not pass, with its first error line. The runner gives the VM `BOUY_COMPILER`, the `bouy` binary next to it, which compiles the code of `eval` and `new Function`.

The columns of the tables:

- **Compile:** the compiler rejected the test with a Bouy diagnostic. Most are `BOUY206`, syntax that the reference lowering does not lower yet.
- **Skip:** a `CanBlockIsFalse` test or an `IsHTMLDDA` test. A `noStrict` test runs as sloppy code.
- **Pass rate:** the passes divided by the tests that ran, which are the tests minus the skips.

The counts include proposals, such as Temporal and ShadowRealm, and the features after ES2022. The number T of ADR 0003 (testing.md §5.5) leaves them out, and this runner does not compute T.

## Totals

| Directory      | Tests |  Pass |  Fail | Compile | Timeout | Skip | Pass rate |
| -------------- | ----: | ----: | ----: | ------: | ------: | ---: | --------: |
| test/language  | 23726 | 14049 |  2777 |    6897 |       3 |    0 |     59.2% |
| test/built-ins | 23823 |  8614 | 10640 |    4566 |       1 |    2 |     36.2% |
| **Total**      | 47549 | 22663 | 13417 |   11463 |       4 |    2 |     47.7% |

## Run log

- 2026-10-17, commit `7090eb1`: the baseline. Other workflows kept the load average between 40 and 95 during the run, so the 3 timeouts are an upper bound.
- 2026-10-17, branch `engine-objects` at commit `9a6ba4d` (the functions and objects area, alone): 22663 passes, up from 17547. `noStrict` tests now run as sloppy code instead of being skipped. The area directories, before and after: built-ins Object 1761 → 3011 of 3411, Function 97 → 391 of 509, Reflect 0 → 151 of 153, Proxy 0 → 257 of 311, Symbol 35 → 71 of 98, WeakMap 86 → 140 of 141, WeakSet 62 → 84 of 85, WeakRef 0 → 27 of 29, FinalizationRegistry 0 → 45 of 47; language (rerun at `219bd27`) expressions/call 69 → 90 of 92, expressions/new 56 → 56 of 59, arguments-object 104 → 161 of 263, function-code 91 → 211 of 217, statements/function 295 → 443 of 451, statements/variable 131 → 173 of 178. Most of the rest wait for primitive wrapper objects, regular expressions, class expressions, async generators, and `$262.createRealm`. The load average stayed between 35 and 175.
- 2026-10-17, branch `engine-objects` at commit `c516f2c`, reruns of single directories after later fixes (weak collection, array methods on proxies, eval declaration checks): built-ins Function 392 of 509, WeakMap, WeakSet, WeakRef, and FinalizationRegistry 296 of 302; language statements/function 446 of 451, eval-code 311 of 347, statements/with 170 of 181. The totals above are from `9a6ba4d`.

## test/language

| Directory                             | Tests | Pass | Fail | Compile | Timeout | Skip | Pass rate |
| ------------------------------------- | ----: | ---: | ---: | ------: | ------: | ---: | --------: |
| test/language/arguments-object        |   263 |  161 |   42 |      60 |       0 |    0 |     61.2% |
| test/language/asi                     |   102 |  102 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/block-scope             |   145 |  145 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/comments                |    52 |   48 |    2 |       0 |       2 |    0 |     92.3% |
| test/language/computed-property-names |    48 |   39 |    5 |       4 |       0 |    0 |     81.2% |
| test/language/destructuring           |    19 |   17 |    2 |       0 |       0 |    0 |     89.5% |
| test/language/directive-prologue      |    62 |   62 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/eval-code               |   347 |  307 |   40 |       0 |       0 |    0 |     88.5% |
| test/language/export                  |     3 |    3 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/expressions             | 11102 | 5357 | 1170 |    4574 |       1 |    0 |     48.3% |
| test/language/function-code           |   217 |  211 |    6 |       0 |       0 |    0 |     97.2% |
| test/language/future-reserved-words   |    55 |   54 |    1 |       0 |       0 |    0 |     98.2% |
| test/language/global-code             |    42 |   24 |   17 |       1 |       0 |    0 |     57.1% |
| test/language/identifier-resolution   |    14 |   13 |    1 |       0 |       0 |    0 |     92.9% |
| test/language/identifiers             |   268 |  267 |    1 |       0 |       0 |    0 |     99.6% |
| test/language/import                  |   129 |   10 |    3 |     116 |       0 |    0 |      7.8% |
| test/language/keywords                |    25 |   25 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/line-terminators        |    41 |   41 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/literals                |   536 |  311 |  178 |      47 |       0 |    0 |     58.0% |
| test/language/module-code             |   599 |  336 |   40 |     223 |       0 |    0 |     56.1% |
| test/language/punctuators             |    11 |   11 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/reserved-words          |    27 |   26 |    1 |       0 |       0 |    0 |     96.3% |
| test/language/rest-parameters         |    11 |   10 |    1 |       0 |       0 |    0 |     90.9% |
| test/language/source-text             |     1 |    1 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/statementList           |    80 |   60 |   12 |       8 |       0 |    0 |     75.0% |
| test/language/statements              |  9347 | 6270 | 1238 |    1839 |       0 |    0 |     67.1% |
| test/language/types                   |   113 |  101 |   12 |       0 |       0 |    0 |     89.4% |
| test/language/white-space             |    67 |   37 |    5 |      25 |       0 |    0 |     55.2% |

## test/built-ins

| Directory                                     | Tests | Pass | Fail | Compile | Timeout | Skip | Pass rate |
| --------------------------------------------- | ----: | ---: | ---: | ------: | ------: | ---: | --------: |
| test/built-ins/AbstractModuleSource           |     8 |    0 |    8 |       0 |       0 |    0 |      0.0% |
| test/built-ins/AggregateError                 |    25 |   21 |    4 |       0 |       0 |    0 |     84.0% |
| test/built-ins/Array                          |  3083 | 1898 | 1153 |      32 |       0 |    0 |     61.6% |
| test/built-ins/ArrayBuffer                    |   221 |    0 |  216 |       5 |       0 |    0 |      0.0% |
| test/built-ins/ArrayIteratorPrototype         |    27 |    8 |   19 |       0 |       0 |    0 |     29.6% |
| test/built-ins/AsyncDisposableStack           |   104 |    0 |  100 |       4 |       0 |    0 |      0.0% |
| test/built-ins/AsyncFromSyncIteratorPrototype |    38 |    0 |    0 |      38 |       0 |    0 |      0.0% |
| test/built-ins/AsyncFunction                  |    18 |   17 |    1 |       0 |       0 |    0 |     94.4% |
| test/built-ins/AsyncGeneratorFunction         |    23 |   15 |    8 |       0 |       0 |    0 |     65.2% |
| test/built-ins/AsyncGeneratorPrototype        |    48 |    0 |   41 |       7 |       0 |    0 |      0.0% |
| test/built-ins/AsyncIteratorPrototype         |    13 |    0 |   12 |       1 |       0 |    0 |      0.0% |
| test/built-ins/Atomics                        |   389 |    0 |  274 |     113 |       0 |    2 |      0.0% |
| test/built-ins/BigInt                         |    77 |    0 |   34 |      43 |       0 |    0 |      0.0% |
| test/built-ins/Boolean                        |    51 |   33 |   18 |       0 |       0 |    0 |     64.7% |
| test/built-ins/DataView                       |   561 |    0 |  533 |      28 |       0 |    0 |      0.0% |
| test/built-ins/Date                           |   594 |   82 |  506 |       6 |       0 |    0 |     13.8% |
| test/built-ins/DisposableStack                |    93 |    0 |   92 |       1 |       0 |    0 |      0.0% |
| test/built-ins/Error                          |    93 |   43 |   45 |       5 |       0 |    0 |     46.2% |
| test/built-ins/FinalizationRegistry           |    47 |   45 |    2 |       0 |       0 |    0 |     95.7% |
| test/built-ins/Function                       |   509 |  391 |   47 |      71 |       0 |    0 |     76.8% |
| test/built-ins/GeneratorFunction              |    23 |   21 |    2 |       0 |       0 |    0 |     91.3% |
| test/built-ins/GeneratorPrototype             |    61 |   40 |    5 |      16 |       0 |    0 |     65.6% |
| test/built-ins/Infinity                       |     6 |    6 |    0 |       0 |       0 |    0 |    100.0% |
| test/built-ins/Iterator                       |   654 |   14 |  604 |      36 |       0 |    0 |      2.1% |
| test/built-ins/JSON                           |   166 |  101 |   58 |       7 |       0 |    0 |     60.8% |
| test/built-ins/Map                            |   204 |  130 |   71 |       3 |       0 |    0 |     63.7% |
| test/built-ins/MapIteratorPrototype           |    11 |    8 |    3 |       0 |       0 |    0 |     72.7% |
| test/built-ins/Math                           |   327 |  266 |   60 |       1 |       0 |    0 |     81.3% |
| test/built-ins/NaN                            |     6 |    6 |    0 |       0 |       0 |    0 |    100.0% |
| test/built-ins/NativeErrors                   |    94 |   52 |   42 |       0 |       0 |    0 |     55.3% |
| test/built-ins/Number                         |   340 |  221 |  117 |       2 |       0 |    0 |     65.0% |
| test/built-ins/Object                         |  3411 | 3011 |  390 |      10 |       0 |    0 |     88.3% |
| test/built-ins/Promise                        |   732 |  388 |  335 |       9 |       0 |    0 |     53.0% |
| test/built-ins/Proxy                          |   311 |  257 |   46 |       8 |       0 |    0 |     82.6% |
| test/built-ins/Reflect                        |   153 |  151 |    2 |       0 |       0 |    0 |     98.7% |
| test/built-ins/RegExp                         |  1879 |    1 |  648 |    1230 |       0 |    0 |      0.1% |
| test/built-ins/RegExpStringIteratorPrototype  |    17 |    0 |    0 |      17 |       0 |    0 |      0.0% |
| test/built-ins/Set                            |   383 |  189 |  164 |      30 |       0 |    0 |     49.3% |
| test/built-ins/SetIteratorPrototype           |    11 |    8 |    3 |       0 |       0 |    0 |     72.7% |
| test/built-ins/ShadowRealm                    |    64 |    0 |   64 |       0 |       0 |    0 |      0.0% |
| test/built-ins/SharedArrayBuffer              |   104 |    0 |  102 |       2 |       0 |    0 |      0.0% |
| test/built-ins/String                         |  1223 |  685 |  421 |     116 |       1 |    0 |     56.0% |
| test/built-ins/StringIteratorPrototype        |     7 |    4 |    3 |       0 |       0 |    0 |     57.1% |
| test/built-ins/SuppressedError                |    22 |    0 |   22 |       0 |       0 |    0 |      0.0% |
| test/built-ins/Symbol                         |    98 |   71 |   27 |       0 |       0 |    0 |     72.4% |
| test/built-ins/Temporal                       |  4605 |    0 | 2280 |    2325 |       0 |    0 |      0.0% |
| test/built-ins/ThrowTypeError                 |    14 |   13 |    1 |       0 |       0 |    0 |     92.9% |
| test/built-ins/TypedArray                     |  1453 |    0 | 1161 |     292 |       0 |    0 |      0.0% |
| test/built-ins/TypedArrayConstructors         |   738 |    0 |  630 |     108 |       0 |    0 |      0.0% |
| test/built-ins/Uint8Array                     |    70 |    0 |   70 |       0 |       0 |    0 |      0.0% |
| test/built-ins/WeakMap                        |   141 |  140 |    1 |       0 |       0 |    0 |     99.3% |
| test/built-ins/WeakRef                        |    29 |   27 |    2 |       0 |       0 |    0 |     93.1% |
| test/built-ins/WeakSet                        |    85 |   84 |    1 |       0 |       0 |    0 |     98.8% |
| test/built-ins/decodeURI                      |    55 |    1 |   54 |       0 |       0 |    0 |      1.8% |
| test/built-ins/decodeURIComponent             |    56 |    1 |   55 |       0 |       0 |    0 |      1.8% |
| test/built-ins/encodeURI                      |    31 |    1 |   30 |       0 |       0 |    0 |      3.2% |
| test/built-ins/encodeURIComponent             |    31 |    1 |   30 |       0 |       0 |    0 |      3.2% |
| test/built-ins/eval                           |    10 |   10 |    0 |       0 |       0 |    0 |    100.0% |
| test/built-ins/global                         |    29 |   22 |    7 |       0 |       0 |    0 |     75.9% |
| test/built-ins/isFinite                       |    15 |   13 |    2 |       0 |       0 |    0 |     86.7% |
| test/built-ins/isNaN                          |    15 |   13 |    2 |       0 |       0 |    0 |     86.7% |
| test/built-ins/parseFloat                     |    54 |   50 |    4 |       0 |       0 |    0 |     92.6% |
| test/built-ins/parseInt                       |    55 |   47 |    8 |       0 |       0 |    0 |     85.5% |
| test/built-ins/undefined                      |     8 |    8 |    0 |       0 |       0 |    0 |    100.0% |

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

## Largest causes after the functions and objects area

The first error of each test that did not pass, at commit `9a6ba4d` of `engine-objects`:

| Cause                                                       | language | built-ins |
| ----------------------------------------------------------- | -------: | --------: |
| a class expression                                          |     3751 |        25 |
| a regular expression literal, or `RegExp`                   |      268 |      3533 |
| typed arrays, `ArrayBuffer`, `DataView`, and `Atomics`      |       45 |      2929 |
| `Temporal`                                                  |        0 |      1931 |
| a BigInt literal or `BigInt`                                |      170 |      1519 |
| async generators (`object.then is not a function`)          |     1183 |        19 |
| `yield*`                                                    |     1054 |        33 |
| `import()`, a second module, or `export default`            |      862 |         1 |
| `for await`                                                 |      820 |         4 |
| `new String()`, `new Number()`, and `new Boolean()`         |      432 |       558 |
| `$262`: `createRealm` and `agent`                           |       26 |       208 |
| an early error that the compiler does not report            |       53 |       105 |
| an assertion of the test (`Test262Error`) with another root |      532 |      2195 |
