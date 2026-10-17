// The value-semantics form of closures.ts: the counter is threaded through a pure function.
function inc(count: number): number {
  return count + 1;
}

function measure(n: number): string {
  const start = Date.now();
  let count = 0;
  for (let i = 0; i < n; i++) count = inc(count);
  const end = Date.now();
  return JSON.stringify({ bench: "closures-value", n, total_ms: end - start, check: count });
}

console.log(measure(1000000));
