import { setTimeout as sleep } from "node:timers/promises";
import { shutdown, spawn, stop } from "bouy";

class Leaky {
  leak(): string {
    setTimeout(() => {
      throw new Error("late timer fault");
    }, 30);
    return "armed";
  }
}

const leaky = spawn(Leaky);
console.log(await leaky.leak());
await stop(leaky);
await sleep(80);
console.log(JSON.stringify({ stopped: true }));
await shutdown();
