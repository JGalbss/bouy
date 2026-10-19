import { cast, spawn } from "buoy";

// Runaway loop: 100 agents answer pings. Agent 0 enters a loop that never ends, inside its
// turn. The BEAM scheduler preempts it, so the other agents keep their turns. For 1 s the
// program pings the other 99 agents in rounds of parallel calls, one round every 5 ms, and
// times each ping. Every agent has turnTimeout: 100, so the runtime ends a turn that runs
// longer than 100 ms, and the keeper restarts the agent with a fresh state, with no
// supervisor code in the program. A ping that waits behind the loop is lost with it and
// fails, as the Node pool fails the calls of a stuck worker. The program records the ping
// times and failures of the 99 agents, the time until the runaway turn ended, and the time
// until agent 0 answered again.

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

// Waits ms without blocking the realm, so the replies of other calls keep arriving.
function pause(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function pingRounds(others: any[], until: number): Promise<Sample[]> {
  const rounds: Sample[][] = [];
  while (performance.now() < until) {
    rounds.push(await Promise.all(others.map((agent) => timedPing(agent))));
    await pause(PAUSE_MS);
  }
  return rounds.flat();
}

// Starts the loop and pings agent 0 behind it. The turn timeout ends the loop, and the ping
// is lost with it. The next ping waits for the restart.
async function recover(runaway: any, started: number): Promise<number[]> {
  cast(runaway).spin();
  try {
    await runaway.ping();
    throw new Error("the runaway agent answered during its loop");
  } catch (error) {
    if (error._tag !== "ActorStopped") throw error;
  }
  const stopped = performance.now() - started;
  await runaway.ping();
  return [stopped, performance.now() - started];
}

// The nearest-rank percentile of sorted samples.
function percentile(sorted: number[], fraction: number): number {
  return sorted[Math.max(0, Math.ceil(fraction * sorted.length) - 1)] ?? 0;
}

async function measure(): Promise<object> {
  const agents = Array.from({ length: AGENTS }, () => spawn(Agent, { turnTimeout: TIMEOUT_MS }));
  const others = agents.slice(1);
  await Promise.all(agents.map((agent) => agent.ping()));
  const started = performance.now();
  const [[stopped, recovered], samples] = await Promise.all([
    recover(agents[0], started),
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
