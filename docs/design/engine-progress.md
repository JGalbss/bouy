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
| test/language  | 23726 | 19204 |  1700 |    1278 |       0 | 1544 |     86.5% |
| test/built-ins | 23823 |  6757 | 12391 |    4475 |       2 |  198 |     28.6% |
| **Total**      | 47549 | 25961 | 14091 |    5753 |       2 | 1742 |     56.6% |

## Run log

- 2026-10-17, commit `7090eb1`: the baseline. Other workflows kept the load average between 40 and 95 during the run, so the 3 timeouts are an upper bound.
- 2026-10-17, branch `engine-classes`, commit `bbf22f9`: classes, generators, async iteration, iterator closing, the iterator helpers, function names, and the temporal dead zone (section "Classes and iteration"). `test/language` 11354 to 19204 passes, `test/built-ins` 6193 to 6757. The `test/built-ins` rows come from the run at commit `c0a4efa`, with the row of `Iterator` from the run at `bbf22f9`; the commits between changed only `Iterator` among the built-ins.

## test/language

| Directory                             | Tests | Pass | Fail | Compile | Timeout | Skip | Pass rate |
| ------------------------------------- | ----: | ---: | ---: | ------: | ------: | ---: | --------: |
| test/language/arguments-object        |   263 |  204 |    2 |       0 |       0 |   57 |     99.0% |
| test/language/asi                     |   102 |  102 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/block-scope             |   145 |  145 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/comments                |    52 |   43 |    9 |       0 |       0 |    0 |     82.6% |
| test/language/computed-property-names |    48 |   48 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/destructuring           |    19 |   17 |    1 |       0 |       0 |    1 |     94.4% |
| test/language/directive-prologue      |    62 |    5 |    0 |       0 |       0 |   57 |    100.0% |
| test/language/eval-code               |   347 |    9 |  117 |       1 |       0 |  220 |      7.0% |
| test/language/export                  |     3 |    3 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/expressions             | 11102 | 8907 |  763 |     844 |       0 |  588 |     84.7% |
| test/language/function-code           |   217 |   91 |   17 |       0 |       0 |  109 |     84.2% |
| test/language/future-reserved-words   |    55 |   48 |    0 |       0 |       0 |    7 |    100.0% |
| test/language/global-code             |    42 |   17 |   19 |       1 |       0 |    5 |     45.9% |
| test/language/identifier-resolution   |    14 |    3 |    5 |       1 |       0 |    5 |     33.3% |
| test/language/identifiers             |   268 |  268 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/import                  |   129 |   10 |    3 |     116 |       0 |    0 |      7.7% |
| test/language/keywords                |    25 |   25 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/line-terminators        |    41 |   32 |    9 |       0 |       0 |    0 |     78.0% |
| test/language/literals                |   536 |  279 |  196 |      47 |       0 |   14 |     53.4% |
| test/language/module-code             |   599 |  360 |   41 |     198 |       0 |    0 |     60.1% |
| test/language/punctuators             |    11 |   10 |    1 |       0 |       0 |    0 |     90.9% |
| test/language/reserved-words          |    27 |   26 |    1 |       0 |       0 |    0 |     96.2% |
| test/language/rest-parameters         |    11 |   11 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/source-text             |     1 |    1 |    0 |       0 |       0 |    0 |    100.0% |
| test/language/statementList           |    80 |   32 |   40 |       8 |       0 |    0 |     40.0% |
| test/language/statements              |  9347 | 8398 |  444 |      33 |       0 |  472 |     94.6% |
| test/language/types                   |   113 |   84 |   16 |       4 |       0 |    9 |     80.7% |
| test/language/white-space             |    67 |   26 |   16 |      25 |       0 |    0 |     38.8% |

## test/built-ins

| Directory                                     | Tests | Pass | Fail | Compile | Timeout | Skip | Pass rate |
| --------------------------------------------- | ----: | ---: | ---: | ------: | ------: | ---: | --------: |
| test/built-ins/AbstractModuleSource           |     8 |    0 |    8 |       0 |       0 |    0 |      0.0% |
| test/built-ins/AggregateError                 |    25 |   16 |    9 |       0 |       0 |    0 |     64.0% |
| test/built-ins/Array                          |  3083 | 1834 | 1187 |      26 |       0 |   36 |     60.1% |
| test/built-ins/ArrayBuffer                    |   221 |    0 |  217 |       4 |       0 |    0 |      0.0% |
| test/built-ins/ArrayIteratorPrototype         |    27 |    4 |   15 |       0 |       0 |    8 |     21.0% |
| test/built-ins/AsyncDisposableStack           |   104 |    0 |  102 |       2 |       0 |    0 |      0.0% |
| test/built-ins/AsyncFromSyncIteratorPrototype |    38 |   38 |    0 |       0 |       0 |    0 |    100.0% |
| test/built-ins/AsyncFunction                  |    18 |   10 |    8 |       0 |       0 |    0 |     55.5% |
| test/built-ins/AsyncGeneratorFunction         |    23 |    4 |   19 |       0 |       0 |    0 |     17.3% |
| test/built-ins/AsyncGeneratorPrototype        |    48 |   48 |    0 |       0 |       0 |    0 |    100.0% |
| test/built-ins/AsyncIteratorPrototype         |    13 |    3 |    9 |       1 |       0 |    0 |     23.0% |
| test/built-ins/Atomics                        |   389 |    0 |  274 |     113 |       0 |    2 |      0.0% |
| test/built-ins/BigInt                         |    77 |    0 |   34 |      43 |       0 |    0 |      0.0% |
| test/built-ins/Boolean                        |    51 |   28 |   22 |       1 |       0 |    0 |     54.9% |
| test/built-ins/DataView                       |   561 |    0 |  533 |      28 |       0 |    0 |      0.0% |
| test/built-ins/Date                           |   594 |   73 |  515 |       6 |       0 |    0 |     12.2% |
| test/built-ins/DisposableStack                |    93 |    0 |   92 |       1 |       0 |    0 |      0.0% |
| test/built-ins/Error                          |    93 |   36 |   54 |       3 |       0 |    0 |     38.7% |
| test/built-ins/FinalizationRegistry           |    47 |    0 |   47 |       0 |       0 |    0 |      0.0% |
| test/built-ins/Function                       |   509 |   99 |  251 |      71 |       0 |   88 |     23.5% |
| test/built-ins/GeneratorFunction              |    23 |    4 |   19 |       0 |       0 |    0 |     17.3% |
| test/built-ins/GeneratorPrototype             |    61 |   61 |    0 |       0 |       0 |    0 |    100.0% |
| test/built-ins/Infinity                       |     6 |    2 |    2 |       0 |       0 |    2 |     50.0% |
| test/built-ins/Iterator                       |   654 |  427 |  205 |      22 |       0 |    0 |     65.2% |
| test/built-ins/JSON                           |   166 |   93 |   66 |       7 |       0 |    0 |     56.0% |
| test/built-ins/Map                            |   204 |  114 |   86 |       3 |       0 |    1 |     56.1% |
| test/built-ins/MapIteratorPrototype           |    11 |    8 |    3 |       0 |       0 |    0 |     72.7% |
| test/built-ins/Math                           |   327 |  265 |   61 |       1 |       0 |    0 |     81.0% |
| test/built-ins/NaN                            |     6 |    2 |    2 |       0 |       0 |    2 |     50.0% |
| test/built-ins/NativeErrors                   |    94 |   32 |   62 |       0 |       0 |    0 |     34.0% |
| test/built-ins/Number                         |   340 |  219 |  116 |       5 |       0 |    0 |     64.4% |
| test/built-ins/Object                         |  3411 | 1776 | 1611 |      11 |       2 |   11 |     52.2% |
| test/built-ins/Promise                        |   732 |  375 |  348 |       6 |       0 |    3 |     51.4% |
| test/built-ins/Proxy                          |   311 |    0 |  292 |       8 |       0 |   11 |      0.0% |
| test/built-ins/Reflect                        |   153 |    0 |  153 |       0 |       0 |    0 |      0.0% |
| test/built-ins/RegExp                         |  1879 |    1 |  648 |    1229 |       0 |    1 |      0.0% |
| test/built-ins/RegExpStringIteratorPrototype  |    17 |    0 |    0 |      17 |       0 |    0 |      0.0% |
| test/built-ins/Set                            |   383 |  177 |  182 |      23 |       0 |    1 |     46.3% |
| test/built-ins/SetIteratorPrototype           |    11 |    8 |    3 |       0 |       0 |    0 |     72.7% |
| test/built-ins/ShadowRealm                    |    64 |    0 |   64 |       0 |       0 |    0 |      0.0% |
| test/built-ins/SharedArrayBuffer              |   104 |    0 |  102 |       2 |       0 |    0 |      0.0% |
| test/built-ins/String                         |  1223 |  673 |  432 |     115 |       0 |    3 |     55.1% |
| test/built-ins/StringIteratorPrototype        |     7 |    4 |    3 |       0 |       0 |    0 |     57.1% |
| test/built-ins/SuppressedError                |    22 |    0 |   22 |       0 |       0 |    0 |      0.0% |
| test/built-ins/Symbol                         |    98 |   35 |   61 |       0 |       0 |    2 |     36.4% |
| test/built-ins/Temporal                       |  4605 |    0 | 2280 |    2325 |       0 |    0 |      0.0% |
| test/built-ins/ThrowTypeError                 |    14 |    7 |    7 |       0 |       0 |    0 |     50.0% |
| test/built-ins/TypedArray                     |  1453 |    0 | 1154 |     291 |       0 |    8 |      0.0% |
| test/built-ins/TypedArrayConstructors         |   738 |    0 |  616 |     106 |       0 |   16 |      0.0% |
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

## Classes and iteration

The area of the `engine-classes` branch: classes, generators, async functions, async generators, `for...of` and `for await...of`, labeled statements, and the iterator helpers. "Before" is the run at commit `8a5ddfc`, and "after" is the run of the log above.

| Directory                                      | Tests | Pass before | Pass after | Rate before | Rate after |
| ---------------------------------------------- | ----: | ----------: | ---------: | ----------: | ---------: |
| test/language/statements/class                 |  4367 |        2646 |       4126 |       61.2% |      95.5% |
| test/language/expressions/class                |  4059 |         592 |       3860 |       14.8% |      96.7% |
| test/language/statements/for-of                |   751 |         503 |        671 |       70.5% |      94.1% |
| test/language/statements/for-await-of          |  1234 |          87 |       1197 |        7.2% |      99.4% |
| test/language/expressions/yield                |    63 |          18 |         60 |       29.5% |      98.3% |
| test/language/statements/generators            |   266 |         203 |        244 |       82.5% |      99.1% |
| test/language/expressions/generators           |   290 |         213 |        262 |       80.6% |      99.2% |
| test/language/expressions/async-arrow-function |    60 |          38 |         51 |       73.0% |      98.0% |
| test/language/expressions/async-function       |    93 |          58 |         73 |       78.3% |      98.6% |
| test/language/expressions/async-generator      |   623 |         178 |        596 |       29.6% |      99.3% |
| test/language/statements/async-function        |    74 |          51 |         62 |       79.6% |      96.8% |
| test/language/statements/async-generator       |   301 |          79 |        291 |       27.1% |     100.0% |
| test/language/statements/labeled               |    24 |          15 |         17 |       78.9% |      89.4% |
| test/language/expressions/await                |    22 |          13 |         22 |       59.0% |     100.0% |
| test/language/expressions/super                |    94 |          48 |         86 |       52.1% |      93.4% |
| test/language/expressions/new.target           |    14 |           2 |         11 |       14.2% |      78.5% |
| test/built-ins/GeneratorPrototype              |    61 |          31 |         61 |       50.8% |     100.0% |
| test/built-ins/AsyncGeneratorPrototype         |    48 |           0 |         48 |        0.0% |     100.0% |
| test/built-ins/Iterator                        |   654 |          14 |        427 |        2.1% |      65.2% |
| test/built-ins/GeneratorFunction               |    23 |           0 |          4 |        0.0% |      17.3% |
| test/built-ins/AsyncGeneratorFunction          |    23 |           0 |          4 |        0.0% |      17.3% |
| test/built-ins/AsyncFromSyncIteratorPrototype  |    38 |           0 |         38 |        0.0% |     100.0% |
| **Total**                                      | 13182 |        4789 |      12211 |       37.1% |      94.8% |

What the area changed:

- A class is made where its code runs. Each evaluation makes new private names, a private element lives under its name outside the own keys, and `#x in o` checks the brand. A derived constructor binds `this` in a cell that `super(...)` sets once (`bouy_ref_class`).
- Code at region depth `d` runs under a chain of handlers, one Erlang `try` per level, and `{'$k', F, A, Level}` peels one level at a time. So a `finally` block, a conditional expression, and a nested `try` can hold `await` or `yield`. Async generators, `yield*`, and `for await` are built on this (`bouy_ref_generator`).
- `for...of` and array patterns close their iterator on an abrupt exit, and a generator that returns at a `yield` inside them closes it too.
- Every function has a name and a length, from `NamedEvaluation` or its own name, and the name of a function expression refers to the function.
- A binding that code reads before its declaration runs is a cell that throws a `ReferenceError` until then (`early`).
- `Iterator` and its helpers of ES2025, and `Iterator.concat` (`bouy_ref_iterator_prototype`).

What the area leaves, by the cause of the first error:

| Cause                                                                                            |    Tests | Owner                                |
| ------------------------------------------------------------------------------------------------ | -------: | ------------------------------------ |
| `eval` (direct eval in the class element tests)                                                  |      193 | eval and the global scope            |
| Iterator proposals: `zip`, `zipKeyed`, `windows`, `chunks`, `includes`, `join`, `Symbol.dispose` |      211 | not at stage 4                       |
| `Function()` and the constructors of the function kinds, which compile source text               |       34 | eval                                 |
| `Proxy`, `Reflect`, typed arrays, `RegExp`, `BigInt`                                             | about 90 | built-ins                            |
| Bound functions and `Boolean`, `Number`, `String`, `Function` as constructors of a subclass      | about 30 | built-ins                            |
| Assignment to an undeclared name                                                                 |       15 | the global scope                     |
| A `Map` or a `Set` that changes while a `for...of` reads it                                      |        4 | `Map` and `Set` keep a snapshot list |
| The `accessor` keyword of the decorators proposal                                                |        2 | not at stage 4                       |
