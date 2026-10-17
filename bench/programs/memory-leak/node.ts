// Memory leak, plain Node: the 100 agents run on a pool of 4 worker threads from
// node-shards.ts, 25 agents in each, and each worker has resourceLimits of a 64 MiB old
// generation, because one heap fails as a whole. Agent 0 leaks: its turn keeps 1 MiB more
// every millisecond and never returns. On Node the heap limit ends the worker with
// ERR_WORKER_OUT_OF_MEMORY, and the pool starts the shard again, so the 24 other agents of
// that worker fail their calls until it is back. Bun ignores resourceLimits (checked with
// Bun 1.3.14), so its shared heap grows: when the RSS of the process passes 512 MiB, the
// program stops as a container memory limit would stop it, and reports the process lost.
// Every call has a timeout of 100 ms. A process-wide --max-old-space-size would override
// the limit of each worker, so the harness runs this program without it. The pings and
// the measurements are those of the Bouy program.
import { isMainThread } from "node:worker_threads";
import { percentile, sleep } from "../node-actor.ts";
import { Shards, serveShard } from "../node-shards.ts";

const AGENTS = 100;
const SHARDS = 4;
const WINDOW_MS = 2000;
const PAUSE_MS = 5;
const TIMEOUT_MS = 100;
const HEAP_MIB = 64;
const PROCESS_MIB = 512;
const CHUNK = 1024 * 1024;

class Agent {
  chunks: number[][] = [];

  ping(): number {
    return 1;
  }

  async leak(): Promise<number> {
    for (;;) {
      this.chunks.push(new Array(CHUNK / 8).fill(this.chunks.length));
      await sleep(1);
    }
  }
}

type Sample = { agent: number; ms: number; ok: boolean };

async function timedPing(shards: Shards, agent: number): Promise<Sample> {
  const sent = performance.now();
  try {
    await shards.call(agent, "ping", TIMEOUT_MS);
    return { agent, ms: performance.now() - sent, ok: true };
  } catch {
    return { agent, ms: performance.now() - sent, ok: false };
  }
}

async function pingRounds(
  shards: Shards,
  others: number[],
  until: number,
  samples: Sample[],
): Promise<void> {
  while (performance.now() < until) {
    samples.push(...(await Promise.all(others.map((agent) => timedPing(shards, agent)))));
    await sleep(PAUSE_MS);
  }
}

// The time until the heap limit ended the leak, and then until agent 0 answered again.
async function watchLeak(shards: Shards, started: number): Promise<number[]> {
  await shards.call(0, "leak", WINDOW_MS * 10).catch(() => {});
  const killed = performance.now();
  for (;;) {
    try {
      await shards.call(0, "ping", TIMEOUT_MS);
      return [killed - started, performance.now() - killed];
    } catch {}
  }
}

function summary(samples: Sample[]): object {
  const failures = samples.filter((sample) => !sample.ok);
  const sorted = samples.map((sample) => sample.ms).sort((a, b) => a - b);
  return {
    pings: samples.length,
    failed_requests: failures.length,
    agents_lost: new Set(failures.map((sample) => sample.agent)).size,
    p50_ms: percentile(sorted, 0.5),
    p99_ms: percentile(sorted, 0.99),
    max_ms: percentile(sorted, 1),
  };
}

// Stops the program past PROCESS_MIB of RSS and reports every agent lost with it.
function guardProcess(samples: Sample[], started: number): void {
  setInterval(() => {
    if (process.memoryUsage().rss < PROCESS_MIB * 1024 * 1024) return;
    const report = {
      ...summary(samples),
      agents_lost: AGENTS - 1,
      killed_ms: performance.now() - started,
      leaker_restarts: 0,
      process_lost: 1,
    };
    console.log(JSON.stringify(report));
    process.exit(0);
  }, 10);
}

async function measure(): Promise<object> {
  const shards = new Shards({
    url: new URL(import.meta.url),
    shards: SHARDS,
    agents: AGENTS,
    resourceLimits: { maxOldGenerationSizeMb: HEAP_MIB },
  });
  await shards.ready();
  const agents = Array.from({ length: AGENTS }, (_, agent) => agent);
  await Promise.all(agents.map((agent) => shards.call(agent, "ping", TIMEOUT_MS)));
  const started = performance.now();
  const samples: Sample[] = [];
  guardProcess(samples, started);
  const [[killed, recovered]] = await Promise.all([
    watchLeak(shards, started),
    pingRounds(shards, agents.slice(1), started + WINDOW_MS, samples),
  ]);
  await shards.close();
  return {
    ...summary(samples),
    killed_ms: killed,
    recovery_ms: recovered,
    leaker_restarts: shards.restarts,
    process_lost: 0,
  };
}

if (isMainThread) {
  console.log(JSON.stringify(await measure()));
  process.exit(0);
} else {
  serveShard(() => new Agent());
}
