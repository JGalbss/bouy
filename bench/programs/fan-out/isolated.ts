// Fan-out, isolated Node: 10,000 concurrent calls over 1,000 mailbox actors with
// Promise.all, ten calls per actor, in 10 rounds. A worker thread for each actor does not
// fit in memory, so a pool of worker threads from node-shards.ts, one for each core up to
// 8, hosts a shard of the actors each. postMessage copies each call and each reply with
// the structured clone, as Bouy copies a message. The actors of one shard share a thread.
import { availableParallelism } from "node:os";
import { isMainThread } from "node:worker_threads";
import { Shards, serveShard } from "../node-shards.ts";

const ACTORS = 1000;
const CALLS = 10000;
const ROUNDS = 10;
const SHARDS = Math.min(8, availableParallelism());

class Worker {
  work(n: number): number {
    return n * 2;
  }
}

async function measure(): Promise<object> {
  const workers = new Shards({ url: new URL(import.meta.url), shards: SHARDS, agents: ACTORS });
  await workers.ready();
  const targets = Array.from({ length: CALLS }, (_, i) => i % ACTORS);
  let total = 0;
  let slowest = 0;
  let answers = 0;
  for (let round = 0; round < ROUNDS; round++) {
    const started = performance.now();
    const results = await Promise.all(
      targets.map((worker, i) => workers.call(worker, "work", Infinity, i)),
    );
    const elapsed = performance.now() - started;
    total += elapsed;
    slowest = Math.max(slowest, elapsed);
    answers += results.length;
  }
  await workers.close();
  if (answers !== CALLS * ROUNDS) throw new Error(`${answers} of ${CALLS * ROUNDS} calls answered`);
  return { calls_per_s: Math.round((answers * 1000) / total), max_round_ms: slowest };
}

if (isMainThread) {
  console.log(JSON.stringify(await measure()));
  process.exit(0);
} else {
  serveShard(() => new Worker());
}
