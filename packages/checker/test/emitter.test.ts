import { describe, expect, it } from "vitest";
import { diagnosticsIn, lineWith } from "./check.ts";

describe("BOUY107", () => {
  it("warns when actors share a module-level event emitter", async () => {
    const diagnostics = await diagnosticsIn("emitter.ts");
    expect(diagnostics.map(({ code, severity, line }) => ({ code, severity, line }))).toEqual([
      { code: "BOUY107", severity: "warning", line: lineWith("emitter.ts", 'bell.on("ring"') },
      { code: "BOUY107", severity: "warning", line: lineWith("emitter.ts", 'bell.emit("ring")') },
    ]);
    expect(diagnostics[0]?.message).toContain(
      "Listener.listen reads the module-level event emitter bell.",
    );
    expect(diagnostics[0]?.message).toContain(
      "Send events between actors as messages with cast().",
    );
  });
});
