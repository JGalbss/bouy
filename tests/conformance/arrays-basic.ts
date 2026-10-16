function main(): void {
  const xs = [5, 3, 8, 1, 9, 2];
  console.log(xs.length, xs[0], xs[xs.length - 1]);
  console.log(xs.map((x) => x * 10).join(","));
  console.log(xs.filter((x) => x % 2 === 1).join(","));
  console.log(xs.reduce((sum, x) => sum + x, 0));
  console.log(
    xs.find((x) => x > 6),
    xs.find((x) => x > 100),
  );
  console.log(
    xs.findIndex((x) => x === 8),
    xs.indexOf(9),
    xs.indexOf(42),
  );
  console.log(
    xs.some((x) => x > 8),
    xs.every((x) => x > 0),
    xs.includes(3),
  );
  console.log(xs.slice(1, 3).join(","), xs.slice(-2).join(","));
  console.log(xs.concat([100, 200]).join(","));
  console.log(xs.at(-1), xs.at(0));
  console.log([1, [2, [3, [4]]]].flat().length, [1, [2, [3, [4]]]].flat(Infinity).join(","));
  console.log([1, 2, 3].flatMap((x) => [x, x * 2]).join(","));
  console.log(xs.join(), [].join("-"), ["a"].join("-"));
  console.log(Array.isArray(xs), Array.isArray("no"));
  console.log(Array.from("abc").join("|"), Array.of(7, 8).join("|"));
  console.log(xs);
  console.log([[1, 2], [3]]);
  console.log(["a", "b"]);
}

main();
