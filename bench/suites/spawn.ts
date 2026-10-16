import { once } from "node:events";
import { getHeapStatistics } from "node:v8";
import type { Worker } from "node:worker_threads";
import { shutdown, spawn } from "bouy";
import { startEchoWorker } from "../evidence/echo.ts";
import { nanosecondsSince, percentile, repeatInSequence } from "../evidence/measure.ts";
import { PlainActor } from "../plain-actor.ts";
import { report } from "../suite.ts";

const FEW = 10_000;
const MANY = 100_000;
const WARMUP = 1_000;
const WORKERS = 64;

const { gc } = globalThis;
if (gc === undefined) throw new Error("Run this suite with --expose-gc.");

class Counter {
  #count = 0;

  increment(): number {
    this.#count += 1;
    return this.#count;
  }
}

const measureUnits = (count: number, create: () => object) => {
  gc();
  const heapBefore = getHeapStatistics().used_heap_size;
  const rssBefore = process.memoryUsage().rss;
  const start = process.hrtime.bigint();
  const units = Array.from({ length: count }, create);
  const elapsed = nanosecondsSince(start);
  gc();
  return {
    units: units.length,
    nsPerUnit: elapsed / count,
    heapBytesPerUnit: (getHeapStatistics().used_heap_size - heapBefore) / count,
    rssBytesPerUnit: (process.memoryUsage().rss - rssBefore) / count,
  };
};

const createPlainObject = (): Counter => new Counter();
const createPlainActor = (): PlainActor<Counter> => new PlainActor(new Counter());
const spawnCounter = () => spawn(Counter);

measureUnits(WARMUP, createPlainObject);
measureUnits(WARMUP, createPlainActor);

const plainObject = {
  few: measureUnits(FEW, createPlainObject),
  many: measureUnits(MANY, createPlainObject),
};
const plainActor = {
  few: measureUnits(FEW, createPlainActor),
  many: measureUnits(MANY, createPlainActor),
};

gc();
const workers: Array<Worker> = [];
const onlineNanoseconds: Array<number> = [];
const rssBeforeWorkers = process.memoryUsage().rss;
await repeatInSequence(WORKERS, async () => {
  const start = process.hrtime.bigint();
  const worker = startEchoWorker();
  await once(worker, "online");
  onlineNanoseconds.push(nanosecondsSince(start));
  workers.push(worker);
});
gc();
const rssAfterWorkers = process.memoryUsage().rss;
await Promise.all(workers.map((worker) => worker.terminate()));

measureUnits(WARMUP, spawnCounter);
await shutdown();
spawnCounter();
const bouyFew = measureUnits(FEW, spawnCounter);
const stopStart = process.hrtime.bigint();
await shutdown();
const shutdownNsPerUnit = nanosecondsSince(stopStart) / (FEW + 1);
spawnCounter();
const bouyMany = measureUnits(MANY, spawnCounter);

report({
  [`plainObject.${FEW}`]: plainObject.few,
  [`plainObject.${MANY}`]: plainObject.many,
  [`plainActor.${FEW}`]: plainActor.few,
  [`plainActor.${MANY}`]: plainActor.many,
  [`bouy.${FEW}`]: { ...bouyFew, shutdownNsPerUnit },
  [`bouy.${MANY}`]: bouyMany,
  [`worker.${WORKERS}`]: {
    units: workers.length,
    nsPerUnit: onlineNanoseconds.reduce((total, value) => total + value, 0) / WORKERS,
    onlineP50Ns: percentile(onlineNanoseconds, 0.5),
    onlineP99Ns: percentile(onlineNanoseconds, 0.99),
    rssBytesPerUnit: (rssAfterWorkers - rssBeforeWorkers) / WORKERS,
  },
});
