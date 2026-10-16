type Reducer<T> = (acc: T, item: number) => T;

function applyTwice(f: (x: number) => number, x: number): number {
  return f(f(x));
}

function pipeline(...fns: ((x: number) => number)[]): (x: number) => number {
  return (x) => fns.reduce((acc, fn) => fn(acc), x);
}

function curry(a: number) {
  return (b: number) => (c: number) => a * 100 + b * 10 + c;
}

function fold<T>(xs: number[], reducer: Reducer<T>, initial: T): T {
  let acc = initial;
  for (const x of xs) {
    acc = reducer(acc, x);
  }
  return acc;
}

function main(): void {
  console.log(applyTwice((x) => x * 3, 2));
  const transform = pipeline(
    (x) => x + 1,
    (x) => x * 2,
    (x) => x - 3,
  );
  console.log(transform(5), transform(0));
  console.log(curry(1)(2)(3));
  console.log(fold([1, 2, 3, 4], (acc, x) => acc + x, 0));
  console.log(fold([1, 2, 3], (acc: string, x) => acc + x, ">"));
  const byParity = fold(
    [1, 2, 3, 4, 5],
    (acc: { even: number; odd: number }, x) =>
      x % 2 === 0 ? { ...acc, even: acc.even + x } : { ...acc, odd: acc.odd + x },
    { even: 0, odd: 0 },
  );
  console.log(byParity.even, byParity.odd);
  const sorted = ["bb", "a", "ccc"].sort((a, b) => b.length - a.length);
  console.log(sorted.join(","));
  const counts = [3, 1, 2].map(String);
  console.log(
    counts.join("+"),
    ["1", "2"].map(Number).reduce((a, b) => a + b, 0),
  );
  console.log([0, 1, "", "x", null].filter(Boolean).length);
  [10, 20].forEach((value, index) => console.log(index, value));
}

main();
