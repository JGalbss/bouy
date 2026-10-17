// Array methods on a proxy of an array and on array-likes, as reactive stores use them.
const log: string[] = [];
const target = [1, 2, 3];
const reactive = new Proxy(target, {
  get(t, k, r) {
    if (typeof k === "string") log.push(`get ${k}`);
    return Reflect.get(t, k, r);
  },
  set(t, k, v, r) {
    log.push(`set ${String(k)}`);
    return Reflect.set(t, k, v, r);
  },
});
reactive.push(4);
console.log(target, Array.isArray(reactive), reactive.length);
console.log(
  reactive.map((x: number) => x * 2),
  reactive.indexOf(3),
);
reactive.pop();
reactive.reverse();
console.log(target, log.length > 0);
const args = (function (..._a: number[]) {
  return arguments;
})(1, 2);
Array.prototype.push.call(args, 3);
console.log(args.length, Array.prototype.slice.call(args));
const like = { length: 2, 0: "a", 1: "b" } as unknown as string[];
console.log(Array.prototype.join.call(like, "-"));
