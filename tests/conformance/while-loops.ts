function collatz(start: number): number {
  let n = start;
  let steps = 0;
  while (n !== 1) {
    n = n % 2 === 0 ? n / 2 : 3 * n + 1;
    steps++;
  }
  return steps;
}

function digits(n: number): number[] {
  const result: number[] = [];
  let rest = n;
  do {
    result.unshift(rest % 10);
    rest = Math.floor(rest / 10);
  } while (rest > 0);
  return result;
}

function firstPowerAbove(limit: number): number {
  let value = 1;
  while (true) {
    value *= 2;
    if (value > limit) break;
  }
  return value;
}

function sumUntilNegative(xs: number[]): number {
  let i = 0;
  let sum = 0;
  while (i < xs.length) {
    const x = xs[i];
    i++;
    if (x === 0) continue;
    if (x < 0) return sum;
    sum += x;
  }
  return sum;
}

function main(): void {
  console.log(collatz(6), collatz(27));
  console.log(digits(9042).join(","), digits(0).join(","));
  console.log(firstPowerAbove(1000));
  console.log(sumUntilNegative([1, 0, 2, 3, -1, 100]), sumUntilNegative([4, 5]));
  let count = 0;
  do {
    count++;
  } while (count < 0);
  console.log(count);
}

main();
