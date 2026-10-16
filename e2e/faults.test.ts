import { describe, expect, it } from "vitest";
import { z } from "zod";
import {
  BOUY_HOSTS,
  PROGRAMS,
  launch,
  lastJsonLine,
  CHILD_TIMEOUT_MS,
  TEST_TIMEOUT_MS,
  type Host,
} from "./hosts.ts";

const FaultReport = z.object({
  fault: z.enum(["timer", "microtask", "emitter", "shared-emitter", "promise"]),
  armedBefore: z.number(),
  armedAfter: z.number(),
  faultyRestarts: z.number(),
  steadyRestarts: z.number(),
  steadyRepliesInOrder: z.boolean(),
  steadyReplies: z.number(),
  exitCode: z.number(),
});

const RESTARTED = {
  armedBefore: 1,
  armedAfter: 0,
  faultyRestarts: 1,
  steadyRestarts: 0,
  steadyRepliesInOrder: true,
  exitCode: 0,
};

const ESCAPED = {
  armedBefore: 1,
  armedAfter: 1,
  faultyRestarts: 0,
  steadyRestarts: 0,
  steadyRepliesInOrder: true,
  exitCode: 1,
};

const LOST_STORE_ON_BUN = [
  ["microtask", "a queueMicrotask callback"],
  ["promise", "a floating promise"],
] as const;

const injectFault = (host: Host, fault: string) =>
  launch(host, "faults.ts", {
    cwd: PROGRAMS,
    timeoutMs: CHILD_TIMEOUT_MS,
    env: { FAULT: fault },
  });

describe("fault isolation", () => {
  for (const host of BOUY_HOSTS) {
    const test = { timeout: TEST_TIMEOUT_MS, skip: !host.available };

    for (const [fault, site] of [
      ["timer", "a setTimeout callback"],
      ["emitter", "an EventEmitter listener that its own timer emits"],
    ] as const) {
      it(`restarts an actor that throws in ${site} on ${host.name}`, test, async () => {
        const exit = await injectFault(host, fault);
        expect(exit.code, exit.stderr).toBe(0);
        expect(lastJsonLine(FaultReport, exit)).toMatchObject({ fault, ...RESTARTED });
      });
    }

    it(
      `attributes a shared EventEmitter listener fault to the actor whose turn emitted, on ${host.name}`,
      test,
      async () => {
        const exit = await injectFault(host, "shared-emitter");
        expect(exit.code, exit.stderr).toBe(0);
        expect(lastJsonLine(FaultReport, exit)).toMatchObject({
          fault: "shared-emitter",
          armedBefore: 1,
          armedAfter: 1,
          faultyRestarts: 0,
          steadyRestarts: 1,
          exitCode: 0,
        });
      },
    );
  }

  for (const host of BOUY_HOSTS.filter((candidate) => candidate.runtime === "node")) {
    const test = { timeout: TEST_TIMEOUT_MS };

    for (const [fault, site] of LOST_STORE_ON_BUN) {
      it(`restarts an actor that throws in ${site} on ${host.name}`, test, async () => {
        const exit = await injectFault(host, fault);
        expect(exit.code, exit.stderr).toBe(0);
        expect(lastJsonLine(FaultReport, exit)).toMatchObject({ fault, ...RESTARTED });
      });
    }
  }

  for (const host of BOUY_HOSTS.filter((candidate) => candidate.runtime === "bun")) {
    const test = { timeout: TEST_TIMEOUT_MS, skip: !host.available };

    for (const [fault, site] of LOST_STORE_ON_BUN) {
      it(
        `reports a fault in ${site} as escaped and exits 1 on ${host.name}, because Bun 1.3.11 loses the AsyncLocalStorage store in the process fault handlers`,
        test,
        async () => {
          const exit = await injectFault(host, fault);
          expect(exit.code, exit.stderr).toBe(1);
          expect(exit.stderr).toContain("bouy: an error escaped outside any actor turn");
          expect(exit.stderr).toContain(`${fault} fault`);
          expect(lastJsonLine(FaultReport, exit)).toMatchObject({ fault, ...ESCAPED });
        },
      );
    }
  }
});
