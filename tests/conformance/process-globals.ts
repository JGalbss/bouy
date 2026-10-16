function main(): void {
  console.log(process.argv.slice(2).length);
  console.log(typeof process.argv[0], process.argv.length >= 2);
  console.log(process.env.BOUY_CONFORMANCE_UNSET_VARIABLE === undefined);
  console.log(typeof process.env.PATH);
  const copy = structuredClone({ list: [1, 2], name: "x" });
  copy.list.push(3);
  console.log(copy.list.length, copy.name);
}

main();
