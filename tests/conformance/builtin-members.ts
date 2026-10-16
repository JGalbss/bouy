// Built-in methods are properties too: a numeric key names a callable value,
// a method read as a property is a function, and the Object, Map, and JSON
// helpers that programs reach for exist.

function main(): void {
  const handlers = [(n: number) => n + 1, (n: number) => n * 2];
  console.log("index call:", handlers[0](10), handlers[1](10));
  const pairs: [string, (n: number) => number][] = [["double", (n) => n * 2]];
  for (const pair of pairs) console.log("tuple call:", pair[0], pair[1](21));
  const byCode: Record<number, () => string> = { 1: () => "one" };
  console.log("numeric key call:", byCode[1]());

  const xs = [1, 2, 3];
  console.log(
    "optional method:",
    xs.map?.((x) => x * 2),
    typeof xs.map,
    typeof "s".trim,
    typeof (5).toFixed,
  );
  console.log("missing method:", (xs as any).nope?.(1), typeof (xs as any).nope);
  const { toFixed } = 5 as any;
  console.log("destructured method:", typeof toFixed);
  console.log(
    "inherited:",
    "toString" in {},
    typeof ({} as any).toString,
    "map" in [],
    "size" in new Map(),
  );
  try {
    const f = xs.map;
    (f as any)((x: number) => x);
  } catch (e) {
    console.log("detached method:", (e as Error).name);
  }
  console.log(
    "method call:",
    [].map.call([1, 2], (x: number) => x + 1),
    "a-b".split.apply("a-b", ["-"]),
  );

  console.log("Object.is:", Object.is(NaN, NaN), Object.is("a", "a"), Object.is(1, 2));
  const grouped = Object.groupBy([1, 2, 3, 4, 5], (x) => (x % 2 ? "odd" : "even"));
  console.log("groupBy:", grouped.odd, grouped.even);
  const byLength = Map.groupBy(["a", "bb", "cc", "d"], (s) => s.length);
  console.log("Map.groupBy:", byLength.get(1), byLength.get(2), byLength.size);
  console.log(
    "getOwnPropertyNames:",
    Object.getOwnPropertyNames([7, 8]),
    Object.getOwnPropertyNames({ a: 1 }),
  );
  const dict = Object.create(null);
  dict.key = "value";
  console.log("Object.create(null):", dict.key, Object.keys(dict));

  console.log("map(JSON.parse):", ['{"a":1}', '{"a":2}'].map(JSON.parse));
  console.log(
    "map(JSON.stringify):",
    [[1, 2], [3]].map(JSON.stringify),
    ["a", "b"].map((s) => JSON.stringify(s, null)),
  );
  console.log("Array.from primitive:", Array.from(123 as any), Array.from(true as any));
  try {
    Object.fromEntries([1] as any);
  } catch (e) {
    console.log((e as Error).name + ": " + (e as Error).message);
  }
  try {
    (255).toString(1);
  } catch (e) {
    console.log((e as Error).name + ": " + (e as Error).message);
  }
}

main();
