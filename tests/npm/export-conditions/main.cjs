const { condition } = require("@buoytest/conditions");

console.log(`require picks ${condition}`);
try {
  require("@buoytest/conditions/default.js");
} catch (error) {
  console.log(`an unexported path throws ${error.code}`);
}
