import { deepStrictEqual } from "node:assert/strict";
import { median, nanosecondsSince } from "./measure.ts";

const TRIALS = 5;

type Plain = string | number | boolean | null | Array<Plain> | { [key: string]: Plain };

const copyPlain = (value: Plain): Plain => {
  if (Array.isArray(value)) return value.map(copyPlain);
  if (!(value instanceof Object)) return value;
  const copy: { [key: string]: Plain } = {};
  for (const key of Object.keys(value)) copy[key] = copyPlain(value[key] ?? null);
  return copy;
};

const createMessage = (index: number): Plain => ({
  id: index,
  kind: "tool-call",
  priority: index % 5,
  sentAt: 1_760_000_000_000 + index,
  urgent: index % 2 === 0,
});

const payloads = [
  { name: "small", value: createMessage(0), iterations: 200_000 },
  {
    name: "medium",
    value: Array.from({ length: 100 }, (_, index) => createMessage(index)),
    iterations: 5_000,
  },
  {
    name: "large",
    value: Array.from({ length: 10_000 }, (_, index) => createMessage(index)),
    iterations: 50,
  },
] as const;

const methods = [
  { name: "structuredClone", copy: (value: Plain): Plain => structuredClone(value) },
  { name: "jsonRoundTrip", copy: (value: Plain): Plain => JSON.parse(JSON.stringify(value)) },
  { name: "recursiveCopy", copy: copyPlain },
] as const;

let sink: Plain = null;

const result = Object.fromEntries(
  payloads.flatMap((payload) =>
    methods.map((method) => {
      deepStrictEqual(method.copy(payload.value), payload.value);
      const trials = Array.from({ length: TRIALS }, () => {
        const start = process.hrtime.bigint();
        for (let iteration = 0; iteration < payload.iterations; iteration += 1) {
          sink = method.copy(payload.value);
        }
        return nanosecondsSince(start) / payload.iterations;
      });
      return [`${payload.name}.${method.name}Ns`, median(trials)];
    }),
  ),
);

console.log(
  JSON.stringify({
    ...result,
    ...Object.fromEntries(
      payloads.map((payload) => [
        `${payload.name}.jsonBytes`,
        JSON.stringify(payload.value).length,
      ]),
    ),
    sinkJsonBytes: JSON.stringify(sink).length,
    involuntaryContextSwitches: process.resourceUsage().involuntaryContextSwitches,
  }),
);
