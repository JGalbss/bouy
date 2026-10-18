import lexer, { alpha, beta, gamma, delta } from "@buoytest/lexer";
import * as namespace from "@buoytest/lexer";

console.log(`${alpha} ${beta()} ${gamma} ${delta}`);
console.log(`named exports: ${Object.keys(namespace).sort().join(", ")}`);
console.log(`hidden through the default export: ${lexer.hidden}`);
