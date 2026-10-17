import { child, supervise } from "bouy";

// Crash recovery: an actor throws, its supervisor restarts it, and the program times the
// next successful reply with performance.now(), 1,000 times. Each crash prints one line
// to stderr.

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
  const team = supervise({
    maxRestarts: CRASHES * 10,
    withinMs: 1000,
    children: { worker: child(Worker) },
  });
  let recovering = 0;
  let slowest = 0;
  let failures = 0;
  const started = performance.now();
  for (let i = 0; i < CRASHES; i++) {
    try {
      await team.worker.fail();
    } catch {
      failures++;
    }
    const failed = performance.now();
    await team.worker.ping();
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
