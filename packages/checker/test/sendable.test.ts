import { describe, expect, it } from "vitest";
import { diagnosticsIn, lineWith } from "./check.ts";

const COPY_RULE =
  "Every value that crosses an actor boundary is copied, so it must be plain data or an actor ref.";
const CONCRETE = "Give it a concrete Sendable type.";

const parameters: ReadonlyArray<readonly [string, string]> = [
  [
    "enqueue(task",
    `The parameter task of Worker.enqueue is not Sendable: the property run is a function. ${COPY_RULE}`,
  ],
  [
    "subscribe(listener",
    "The parameter listener of Worker.subscribe is not Sendable: it is a function.",
  ],
  ["store(items", "the value at [number] is an instance of the class Item"],
  [
    "accept(input",
    `The parameter input of Worker.accept is not Sendable: it has the type unknown, which the checker cannot verify. ${CONCRETE}`,
  ],
  ["tag(key", "it is a symbol"],
  ["wait(signal", "it is a promise"],
  ["fail(error", "it is an Error"],
  ["configure(options", "the property retry.onRetry is a function"],
  ["lookup(table", "the value at <value> is an instance of the class Item"],
  [
    "hold<T>(value",
    `it has the type T, which has no constraint, so the checker cannot verify it. ${CONCRETE}`,
  ],
  ["take(value", `it has the type {}, which the checker cannot verify. ${CONCRETE}`],
  ["shelve(items", "the value at [number] is an instance of the class Item"],
  ["descend(nest", "is nested more than 24 levels deep, which the checker cannot verify"],
  [
    "claim({",
    "The parameter at position 1 of Worker.claim is not Sendable: the property run is a function.",
  ],
  ['["schedule"](job', "The parameter job of Worker.schedule is not Sendable: it is a function."],
];

const results: ReadonlyArray<readonly [string, string]> = [
  ["callback()", "Worker.callback returns a value that is not Sendable: it is a function."],
  [
    "async item()",
    "Worker.item returns a value that is not Sendable: it is an instance of the class Item.",
  ],
  [
    "async *items()",
    "Worker.items yields a value that is not Sendable: it is an instance of the class Item.",
  ],
];

describe("BOUY101", () => {
  it.each(parameters)("reports the parameter in %s", async (text, message) => {
    expect(await diagnosticsIn("sendable.ts")).toContainEqual(
      expect.objectContaining({
        code: "BOUY101",
        severity: "error",
        line: lineWith("sendable.ts", text),
        message: expect.stringContaining(message),
      }),
    );
  });

  it("reports nothing else in the fixture", async () => {
    const diagnostics = await diagnosticsIn("sendable.ts");
    expect(diagnostics.filter((diagnostic) => diagnostic.code === "BOUY101")).toHaveLength(
      parameters.length,
    );
  });

  it("accepts Sendable parameters, refs, wrapped containers, and methods that are not public", async () => {
    expect(await diagnosticsIn("clean.ts")).toEqual([]);
  });
});

describe("BOUY102", () => {
  it.each(results)("reports the result of %s", async (text, message) => {
    expect(await diagnosticsIn("sendable.ts")).toContainEqual(
      expect.objectContaining({
        code: "BOUY102",
        severity: "error",
        line: lineWith("sendable.ts", text),
        message: expect.stringContaining(message),
      }),
    );
  });

  it("unwraps promises and checks the yields of async generators", async () => {
    const diagnostics = await diagnosticsIn("sendable.ts");
    expect(diagnostics.filter((diagnostic) => diagnostic.code === "BOUY102")).toHaveLength(
      results.length,
    );
    expect(diagnostics).toHaveLength(parameters.length + results.length);
  });
});
