import { setTimeout as sleep } from "node:timers/promises";
import { shutdown, spawn } from "bouy";

const LOOP_MS = 1_000;
const PINGS = 20;
const PING_EVERY_MS = LOOP_MS / PINGS;

interface LoopRun {
  readonly startedAt: number;
  readonly finishedAt: number;
  readonly spins: number;
}

class Cruncher {
  async crunch(durationMs: number): Promise<LoopRun> {
    const startedAt = performance.now();
    let spins = 0;
    while (performance.now() - startedAt < durationMs) spins += 1;
    return { startedAt, finishedAt: performance.now(), spins };
  }
}

class Pinger {
  ping(): number {
    return performance.now();
  }
}

const cruncher = spawn(Cruncher);
const pinger = spawn(Pinger);

const startedAt = performance.now();
const crunching = cruncher.crunch(LOOP_MS);
const latencies: Array<number> = [];
for (let slot = 0; slot < PINGS; slot += 1) {
  const dueAt = startedAt + slot * PING_EVERY_MS;
  const wait = dueAt - performance.now();
  if (wait > 0) await sleep(wait);
  const sentAt = performance.now();
  await pinger.ping();
  latencies.push(performance.now() - Math.min(dueAt, sentAt));
}
const loop = await crunching;

console.log(
  JSON.stringify({
    loopMs: loop.finishedAt - loop.startedAt,
    loopStartMs: loop.startedAt - startedAt,
    spins: loop.spins,
    worstPingMs: Math.max(...latencies),
    latencies,
  }),
);
await shutdown();
