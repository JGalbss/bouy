function makeAdder(n: number): (x: number) => number {
  return (x) => x + n;
}

function makeCounter(start: number) {
  const next = (current: number) => current + 1;
  return { start, next };
}

function compose<A, B, C>(f: (b: B) => C, g: (a: A) => B): (a: A) => C {
  return (a) => f(g(a));
}

function main(): void {
  const add5 = makeAdder(5);
  const add10 = makeAdder(10);
  console.log(add5(1), add10(1), makeAdder(-1)(1));
  const counter = makeCounter(3);
  let value = counter.start;
  value = counter.next(value);
  value = counter.next(value);
  console.log(value);
  const shout = compose(
    (s: string) => s + "!",
    (s: string) => s.toUpperCase(),
  );
  console.log(shout("hey"));
  const multipliers = [1, 2, 3].map((factor) => (x: number) => x * factor);
  console.log(multipliers.map((m) => m(10)).join(","));
  const prefix = "item-";
  const labels = ["a", "b"].map((name, index) => `${prefix}${index}:${name}`);
  console.log(labels.join(" "));
  function helper(x: number): number {
    return x * value;
  }
  console.log(helper(2));
  const fact = (n: number): number => (n <= 1 ? 1 : n * fact(n - 1));
  console.log(fact(10));
  const memo = new Map<number, number>();
  const cached = (n: number): number => {
    const hit = memo.get(n);
    return hit === undefined ? n * n : hit;
  };
  console.log(cached(7));
}

main();
