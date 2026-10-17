// A CommonJS module: exports properties, then reads its own wrapper arguments.
const path = require("./legacy-helper.cjs");
exports.greet = function greet(name) {
  return "hello " + name;
};
exports.kind = typeof module;
exports.self = this === module.exports;
exports.file = __filename.endsWith("legacy.cjs");
exports.dir = __dirname === module.path;
exports.helper = path.helper();
exports.loaded = module.loaded;
