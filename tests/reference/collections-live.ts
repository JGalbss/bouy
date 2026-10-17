// Map and Set iteration sees the entries that a loop adds and skips the ones
// it deletes; the Set methods and Map.groupBy.
const m = new Map([["a", 1], ["b", 2], ["c", 3]]);
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
console.log([...evens.union(small)], [...evens.intersection(small)], [...evens.difference(small)], [...evens.symmetricDifference(small)]);
console.log(small.isSubsetOf(new Set([1, 2, 3, 4, 5])), evens.isSupersetOf(new Set([2, 4])), evens.isDisjointFrom(new Set([1, 3])));
const groups = Map.groupBy([1, 2, 3, 4, 5], (x) => (x % 2 ? "odd" : "even"));
console.log(groups.get("odd"), groups.get("even"), new Map([[-0, "zero"]]).get(0));
const wm = new WeakMap<object, number>();
const key = {};
wm.set(key, 1);
console.log(wm.get(key), wm.has({}), Object.prototype.toString.call(wm));
