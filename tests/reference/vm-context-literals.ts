// An object literal in the code of a vm context takes the Object.prototype of
// that context, as an array literal does.
import vm from "node:vm";

const context = vm.createContext({});
console.log(vm.runInContext("({}) instanceof Object", context));
console.log(vm.runInContext("Object.getPrototypeOf({ a: 1 }) === Object.prototype", context));
console.log(vm.runInContext("({ ...{ a: 1 }, b: 2 }).constructor === Object", context));
console.log(vm.runInContext("[] instanceof Array", context));
const inner = vm.runInContext("({ a: 1 })", context);
console.log(inner instanceof Object, Object.getPrototypeOf(inner) === Object.prototype);
console.log({} instanceof Object);
