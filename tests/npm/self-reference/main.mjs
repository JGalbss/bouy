import { where } from "@buoytest/self";
import { help } from "@buoytest/self/helper";

console.log(where);
console.log(help);
try {
  await import("@buoytest/self/main.mjs");
} catch (error) {
  console.log(`an unexported path of the package throws ${error.code}`);
}
