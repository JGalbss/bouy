// JSON.parse with a reviver and its source context, and the parse errors;
// JSON.stringify with property lists, gaps, toJSON, wrappers, lone
// surrogates, and JSON.rawJSON.
const parsed = JSON.parse('{"b": [1, 2.50, "x\\u00e9\\ud800"], "a": {"n": null}, "a": true}', function (key, value, context) {
  if (typeof value === "number") return `${value}@${context.source}`;
  return value;
});
console.log(parsed, Object.keys(parsed));
console.log(JSON.stringify({ b: 2, a: [1, { c: 3, d: 4 }], e: undefined, f: () => 1 }, ["a", "c", "b"], "--"));
console.log(JSON.stringify([new Number(3), new String("s"), new Boolean(false), Object(5n) && 1]), JSON.stringify(" \u0007\ud834"));
console.log(JSON.stringify({ toJSON(key: string) { return "key:" + key; } }), JSON.stringify({ x: { toJSON() { return undefined; } } }));
console.log(JSON.stringify({ big: JSON.rawJSON("12345678901234567890") }), JSON.isRawJSON(JSON.rawJSON("1")), JSON.stringify(1e21), JSON.stringify(-0));
for (const text of ["[1,]", "", "[1", '{"a" 1}', '"abc', "01", "-", "1.", "1e", '"\\x"', "{a:1}"]) {
  try {
    JSON.parse(text);
  } catch (error) {
    console.log((error as Error).name + ": " + (error as Error).message);
  }
}
const cycle: Record<string, unknown> = {};
cycle.self = cycle;
try {
  JSON.stringify(cycle);
} catch (error) {
  console.log((error as Error).name);
}
