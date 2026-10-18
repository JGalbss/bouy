// 1,000,000 calls of a closure that increments a captured counter. Value semantics
// rejects this program (BUOY205); closures-value.ts is its closest legal form.
function counter() {
  let count = 0;
  return {
    inc: () => ++count,
    get: () => count,
  };
}

function measure(n: number): string {
  const c = counter();
  const start = Date.now();
  for (let i = 0; i < n; i++) c.inc();
  const end = Date.now();
  return JSON.stringify({ bench: "closures", n, total_ms: end - start, check: c.get() });
}

console.log(measure(1000000));
