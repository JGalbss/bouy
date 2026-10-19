// Object.keys/entries, defineProperty, freeze, prototypes, and for...in.
const proto = {
  greet() {
    return `hi ${(this as { name: string }).name}`;
  },
  kind: "proto",
};
const obj = Object.create(proto) as {
  name: string;
  greet(): string;
  kind: string;
  [k: string]: unknown;
};
obj.name = "obj";
obj[2] = "two";
obj.b = 1;
Object.defineProperty(obj, "hidden", { value: 42, enumerable: false });
console.log(Object.keys(obj), obj.greet(), obj.hidden, "hidden" in obj, obj.hasOwnProperty("kind"));
const inherited: string[] = [];
for (const key in obj) inherited.push(key);
console.log(inherited);
console.log(Object.entries({ x: 1, y: [2] }), Object.getPrototypeOf(obj) === proto);

const frozen = Object.freeze({ a: 1 });
try {
  (frozen as { a: number }).a = 2;
} catch (e) {
  console.log((e as Error).constructor.name);
}
console.log(frozen.a, Object.isFrozen(frozen));
const assigned = Object.assign({ base: true }, { a: 1 }, { b: 2 });
console.log(assigned, Object.fromEntries([["k", "v"]]));
delete (assigned as { a?: number }).a;
console.log("a" in assigned, Object.keys(assigned).length);

// Objects that gain the same keys in another order, or that lose and regain a key, keep
// the order in which each one gained its keys.
const xy: Record<string, number> = { x: 1, y: 2 };
const yx: Record<string, number> = { y: 2, x: 1 };
yx.z = 3;
delete xy.x;
xy.x = 4;
console.log(Object.keys(xy), Object.keys(yx), JSON.stringify(xy), JSON.stringify(yx));
const wide: Record<string, number> = {};
for (let i = 0; i < 80; i++) wide[`k${i}`] = i;
delete wide.k5;
console.log(Object.keys(wide).length, Object.keys(wide).slice(0, 6).join(), wide.k79);
const counted: Record<string, number> = {};
for (const word of "the cat and the hat and the bat".split(" ")) counted[word] = (counted[word] ?? 0) + 1;
console.log(counted, Object.entries(counted).length);
const reconfigured = { a: 1, b: 2, c: 3 };
Object.defineProperty(reconfigured, "b", { enumerable: false });
reconfigured.c = 30;
console.log(Object.keys(reconfigured), reconfigured.b, Object.getOwnPropertyNames(reconfigured));
