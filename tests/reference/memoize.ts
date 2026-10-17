// A memoizing cache held in a closure.
function memoize(f: (n: number) => number): (n: number) => number {
  const cache = new Map<number, number>();
  let misses = 0;
  const memo = (n: number): number => {
    const hit = cache.get(n);
    if (hit !== undefined) return hit;
    misses++;
    const value = f(n);
    cache.set(n, value);
    return value;
  };
  (memo as unknown as { misses: () => number }).misses = () => misses;
  return memo;
}

const fib: (n: number) => number = memoize((n) => (n < 2 ? n : fib(n - 1) + fib(n - 2)));
console.log(fib(30), fib(50));
console.log((fib as unknown as { misses: () => number }).misses());
