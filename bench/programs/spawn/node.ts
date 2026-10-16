// Spawn, plain Node: 100,000 mailbox actors from node-actor.ts, each an object that holds
// a number, with their refs kept in an array. No worker_threads. The harness derives the
// memory per actor from the peak RSS of this run and of `startup`.
import { Actor } from "../node-actor.ts";

const ACTORS = 100000;

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
  const cells = Array.from({ length: ACTORS }, (_, i) => new Actor(() => new Cell(i)));
  const elapsed = performance.now() - started;
  if ((await cells[0]?.call("read")) !== 0) throw new Error("the first actor lost its value");
  return { actors: ACTORS, per_actor_us: (elapsed * 1000) / ACTORS };
}

console.log(JSON.stringify(await measure()));
