import { ActorFailed, shutdown, spawn } from "bouy";
import { afterAll, describe, expect, it } from "vitest";

class Thrower {
  fail(): never {
    throw new Error("always fails");
  }
}

describe("ref types", () => {
  afterAll(() => shutdown());

  it("types a call to a method that returns never as the promise the runtime returns", async () => {
    const thrower = spawn(Thrower);
    const pending: Promise<never> = thrower.fail();
    await expect(pending).rejects.toBeInstanceOf(ActorFailed);
  });
});
