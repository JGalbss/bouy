// CommonJS on the reference engine: the wrapper arguments, require and its cache, the
// named exports that Node's lexer finds, the default export, require of an ES module,
// and JSON modules.
import legacy, { greet, kind, helper } from "./modules/legacy.cjs";
import * as legacyNamespace from "./modules/legacy.cjs";
import replaced from "./modules/replaced.cjs";
import flagged, * as flaggedNamespace from "./modules/esm-flag.cjs";
import report from "./modules/requires-esm.cjs";
import data from "./modules/data.json" with { type: "json" };

console.log(greet("bouy"), kind, helper);
console.log(legacy.self, legacy.file, legacy.dir, legacy.loaded);
console.log(Object.keys(legacyNamespace));
console.log(legacyNamespace.default === legacy, legacyNamespace["module.exports"] === legacy);
console.log(replaced(), replaced.extra);
console.log(flagged.default, flagged.other, Object.keys(flaggedNamespace));
console.log(report.esm, report.data, report.cached, report.resolved, report.inCache);
console.log(data.name, data.items);
