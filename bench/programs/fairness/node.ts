// Fairness, plain Node: 8 mailbox actors from node-actor.ts run CPU-bound loops for 2 s
// while the main code pings another actor, sleeps 1 ms, and pings again until the 2 s
// end. No worker_threads: one event loop runs every actor, so a loop blocks the pings
// until it ends. A sample is the round trip of one ping.
import { Actor, percentile, sleep } from "../node-actor.ts";

const SPINNERS = 8;
const WINDOW_MS = 2000;

class Spinner {
  spin(until: number): number {
    let turns = 0;
    while (performance.now() < until) {
      turns++;
    }
    return turns;
  }
}

class Echo {
  ping(n: number): number {
    return n;
  }
}

async function measure(): Promise<object> {
  const spinners = Array.from({ length: SPINNERS }, () => new Actor(() => new Spinner()));
  const echo = new Actor(() => new Echo());
  const until = performance.now() + WINDOW_MS;
  for (const spinner of spinners) {
    spinner.cast("spin", until);
  }
  const samples: number[] = [];
  while (performance.now() < until) {
    const sent = performance.now();
    await echo.call("ping", 1);
    samples.push(performance.now() - sent);
    await sleep(1);
  }
  samples.sort((a, b) => a - b);
  return {
    pings: samples.length,
    p50_ms: percentile(samples, 0.5),
    p99_ms: percentile(samples, 0.99),
    max_ms: percentile(samples, 1),
  };
}

console.log(JSON.stringify(await measure()));
