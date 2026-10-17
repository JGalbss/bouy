// A deterministic sweep of typed array element conversions, sorting,
// views, and DataView reads over every element type. Node 25's
// Float16Array.prototype.indexOf misses present values, so the sweep skips it.
let seed = 2024;
function rand(): number {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
}
const kinds = [
  Int8Array,
  Uint8Array,
  Uint8ClampedArray,
  Int16Array,
  Uint16Array,
  Int32Array,
  Uint32Array,
  Float16Array,
  Float32Array,
  Float64Array,
];
const specials = [
  0,
  -0,
  NaN,
  Infinity,
  -Infinity,
  0.5,
  1.5,
  2.5,
  -1.5,
  255.5,
  65535,
  65536,
  2 ** 31,
  -(2 ** 31) - 1,
  1e300,
  5e-324,
  1 / 3,
  70000.7,
  -129,
];
const out: string[] = [];
for (let i = 0; i < 800; i++) {
  const K = kinds[Math.floor(rand() * kinds.length)];
  const n = 1 + Math.floor(rand() * 6);
  const t = new K(n);
  for (let j = 0; j < n; j++)
    t[j] = rand() < 0.5 ? specials[Math.floor(rand() * specials.length)] : (rand() - 0.5) * 1000;
  const dv = new DataView(t.buffer);
  const off = Math.floor(rand() * Math.max(1, t.byteLength - 3));
  const le = rand() < 0.5;
  const r: unknown[] = [
    K.name,
    Array.from(t),
    Array.from(t.slice().sort()),
    Array.from(t.subarray(1)),
    K === Float16Array ? "skip" : t.indexOf(t[0]),
    t.join(","),
    dv.getUint8(0),
    t.byteLength >= off + 2 ? dv.getInt16(off, le) : "x",
    t.byteLength >= off + 4 ? dv.getFloat32(off, le) : "x",
    Array.from(new Uint8Array(t.buffer)),
  ];
  out.push(
    r
      .map((v) =>
        Array.isArray(v)
          ? v.map((x) => (Object.is(x, -0) ? "-0" : String(x))).join(" ")
          : String(v),
      )
      .join(" | "),
  );
}
console.log(out.join("\n"));
