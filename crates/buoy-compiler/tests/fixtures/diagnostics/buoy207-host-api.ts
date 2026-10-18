setTimeout(() => console.log("later"), 10);
console.log(globalThis);
process.exit(1);
console.log(process.cwd());
