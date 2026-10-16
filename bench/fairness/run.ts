import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { cpus, loadavg } from "node:os";
import { relative } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";
import { BOUY_HOSTS, BUN_CLI, PROGRAMS, PLAIN_NODE } from "../../e2e/hosts.ts";
import { median } from "../evidence/measure.ts";
import { resultsFileName } from "../suite.ts";

const RUNS = 30;
const REPOSITORY_ROOT = fileURLToPath(new URL("../..", import.meta.url));

const FairnessRun = z.object({
  loopMs: z.number(),
  loopStartMs: z.number(),
  spins: z.number(),
  worstPingMs: z.number(),
  latencies: z.array(z.number()),
});

const recordedAt = new Date();
const resultsFile = new URL(`results/${resultsFileName("fairness", recordedAt)}`, import.meta.url);
const hosts = [...BOUY_HOSTS, PLAIN_NODE].filter((host) => host.available);

const loadAverageAtStart = loadavg();
const runs = Array.from({ length: RUNS }, () => hosts)
  .flat()
  .map((host, index) => {
    console.error(`run ${Math.floor(index / hosts.length) + 1} of ${RUNS}: ${host.name}`);
    const loadAverage1m = loadavg()[0] ?? Number.NaN;
    const stdout = execFileSync(host.executable, host.argv("fairness.ts"), {
      cwd: PROGRAMS,
      encoding: "utf8",
    });
    return Object.assign({ host: host.name, loadAverage1m }, FairnessRun.parse(JSON.parse(stdout)));
  });

const summary = hosts.map((host) => {
  const own = runs.filter((run) => run.host === host.name);
  const worst = own.map((run) => run.worstPingMs);
  const loops = own.map((run) => run.loopMs);
  return {
    host: host.name,
    command: [host.executable, ...host.argv("fairness.ts")]
      .map((part) => (part.startsWith(REPOSITORY_ROOT) ? relative(PROGRAMS, part) : part))
      .join(" "),
    runs: own.length,
    worstPingMs: { min: Math.min(...worst), median: median(worst), max: Math.max(...worst) },
    loopMs: { min: Math.min(...loops), median: median(loops), max: Math.max(...loops) },
  };
});

const results = {
  recordedAt: recordedAt.toISOString(),
  command: "node bench/fairness/run.ts",
  fixture: "e2e/test/fairness.ts",
  workingDirectory: "e2e/test",
  machine: {
    cpu: cpus()[0]?.model ?? "unknown",
    logicalCores: cpus().length,
    node: process.version,
    bun: BUN_CLI.available
      ? execFileSync("bun", ["--version"], { encoding: "utf8" }).trim()
      : "absent",
    loadAverageAtStart,
    loadAverageAtEnd: loadavg(),
  },
  runsPerHost: RUNS,
  summary,
  runs,
};

writeFileSync(resultsFile, `${JSON.stringify(results, null, 2)}\n`);
console.error(`wrote ${fileURLToPath(resultsFile)}`);
