// Array destructuring through the iterator protocol: it closes an iterator that it did not
// exhaust, and it follows a replaced Array.prototype[Symbol.iterator].
let closed = 0;
const endless = {
  [Symbol.iterator]() {
    return {
      next: () => ({ value: 1, done: false }),
      return: () => {
        closed += 1;
        return {};
      },
    };
  },
};
const [first] = endless as unknown as number[];
console.log(first, closed);
let rest: number[] = [];
[, ...rest] = [1, 2, 3];
console.log(rest, closed);

const original = Array.prototype[Symbol.iterator];
Array.prototype[Symbol.iterator] = function* () {
  yield 42;
} as unknown as typeof original;
const [replaced] = [3];
console.log(replaced, [...[1, 2]]);
Array.prototype[Symbol.iterator] = original;
const [a, b] = [1, 2, 3];
console.log(a, b);
