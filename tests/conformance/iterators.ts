// keys(), values(), and entries() return iterators: next() reads and
// advances them, for...of and spreads walk what is left, and the iterator
// helpers map and filter them.

function firstKey<K, V>(cache: Map<K, V>): K | undefined {
  return cache.keys().next().value;
}

function main(): void {
  const cache = new Map([
    ["a", 1],
    ["b", 2],
    ["c", 3],
  ]);
  console.log("LRU eviction:", firstKey(cache), cache.keys().next().done);
  console.log(
    "not arrays:",
    Array.isArray(cache.keys()),
    (cache.keys() as any).length,
    typeof cache.values(),
  );
  console.log(cache.keys(), cache.values(), cache.entries());
  console.log(new Set(["x", "y"]).values(), new Set(["x"]).entries(), new Map().keys());
  console.log([1, 2].keys(), [1, 2].entries(), String(cache.keys()));

  const it = cache.values();
  const first = it.next();
  const second = it.next();
  console.log(
    "next advances:",
    first.value,
    first.done,
    second.value,
    it.next().value,
    it.next().done,
    it.next().value,
  );
  const rest = cache.keys();
  rest.next();
  console.log("rest after next:", rest);
  console.log("spread of the rest:", [...rest]);

  const walked: string[] = [];
  const entries = cache.entries();
  let step = entries.next();
  while (!step.done) {
    walked.push(`${step.value[0]}=${step.value[1]}`);
    step = entries.next();
  }
  console.log("manual loop:", walked.join(" "));

  for (const [i, x] of ["p", "q"].entries()) console.log("entries:", i, x);
  console.log("spread:", [...cache.keys()], Array.from(cache.values()), new Set(cache.keys()).size);
  console.log(
    "helpers:",
    cache
      .keys()
      .map((k) => k + "!")
      .toArray(),
    [...cache.values().filter((v) => v > 1)],
  );
  console.log(
    "helper values:",
    cache.values().reduce((a, b) => a + b),
    cache.values().some((v) => v > 2),
    cache.keys().find((k) => k > "a"),
  );
  console.log(cache.keys().map((k) => k));
}

main();
