// Build 1,000,000 small objects with push, then sum their fields. Value semantics stores
// an array as a list, so push is linear there and this program quadratic.
function measure(n: number): string {
  const start = Date.now();
  const items: { x: number; y: number }[] = [];
  for (let i = 0; i < n; i++) {
    items.push({ x: i, y: i * 2 });
  }
  const built = Date.now();
  let total = 0;
  for (const item of items) {
    total += item.x + item.y;
  }
  const end = Date.now();
  return JSON.stringify({
    bench: "objects",
    n,
    build_ms: built - start,
    sum_ms: end - built,
    total_ms: end - start,
    check: total,
  });
}

console.log(measure(1000000));
