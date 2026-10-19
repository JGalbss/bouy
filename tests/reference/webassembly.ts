// The JavaScript API of WebAssembly: modules, instances, imports, memory,
// tables, globals, traps, errors, and JSPI.
const bytes = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 47, 10, 96, 1, 127, 0, 96, 0, 2, 127, 126, 96, 2, 127, 127, 1, 127, 96, 1, 127, 1, 127, 96, 2, 127, 127, 0, 96, 0, 0, 96, 1, 126, 1, 126, 96, 1, 125, 1, 125, 96, 0, 1, 126, 96, 0, 1, 127, 2, 42, 4, 2, 106, 115, 3, 108, 111, 103, 0, 0, 2, 106, 115, 4, 112, 97, 105, 114, 0, 1, 2, 106, 115, 3, 109, 101, 109, 2, 1, 1, 4, 2, 106, 115, 4, 115, 101, 101, 100, 3, 127, 0, 3, 12, 11, 2, 0, 3, 4, 5, 2, 6, 7, 8, 9, 3, 4, 4, 1, 112, 0, 2, 6, 6, 1, 127, 1, 65, 7, 11, 7, 95, 13, 1, 103, 3, 1, 3, 116, 98, 108, 1, 0, 3, 97, 100, 100, 0, 2, 7, 99, 97, 108, 108, 76, 111, 103, 0, 3, 4, 108, 111, 97, 100, 0, 4, 5, 115, 116, 111, 114, 101, 0, 5, 4, 116, 114, 97, 112, 0, 6, 6, 100, 105, 118, 105, 100, 101, 0, 7, 3, 98, 105, 103, 0, 8, 4, 104, 97, 108, 102, 0, 9, 7, 115, 117, 109, 80, 97, 105, 114, 0, 10, 4, 103, 114, 111, 119, 0, 11, 4, 115, 112, 105, 110, 0, 12, 9, 7, 1, 0, 65, 0, 11, 1, 2, 10, 122, 11, 7, 0, 32, 0, 32, 1, 106, 11, 9, 0, 32, 0, 35, 0, 106, 16, 0, 11, 7, 0, 32, 0, 45, 0, 0, 11, 9, 0, 32, 0, 32, 1, 58, 0, 0, 11, 3, 0, 0, 11, 7, 0, 32, 0, 32, 1, 109, 11, 7, 0, 32, 0, 66, 1, 124, 11, 10, 0, 32, 0, 67, 0, 0, 0, 63, 148, 11, 12, 1, 1, 126, 16, 1, 33, 0, 172, 32, 0, 124, 11, 6, 0, 65, 1, 64, 0, 11, 33, 1, 1, 127, 2, 64, 3, 64, 32, 0, 69, 13, 1, 32, 1, 65, 1, 106, 33, 1, 32, 0, 65, 1, 107, 33, 0, 12, 0, 11, 11, 32, 1, 11, 0, 50, 4, 110, 97, 109, 101, 1, 17, 3, 0, 3, 108, 111, 103, 1, 4, 112, 97, 105, 114, 2, 3, 97, 100, 100, 2, 6, 1, 10, 1, 0, 1, 98, 5, 4, 1, 0, 1, 116, 7, 10, 2, 0, 4, 115, 101, 101, 100, 1, 1, 103]);
const jspiBytes = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 127, 2, 11, 1, 2, 106, 115, 4, 119, 97, 105, 116, 0, 0, 3, 2, 1, 0, 7, 9, 1, 5, 116, 119, 105, 99, 101, 0, 1, 10, 13, 1, 11, 0, 32, 0, 16, 0, 32, 0, 16, 0, 106, 11, 0, 14, 4, 110, 97, 109, 101, 1, 7, 1, 0, 4, 119, 97, 105, 116]);

const show = (label: string, f: () => unknown): void => {
  try {
    console.log(label, f());
  } catch (error) {
    const e = error as Error;
    console.log(label, "threw", e.constructor.name, e instanceof Error);
  }
};

console.log(typeof WebAssembly, Object.prototype.toString.call(WebAssembly));
console.log(WebAssembly.validate(bytes), WebAssembly.validate(new Uint8Array([0, 97, 115, 109, 2, 0, 0, 0])));
const module = new WebAssembly.Module(bytes);
console.log(JSON.stringify(WebAssembly.Module.imports(module)));
console.log(JSON.stringify(WebAssembly.Module.exports(module)));
console.log(WebAssembly.Module.customSections(module, "name").length);

const logged: number[] = [];
const memory = new WebAssembly.Memory({ initial: 1, maximum: 4 });
const imports = {
  js: {
    log: (value: number) => logged.push(value),
    pair: () => [5, 10n],
    mem: memory,
    seed: 100,
  },
};
const instance = new WebAssembly.Instance(module, imports);
const exports = instance.exports as Record<string, any>;
console.log(Object.keys(exports).join(","));
console.log(Object.getPrototypeOf(exports), Object.isFrozen(exports));
console.log(exports.add(2, 3), exports.add.name, exports.add.length, exports.add === instance.exports.add);
console.log(exports.add(2 ** 31, 1), exports.add("4", 1.9));
exports.callLog(5);
console.log(logged);
console.log(exports.big(41n), exports.half(3), exports.sumPair());
show("big of a number", () => exports.big(1));

const view = new Uint8Array(memory.buffer);
view[10] = 77;
console.log(exports.load(10), memory.buffer.byteLength);
exports.store(11, 300);
console.log(view[11], new Uint8Array(memory.buffer)[11]);
const before = memory.buffer;
console.log(exports.grow(), before.byteLength, memory.buffer.byteLength, memory.buffer === memory.buffer);
console.log(memory.grow(1), memory.buffer.byteLength);
show("grow past maximum", () => memory.grow(10));

console.log(exports.g.value, exports.g instanceof WebAssembly.Global);
exports.g.value = 9;
console.log(exports.g.value, exports.g.valueOf());
const big = new WebAssembly.Global({ value: "i64", mutable: true }, 5n);
big.value = 7n;
console.log(big.value);
show("immutable global", () => {
  const fixed = new WebAssembly.Global({ value: "i32" }, 1);
  (fixed as any).value = 2;
  return fixed.value;
});

const table = exports.tbl as WebAssembly.Table;
console.log(table.length, table.get(0) === exports.add, table.get(1));
table.set(1, exports.add);
console.log(table.get(1) === exports.add, table.grow(2), table.length);
show("set a plain function", () => table.set(0, () => 1));

show("trap", () => exports.trap());
try {
  exports.trap();
} catch (error) {
  const e = error as Error;
  console.log(e instanceof WebAssembly.RuntimeError, e.message);
}
try {
  exports.divide(1, 0);
} catch (error) {
  console.log((error as Error).message);
}
show("missing import", () => new WebAssembly.Instance(module, {}));
show("bad import", () => new WebAssembly.Instance(module, { js: { ...imports.js, log: 5 } }));
show("bad bytes", () => new WebAssembly.Module(new Uint8Array([1, 2, 3])));
console.log(new WebAssembly.CompileError("x").name, WebAssembly.LinkError.prototype instanceof Error);
console.log(exports.spin(200000));

const thrower = new WebAssembly.Instance(module, {
  js: {
    ...imports.js,
    log: () => {
      throw new RangeError("from js");
    },
  },
});
try {
  (thrower.exports as any).callLog(1);
} catch (error) {
  console.log((error as Error).constructor.name, (error as Error).message);
}

const { instance: asyncInstance, module: asyncModule } = await WebAssembly.instantiate(bytes, imports);
console.log(asyncModule instanceof WebAssembly.Module, (asyncInstance.exports as any).add(20, 22));
const again = await WebAssembly.instantiate(asyncModule, imports);
console.log(again instanceof WebAssembly.Instance);
await WebAssembly.compile(new Uint8Array([1])).catch((error: Error) => console.log("rejected", error.constructor.name));

const jspi = new WebAssembly.Instance(new WebAssembly.Module(jspiBytes), {
  js: {
    wait: new WebAssembly.Suspending(async (x: number) => {
      await new Promise((resolve) => setTimeout(resolve, 5));
      return x * 10;
    }),
  },
});
const twice = WebAssembly.promising((jspi.exports as any).twice);
console.log(await twice(4));

const words = new Int32Array(new WebAssembly.Memory({ initial: 1 }).buffer);
console.log(
  Atomics.add(words, 0, 5),
  Atomics.compareExchange(words, 0, 5, 7),
  Atomics.exchange(words, 0, 1),
  Atomics.or(words, 0, 2),
  Atomics.load(words, 0),
  Atomics.notify(words, 0, 1),
);
