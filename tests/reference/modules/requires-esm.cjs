const esm = require("./plain-esm.mjs");
const data = require("./data.json");
const again = require("./legacy-helper.cjs");
module.exports = {
  esm: [esm.value, typeof esm.default, Object.keys(esm).join(",")],
  data: data.items.length + ":" + data.name,
  cached: again === require("./legacy-helper.cjs"),
  resolved: require.resolve("./data.json").endsWith("modules/data.json"),
  inCache: Object.keys(require.cache).some((key) => key.endsWith("legacy-helper.cjs")),
  nested: require("./esm-imports-esm.mjs").nested,
};
