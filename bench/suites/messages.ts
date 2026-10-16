import { deepStrictEqual, notStrictEqual } from "node:assert/strict";
import type { Sendable } from "bouy";
import { copyValue } from "../../packages/bouy/src/runtime/Sendable.ts";
import { median, nanosecondsSince } from "../evidence/measure.ts";
import { report } from "../suite.ts";

const TRIALS = 5;

const createMessage = (index: number) => ({
  id: index,
  kind: "tool-call",
  priority: index % 5,
  sentAt: 1_760_000_000_000 + index,
  urgent: index % 2 === 0,
});

const payloads = {
  small: { value: createMessage(0), copies: 50_000 },
  medium: { value: Array.from({ length: 100 }, (_, index) => createMessage(index)), copies: 1_000 },
  large: { value: Array.from({ length: 10_000 }, (_, index) => createMessage(index)), copies: 10 },
};

const nanosecondsPerCopy = (
  value: Sendable,
  copies: number,
  copy: (value: Sendable) => Sendable,
): number => {
  const twin = copy(value);
  deepStrictEqual(twin, value);
  notStrictEqual(twin, value);
  const trials = Array.from({ length: TRIALS }, () => {
    const start = process.hrtime.bigint();
    for (let round = 0; round < copies; round += 1) copy(value);
    return nanosecondsSince(start) / copies;
  });
  return median(trials);
};

report(
  Object.fromEntries(
    Object.entries(payloads).map(([size, { value, copies }]) => [
      size,
      {
        jsonBytes: JSON.stringify(value).length,
        schemaCopyNs: nanosecondsPerCopy(value, copies, copyValue),
        structuredCloneNs: nanosecondsPerCopy(value, copies, (input) => structuredClone(input)),
      },
    ]),
  ),
);
