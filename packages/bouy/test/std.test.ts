import { afterEach, describe, expect, it } from "vitest";
import { ActorFailed, inspect, self, shutdown, spawn, stop } from "../src/index.ts";
import { NameTaken, lookup, pool, register, schedule } from "../src/std.ts";

const holds: Array<() => void> = [];

class Worker {
  readonly #id = Math.random().toString(36).slice(2);

  whoAmI(): string {
    return this.#id;
  }

  async slow(): Promise<string> {
    await new Promise<void>((resolve) => holds.push(resolve));
    return this.#id;
  }

  explode(): never {
    throw new Error("worker exploded");
  }
}

const incarnations = { next: 0 };

class Heartbeat {
  readonly #id: number;
  readonly #sources: Array<number> = [];

  constructor() {
    incarnations.next += 1;
    this.#id = incarnations.next;
    schedule(self<Heartbeat>(this), { every: 5 }, "beat", this.#id);
  }

  beat(source: number): void {
    this.#sources.push(source);
  }

  id(): number {
    return this.#id;
  }

  sources(): Array<number> {
    return this.#sources;
  }

  explode(): never {
    throw new Error("heartbeat exploded");
  }
}

class Reminder {
  #reminded = false;

  remindLater(ms: number): void {
    schedule(self<Reminder>(this), { after: ms }, "remind");
  }

  remind(): void {
    this.#reminded = true;
  }

  reminded(): boolean {
    return this.#reminded;
  }
}

const settle = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

const until = async (ready: () => Promise<boolean>): Promise<void> => {
  const deadline = performance.now() + 5_000;
  while (!(await ready())) {
    if (performance.now() > deadline) throw new Error("the condition did not hold within 5 s");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
};

afterEach(() => shutdown());

describe("pool", () => {
  it("routes calls to the least busy member", async () => {
    const workers = pool(Worker, 3);
    const busy = workers.slow();
    await settle(5);
    const answers = await Promise.all([workers.whoAmI(), workers.whoAmI()]);
    holds.shift()?.();
    const busyId = await busy;
    expect(answers).not.toContain(busyId);
    expect(new Set(answers).size).toBe(2);
  });

  it("keeps serving after a member crashes", async () => {
    const workers = pool(Worker, 2);
    await expect(workers.explode()).rejects.toBeInstanceOf(ActorFailed);
    expect(await workers.whoAmI()).toEqual(expect.any(String));
    expect(inspect().filter((actor) => actor.name === "Worker")).toHaveLength(2);
  });
});

describe("timers", () => {
  it("delivers periodic messages to the actor and stops them on restart", async () => {
    const heartbeat = spawn(Heartbeat);
    await until(async () => (await heartbeat.sources()).length >= 3);
    const before = await heartbeat.id();
    await expect(heartbeat.explode()).rejects.toBeInstanceOf(ActorFailed);
    const after = await heartbeat.id();
    await until(
      async () => (await heartbeat.sources()).filter((source) => source === after).length >= 5,
    );
    const sources = await heartbeat.sources();
    expect(after).not.toBe(before);
    expect(sources.filter((source) => source === before).length).toBeLessThanOrEqual(1);
    expect(sources.slice(1).every((source) => source === after)).toBe(true);
  });

  it("delivers a single delayed message", async () => {
    const reminder = spawn(Reminder);
    await reminder.remindLater(10);
    expect(await reminder.reminded()).toBe(false);
    await settle(30);
    expect(await reminder.reminded()).toBe(true);
  });

  it("stops timers when the actor stops", async () => {
    const heartbeat = spawn(Heartbeat);
    await until(async () => (await heartbeat.sources()).length >= 1);
    await stop(heartbeat);
    await settle(30);
    expect(inspect().some((actor) => actor.name === "Heartbeat")).toBe(false);
  });
});

describe("registry", () => {
  it("finds a registered actor by name and class", async () => {
    const worker = spawn(Worker);
    register("primary", worker);
    const found = lookup("primary", Worker);
    expect(found).toBe(worker);
    expect(lookup("primary", Heartbeat)).toBeUndefined();
    expect(await found?.whoAmI()).toBe(await worker.whoAmI());
  });

  it("refuses a taken name and frees it when the actor stops", async () => {
    const first = spawn(Worker);
    register("unique", first);
    expect(() => register("unique", spawn(Worker))).toThrow(NameTaken);
    await stop(first);
    await settle(1);
    expect(lookup("unique", Worker)).toBeUndefined();
  });
});
