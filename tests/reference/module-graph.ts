// The ES module graph of the reference engine: live bindings, namespaces, default
// exports, re-exports, string export names, evaluation order, cycles, import.meta, and
// the facade of a built-in module.
import Counter, { count, increment, label } from "./modules/counter.ts";
import * as counter from "./modules/counter.ts";
import area, * as shapes from "./modules/shapes.ts";
import { "the answer" as answer } from "./modules/shapes.ts";
import "./modules/order-a.ts";
import { events } from "./modules/order-log.ts";
import { fromA, viaB } from "./modules/cycle-a.ts";
import { early } from "./modules/cycle-b.ts";
import path, * as pathNamespace from "node:path";
import { join } from "node:path";

console.log("live", count, counter.count);
increment();
increment();
console.log("live", count, counter.count, shapes.total);
console.log("label", label, area(3, 4), answer);
new Counter();
console.log("default class", Counter.name, Counter.created);
console.log("namespace keys", Object.keys(shapes));
console.log("namespace tag", Object.prototype.toString.call(shapes));
console.log("star", shapes.red, shapes.colors.green, shapes.colors.default);
console.log("null prototype", Object.getPrototypeOf(counter) === null);
try {
  (counter as { count: number }).count = 5;
} catch (error) {
  console.log("write", (error as Error).name);
}
console.log("same namespace", counter === (shapes.colors === shapes.colors ? counter : null));
console.log("order", events.join(","));
console.log("cycle", fromA(), viaB, early);
console.log(
  "meta",
  import.meta.url.startsWith("file://"),
  import.meta.filename.endsWith("module-graph.ts"),
);
console.log(
  "meta dirname",
  import.meta.dirname === import.meta.filename.slice(0, import.meta.filename.lastIndexOf("/")),
);
console.log(
  "meta resolve",
  import.meta.resolve("./modules/counter.ts").endsWith("/modules/counter.ts"),
);
console.log("meta main", import.meta.main);
console.log(
  "builtin",
  typeof path,
  pathNamespace.default === path,
  pathNamespace.join === join,
  Object.keys(pathNamespace).slice(0, 4),
  pathNamespace[Symbol.toStringTag],
);
