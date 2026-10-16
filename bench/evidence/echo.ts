import { fork } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { Worker } from "node:worker_threads";

const workerSource = `const { parentPort } = require("node:worker_threads");
parentPort.on("message", (message) => parentPort.postMessage(message));`;

const childSource = `process.send("ready");
process.on("message", (message) => process.send(message));`;

const ignoredEntryPath = import.meta.filename;

export const startEchoWorker = (): Worker => new Worker(workerSource, { eval: true });

export const forkEchoChild = (): ChildProcess =>
  fork(ignoredEntryPath, [], {
    execArgv: ["-e", childSource],
    stdio: ["ignore", "ignore", "inherit", "ipc"],
  });

export const forkEchoChildFile = (): ChildProcess =>
  fork(new URL("echo-child.ts", import.meta.url), [], {
    execArgv: [],
    stdio: ["ignore", "ignore", "inherit", "ipc"],
  });
