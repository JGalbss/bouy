import { execFileSync } from "node:child_process";
import { benchPath, bouyRun, readMetrics, report, type Command, type Metrics } from "../suite.ts";

const PROGRAM = benchPath("programs/noisy-neighbor.ts");
const NEIGHBOR_CPU_MS = { busy: "2000", idle: "0" } as const;

const compiled = bouyRun(PROGRAM);
const plain: Command = { file: process.execPath, args: [PROGRAM] };

const runProgram = (command: Command, neighbor: keyof typeof NEIGHBOR_CPU_MS): Metrics => {
  const stdout = execFileSync(command.file, command.args, {
    cwd: benchPath("."),
    encoding: "utf8",
    env: { ...process.env, NEIGHBOR_CPU_MS: NEIGHBOR_CPU_MS[neighbor] },
  });
  return readMetrics(stdout.trim().split("\n").at(-1) ?? "");
};

report({
  "compiled.busy": runProgram(compiled, "busy"),
  "plain.busy": runProgram(plain, "busy"),
  "compiled.idle": runProgram(compiled, "idle"),
  "plain.idle": runProgram(plain, "idle"),
});
