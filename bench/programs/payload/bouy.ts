import { cast, spawn } from "bouy";

// Payloads: 100,000 casts of one 1 KB object to one actor, then one call that waits
// until the actor has taken them all. The object is many small fields, so the BEAM
// copies every field into the mailbox of the actor. The mailbox has the default
// capacity of 1024 messages with backpressure.

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
  const sink = spawn(Sink);
  const started = Date.now();
  for (let i = 0; i < MESSAGES; i++) {
    cast(sink).take(order);
  }
  const items = await sink.items();
  const total = Date.now() - started;
  if (items !== MESSAGES * order.items.length) throw new Error(`the actor took ${items} items`);
  return {
    messages_per_s: Math.round((MESSAGES * 1000) / total),
    payload_bytes: JSON.stringify(order).length,
  };
}

console.log(JSON.stringify(await measure()));
