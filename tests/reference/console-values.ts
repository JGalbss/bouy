// How console.log prints the iterators of Map, Set, arrays, and strings, a
// DataView, dates, primitive wrappers, and weak collections, as Node does.
console.log(
  new Map([[1, 2]]).entries(),
  new Set([1, 2]).values(),
  [1, 2].values(),
  "ab"[Symbol.iterator](),
);
console.log(
  new DataView(new ArrayBuffer(2)),
  [new Date(0)],
  { d: new Date(NaN) },
  Object(Symbol("s")),
  [1n, Object(2n)],
);
console.log(new Map([[{ a: 1 }, new Set(["x"])]]), new WeakMap(), [undefined, null, -0, 0.1], {
  s: "it's",
});
