// Call latency, plain Node: 100,000 sequential calls to one mailbox actor from
// node-actor.ts, each awaited before the next. No worker_threads. performance.now() gives
// the percentiles of single calls, which the Buoy program cannot measure.
import { Actor, percentile } from "../node-actor.ts";

const CALLS = 100000;

class Echo {
  ping(n: number): number {
    return n;
  }
}

async function measure(): Promise<object> {
  const echo = new Actor(() => new Echo());
  const samples = new Float64Array(CALLS);
  let answered = 0;
  const started = performance.now();
  for (let i = 0; i < CALLS; i++) {
    const sent = performance.now();
    answered += Number(await echo.call("ping", 1));
    samples[i] = performance.now() - sent;
  }
  const total = performance.now() - started;
  if (answered !== CALLS) throw new Error(`${answered} of ${CALLS} calls answered`);
  samples.sort();
  return {
    mean_us: (total * 1000) / CALLS,
    max_ms: percentile(samples, 1),
    p50_us: percentile(samples, 0.5) * 1000,
    p99_us: percentile(samples, 0.99) * 1000,
  };
}

console.log(JSON.stringify(await measure()));
