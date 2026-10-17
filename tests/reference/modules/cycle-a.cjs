exports.done = false;
const b = require("./cycle-b.cjs");
exports.fromB = b.sawA;
exports.done = true;
