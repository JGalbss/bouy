// A deterministic sweep of number text: String, toFixed, toExponential,
// toPrecision, and toString with a radix over 3000 generated doubles, and
// the parse functions, compared with Node line by line.
let seed = 12345;
function rand(): number {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
}
const out: string[] = [];
for (let i = 0; i < 3000; i++) {
  const e = Math.floor(rand() * 60) - 30;
  const sign = rand() < 0.3 ? -1 : 1;
  const v = sign * rand() * Math.pow(10, e);
  const p = 1 + Math.floor(rand() * 20);
  const f = Math.floor(rand() * 21);
  const r = 2 + Math.floor(rand() * 35);
  out.push(
    [
      String(v),
      v.toFixed(f),
      v.toExponential(f),
      v.toPrecision(p),
      v.toString(r),
      parseFloat(String(v)) === v,
      Number(v.toExponential()) === v,
    ].join(" "),
  );
}
for (const s of [
  "0x1p3",
  "  1e-400",
  "1e309",
  "-0",
  "00012",
  "1.7976931348623159e308",
  "4.9e-324",
  "2.4703282292062328e-324",
  "123456789012345678901234567890",
])
  out.push(String(Number(s)) + " " + String(parseFloat(s)));
for (const v of [
  0.5, 1.5, 2.5, 1.005, 1.255, 8.345, 0.000001, 1e-7, 123.456, 1e21, 1e20, 999999999999999999999,
])
  out.push(v.toFixed(2) + " " + v.toPrecision(3) + " " + v.toExponential(1));
console.log(out.join("\n"));
