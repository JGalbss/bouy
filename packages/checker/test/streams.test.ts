import { describe, expect, it } from "vitest";
import { diagnosticsIn, lineWith } from "./check.ts";

describe("BOUY106", () => {
  it.each([
    ["async list()", "Feed.list"],
    ["direct()", "Feed.direct"],
  ])("reports %s as an error and suggests an async generator method", async (text, method) => {
    const diagnostics = await diagnosticsIn("streams.ts");
    const line = lineWith("streams.ts", text);
    expect(diagnostics).toContainEqual(
      expect.objectContaining({
        code: "BOUY106",
        severity: "warning",
        line,
        message: expect.stringContaining(`${method} returns an async iterable`),
      }),
    );
    expect(diagnostics).toContainEqual(
      expect.objectContaining({
        code: "BOUY102",
        severity: "error",
        line,
        message: expect.stringContaining(
          `${method} returns a value that is not Sendable: it is an async iterable.`,
        ),
      }),
    );
  });

  it("accepts async generator methods, their overloads, and abstract declarations they implement", async () => {
    expect(await diagnosticsIn("streams.ts")).toHaveLength(4);
  });
});
