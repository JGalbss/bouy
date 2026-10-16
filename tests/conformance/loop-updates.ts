function pairs(n: number): string {
  const out: string[] = [];
  for (let i = 0, j = n; i < j; i++, j--) {
    if ((i + j) % 2 === 0) continue;
    out.push(`${i}-${j}`);
  }
  return out.join(" ");
}

function skipMultiples(limit: number, k: number): number {
  let sum = 0;
  for (let i = 1; i <= limit; i += 1) {
    if (i % k === 0) {
      continue;
    }
    sum += i;
  }
  return sum;
}

function countDown(): string {
  const out: number[] = [];
  let i = 10;
  for (; i > 0; i -= 3) {
    out.push(i);
  }
  return `${out.join(",")} ends at ${i}`;
}

function infiniteWithBreak(): number {
  let steps = 0;
  for (;;) {
    steps++;
    if (steps * steps > 50) break;
  }
  return steps;
}

function nestedContinue(): string {
  const out: string[] = [];
  for (let i = 0; i < 3; i++) {
    for (let j = 0; j < 3; j++) {
      if (j === i) continue;
      if (j > i + 1) break;
      out.push(`${i}${j}`);
    }
  }
  return out.join(",");
}

function main(): void {
  console.log(pairs(9));
  console.log(skipMultiples(20, 3));
  console.log(countDown());
  console.log(infiniteWithBreak());
  console.log(nestedContinue());
}

main();
