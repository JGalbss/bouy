import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { Effect } from "effect";
import { Checker, type Diagnostic } from "../src/index.ts";

const results = new Map<string, Promise<ReadonlyArray<Diagnostic>>>();

export const fixture = (name: string): string =>
  fileURLToPath(new URL(`fixtures/${name}`, import.meta.url));

export const check = (entry: string): Promise<ReadonlyArray<Diagnostic>> =>
  Effect.runPromise(
    Checker.use((checker) => checker.check(entry)).pipe(Effect.provide(Checker.layer)),
  );

export const diagnosticsIn = async (name: string): Promise<ReadonlyArray<Diagnostic>> => {
  const pending = results.get(name) ?? check(fixture(name));
  results.set(name, pending);
  const diagnostics = await pending;
  return diagnostics.filter((diagnostic) => diagnostic.file === fixture(name));
};

export const lineWith = (name: string, text: string): number =>
  readFileSync(fixture(name), "utf8")
    .split("\n")
    .findIndex((line) => line.includes(text)) + 1;
