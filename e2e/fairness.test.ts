import { describe, expect, it } from "vitest";
import { z } from "zod";
import {
  BOUY_HOSTS,
  CHILD_TIMEOUT_MS,
  PROGRAMS,
  launch,
  lastJsonLine,
  PLAIN_NODE,
  TEST_TIMEOUT_MS,
} from "./hosts.ts";

const LOOP_MS = 1_000;
const PINGS = 20;
const PING_EVERY_MS = LOOP_MS / PINGS;
const WORST_PING_BOUND_MS = 250;

const FairnessReport = z.object({
  loopMs: z.number(),
  loopStartMs: z.number(),
  spins: z.number(),
  worstPingMs: z.number(),
  latencies: z.array(z.number()).length(PINGS),
});

const options = { cwd: PROGRAMS, timeoutMs: CHILD_TIMEOUT_MS };

describe("fairness: what the compiler adds", () => {
  for (const host of BOUY_HOSTS) {
    const test = { timeout: TEST_TIMEOUT_MS, skip: !host.available };

    it(
      `answers a ping every ${PING_EVERY_MS} ms within ${WORST_PING_BOUND_MS} ms while another actor runs a ${LOOP_MS} ms loop on ${host.name}`,
      test,
      async () => {
        const exit = await launch(host, "fairness.ts", options);
        expect(exit.code, exit.stderr).toBe(0);
        const report = lastJsonLine(FairnessReport, exit);
        expect(report.loopMs).toBeGreaterThanOrEqual(LOOP_MS);
        expect(report.loopStartMs).toBeLessThan(PING_EVERY_MS);
        expect(report.worstPingMs).toBeLessThan(WORST_PING_BOUND_MS);
      },
    );
  }

  it(
    "holds the first ping for the whole loop under plain node, which runs the program without preemption points",
    { timeout: TEST_TIMEOUT_MS },
    async () => {
      const exit = await launch(PLAIN_NODE, "fairness.ts", options);
      expect(exit.code, exit.stderr).toBe(0);
      const report = lastJsonLine(FairnessReport, exit);
      expect(report.loopMs).toBeGreaterThanOrEqual(LOOP_MS);
      expect(report.latencies[0]).toBeGreaterThanOrEqual(report.loopMs);
    },
  );
});
