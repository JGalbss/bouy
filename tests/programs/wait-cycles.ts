import { cast, inspect, sleep, spawn, stop, withTimeout, type Ref } from "buoy";

// Turns that wait on each other at once, through calls, backpressure casts,
// or a restart, end without a deadlock: a call throws CallCycle, and a cast
// goes in at once.

class Peer {
  #peer: Ref<Peer> | undefined;

  connect(peer: Ref<Peer>): void {
    this.#peer = peer;
  }

  async ask(other: Ref<Peer>): Promise<string> {
    // Both turns are running before either calls the other.
    sleep(50);
    try {
      return await other.answer();
    } catch (error) {
      return error._tag;
    }
  }

  answer(): string {
    return "ok";
  }

  flood(count: number): void {
    for (let i = 0; i < count; i++) cast(this.#peer).note();
  }

  note(): void {}
}

class Hub {
  config(): number {
    return 42;
  }

  async restartAndPing(worker: Ref<Worker>): Promise<string> {
    try {
      await worker.boom();
    } catch (error) {}
    try {
      return await worker.ping();
    } catch (error) {
      return error._tag;
    }
  }
}

// The constructor calls the hub, so the actor waits on the hub until the reply.
class Worker {
  #limit: Promise<number>;

  constructor(hub: Ref<Hub>) {
    this.#limit = hub.config();
  }

  boom(): void {
    throw new Error("boom");
  }

  async ping(): Promise<string> {
    return `pong ${await this.#limit}`;
  }
}

class Helper {}

// The restart constructor runs long and then spawns, so a stop() during it
// must neither wait for it nor block the spawn.
class Parent {
  constructor() {
    const me = inspect().find((actor) => actor.class === "Parent");
    if (me !== undefined && me.restarts > 0) {
      sleep(3000);
      spawn(Helper);
    }
  }

  boom(): void {
    throw new Error("parent boom");
  }
}

async function main(): Promise<void> {
  const a = spawn(Peer);
  const b = spawn(Peer);
  const answers = await Promise.all([a.ask(b), b.ask(a)]);
  console.log(`crossing calls end: ${answers.includes("CallCycle")}`);

  const left = spawn(Peer, { mailbox: { capacity: 1 } });
  const right = spawn(Peer, { mailbox: { capacity: 1 } });
  await left.connect(right);
  await right.connect(left);
  cast(left).flood(50);
  cast(right).flood(50);
  await left.note();
  await right.note();
  console.log("crossing backpressure casts end");

  const hub = spawn(Hub);
  const worker = spawn(Worker, { args: [hub] });
  console.log(
    `a call that waits on a restart that waits on it: ${await hub.restartAndPing(worker)}`,
  );
  console.log(`the restart then completes: ${await worker.ping()}`);

  const parent = spawn(Parent);
  try {
    await parent.boom();
  } catch (error) {}
  await sleep(100);
  const started = Date.now();
  await withTimeout(2500, () => stop(parent));
  console.log(`stop returns before the restart constructor ends: ${Date.now() - started < 2500}`);
  spawn(Helper);
  console.log("a spawn after the stop works");
}

await main();
