// A deterministic sweep of Array.prototype over generated arrays with
// holes, -0, NaN, and BigInts, compared with Node line by line.
let seed = 99;
function rand(): number {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
}
function ri(n: number): number {
  return Math.floor(rand() * n);
}
const out: string[] = [];
for (let i = 0; i < 1500; i++) {
  const a: unknown[] = [];
  const n = ri(8);
  for (let j = 0; j < n; j++)
    if (rand() < 0.8) a[j] = [ri(10), "s" + ri(5), -0, NaN, null, undefined, [ri(3)], 1n][ri(8)];
  if (rand() < 0.3) a.length = n + ri(3);
  const b = a.slice();
  const x = ri(12) - 4,
    y = ri(12) - 4;
  let ops: unknown[] = [];
  try {
    ops = [
      a.indexOf(a[1]),
      a.lastIndexOf(a[0]),
      a.includes(NaN),
      a.join("|"),
      a.slice(x, y),
      a.concat([9], 8),
      a.flat(),
      a.at(x),
      a.map((v) => typeof v),
      a.filter((v) => v != null),
      a.findLastIndex((v) => v === undefined),
      a.toReversed(),
      a.with(Math.max(0, Math.min(x, Math.max(0, a.length - 1))) || 0, "w"),
      Object.keys(a),
      a.toSpliced(x, y, "q"),
      a.copyWithin(x, y).length,
      [...a.keys()],
      a.fill("f", y, x),
      b.splice(x, y, "r", "t"),
      b,
      b.reverse(),
      b.sort((p, q) => String(p).localeCompare(String(q))).length,
      b.toSorted().length,
      b.every((v) => v !== 3),
      b.some((v) => v === 1),
      b.reduce((acc: number, v) => acc + (typeof v === "number" ? v : 0), 0),
    ];
  } catch (e) {
    ops = ["ERR", String(e), i, a.length, x, y];
  }
  out.push(
    JSON.stringify(ops, (k, v) =>
      typeof v === "bigint"
        ? v + "n"
        : v === undefined
          ? "undef"
          : Number.isNaN(v)
            ? "NaN"
            : Object.is(v, -0)
              ? "-0"
              : v,
    ),
  );
}
console.log(out.join("\n"));
