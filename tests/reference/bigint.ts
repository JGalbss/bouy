// BigInt literals, operators, comparisons with numbers and strings, the
// BigInt function, and the errors of mixing BigInt with numbers.
const big = 123456789012345678901234567890n;
console.log(typeof big, big, -big, big * big);
console.log(7n / 2n, -7n / 2n, 7n % -3n, -7n % 3n, 2n ** 100n);
console.log(1n << 70n, -9n >> 1n, 5n & 3n, 5n | 8n, 5n ^ 1n, ~5n);
let counter = 0n;
counter++;
counter += 10n;
console.log(counter, counter > 10, counter == 11, counter === 11n, 1n < 1.5, 2n > "1");
console.log(BigInt("0x1f"), BigInt(" 42 "), BigInt(true), BigInt(Number.MAX_SAFE_INTEGER) + 2n);
console.log(BigInt.asIntN(8, 255n), BigInt.asUintN(8, -1n), (255n).toString(16), `${10n}`);
console.log([3n, 1n, 2n].sort().join(), new Set([1n, 1n, 2n]).size, new Map([[1n, "one"]]).get(1n));
for (const attempt of [() => 1n + 1, () => +1n, () => BigInt(1.5), () => BigInt("1.5"), () => 1n / 0n, () => 1n >>> 0n]) {
  try {
    attempt();
  } catch (error) {
    console.log((error as Error).name + ": " + (error as Error).message);
  }
}
console.log(Object(5n) instanceof BigInt, typeof Object(5n), JSON.stringify({ a: 1 }));
