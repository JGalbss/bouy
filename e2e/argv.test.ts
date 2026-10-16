import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { z } from "zod";
import {
  BOUY_HOSTS,
  CHILD_TIMEOUT_MS,
  PROGRAMS,
  launch,
  lastJsonLine,
  TEST_TIMEOUT_MS,
} from "./hosts.ts";

const ArgvReport = z.object({
  argv: z.array(z.string()),
  isMain: z.boolean(),
  importMetaMain: z.boolean(),
});

describe("program arguments", () => {
  for (const host of BOUY_HOSTS) {
    const test = { timeout: TEST_TIMEOUT_MS, skip: !host.available };

    it(`gives the program its own path and arguments on ${host.name}`, test, async () => {
      const exit = await launch(host, "argv.ts", {
        cwd: PROGRAMS,
        timeoutMs: CHILD_TIMEOUT_MS,
        args: ["a", "b"],
      });
      expect(exit.code, exit.stderr).toBe(0);
      expect(lastJsonLine(ArgvReport, exit)).toMatchObject({
        argv: [join(PROGRAMS, "argv.ts"), "a", "b"],
        isMain: true,
      });
    });
  }
});
