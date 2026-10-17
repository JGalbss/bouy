// Payloads, isolated Node: 100,000 casts of one 1 KB object to one mailbox actor that runs
// on its own worker thread, from node-shards.ts, then one call that waits until the actor
// has taken them all. postMessage copies the object with the structured clone for each
// cast, as Bouy copies a message.
import { isMainThread } from "node:worker_threads";
import { Shards, serveShard } from "../node-shards.ts";

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
  const sink = new Shards({ url: new URL(import.meta.url), shards: 1, agents: 1 });
  await sink.ready();
  const started = performance.now();
  for (let i = 0; i < MESSAGES; i++) {
    sink.cast(0, "take", order);
  }
  const items = Number(await sink.call(0, "items", Infinity));
  const total = performance.now() - started;
  await sink.close();
  if (items !== MESSAGES * order.items.length) throw new Error(`the actor took ${items} items`);
  return {
    messages_per_s: Math.round((MESSAGES * 1000) / total),
    payload_bytes: JSON.stringify(order).length,
  };
}

if (isMainThread) {
  console.log(JSON.stringify(await measure()));
  process.exit(0);
} else {
  serveShard(() => new Sink());
}
