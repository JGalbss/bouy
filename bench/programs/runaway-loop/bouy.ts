import { cast, sleep, spawn, stop, withTimeout } from "bouy";

// Runaway loop: 100 agents answer pings. Agent 0 enters a loop that never ends, inside its
// turn. The BEAM scheduler preempts it, so the other agents keep their turns. For 1 s the
// program pings the other 99 agents in rounds of parallel calls, one round every 5 ms, and
// times each ping. Meanwhile a supervisor pings agent 0 with withTimeout(100, ...). The
// call times out, stop() kills the agent at once, and the supervisor spawns a fresh agent
// in its place. stop() is final, so the supervisor replaces the agent, as the Node pool
// replaces a worker. The program records the ping times and failures of the 99 agents,
// the time until the runaway agent stopped, and the time until its replacement answered.

const AGENTS = 100;
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

async function timedPing(agent: any): Promise<Sample> {
  const sent = performance.now();
  try {
    await agent.ping();
    return { ms: performance.now() - sent, ok: true };
  } catch {
    return { ms: performance.now() - sent, ok: false };
  }
}

async function pingRounds(others: any[], until: number): Promise<Sample[]> {
  const rounds: Sample[][] = [];
  while (performance.now() < until) {
    rounds.push(await Promise.all(others.map((agent) => timedPing(agent))));
    sleep(PAUSE_MS);
  }
  return rounds.flat();
}

async function answers(agent: any): Promise<boolean> {
  try {
    await withTimeout(TIMEOUT_MS, () => agent.ping());
    return true;
  } catch {
    return false;
  }
}

async function supervise(runaway: any, started: number): Promise<number[]> {
  if (await answers(runaway)) throw new Error("the runaway agent answered");
  stop(runaway);
  const stopped = performance.now() - started;
  await spawn(Agent).ping();
  return [stopped, performance.now() - started];
}

// The nearest-rank percentile of sorted samples.
function percentile(sorted: number[], fraction: number): number {
  return sorted[Math.max(0, Math.ceil(fraction * sorted.length) - 1)] ?? 0;
}

async function measure(): Promise<object> {
  const agents = Array.from({ length: AGENTS }, () => spawn(Agent));
  const others = agents.slice(1);
  await Promise.all(agents.map((agent) => agent.ping()));
  const started = performance.now();
  cast(agents[0]).spin();
  const [[stopped, recovered], samples] = await Promise.all([
    supervise(agents[0], started),
    pingRounds(others, started + WINDOW_MS),
  ]);
  const sorted = samples.map((sample) => sample.ms).toSorted((a, b) => a - b);
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

console.log(JSON.stringify(await measure()));
