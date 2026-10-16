interface Options {
  name?: string;
  retries?: number;
  tags?: string[];
}

function configure({ name = "default", retries = 3, tags = [] }: Options): string {
  return `${name}:${retries}:${tags.length}`;
}

function main(): void {
  const [a, b, ...rest] = [1, 2, 3, 4, 5];
  console.log(a, b, rest.join(","));
  const [x, , z = 30] = [10, 20];
  console.log(x, z);
  const {
    first,
    second: renamed,
    missing = "fallback",
  } = { first: 1, second: 2 } as {
    first: number;
    second: number;
    missing?: string;
  };
  console.log(first, renamed, missing);
  const { keep, ...others } = { keep: 1, drop1: 2, drop2: 3 };
  console.log(keep, Object.keys(others).sort().join(","));
  const {
    outer: { inner },
  } = { outer: { inner: "deep" } };
  console.log(inner);
  console.log(configure({}), configure({ name: "x", tags: ["t"] }));
  let left = 1;
  let right = 2;
  [left, right] = [right, left];
  console.log(left, right);
  const pairs: [string, number][] = [
    ["one", 1],
    ["two", 2],
  ];
  for (const [word, num] of pairs) {
    console.log(word, num);
  }
  const [head, ...tail] = "hey";
  console.log(head, tail.join("+"));
}

main();
