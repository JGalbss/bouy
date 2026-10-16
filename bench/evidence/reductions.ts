const BUDGET = 4_000;

let remaining = BUDGET;
let yields = 0;

export const spendReduction = (): void => {
  remaining -= 1;
  if (remaining > 0) return;
  remaining = BUDGET;
  yields += 1;
};

export const countYields = (): number => yields;
