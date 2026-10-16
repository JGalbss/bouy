import { defineConfig } from "oxlint";
import { recommended } from "./tools/oxlint/guardrails/preset.ts";

const preset = recommended({ typeAware: true });

const measurementRelaxations = {
  "guardrails/maintainability-index": "off",
  "guardrails/abc-size": "off",
  "typescript/explicit-module-boundary-types": "off",
  "import/max-dependencies": "off",
} as const;

export default defineConfig({
  ...preset,
  ignorePatterns: [...(preset.ignorePatterns ?? []), "dist/**", ".bouy/**"],
  overrides: [
    ...(preset.overrides ?? []),
    { files: ["src/**/*.ts", "bin/**/*.ts"], rules: { "eslint/no-ternary": "error" } },
    { files: ["bench/**"], rules: measurementRelaxations },
  ],
});
