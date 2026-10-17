import { child, inspect, spawn, supervise } from "bouy";

class Looper {
  #turns = 0;

  spin(): number {
    for (;;) {
      this.#turns += 1;
    }
  }

  turns(): number {
    return this.#turns;
  }

  ping(): string {
    return "pong";
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
  const looper = spawn(Looper, { name: "looper", turnTimeout: 50 });
  const counter = spawn(Counter, { name: "counter" });
  await counter.inc();
  const started = Date.now();
  try {
    await looper.spin();
  } catch (error) {
    console.log(`${error._tag}: ${error.message}`);
  }
  console.log(`the loop ended within a second: ${Date.now() - started < 1000}`);
  console.log(`the counter still answers: ${await counter.inc()}`);
  console.log(`the looper restarted fresh: ${await looper.turns()}`);

  const team = supervise({
    maxRestarts: 1,
    children: { worker: child(Looper, { turnTimeout: 20 }) },
  });
  for (const round of [1, 2]) {
    try {
      await team.worker.spin();
    } catch (error) {
      console.log(`round ${round}: ${error._tag}`);
    }
  }
  try {
    await team.worker.ping();
  } catch (error) {
    console.log(`past the budget: ${error._tag}`);
  }
  for (const actor of inspect()) {
    console.log(`${actor.name}: ${actor.status}, restarts ${actor.restarts}`);
  }
}

await main();
