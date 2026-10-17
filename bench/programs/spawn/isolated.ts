// Spawn, isolated Node: 32 mailbox actors that each hold a number, each on its own worker
// thread, from node-shards.ts. 100,000 worker threads do not fit in memory, and 32 keep
// Node well under the RSS ceiling of the harness. An actor counts as started when it has
// answered one call, so per_actor_us is the time until every actor has answered, divided
// by 32. The harness derives the memory per actor from the peak RSS of this run and of
// `startup` on Node or Bun.
import { isMainThread } from "node:worker_threads";
import { Shards, serveShard } from "../node-shards.ts";

const ACTORS = 32;

class Cell {
  #value: number;

  constructor(value: number) {
    this.#value = value;
  }

  read(): number {
    return this.#value;
  }
}

async function measure(): Promise<object> {
  const started = performance.now();
  const cells = new Shards({ url: new URL(import.meta.url), shards: ACTORS, agents: ACTORS });
  const values = await Promise.all(
    Array.from({ length: ACTORS }, (_, i) => cells.call(i, "read", Infinity)),
  );
  const elapsed = performance.now() - started;
  await cells.close();
  const lost = values.findIndex((value, i) => value !== i);
  if (lost !== -1) throw new Error(`actor ${lost} lost its value`);
  return { actors: ACTORS, per_actor_us: (elapsed * 1000) / ACTORS };
}

if (isMainThread) {
  console.log(JSON.stringify(await measure()));
  process.exit(0);
} else {
  serveShard((agent) => new Cell(agent));
}
