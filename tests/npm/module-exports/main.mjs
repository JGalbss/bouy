import greet from "@buoytest/assign";
import properties, { add, name } from "@buoytest/properties";

console.log(`${typeof greet} ${greet("buoy")}`);
console.log(`${add(2, 3)} ${name} ${properties.both}`);
