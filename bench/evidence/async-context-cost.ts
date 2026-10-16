import { strictEqual } from "node:assert/strict";
import { AsyncLocalStorage } from "node:async_hooks";
import { median, nanosecondsSince, repeatInSequence } from "./measure.ts";

const CALLS = 500_000;
const TRIALS = 5;

const storage = new AsyncLocalStorage<number>();
const resolved = Promise.resolve();

const awaitOnce = async (): Promise<void> => {
  await resolved;
};

const timeCalls = async (call: () => Promise<void>): Promise<number> => {
  const start = process.hrtime.bigint();
  await repeatInSequence(CALLS, call);
  return nanosecondsSince(start) / CALLS;
};

await storage.run(7, async () => {
  await resolved;
  strictEqual(storage.getStore(), 7);
});

const runInActor = storage.run(1, () => AsyncLocalStorage.snapshot());
await runInActor(async () => {
  await resolved;
  strictEqual(storage.getStore(), 1);
});

const withoutRun: Array<number> = [];
const withRun: Array<number> = [];
const withSnapshot: Array<number> = [];
await repeatInSequence(TRIALS, async () => {
  withoutRun.push(await timeCalls(awaitOnce));
  withRun.push(await timeCalls(() => storage.run(1, awaitOnce)));
  withSnapshot.push(await timeCalls(() => runInActor(awaitOnce)));
});

console.log(
  JSON.stringify({
    calls: CALLS,
    trials: TRIALS,
    "withoutRun.nsPerCall": median(withoutRun),
    "withRun.nsPerCall": median(withRun),
    "withSnapshot.nsPerCall": median(withSnapshot),
    "runOverhead.nsPerCall": median(
      withRun.map((value, index) => value - (withoutRun[index] ?? 0)),
    ),
    "snapshotOverhead.nsPerCall": median(
      withSnapshot.map((value, index) => value - (withoutRun[index] ?? 0)),
    ),
    involuntaryContextSwitches: process.resourceUsage().involuntaryContextSwitches,
  }),
);
