import { inspect, spawn } from "buoy";

class Hoarder {
  #chunks: string[] = [];

  hoard(): number {
    for (;;) {
      this.#chunks.push("x".repeat(1024 * 1024));
    }
  }

  count(): number {
    return this.#chunks.length;
  }
}

class Counter {
  #count = 0;

  inc(): number {
    this.#count += 1;
    return this.#count;
  }
}

async function main(): Promise<void> {
  const hoarder = spawn(Hoarder, { name: "hoarder", maxMemory: "16M" });
  const counter = spawn(Counter, { name: "counter" });
  await counter.inc();
  try {
    await hoarder.hoard();
  } catch (error) {
    console.log(`${error._tag}: ${error.message}`);
  }
  console.log(`the counter still answers: ${await counter.inc()}`);
  console.log(`the hoarder restarted empty: ${await hoarder.count()}`);
  for (const actor of inspect()) {
    console.log(`${actor.name}: ${actor.status}, restarts ${actor.restarts}`);
  }
}

await main();
