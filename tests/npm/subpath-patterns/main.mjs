import { name as root } from "@bouytest/patterns";
import { name as alpha } from "@bouytest/patterns/features/alpha";
import { name as beta } from "@bouytest/patterns/features/beta";
import { name as gamma } from "@bouytest/patterns/utils/gamma.js";

console.log([root, alpha, beta, gamma].join(" "));
for (const specifier of [
  "@bouytest/patterns/features/internal/secret",
  "@bouytest/patterns/utils/gamma",
  "@bouytest/patterns/src/index.js",
]) {
  try {
    await import(specifier);
    console.log(`${specifier} loads`);
  } catch (error) {
    console.log(`${specifier} throws ${error.code}`);
  }
}
