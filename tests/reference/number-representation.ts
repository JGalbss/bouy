// The representation of numbers: integers and floats are one kind of value, -0 and the
// non-finite values survive arithmetic, integral results past 2^53 round as doubles do,
// and the bitwise operators work on 32-bit integers.

const negativeZero = -0;
console.log(Object.is(negativeZero, 0), negativeZero === 0, 1 / negativeZero);
console.log(Object.is(0 * -5, -0), Object.is(-5 % 5, -0), Object.is(0 / -3, -0));
console.log(Object.is(-0 + 0, 0), Object.is(-0 - 0, -0), Object.is(Math.max(-0, 0), 0));
console.log(String(-0), `${-0}`, JSON.stringify(-0), [-0].includes(0));

const half = 0.5;
console.log(half + half === 1, typeof (half + half), [1].indexOf(half * 2));
console.log(0.1 + 0.2, 1 / 3, 2 ** 0.5, 10 / 4, 9 / 3);

const big = 2 ** 53;
console.log(big, big + 1, big + 2, big * 3, Number.MAX_SAFE_INTEGER + 2);
console.log(2 ** 64, 2 ** 1023 * 2, -(2 ** 1023) * 4, 1e308 * 10);
console.log(123456789 * 987654321, 3 ** 40, (2 ** 53 + 1) % 2);

console.log(NaN === NaN, Object.is(NaN, NaN), [NaN].includes(NaN), [NaN].indexOf(NaN));
console.log(Infinity - Infinity, Infinity * 0, -Infinity / Infinity, 5 % Infinity, Infinity % 5);
console.log(1 / 0, -1 / 0, 0 / 0, Math.sign(-Infinity));

console.log((2 ** 31) | 0, -1 >>> 0, 1 << 31, 1 << 32, -1 >>> 28, ~5, 5 & -2, (2 ** 32 + 5) | 0);
console.log(1.9 | 0, -1.9 | 0, NaN | 0, Infinity | 0, 4294967296.5 >> 0);

const keys = new Map<number, string>();
keys.set(0, "zero");
keys.set(1, "one");
console.log(keys.get(-0), keys.get(0.5 + 0.5), new Set([0, -0, 1, 1.0]).size);

console.log(
  Number("  12  "),
  Number("1e3"),
  Number("-0"),
  Number("0x1F"),
  Number(""),
  Number("1_0"),
);
console.log(parseInt("42px"), parseFloat("3.25e2x"), (255).toString(16), (0.000001234).toFixed(8));
console.log(1e21, 1e-7, 123456789012345680000, 5e-324, -1.5e300);
