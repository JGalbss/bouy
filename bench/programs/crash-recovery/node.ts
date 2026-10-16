// Crash recovery, plain Node: a mailbox actor from node-actor.ts throws, the actor
// catches the error, logs one line to stderr, and recreates its state, and the program
// times the next successful reply, 1,000 times. No worker_threads.
import { Actor } from "../node-actor.ts";

const CRASHES = 1000;

class Worker {
  fail(): void {
    throw new Error("boom");
  }

  ping(): number {
    return 1;
  }
}

async function measure(): Promise<object> {
  const worker = new Actor(() => new Worker());
  let recovering = 0;
  let slowest = 0;
  let failures = 0;
  const started = performance.now();
  for (let i = 0; i < CRASHES; i++) {
    try {
      await worker.call("fail");
    } catch {
      failures++;
    }
    const failed = performance.now();
    await worker.call("ping");
    const waited = performance.now() - failed;
    recovering += waited;
    slowest = Math.max(slowest, waited);
  }
  const total = performance.now() - started;
  if (failures !== CRASHES) throw new Error(`${failures} of ${CRASHES} calls failed`);
  return {
    cycle_us: (total * 1000) / CRASHES,
    recovery_us: (recovering * 1000) / CRASHES,
    max_recovery_ms: slowest,
  };
}

console.log(JSON.stringify(await measure()));
