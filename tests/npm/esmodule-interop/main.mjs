import transpiled, { helper } from "@buoytest/transpiled";
import * as namespace from "@buoytest/transpiled";

console.log(`default import: ${typeof transpiled}`);
console.log(`default import .default: ${transpiled.default()}`);
console.log(`helper: ${helper()}`);
console.log(`namespace keys: ${Object.keys(namespace).sort().join(", ")}`);
console.log(`namespace.default is module.exports: ${namespace.default === transpiled}`);
