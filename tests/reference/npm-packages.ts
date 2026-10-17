// Real packages from tests/node_modules, unchanged: an ES module package, a package that
// chooses its file by the `import` and `require` conditions of its `exports`, a CommonJS
// package, a CommonJS package that requires another package, and an ES module wrapper
// that imports its CommonJS build.
import isPlainObject from "is-plain-obj";
import { defu } from "defu";
import defuDefault from "defu";
import stringify from "fast-json-stable-stringify";
import extend from "extend-shallow";
import EventEmitter, { EventEmitter as Named } from "eventemitter3";
import required from "./modules/requires-defu.cjs";

console.log("is-plain-obj", isPlainObject({ a: 1 }), isPlainObject([]), isPlainObject(null));
console.log("defu", defu({ a: { b: 1 } }, { a: { b: 2, c: 3 }, d: [1] }), defu === defuDefault);
console.log("defu require", required.merged, required.defu === defu);
console.log("stable", stringify({ b: 2, a: [3, { d: 4, c: 5 }] }));
console.log("extend", extend({ a: 1 }, { b: 2 }, { a: 3 }));
const emitter = new EventEmitter();
emitter.on("ping", (value: number) => console.log("ping", value));
emitter.once("ping", (value: number) => console.log("once", value));
emitter.emit("ping", 1);
emitter.emit("ping", 2);
console.log("eventemitter3", EventEmitter === Named, emitter.listenerCount("ping"));
