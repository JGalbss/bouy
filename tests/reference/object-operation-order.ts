// The abstract operations of ECMA-262 in the order that Proxy traps, getters, and
// coercions can observe: CopyDataProperties, ArraySetLength, CreateDataPropertyOrThrow,
// TypedArray [[Set]] and [[PreventExtensions]], PutValue, GetPrototypeFromConstructor,
// and the JSON.parse reviver. Node 25.9 reads the prototype of new.target before it
// converts a typed array length, so test262 alone covers that order.
const outcome = (run: () => unknown): string => {
  try {
    run();
    return "ok";
  } catch (error) {
    return (error as Error).constructor.name;
  }
};

const traced = <T extends object>(target: T, log: string[]): T =>
  new Proxy(target, {
    ownKeys(t) {
      log.push("ownKeys");
      return Reflect.ownKeys(t).reverse();
    },
    getOwnPropertyDescriptor(t, key) {
      log.push(`gopd ${String(key)}`);
      return Reflect.getOwnPropertyDescriptor(t, key);
    },
    get(t, key, receiver) {
      log.push(`get ${String(key)}`);
      return Reflect.get(t, key, receiver);
    },
  });

// Spread and rest walk the keys in the order ownKeys returns them, skip an excluded key
// before [[GetOwnProperty]], and read only an enumerable property.
const tag = Symbol("tag");
const source: Record<string | symbol, unknown> = { a: 1, b: 2, [tag]: 3 };
Object.defineProperty(source, "hidden", { value: 4, enumerable: false });
const spreadLog: string[] = [];
const spread = { ...traced(source, spreadLog) };
console.log(spreadLog.join(", "));
console.log(Reflect.ownKeys(spread).map(String).join(", "));
const restLog: string[] = [];
const { b, ...rest } = traced(source, restLog);
console.log(b, restLog.join(", "), Reflect.ownKeys(rest).map(String).join(", "));

// A getter that deletes a later key or hides it removes that key from the copy.
const shrinking: Record<string, unknown> = {
  get first() {
    delete shrinking.second;
    Object.defineProperty(shrinking, "third", { enumerable: false });
    return 1;
  },
  second: 2,
  third: 3,
  fourth: 4,
};
console.log(JSON.stringify({ ...shrinking }));

// ArraySetLength reads the length property after the new length coerces.
const array = [1, 2, 3];
const length = {
  valueOf() {
    Object.defineProperty(array, "length", { writable: false });
    return 0;
  },
};
console.log(
  outcome(() => (array.length = length as unknown as number)),
  array.length,
);

// CreateDataPropertyOrThrow is one [[DefineOwnProperty]] on the array of a species.
const speciesLog: string[] = [];
const speciesSource = [0, 1, 2];
(speciesSource as unknown as { constructor: unknown }).constructor = {
  [Symbol.species]: function (count: number) {
    return new Proxy(new Array(count), {
      defineProperty(t, key, desc) {
        speciesLog.push(`define ${String(key)}`);
        return Reflect.defineProperty(t, key, desc);
      },
      getOwnPropertyDescriptor(t, key) {
        speciesLog.push(`gopd ${String(key)}`);
        return Reflect.getOwnPropertyDescriptor(t, key);
      },
      set(t, key, value, receiver) {
        speciesLog.push(`set ${String(key)}`);
        return Reflect.set(t, key, value, receiver);
      },
    });
  },
};
speciesSource.splice(0, 2);
console.log(speciesLog.join(", "));

// A write through a typed array on the prototype chain defines the property on the
// receiver for a valid index, ignores an invalid index, and runs no inherited setter.
Object.defineProperty(Uint8Array.prototype, 0, {
  set() {
    console.log("inherited setter ran");
  },
  configurable: true,
});
const typed = new Uint8Array([7]);
const heir = Object.create(typed) as Record<number, unknown>;
heir[0] = "own";
heir[5] = "ignored";
console.log(typed[0], heir[0], Object.keys(heir).join(","));
delete (Uint8Array.prototype as unknown as Record<number, unknown>)[0];

// A typed array whose length can change stays extensible, and one with elements cannot
// freeze.
const resizable = new ArrayBuffer(4, { maxByteLength: 8 });
console.log(
  outcome(() => Object.preventExtensions(new Uint8Array(resizable))),
  Reflect.preventExtensions(new Uint8Array(resizable, 0, 2)),
  outcome(() => Object.freeze(new Uint8Array(resizable, 0, 0))),
  outcome(() => Object.freeze(new Uint8Array(2))),
  outcome(() => Object.freeze(new Uint8Array(0))),
  Reflect.preventExtensions(new Uint8Array(new SharedArrayBuffer(4, { maxByteLength: 8 }), 0, 2)),
);

// A strict write to a primitive calls [[Set]] with the primitive as the receiver.
const seen: string[] = [];
Object.defineProperty(Number.prototype, "mark", {
  set(this: unknown, value: unknown) {
    seen.push(`${typeof this} ${String(value)}`);
  },
  configurable: true,
});
Object.defineProperty(BigInt.prototype, "mark", {
  set(this: unknown, value: unknown) {
    seen.push(`${typeof this} ${String(value)}`);
  },
  configurable: true,
});
(5 as unknown as { mark: number }).mark = 1;
(5n as unknown as { mark: number }).mark = 2;
console.log(
  seen.join(", "),
  outcome(() => ((5 as unknown as { other: number }).other = 3)),
);
console.log(outcome(() => (("abc" as unknown as { length: number }).length = 1)));

// A super write calls [[Set]]: strict code throws when it fails, and sloppy code does not.
const sloppySuper = new Function(`
  var o = { m() { super.x = 1; Object.freeze(o); super.y = 2; return Object.keys(o).join(); } };
  return o.m();
`) as () => string;
console.log(sloppySuper());
const strictTarget = {
  m() {
    super.x = 1;
    Object.freeze(this);
    super.y = 2;
  },
};
console.log(
  outcome(() => strictTarget.m()),
  Object.keys(strictTarget).join(),
);

// The base of o[k] must not be null before the key converts.
const loudKey = {
  toString() {
    throw new RangeError("key converted first");
  },
};
const nothing = null as unknown as Record<string, unknown>;
console.log(
  outcome(() => nothing[loudKey as unknown as string]),
  outcome(() => (nothing[loudKey as unknown as string] = 1)),
  outcome(() => delete nothing[loudKey as unknown as string]),
);

// A reviver that drops a value sees a throwing [[Delete]].
const guarded = new Proxy([0], {
  deleteProperty() {
    throw new RangeError("delete trap");
  },
});
console.log(
  outcome(() =>
    JSON.parse("[0,0]", function (this: unknown[]) {
      this[1] = guarded;
    }),
  ),
);

// Object.prototype.valueOf calls ToObject.
console.log(typeof Object.prototype.valueOf.call(true), typeof Object.prototype.valueOf.call(1));

// GetPrototypeFromConstructor reads the prototype of any new.target, and a revoked proxy
// without one has no realm.
console.log(
  Object.getPrototypeOf(Reflect.construct(WeakRef, [{}], Object)) === Object.prototype,
  Object.getPrototypeOf(Reflect.construct(FinalizationRegistry, [() => {}], Array)) ===
    Array.prototype,
);
const revocable = Proxy.revocable(function () {}, {
  get() {
    revocable.revoke();
    return undefined;
  },
});
console.log(outcome(() => new (revocable.proxy as unknown as new () => object)()));

// Of duplicate parameter names, only the last maps to the arguments object.
const duplicates = new Function("a", "a", "a", "a = 9; return arguments;") as (
  ...values: number[]
) => ArrayLike<number>;
console.log(Array.from(duplicates(1, 2, 3)).join());

// A destructured var inside with writes to the object that has the name.
const withPattern = new Function(`
  var env = { c: 0, e: 0 };
  with (env) {
    var { p: c } = { p: 1 };
    var [d, e = 5] = [2];
  }
  return [env.c, env.e, c, d, e].join();
`) as () => string;
console.log(withPattern());
