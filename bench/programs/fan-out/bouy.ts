import { spawn } from "bouy";

// Fan-out: 10,000 parallel calls over 1,000 actors with Promise.all, ten calls per actor,
// in 10 rounds. Bouy runs each call of a round in its own process.

const ACTORS = 1000;
const CALLS = 10000;
const ROUNDS = 10;

class Worker {
  work(n: number): number {
    return n * 2;
  }
}

async function measure(): Promise<object> {
  const workers = Array.from({ length: ACTORS }, () => spawn(Worker));
  const targets = Array.from({ length: CALLS / ACTORS }, () => workers).flat();
  let total = 0;
  let slowest = 0;
  let answers = 0;
  for (let round = 0; round < ROUNDS; round++) {
    const started = Date.now();
    const results = await Promise.all(targets.map((worker, i) => worker.work(i)));
    const elapsed = Date.now() - started;
    total += elapsed;
    slowest = Math.max(slowest, elapsed);
    answers += results.length;
  }
  if (answers !== CALLS * ROUNDS) throw new Error(`${answers} of ${CALLS * ROUNDS} calls answered`);
  return { calls_per_s: Math.round((answers * 1000) / total), max_round_ms: slowest };
}

console.log(JSON.stringify(await measure()));
