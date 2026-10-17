// Each iteration of a for (let ...) loop has its own binding for closures.
const fns: (() => number)[] = [];
for (let i = 0; i < 3; i++) {
  fns.push(() => i * 10);
}
console.log(fns.map((f) => f()));

const shared: (() => number)[] = [];
let k = 0;
for (; k < 3; k++) {
  shared.push(() => k);
}
console.log(shared.map((f) => f()));

const counters = [1, 2, 3].map((start) => {
  let n = start;
  return () => (n += start);
});
counters[0]();
counters[0]();
counters[2]();
console.log(counters.map((c) => c()));

const handlers: Record<string, () => string> = {};
for (const name of ["x", "y"]) {
  let hits = 0;
  handlers[name] = () => `${name}${++hits}`;
}
handlers.x();
console.log(handlers.x(), handlers.y());

// The first per-iteration copy comes before the first test: a closure of the initializer
// keeps the initial value, and a closure of the test sees its own iteration.
const fromInit: (() => number)[] = [];
const fromTest: (() => number)[] = [];
for (let i = 0, first = () => i; fromTest.push(() => i), i < 3; i++) {
  fromInit.push(first);
}
console.log(
  fromInit.map((f) => f()),
  fromTest.map((f) => f()),
);
