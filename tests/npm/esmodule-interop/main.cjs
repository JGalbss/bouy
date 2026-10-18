const transpiled = require("@buoytest/transpiled");

console.log(`__esModule: ${transpiled.__esModule}`);
console.log(`default: ${transpiled.default()}`);
console.log(`helper: ${transpiled.helper()}`);
