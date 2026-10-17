// Runaway loop, plain Node: the 100 agents run on a pool of 4 worker threads from
// node-shards.ts, 25 agents in each, because one event loop cannot stop a loop that never
// yields: the fairness suite shows how a CPU-bound turn holds every actor of the loop.
// Agent 0 enters a loop that never ends inside its turn, which stops its worker and so
// the 24 other agents of that worker. Every call has a timeout of 100 ms. The supervisor
// pings agent 0; the timeout makes it start a new worker for the shard and terminate()
// the stuck one. The pings and the measurements are those of the Bouy program.
import { isMainThread } from "node:worker_threads";
import { percentile, sleep } from "../node-actor.ts";
import { Shards, serveShard } from "../node-shards.ts";

const AGENTS = 100;
const SHARDS = 4;
const WINDOW_MS = 1000;
const PAUSE_MS = 5;
const TIMEOUT_MS = 100;

class Agent {
  ping(): number {
    return 1;
  }

  spin(): number {
    let turns = 0;
    for (;;) {
      turns++;
    }
  }
}

type Sample = { ms: number; ok: boolean };

async function timedPing(shards: Shards, agent: number): Promise<Sample> {
  const sent = performance.now();
  try {
    await shards.call(agent, "ping", TIMEOUT_MS);
    return { ms: performance.now() - sent, ok: true };
  } catch {
    return { ms: performance.now() - sent, ok: false };
  }
}

async function pingRounds(shards: Shards, others: number[], until: number): Promise<Sample[]> {
  const samples: Sample[] = [];
  while (performance.now() < until) {
    samples.push(...(await Promise.all(others.map((agent) => timedPing(shards, agent)))));
    await sleep(PAUSE_MS);
  }
  return samples;
}

async function supervise(shards: Shards, started: number): Promise<number[]> {
  const answered = await shards.call(0, "ping", TIMEOUT_MS).then(
    () => true,
    () => false,
  );
  if (answered) throw new Error("the runaway agent answered");
  const stopped = (await shards.restart(shards.shardOf(0))) - started;
  await shards.call(0, "ping", TIMEOUT_MS);
  return [stopped, performance.now() - started];
}

async function measure(): Promise<object> {
  const shards = new Shards({ url: new URL(import.meta.url), shards: SHARDS, agents: AGENTS });
  await shards.ready();
  const agents = Array.from({ length: AGENTS }, (_, agent) => agent);
  const others = agents.slice(1);
  await Promise.all(agents.map((agent) => shards.call(agent, "ping", TIMEOUT_MS)));
  const started = performance.now();
  shards.call(0, "spin", WINDOW_MS * 10).catch(() => {});
  const [[stopped, recovered], samples] = await Promise.all([
    supervise(shards, started),
    pingRounds(shards, others, started + WINDOW_MS),
  ]);
  const sorted = samples.map((sample) => sample.ms).sort((a, b) => a - b);
  await shards.close();
  return {
    pings: samples.length,
    failed_requests: samples.filter((sample) => !sample.ok).length,
    p50_ms: percentile(sorted, 0.5),
    p99_ms: percentile(sorted, 0.99),
    max_ms: percentile(sorted, 1),
    stopped_ms: stopped,
    recovered_ms: recovered,
  };
}

if (isMainThread) {
  console.log(JSON.stringify(await measure()));
  process.exit(0);
} else {
  serveShard(() => new Agent());
}
