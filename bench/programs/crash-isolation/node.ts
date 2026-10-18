// Crash isolation, plain Node: 100 mailbox actors from node-actor.ts answer pings on one
// event loop. Agent 0 throws inside an async callback: a setTimeout callback, outside the
// promise of its call, as in a callback API. The program uses the usual protections:
// process.on("uncaughtException") logs the error and keeps the process alive, and each
// call has a timeout of 100 ms. The Node docs advise exiting
// after an uncaught exception, which would stop all 100 agents, so this program is the
// kinder case. The throw leaves the call of agent 0 unsettled, so its mailbox stops. A
// call that times out makes the supervisor replace that agent with a fresh actor. No
// worker_threads. The pings and the measurements are those of the Buoy program, and a
// spare agent faults once first, as there.
import { Actor, sleep } from "../node-actor.ts";

const AGENTS = 100;
const WINDOW_MS = 500;
const PAUSE_MS = 5;
const TIMEOUT_MS = 100;

class Agent {
  ping(): number {
    return 1;
  }

  explode(): Promise<number> {
    return new Promise((resolve) => {
      setTimeout(() => resolve(step()), 0);
    });
  }
}

function step(): number {
  throw new Error("the callback failed");
}

class TimeoutError extends Error {}

// A timer that keeps the process alive, unlike AbortSignal.timeout().
function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new TimeoutError(`no answer within ${ms} ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

// Replaces an agent whose call times out.
class Supervisor {
  agents = Array.from({ length: AGENTS }, () => new Actor(() => new Agent()));

  async call(index: number, method: string): Promise<unknown> {
    const agent = this.agents[index];
    try {
      return await withTimeout(agent.call(method), TIMEOUT_MS);
    } catch (error) {
      if (this.agents[index] === agent && error instanceof TimeoutError) {
        this.agents[index] = new Actor(() => new Agent());
      }
      throw error;
    }
  }
}

// How many agents answered one ping each.
async function pingAll(supervisor: Supervisor): Promise<number> {
  const settled = await Promise.allSettled(
    supervisor.agents.map((_, index) => supervisor.call(index, "ping")),
  );
  return settled.filter((outcome) => outcome.status === "fulfilled").length;
}

async function pingRounds(supervisor: Supervisor, until: number): Promise<number[]> {
  const answers: number[] = [];
  while (performance.now() < until) {
    answers.push(await pingAll(supervisor));
    await sleep(PAUSE_MS);
  }
  return answers;
}

// The time from the fault until agent 0 answers a ping.
async function recovery(supervisor: Supervisor, faulted: number): Promise<number> {
  for (;;) {
    try {
      await supervisor.call(0, "ping");
      return performance.now() - faulted;
    } catch {}
  }
}

async function measure(): Promise<object> {
  process.on("uncaughtException", (error) => console.error(`node: uncaught ${String(error)}`));
  const supervisor = new Supervisor();
  await pingAll(supervisor);
  new Actor(() => new Agent()).cast("explode");
  await sleep(10);
  const faulted = performance.now();
  supervisor.agents[0]?.cast("explode");
  const [recovered, answers] = await Promise.all([
    recovery(supervisor, faulted),
    pingRounds(supervisor, faulted + WINDOW_MS),
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
process.exit(0);
