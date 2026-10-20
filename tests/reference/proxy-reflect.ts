// Proxy traps in the order the internal methods call them, their invariants, and Reflect.
const log: string[] = [];
const target: Record<string | symbol, unknown> = { a: 1 };
const handler: ProxyHandler<typeof target> = {
  get(t, key, receiver) {
    log.push(`get ${String(key)}`);
    return Reflect.get(t, key, receiver);
  },
  set(t, key, value, receiver) {
    log.push(`set ${String(key)}`);
    return Reflect.set(t, key, value, receiver);
  },
  has(t, key) {
    log.push(`has ${String(key)}`);
    return Reflect.has(t, key);
  },
  deleteProperty(t, key) {
    log.push(`delete ${String(key)}`);
    return Reflect.deleteProperty(t, key);
  },
  ownKeys(t) {
    log.push("ownKeys");
    return Reflect.ownKeys(t);
  },
  getOwnPropertyDescriptor(t, key) {
    log.push(`gopd ${String(key)}`);
    return Reflect.getOwnPropertyDescriptor(t, key);
  },
  defineProperty(t, key, desc) {
    log.push(`define ${String(key)}`);
    return Reflect.defineProperty(t, key, desc);
  },
  getPrototypeOf(t) {
    log.push("getPrototypeOf");
    return Reflect.getPrototypeOf(t);
  },
  setPrototypeOf(t, proto) {
    log.push("setPrototypeOf");
    return Reflect.setPrototypeOf(t, proto);
  },
  isExtensible(t) {
    log.push("isExtensible");
    return Reflect.isExtensible(t);
  },
  preventExtensions(t) {
    log.push("preventExtensions");
    return Reflect.preventExtensions(t);
  },
};
const proxy = new Proxy(target, handler);
proxy.b = 2;
console.log(proxy.a, "a" in proxy, Object.keys(proxy), delete proxy.a, target.a);
console.log(Object.getPrototypeOf(proxy) === Object.prototype, Object.isExtensible(proxy));
Object.setPrototypeOf(proxy, null);
Object.preventExtensions(proxy);
console.log(log.join(" | "));

const errorText = (run: () => unknown): string => {
  try {
    run();
    return "no error";
  } catch (error) {
    return (error as Error).constructor.name;
  }
};
const frozenTarget = Object.freeze({ x: 1 });
const liar = new Proxy(frozenTarget, { get: () => 2, has: () => false, ownKeys: () => [] });
console.log(
  errorText(() => liar.x),
  errorText(() => "x" in liar),
  errorText(() => Object.keys(liar)),
);
const { proxy: revocable, revoke } = Proxy.revocable({}, {});
revoke();
console.log(
  errorText(() => (revocable as Record<string, unknown>).x),
  typeof revocable,
);

const callable = new Proxy(
  function sum(a: number, b: number) {
    return a + b;
  },
  {
    apply: (fn, thisArg, args: number[]) => fn.apply(thisArg, args) * 10,
    construct: (_fn, args: unknown[]) => ({ made: args.length }),
  },
);
console.log(
  typeof callable,
  callable(1, 2),
  JSON.stringify(new (callable as unknown as new (...args: unknown[]) => object)(1, 2, 3)),
);

class Base {
  kind = "base";
}
class Derived extends Base {}
const built = Reflect.construct(Base, [], Derived);
console.log(built instanceof Derived, (built as Base).kind);
console.log(
  Reflect.apply(Math.max, undefined, [1, 5, 3]),
  Reflect.ownKeys({ b: 1, a: 2, 1: 0, [Symbol.iterator]: 0 }).length,
);
console.log(
  Reflect.defineProperty(Object.freeze({}), "x", { value: 1 }),
  Reflect.set(Object.freeze({ y: 1 }), "y", 2),
);
const receiver = { scale: 3 };
console.log(
  Reflect.get(
    {
      get doubled() {
        return (this as { scale: number }).scale * 2;
      },
    },
    "doubled",
    receiver,
  ),
);
console.log(
  Object.prototype.toString.call(Reflect),
  Reflect.has([], "length"),
  Array.isArray(new Proxy([], {})),
);
const chainTrap = new Proxy(
  {},
  { get: (_target, key, receiver) => `${String(key)} of ${typeof receiver}` },
);
const savedProto = Object.getPrototypeOf(Number.prototype) as object;
Object.setPrototypeOf(Number.prototype, chainTrap);
const viaPrimitive = (5 as unknown as { found: string }).found;
Object.setPrototypeOf(Number.prototype, savedProto);
class ChainBase {}
Object.setPrototypeOf(ChainBase.prototype, chainTrap);
class ChainChild extends ChainBase {
  read(): unknown {
    return (super["found" as keyof object] as unknown) ?? "none";
  }
}
console.log(viaPrimitive, new ChainChild().read());
