// Node's resolution of bare specifiers on the reference engine: the import and require
// conditions of `exports`, subpath patterns, a null target, `imports` with conditions, a
// package that names itself, a legacy `main` without an extension, and the format of a
// `.js` file by its package `type` or its syntax.
import { report } from "./modules/resolution-cases.mjs";

await report();
