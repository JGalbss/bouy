import local from "./data.json" with { type: "json" };
import packaged from "@bouytest/json-data/data.json" with { type: "json" };

console.log(`${local.name}: ${local.items.join(",")}`);
console.log(`${packaged.source}: ${packaged.count}`);
try {
  await import("./data.json");
} catch (error) {
  console.log(`an import without the type attribute throws ${error.code}`);
}
