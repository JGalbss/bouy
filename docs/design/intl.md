# Intl

This file is the plan for `Intl` (ECMA-402) on the reference engine. It records the state on 2026-10-18 and the design that the work follows.

## State

- Buoy has no `Intl` global. `buoy_ref_temporal` gives the Temporal polyfill a slice of `Intl.DateTimeFormat` in the en-US locale, and `localeCompare` and `toLocaleString` honor a few options (`buoy_ref_string`, `buoy_ref_number`).
- `process.config.variables.hasIntl` is false (`buoy_binding_config`), so the tests of Node that need Intl skip.
- test262 `test/intl402` on the dev runner: 463 of 3382 tests pass, 439 of them in `Temporal`, which tests the ISO calendar too.

| Directory                                       | Tests | Needs                                                               |
| ----------------------------------------------- | ----: | ------------------------------------------------------------------- |
| Temporal                                        |  2029 | non-ISO calendars, eras and month codes, time zone names            |
| NumberFormat                                    |   251 | CLDR number patterns, numbering systems, currencies, units, plurals |
| DateTimeFormat                                  |   245 | CLDR date patterns, calendars, time zones, `formatRange`            |
| Locale                                          |   190 | BCP 47 canonicalization, likely subtags, locale info                |
| DurationFormat                                  |   110 | unit and list patterns                                              |
| ListFormat                                      |    81 | list patterns                                                       |
| RelativeTimeFormat                              |    80 | relative time patterns, plural rules                                |
| Segmenter                                       |    79 | grapheme, word, and sentence breaking                               |
| Intl, top level                                 |    88 | `getCanonicalLocales`, `supportedValuesOf`, locale negotiation      |
| Collator                                        |    65 | the Unicode Collation Algorithm with CLDR tailorings                |
| DisplayNames                                    |    57 | names of languages, regions, scripts, currencies, calendars         |
| PluralRules                                     |    53 | CLDR plural rules                                                   |
| String, Number, BigInt, Date, Array, TypedArray |    52 | the locale-sensitive methods                                        |
| FallbackSymbol                                  |     2 | the legacy constructor behavior of NumberFormat and DateTimeFormat  |

## What Node and Bun do

Node 25.9 is built with full ICU: every CLDR locale. Its output is the oracle of the tests, so Buoy must produce the same strings.

Bun links ICU4C into JavaScriptCore: the system `icucore` on macOS, and the ICU that its prebuilt WebKit bundles on Linux (`scripts/build/bun.ts`). JavaScriptCore implements ECMA-402 in C++ on ICU. V8 splits the work the same way: the abstract operations of ECMA-402 in V8, the data and the algorithms in ICU.

## Design

Buoy follows the same split, with ICU4X in place of ICU4C:

1. **Data and algorithms: ICU4X in a NIF crate**, `crates/buoy-intl`. ICU4X is the Unicode Consortium's Rust implementation of ICU, with CLDR data baked into the binary. It covers collation, date and time formatting with calendars and time zones, decimal and compact numbers, plural rules, lists, segmentation, locale canonicalization, and likely subtags. A format call takes microseconds, so it runs as a normal NIF; loading the data runs once per VM on a dirty scheduler. The crate uses the NIF mechanism that the native tier brings (`buoy-jit`, branch `node-perf-native`).
2. **ECMA-402 in Erlang**, one runtime module per constructor (`buoy_ref_intl_number_format` and so on, with the shared abstract operations in `buoy_ref_intl`): `CanonicalizeLocaleList`, `ResolveLocale`, option reading and validation, the resolved options, `PartitionPattern`, and the `formatToParts` results. These algorithms observe user code (getters of options, `valueOf`), so they stay in the engine, where the order of operations is tested.
3. **Gaps**: where ICU4X lacks a feature, such as some display names and unit patterns in its 2.x releases, or where its CLDR version gives other strings than Node's ICU in a tested case, the build generates the missing data from the cldr-json release that matches Node's CLDR version and compiles it into Erlang terms.

A pure JavaScript polyfill, such as FormatJS compiled as internal code like the Temporal polyfill, was the other option. It needs no native code, but it has no Collator, its locale data is large JavaScript, it is slower, and its strings differ from ICU in places, so it would fail the Node oracle where Node users notice. ICU4C through a NIF would give Node's exact strings, but it needs a C and C++ build of ICU for each release target; ICU4X builds with Cargo like the rest of Buoy.

## Phases

Each phase ends with its test262 directories and the Node tests of its area at 100%, apart from reviewed entries.

1. `Intl.Locale`, `Intl.getCanonicalLocales`, `supportedLocalesOf`, `supportedValuesOf`, and locale negotiation (Locale, Intl, and the top-level tests: 278).
2. `Intl.PluralRules`, `Intl.NumberFormat`, the fallback symbol of the legacy constructors, and `Number` and `BigInt` `toLocaleString` (324).
3. `Intl.DateTimeFormat` and the `Date` locale methods (257), then the Temporal calendars and time zone names of `test/intl402/Temporal` (2029), which also replace the en-US shim of `buoy_ref_temporal`.
4. `Intl.Collator`, `localeCompare`, and the `Array` and `TypedArray` `toLocaleString` (87).
5. `Intl.ListFormat`, `Intl.RelativeTimeFormat`, `Intl.DisplayNames`, `Intl.DurationFormat`, and `Intl.Segmenter` (407).

When the last phase lands, `hasIntl` becomes true and `process.versions` gains `icu`, `unicode`, and `cldr` with the versions of the data.

## Risks

- **Binary size.** The baked data of all locales adds tens of megabytes to the release. A build may keep a smaller locale set, but the default is all locales, as Node's full ICU.
- **Crash isolation.** A NIF that crashes stops the VM. ICU4X is safe Rust; the crate keeps `unsafe` to the NIF boundary, and a fuzz target covers the calls.
- **Data skew.** ICU4X and Node's ICU may ship different CLDR versions. The reference tests freeze Node's strings, so a skew shows as a failing test, and the gap data of step 3 of the design fixes it.
