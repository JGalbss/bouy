function main(): void {
  const ages = new Map<string, number>();
  ages.set("zed", 30);
  ages.set("amy", 25);
  ages.set("bob", 41);
  console.log(ages.size, ages.get("amy"), ages.get("nobody"), ages.has("zed"));
  ages.set("zed", 31);
  for (const [name, age] of ages) {
    console.log(name, age);
  }
  console.log([...ages.keys()].join(","), [...ages.values()].join(","));
  ages.delete("amy");
  console.log(ages.size, ages.has("amy"));
  const seen = new Set<number>();
  for (const n of [3, 1, 3, 2, 1]) {
    seen.add(n);
  }
  console.log(seen.size, [...seen].join(","), seen.has(2), seen.has(9));
  seen.delete(3);
  console.log([...seen].join(","));
  const fromEntries = new Map([
    ["a", 1],
    ["b", 2],
  ]);
  console.log(fromEntries.get("b"));
  const unique = new Set("mississippi");
  console.log([...unique].join(""));
  ages.forEach((age, name) => {
    console.log(`${name}=${age}`);
  });
  console.log(new Map([["k", "v"]]));
  console.log(new Set([1, 2]));
  ages.clear();
  console.log(ages.size);
}

main();
