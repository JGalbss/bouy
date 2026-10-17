import { config } from "#config";
import { twice } from "#lib/math";
import { origin } from "#dependency";
import { via } from "#conditional";

console.log(`mode ${config.mode}`);
console.log(`twice 21 is ${twice(21)}`);
console.log(origin);
console.log(`#conditional resolves through ${via}`);
try {
  await import("#missing");
} catch (error) {
  console.log(`#missing throws ${error.code}`);
}
