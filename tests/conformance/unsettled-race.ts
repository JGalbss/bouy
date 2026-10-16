// An empty Promise.race never settles. Top-level code that awaits it ends the
// program with status 13, as Node ends it.

console.log("before");
const xs: number[] = [];
await Promise.race(xs.map(async (x) => x));
console.log("after");
