import { spawn } from "bouy";

// Call latency: 100,000 sequential request/reply calls to one actor. performance.now()
// times each call, so the program reports the mean, the slowest call, and the 50th and
// 99th percentiles, as the Node program does. A Bouy array is a linked list, so the
// samples go into a histogram of whole microseconds, the resolution of the clock.

const CALLS = 100000;

class Echo {
  ping(n: number): number {
    return n;
  }
}

// The nearest-rank percentile of the samples that a histogram counts.
function percentile(histogram: Map<number, number>, count: number, fraction: number): number {
  const rank = Math.max(1, Math.ceil(fraction * count));
  let seen = 0;
  for (const [us, samples] of [...histogram.entries()].toSorted((a, b) => a[0] - b[0])) {
    seen += samples;
    if (seen >= rank) return us;
  }
  return 0;
}

async function measure(): Promise<object> {
  const echo = spawn(Echo);
  const histogram = new Map<number, number>();
  let answered = 0;
  const started = performance.now();
  for (let i = 0; i < CALLS; i++) {
    const sent = performance.now();
    answered += await echo.ping(1);
    const us = Math.round((performance.now() - sent) * 1000);
    histogram.set(us, (histogram.get(us) ?? 0) + 1);
  }
  const total = performance.now() - started;
  if (answered !== CALLS) throw new Error(`${answered} of ${CALLS} calls answered`);
  return {
    mean_us: (total * 1000) / CALLS,
    max_ms: percentile(histogram, CALLS, 1) / 1000,
    p50_us: percentile(histogram, CALLS, 0.5),
    p99_us: percentile(histogram, CALLS, 0.99),
  };
}

console.log(JSON.stringify(await measure()));
