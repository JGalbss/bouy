import { threadId } from "node:worker_threads";
import { afterEach, describe, expect, it } from "vitest";
import { ActorFailed, inspect, NotSendable, shutdown, spawn } from "../src/index.ts";
import { Calculator } from "./fixtures/threaded.ts";

class Bystander {
  ping(): string {
    return "pong";
  }
}

afterEach(() => shutdown());

describe("thread isolation", () => {
  it("runs a thread actor on another thread behind an ordinary ref", async () => {
    const calculator = spawn(Calculator, { isolation: "thread" });
    expect(await calculator.square(12)).toBe(144);
    expect(await calculator.where()).not.toBe(threadId);
  });

  it("restarts a thread actor whose synchronous loop never yields", async () => {
    const calculator = spawn(Calculator, { isolation: "thread", thread: { stallMs: 300 } });
    const bystander = spawn(Bystander);
    await calculator.square(2);
    const spinning = calculator.spin();
    expect(await bystander.ping()).toBe("pong");
    await expect(spinning).rejects.toBeInstanceOf(ActorFailed);
    expect(await calculator.square(3)).toBe(9);
    expect(await calculator.calls()).toBe(1);
    expect(inspect().find((actor) => actor.name === "Calculator")?.restarts).toBe(1);
  }, 15_000);

  it("refuses an actor ref sent to a thread actor and keeps serving", async () => {
    const calculator = spawn(Calculator, { isolation: "thread" });
    const bystander = spawn(Bystander);
    await expect(calculator.count([bystander])).rejects.toBeInstanceOf(NotSendable);
    expect(await calculator.count([1, 2, 3])).toBe(3);
  }, 15_000);

  it("rejects the caller and restarts after a thrown error", async () => {
    const calculator = spawn(Calculator, { isolation: "thread" });
    await expect(calculator.explode()).rejects.toThrow("calculator exploded");
    expect(await calculator.square(5)).toBe(25);
  }, 15_000);

  it.skipIf(process.versions.bun !== undefined)(
    "contains an out-of-memory failure to the thread actor",
    async () => {
      const calculator = spawn(Calculator, { isolation: "thread", thread: { maxHeapMb: 32 } });
      const bystander = spawn(Bystander);
      await expect(calculator.hoard(512)).rejects.toBeInstanceOf(ActorFailed);
      expect(await bystander.ping()).toBe("pong");
      expect(await calculator.square(4)).toBe(16);
    },
    30_000,
  );
});
