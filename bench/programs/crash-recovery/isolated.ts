// Crash recovery, isolated Node: one mailbox actor on its own worker thread, from
// node-shards.ts. `fail` throws an uncaught error, which ends the worker and fails the
// pending call. The pool, as the supervisor in the main thread, starts a fresh worker
// with a fresh state, and the program times the next successful reply. The start of a
// new worker takes most of each cycle, so the program crashes 100 times, not 1,000 times
// as the other programs do. The metrics are per crash.
import { isMainThread } from "node:worker_threads";
import { Shards, serveShard } from "../node-shards.ts";

const CRASHES = 100;

class Worker {
  // The error escapes the mailbox, so it ends the worker instead of rejecting the call.
  // Bun 1.3 crashes the whole process when a worker throws from a microtask, so the
  // error comes from setImmediate.
  fail(): Promise<never> {
    return new Promise(() => {
      setImmediate(() => {
        throw new Error("boom");
      });
    });
  }

  ping(): number {
    return 1;
  }
}

async function measure(): Promise<object> {
  const worker = new Shards({ url: new URL(import.meta.url), shards: 1, agents: 1 });
  await worker.ready();
  let recovering = 0;
  let slowest = 0;
  let failures = 0;
  const started = performance.now();
  for (let i = 0; i < CRASHES; i++) {
    try {
      await worker.call(0, "fail", Infinity);
    } catch {
      failures++;
    }
    const failed = performance.now();
    await worker.call(0, "ping", Infinity);
    const waited = performance.now() - failed;
    recovering += waited;
    slowest = Math.max(slowest, waited);
  }
  const total = performance.now() - started;
  await worker.close();
  if (failures !== CRASHES) throw new Error(`${failures} of ${CRASHES} calls failed`);
  if (worker.restarts !== CRASHES) throw new Error(`${worker.restarts} of ${CRASHES} restarts`);
  return {
    cycle_us: (total * 1000) / CRASHES,
    recovery_us: (recovering * 1000) / CRASHES,
    max_recovery_ms: slowest,
  };
}

if (isMainThread) {
  console.log(JSON.stringify(await measure()));
  process.exit(0);
} else {
  serveShard(() => new Worker());
}
