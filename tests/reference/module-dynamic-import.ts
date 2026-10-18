// import() on the reference engine: a promise of the namespace that loads once, a
// specifier computed at run time, a rejection for a missing module, and top-level
// await in the graph.
import { steps, ready } from "./modules/tla-dep.ts";

console.log("tla", steps.join(","), ready);
console.log("before import");
const first = import("./modules/lazy.ts");
console.log("import is a promise", first instanceof Promise);
const lazy = await first;
const again = await import("./modules/lazy.ts");
console.log(lazy.name, lazy.default.kind, lazy === again);
console.log(lazy);
for (const language of ["en", "fr"]) {
  const locale = await import(`./modules/locale-${language}.ts`);
  console.log(language, locale.hello);
}
try {
  await import("./modules/missing.ts");
} catch (error) {
  console.log("missing", (error as { code: string }).code);
}
const order: string[] = [];
const pending = import("./modules/locale-en.ts").then(() => order.push("import"));
Promise.resolve().then(() => order.push("microtask"));
await pending;
console.log("order", order.join(","));
// import() in eval code resolves from the module that called eval.
const viaEval = await eval('import("./modules/lazy.ts")');
console.log("eval import", viaEval === lazy);
