// Cast throughput, plain Node: 1,000,000 casts to one mailbox actor from node-actor.ts,
// then one call that waits until the actor has taken them all. The Node queue is
// unbounded, so every cast is queued before the actor runs. No worker_threads.
import { Actor } from "../node-actor.ts";

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
  const counter = new Actor(() => new Counter());
  const started = performance.now();
  for (let i = 0; i < CASTS; i++) {
    counter.cast("bump", 1);
  }
  const counted = await counter.call("count");
  const total = performance.now() - started;
  if (counted !== CASTS) throw new Error(`the actor counted ${counted} of ${CASTS} casts`);
  return { casts_per_s: Math.round((CASTS * 1000) / total) };
}

console.log(JSON.stringify(await measure()));
