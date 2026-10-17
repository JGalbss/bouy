// console.log of proxies, weak collections, the kinds of function, and tagged objects.
console.log(new Proxy({ a: 1 }, {}), typeof new Proxy(function target() {}, {}));
console.log(new WeakMap(), new WeakSet(), new WeakRef({}));
function named(): void {}
console.log(
  named,
  named.bind(null),
  () => 1,
  function* gen() {},
  async function later() {},
);
console.log(Object.create(null), Reflect, { [Symbol.toStringTag]: "Custom", value: 1 });
