import { spawn } from "bouy";

class Counter {
  #count = 0;

  increment(): number {
    this.#count++;
    return this.#count;
  }
}

class Store {
  #items: string[] = [];

  save(items: string[]): void {
    this.#items = items;
  }

  load(): string[] {
    return this.#items;
  }
}

async function main(): Promise<void> {
  const first = spawn(Counter);
  const second = spawn(Counter);
  await first.increment();
  await first.increment();
  await first.increment();
  await second.increment();
  console.log(`first: ${await first.increment()}, second: ${await second.increment()}`);

  // A message carries a copy: a later change to the sender's array does not reach the actor.
  const store = spawn(Store);
  const items = ["a"];
  await store.save(items);
  items.push("b");
  console.log(items, await store.load());
}

await main();
