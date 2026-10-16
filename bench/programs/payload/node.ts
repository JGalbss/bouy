// Payloads, plain Node: 100,000 casts of one 1 KB object to one mailbox actor from
// node-actor.ts, then one call that waits until the actor has taken them all. Node passes
// a reference to the same object and copies nothing. No worker_threads.
import { Actor } from "../node-actor.ts";

const MESSAGES = 100000;

type Order = { items: unknown[] };

class Sink {
  #items = 0;

  take(order: Order): void {
    this.#items += order.items.length;
  }

  items(): number {
    return this.#items;
  }
}

async function measure(): Promise<object> {
  const order = {
    id: 1,
    customer: { name: "Ada Lovelace", email: "ada@example.com" },
    items: Array.from({ length: 20 }, (_, i) => ({
      sku: `SKU-${1000 + i}`,
      quantity: i + 1,
      price: 9.99,
    })),
  };
  const sink = new Actor(() => new Sink());
  const started = performance.now();
  for (let i = 0; i < MESSAGES; i++) {
    sink.cast("take", order);
  }
  const items = Number(await sink.call("items"));
  const total = performance.now() - started;
  if (items !== MESSAGES * order.items.length) throw new Error(`the actor took ${items} items`);
  return {
    messages_per_s: Math.round((MESSAGES * 1000) / total),
    payload_bytes: JSON.stringify(order).length,
  };
}

console.log(JSON.stringify(await measure()));
