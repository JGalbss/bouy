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
