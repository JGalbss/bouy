// A classic script completes with the value of its last expression statement,
// and a directive is one, as eval does.
import vm from "node:vm";

console.log(vm.runInThisContext("'42'"));
console.log(vm.runInThisContext("'use strict'; 'second'"));
console.log(vm.runInThisContext("'first'; var unused = 1;"));
console.log(vm.runInThisContext("'\\x41'"));
console.log(vm.runInNewContext("'in a context'"));
console.log(new vm.Script("'from a script'").runInThisContext());
