import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import type { z } from "zod";

export interface Host {
  readonly name: string;
  readonly runtime: "node" | "bun";
  readonly available: boolean;
  readonly executable: string;
  readonly argv: (entry: string) => ReadonlyArray<string>;
}

export interface Launch {
  readonly cwd: string;
  readonly timeoutMs: number;
  readonly env?: Readonly<Record<string, string>>;
  readonly args?: ReadonlyArray<string>;
}

export interface Exit {
  readonly code: number | null;
  readonly signal: NodeJS.Signals | null;
  readonly stdout: string;
  readonly stderr: string;
}

export const TEST_TIMEOUT_MS = 60_000;
export const CHILD_TIMEOUT_MS = 50_000;

export const PROGRAMS = fileURLToPath(new URL("test/", import.meta.url));
export const EXAMPLES = fileURLToPath(new URL("../examples/", import.meta.url));

const BOUY_BIN = fileURLToPath(new URL("node_modules/.bin/bouy", import.meta.url));
const BOUY_CLI = fileURLToPath(new URL("node_modules/bouy/src/cli/main.ts", import.meta.url));

const hasBun = spawnSync("bun", ["--version"]).status === 0;

export const NODE_CLI: Host = {
  name: "node via bouy run",
  runtime: "node",
  available: true,
  executable: BOUY_BIN,
  argv: (entry) => ["run", entry],
};

export const NODE_REGISTER: Host = {
  name: "node --import bouy/register",
  runtime: "node",
  available: true,
  executable: "node",
  argv: (entry) => ["--import", "bouy/register", entry],
};

export const BUN_CLI: Host = {
  name: "bun via bouy run",
  runtime: "bun",
  available: hasBun,
  executable: "bun",
  argv: (entry) => [BOUY_CLI, "run", entry],
};

export const BUN_PRELOAD: Host = {
  name: "bun --preload bouy/register",
  runtime: "bun",
  available: hasBun,
  executable: "bun",
  argv: (entry) => ["--preload", "bouy/register", entry],
};

export const PLAIN_NODE: Host = {
  name: "plain node",
  runtime: "node",
  available: true,
  executable: "node",
  argv: (entry) => [entry],
};

export const BOUY_HOSTS: ReadonlyArray<Host> = [NODE_CLI, NODE_REGISTER, BUN_CLI, BUN_PRELOAD];

export const CLI_HOSTS: ReadonlyArray<Host> = [NODE_CLI, BUN_CLI];

export const launch = (host: Host, entry: string, options: Launch): Promise<Exit> =>
  new Promise((resolve, reject) => {
    const child = spawn(host.executable, [...host.argv(entry), ...(options.args ?? [])], {
      cwd: options.cwd,
      env: { ...process.env, ...options.env },
      stdio: ["ignore", "pipe", "pipe"],
      timeout: options.timeoutMs,
      killSignal: "SIGKILL",
    });
    const stdout: Array<string> = [];
    const stderr: Array<string> = [];
    child.stdout.setEncoding("utf8").on("data", (chunk: string) => stdout.push(chunk));
    child.stderr.setEncoding("utf8").on("data", (chunk: string) => stderr.push(chunk));
    child.once("error", reject);
    child.once("close", (code, signal) =>
      resolve({ code, signal, stdout: stdout.join(""), stderr: stderr.join("") }),
    );
  });

export const lastJsonLine = <T>(schema: z.ZodType<T>, exit: Exit): T =>
  schema.parse(JSON.parse(exit.stdout.trimEnd().split("\n").at(-1) ?? ""));
