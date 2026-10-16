import { threadId } from "node:worker_threads";
import { locate } from "../../src/intrinsics.ts";

export class Calculator {
  #calls = 0;

  where(): number {
    return threadId;
  }

  square(value: number): number {
    this.#calls += 1;
    return value * value;
  }

  calls(): number {
    return this.#calls;
  }

  spin(): number {
    let spins = 0;
    while (spins >= 0) spins += 1;
    return spins;
  }

  count(items: ReadonlyArray<unknown>): number {
    return items.length;
  }

  explode(): never {
    throw new RangeError("calculator exploded");
  }

  hoard(megabytes: number): number {
    const chunks: Array<Array<number>> = [];
    for (let index = 0; index < megabytes * 16; index += 1)
      chunks.push(Array.from({ length: 8_192 }, () => index));
    return chunks.length;
  }
}

locate(Calculator, import.meta.url, "Calculator");
