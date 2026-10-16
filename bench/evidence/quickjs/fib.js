function fib(n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}

const clock = typeof performance === "undefined" ? Date : performance;
const samples = Array.from({ length: 6 }, () => {
  const start = clock.now();
  fib(27);
  return clock.now() - start;
});

globalThis.fibResult = {
  argument: 27,
  value: fib(27),
  clock: clock === Date ? "Date.now" : "performance.now",
  first_ms: samples[0],
  warm_ms: samples.slice(1),
};

if (typeof console !== "undefined") console.log(JSON.stringify(globalThis.fibResult));
