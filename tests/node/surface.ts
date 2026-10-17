// The probe of the API surface manifest, section 5.7.1 of docs/design/testing.md.
// `bouy-suites node-surface` writes one program for each group of tests/node/surface.json, a
// module such as `node:fs` or a global such as `Buffer`. The program calls `probe` with the
// value of the group and its entries, and `probe` prints one line per entry: the name and
// the shape that scripts/node-surface.sh records. A member of the group value is read, so a
// lazy getter gives its value. A deeper member is looked up on the prototype chain, and an
// accessor is not called.

type Entry = readonly [name: string, ...keys: ReadonlyArray<PropertyKey>];

export function probe(root: unknown, entries: ReadonlyArray<Entry>): void {
  for (const [name, ...keys] of entries) {
    console.log(`${name} ${shapeOf(root, keys)}`);
  }
}

function shapeOf(root: unknown, keys: ReadonlyArray<PropertyKey>): string {
  try {
    const last = keys.at(-1);
    if (last === undefined) return describe(root);
    const holder = keys
      .slice(0, -1)
      .reduce<unknown>((value, key) => Reflect.get(Object(value), key), root);
    const descriptor = findDescriptor(holder, last);
    if (descriptor === undefined) return "missing";
    if (keys.length === 1) return describe(Reflect.get(Object(holder), last));
    return "value" in descriptor ? describe(descriptor.value) : "accessor";
  } catch {
    return "throws";
  }
}

// The walk of the manifest stops at Object.prototype and Function.prototype, so the lookup
// does too.
function findDescriptor(value: unknown, key: PropertyKey): PropertyDescriptor | undefined {
  for (
    let object = Object(value);
    object !== null && object !== Object.prototype && object !== Function.prototype;
    object = Object.getPrototypeOf(object)
  ) {
    const descriptor = Object.getOwnPropertyDescriptor(object, key);
    if (descriptor !== undefined) return descriptor;
  }
  return undefined;
}

function describe(value: unknown): string {
  return typeof value === "function" ? `function ${value.length}` : typeof value;
}
