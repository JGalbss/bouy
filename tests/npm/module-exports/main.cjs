const greet = require("@bouytest/assign");
const properties = require("@bouytest/properties");

console.log(`${typeof greet} ${greet.name} ${greet.version}`);
console.log(greet("bouy"));
console.log(Object.keys(properties).join(" "));
console.log(`${properties.add(2, 3)} ${properties.name} ${properties.both}`);
console.log(require("@bouytest/assign") === greet);
