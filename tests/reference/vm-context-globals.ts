// A vm context has the globals of the language and console, but none of
// Node's own, and a global that it defines stays in the context.
import vm from "node:vm";

const names = [
  "process",
  "Buffer",
  "global",
  "setImmediate",
  "clearImmediate",
  "URL",
  "console",
  "Array",
];
console.log(vm.runInNewContext(`[${names.map((name) => `typeof ${name}`).join(", ")}]`).join(" "));

const context = vm.createContext(vm.constants.DONT_CONTEXTIFY);
const copied = Object.getOwnPropertyDescriptor(globalThis, "global");
if (copied !== undefined) Object.defineProperty(context, "global", copied);
context.global = context;
context.process = "context process";
console.log(globalThis.global === globalThis, typeof process, context.process);
console.log(vm.runInContext("global === globalThis", context));
