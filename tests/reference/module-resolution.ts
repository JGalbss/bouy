// Node's resolution of bare specifiers on the reference engine: the import and require
// conditions of `exports`, subpath patterns, a null target, `imports` with conditions, a
// package that names itself, a legacy `main` without an extension, the format of a
// `.js` file by its package `type` or its syntax, and the modules of `data:` URLs.
import { report } from "./modules/resolution-cases.mjs";
import text from "data:text/javascript,export default %22a data module%22";
import meta from "data:text/javascript,export default Object.keys(import.meta)";
import decoded from "data:text/javascript;base64,ZXhwb3J0IGRlZmF1bHQgNDI=";
import list from "data:application/json,[1,2]" with { type: "json" };

await report();
console.log("data urls", text, meta, decoded, list);
console.log(
  "same instance",
  (await import("data:text/javascript,export default Object.keys(import.meta)")).default === meta,
);
