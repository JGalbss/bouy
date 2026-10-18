export function earlyReturnInNestedLoops(grid: number[][], target: number): string {
  let visited = 0;
  for (let row = 0; row < grid.length; row++) {
    for (const cell of grid[row]) {
      visited++;
      if (cell === target) return `${row}:${visited}`;
    }
  }
  return `none:${visited}`;
}

export function breakInSwitchInLoop(words: string[]): number {
  let score = 0;
  for (const word of words) {
    switch (word) {
      case "skip":
        break;
      case "end":
        return score;
      default:
        if (word.length > 3) break;
        score += word.length;
    }
    score++;
  }
  return score;
}

export function continueWithUpdate(limit: number): number {
  let sum = 0;
  for (let i = 0, j = limit; i < j; i++, j--) {
    if (i % 2 === 0) continue;
    sum += i * j;
  }
  return sum;
}

export function tryCatchRebinds(inputs: string[]): string {
  let parsed = 0;
  let failed = 0;
  for (const input of inputs) {
    try {
      parsed += Number(JSON.parse(input));
    } catch {
      failed++;
    }
  }
  return `${parsed}/${failed}`;
}

export function shadowing(n: number): number {
  let x = n;
  {
    const x = 100;
    n += x;
  }
  for (let x = 0; x < 2; x++) {
    n += x;
  }
  return x + n;
}

export function closuresInLoop(bases: number[]): number[] {
  const fns: (() => number)[] = [];
  for (const base of bases) {
    const doubled = base * 2;
    fns.push(() => doubled + base);
  }
  return fns.map((f) => f());
}
