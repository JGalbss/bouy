import { median, nanosecondsSince } from "./measure.ts";
import { countYields, spendReduction } from "./reductions.ts";

const ITERATIONS = 100_000_000;
const WARMUP_ITERATIONS = 1_000_000;
const TRIALS = 5;
const BUDGET = 4_000;
const SLICE = 1_024;

let budget = BUDGET;
let yields = 0;

const variants = [
  {
    name: "noCheck",
    sum: (count: number): number => {
      let total = 0;
      for (let index = 0; index < count; index += 1) total = (total + index) | 0;
      return total;
    },
  },
  {
    name: "moduleCounter",
    sum: (count: number): number => {
      let total = 0;
      for (let index = 0; index < count; index += 1) {
        total = (total + index) | 0;
        budget -= 1;
        if (budget === 0) {
          budget = BUDGET;
          yields += 1;
        }
      }
      return total;
    },
  },
  {
    name: "importedCall",
    sum: (count: number): number => {
      let total = 0;
      for (let index = 0; index < count; index += 1) {
        total = (total + index) | 0;
        spendReduction();
      }
      return total;
    },
  },
  {
    name: "localSliceEvery1024",
    sum: (count: number): number => {
      let total = 0;
      let slice = SLICE;
      for (let index = 0; index < count; index += 1) {
        total = (total + index) | 0;
        slice -= 1;
        if (slice === 0) {
          slice = SLICE;
          budget -= SLICE;
          if (budget <= 0) {
            budget += BUDGET;
            yields += 1;
          }
        }
      }
      return total;
    },
  },
  {
    name: "indexMaskEvery1024",
    sum: (count: number): number => {
      let total = 0;
      for (let index = 0; index < count; index += 1) {
        total = (total + index) | 0;
        if ((index & (SLICE - 1)) === 0) {
          budget -= SLICE;
          if (budget <= 0) {
            budget += BUDGET;
            yields += 1;
          }
        }
      }
      return total;
    },
  },
] as const;

let checksum = 0;
variants.forEach((variant) => {
  checksum ^= variant.sum(WARMUP_ITERATIONS);
});

const trials = Array.from({ length: TRIALS }, () =>
  variants.map((variant) => {
    const start = process.hrtime.bigint();
    checksum ^= variant.sum(ITERATIONS);
    return nanosecondsSince(start) / 1e6;
  }),
);

const milliseconds = variants.map((_, index) => median(trials.map((trial) => trial[index] ?? 0)));
const baseline = milliseconds[0] ?? 0;

console.log(
  JSON.stringify({
    iterations: ITERATIONS,
    trials: TRIALS,
    ...Object.fromEntries(
      variants.flatMap((variant, index) => {
        const elapsed = milliseconds[index] ?? 0;
        return [
          [`${variant.name}.ms`, elapsed],
          [`${variant.name}.nsPerIteration`, (elapsed * 1e6) / ITERATIONS],
          [`${variant.name}.overheadPercent`, ((elapsed - baseline) / baseline) * 100],
        ];
      }),
    ),
    moduleYields: yields,
    importedYields: countYields(),
    checksum,
    involuntaryContextSwitches: process.resourceUsage().involuntaryContextSwitches,
  }),
);
