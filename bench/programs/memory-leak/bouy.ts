import { inspect, sleep, spawn } from "bouy";

// Memory leak: 100 agents answer pings. Agent 0 runs with maxMemory: "64M", and its turn
// leaks: it keeps 1 MiB more every millisecond and never returns. The limit kills the
// agent at the first garbage collection past 64 MiB, its caller gets ActorOutOfMemory, and
// the keeper restarts it with a fresh state. The heap of every other agent is its own, so
// no other agent notices. For 2 s the program pings the other 99 agents in rounds of
// parallel calls, one round every 5 ms, and times each ping. It records the ping times
// and failures, the agents that failed a ping, the time until the limit killed the leak,
// the time until agent 0 answered again, and its restarts.

const AGENTS = 100;
const WINDOW_MS = 2000;
const PAUSE_MS = 5;
const CHUNK = 1024 * 1024;

class Agent {
  #chunks: string[] = [];

  ping(): number {
    return 1;
  }

  leak(): number {
    for (;;) {
      this.#chunks.push("x".repeat(CHUNK));
      sleep(1);
    }
  }
}

type Sample = { agent: number; ms: number; ok: boolean };

async function timedPing(agent: any, index: number): Promise<Sample> {
  const sent = performance.now();
  try {
    await agent.ping();
    return { agent: index, ms: performance.now() - sent, ok: true };
  } catch {
    return { agent: index, ms: performance.now() - sent, ok: false };
  }
}

async function pingRounds(others: any[], until: number): Promise<Sample[]> {
  const rounds: Sample[][] = [];
  while (performance.now() < until) {
    rounds.push(await Promise.all(others.map((agent, index) => timedPing(agent, index + 1))));
    sleep(PAUSE_MS);
  }
  return rounds.flat();
}

// The time until the limit killed the leak, and then until the agent answered again.
async function watchLeak(leaker: any, started: number): Promise<number[]> {
  let failure = "no error";
  try {
    await leaker.leak();
  } catch (error) {
    failure = error._tag;
  }
  if (failure !== "ActorOutOfMemory") throw new Error(`the leak ended with ${failure}`);
  const killed = performance.now();
  await leaker.ping();
  return [killed - started, performance.now() - killed];
}

// The nearest-rank percentile of sorted samples.
function percentile(sorted: number[], fraction: number): number {
  return sorted[Math.max(0, Math.ceil(fraction * sorted.length) - 1)] ?? 0;
}

async function measure(): Promise<object> {
  const agents = Array.from({ length: AGENTS }, (_, index) =>
    index === 0 ? spawn(Agent, { maxMemory: "64M" }) : spawn(Agent),
  );
  await Promise.all(agents.map((agent) => agent.ping()));
  const started = performance.now();
  const [[killed, recovered], samples] = await Promise.all([
    watchLeak(agents[0], started),
    pingRounds(agents.slice(1), started + WINDOW_MS),
  ]);
  const failures = samples.filter((sample) => !sample.ok);
  const sorted = samples.map((sample) => sample.ms).toSorted((a, b) => a - b);
  return {
    pings: samples.length,
    failed_requests: failures.length,
    agents_lost: new Set(failures.map((sample) => sample.agent)).size,
    p50_ms: percentile(sorted, 0.5),
    p99_ms: percentile(sorted, 0.99),
    max_ms: percentile(sorted, 1),
    killed_ms: killed,
    recovery_ms: recovered,
    leaker_restarts: inspect()[0].restarts,
    process_lost: 0,
  };
}

console.log(JSON.stringify(await measure()));
