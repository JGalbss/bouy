import { cpus } from "node:os";
import { fileURLToPath } from "node:url";
import { Schema } from "effect";

export type Metrics = Readonly<Record<string, number>>;

export interface Command {
  readonly file: string;
  readonly args: ReadonlyArray<string>;
}

export const host = process.versions.bun === undefined ? "node" : "bun";

export const benchPath = (relative: string): string =>
  fileURLToPath(new URL(relative, import.meta.url));

export const resultsFileName = (prefix: string, recordedAt: Date): string => {
  const machineTag = (cpus()[0]?.model ?? "unknown")
    .replace(/^Apple /u, "")
    .replaceAll(/[^A-Za-z0-9]/gu, "")
    .toLowerCase();
  return `${prefix}-${recordedAt.toISOString().slice(0, 10)}-${machineTag}.json`;
};

export const bouyRun = (entry: string): Command => ({
  file: process.execPath,
  args: [benchPath("node_modules/bouy/src/cli/main.ts"), "run", entry],
});

export const readMetrics = Schema.decodeUnknownSync(
  Schema.fromJsonString(Schema.Record(Schema.String, Schema.Number)),
);

export const report = (results: Readonly<Record<string, Metrics>>): void => {
  const flat = Object.entries(results).flatMap(([variant, metrics]) =>
    Object.entries(metrics).map(([metric, value]) => [`${variant}.${metric}`, value] as const),
  );
  console.log(JSON.stringify(Object.fromEntries(flat)));
};
