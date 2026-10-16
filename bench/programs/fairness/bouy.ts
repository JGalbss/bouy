import { cast, sleep, spawn } from "bouy";

// Fairness: 8 actors run CPU-bound loops for 2 s while the top-level code pings another
// actor, sleeps 1 ms, and pings again until the 2 s end. A sample is the round trip of
// one ping, timed with performance.now() as in the Node program.

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

// The nearest-rank percentile of sorted samples.
function percentile(sorted: number[], fraction: number): number {
  return sorted[Math.max(0, Math.ceil(fraction * sorted.length) - 1)] ?? 0;
}

async function measure(): Promise<object> {
  const spinners = Array.from({ length: SPINNERS }, () => spawn(Spinner));
  const echo = spawn(Echo);
  const until = performance.now() + WINDOW_MS;
  for (const spinner of spinners) {
    cast(spinner).spin(until);
  }
  const samples: number[] = [];
  while (performance.now() < until) {
    const sent = performance.now();
    await echo.ping(1);
    samples.push(performance.now() - sent);
    sleep(1);
  }
  const sorted = samples.toSorted((a, b) => a - b);
  return {
    pings: sorted.length,
    p50_ms: percentile(sorted, 0.5),
    p99_ms: percentile(sorted, 0.99),
    max_ms: percentile(sorted, 1),
  };
}

console.log(JSON.stringify(await measure()));
