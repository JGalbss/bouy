// Actors get copies of arguments and results; each actor has its own state.
import { spawn } from "buoy";

class Store {
  items: string[];
  constructor(initial: string[]) {
    this.items = initial;
  }
  add(item: string): number {
    this.items.push(item);
    return this.items.length;
  }
  snapshot(): string[] {
    return this.items;
  }
}

async function main(): Promise<void> {
  const seed = ["seed"];
  const one = spawn(Store, { args: [seed] });
  const two = spawn(Store, { args: [["other"]] });
  seed.push("local only");
  console.log(await one.add("a"), await two.add("b"), await one.add("c"));
  const snap = await one.snapshot();
  snap.push("not in actor");
  console.log(snap, await one.snapshot(), await two.snapshot(), seed);
}

await main();
