// The global console has every method of Node's console, also in a program
// that has loaded no Node module before it calls them. A log function taken
// before the first group follows the group.
const log = console.log;
console.group("group");
console.log("inside");
log("kept");
console.groupEnd();
console.table([{ a: 1 }]);
console.count();
console.count();
console.dir({ a: { b: { c: 1 } } }, { depth: 0 });
console.log(typeof console.Console, typeof console.timeLog, console.log.length);
