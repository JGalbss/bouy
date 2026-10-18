import { name as root } from "@buoytest/patterns";
import { name as alpha } from "@buoytest/patterns/features/alpha";
import { name as beta } from "@buoytest/patterns/features/beta";
import { name as gamma } from "@buoytest/patterns/utils/gamma.js";

console.log([root, alpha, beta, gamma].join(" "));
for (const specifier of [
  "@buoytest/patterns/features/internal/secret",
  "@buoytest/patterns/utils/gamma",
  "@buoytest/patterns/src/index.js",
]) {
  try {
    await import(specifier);
    console.log(`${specifier} loads`);
  } catch (error) {
    console.log(`${specifier} throws ${error.code}`);
  }
}
