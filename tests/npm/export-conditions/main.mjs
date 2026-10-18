import { condition } from "@buoytest/conditions";
import manifest from "@buoytest/conditions/package.json" with { type: "json" };

console.log(`import picks ${condition}`);
console.log(`the manifest names ${manifest.name}`);
