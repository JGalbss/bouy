import { spawnSync } from "node:child_process";
import { median, nanosecondsSince } from "../evidence/measure.ts";
import { benchPath, bouyRun, host, report, type Command } from "../suite.ts";

const SAMPLES = 4;
const CPU_LINE = /^(?:user|sys) ([\d.]+)$/gmu;
const HELLO = benchPath("programs/hello.ts");
const LOADER_FLAG = { node: "--import", bun: "--preload" } as const;

const commands = {
  plain: { file: process.execPath, args: [benchPath("programs/plain-hello.ts")] },
  runtime: { file: process.execPath, args: [HELLO] },
  register: { file: process.execPath, args: [LOADER_FLAG[host], "bouy/register", HELLO] },
  cli: bouyRun(HELLO),
} satisfies Record<string, Command>;

const samples = Array.from({ length: SAMPLES }, () =>
  Object.entries(commands).map(([variant, command]) => {
    const start = process.hrtime.bigint();
    const run = spawnSync("/usr/bin/time", ["-p", command.file, ...command.args], {
      cwd: benchPath("."),
      encoding: "utf8",
    });
    const wallMs = nanosecondsSince(start) / 1e6;
    if (run.status !== 0 || !run.stdout.includes("Hello, Ada!"))
      throw new Error(`${command.args.join(" ")} exited ${run.status}: ${run.stdout}${run.stderr}`);
    const cpuSeconds = [...run.stderr.matchAll(CPU_LINE)].map((line) => Number(line[1]));
    if (cpuSeconds.length !== 2) throw new Error(`time -p printed ${run.stderr}`);
    return { variant, wallMs, cpuMs: (cpuSeconds[0] ?? 0) * 1e3 + (cpuSeconds[1] ?? 0) * 1e3 };
  }),
).flat();

report(
  Object.fromEntries(
    Object.keys(commands).map((variant) => {
      const runs = samples.filter((sample) => sample.variant === variant);
      const wall = runs.map(({ wallMs }) => wallMs);
      return [
        variant,
        {
          p50Ms: median(wall),
          minMs: Math.min(...wall),
          maxMs: Math.max(...wall),
          cpuP50Ms: median(runs.map(({ cpuMs }) => cpuMs)),
        },
      ];
    }),
  ),
);
