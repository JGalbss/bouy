// Atomics.waitAsync and Atomics.notify in one realm. Notify wakes the waiters of one
// index in the order they waited, up to its count, and returns how many it woke. A
// waiter that nobody wakes before its timeout times out, and a pending wait does not
// keep the program alive.
const ta = new Int32Array(new SharedArrayBuffer(16));
const results: string[] = [];
const record = (name: string) => (value: string) => results.push(`${name} ${value}`);
let timeout = "pending";

const first = Atomics.waitAsync(ta, 0, 0);
first.value.then(record("first"));
Atomics.waitAsync(ta, 0, 0, 5000).value.then(record("second"));
Atomics.waitAsync(ta, 0, 0).value.then(record("third"));
Atomics.waitAsync(ta, 1, 0, 10).value.then((value) => (timeout = value));
Atomics.waitAsync(ta, 2, 0).value.then(record("never"));

console.log(first.async, first.value instanceof Promise);
console.log(Atomics.waitAsync(ta, 0, 1), Atomics.waitAsync(ta, 0, 0, 0));
console.log(Atomics.wait(ta, 3, 1), Atomics.wait(ta, 3, 0, 5));
console.log(Atomics.notify(ta, 0, 2), Atomics.notify(ta, 3), Atomics.notify(new Int32Array(4), 0));

setTimeout(() => {
  console.log(results, timeout);
  console.log(Atomics.notify(ta, 0), Atomics.notify(ta, 0));
  setTimeout(() => console.log(results), 50);
}, 100);
