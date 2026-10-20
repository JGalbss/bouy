// Two forms of `var` that sloppy code keeps for the web (Annex B.3.4 and B.3.5): a `var`
// in a catch block that names the catch parameter writes the parameter, and the
// initializer of a `for (var x = init in o)` runs once, before the object.
var name = "before";
try {
  throw new Error("thrown");
} catch (name) {
  var name = "in catch";
}
var effects = 0;
for (var key = ++effects in {}) {
  break;
}
module.exports = [name, effects, key].join(",");
