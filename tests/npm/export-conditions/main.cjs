const { condition } = require("@bouytest/conditions");

console.log(`require picks ${condition}`);
try {
  require("@bouytest/conditions/default.js");
} catch (error) {
  console.log(`an unexported path throws ${error.code}`);
}
