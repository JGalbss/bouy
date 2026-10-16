import { describe, expect, it } from "vitest";
import { diagnosticsIn, lineWith } from "./check.ts";

const dropped: ReadonlyArray<string> = [
  "    this.save();",
  "this.save().then(",
  "      this.save();",
  "items.map(async",
  "await [this.save(",
  "this.save() as unknown",
];

const passed: ReadonlyArray<string> = ["items.forEach((item)", "setTimeout("];

describe("BOUY104", () => {
  it.each(dropped)("reports the floating promise at %s", async (text) => {
    expect(await diagnosticsIn("floating.ts")).toContainEqual(
      expect.objectContaining({
        code: "BOUY104",
        severity: "warning",
        line: lineWith("floating.ts", text),
        message: expect.stringContaining(
          "starts a promise that it does not await. The work can outlive the turn and interleave with the next message.",
        ),
      }),
    );
  });

  it.each(passed)("reports the promise returned into a void callback at %s", async (text) => {
    expect(await diagnosticsIn("floating.ts")).toContainEqual(
      expect.objectContaining({
        code: "BOUY104",
        severity: "warning",
        line: lineWith("floating.ts", text),
        message: expect.stringContaining(
          "Writer.concise passes a function that returns a promise to a caller that ignores the result.",
        ),
      }),
    );
  });

  it("accepts promises that are awaited, returned, assigned, or discarded with void", async () => {
    expect(await diagnosticsIn("floating.ts")).toHaveLength(dropped.length + passed.length);
    expect(await diagnosticsIn("clean.ts")).toEqual([]);
  });
});
