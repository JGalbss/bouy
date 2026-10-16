import { describe, expect, it } from "vitest";
import { diagnosticsIn, lineWith } from "./check.ts";

describe("actor discovery", () => {
  it("follows import aliases, value aliases, child, pool, re-exports, and instantiation expressions", async () => {
    const methods = (await diagnosticsIn("aliases.ts"))
      .map((diagnostic) => / of (\S+) is not Sendable/u.exec(diagnostic.message)?.[1] ?? "")
      .toSorted();
    expect(methods).toEqual([
      "Assigned.run",
      "Box.put",
      "Crate.put",
      "Destructured.run",
      "Exported.run",
      "Expression.run",
      "Indexed.run",
      "Namespaced.run",
      "Pooled.run",
      "Renamed.run",
      "Supervised.run",
    ]);
  });

  it("ignores a spawn function that does not come from bouy", async () => {
    const diagnostics = await diagnosticsIn("aliases.ts");
    expect(diagnostics.filter((diagnostic) => diagnostic.message.includes("Ignored"))).toEqual([]);
  });

  it("checks inherited methods with the type arguments of the subclass and skips overridden methods", async () => {
    expect(await diagnosticsIn("inheritance.ts")).toEqual([
      expect.objectContaining({
        code: "BOUY101",
        line: lineWith("inheritance.ts", "add(item: T)"),
        message: expect.stringContaining(
          "The parameter item of Callbacks.add is not Sendable: it is a function.",
        ),
      }),
      expect.objectContaining({
        code: "BOUY101",
        line: lineWith("inheritance.ts", "inherited(callback"),
        message: expect.stringContaining("The parameter callback of Overrides.inherited"),
      }),
    ]);
  });
});
