// Step 1 baseline: the same heap operations in Node (V8).
// Run: bench/reference/run.sh heap
import os from "node:os";

const N = 1_000_000;
const load = () =>
  `load ${os
    .loadavg()
    .map((x) => x.toFixed(2))
    .join(" ")}`;
console.log(load());

function time(name, f) {
  f(1000);
  const t0 = process.hrtime.bigint();
  const r = f(N);
  const ns = Number(process.hrtime.bigint() - t0);
  console.log(`${name.padEnd(55)} ${(ns / N).toFixed(1).padStart(8)} ns/op  (check ${r})`);
}

class Base {
  get() {
    return this.v;
  }
}
class Mid extends Base {}

time("empty loop", (n) => {
  let a = 0;
  for (let i = n; i > 0; i--) a += 0;
  return a;
});
time("get own property", (n) => {
  const o = { x: 1, y: 2, z: 3 };
  let a = 0;
  for (let i = n; i > 0; i--) a += o.y;
  return a;
});
time("set existing property", (n) => {
  const o = { x: 1, y: 2, z: 3 };
  for (let i = n; i > 0; i--) o.y = i;
  return o.y;
});
time("method call via prototype (2 levels)", (n) => {
  const o = new Mid();
  o.v = 1;
  let a = 0;
  for (let i = n; i > 0; i--) a += o.get();
  return a;
});
time("allocate {x, y} object (kept live)", (n) => {
  const keep = new Array(n);
  for (let i = n; i > 0; i--) keep[i - 1] = { x: i, y: i };
  return keep.length;
});
let sink = null;
time("allocate {x, y} object (short-lived)", (n) => {
  for (let i = n; i > 0; i--) sink = { x: i, y: i };
  return sink.x;
});
time("cell increment (captured counter)", (n) => {
  let c = 0;
  const inc = () => {
    c++;
  };
  for (let i = n; i > 0; i--) inc();
  return c;
});
time("array push", (n) => {
  const a = [];
  for (let i = 0; i < n; i++) a.push(i);
  return a.length;
});
time("array index read", (n) => {
  const a = Array.from({ length: 1000 }, (_, i) => i + 1);
  let s = 0;
  for (let i = n; i > 0; i--) s += a[i % 1000];
  return s;
});

function build(n) {
  let next = null;
  for (let i = n; i > 0; i--) next = { id: i, next };
  return next;
}
for (const [live, garbage] of [
  [100_000, 0],
  [100_000, 900_000],
  [1_000_000, 0],
]) {
  let root = build(live);
  let junk = [];
  for (let i = 0; i < garbage; i++) junk.push({});
  junk = null;
  const t0 = process.hrtime.bigint();
  globalThis.gc();
  const us = Number(process.hrtime.bigint() - t0) / 1000;
  const used = process.memoryUsage().heapUsed / 1048576;
  console.log(
    `gc: ${String(live).padStart(7)} live + ${String(garbage).padStart(7)} garbage: full gc() ${(us / 1000).toFixed(1)} ms, heapUsed ${used.toFixed(1)} MB (root ${root.id})`,
  );
  root = null;
  globalThis.gc();
}
console.log(load());
