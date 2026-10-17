// Object and array destructuring, defaults, rest, and spread.
const user = {
  name: "ann",
  age: 30,
  address: { city: "Oslo", zip: "0150" },
  tags: ["a", "b", "c"],
};
const {
  name,
  address: { city },
  tags: [first, ...others],
  missing = "default",
  ...rest
} = user as typeof user & { missing?: string };
console.log(name, city, first, others, missing, Object.keys(rest));

let x = 1;
let y = 2;
[x, y] = [y, x];
console.log(x, y);

const merged = { ...user.address, zip: "9999", extra: true };
console.log(merged);
const arr = [0, ...user.tags, ...new Set([1, 1, 2])];
console.log(arr);

function f({ a = 1, b }: { a?: number; b: number }, ...more: number[]): number {
  return a + b + more.reduce((s, n) => s + n, 0);
}
console.log(f({ b: 2 }), f({ a: 10, b: 2 }, 3, 4));
const pairs = Object.entries({ p: 1, q: 2 }).map(([k, v]) => `${k}=${v}`);
console.log(pairs);
