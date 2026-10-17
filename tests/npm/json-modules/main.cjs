const local = require("./data.json");
const packaged = require("@bouytest/json-data/data.json");

console.log(`${local.name}: ${local.items.join(",")}`);
console.log(`${packaged.source}: ${packaged.count}`);
console.log(`cached: ${require("./data.json") === local}`);
