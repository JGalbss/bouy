// JSON.parse with a reviver and its source context, and the parse errors;
// JSON.stringify with property lists, gaps, toJSON, wrappers, lone
// surrogates, and JSON.rawJSON.
const parsed = JSON.parse(
  '{"b": [1, 2.50, "x\\u00e9\\ud800"], "a": {"n": null}, "a": true}',
  function (key, value, context) {
    if (typeof value === "number") return `${value}@${context.source}`;
    return value;
  },
);
console.log(parsed, Object.keys(parsed));
console.log(
  JSON.stringify({ b: 2, a: [1, { c: 3, d: 4 }], e: undefined, f: () => 1 }, ["a", "c", "b"], "--"),
);
console.log(
  JSON.stringify([new Number(3), new String("s"), new Boolean(false), Object(5n) && 1]),
  JSON.stringify(" \u0007\ud834"),
);
console.log(
  JSON.stringify({
    toJSON(key: string) {
      return "key:" + key;
    },
  }),
  JSON.stringify({
    x: {
      toJSON() {
        return undefined;
      },
    },
  }),
);
console.log(
  JSON.stringify({ big: JSON.rawJSON("12345678901234567890") }),
  JSON.isRawJSON(JSON.rawJSON("1")),
  JSON.stringify(1e21),
  JSON.stringify(-0),
);
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
// JSON.parse without a reviver: keys that are array indexes come first, a repeated key
// keeps its first position and its last value, "__proto__" is an own property, and the
// numbers take their exact double.
const keyed = JSON.parse(
  '{"b":1,"2":2,"a":3,"1":4,"01":5,"4294967295":6,"b":7,"__proto__":{"x":1}}',
);
console.log(
  Object.keys(keyed),
  keyed.b,
  Object.getPrototypeOf(keyed) === Object.prototype,
  keyed.__proto__.x,
);
const numbers = JSON.parse(
  "[-0, 0, 1e2, 1E-2, 0.1, 12345678901234567890, 9007199254740993, 1e400, -1e400, -1.5e-7]",
);
console.log(numbers.map((n: number) => String(n)).join(" "), Object.is(numbers[0], -0));
const strings = JSON.parse(
  '["\\u00e9\\u20ac\\ud83d\\ude00\\ud800", "café", "中文", "\\"\\\\\\/\\b\\f\\n\\r\\t"]',
);
console.log(strings.map((s: string) => s.length).join(" "), JSON.stringify(strings));
const wide = JSON.parse('{"€": ["é", 1, {"kéy": "中"}], "plain": "x"}');
console.log(Object.keys(wide), JSON.stringify(wide));
// A document large enough to take many time slices, and one nested 10000 deep.
const records = Array.from({ length: 20000 }, (_, i) => ({
  i,
  s: "item " + i,
  f: i / 8,
  t: [i % 3 === 0, null, "é" + i],
}));
const text = JSON.stringify(records);
const back = JSON.parse(text);
console.log(
  back.length,
  back[19999].s,
  back[12345].f,
  back[777].t[2],
  JSON.stringify(back) === text,
);
const deep = JSON.parse("[".repeat(10000) + "]".repeat(10000));
let depth = 0;
for (let level = deep; Array.isArray(level) && level.length > 0; level = level[0]) depth++;
console.log(depth);
for (const text of ["[1 2]", '{"a":1,}', "tru", "nul", "{} x", '"\\u12G4"', '"\u0001"', " "]) {
  try {
    JSON.parse(text);
  } catch (error) {
    console.log((error as Error).name + ": " + (error as Error).message);
  }
}
