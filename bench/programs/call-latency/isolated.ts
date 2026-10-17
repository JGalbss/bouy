// Call latency, isolated Node: 100,000 sequential calls to one mailbox actor that runs on
// its own worker thread, from node-shards.ts, each awaited before the next. postMessage
// copies each call and each reply with the structured clone, as Bouy copies a message.
// performance.now() gives the percentiles of single calls.
import { isMainThread } from "node:worker_threads";
import { percentile } from "../node-actor.ts";
import { Shards, serveShard } from "../node-shards.ts";

const CALLS = 100000;

class Echo {
  ping(n: number): number {
    return n;
  }
}

async function measure(): Promise<object> {
  const echo = new Shards({ url: new URL(import.meta.url), shards: 1, agents: 1 });
  await echo.ready();
  const samples = new Float64Array(CALLS);
  let answered = 0;
  const started = performance.now();
  for (let i = 0; i < CALLS; i++) {
    const sent = performance.now();
    answered += Number(await echo.call(0, "ping", Infinity, 1));
    samples[i] = performance.now() - sent;
  }
  const total = performance.now() - started;
  await echo.close();
  if (answered !== CALLS) throw new Error(`${answered} of ${CALLS} calls answered`);
  samples.sort();
  return {
    mean_us: (total * 1000) / CALLS,
    max_ms: percentile(samples, 1),
    p50_us: percentile(samples, 0.5) * 1000,
    p99_us: percentile(samples, 0.99) * 1000,
  };
}

if (isMainThread) {
  console.log(JSON.stringify(await measure()));
  process.exit(0);
} else {
  serveShard(() => new Echo());
}
