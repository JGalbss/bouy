import { cast, sleep, spawn, withTimeout } from "buoy";

// Stuck call: 100 agents call a tool 10 times each, 1,000 calls in all, and the tool never
// returns. The tool holds a buffer of 64 KiB and reports to a ledger every 50 ms. Each
// agent runs the tool under withTimeout(20, ...), which runs it in a new process and kills
// that process when the time passes: the agent gets CallTimedOut, and the tool stops and
// frees its buffer. After the 1,000 calls, the program waits 500 ms and counts the reports
// of abandoned tools in that time, the tools that sent them, and the buffers they hold.

const AGENTS = 100;
const CALLS = 1000;
const TIMEOUT_MS = 20;
const TICK_MS = 50;
const QUIET_MS = 500;
const BUFFER = 64 * 1024;

class Ledger {
  #ticks = 0;
  #held = new Map<number, number>();

  tick(tool: number, bytes: number): void {
    this.#ticks += 1;
    this.#held.set(tool, bytes);
  }

  reset(): void {
    this.#ticks = 0;
    this.#held = new Map();
  }

  // The reports, the tools that sent them, and the bytes that those tools hold.
  report(): number[] {
    const bytes = [...this.#held.values()].reduce((sum, held) => sum + held, 0);
    return [this.#ticks, this.#held.size, bytes];
  }
}

function stuckTool(ledger: any, tool: number): number {
  const buffer = "x".repeat(BUFFER);
  for (;;) {
    cast(ledger).tick(tool, buffer.length);
    sleep(TICK_MS);
  }
}

class Agent {
  #ledger: any;

  constructor(ledger: any) {
    this.#ledger = ledger;
  }

  async ask(tool: number): Promise<string> {
    try {
      return String(await withTimeout(TIMEOUT_MS, () => stuckTool(this.#ledger, tool)));
    } catch (error) {
      return error._tag;
    }
  }
}

async function measure(): Promise<object> {
  const ledger = spawn(Ledger);
  const agents = Array.from({ length: AGENTS }, () => spawn(Agent, { args: [ledger] }));
  const tools = Array.from({ length: CALLS }, (_, tool) => tool);
  const started = performance.now();
  const outcomes = await Promise.all(tools.map((tool) => agents[tool % AGENTS].ask(tool)));
  const elapsed = performance.now() - started;
  await ledger.reset();
  sleep(QUIET_MS);
  const [ticks, zombies, bytes] = await ledger.report();
  return {
    timed_out: outcomes.filter((outcome) => outcome === "CallTimedOut").length,
    calls_ms: elapsed,
    zombie_ticks: ticks,
    zombies,
    leftover_kib: bytes / 1024,
  };
}

console.log(JSON.stringify(await measure()));
