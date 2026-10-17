import { where } from "@bouytest/self";
import { help } from "@bouytest/self/helper";

console.log(where);
console.log(help);
try {
  await import("@bouytest/self/main.mjs");
} catch (error) {
  console.log(`an unexported path of the package throws ${error.code}`);
}
