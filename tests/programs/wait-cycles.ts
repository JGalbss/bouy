import { cast, sleep, spawn, stop, withTimeout, type Ref } from "buoy";

// Turns that wait on each other at once, through calls, backpressure casts,
// or a restart, end without a deadlock: a call throws CallCycle, and a cast
// goes in at once.

class Peer {
  #peer: Ref<Peer> | undefined;

  connect(peer: Ref<Peer>): void {
    this.#peer = peer;
  }

  ask(other: Ref<Peer>): string {
    // Both turns are running before either calls the other.
    sleep(50);
    try {
      return other.answer();
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

  restartAndPing(worker: Ref<Worker>): string {
    try {
      worker.boom();
    } catch (error) {}
    try {
      return worker.ping();
    } catch (error) {
      return error._tag;
    }
  }
}

class Worker {
  #limit: number;

  constructor(hub: Ref<Hub>) {
    this.#limit = hub.config();
  }

  boom(): void {
    throw new Error("boom");
  }

  ping(): string {
    return `pong ${this.#limit}`;
  }
}

class Gate {
  #starts = 0;

  start(): number {
    this.#starts++;
    return this.#starts;
  }
}

class Helper {}

// The restart constructor runs long and then spawns, so a stop() during it
// must neither wait for it nor block the spawn.
class Parent {
  constructor(gate: Ref<Gate>) {
    if (gate.start() > 1) {
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

  const gate = spawn(Gate);
  const parent = spawn(Parent, { args: [gate] });
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
