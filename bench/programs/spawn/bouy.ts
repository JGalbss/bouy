import { spawn } from "bouy";

// Spawn: start 100,000 actors that each hold a number, and keep their refs. The harness
// derives the memory per actor from the peak RSS of this run and of `startup`. The
// constructor only stores its argument, so the compiler marks it pure, and spawn() runs it
// in the calling process without a wait for the new process (contract section 9). A
// constructor with effects takes the slower path, which waits for the new process.

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
  const started = Date.now();
  const cells = Array.from({ length: ACTORS }, (_, i) => spawn(Cell, { args: [i] }));
  const elapsed = Date.now() - started;
  if ((await cells[0].read()) !== 0) throw new Error("the first actor lost its value");
  return { actors: ACTORS, per_actor_us: (elapsed * 1000) / ACTORS };
}

console.log(JSON.stringify(await measure()));
