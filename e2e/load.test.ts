import { describe, expect, it } from "vitest";
import { z } from "zod";
import {
  CLI_HOSTS,
  PROGRAMS,
  launch,
  lastJsonLine,
  CHILD_TIMEOUT_MS,
  TEST_TIMEOUT_MS,
} from "./hosts.ts";

const LoadReport = z.object({
  actors: z.number(),
  replies: z.number(),
  everyActorAnsweredInOrder: z.boolean(),
  elapsedMs: z.number(),
});

describe("load", () => {
  for (const host of CLI_HOSTS) {
    const test = { timeout: TEST_TIMEOUT_MS, skip: !host.available };

    it(`answers 20 concurrent calls to each of 2,000 actors on ${host.name}`, test, async () => {
      const exit = await launch(host, "load.ts", { cwd: PROGRAMS, timeoutMs: CHILD_TIMEOUT_MS });
      expect(exit.code, exit.stderr).toBe(0);
      expect(lastJsonLine(LoadReport, exit)).toMatchObject({
        actors: 2_000,
        replies: 40_000,
        everyActorAnsweredInOrder: true,
      });
    });
  }
});
