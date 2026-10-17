import greet from "@bouytest/assign";
import properties, { add, name } from "@bouytest/properties";

console.log(`${typeof greet} ${greet("bouy")}`);
console.log(`${add(2, 3)} ${name} ${properties.both}`);
