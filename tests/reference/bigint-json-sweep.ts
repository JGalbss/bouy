// A deterministic sweep of BigInt operators, conversions, and mixed
// comparisons, and of JSON text with gaps and property lists.
let seed = 31337;
function rand(): number {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
}
function big(): bigint {
  let s = rand() < 0.5 ? "-" : "";
  const n = 1 + Math.floor(rand() * 40);
  for (let i = 0; i < n; i++) s += Math.floor(rand() * 10);
  return BigInt(s);
}
const out: string[] = [];
for (let i = 0; i < 1500; i++) {
  const a = big(),
    b = big() || 1n,
    s = BigInt(Math.floor(rand() * 70));
  const n = (rand() - 0.5) * 1e20;
  const r: unknown[] = [
    a + b,
    a - b,
    a * b,
    a / b,
    a % b,
    a ** (s % 5n),
    a & b,
    a | b,
    a ^ b,
    ~a,
    a << s,
    a >> s,
    -a,
    a < b,
    a == n,
    a < n,
    a > n,
    a.toString(36),
    BigInt.asIntN(Number(s), a),
    BigInt.asUintN(Number(s), a),
    Number(a),
    String(a),
    parseInt(a.toString(16), 16),
  ];
  out.push(r.map(String).join(" "));
}
const vals: unknown[] = [
  { a: [1, "x", null, true, { b: -0, c: 1e21, d: 1.5e-7 }], e: 'q \ud800"\\', f: undefined },
  [NaN, Infinity, new Date(0), [], {}],
];
for (const v of vals) {
  const t = JSON.stringify(v, null, 3);
  out.push(t, JSON.stringify(JSON.parse(t)), JSON.stringify(v, ["a", "e"], "\t"));
}
console.log(out.join("\n"));
