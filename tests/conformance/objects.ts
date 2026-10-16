interface Point {
  x: number;
  y: number;
}

function move(p: Point, dx: number): Point {
  return { ...p, x: p.x + dx };
}

function main(): void {
  const p: Point = { x: 1, y: 2 };
  const q = move(p, 10);
  console.log(p.x, q.x, q.y);
  const config = { alpha: 1, beta: "two", gamma: [3] };
  console.log(Object.keys(config).join(","));
  console.log(Object.values({ only: 42 }).join(","));
  console.log(JSON.stringify(Object.entries({ k: "v" })));
  const merged = { ...{ a: 1, b: 2 }, ...{ b: 3, c: 4 } };
  console.log(merged.a, merged.b, merged.c);
  const key = "dynamic";
  const withKey = { [key]: true, [`${key}2`]: false };
  console.log(withKey.dynamic, withKey.dynamic2);
  const nested = { inner: { value: 1 } };
  nested.inner.value = 99;
  console.log(nested.inner.value);
  const counts: Record<string, number> = {};
  for (const word of ["a", "b", "a"]) {
    counts[word] = (counts[word] ?? 0) + 1;
  }
  console.log(counts["a"], counts["b"], counts["c"]);
  console.log("a" in counts, "z" in counts);
  delete counts["a"];
  console.log(Object.keys(counts).length);
  const shorthand = { p, q };
  console.log(shorthand.p.y);
  console.log({ single: "value" });
  console.log({ a: 1, b: [1, 2], c: { d: null } });
  const methods = {
    double(n: number): number {
      return n * 2;
    },
    triple: (n: number) => n * 3,
  };
  console.log(methods.double(4), methods.triple(4));
}

main();
