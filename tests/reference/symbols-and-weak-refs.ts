// Symbols, the registry, well-known symbols, and the weak collections.
const plain = Symbol("plain");
const empty = Symbol();
const shared = Symbol.for("shared");
console.log(plain.description, empty.description, plain.toString(), String(empty));
console.log(Symbol.for("shared") === shared, Symbol.keyFor(shared), Symbol.keyFor(plain));
const errorName = (run: () => unknown): string => {
  try {
    run();
    return "no error";
  } catch (error) {
    return (error as Error).constructor.name;
  }
};
console.log(
  errorName(() => new (Symbol as unknown as new () => object)()),
  errorName(() => `${plain as unknown as string}`),
);
console.log(errorName(() => Symbol.keyFor("text" as unknown as symbol)));
const wellKnown = [
  "asyncIterator",
  "hasInstance",
  "isConcatSpreadable",
  "iterator",
  "match",
  "matchAll",
  "replace",
  "search",
  "species",
  "split",
  "toPrimitive",
  "toStringTag",
  "unscopables",
] as const;
console.log(
  wellKnown.every((name) => typeof Symbol[name] === "symbol"),
  Symbol.iterator.description,
);
console.log(JSON.stringify(Object.getOwnPropertyDescriptor(Symbol, "iterator")));

const money = {
  [Symbol.toPrimitive](hint: string) {
    return hint === "number" ? 42 : "forty-two";
  },
  get [Symbol.toStringTag]() {
    return "Money";
  },
};
console.log(+money, `${money}`, Object.prototype.toString.call(money));
const keyed = { [plain]: 1, regular: 2 };
console.log(Object.keys(keyed), Object.getOwnPropertySymbols(keyed).length, JSON.stringify(keyed));

const map = new WeakMap<object, string>();
const set = new WeakSet<object>();
const key = {};
map.set(key, "value");
set.add(key);
console.log(map.get(key), map.has({}), set.has(key), map.delete(key), map.has(key));
console.log(
  errorName(() => map.set(1 as unknown as object, "x")),
  errorName(() => set.add("s" as unknown as object)),
);
console.log(Object.prototype.toString.call(map), Object.prototype.toString.call(set));

const ref = new WeakRef(key);
console.log(
  ref.deref() === key,
  Object.prototype.toString.call(ref),
  errorName(() => new WeakRef(1 as unknown as object)),
);
const registry = new FinalizationRegistry<string>(() => {});
const token = {};
registry.register(key, "held", token);
console.log(
  registry.unregister(token),
  registry.unregister(token),
  errorName(() => registry.register(key, key as unknown as string)),
);
