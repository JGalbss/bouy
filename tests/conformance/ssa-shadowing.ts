function shadow(): string {
  const parts: string[] = [];
  let x = 1;
  {
    let x = 2;
    x += 10;
    parts.push(`inner ${x}`);
  }
  parts.push(`outer ${x}`);
  for (let x = 0; x < 2; x++) {
    parts.push(`loop ${x}`);
  }
  if (x === 1) {
    const x = "shadowed";
    parts.push(x);
  }
  x *= 7;
  parts.push(`final ${x}`);
  return parts.join(", ");
}

function branches(flag: boolean, n: number): string {
  let a = 0;
  let b = 0;
  let c = "unset";
  if (flag) {
    a = n;
    if (n > 5) {
      b = n * 2;
      c = "big";
    } else {
      c = "small";
    }
  } else {
    b = -1;
  }
  return `${a} ${b} ${c}`;
}

function closuresInLoop(): string {
  const fns: (() => number)[] = [];
  for (const base of [1, 2, 3]) {
    const scaled = base * 10;
    fns.push(() => scaled + base);
  }
  return fns.map((f) => f()).join(",");
}

function reassignInsideConditionals(values: number[]): string {
  let min = Infinity;
  let max = -Infinity;
  let sum = 0;
  for (const v of values) {
    if (v < min) min = v;
    if (v > max) max = v;
    sum += v;
  }
  const average = values.length === 0 ? 0 : sum / values.length;
  return `${min} ${max} ${average}`;
}

function main(): void {
  console.log(shadow());
  console.log(branches(true, 9), "|", branches(true, 2), "|", branches(false, 9));
  console.log(closuresInLoop());
  console.log(reassignInsideConditionals([4, 8, 15, 16, 23, 42]));
  console.log(reassignInsideConditionals([]));
}

main();
