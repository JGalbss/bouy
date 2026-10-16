import { setTimeout as sleep } from "node:timers/promises";
import { spawn } from "bouy";
import { percentile } from "../evidence/measure.ts";

const WINDOW_MS = 2_000;
const PING_EVERY_MS = 1;
const neighborCpuMs = Number(process.env.NEIGHBOR_CPU_MS ?? WINDOW_MS);

class Cruncher {
  async crunch(milliseconds: number): Promise<number> {
    const deadline = performance.now() + milliseconds;
    let rounds = 0;
    while (performance.now() < deadline) rounds += 1;
    return rounds;
  }
}

class Pinger {
  ping(dueAt: number): number {
    return dueAt;
  }
}

const cruncher = spawn(Cruncher);
const pinger = spawn(Pinger);
await pinger.ping(0);

const startedAt = performance.now();
const latencies: Array<number> = [];
const crunching = cruncher.crunch(neighborCpuMs);

const pingFrom = async (slot: number): Promise<void> => {
  const dueAt = startedAt + slot * PING_EVERY_MS;
  if (dueAt > startedAt + WINDOW_MS) return;
  const wait = dueAt - performance.now();
  if (wait > 0) await sleep(wait);
  await pinger.ping(dueAt);
  latencies.push(performance.now() - dueAt);
  await pingFrom(slot + 1);
};

await pingFrom(0);
const crunchRounds = await crunching;

console.log(
  JSON.stringify({
    pings: latencies.length,
    p50Ms: percentile(latencies, 0.5),
    p99Ms: percentile(latencies, 0.99),
    maxMs: Math.max(...latencies),
    crunchRounds,
    wallMs: performance.now() - startedAt,
  }),
);
