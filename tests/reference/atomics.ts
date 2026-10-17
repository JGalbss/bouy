// Atomics over shared and unshared integer typed arrays: the read-modify-write
// operations return the old value, store returns the converted value, and
// float arrays and out-of-range indexes throw.
const ta = new Int32Array(new SharedArrayBuffer(16));
console.log(
  Atomics.add(ta, 0, 5),
  Atomics.sub(ta, 0, 2),
  Atomics.load(ta, 0),
  Atomics.store(ta, 1, 3.7),
  Atomics.exchange(ta, 1, 9),
  Atomics.compareExchange(ta, 1, 9, 4),
  ta,
);
const u8 = new Uint8Array(4);
console.log(
  Atomics.add(u8, 0, 300),
  u8[0],
  Atomics.or(u8, 1, 6),
  Atomics.and(u8, 1, 3),
  Atomics.xor(u8, 1, 1),
  u8,
  Atomics.isLockFree(4),
  Atomics.wait(ta, 0, 1, 0),
  Atomics.notify(ta, 0),
);
const b = new BigInt64Array(2);
console.log(Atomics.add(b, 0, 2n ** 63n), b[0]);
try {
  Atomics.add(new Float64Array(1), 0, 1);
} catch (e) {
  console.log((e as Error).name);
}
try {
  Atomics.load(ta, 9);
} catch (e) {
  console.log((e as Error).name);
}
