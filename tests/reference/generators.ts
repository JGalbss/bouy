// A sync generator: lazy values, two-way next(), return, and early exit.
function* naturals(): Generator<number> {
  let n = 0;
  while (true) {
    yield n++;
  }
}

function* take<T>(source: Iterable<T>, count: number): Generator<T> {
  let i = 0;
  for (const item of source) {
    if (i++ >= count) return;
    yield item;
  }
}

console.log([...take(naturals(), 5)]);

function* accumulator(): Generator<number, string, number> {
  let total = 0;
  while (total < 10) {
    const next = yield total;
    total += next;
  }
  return `done at ${total}`;
}
const acc = accumulator();
console.log(acc.next(0).value, acc.next(3).value, acc.next(4).value, acc.next(5));
console.log(acc.next(1));

function* fib(): Generator<number> {
  let [a, b] = [0, 1];
  for (;;) {
    yield a;
    [a, b] = [b, a + b];
  }
}
const f = fib();
const firsts: number[] = [];
for (let i = 0; i < 10; i++) firsts.push(f.next().value);
console.log(firsts.join(","));
