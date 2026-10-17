// Number to text and text to number, with the exact roundings of toFixed,
// toExponential, toPrecision, and toString with a radix.
const values = [
  0,
  -0,
  1.005,
  0.1,
  123.456,
  1e21,
  5e-7,
  -1.5e-9,
  2 ** 53 + 2,
  1 / 3,
  255,
  0.000001234,
];
for (const v of values) {
  console.log(
    String(v),
    v.toFixed(2),
    v.toExponential(3),
    v.toPrecision(4),
    v.toString(16),
    v.toString(3),
  );
}
console.log((0.1).toFixed(20), (123.456).toExponential(), (1e-7).toString(), (-255).toString(2));
console.log(
  Number("0x1F"),
  Number("0b101"),
  Number("-0x10"),
  Number(" 12.5e3 "),
  Number("1_0"),
  Number(""),
  Number("Infinity"),
);
console.log(
  parseInt("  -0x1F"),
  parseInt("123abc", 8),
  parseInt("z", 36),
  parseFloat(".5e1x"),
  parseFloat("-0"),
  parseFloat("Infinityx"),
);
console.log(
  Number.MAX_VALUE,
  Number.MIN_VALUE,
  Number.EPSILON,
  Number.isSafeInteger(2 ** 53),
  (12345.6789).toLocaleString(),
);
for (const attempt of [() => (1).toFixed(101), () => (1).toString(1), () => (1).toPrecision(0)]) {
  try {
    attempt();
  } catch (error) {
    console.log((error as Error).name + ": " + (error as Error).message);
  }
}
