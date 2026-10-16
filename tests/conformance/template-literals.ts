function describe(name: string, count: number): string {
  return `${name} has ${count} item${count === 1 ? "" : "s"}`;
}

function main(): void {
  console.log(describe("box", 1));
  console.log(describe("crate", 3));
  const a = 2;
  const b = 3;
  console.log(`${a} + ${b} = ${a + b}`);
  console.log(`nested ${`inner ${a * b}`} done`);
  console.log(`values: ${[1, 2, 3]} and ${null} and ${undefined} and ${true}`);
  const multi = `line one
line two`;
  console.log(multi);
  console.log(`escaped \${not} and \`ticks\``);
}

main();
