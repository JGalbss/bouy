# Repository guidance

- Run `pnpm check` before every commit. It runs the format check, the lint, the type check, and the tests.
- Write commit subjects as Conventional Commits: `<type>(<scope>): <summary>`. The `commit-msg` hook in `.githooks/` and the CI `commits` job reject other subjects.
- The lint uses the vendored guardrails plugins in `tools/oxlint/guardrails/`. Do not edit that copy. Do not disable a rule, lower a severity, or add a cast to make the lint pass. Change the code.
- `src/` uses erasable TypeScript syntax only, because Node runs it with type stripping. Use `.ts` extensions on relative imports.
- Every performance claim in a document cites a benchmark in `bench/` and its recorded output. Do not write a number that no benchmark produced.
- Every claim about npm compatibility names the package, the version, and the test that proves it.
- `docs/architecture.md` is the living design document. Update it in the same commit as a change to the semantics it describes.
