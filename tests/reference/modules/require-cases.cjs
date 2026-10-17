// require from CommonJS: a cycle, a missing module, the shared JSON value, a top-level
// return, and require.cache.
console.log("wrapper", require.main === module, typeof __filename, arguments.length);
const a = require("./cycle-a.cjs");
console.log("cycle", a.done, a.fromB);
try {
  require("./missing.cjs");
} catch (error) {
  console.log("missing", error.code);
}
try {
  require.resolve("nope-package");
} catch (error) {
  console.log("resolve", error.code);
}
const json = require("./count.json");
json.count += 1;
console.log("json shared", require("./count.json").count);
console.log("early", require("./early-return.cjs"));
console.log("this", this === module.exports);
delete require.cache[require.resolve("./loads.cjs")];
console.log("loads", require("./loads.cjs").n, require("./loads.cjs").n);
delete require.cache[require.resolve("./loads.cjs")];
console.log("loads again", require("./loads.cjs").n);
console.log("toString", String(function named(a) { return a; }), String((b) => b));
