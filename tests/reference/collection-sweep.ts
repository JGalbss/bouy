// A deterministic sweep of Map and Set: SameValueZero keys, deletes and
// clears, iteration that sees later sets and skips deletes, the Set
// methods, and Map.groupBy.
let seed = 5;
function rand(): number {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
}
const keys: unknown[] = [0, -0, NaN, "0", 1, "a", null, undefined, 1n, true];
const out: string[] = [];
for (let i = 0; i < 600; i++) {
  const m = new Map<unknown, number>();
  const s = new Set<unknown>();
  const log: string[] = [];
  for (let j = 0; j < 12; j++) {
    const k = keys[Math.floor(rand() * keys.length)];
    const op = Math.floor(rand() * 4);
    if (op === 0) {
      m.set(k, j);
      s.add(k);
    } else if (op === 1) {
      log.push(String(m.delete(k)) + String(s.delete(k)));
    } else if (op === 2) {
      log.push(String(m.get(k)) + String(s.has(k)));
    } else if (rand() < 0.2) {
      m.clear();
    }
  }
  const seen: string[] = [];
  for (const [k, v] of m) {
    seen.push(String(k) + ":" + v);
    if (seen.length === 2) m.set("late", 99);
    if (seen.length === 1) m.delete(keys[3]);
  }
  const other = new Set([0, "a", 2]);
  out.push(
    [
      log.join(","),
      seen.join(","),
      m.size,
      [...s].map(String).join(","),
      [...s.union(other)].map(String).join(","),
      [...s.intersection(other)].map(String).join(","),
      s.isSubsetOf(other),
      [...Map.groupBy([1, 2, 3, 4], (x) => x % 2)].map(String).join(";"),
    ].join(" | "),
  );
}
console.log(out.join("\n"));
