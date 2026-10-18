const esm = require("@buoytest/esm-only");

console.log(`keys: ${Object.keys(esm).sort().join(", ")}`);
console.log(`value: ${esm.value}`);
console.log(`default: ${esm.default()}`);
console.log(`__esModule: ${esm.__esModule}`);
console.log(`same object twice: ${require("@buoytest/esm-only") === esm}`);
try {
  require("@buoytest/top-level-await");
} catch (error) {
  console.log(`top-level await throws ${error.code}`);
}
