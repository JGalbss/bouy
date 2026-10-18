import { dependency, real } from "@buoytest/linked";

console.log(dependency);
console.log(`the module runs from its real path: ${real}`);
try {
  await import("@buoytest/dep");
} catch (error) {
  console.log(`the dependency of a dependency is not visible here: ${error.code}`);
}
