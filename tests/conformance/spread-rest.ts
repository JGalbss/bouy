function joinAll(separator: string, ...items: (string | number)[]): string {
  return items.join(separator);
}

function main(): void {
  const first = [1, 2];
  const second = [3, 4];
  const combined = [0, ...first, ...second, 5];
  console.log(combined.join(","), combined.length);
  console.log(joinAll("-", ...first, "x", ...second));
  const base = { a: 1, b: 2 };
  const extended = { ...base, b: 20, c: 30 };
  const overridden = { b: 0, ...base };
  console.log(extended.a, extended.b, extended.c, overridden.b);
  const copy = { ...base };
  copy.a = 100;
  console.log(base.a, copy.a);
  const chars = [..."spread"];
  console.log(chars.length, chars[0], chars[chars.length - 1]);
  const set = new Set([3, 1, 3]);
  console.log([...set, ...new Set([9])].join(","));
  const nested = [[1], [2, 3]];
  const flat = ([] as number[]).concat(...nested);
  console.log(flat.join(","));
  console.log(Math.min(...combined), Math.max(...combined, 100));
}

main();
