import { cast, spawn } from "buoy";

// Cast throughput: 1,000,000 casts to one actor, then one call that waits until the
// actor has taken them all. The mailbox has the default capacity of 1024 messages with
// backpressure, so a cast to a full mailbox waits for room.

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
  const counter = spawn(Counter);
  const started = Date.now();
  for (let i = 0; i < CASTS; i++) {
    cast(counter).bump(1);
  }
  const counted = await counter.count();
  const total = Date.now() - started;
  if (counted !== CASTS) throw new Error(`the actor counted ${counted} of ${CASTS} casts`);
  return { casts_per_s: Math.round((CASTS * 1000) / total) };
}

console.log(JSON.stringify(await measure()));
