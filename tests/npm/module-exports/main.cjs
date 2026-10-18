const greet = require("@buoytest/assign");
const properties = require("@buoytest/properties");

console.log(`${typeof greet} ${greet.name} ${greet.version}`);
console.log(greet("buoy"));
console.log(Object.keys(properties).join(" "));
console.log(`${properties.add(2, 3)} ${properties.name} ${properties.both}`);
console.log(require("@buoytest/assign") === greet);
