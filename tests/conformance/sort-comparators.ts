// A comparator that is not consistent orders items as V8 does: a comparator
// that never returns 0, one that returns a boolean, one that returns NaN,
// and one that answers at random, on short arrays (binary insertion) and long
// ones (runs, merges, and galloping). The random comparator makes the order
// depend on every call that V8 makes.

type Row = { id: number; k: number };

function rows(n: number, seed: number, range: number): Row[] {
  let state = seed;
  const out: Row[] = [];
  for (let i = 0; i < n; i++) {
    state = (state * 48271 + 1) % 2147483647;
    out.push({ id: i, k: state % range });
  }
  return out;
}

// A checksum of the order.
function digest(sorted: Row[]): number {
  let sum = 0;
  for (let i = 0; i < sorted.length; i++) sum = (sum * 31 + sorted[i].id * (i + 1)) % 1000000007;
  return sum;
}

function main(): void {
  const tied = [
    { k: 1, id: "a" },
    { k: 1, id: "b" },
  ];
  console.log([...tied].sort((x, y) => (x.k < y.k ? -1 : 1)).map((r) => r.id));
  console.log([2, 1].sort((a: any, b: any) => a > b));
  console.log([1, 2, 3, NaN, 0].sort((a, b) => a - b));
  const ages = [30, 25, 30, 20, 25, 30, 20].map((age, id) => ({ id, age }));
  console.log(
    ages
      .sort((x, y) => (x.age > y.age ? 1 : -1))
      .map((p) => p.id)
      .join(""),
  );

  const noZero = (a: Row, b: Row): number => (a.k < b.k ? -1 : 1);
  const boolean = (a: Row, b: Row): number => (a.k > b.k) as unknown as number;
  const someNaN = (a: Row, b: Row): number => (a.k === 3 || b.k === 3 ? NaN : a.k - b.k);
  const random = (a: Row, b: Row): number => ((a.id * 7919 + b.id * 104729) % 3) - 1;
  const consistent = (a: Row, b: Row): number => a.k - b.k;
  for (const n of [5, 7, 8, 31, 64, 65, 200, 1000, 3000]) {
    const line = [noZero, boolean, someNaN, random, consistent].map((compare) =>
      digest(rows(n, n, n > 100 ? 7 : 3).sort(compare)),
    );
    console.log(n, line.join(" "));
  }
  // Long ascending and descending runs make TimSort gallop.
  const runs = Array.from({ length: 600 }, (_, i) => ({ id: i, k: i % 100 < 50 ? i : 600 - i }));
  console.log("runs", digest([...runs].sort(noZero)), digest([...runs].sort(random)));
}

main();
