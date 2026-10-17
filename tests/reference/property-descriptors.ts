// Property descriptors: validation, integrity levels, array length, and the legacy accessors.
const show = (value: unknown): string => JSON.stringify(value);
const errorName = (run: () => unknown): string => {
  try {
    run();
    return "no error";
  } catch (error) {
    return (error as Error).constructor.name;
  }
};

const fixed: Record<string, unknown> = {};
Object.defineProperty(fixed, "x", { value: 1 });
console.log(show(Object.getOwnPropertyDescriptor(fixed, "x")));
console.log(errorName(() => Object.defineProperty(fixed, "x", { value: 2 })));
console.log(errorName(() => Object.defineProperty(fixed, "x", { value: 1, writable: false })));
console.log(errorName(() => Object.defineProperty(fixed, "x", { get: () => 1 })));
console.log(errorName(() => Object.defineProperty(fixed, "y", { get: () => 1, value: 2 })));
console.log(errorName(() => Object.defineProperty(fixed, "y", { get: 5 as never })));

const accessor: Record<string, number> = {};
let stored = 0;
Object.defineProperty(accessor, "v", {
  get: () => stored,
  set: (value: number) => {
    stored = value * 2;
  },
  enumerable: true,
  configurable: true,
});
accessor.v = 4;
console.log(
  accessor.v,
  Object.keys(accessor),
  show(Object.getOwnPropertyDescriptor(accessor, "v")?.enumerable),
);
Object.defineProperty(accessor, "v", { value: 10 });
console.log(show(Object.getOwnPropertyDescriptor(accessor, "v")));

const many = Object.defineProperties(
  {},
  {
    a: { value: 1, enumerable: true },
    b: { value: 2 },
  },
);
console.log(
  Object.keys(many),
  Object.getOwnPropertyNames(many),
  show(Object.getOwnPropertyDescriptors(many)),
);
const made = Object.create({ inherited: true }, { own: { value: "o", enumerable: true } });
console.log(made.own, made.inherited, Object.keys(made));

const sealed = Object.seal({ s: 1 });
sealed.s = 2;
console.log(
  sealed.s,
  Object.isSealed(sealed),
  Object.isFrozen(sealed),
  errorName(() => delete (sealed as { s?: number }).s),
);
const closed = Object.preventExtensions({ p: 1 });
console.log(
  Object.isExtensible(closed),
  errorName(() => ((closed as Record<string, number>).q = 1)),
);
const manual: Record<string, number> = {};
Object.defineProperty(manual, "m", { value: 1 });
Object.preventExtensions(manual);
console.log(Object.isFrozen(manual), Object.isFrozen(1), Object.isExtensible(1));

const list = [1, 2, 3];
Object.defineProperty(list, "length", { writable: false });
console.log(
  errorName(() => list.push(4)),
  list.length,
  Object.getOwnPropertyNames(list),
);
const shrink = [1, 2, 3, 4];
Object.defineProperty(shrink, 1, { value: 2, configurable: false });
console.log(
  errorName(() => (shrink.length = 0)),
  shrink.length,
);
console.log(errorName(() => Object.defineProperty([], "length", { value: -1 })));

const literal = { __proto__: { greet: "hi" }, own: 1 } as { greet: string; own: number };
console.log(
  literal.greet,
  Object.keys(literal),
  Object.getPrototypeOf(Object.getPrototypeOf(literal)) === Object.prototype,
);
const legacy: Record<string, unknown> = {};
(legacy as { __defineGetter__(k: string, f: () => unknown): void }).__defineGetter__("g", () => 7);
console.log(
  legacy.g,
  typeof (legacy as { __lookupGetter__(k: string): unknown }).__lookupGetter__("g"),
);

const grouped = Object.groupBy([1, 2, 3, 4, 5], (n) => (n % 2 === 0 ? "even" : "odd"));
console.log(show(grouped), Object.getPrototypeOf(grouped));
console.log(
  Object.entries({ b: 2, a: 1, 1: "one" })
    .map(([k, v]) => `${k}=${v}`)
    .join(","),
);
console.log(Object.hasOwn({ q: 1 }, "q"), Object.is(-0, 0), Object.is(NaN, NaN));
console.log(errorName(() => Object.setPrototypeOf(Object.prototype, {})));
const a: Record<string, unknown> = {};
const b = Object.create(a);
console.log(errorName(() => Object.setPrototypeOf(a, b)));
