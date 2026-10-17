// Number.prototype.toLocaleString in the en-US locale: grouping, the
// fraction and integer digits, percent and currency styles, and the
// rounding of the shortest digits half away from zero; BigInt grouping.
const f = (n: number, o?: Intl.NumberFormatOptions) => n.toLocaleString("en-US", o);
console.log(
  f(1234.5678),
  f(1.0005),
  f(1.005, { maximumFractionDigits: 2 }),
  f(0.5, { maximumFractionDigits: 0 }),
  f(2.5, { maximumFractionDigits: 0 }),
  f(-2.5, { maximumFractionDigits: 0 }),
  f(1234.5, { minimumFractionDigits: 2 }),
  f(1234.5, { useGrouping: false }),
  f(0.256, { style: "percent" }),
  f(-1234.5, { style: "currency", currency: "USD" }),
  f(1234.5, { style: "currency", currency: "EUR" }),
  f(5, { minimumIntegerDigits: 3 }),
  f(1e21),
  f(-0),
  f(123456789.123456, { maximumFractionDigits: 5 }),
  f(1.23e-7),
  f(1e-7, { maximumFractionDigits: 10 }),
  f(999.9995),
  f(NaN),
  f(-Infinity),
  f(0.0004),
  f(-0.0004),
  f(99.95, { maximumFractionDigits: 1 }),
  f(1234567.891, { style: "currency", currency: "JPY" }),
);
let seed = 3;
const r = () => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
};
const out: string[] = [];
for (let i = 0; i < 500; i++) {
  const v = (r() - 0.5) * Math.pow(10, Math.floor(r() * 16) - 6);
  out.push(
    f(v) +
      " " +
      f(v, { maximumFractionDigits: Math.floor(r() * 6) }) +
      " " +
      f(v, { style: "percent" }),
  );
}
console.log(out.join("\n"));
console.log(1234567n.toLocaleString(), (-1000n).toLocaleString(), 12n.toLocaleString());
