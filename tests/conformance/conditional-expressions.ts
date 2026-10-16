function classify(n: number): string {
  return n < 0 ? "negative" : n === 0 ? "zero" : n < 10 ? "small" : "large";
}

function lazyDefault(cache: Map<string, number>, key: string): number {
  let value = cache.get(key);
  value = value ?? (value = key.length * 100);
  return value;
}

function counters(xs: number[]): string {
  let evens = 0;
  let odds = 0;
  for (const x of xs) {
    x % 2 === 0 ? evens++ : odds++;
  }
  const log: string[] = [];
  evens > odds && log.push("more evens");
  odds > evens || log.push("not more odds");
  return `${evens}/${odds} ${log.join(";")}`;
}

function pick(flag: boolean): string {
  let chosen = "none";
  const result = flag ? (chosen = "yes") : (chosen = "no");
  return `${result} ${chosen}`;
}

function main(): void {
  console.log([-5, 0, 3, 42].map(classify).join(","));
  console.log(lazyDefault(new Map([["a", 1]]), "a"), lazyDefault(new Map(), "abc"));
  console.log(counters([1, 2, 4, 6, 7]), "|", counters([1, 3]));
  console.log(pick(true), "|", pick(false));
  const x = 5;
  const parity = x % 2 ? "odd" : "even";
  const sign = x > 0 ? (x > 100 ? "big" : "positive") : "non-positive";
  console.log(parity, sign);
}

main();
