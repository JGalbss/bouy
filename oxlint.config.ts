import { defineConfig } from "oxlint";
import { recommended } from "./tools/oxlint/guardrails/preset.ts";

const preset = recommended({ effect: true, typeAware: true });

// Tests sequence awaits on purpose: they check per-sender order, repeated crashes, and the
// preemption points the compiler inserts into loops.
const scenarioRelaxations = {
  "eslint/no-await-in-loop": "off",
} as const;

const measurementRelaxations = {
  "guardrails/maintainability-index": "off",
  "guardrails/abc-size": "off",
  "typescript/explicit-module-boundary-types": "off",
  "import/max-dependencies": "off",
} as const;

export default defineConfig({
  ...preset,
  ignorePatterns: [
    ...(preset.ignorePatterns ?? []),
    "dist/**",
    ".bouy/**",
    "target/**",
    "crates/*/binding.*",
    "**/fixtures/**",
  ],
  overrides: [
    ...(preset.overrides ?? []),
    { files: ["packages/*/src/**/*.ts"], rules: { "eslint/no-ternary": "error" } },
    { files: ["bench/**"], rules: measurementRelaxations },
    { files: ["**/test/**", "e2e/**"], rules: scenarioRelaxations },
  ],
});
