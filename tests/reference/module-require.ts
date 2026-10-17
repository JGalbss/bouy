// require on the reference engine, through createRequire of node:module: CommonJS
// cycles, errors, JSON, a top-level return, and require.cache.
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
require("./modules/require-cases.cjs");
console.log("resolve", require.resolve("./modules/count.json").endsWith("modules/count.json"));
