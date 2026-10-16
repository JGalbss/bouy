import { cast, spawn } from "bouy";

class Log {
  #entries: number[] = [];

  append(entry: number): void {
    this.#entries.push(entry);
  }

  entries(): number[] {
    return this.#entries;
  }
}

async function main(): Promise<void> {
  const log = spawn(Log);
  for (let i = 0; i < 1000; i++) {
    cast(log).append(i);
  }
  const entries = await log.entries();
  console.log(`${entries.length} entries`);
  console.log(`in order: ${entries.every((entry, index) => entry === index)}`);
}

await main();
