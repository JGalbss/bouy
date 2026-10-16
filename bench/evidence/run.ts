import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { cpus, loadavg, totalmem, version } from "node:os";
import { fileURLToPath } from "node:url";
import { z } from "zod";
import { median } from "./measure.ts";

const RUNS = 5;
const REPOSITORY_ROOT = fileURLToPath(new URL("../..", import.meta.url));
const RESULTS_FILE = new URL("results/node-2026-10-16-m5pro.json", import.meta.url);
const EXECUTABLES = { node: process.execPath, bun: "bun" } as const;

const metrics = z.record(z.string(), z.number());
const outcomes = z.record(z.string(), z.string());

interface Experiment {
  readonly id: string;
  readonly runtime: keyof typeof EXECUTABLES;
  readonly flags: ReadonlyArray<string>;
  readonly script: string;
  readonly kind: "metrics" | "outcomes";
}

const experiments: ReadonlyArray<Experiment> = [
  { id: "E1", runtime: "node", flags: ["--expose-gc"], script: "spawn-cost.ts", kind: "metrics" },
  { id: "E2", runtime: "node", flags: [], script: "request-reply.ts", kind: "metrics" },
  { id: "E2", runtime: "bun", flags: [], script: "request-reply.ts", kind: "metrics" },
  { id: "E3", runtime: "node", flags: [], script: "message-copy.ts", kind: "metrics" },
  { id: "E4", runtime: "node", flags: [], script: "async-context-cost.ts", kind: "metrics" },
  { id: "E5", runtime: "node", flags: [], script: "preemption-check.ts", kind: "metrics" },
  { id: "E6", runtime: "node", flags: [], script: "fault-attribution.ts", kind: "outcomes" },
  { id: "E6", runtime: "bun", flags: [], script: "fault-attribution.ts", kind: "outcomes" },
];

const commandLine = (experiment: Experiment): ReadonlyArray<string> => [
  ...experiment.flags,
  `bench/evidence/${experiment.script}`,
];

const summarize = {
  metrics: (stdouts: ReadonlyArray<string>) => {
    const runs = stdouts.map((stdout) => metrics.parse(JSON.parse(stdout)));
    const columns = Object.keys(runs[0] ?? {}).map(
      (key) => [key, runs.map((run) => run[key] ?? Number.NaN)] as const,
    );
    return {
      median: Object.fromEntries(columns.map(([key, values]) => [key, median(values)])),
      min: Object.fromEntries(columns.map(([key, values]) => [key, Math.min(...values)])),
      max: Object.fromEntries(columns.map(([key, values]) => [key, Math.max(...values)])),
      runs,
    };
  },
  outcomes: (stdouts: ReadonlyArray<string>) => {
    const runs = stdouts.map((stdout) => outcomes.parse(JSON.parse(stdout)));
    const values = Object.keys(runs[0] ?? {}).map((key) => [
      key,
      [...new Set(runs.map((run) => run[key] ?? "missing"))],
    ]);
    return { values: Object.fromEntries(values), runs };
  },
};

const loadAtStart = loadavg();
const schedule = Array.from({ length: RUNS }, () => experiments).flat();
const executions = schedule.map((experiment, index) => {
  console.error(
    `run ${Math.floor(index / experiments.length) + 1}: ${experiment.id} on ${experiment.runtime}`,
  );
  const loadAverage1m = loadavg()[0] ?? Number.NaN;
  const stdout = execFileSync(EXECUTABLES[experiment.runtime], commandLine(experiment), {
    cwd: REPOSITORY_ROOT,
    encoding: "utf8",
  });
  return { experiment, loadAverage1m, stdout };
});

const results = {
  recordedAt: new Date().toISOString(),
  machine: {
    cpu: cpus()[0]?.model ?? "unknown",
    logicalCores: cpus().length,
    memoryBytes: totalmem(),
    kernel: version(),
    node: process.version,
    bun: execFileSync("bun", ["--version"], { encoding: "utf8" }).trim(),
    loadAverageAtStart: loadAtStart,
    loadAverageAtEnd: loadavg(),
  },
  runsPerExperiment: RUNS,
  experiments: experiments.map((experiment) => {
    const runs = executions.filter((execution) => execution.experiment === experiment);
    return {
      id: experiment.id,
      runtime: experiment.runtime,
      command: [experiment.runtime, ...commandLine(experiment)].join(" "),
      loadAverage1m: runs.map((run) => run.loadAverage1m),
      summary: summarize[experiment.kind](runs.map((run) => run.stdout)),
    };
  }),
};

writeFileSync(RESULTS_FILE, `${JSON.stringify(results, null, 2)}\n`);
console.error(`wrote ${fileURLToPath(RESULTS_FILE)}`);
