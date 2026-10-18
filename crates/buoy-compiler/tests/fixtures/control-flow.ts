export function earlyReturns(n: number): string {
  if (n < 0) return "negative";
  if (n === 0) {
    return "zero";
  }
  let label = "small";
  if (n > 10) {
    label = "large";
  } else if (n > 5) {
    label = "medium";
  }
  return label;
}

export function dispatch(command: string): number {
  switch (command) {
    case "one":
      return 1;
    case "two":
    case "deux":
      return 2;
    default:
      return 0;
  }
}

export function switchWithBreaks(n: number, key: string): number {
  let total = 0;
  switch (n) {
    case 1:
      total = 10;
      break;
    case 2:
      if (key === "skip") break;
      total = 20;
      break;
  }
  switch (key) {
    case key.toUpperCase():
      total += 1;
      break;
    default:
      total += 2;
  }
  return total;
}

export function loops(xs: number[]): number {
  let sum = 0;
  for (let i = 0; i < xs.length; i++) {
    if (xs[i] < 0) continue;
    if (xs[i] > 100) break;
    sum += xs[i];
  }
  let k = 0;
  while (k < 3) k++;
  do {
    k--;
  } while (k > 1);
  for (const x of xs) sum += x;
  for (const key in { a: 1 }) sum += key.length;
  return sum + k;
}

export function nestedReturn(grid: number[][]): string {
  for (const row of grid) {
    for (const cell of row) {
      if (cell === 0) return "found";
    }
  }
  return "missing";
}

export function switchInLoop(items: string[]): number {
  let count = 0;
  for (const item of items) {
    switch (item) {
      case "skip":
        continue;
      case "stop":
        return -count;
      default:
        count++;
    }
  }
  return count;
}
