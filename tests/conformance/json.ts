function main(): void {
  console.log(JSON.stringify({ a: 1, b: "two", c: [true, null] }));
  console.log(JSON.stringify([1, "x", { nested: [] }]));
  console.log(JSON.stringify('quote"and\\slash'));
  console.log(JSON.stringify({ z: 1 }, null, 2));
  const parsed = JSON.parse('{"name":"bouy","tags":["a","b"],"n":1.5,"ok":true,"none":null}');
  console.log(parsed.name, parsed.tags.length, parsed.n, parsed.ok, parsed.none);
  const list = JSON.parse("[1,2,3]");
  console.log(list.length, list[2]);
  console.log(JSON.stringify(JSON.parse('"text"')));
  console.log(JSON.stringify(undefined), JSON.stringify(null), JSON.stringify(42));
  try {
    JSON.parse("{bad json");
  } catch (e) {
    console.log("parse failed:", e instanceof SyntaxError);
  }
}

main();
