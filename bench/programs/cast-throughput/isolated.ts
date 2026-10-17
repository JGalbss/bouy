// Cast throughput, isolated Node: 1,000,000 casts to one mailbox actor that runs on its
// own worker thread, from node-shards.ts, then one call that waits until the actor has
// taken them all. postMessage copies each cast with the structured clone, as Bouy copies a
// message. The message queue of the worker is unbounded.
import { isMainThread } from "node:worker_threads";
import { Shards, serveShard } from "../node-shards.ts";

const CASTS = 1000000;

class Counter {
  #count = 0;

  bump(n: number): void {
    this.#count += n;
  }

  count(): number {
    return this.#count;
  }
}

async function measure(): Promise<object> {
  const counter = new Shards({ url: new URL(import.meta.url), shards: 1, agents: 1 });
  await counter.ready();
  const started = performance.now();
  for (let i = 0; i < CASTS; i++) {
    counter.cast(0, "bump", 1);
  }
  const counted = await counter.call(0, "count", Infinity);
  const total = performance.now() - started;
  await counter.close();
  if (counted !== CASTS) throw new Error(`the actor counted ${counted} of ${CASTS} casts`);
  return { casts_per_s: Math.round((CASTS * 1000) / total) };
}

if (isMainThread) {
  console.log(JSON.stringify(await measure()));
  process.exit(0);
} else {
  serveShard(() => new Counter());
}
