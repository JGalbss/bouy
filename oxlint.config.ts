import { defineConfig } from "oxlint";
import { recommended } from "./tools/oxlint/guardrails/preset.ts";

const preset = recommended({ effect: true, typeAware: true });

export default defineConfig({
  ...preset,
  ignorePatterns: [
    ...(preset.ignorePatterns ?? []),
    "dist/**",
    ".bouy/**",
    "target/**",
    "**/fixtures/**",
    // Compiler inputs: these programs exercise every construct the compiler lowers.
    "tests/**",
  ],
  overrides: [...(preset.overrides ?? [])],
});
