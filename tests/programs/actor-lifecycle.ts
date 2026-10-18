import { cast, child, inspect, self, sleep, spawn, stop, supervise, type Ref } from "buoy";

// The life of actors: the actors that a constructor starts stop with it,
// stopped actors do not pile up, inspect() shows a restart until its
// constructor ends, a ref from a failed constructor keeps its label, a
// Promise.race loser no longer acts for the turn that started it, and a cast
// that waits for room in a stopped actor throws ActorStopped.

class Leaf {}

class Team {
  constructor() {
    supervise({ children: { leaf: child(Leaf) } });
  }

  boom(): void {
    throw new Error("team boom");
  }
}

class SlowStart {
  constructor() {
    sleep(500);
  }

  boom(): void {
    throw new Error("slow boom");
  }
}

class Registry {
  #refs: any[] = [];

  add(ref: any): void {
    this.#refs.push(ref);
  }

  first(): any {
    return this.#refs[0];
  }
}

class Doomed {
  constructor(registry: Ref<Registry>) {
    registry.add(self(this));
    throw new Error("constructor failed after registering");
  }

  ping(): string {
    return "pong";
  }
}

class Racer {
  #log: string[] = [];

  go(): string {
    const me = self(this);
    return Promise.race([1, 2].map((k) => (k === 1 ? "fast" : later(me))));
  }

  record(entry: string): void {
    this.#log.push(entry);
  }

  log(): string[] {
    return this.#log;
  }
}

function later(me: Ref<Racer>): string {
  sleep(100);
  try {
    me.record("late");
    return "recorded";
  } catch (error) {
    return error._tag;
  }
}

class Cell {
  ping(): string {
    return "pong";
  }

  greet(): string {
    return `${this.constructor.name} ready`;
  }

  work(ms: number): void {
    sleep(ms);
  }
}

function castWaiting(cell: Ref<Cell>): string {
  try {
    return `cast returned ${cast(cell).work(1)}`;
  } catch (error) {
    return `cast threw ${error._tag}`;
  }
}

function stopLater(cell: Ref<Cell>): string {
  sleep(200);
  stop(cell);
  return "stopped";
}

async function main(): Promise<void> {
  const outer = supervise({ children: { team: child(Team) } });
  for (let i = 0; i < 3; i++) {
    try {
      await outer.team.boom();
    } catch (error) {}
  }
  await sleep(100);
  console.log(
    `running leaves after 3 restarts: ${inspect().filter((actor) => actor.class === "Leaf" && actor.status === "running").length}`,
  );

  const slow = spawn(SlowStart, { name: "slow" });
  try {
    await slow.boom();
  } catch (error) {}
  await sleep(100);
  console.log(
    `status during the restart constructor: ${inspect().find((actor) => actor.name === "slow")?.status}`,
  );

  const registry = spawn(Registry);
  try {
    spawn(Doomed, { args: [registry], name: "doomed" });
  } catch (error) {}
  const ghost = await registry.first();
  try {
    await ghost.ping();
  } catch (error) {
    console.log(`${error._tag} | ${error.message}`);
  }

  try {
    spawn(Error as any);
  } catch (error) {
    console.log(`${error.name}: ${error.message}`);
  }

  const racer = spawn(Racer);
  console.log(await racer.go());
  await sleep(300);
  console.log(await racer.log());

  const config = JSON.parse('{"capacity": 64.0, "restarts": 2.0}');
  const sized = spawn(Cell, { mailbox: { capacity: config.capacity } });
  const team = supervise({ maxRestarts: config.restarts, children: { cell: child(Cell) } });
  console.log(`integral floats as options: ${await sized.ping()} ${await team.cell.ping()}`);
  console.log(await sized.greet());

  const full = spawn(Cell, { mailbox: { capacity: 1 } });
  cast(full).work(2000);
  await sleep(50);
  cast(full).work(1);
  console.log(await Promise.all([castWaiting(full), stopLater(full)]));

  for (let i = 0; i < 3000; i++) stop(spawn(Cell));
  const stopped = inspect().filter((actor) => actor.status === "stopped").length;
  console.log(`stopped actors kept: ${stopped}`);
}

await main();
