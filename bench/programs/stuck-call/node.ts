// Stuck call, plain Node: 100 mailbox actors from node-actor.ts call a tool 10 times each,
// 1,000 calls in all, and the tool never returns. The tool holds a buffer of 64 KiB and
// reports to a ledger every 50 ms. Each agent uses the usual protection: it makes an
// AbortSignal.timeout(20), passes it to the tool, and races the call against it. The tool,
// like many third-party clients, ignores the signal, and nothing else can stop it: the
// agent gets a TimeoutError, and the tool keeps its timer and its buffer. No
// worker_threads. The calls and the measurements are those of the Buoy program.
import { Actor, sleep } from "../node-actor.ts";

const AGENTS = 100;
const CALLS = 1000;
const TIMEOUT_MS = 20;
const TICK_MS = 50;
const QUIET_MS = 500;
const BUFFER = 64 * 1024;

class Ledger {
  ticks = 0;
  held = new Map<number, number>();

  tick(tool: number, bytes: number): void {
    this.ticks += 1;
    this.held.set(tool, bytes);
  }

  reset(): void {
    this.ticks = 0;
    this.held = new Map();
  }

  // The reports, the tools that sent them, and the bytes that those tools hold.
  report(): number[] {
    const bytes = [...this.held.values()].reduce((sum, held) => sum + held, 0);
    return [this.ticks, this.held.size, bytes];
  }
}

function stuckTool(
  ledger: Ledger,
  tool: number,
  _options: { signal: AbortSignal },
): Promise<never> {
  const buffer = new Array(BUFFER / 8).fill(tool);
  return new Promise(() => {
    ledger.tick(tool, buffer.length * 8);
    setInterval(() => ledger.tick(tool, buffer.length * 8), TICK_MS);
  });
}

function aborted(signal: AbortSignal): Promise<never> {
  return new Promise((_, reject) => {
    signal.addEventListener("abort", () => reject(signal.reason), { once: true });
  });
}

class Agent {
  ledger: Ledger;

  constructor(ledger: Ledger) {
    this.ledger = ledger;
  }

  async ask(tool: number): Promise<string> {
    const signal = AbortSignal.timeout(TIMEOUT_MS);
    try {
      return String(
        await Promise.race([stuckTool(this.ledger, tool, { signal }), aborted(signal)]),
      );
    } catch (error) {
      return error instanceof DOMException ? error.name : String(error);
    }
  }
}

async function measure(): Promise<object> {
  const ledger = new Ledger();
  const agents = Array.from({ length: AGENTS }, () => new Actor(() => new Agent(ledger)));
  const tools = Array.from({ length: CALLS }, (_, tool) => tool);
  const started = performance.now();
  const outcomes = await Promise.all(tools.map((tool) => agents[tool % AGENTS]?.call("ask", tool)));
  const elapsed = performance.now() - started;
  ledger.reset();
  await sleep(QUIET_MS);
  const [ticks, zombies, bytes] = ledger.report();
  return {
    timed_out: outcomes.filter((outcome) => outcome === "TimeoutError").length,
    calls_ms: elapsed,
    zombie_ticks: ticks,
    zombies,
    leftover_kib: (bytes ?? 0) / 1024,
  };
}

console.log(JSON.stringify(await measure()));
process.exit(0);
