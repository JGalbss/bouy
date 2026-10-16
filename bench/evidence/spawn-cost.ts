import { execFileSync } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { once } from "node:events";
import { createContext } from "node:vm";
import type { Worker } from "node:worker_threads";
import { forkEchoChild, forkEchoChildFile, startEchoWorker } from "./echo.ts";
import { median, nanosecondsSince, percentile, repeatInSequence } from "./measure.ts";

const ACTORS = 100_000;
const CONTEXTS = 1_000;
const WORKERS = 64;
const CHILDREN = 16;

const { gc } = globalThis;
if (gc === undefined) throw new Error("Run node with --expose-gc.");

interface LightActor {
  state: number;
  readonly mailbox: Array<number>;
  readonly receive: (message: number) => void;
}

const measureHeap = <Unit>(count: number, spawn: () => Unit) => {
  gc();
  const before = process.memoryUsage();
  const start = process.hrtime.bigint();
  const units = Array.from({ length: count }, spawn);
  const spawnNanoseconds = nanosecondsSince(start);
  gc();
  const after = process.memoryUsage();
  return {
    units,
    spawnNanosecondsPerUnit: spawnNanoseconds / count,
    heapBytesPerUnit: (after.heapUsed - before.heapUsed) / count,
    rssBytesPerUnit: (after.rss - before.rss) / count,
  };
};

const spawnChildren = async (spawn: () => ChildProcess) => {
  const children: Array<ChildProcess> = [];
  const firstMessageNanoseconds: Array<number> = [];
  await repeatInSequence(CHILDREN, async () => {
    const start = process.hrtime.bigint();
    const child = spawn();
    await once(child, "message");
    firstMessageNanoseconds.push(nanosecondsSince(start));
    children.push(child);
  });
  const pids = children.map((child) => child.pid).join(",");
  const rssKilobytes = execFileSync("ps", ["-o", "rss=", "-p", pids], { encoding: "utf8" })
    .trim()
    .split(/\s+/u)
    .map(Number);
  children.forEach((child) => child.kill());
  return {
    firstMessageP50Ms: percentile(firstMessageNanoseconds, 0.5) / 1e6,
    firstMessageP99Ms: percentile(firstMessageNanoseconds, 0.99) / 1e6,
    rssBytesMedian: median(rssKilobytes) * 1024,
  };
};

const actors = measureHeap(ACTORS, (): LightActor => {
  const actor: LightActor = {
    state: 0,
    mailbox: [],
    receive: (message) => {
      actor.state += message;
    },
  };
  return actor;
});

const contexts = measureHeap(CONTEXTS, () => createContext());

const workers: Array<Worker> = [];
const onlineNanoseconds: Array<number> = [];
gc();
const rssBeforeWorkers = process.memoryUsage().rss;
await repeatInSequence(WORKERS, async () => {
  const start = process.hrtime.bigint();
  const worker = startEchoWorker();
  await once(worker, "online");
  onlineNanoseconds.push(nanosecondsSince(start));
  workers.push(worker);
});
await Promise.all(
  workers.map((worker) => {
    const reply = once(worker, "message");
    worker.postMessage(0, []);
    return reply;
  }),
);
gc();
const rssAfterWorkers = process.memoryUsage().rss;
const workerHeaps = await Promise.all(workers.map((worker) => worker.getHeapStatistics()));
await Promise.all(workers.map((worker) => worker.terminate()));

const inlineChildren = await spawnChildren(forkEchoChild);
const typeScriptChildren = await spawnChildren(forkEchoChildFile);

console.log(
  JSON.stringify({
    "lightActor.units": actors.units.length,
    "lightActor.heapBytesPerUnit": actors.heapBytesPerUnit,
    "lightActor.rssBytesPerUnit": actors.rssBytesPerUnit,
    "lightActor.spawnNsPerUnit": actors.spawnNanosecondsPerUnit,
    "vmContext.units": contexts.units.length,
    "vmContext.heapBytesPerUnit": contexts.heapBytesPerUnit,
    "vmContext.rssBytesPerUnit": contexts.rssBytesPerUnit,
    "vmContext.spawnUsPerUnit": contexts.spawnNanosecondsPerUnit / 1e3,
    "worker.units": workers.length,
    "worker.onlineP50Ms": percentile(onlineNanoseconds, 0.5) / 1e6,
    "worker.onlineP99Ms": percentile(onlineNanoseconds, 0.99) / 1e6,
    "worker.rssBytesPerUnit": (rssAfterWorkers - rssBeforeWorkers) / WORKERS,
    "worker.isolateHeapUsedBytesMedian": median(workerHeaps.map((heap) => heap.used_heap_size)),
    "worker.isolateHeapTotalBytesMedian": median(workerHeaps.map((heap) => heap.total_heap_size)),
    "forkInlineScript.units": CHILDREN,
    "forkInlineScript.firstMessageP50Ms": inlineChildren.firstMessageP50Ms,
    "forkInlineScript.firstMessageP99Ms": inlineChildren.firstMessageP99Ms,
    "forkInlineScript.rssBytesMedian": inlineChildren.rssBytesMedian,
    "forkTypeScriptFile.units": CHILDREN,
    "forkTypeScriptFile.firstMessageP50Ms": typeScriptChildren.firstMessageP50Ms,
    "forkTypeScriptFile.firstMessageP99Ms": typeScriptChildren.firstMessageP99Ms,
    "forkTypeScriptFile.rssBytesMedian": typeScriptChildren.rssBytesMedian,
    involuntaryContextSwitches: process.resourceUsage().involuntaryContextSwitches,
  }),
);
