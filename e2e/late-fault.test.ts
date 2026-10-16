import { describe, expect, it } from "vitest";
import { BOUY_HOSTS, CHILD_TIMEOUT_MS, PROGRAMS, launch, TEST_TIMEOUT_MS } from "./hosts.ts";

describe("late faults", () => {
  for (const host of BOUY_HOSTS) {
    const test = { timeout: TEST_TIMEOUT_MS, skip: !host.available };

    it(
      `logs a fault from an actor that already stopped and sets exit status 1 on ${host.name}`,
      test,
      async () => {
        const exit = await launch(host, "late-fault.ts", {
          cwd: PROGRAMS,
          timeoutMs: CHILD_TIMEOUT_MS,
          args: [],
        });
        expect(exit.stdout).toContain('{"stopped":true}');
        expect(exit.stderr).toContain("raised an error after it stopped or restarted");
        expect(exit.stderr).toContain("late timer fault");
        expect(exit.code).toBe(1);
      },
    );
  }
});
