import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { fileURLToPath } from "node:url";
import { assert, describe, expect, it } from "@effect/vitest";
import { Effect } from "effect";
import { Checker, CheckFailed, formatDiagnostic, type Diagnostic } from "../src/index.ts";
import { check, diagnosticsIn, fixture, lineWith } from "./check.ts";

const failure = (entry: string): Effect.Effect<CheckFailed, ReadonlyArray<Diagnostic>> =>
  Checker.use((checker) => checker.check(entry)).pipe(Effect.flip, Effect.provide(Checker.layer));

const packageDirectory = (path: string): string =>
  fileURLToPath(new URL(`../${path}`, import.meta.url));

const temporaryProject = (files: Readonly<Record<string, string>>): string => {
  const directory = mkdtempSync(join(tmpdir(), "bouy-checker-"));
  Object.entries(files).forEach(([name, text]) => writeFileSync(join(directory, name), text));
  return directory;
};

describe("Checker", () => {
  it("returns TypeScript diagnostics with a TS code", async () => {
    expect(await diagnosticsIn("type-error.ts")).toEqual([
      {
        code: "TS2322",
        severity: "error",
        message: "Type 'string' is not assignable to type 'number'.",
        file: fixture("type-error.ts"),
        line: lineWith("type-error.ts", "count"),
        column: 14,
      },
    ]);
  });

  it("uses defaults that type-check bouy and node: imports when no tsconfig.json is found", async () => {
    const directory = temporaryProject({
      "double.ts": "export const double = (value) => value * 2;\n",
      "entry.ts": [
        'import { readFileSync } from "node:fs";',
        'import { spawn } from "bouy";',
        'import { double } from "./double.ts";',
        "",
        "class Reader {",
        "  size(path: string): number {",
        '    return double(readFileSync(path, "utf8").length);',
        "  }",
        "}",
        "",
        "spawn(Reader);",
        "",
      ].join("\n"),
    });
    mkdirSync(join(directory, "node_modules", "@types"), { recursive: true });
    symlinkSync(packageDirectory("../bouy"), join(directory, "node_modules", "bouy"));
    symlinkSync(
      packageDirectory("node_modules/@types/node"),
      join(directory, "node_modules", "@types", "node"),
    );
    const diagnostics = await check(join(directory, "entry.ts"));
    rmSync(directory, { recursive: true });
    expect(
      diagnostics.map((diagnostic) => `${basename(diagnostic.file)} ${diagnostic.code}`),
    ).toEqual(["double.ts TS7006"]);
  });

  it("reports compiler option errors at the tsconfig.json that set them", async () => {
    const directory = temporaryProject({
      "tsconfig.json": '{ "compilerOptions": { "strict": true, "types": ["bouy-missing"] } }\n',
      "entry.ts": "export const one = 1;\n",
    });
    const diagnostics = await check(join(directory, "entry.ts"));
    rmSync(directory, { recursive: true });
    expect(diagnostics).toEqual([
      expect.objectContaining({ code: "TS2688", file: join(directory, "tsconfig.json") }),
    ]);
  });

  it.effect("fails with CheckFailed for an entry that does not exist", () =>
    Effect.gen(function* () {
      const error = yield* failure(fixture("missing.ts"));
      assert.instanceOf(error, CheckFailed);
      assert.include(error.message, "ENOENT");
    }),
  );

  it.effect("fails with CheckFailed for an entry that is a directory", () =>
    Effect.gen(function* () {
      const error = yield* failure(fixture(""));
      assert.instanceOf(error, CheckFailed);
      assert.include(error.message, "it is not a file");
    }),
  );

  it("formats a diagnostic the way tsc does", () => {
    expect(
      formatDiagnostic({
        code: "BOUY101",
        severity: "error",
        message: "The parameter task of Worker.enqueue is not Sendable: it is a function.",
        file: "src/worker.ts",
        line: 3,
        column: 11,
      }),
    ).toBe(
      "src/worker.ts:3:11 - error BOUY101: The parameter task of Worker.enqueue is not Sendable: it is a function.",
    );
  });
});
