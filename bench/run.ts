import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { cpus, loadavg, release, totalmem, type, version } from "node:os";
import { median, nanosecondsSince } from "./evidence/measure.ts";
import { benchPath, host, readMetrics, resultsFileName, type Metrics } from "./suite.ts";

const RUNS = 5;
const RUNTIME_SOURCES = ["packages/bouy/src", "crates/bouy-compiler/src"];

const SUITES = [
  { name: "spawn", flags: ["--expose-gc"] },
  { name: "request-reply", flags: [] },
  { name: "fan-out", flags: [] },
  { name: "fairness", flags: [] },
  { name: "streaming", flags: [] },
  { name: "messages", flags: [] },
  { name: "startup", flags: [] },
] as const;

const git = (...args: ReadonlyArray<string>): string =>
  execFileSync("git", args, { cwd: benchPath(".."), encoding: "utf8" }).trim();

const hashSources = (): string =>
  execFileSync(
    "git",
    ["ls-files", "--cached", "--others", "--exclude-standard", ...RUNTIME_SOURCES],
    { cwd: benchPath(".."), encoding: "utf8" },
  )
    .trim()
    .split("\n")
    .filter((file) => existsSync(benchPath(`../${file}`)))
    .toSorted()
    .reduce(
      (hash, file) => hash.update(file).update(readFileSync(benchPath(`../${file}`))),
      createHash("sha256"),
    )
    .digest("hex");

const cpu = cpus()[0]?.model ?? "unknown";
const recordedAt = new Date();
const resultsFile = benchPath(`results/${resultsFileName(host, recordedAt)}`);
const runtimeVersion = process.versions.bun ?? process.version;
const loadAverageAtStart = loadavg();
const sourceHashAtStart = hashSources();
const sourceChanges = git("status", "--porcelain", "--", ...RUNTIME_SOURCES);

const executions = Array.from({ length: RUNS }, () => SUITES)
  .flat()
  .map((suite, index) => {
    console.error(`run ${Math.floor(index / SUITES.length) + 1} of ${RUNS}: ${suite.name}`);
    const loadAverage1m = loadavg()[0] ?? Number.NaN;
    const start = process.hrtime.bigint();
    const stdout = execFileSync(process.execPath, [...suite.flags, `suites/${suite.name}.ts`], {
      cwd: benchPath("."),
      encoding: "utf8",
      stdio: ["ignore", "pipe", "inherit"],
    });
    return {
      suite,
      loadAverage1m,
      seconds: nanosecondsSince(start) / 1e9,
      metrics: readMetrics(stdout),
    };
  });

const results = {
  recordedAt: recordedAt.toISOString(),
  host,
  command: `${host} bench/run.ts`,
  machine: {
    cpu,
    logicalCores: cpus().length,
    memoryBytes: totalmem(),
    os: `${type()} ${release()}`,
    kernel: version(),
  },
  versions: { [host]: runtimeVersion },
  source: {
    commit: git("rev-parse", "HEAD"),
    hashedPaths: RUNTIME_SOURCES,
    sha256AtStart: sourceHashAtStart,
    sha256AtEnd: hashSources(),
    uncommittedChanges: sourceChanges.split("\n").filter((line) => line !== ""),
  },
  loadAverage: { atStart: loadAverageAtStart, atEnd: loadavg() },
  runsPerSuite: RUNS,
  suites: Object.fromEntries(
    SUITES.map((suite) => {
      const runs = executions.filter((execution) => execution.suite === suite);
      const metrics: ReadonlyArray<Metrics> = runs.map((run) => run.metrics);
      const columns = Object.keys(metrics[0] ?? {}).map(
        (key) => [key, metrics.map((run) => run[key] ?? Number.NaN)] as const,
      );
      return [
        suite.name,
        {
          command: [host, ...suite.flags, `bench/suites/${suite.name}.ts`].join(" "),
          loadAverage1m: runs.map((run) => run.loadAverage1m),
          seconds: runs.map((run) => run.seconds),
          median: Object.fromEntries(columns.map(([key, values]) => [key, median(values)])),
          min: Object.fromEntries(columns.map(([key, values]) => [key, Math.min(...values)])),
          max: Object.fromEntries(columns.map(([key, values]) => [key, Math.max(...values)])),
          runs: metrics,
        },
      ];
    }),
  ),
};

writeFileSync(resultsFile, `${JSON.stringify(results, null, 2)}\n`);
console.error(`wrote ${resultsFile}`);
