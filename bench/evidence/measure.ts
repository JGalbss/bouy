export const nanosecondsSince = (start: bigint): number => Number(process.hrtime.bigint() - start);

export const median = (values: ReadonlyArray<number>): number => {
  const sorted = values.toSorted((left, right) => left - right);
  const lower = sorted[Math.floor((sorted.length - 1) / 2)] ?? Number.NaN;
  const upper = sorted[Math.ceil((sorted.length - 1) / 2)] ?? Number.NaN;
  return (lower + upper) / 2;
};

export const percentile = (values: ReadonlyArray<number>, fraction: number): number => {
  const sorted = values.toSorted((left, right) => left - right);
  return sorted[Math.max(0, Math.ceil(fraction * sorted.length) - 1)] ?? Number.NaN;
};

export const repeatInSequence = (count: number, step: () => Promise<void>): Promise<void> =>
  new Promise((resolve, reject) => {
    let remaining = count;
    const takeStep = (): void => {
      if (remaining <= 0) {
        resolve();
        return;
      }
      remaining -= 1;
      step().then(takeStep, reject);
    };
    takeStep();
  });
