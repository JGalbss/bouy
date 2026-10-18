// Realms: a function runs in the realm that made it, also when a builtin of another
// realm, here a vm context, calls it back.
import vm from "node:vm";

const context = vm.createContext({});
const forEach = vm.runInContext("Array.prototype.forEach", context) as (
  this: unknown[],
  callback: (value: number) => void,
) => void;
let total = 0;
forEach.call([1, 2], (value: number) => {
  total += value;
});
const made: boolean[] = [];
forEach.call([1], () => {
  made.push([].constructor === Array, {}.constructor === Object);
});
console.log("callback realm", total, made.join(","));
