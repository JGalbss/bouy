// Labeled loops, switch fallthrough, do...while, break and continue.
const found: string[] = [];
outer: for (let i = 0; i < 4; i++) {
  for (let j = 0; j < 4; j++) {
    if (j === 2) continue outer;
    if (i === 3) break outer;
    found.push(`${i}${j}`);
  }
}
console.log(found.join(" "));

function classify(n: number): string {
  const parts: string[] = [];
  switch (n % 4) {
    case 0:
      parts.push("zero");
    case 1:
      parts.push("one-or-fallthrough");
      break;
    case 2: {
      parts.push("two");
      break;
    }
    default:
      parts.push("other");
  }
  return parts.join("+");
}
console.log([0, 1, 2, 3].map(classify));

let n = 0;
do {
  n += 3;
} while (n < 10);
console.log(n);

let steps = 0;
let value = 27;
while (value !== 1) {
  value = value % 2 === 0 ? value / 2 : 3 * value + 1;
  steps++;
}
console.log(steps);

const words = ["alpha", "beta", "gamma"];
let joined = "";
for (const w of words) {
  if (w === "beta") continue;
  joined += w[0];
}
for (const key in { p: 1, q: 2 }) joined += key;
console.log(joined);

// for...in skips a key that the loop body deletes before the loop reaches it.
const table: Record<string, number> = Object.create(null);
table.aa = 1;
table.ba = 2;
table.ca = 3;
let visited = "";
for (const key in table) {
  delete table.ba;
  visited += key + table[key];
}
console.log(visited);

// A parenthesized optional chain is still a reference: the call keeps its this.
const holder = {
  label: "holder",
  read(this: { label: string }): string {
    return this.label;
  },
};
const maybe: typeof holder | undefined = holder;
console.log((maybe?.read)(), (holder.read)?.(), (maybe?.read)?.());
