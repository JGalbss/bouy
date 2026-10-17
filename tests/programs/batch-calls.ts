import { self, spawn } from "bouy";

class Counter {
  #count = 0;

  add(n: number): number {
    this.#count += n;
    return this.#count;
  }

  failFirst(index: number): number {
    if (index === 0) throw new Error("boom");
    return this.#count;
  }
}

class Named {
  #name: string;

  constructor(name: string) {
    this.#name = name;
  }

  name(): string {
    return this.#name;
  }
}

class Hub {
  #peers: any[] = [];

  join(peers: any[], withSelf: boolean): number {
    this.#peers = withSelf ? [...peers, self(this)] : peers;
    return this.#peers.length;
  }

  name(): string {
    return "hub";
  }

  async poll(): Promise<string> {
    try {
      const names = await Promise.all(this.#peers.map((peer) => peer.name()));
      return names.join(",");
    } catch (error) {
      return error._tag;
    }
  }
}

async function main(): Promise<void> {
  const counters = Array.from({ length: 4 }, () => spawn(Counter));
  console.log(await Promise.all(counters.map((counter, i) => counter.add(i))));

  const many = Array.from({ length: 1000 }, (_, i) => counters[i % 4]);
  const added = await Promise.all(many.map((counter) => counter.add(1)));
  console.log(`${added.length} calls answered`);
  console.log(await Promise.all(counters.map((counter) => counter.add(0))));

  const plain = { add: (n: number) => n * 10 };
  console.log(await Promise.all([counters[1], plain].map((target) => target.add(2))));

  try {
    await Promise.all(counters.map((counter, i) => counter.failFirst(i)));
  } catch (error) {
    console.log(`${error._tag} in ${error.method}`);
  }
  console.log(await Promise.all(counters.map((counter) => counter.add(0))));

  const hub = spawn(Hub);
  const peers = [spawn(Named, { args: ["a"] }), spawn(Named, { args: ["b"] })];
  await hub.join(peers, true);
  console.log(await hub.poll());
  await hub.join(peers, false);
  console.log(await hub.poll());
}

await main();
