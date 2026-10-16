import { describe, expect, it } from "vitest";
import { diagnosticsIn, lineWith } from "./check.ts";

const uses: ReadonlyArray<readonly [string, string]> = [
  ["counter += 1", "Counter.increment writes the module-level binding counter."],
  ["return legacy", "Counter.label reads the module-level binding legacy."],
  ["queue.shift()", "Counter.next writes the module-level binding queue."],
  ["return settings.verbose", "Counter.verbose reads the module-level binding settings."],
  ["cache.set(key", "Counter.record writes the module-level binding cache."],
  ["registry.length", "Counter.shared reads the module-level binding registry."],
  ["sessions.get(", "Counter.append writes the module-level binding sessions."],
  ["return advance()", "Counter.step calls advance, which writes the module-level binding ticks."],
];

describe("BOUY103", () => {
  it.each(uses)("reports %s", async (text, message) => {
    expect(await diagnosticsIn("module-state.ts")).toContainEqual(
      expect.objectContaining({
        code: "BOUY103",
        severity: "error",
        line: lineWith("module-state.ts", text),
        message: expect.stringContaining(
          `${message} That binding is mutable state, and every actor in a thread shares module state`,
        ),
      }),
    );
  });

  it("reports each binding once per method", async () => {
    expect(await diagnosticsIn("module-state.ts")).toHaveLength(uses.length);
  });

  it("ignores constants that nothing mutates, typeof queries, and state in actor fields", async () => {
    const diagnostics = await diagnosticsIn("module-state.ts");
    expect(
      diagnostics.filter(
        (diagnostic) =>
          diagnostic.message.includes("Counter.local") ||
          diagnostic.message.includes("Counter.typed"),
      ),
    ).toEqual([]);
    expect(await diagnosticsIn("clean.ts")).toEqual([]);
  });
});
