import { afterEach, describe, expect, it } from "vitest";
import {
  ActorFailed,
  ActorStopped,
  inspect,
  monitor,
  shutdown,
  spawn,
  supervise,
  child,
  tree,
} from "../src/index.ts";

class Counter {
  #count = 0;

  increment(): number {
    this.#count += 1;
    return this.#count;
  }

  explode(reason: string): never {
    throw new Error(reason);
  }

  async explodeLater(reason: string): Promise<never> {
    await new Promise((resolve) => setTimeout(resolve, 1));
    throw new Error(reason);
  }
}

class Fragile {
  constructor(configuration: { readonly valid: boolean }) {
    if (!configuration.valid) throw new Error("bad configuration");
  }

  ping(): string {
    return "pong";
  }
}

afterEach(() => shutdown());

describe("supervision", () => {
  it("rejects the caller and restarts the actor with fresh state", async () => {
    const counter = spawn(Counter);
    await counter.increment();
    await counter.increment();
    await expect(counter.explode("boom")).rejects.toBeInstanceOf(ActorFailed);
    expect(await counter.increment()).toBe(1);
    expect(inspect().find((actor) => actor.name === "Counter")?.restarts).toBe(1);
  });

  it("isolates one actor's failure from unrelated actors", async () => {
    const failing = spawn(Counter);
    const healthy = spawn(Counter);
    await healthy.increment();
    await expect(failing.explodeLater("async boom")).rejects.toThrow("async boom");
    expect(await healthy.increment()).toBe(2);
  });

  it("keeps queued messages across a restart", async () => {
    const counter = spawn(Counter);
    const crash = counter.explode("first");
    const after = [counter.increment(), counter.increment()];
    await expect(crash).rejects.toBeInstanceOf(ActorFailed);
    expect(await Promise.all(after)).toEqual([1, 2]);
  });

  it("stops restarting after the intensity limit and rejects later calls", async () => {
    const counter = spawn(Counter, { restart: { maxRestarts: 2, withinMs: 10_000 } });
    for (const attempt of [1, 2, 3]) {
      await expect(counter.explode(`crash ${attempt}`)).rejects.toBeInstanceOf(ActorFailed);
    }
    expect((await monitor(counter)).kind).toBe("failed");
    await expect(counter.increment()).rejects.toBeInstanceOf(ActorStopped);
  });

  it("fails spawn when the first construction throws", () => {
    expect(() => spawn(Fragile, { args: [{ valid: false }] })).toThrow("bad configuration");
    expect(spawn(Fragile, { args: [{ valid: true }] })).toBeDefined();
  });

  it("restarts only the failed child under one-for-one", async () => {
    const team = supervise({
      strategy: "one-for-one",
      children: { left: child(Counter), right: child(Counter) },
    });
    await team.left.increment();
    await team.right.increment();
    await expect(team.left.explode("left")).rejects.toBeInstanceOf(ActorFailed);
    expect(await team.left.increment()).toBe(1);
    expect(await team.right.increment()).toBe(2);
  });

  it("restarts every child under one-for-all", async () => {
    const team = supervise({
      strategy: "one-for-all",
      children: { left: child(Counter), right: child(Counter) },
    });
    await team.left.increment();
    await team.right.increment();
    await expect(team.left.explode("left")).rejects.toBeInstanceOf(ActorFailed);
    expect(await team.left.increment()).toBe(1);
    expect(await team.right.increment()).toBe(1);
  });

  it("restarts the failed child and the children after it under rest-for-one", async () => {
    const team = supervise({
      strategy: "rest-for-one",
      children: { first: child(Counter), middle: child(Counter), last: child(Counter) },
    });
    await Promise.all([team.first.increment(), team.middle.increment(), team.last.increment()]);
    await expect(team.middle.explode("middle")).rejects.toBeInstanceOf(ActorFailed);
    expect(await team.first.increment()).toBe(2);
    expect(await team.middle.increment()).toBe(1);
    expect(await team.last.increment()).toBe(1);
  });

  it("supervises nested trees", async () => {
    const team = supervise({
      strategy: "one-for-one",
      children: {
        lead: child(Counter),
        tools: tree({
          strategy: "one-for-all",
          children: { search: child(Counter), fetch: child(Counter) },
        }),
      },
    });
    await team.lead.increment();
    await team.tools.fetch.increment();
    await expect(team.tools.search.explode("search")).rejects.toBeInstanceOf(ActorFailed);
    expect(await team.tools.fetch.increment()).toBe(1);
    expect(await team.lead.increment()).toBe(2);
  });
});
