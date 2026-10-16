import { describe, expect, it } from "vitest";
import { diagnosticsIn, lineWith } from "./check.ts";

describe("BOUY105", () => {
  it.each([
    ["Deferred", "then(value"],
    ["Computed", '["then"](value'],
    ["Overloaded", "then(value: string): string;"],
  ])("reports %s once, at its first then declaration", async (actor, text) => {
    const diagnostics = await diagnosticsIn("then.ts");
    expect(diagnostics.filter((diagnostic) => diagnostic.message.startsWith(`${actor} `))).toEqual([
      expect.objectContaining({
        code: "BOUY105",
        severity: "error",
        line: lineWith("then.ts", text),
        message: expect.stringContaining(`${actor} has a method named then`),
      }),
    ]);
  });

  it("ignores private names, static methods, accessors, and names that only start with then", async () => {
    const diagnostics = await diagnosticsIn("then.ts");
    expect(diagnostics.filter((diagnostic) => diagnostic.message.includes("Settled"))).toEqual([]);
    expect(diagnostics).toHaveLength(3);
  });
});
