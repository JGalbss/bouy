// Map and Set iteration sees the entries that a loop adds and skips the ones
// it deletes; the Set methods and Map.groupBy.
const m = new Map([
  ["a", 1],
  ["b", 2],
  ["c", 3],
]);
const seen: string[] = [];
for (const [key, value] of m) {
  seen.push(key + value);
  if (key === "a") {
    m.delete("b");
    m.set("d", 4);
  }
}
console.log(seen.join(" "), m.size);
const s = new Set([1, 2, 3]);
s.forEach((v) => {
  if (v < 3) s.add(v + 10);
});
console.log([...s].join(" "));
const it = s.values();
it.next();
s.clear();
s.add(99);
console.log(it.next(), it.next());
const evens = new Set([2, 4, 6, 8]);
const small = new Set([1, 2, 3, 4]);
console.log(
  [...evens.union(small)],
  [...evens.intersection(small)],
  [...evens.difference(small)],
  [...evens.symmetricDifference(small)],
);
console.log(
  small.isSubsetOf(new Set([1, 2, 3, 4, 5])),
  evens.isSupersetOf(new Set([2, 4])),
  evens.isDisjointFrom(new Set([1, 3])),
);
const groups = Map.groupBy([1, 2, 3, 4, 5], (x) => (x % 2 ? "odd" : "even"));
console.log(groups.get("odd"), groups.get("even"), new Map([[-0, "zero"]]).get(0));
const wm = new WeakMap<object, number>();
const key = {};
wm.set(key, 1);
console.log(wm.get(key), wm.has({}), Object.prototype.toString.call(wm));
// Deletes that leave most of the entries dead while an iterator is between
// steps: the iterator goes on after the last key that it gave.
const big = new Map<number, number>();
for (let i = 0; i < 1000; i++) big.set(i, i * 2);
const bigIt = big.entries();
const firstTwo = [bigIt.next().value, bigIt.next().value];
for (let i = 0; i < 990; i++) big.delete(i);
big.set(5, 55);
big.set(1001, 1);
console.log(firstTwo, [...bigIt], big.size, [...big.keys()]);
// A queue that deletes its oldest key and reads the next one.
const queue = new Set<number>();
for (let i = 0; i < 100; i++) queue.add(i);
let drained = 0;
while (queue.size > 0) {
  const oldest = queue.values().next().value as number;
  queue.delete(oldest);
  if (oldest < 50) queue.add(oldest + 1000);
  drained += oldest;
}
console.log(drained, queue.size);
// A worklist that adds while it iterates, and forEach that deletes ahead.
const work = new Set<number>([1]);
for (const n of work) if (n < 2000) work.add(n * 2).add(n * 2 + 1);
let sum = 0;
for (const n of work) sum += n;
console.log(work.size, sum);
const ahead = new Map<number, string>();
for (let i = 0; i < 200; i++) ahead.set(i, `v${i}`);
const visited: number[] = [];
ahead.forEach((_, k) => {
  visited.push(k);
  for (let j = k + 1; j < k + 10; j++) ahead.delete(j);
  if (k === 190) ahead.set(500, "late");
});
console.log(visited.join(","), ahead.size);
// A key deleted and set again moves to the end, and a clone keeps the order.
const moved = new Map([
  ["x", 1],
  ["y", 2],
  ["z", 3],
]);
const movedIt = moved.keys();
console.log(movedIt.next().value);
moved.delete("y");
moved.set("y", 4);
console.log([...movedIt], [...moved]);
const cloned = structuredClone(moved);
cloned.set("w", 0);
cloned.delete("x");
console.log([...cloned], cloned.get("y"), [...moved.entries()].length);
