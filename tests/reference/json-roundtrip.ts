// JSON.stringify and JSON.parse over nested objects, arrays, and toJSON.
const data = {
  name: "widget",
  sizes: [1, 2.5, -3],
  meta: { ok: true, none: null, skip: undefined, nested: { deep: ["x"] } },
  when: { toJSON: () => "custom" },
};
const text = JSON.stringify(data);
console.log(text);
const back = JSON.parse(text);
back.sizes.push(4);
console.log(back.sizes.length, data.sizes.length, back.meta.nested.deep[0]);
console.log(JSON.stringify({ a: [1, { b: 2 }] }, null, 2));
console.log(JSON.stringify([new Map(), new Set([1])]), JSON.stringify('q"uote\n'));
