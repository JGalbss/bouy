import { condition } from "@bouytest/conditions";
import manifest from "@bouytest/conditions/package.json" with { type: "json" };

console.log(`import picks ${condition}`);
console.log(`the manifest names ${manifest.name}`);
