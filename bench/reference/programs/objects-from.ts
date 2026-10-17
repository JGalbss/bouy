// Build 1,000,000 small objects with Array.from, then sum their fields. Value semantics
// stores an array as a list, so objects.ts, which pushes, is quadratic there; this is the
// form that all three runtimes run in linear time.
function measure(n: number): string {
  const start = Date.now();
  const items = Array.from({ length: n }, (_, i) => ({ x: i, y: i * 2 }));
  const built = Date.now();
  let total = 0;
  for (const item of items) {
    total += item.x + item.y;
  }
  const end = Date.now();
  return JSON.stringify({
    bench: "objects-from",
    n,
    build_ms: built - start,
    sum_ms: end - built,
    total_ms: end - start,
    check: total,
  });
}

console.log(measure(1000000));
