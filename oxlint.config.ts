import { defineConfig } from "oxlint";
import { recommended } from "./tools/oxlint/guardrails/preset.ts";

const preset = recommended({ effect: true, typeAware: true });

export default defineConfig({
  ...preset,
  ignorePatterns: [
    ...(preset.ignorePatterns ?? []),
    "dist/**",
    ".bouy/**",
    ".claude/**",
    "target/**",
    "**/fixtures/**",
    // Compiler inputs: these programs exercise every construct the compiler lowers.
    "tests/**",
    // Benchmark programs: Bouy compiler inputs and the plain Node baselines that they
    // measure against, which await in loops on purpose to time one call at a time.
    "bench/programs/**",
    // The same kind of programs for the reference-semantics prototype: compiler inputs and
    // their Node baselines.
    "bench/reference/**",
    // Third-party JavaScript that build.rs compiles into the runtime, kept as published.
    "runtime/vendor/**",
    // Speed kernels: idiomatic TypeScript ports of Octane and other benchmarks, compiled by
    // the engine and run on Node and Bun as they are.
    "bench/speed/**",
  ],
  overrides: [...(preset.overrides ?? [])],
});
