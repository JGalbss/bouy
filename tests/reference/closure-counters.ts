// Closures share and mutate the variables they capture.
function makeCounter() {
  let count = 0;
  return {
    inc: () => ++count,
    dec: () => --count,
    get: () => count,
  };
}
const c1 = makeCounter();
const c2 = makeCounter();
c1.inc();
c1.inc();
c2.dec();
console.log(c1.get(), c2.get());

let total = 0;
const add = (n: number) => {
  total += n;
};
[1, 2, 3, 4].forEach(add);
console.log(total);

let calls = 0;
function counted<T extends unknown[], R>(f: (...args: T) => R) {
  return (...args: T): R => {
    calls++;
    return f(...args);
  };
}
const double = counted((x: number) => x * 2);
console.log(double(2), double(5), calls);
