import { cast, spawn } from "buoy";

// Crash isolation: 100 agents answer pings. Agent 0 throws inside an async callback of
// Promise.all. The rejection fails the turn of the agent, so the agent crashes and its
// supervisor, the keeper, restarts it. For 500 ms
// after the fault, the program pings all 100 agents in rounds of parallel calls, one round
// every 5 ms, and meanwhile pings agent 0 until it answers. It records the agents that
// answer the first round, the pings that fail, and the time from the fault until agent 0
// answers again. A spare agent crashes once before, so the first crash of the code path
// does not count.

const AGENTS = 100;
const WINDOW_MS = 500;
const PAUSE_MS = 5;

class Agent {
  ping(): number {
    return 1;
  }

  async explode(): Promise<number> {
    const replies = await Promise.all(
      [1, 2].map(async (n) => {
        if (n === 2) throw new Error("the callback failed");
        return n;
      }),
    );
    return replies.length;
  }
}

// How many agents answered one ping each.
async function pingAll(agents: any[]): Promise<number> {
  const settled = await Promise.allSettled(agents.map((agent) => agent.ping()));
  return settled.filter((outcome) => outcome.status === "fulfilled").length;
}

// Waits ms without blocking the realm, so the replies of other calls keep arriving.
function pause(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function pingRounds(agents: any[], until: number): Promise<number[]> {
  const answers: number[] = [];
  while (performance.now() < until) {
    answers.push(await pingAll(agents));
    await pause(PAUSE_MS);
  }
  return answers;
}

// The time from the fault until the agent answers a ping.
async function recovery(agent: any, faulted: number): Promise<number> {
  for (;;) {
    try {
      await agent.ping();
      return performance.now() - faulted;
    } catch {}
  }
}

async function measure(): Promise<object> {
  const agents = Array.from({ length: AGENTS }, () => spawn(Agent));
  await pingAll(agents);
  const spare = spawn(Agent);
  cast(spare).explode();
  await recovery(spare, 0);
  const faulted = performance.now();
  cast(agents[0]).explode();
  const [recovered, answers] = await Promise.all([
    recovery(agents[0], faulted),
    pingRounds(agents, faulted + WINDOW_MS),
  ]);
  const answered = answers.reduce((sum, count) => sum + count, 0);
  return {
    agents_answering: answers[0],
    pings: answers.length * AGENTS,
    failed_requests: answers.length * AGENTS - answered,
    recovery_ms: recovered,
  };
}

console.log(JSON.stringify(await measure()));
